import AppKit
import QuartzCore

/// Corner for the text watermark.
enum WatermarkCorner: String, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var title: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        }
    }
}

struct EffectsConfig: Equatable {
    var cursorHighlight: Bool
    var clickRipples: Bool
    var watermark: Bool
    var watermarkText: String
    var watermarkCorner: WatermarkCorner

    var isActive: Bool { cursorHighlight || clickRipples || watermark }

    static let defaultWatermarkText = "小名"

    var resolvedWatermarkText: String {
        let trimmed = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultWatermarkText : trimmed
    }
}

/// Transparent, click-through window that sits over the recorded display while
/// a take runs. It draws the cursor halo, click ripples and the watermark with
/// Core Animation, so what the user sees is exactly what gets recorded:
/// the window keeps the default `sharingType` and is passed to ScreenCaptureKit
/// in `exceptingWindows`, same as the camera PIP.
///
/// Cost model: no timers, no display link. The halo moves only when the system
/// delivers a mouse event (NSEvent monitors), with implicit animations off.
/// Ripples are one-shot CA animations rendered by the render server. The
/// watermark is a static layer, so it never wakes the capture pipeline.
@MainActor
final class EffectsOverlay {
    private var window: NSPanel?
    private var rootLayer: CALayer?
    private var haloLayer: CALayer?
    private var monitors: [Any] = []
    private var config: EffectsConfig?
    private var scale: CGFloat = 2

    var windowID: Int? { window?.windowNumber }
    var isShowing: Bool { window != nil }

    static let orange = NSColor(srgbRed: 252 / 255, green: 107 / 255, blue: 16 / 255, alpha: 1)
    /// 汝窑天青, deepened so a right-click ring still reads on white pages.
    static let celadon = NSColor(srgbRed: 64 / 255, green: 138 / 255, blue: 150 / 255, alpha: 1)

    /// - Parameters:
    ///   - screen: display being recorded.
    ///   - region: crop in top-left display points (same space as `AppModel.region`), or nil for full screen.
    func show(on screen: NSScreen, region: CGRect?, config: EffectsConfig) {
        hide()
        guard config.isActive else { return }
        self.config = config
        scale = screen.backingScaleFactor

        let frame = screen.frame
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.title = "小名效果层"
        // Above normal and floating windows (camera PIP), below the screen saver.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Leave sharingType at the default so ScreenCaptureKit records this window.

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let root = CALayer()
        root.frame = view.bounds
        root.contentsScale = scale
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        panel.setFrame(frame, display: false)

        rootLayer = root
        window = panel

        if config.watermark {
            addWatermark(config: config, viewSize: frame.size, region: region)
        }
        if config.cursorHighlight {
            let halo = makeHalo()
            root.addSublayer(halo)
            haloLayer = halo
            pointerMoved(to: NSEvent.mouseLocation)
        }
        installMonitors(config: config)
        panel.orderFrontRegardless()
    }

    func hide() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        haloLayer = nil
        rootLayer = nil
        config = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    // MARK: - Events

