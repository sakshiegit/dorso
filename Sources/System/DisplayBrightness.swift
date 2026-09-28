import AppKit
import CoreGraphics
import os.log

private let log = OSLog(subsystem: "com.thelazydeveloper.dorso", category: "DisplayBrightness")

// MARK: - Private API Loading
//
// There is no public API for setting display brightness on modern macOS, so the
// light boost drives DisplayServices directly — the same dlopen/dlsym pattern
// `BlurOverlay.swift` already uses for the CoreGraphics blur. App Store builds
// compile this out and fall back to the cyan wash alone, which still works,
// just less strongly.

#if !APP_STORE
private let displayServicesHandle: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    RTLD_LAZY
)

private let displayServicesGetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let handle = displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()

private let displayServicesSetBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
    guard let handle = displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
}()
#endif

// MARK: - Display Brightness

/// Temporarily raises display brightness for the duration of a light boost, and
/// puts it back afterwards.
///
/// Bright light is the strongest part of the intervention, so this matters — but
/// it is also the part that touches state the user owns. Every path out of a
/// boost (finish, cancel, screen lock, quit) must restore, or the app leaves
/// someone's laptop pinned at full brightness.
@MainActor
final class DisplayBrightness {

    /// Absolute brightness a boost drives toward, rather than a fraction of the
    /// headroom above wherever the user had it.
    ///
    /// A relative lift is self-defeating: the dimmer the screen, the smaller
    /// the boost, so the times you most need light are the times you get least.
    /// A fixed target gives the same end state whatever the baseline, which is
    /// what "boost" should mean. 80% is short of the full-blast 100% that made
    /// this glare, while still being a real lift from a typical working level.
    static let boostTargetLevel: Float = 0.8

    /// Brightness levels captured when the current boost started, keyed by
    /// display. Non-empty means we owe the user a restore.
    private var originalLevels: [CGDirectDisplayID: Float] = [:]
    private var lastAppliedFraction: CGFloat = 0

    /// False on App Store builds and anywhere the private symbols fail to
    /// resolve, so callers can fall back to a stronger wash.
    var isSupported: Bool {
        #if APP_STORE
        return false
        #else
        return displayServicesGetBrightness != nil && displayServicesSetBrightness != nil
        #endif
    }

    var isBoosting: Bool { !originalLevels.isEmpty }

    /// Blends every display from its captured brightness toward
    /// `boostTargetLevel`. `fraction` 0 restores and releases; 1 is the target.
    ///
    /// A display already brighter than the target is left alone: dimming the
    /// screen is the opposite of a boost, and nobody would read it as one.
    ///
    /// Driven per frame from the boost ramp, so brightness rises and falls with
    /// the wash rather than snapping.
    func apply(fraction: CGFloat) {
        guard isSupported else { return }

        let clamped = max(0, min(fraction, 1))

        guard clamped > 0 else {
            restore()
            return
        }

        // Capture once, at the start of a boost. Re-capturing mid-boost would
        // save our own raised value as the "original" and strand the user at
        // full brightness.
        if originalLevels.isEmpty {
            captureCurrentLevels()
            guard !originalLevels.isEmpty else { return }
        }

        // Skip sub-perceptual steps; these are IOKit round-trips per display
        // and this runs at display rate.
        guard abs(clamped - lastAppliedFraction) > 0.01 else { return }
        lastAppliedFraction = clamped

        for (displayID, original) in originalLevels {
            // Never below the captured level -- a screen already past the
            // target simply holds rather than being pulled down to it.
            let destination = max(original, Self.boostTargetLevel)
            let target = original + (destination - original) * Float(clamped)
            setBrightness(target, for: displayID)
        }
    }

    /// Puts every display back to where it was and forgets the capture.
    /// Safe to call when no boost is running.
    func restore() {
        guard !originalLevels.isEmpty else {
            lastAppliedFraction = 0
            return
        }

        for (displayID, original) in originalLevels {
            setBrightness(original, for: displayID)
        }
        originalLevels.removeAll()
        lastAppliedFraction = 0
    }

    // MARK: - Private

    private func captureCurrentLevels() {
        #if !APP_STORE
        guard let getBrightness = displayServicesGetBrightness else { return }

        for displayID in Self.activeDisplayIDs() {
            var level: Float = 0
            guard getBrightness(displayID, &level) == 0 else {
                os_log(.info, log: log, "Could not read brightness for display %{public}u", displayID)
                continue
            }
            originalLevels[displayID] = max(0, min(level, 1))
        }
        #endif
    }

    private func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        #if !APP_STORE
        guard let setBrightness = displayServicesSetBrightness else { return }
        _ = setBrightness(displayID, max(0, min(value, 1)))
        #endif
    }

    /// Display IDs backing the current screens. Built from `NSScreen` rather
    /// than `CGGetActiveDisplayList` so a display unplugged mid-boost simply
    /// drops out instead of taking a stale ID with it.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
    }
}
