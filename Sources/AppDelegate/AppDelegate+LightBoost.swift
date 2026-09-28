import AppKit
import os.log

private let log = OSLog(subsystem: "com.thelazydeveloper.dorso", category: "LightBoost")

extension AppDelegate {

    // MARK: - Setup

    func setupLightBoostOverlay() {
        lightBoostOverlayManager.useFullScreenOverlay = useFullScreenOverlay
        lightBoostOverlayManager.setupOverlayWindows()
    }

    func rebuildLightBoostOverlay() {
        lightBoostOverlayManager.useFullScreenOverlay = useFullScreenOverlay
        lightBoostOverlayManager.rebuildOverlayWindows()
    }

    // MARK: - Suspension

    /// True when nobody is looking at the screen. Lighting an empty chair does
    /// nothing, and a boost that burned through a lunch break would also make
    /// the next automatic one land at the wrong time.
    var lightBoostShouldSuspend: Bool {
        if case .paused(.screenLocked) = state { return true }
        return isCurrentlyAway
    }

    /// Automatic boosts only run while we can actually see the user at their
    /// desk. Manual ones don't need this — pressing the button is its own proof
    /// of presence.
    private var lightBoostAutoClockShouldRun: Bool {
        state == .monitoring && lightBoostConfig.isEnabled && lightBoostConfig.isAutoEnabled
    }

    // MARK: - Tick

    /// Advances the boost and paints it. Driven from the existing display-rate
    /// timer in `applicationDidFinishLaunching` alongside `updateBlur`, so the
    /// feature adds no timer of its own.
    func tickLightBoost(now: Date = Date()) {
        lightBoostEngine.setPaused(lightBoostShouldSuspend, at: now)

        if lightBoostAutoClockShouldRun {
            if lightBoostEngine.autoClockStartedAt == nil {
                lightBoostEngine.startAutoClock(at: now)
            }
        } else {
            lightBoostEngine.stopAutoClock()
        }

        let result = lightBoostEngine.tick(at: now, config: lightBoostConfig)

        // Availability also changes with the clock alone (crossing the evening
        // cutoff), not just on start/end edges. The menu update early-outs when
        // nothing changed, so running it every tick is cheap.
        updateLightBoostMenuItem()

        lightBoostOverlayManager.targetIntensity = result.intensity
        // A posture warning carries information; the wash does not. Fade the
        // wash back while one is on screen so the warning colour stays true.
        lightBoostOverlayManager.dimFactor = 1.0 - min(max(postureWarningIntensity, 0), 1) * 0.7
        lightBoostOverlayManager.updateWash()

        applyLightBoostBrightness(for: result.intensity)
    }

    /// Tracks display brightness to the wash ramp so light and colour rise and
    /// fall together.
    private func applyLightBoostBrightness(for intensity: CGFloat) {
        guard lightBoostConfig.boostBrightness, displayBrightness.isSupported else {
            if displayBrightness.isBoosting {
                displayBrightness.restore()
            }
            return
        }

        let peak = lightBoostConfig.peakIntensity
        let fraction = peak > 0 ? min(max(intensity / peak, 0), 1) : 0
        displayBrightness.apply(fraction: fraction)
    }

    // MARK: - Manual Control ("Espresso")

    /// Menu action. Starts a boost on demand, or cancels the running one so a
    /// single item can do both without the user hunting for a second command.
    func toggleManualLightBoost() {
        let now = Date()

        if lightBoostEngine.isBoosting {
            lightBoostEngine.stop(at: now)
            finishLightBoostVisuals()
            updateLightBoostMenuItem()
            return
        }

        guard lightBoostConfig.isEnabled else { return }

        // Manual boosts ignore the evening cutoff and run at full strength, so
        // the only thing that can refuse one now is the user being away or the
        // screen being locked — neither of which they can be while clicking.
        let started = lightBoostEngine.start(trigger: .manual, at: now, config: lightBoostConfig)
        if !started {
            os_log(.info, log: log, "Manual light boost refused (engine suspended)")
        }
        updateLightBoostMenuItem()
    }

    /// Clears the wash and hands brightness back immediately.
    func finishLightBoostVisuals() {
        lightBoostOverlayManager.targetIntensity = 0
        lightBoostOverlayManager.updateWash()
        displayBrightness.restore()
    }

    /// Cancels any boost and restores brightness. Called on quit and whenever
    /// the feature is switched off — brightness is the user's setting, and we
    /// must never leave it where we put it.
    func cancelLightBoost() {
        lightBoostEngine.stop(at: Date())
        lightBoostEngine.stopAutoClock()
        finishLightBoostVisuals()
        updateLightBoostMenuItem()
    }

    // MARK: - Settings

    /// Applies edited settings. Stopping a running boost when the feature is
    /// turned off (or the clock window closes) keeps Settings honest: the
    /// screen matches the switch the moment it flips.
    func applyLightBoostConfig(_ config: LightBoostConfig) {
        lightBoostConfig = config.clamped()

        if !lightBoostConfig.isEnabled {
            cancelLightBoost()
        }
        if !lightBoostConfig.boostBrightness, displayBrightness.isBoosting {
            displayBrightness.restore()
        }
        saveSettings()
        updateLightBoostMenuItem()
    }

    // MARK: - Menu

    func updateLightBoostMenuItem() {
        menuBarManager.updateLightBoost(
            isBoosting: lightBoostEngine.isBoosting,
            isEnabled: lightBoostConfig.isEnabled,
            isLate: LightBoostEngine.isAfterCutoff(at: Date(), config: lightBoostConfig)
        )
    }
}