    private func installMonitors(config: EffectsConfig) {
        var mask: NSEvent.EventTypeMask = []
        if config.cursorHighlight {
            mask.formUnion([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
        }
        if config.clickRipples || config.cursorHighlight {
            mask.formUnion([.leftMouseDown, .rightMouseDown])
        }
        guard !mask.isEmpty else { return }
        // Mouse events need no Accessibility / Input Monitoring permission
        // (only key events do). Global = other apps, local = 小名's own windows.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(type, at: location) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(type, at: location) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ type: NSEvent.EventType, at location: NSPoint) {
        switch type {
        case .leftMouseDown:
            pointerMoved(to: location)
            if config?.clickRipples == true { ripple(at: location, secondary: false) }
        case .rightMouseDown:
            pointerMoved(to: location)
            if config?.clickRipples == true { ripple(at: location, secondary: true) }
        default:
            pointerMoved(to: location)
        }
    }

    /// Global (bottom-left) screen point.
    func pointerMoved(to location: NSPoint) {
        guard let window, let haloLayer else { return }
        let frame = window.frame
        let inside = frame.insetBy(dx: -40, dy: -40).contains(location)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.isHidden = !inside
        if inside {
            haloLayer.position = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        }
        CATransaction.commit()
    }

    /// Public so the self-test can drive a ripple without posting real clicks.
    func ripple(at location: NSPoint, secondary: Bool) {
        guard let window, let rootLayer else { return }
        let frame = window.frame
        guard frame.contains(location) else { return }
        let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        let diameter: CGFloat = secondary ? 56 : 60
        let color = secondary ? Self.celadon : Self.orange

        let ring = CAShapeLayer()
        ring.contentsScale = scale
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.fillColor = color.withAlphaComponent(secondary ? 0.10 : 0.16).cgColor
        ring.strokeColor = color.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 3
        if secondary {
            ring.lineDashPattern = [7, 5]
        }
        ring.opacity = 0

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.25
        grow.toValue = 1.0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak ring] in
            ring?.removeFromSuperlayer()
        }
        if let haloLayer {
            rootLayer.insertSublayer(ring, below: haloLayer)
        } else {
            rootLayer.addSublayer(ring)
        }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    // MARK: - Layers

    private func makeHalo() -> CALayer {
        let diameter: CGFloat = 76
        let halo = CALayer()
        halo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        halo.contentsScale = scale

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = halo.bounds
        glow.contentsScale = scale
        glow.colors = [
            Self.orange.withAlphaComponent(0.34).cgColor,
            Self.orange.withAlphaComponent(0.22).cgColor,
            Self.orange.withAlphaComponent(0.0).cgColor
        ]
        glow.locations = [0, 0.55, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        halo.addSublayer(glow)

        let rimInset: CGFloat = 16
        let rim = CAShapeLayer()
        rim.frame = halo.bounds
        rim.contentsScale = scale
        rim.path = CGPath(ellipseIn: halo.bounds.insetBy(dx: rimInset, dy: rimInset), transform: nil)
        rim.fillColor = NSColor.clear.cgColor
        rim.strokeColor = Self.orange.withAlphaComponent(0.55).cgColor
        rim.lineWidth = 1.5
        halo.addSublayer(rim)
        return halo
    }

    private func addWatermark(config: EffectsConfig, viewSize: CGSize, region: CGRect?) {
        guard let rootLayer else { return }
        // Recorded area in this view's bottom-left coordinates.
        var area = CGRect(origin: .zero, size: viewSize)
        if let region {
            let clipped = region.intersection(CGRect(origin: .zero, size: viewSize))
            if clipped.width >= 2, clipped.height >= 2 {
                area = CGRect(x: clipped.minX, y: viewSize.height - clipped.maxY, width: clipped.width, height: clipped.height)
            }
        }
        let shortSide = min(area.width, area.height)
        let fontSize = max(13, min(34, (shortSide * 0.032).rounded()))
        let margin = max(12, (shortSide * 0.028).rounded())

        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = NSAttributedString(string: config.resolvedWatermarkText, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.08
        ])
        let textSize = text.size()
        let padX = (fontSize * 0.55).rounded()
        let padY = (fontSize * 0.22).rounded()
        let textWidth = ceil(min(textSize.width + 2, area.width - margin * 2 - padX * 2))
        let textHeight = ceil(textSize.height)
        guard textWidth > 4 else { return }
        let width = textWidth + padX * 2
        let height = textHeight + padY * 2

        let x: CGFloat
        let y: CGFloat
        switch config.watermarkCorner {
        case .topLeft:
            x = area.minX + margin; y = area.maxY - margin - height
        case .topRight:
            x = area.maxX - margin - width; y = area.maxY - margin - height
        case .bottomLeft:
            x = area.minX + margin; y = area.minY + margin
        case .bottomRight:
            x = area.maxX - margin - width; y = area.minY + margin
        }

        // Soft ink pill so white text stays readable on white pages too.
        let pill = CALayer()
        pill.contentsScale = scale
        pill.frame = CGRect(x: x, y: y, width: width, height: height)
        pill.backgroundColor = NSColor(srgbRed: 40 / 255, green: 28 / 255, blue: 18 / 255, alpha: 0.30).cgColor
        pill.cornerRadius = height / 2
        // Moderate: present but not shouting.
        pill.opacity = 0.78

        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.frame = CGRect(x: padX, y: padY, width: textWidth, height: textHeight)
        layer.string = text
        layer.truncationMode = .end
        layer.isWrapped = false
        layer.alignmentMode = .center
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: -1)
        pill.addSublayer(layer)
        rootLayer.addSublayer(pill)
    }
}
