import Foundation
import CoreGraphics

// MARK: - Light Boost
//
// "Espresso": a timed wash of alerting cyan light over every screen, optionally
// paired with a display brightness bump. Bright, blue-cyan light near 480nm is
// the best-evidenced acute alertness intervention, and unlike a break reminder
// it needs no cooperation from the user — they keep working straight through it.
//
// Everything in this file is pure and clock-injected so it stays testable
// without a window server.

/// What asked for a boost. Manual boosts are trusted more than automatic ones:
/// they bypass the "is one already due" scheduling but not the evening cutoff.
public enum LightBoostTrigger: String, Equatable, Sendable {
    case manual
    case automatic
}

public enum LightBoostPhase: Equatable, Sendable {
    case idle
    case ramping
    case holding
    case fading
}

// MARK: - Configuration

public struct LightBoostConfig: Equatable, Sendable {
    /// Master switch for the whole feature.
    public var isEnabled: Bool
    /// Whether boosts fire on their own on `autoInterval`, or only on demand.
    public var isAutoEnabled: Bool
    /// Gap between the end of one automatic boost and the start of the next.
    public var autoInterval: TimeInterval
    /// How long a single boost lasts, ramps included.
    ///
    /// Kept short deliberately. The acute alerting response to light arrives in
    /// the first minute or two; past that a tinted, brighter screen is mostly
    /// buying eye strain, and a boost that leaves someone with a headache gets
    /// the whole feature switched off.
    public var duration: TimeInterval
    /// Peak alpha of the cyan wash. Deliberately low — this sits on top of the
    /// user's actual work, so it has to stay readable.
    public var peakIntensity: CGFloat
    /// Hour (0-23) after which *automatic* boosts stop. Bright cyan late at
    /// night suppresses melatonin and costs the sleep that caused the
    /// drowsiness in the first place — but that's a reason to stop an
    /// unattended timer, not to overrule someone who deliberately pressed the
    /// button. Manual boosts ignore this entirely.
    public var cutoffHour: Int
    /// Hour (0-23) before which no boost may run.
    public var startHour: Int
    /// Window before `cutoffHour` over which strength fades to zero, so the
    /// feature tails off rather than snapping shut mid-evening.
    public var taper: TimeInterval
    /// Slow on purpose: a gradual rise slips under conscious notice, so the
    /// boost doesn't startle and doesn't demand a reaction.
    public var rampUp: TimeInterval
    /// Deliberately much shorter than `rampUp`.
    ///
    /// A slow dim is a dusk cue — light falling away over tens of seconds is
    /// what sunset looks like, and it reads as "wind down", quietly undoing the
    /// alerting the boost just bought. Ending quickly gives the brain a change
    /// to notice rather than a sunset to relax into.
    public var rampDown: TimeInterval
    /// Whether to also drive display brightness (needs private APIs; ignored
    /// on App Store builds, which fall back to the wash alone).
    public var boostBrightness: Bool

    public init(
        isEnabled: Bool = true,
        isAutoEnabled: Bool = true,
        autoInterval: TimeInterval = 15 * 60,
        duration: TimeInterval = 90,
        peakIntensity: CGFloat = 0.18,
        cutoffHour: Int = 20,
        startHour: Int = 5,
        taper: TimeInterval = 60 * 60,
        rampUp: TimeInterval = 30,
        rampDown: TimeInterval = 3,
        boostBrightness: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.isAutoEnabled = isAutoEnabled
        self.autoInterval = autoInterval
        self.duration = duration
        self.peakIntensity = peakIntensity
        self.cutoffHour = cutoffHour
        self.startHour = startHour
        self.taper = taper
        self.rampUp = rampUp
        self.rampDown = rampDown
        self.boostBrightness = boostBrightness
    }

    public static let `default` = LightBoostConfig()

    // Bounds for anything user-editable, applied on load as well as on set so a
    // hand-edited defaults plist can't produce a permanent full-screen wash.
    public static let autoIntervalRange: ClosedRange<TimeInterval> = 5 * 60 ... 120 * 60
    public static let durationRange: ClosedRange<TimeInterval> = 30 ... 600
    public static let peakIntensityRange: ClosedRange<CGFloat> = 0.02 ... 0.45

    /// Returns a copy with every user-editable field forced into range.
    public func clamped() -> LightBoostConfig {
        var copy = self
        copy.autoInterval = min(max(autoInterval, Self.autoIntervalRange.lowerBound), Self.autoIntervalRange.upperBound)
        copy.duration = min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        copy.peakIntensity = min(max(peakIntensity, Self.peakIntensityRange.lowerBound), Self.peakIntensityRange.upperBound)
        copy.cutoffHour = min(max(cutoffHour, 0), 23)
        copy.startHour = min(max(startHour, 0), 23)
        return copy
    }

