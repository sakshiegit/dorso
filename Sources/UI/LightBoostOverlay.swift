import AppKit

// MARK: - Light Wash View

/// A translucent cyan field drawn over the whole screen.
///
/// The colour is the brand cyan, which happens to sit close to 480nm — the band
/// the retina's non-visual cells are tuned to, and the one that actually drives
/// alertness. Convenient, since it means the treatment looks like the app.
///
/// A flat fill reads as a colour filter laid over the work; a gentle vertical
/// gradient (stronger at the top, where a window's chrome is) reads more like
/// light falling on the screen. Alpha stays low so text underneath stays sharp.
final class LightWashOverlayView: NSView {
    private var gradientLayer: CAGradientLayer!
    private var lastDrawnIntensity: CGFloat = -1

    /// 0...1 wash strength. Multiplied into the layer's alpha.
    var intensity: CGFloat = 0.0 {
        didSet { updateLayerIfNeeded() }
    }

    var washColor: NSColor = LightBoostDefaults.color {
        didSet {
            lastDrawnIntensity = -1
            updateLayerIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        gradientLayer = CAGradientLayer()
        gradientLayer.frame = bounds
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        layer?.addSublayer(gradientLayer)
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        lastDrawnIntensity = -1
        updateLayerIfNeeded()
    }

    private func updateLayerIfNeeded() {
        let threshold: CGFloat = 0.002
        guard abs(intensity - lastDrawnIntensity) > threshold else { return }
        lastDrawnIntensity = intensity

        // Layer colour changes animate implicitly by default, which fights the
        // engine's own ramp and smears every step into a half-second lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [
            washColor.withAlphaComponent(intensity).cgColor,
            washColor.withAlphaComponent(intensity * 0.72).cgColor
        ]
        CATransaction.commit()
    }
}

// MARK: - Defaults

enum LightBoostDefaults {
    /// Brand cyan (#4fd1c5), which sits near the 480nm alerting band.
    static let color = NSColor(red: 0.31, green: 0.82, blue: 0.77, alpha: 1.0)
}

extension NSWindow.Level {
    /// Just below `.aboveFullscreen`, so the light wash never covers a posture
    /// warning or the privacy blur — those carry information, this does not.
    static let lightBoost = NSWindow.Level(rawValue: 99)
}

// MARK: - Manager

/// Owns one click-through wash window per screen. Mirrors
/// `WarningOverlayManager` so display hot-plug, Spaces behaviour and teardown
/// all work the same way they already do for warnings.
@MainActor
final class LightBoostOverlayManager {
    private(set) var windows: [NSWindow] = []
    private(set) var overlayViews: [LightWashOverlayView] = []

    /// Wash strength the engine last asked for, before any dimming.
    var targetIntensity: CGFloat = 0.0
    /// Scales `targetIntensity` down while a posture warning is on screen, so
    /// the warning colour stays readable through the wash.
    var dimFactor: CGFloat = 1.0
    var washColor: NSColor = LightBoostDefaults.color
    var useFullScreenOverlay = false

    private(set) var appliedIntensity: CGFloat = -1

    var hasWindows: Bool { !windows.isEmpty }

    func setupOverlayWindows() {
        guard windows.isEmpty else { return }

        for screen in NSScreen.screens {
            let frame = screen.overlayFrame(fullScreen: useFullScreenOverlay)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .lightBoost
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let view = LightWashOverlayView(frame: NSRect(origin: .zero, size: frame.size))
            view.washColor = washColor
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
            overlayViews.append(view)
        }

        // Fresh views start at zero; reset the applied cache so the next
        // update actually repaints instead of matching a stale value.
        appliedIntensity = -1
    }

    func teardownOverlayWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        overlayViews.removeAll()
        appliedIntensity = -1
    }

    func rebuildOverlayWindows() {
        teardownOverlayWindows()
        setupOverlayWindows()
    }

    /// Pushes the current intensity into every view. Cheap to call every frame:
    /// it early-outs when nothing changed, and the views do the same.
    func updateWash() {
        let resolved = max(0, min(targetIntensity * dimFactor, 1))
        guard abs(resolved - appliedIntensity) > 0.002 else { return }
        appliedIntensity = resolved

        for view in overlayViews {
            view.intensity = resolved
        }
    }

    func updateColor(_ color: NSColor) {
        washColor = color
        for view in overlayViews {
            view.washColor = color
        }
    }
}
