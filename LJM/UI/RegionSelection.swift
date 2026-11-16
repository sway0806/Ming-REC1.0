import AppKit

/// Full-screen drag-to-select overlay. Confirms on mouse-up or Return; Esc cancels.
/// Visuals use 小名's orange, not another product's theme.
@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var completion: ((CGDirectDisplayID, CGRect) -> Void)?
    private var activeView: SelectionCanvas?

    func begin(completion: @escaping (CGDirectDisplayID, CGRect) -> Void) {
        cancel()
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.sharingType = .none
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            let canvas = SelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.onSelect = { [weak self, weak panel] localRect in
                guard let self, let panel else { return }
                self.confirm(window: panel, localRect: localRect)
            }
            canvas.onBecomeActive = { [weak self] view in
                self?.activeView = view
            }
            panel.contentView = canvas
            windows.append(panel)
            panel.orderFrontRegardless()
            if screen.frame.contains(NSEvent.mouseLocation) {
                panel.makeKey()
                activeView = canvas
            }
        }
        NSApp.activate()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                self.confirmFromKeyboard()
                return nil
            }
            return event
        }
    }

    func cancel() {
        teardown(keepCompletion: false)
    }

    private func confirm(window: NSWindow, localRect: CGRect) {
        guard let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame == window.frame }) else {
            cancel()
            return
        }
        let global = window.convertToScreen(localRect)
        let rect = CaptureGeometry.sourceRect(selectionInScreen: global, screenFrame: screen.frame)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard rect.width >= 64, rect.height >= 64 else { return }
        let callback = completion
        teardown(keepCompletion: false)
        callback?(id, rect)
    }

    private func confirmFromKeyboard() {
        guard let canvas = activeView ?? windows.compactMap({ $0.contentView as? SelectionCanvas }).first(where: { $0.currentSelection != nil }),
              let window = canvas.window,
              let selection = canvas.currentSelection
        else { return }
        confirm(window: window, localRect: selection)
    }

    private func teardown(keepCompletion: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        activeView = nil
        if !keepCompletion { completion = nil }
    }
}

final class SelectionCanvas: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onBecomeActive: ((SelectionCanvas) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    var currentSelection: CGRect? {
        guard let start, let current else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        ).intersection(bounds)
        return rect
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onBecomeActive?(self)
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        if let selection = currentSelection, selection.width >= 64, selection.height >= 64 {
            onSelect?(selection)
        } else {
            start = nil
            current = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        if let selection = currentSelection, selection.width > 1, selection.height > 1 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            selection.fill()
            NSGraphicsContext.restoreGraphicsState()
            // 小名 orange #FC6B10
            NSColor(calibratedRed: 252 / 255, green: 107 / 255, blue: 16 / 255, alpha: 1).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 2
            border.stroke()
            let sizeText = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
            drawLabel(sizeText, at: CGPoint(x: selection.minX + 8, y: max(12, selection.minY - 34)))
        }
        let hint = "拖动选择录制区域  ·  至少 64 × 64  ·  回车确认  ·  Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (hint as NSString).size(withAttributes: attrs)
        let hintPoint = CGPoint(x: max(20, bounds.midX - size.width / 2), y: bounds.maxY - 90)
        drawLabel(hint, at: hintPoint)
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: point.x - 10, y: point.y - 7, width: size.width + 20, height: size.height + 14),
            xRadius: 10,
            yRadius: 10
        ).fill()
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}