    /// Ramps are clamped so a short duration can't produce a boost that ramps
    /// up and down at the same time.
    var effectiveRampUp: TimeInterval { min(rampUp, duration / 2) }
    var effectiveRampDown: TimeInterval { min(rampDown, duration / 2) }
}

// MARK: - Session

public struct LightBoostSession: Equatable, Sendable {
    public let startedAt: Date
    public let duration: TimeInterval
    public let trigger: LightBoostTrigger

    public init(startedAt: Date, duration: TimeInterval, trigger: LightBoostTrigger) {
        self.startedAt = startedAt
        self.duration = duration
        self.trigger = trigger
    }
}

// MARK: - Engine

/// Owns boost scheduling and the intensity curve. Drive it by calling `tick`
/// from an existing display-rate timer; it has no timer of its own.
public struct LightBoostEngine: Equatable, Sendable {
    public private(set) var session: LightBoostSession?
    /// Start of the current wait for the next automatic boost. Nil means the
    /// automatic clock isn't running (monitoring stopped, user away, screen
    /// locked), which is different from "running but not yet due".
    public private(set) var autoClockStartedAt: Date?
    public private(set) var isPaused: Bool = false

    public init() {}

    public var isBoosting: Bool { session != nil }

    // MARK: Time-of-day guardrail

    /// Scale in 0...1 applied to every boost, from the clock alone. Zero outside
    /// the allowed window; tapers to zero across `taper` before the cutoff.
    public static func daylightScale(
        at date: Date,
        config: LightBoostConfig,
        calendar: Calendar = .current
    ) -> CGFloat {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return 0 }

        let nowMinutes = Double(hour * 60 + minute)
        let startMinutes = Double(config.startHour * 60)
        let cutoffMinutes = Double(config.cutoffHour * 60)

        // A cutoff at or before the start hour leaves no valid window at all.
        // Refusing to run beats guessing what was meant.
        guard cutoffMinutes > startMinutes else { return 0 }
        guard nowMinutes >= startMinutes, nowMinutes < cutoffMinutes else { return 0 }

        let taperMinutes = max(config.taper / 60, 1)
        let taperStart = cutoffMinutes - taperMinutes
        guard nowMinutes > taperStart else { return 1 }

