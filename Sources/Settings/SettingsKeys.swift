import Foundation

// MARK: - Settings Keys

enum SettingsKeys {
    static let intensity = "intensity"
    static let deadZone = "deadZone"
    static let useCompatibilityMode = "useCompatibilityMode"
    static let appAppearance = "appAppearance"
    static let blurWhenAway = "blurWhenAway"
    static let showInDock = "showInDock"
    static let pauseOnTheGo = "pauseOnTheGo"
    static let pauseOnBattery = "pauseOnBattery"
    static let useFullScreenOverlay = "useFullScreenOverlay"
    static let lastCameraID = "lastCameraID"
    static let profiles = "profiles"
    static let settingsProfiles = "settingsProfiles"
    static let currentSettingsProfileID = "currentSettingsProfileID"
    static let warningMode = "warningMode"
    static let warningColor = "warningColor"
    static let warningOnsetDelay = "blurOnsetDelay"  // Keep key for backward compatibility
    static let toggleShortcutEnabled = "toggleShortcutEnabled"
    static let toggleShortcutKeyCode = "toggleShortcutKeyCode"
    static let toggleShortcutModifiers = "toggleShortcutModifiers"
    static let detectionMode = "detectionMode"
    static let trackingSource = "trackingSource"
    static let trackingMode = "trackingMode"
    static let preferredSource = "preferredSource"
    static let autoReturnEnabled = "autoReturnEnabled"
    static let airPodsCalibration = "airPodsCalibration"

    // Light boost ("Espresso")
    static let lightBoostEnabled = "lightBoostEnabled"
    static let lightBoostAutoEnabled = "lightBoostAutoEnabled"
    static let lightBoostInterval = "lightBoostInterval"
    static let lightBoostDuration = "lightBoostDuration"
    static let lightBoostIntensity = "lightBoostIntensity"
    static let lightBoostCutoffHour = "lightBoostCutoffHour"
    static let lightBoostBrightness = "lightBoostBrightness"

    // Legacy keys (migrated on load)
    static let legacyAirPodsProfile = "airPodsProfile"
}
