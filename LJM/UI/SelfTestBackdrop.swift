import AppKit

/// Self-test only (--self-test-static): an opaque, completely still sheet over
/// the main display so a take has no moving pixels except the pointer. It is
/// passed to ScreenCaptureKit in `exceptingWindows` like the effects layer.
/// Also keeps whatever else is on the user's screen out of test footage.
@MainActor
final class SelfTestBackdrop {
    private var window: NSPanel?

    var windowID: Int? { window?.windowNumber }

    func show(on screen: NSScreen) {
        hide()
        let frame = screen.frame
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.backgroundColor = NSColor(srgbRed: 244 / 255, green: 239 / 255, blue: 230 / 255, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.title = "小名静止自测"
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = StillPatternView(frame: NSRect(origin: .zero, size: frame.size))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

private final class StillPatternView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 244 / 255, green: 239 / 255, blue: 230 / 255, alpha: 1).setFill()
        bounds.fill()
        let grid = NSBezierPath()
        let step: CGFloat = 60
        var x: CGFloat = 0
        while x <= bounds.width {
            grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: bounds.height)); x += step
        }
        var y: CGFloat = 0
        while y <= bounds.height {
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: y)); y += step
        }
        NSColor(srgbRed: 108 / 255, green: 106 / 255, blue: 98 / 255, alpha: 0.18).setStroke()
        grid.lineWidth = 1
        grid.stroke()
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 252 / 255, green: 107 / 255, blue: 16 / 255, alpha: 1)
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 97 / 255, green: 51 / 255, blue: 7 / 255, alpha: 1)
        ]
        ("小名 · 静止画面自测" as NSString).draw(at: NSPoint(x: bounds.width * 0.08, y: bounds.height * 0.8), withAttributes: title)
        let lines = [
            "左侧标记 A：自动缩放第一次点击附近",
            "右侧标记 B：第二次点击附近",
            "整块画面不动，只有光标在动，用来检验补插过渡帧。"
        ]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: bounds.width * 0.08, y: bounds.height * 0.72 - CGFloat(i) * 30), withAttributes: body)
        }
        for (label, fx, fy) in [("A", 0.32, 0.55), ("B", 0.62, 0.45)] {
            let center = NSPoint(x: bounds.width * fx, y: bounds.height * fy)
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 50, y: center.y - 50, width: 100, height: 100))
            NSColor(srgbRed: 64 / 255, green: 138 / 255, blue: 150 / 255, alpha: 1).setStroke()
            ring.lineWidth = 4
            ring.stroke()
            (label as NSString).draw(at: NSPoint(x: center.x - 14, y: center.y - 26), withAttributes: title)
        }
    }
}