        return CGFloat((cutoffMinutes - nowMinutes) / taperMinutes)
    }

    /// Whether an *automatic* boost may run right now.
    public static func isWithinActiveWindow(
        at date: Date,
        config: LightBoostConfig,
        calendar: Calendar = .current
    ) -> Bool {
        config.isEnabled && daylightScale(at: date, config: config, calendar: calendar) > 0
    }

    /// Strength multiplier for a boost with this trigger.
    ///
    /// Manual boosts run at full strength whatever the hour. The user pressed
    /// the button; they know what time it is better than a schedule does, and
    /// a deliberately requested boost that arrives dimmed just reads as broken.
    /// Only the unattended timer is gated and tapered.
    public static func scale(
        for trigger: LightBoostTrigger,
        at date: Date,
        config: LightBoostConfig,
        calendar: Calendar = .current
    ) -> CGFloat {
        switch trigger {
        case .manual:
            return 1
        case .automatic:
            return daylightScale(at: date, config: config, calendar: calendar)
        }
    }

    /// True once automatic boosts have stopped for the day. Drives the gentle
    /// "it's late" hint on the menu item — a note, not a refusal.
    public static func isAfterCutoff(
        at date: Date,
        config: LightBoostConfig,
        calendar: Calendar = .current
    ) -> Bool {
        daylightScale(at: date, config: config, calendar: calendar) == 0
    }

    // MARK: Curve

    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Wash alpha for a boost `elapsed` seconds in, before the clock guardrail.
    static func rawIntensity(elapsed: TimeInterval, config: LightBoostConfig, duration: TimeInterval) -> CGFloat {
        guard elapsed >= 0, elapsed < duration, duration > 0 else { return 0 }

        let rampUp = config.effectiveRampUp
        let rampDown = config.effectiveRampDown

        if rampUp > 0, elapsed < rampUp {
            return config.peakIntensity * smoothstep(CGFloat(elapsed / rampUp))
        }
        let fadeStart = duration - rampDown
        if rampDown > 0, elapsed >= fadeStart {
            return config.peakIntensity * smoothstep(CGFloat((duration - elapsed) / rampDown))
        }
        return config.peakIntensity
    }

    public func phase(at date: Date, config: LightBoostConfig) -> LightBoostPhase {
        guard let session else { return .idle }
        let elapsed = date.timeIntervalSince(session.startedAt)
        guard elapsed >= 0, elapsed < session.duration else { return .idle }

        if elapsed < config.effectiveRampUp { return .ramping }
        if elapsed >= session.duration - config.effectiveRampDown { return .fading }
        return .holding
    }

    // MARK: Lifecycle

    /// Starts the automatic-boost clock. Called when monitoring begins and when
    /// the user comes back, so returning to the desk never fires a boost
    /// instantly — the wait always starts from now.
    public mutating func startAutoClock(at date: Date) {
        autoClockStartedAt = date
    }

    public mutating func stopAutoClock() {
        autoClockStartedAt = nil
    }

    /// Begins a boost. Returns false when the clock guardrail forbids it, the
    /// feature is off, or one is already running.
    @discardableResult
    public mutating func start(
        trigger: LightBoostTrigger,
        at date: Date,
        config: LightBoostConfig,
        calendar: Calendar = .current
    ) -> Bool {
        guard session == nil, !isPaused, config.isEnabled else { return false }
        if trigger == .automatic,
           !Self.isWithinActiveWindow(at: date, config: config, calendar: calendar) {
            return false
        }

        session = LightBoostSession(startedAt: date, duration: config.duration, trigger: trigger)
        return true
    }

    /// Ends any running boost and restarts the wait for the next automatic one.
    public mutating func stop(at date: Date) {
        guard session != nil else { return }
        session = nil
        if autoClockStartedAt != nil {
            autoClockStartedAt = date
        }
    }

    /// Suspends boosting entirely — used when the user is away or the screen is
    /// locked. There is no point lighting an empty chair, and a boost that ran
    /// while away would poison the recovery measurement.
    public mutating func setPaused(_ paused: Bool, at date: Date) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            session = nil
        } else if autoClockStartedAt != nil {
            autoClockStartedAt = date
        }
    }

    // MARK: Tick

    public struct TickResult: Equatable, Sendable {
        public let intensity: CGFloat
        /// True on the tick a boost begins, false on the tick it ends. Nil when
        /// nothing changed — lets the caller drive brightness and analytics off
        /// edges instead of polling.
        public let didStart: Bool
        public let didEnd: Bool
    }

    /// Advances the engine. Ends a finished boost, starts a due automatic one,
    /// and returns the wash alpha to render.
    @discardableResult
    public mutating func tick(
        at date: Date,
        config: LightBoostConfig,
        calendar: Calendar = .current
    ) -> TickResult {
        var didStart = false
        var didEnd = false

        // A running boost must still end cleanly when the feature is switched
        // off mid-session, so expiry is checked before the enabled guard.
        if let current = session {
            let elapsed = date.timeIntervalSince(current.startedAt)
            let expired = elapsed >= current.duration || elapsed < 0
            // Switching the feature off ends any boost, manual included. The
            // clock, though, only governs automatic ones: cutting a manual
            // boost off mid-fade would overrule a choice the user just made.
            let forbidden = !config.isEnabled
                || (current.trigger == .automatic
                    && !Self.isWithinActiveWindow(at: date, config: config, calendar: calendar))
            if expired || forbidden || isPaused {
                session = nil
                didEnd = true
                if autoClockStartedAt != nil {
                    autoClockStartedAt = date
                }
            }
        }

        guard config.isEnabled, !isPaused else {
            return TickResult(intensity: 0, didStart: false, didEnd: didEnd)
        }

        if session == nil,
           config.isAutoEnabled,
           let clockStart = autoClockStartedAt,
           date.timeIntervalSince(clockStart) >= config.autoInterval {
            didStart = start(trigger: .automatic, at: date, config: config, calendar: calendar)
            // Restart the wait even when the guardrail blocked the boost,
            // otherwise every tick after the cutoff retries and the first
            // moment of the next morning fires immediately.
            if !didStart {
                autoClockStartedAt = date
            }
        }

        guard let current = session else {
            return TickResult(intensity: 0, didStart: didStart, didEnd: didEnd)
        }

        let raw = Self.rawIntensity(
            elapsed: date.timeIntervalSince(current.startedAt),
            config: config,
            duration: current.duration
        )
        let scale = Self.scale(for: current.trigger, at: date, config: config, calendar: calendar)

        return TickResult(intensity: raw * scale, didStart: didStart, didEnd: didEnd)
    }
}
