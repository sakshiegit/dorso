import AppKit

// MARK: - Menu Bar Manager

@MainActor
final class MenuBarManager {
    private(set) var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var enabledMenuItem: NSMenuItem!
    private var recalibrateMenuItem: NSMenuItem!
    private var espressoMenuItem: NSMenuItem!

    private struct LightBoostMenuState: Equatable {
        let isBoosting: Bool
        let isEnabled: Bool
        let isLate: Bool
    }
    private var lastLightBoostState: LightBoostMenuState?

    // Callbacks
    var onToggleEnabled: (() -> Void)?
    var onRecalibrate: (() -> Void)?
    var onToggleLightBoost: (() -> Void)?
    var onShowAnalytics: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSupport: (() -> Void)?
    var onQuit: (() -> Void)?
    #if !APP_STORE
    var onCheckForUpdates: (() -> Void)?
    #endif

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = MenuBarIcon.good.image
        }

        statusItem.menu = makeMenu()
    }

    /// Builds the status menu and retains its mutable items. Separate from
    /// `setup()` because NSMenu needs no window server connection, so
    /// headless tests can build the menu and exercise the update methods.
    @discardableResult
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Without this, AppKit re-enables every item whose target implements
        // its action just before the menu draws, overriding the isEnabled we
        // set in the update methods below. A disabled item would still render
        // -- and behave -- as if it were live.
        menu.autoenablesItems = false

        // Status
        statusMenuItem = NSMenuItem(title: L("menu.status.starting"), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Enabled toggle
        enabledMenuItem = NSMenuItem(title: L("menu.enable"), action: #selector(handleToggleEnabled), keyEquivalent: "")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        menu.addItem(enabledMenuItem)

        // Recalibrate
        recalibrateMenuItem = NSMenuItem(title: L("menu.recalibrate"), action: #selector(handleRecalibrate), keyEquivalent: "r")
        recalibrateMenuItem.target = self
        menu.addItem(recalibrateMenuItem)

        // Espresso: an on-demand light boost. Sits with the other "do
        // something now" actions because the user reaches for it exactly when
        // they feel themselves fading — it must be two clicks, not five.
        espressoMenuItem = NSMenuItem(title: L("menu.espresso"), action: #selector(handleToggleLightBoost), keyEquivalent: "e")
        espressoMenuItem.target = self
        espressoMenuItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: L("menu.espresso"))
        menu.addItem(espressoMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Support
        let supportItem = NSMenuItem(title: L("menu.support"), action: #selector(handleOpenSupport), keyEquivalent: "")
        supportItem.target = self
        supportItem.image = NSImage(systemSymbolName: "heart", accessibilityDescription: L("menu.support"))
        menu.addItem(supportItem)

        // Analytics
        let statsItem = NSMenuItem(title: L("menu.analytics"), action: #selector(handleShowAnalytics), keyEquivalent: "a")
        statsItem.target = self
        statsItem.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: L("menu.analytics"))
        menu.addItem(statsItem)

        // Settings
        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("menu.settings"))
        menu.addItem(settingsItem)

        #if !APP_STORE
        // Check for Updates (direct-distribution builds only; the App Store
        // delivers updates for Mac App Store installs)
        let updatesItem = NSMenuItem(title: L("menu.checkForUpdates"), action: #selector(handleCheckForUpdates), keyEquivalent: "")
        updatesItem.target = self
        updatesItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: L("menu.checkForUpdates"))
        menu.addItem(updatesItem)
        #endif

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Updates

    private var isSetUp: Bool { statusMenuItem != nil }

    func updateStatus(text: String, icon: MenuBarIcon) {
        guard isSetUp else { return }
        statusMenuItem.title = text
        statusItem?.button?.image = icon.image
    }

    func updateEnabledState(_ enabled: Bool) {
        guard isSetUp else { return }
        enabledMenuItem.state = enabled ? .on : .off
    }

    func updateRecalibrateEnabled(_ enabled: Bool) {
        guard isSetUp else { return }
        recalibrateMenuItem.isEnabled = enabled
    }

    /// Flips the item between start and stop, and adds a quiet "it's late" note
    /// once the automatic schedule has stopped for the day.
    ///
    /// The note is a hint, not a refusal: the button still works at full
    /// strength after the cutoff. It's there so a late boost is a decision
    /// rather than an accident.
    ///
    /// Called every tick, so it early-outs unless something actually changed.
    func updateLightBoost(isBoosting: Bool, isEnabled: Bool, isLate: Bool) {
        guard isSetUp else { return }

        let state = LightBoostMenuState(isBoosting: isBoosting, isEnabled: isEnabled, isLate: isLate)
        guard state != lastLightBoostState else { return }
        lastLightBoostState = state

        if isBoosting {
            espressoMenuItem.title = L("menu.espresso.stop")
        } else {
            espressoMenuItem.title = isLate ? L("menu.espresso.late") : L("menu.espresso")
        }
        espressoMenuItem.image = NSImage(
            systemSymbolName: isBoosting ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: espressoMenuItem.title
        )
        espressoMenuItem.isEnabled = isEnabled || isBoosting
    }

    func updateShortcut(enabled: Bool, shortcut: KeyboardShortcut) {
        guard isSetUp else { return }
        if enabled {
            enabledMenuItem.keyEquivalent = shortcut.keyCharacter
            enabledMenuItem.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            enabledMenuItem.keyEquivalent = ""
            enabledMenuItem.keyEquivalentModifierMask = []
        }
    }

    // MARK: - Actions

    @objc private func handleToggleEnabled() {
        onToggleEnabled?()
    }

    @objc private func handleRecalibrate() {
        onRecalibrate?()
    }

    @objc private func handleToggleLightBoost() {
        onToggleLightBoost?()
    }

    @objc private func handleShowAnalytics() {
        onShowAnalytics?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleOpenSupport() {
        onOpenSupport?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }

    #if !APP_STORE
    @objc private func handleCheckForUpdates() {
        onCheckForUpdates?()
    }
    #endif
}
