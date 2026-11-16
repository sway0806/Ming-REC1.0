import AppKit

/// Helpers shown around a take that must never end up in the file. Both are
/// windows of 小名 itself, and the capture filter excludes every 小名 window
/// except the camera PIP and the effects overlay, so they stay out of the video.
@MainActor
enum RecordingChromeGeometry {
    /// `region` is in top-left display points (same space as `AppModel.region`).
    static func area(on screen: NSScreen, region: CGRect?) -> NSRect {
        let frame = screen.frame
        guard let region else { return frame }
        return NSRect(
            x: frame.minX + region.minX,
            y: frame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )
    }

    static func makePanel(frame: NSRect, title: String) -> NSPanel {
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
        panel.title = title
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

/// Thin frame around what is being recorded (full display or region).
@MainActor
final class RecordingBorder {
    private var window: NSPanel?
    private var frameLayer: CAShapeLayer?

    var isVisible: Bool { window?.isVisible == true }
    var windowFrame: NSRect? { window?.frame }

    func show(on screen: NSScreen, region: CGRect?) {
        hide()
        let area = RecordingChromeGeometry.area(on: screen, region: region)
        // Draw just outside a region so the line is not inside the picture;
        // for a full display draw on the inner edge (there is no outside).
        let outset: CGFloat = region == nil ? 0 : 3
        let frame = area.insetBy(dx: -outset, dy: -outset)
        let panel = RecordingChromeGeometry.makePanel(frame: frame, title: "小名录制边框")
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let layer = CAShapeLayer()
        layer.frame = view.bounds
        layer.contentsScale = screen.backingScaleFactor
        layer.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        layer.fillColor = nil
        layer.strokeColor = EffectsOverlay.orange.withAlphaComponent(0.9).cgColor
        layer.lineWidth = 2
        view.layer?.addSublayer(layer)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        window = panel
        frameLayer = layer
    }

    /// Dashed and dimmer while paused, solid while recording.
    func setPaused(_ paused: Bool) {
        frameLayer?.lineDashPattern = paused ? [8, 6] : nil
        frameLayer?.opacity = paused ? 0.6 : 1
    }

    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        frameLayer = nil
    }
}

/// Big 3-2-1 in the middle of the recorded area before a take starts.
@MainActor
final class CountdownOverlay {
    private var window: NSPanel?
    private var label: NSTextField?

    var isVisible: Bool { window?.isVisible == true }
    var shownValue: String? { label?.stringValue }

    func show(_ value: Int, on screen: NSScreen, region: CGRect?) {
        if window == nil {
            let area = RecordingChromeGeometry.area(on: screen, region: region)
            let side: CGFloat = 180
            let frame = NSRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
            let panel = RecordingChromeGeometry.makePanel(frame: frame, title: "小名倒计时")
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
            view.layer?.cornerRadius = side / 2
            view.layer?.borderWidth = 2
            view.layer?.borderColor = EffectsOverlay.orange.withAlphaComponent(0.85).cgColor
            let text = NSTextField(labelWithString: "")
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold)
            text.textColor = .white
            text.alignment = .center
            text.frame = NSRect(x: 0, y: (side - 116) / 2, width: side, height: 116)
            view.addSubview(text)
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            window = panel
            label = text
        }
        label?.stringValue = "\(value)"
    }

    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        label = nil
    }
}
