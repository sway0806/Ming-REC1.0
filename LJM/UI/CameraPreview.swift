import AppKit
@preconcurrency import AVFoundation

enum CameraShape: String, CaseIterable, Identifiable {
    case circle
    /// Persisted as "roundedSquare" so an earlier 圆角方形 choice still loads.
    case rectangle = "roundedSquare"

    var id: String { rawValue }
    var title: String { self == .circle ? "圆形" : "长方形" }

    /// Circular clip for 圆形; rounded-rect hit area for 长方形.
    func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        switch self {
        case .circle:
            let radius = min(bounds.width, bounds.height) / 2
            return hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius + 1
        case .rectangle:
            return bounds.contains(point)
        }
    }
}

enum CameraGeometry {
    // Top-left stays put; the user drags the bottom-right corner.
    static func resized(_ frame: CGRect, delta: CGSize, shape: CameraShape, available: CGRect) -> CGRect {
        let maxWidth = max(64, available.maxX - frame.minX)
        let maxHeight = max(64, frame.maxY - available.minY)
        var width = min(maxWidth, max(64, frame.width + delta.width))
        var height = min(maxHeight, max(64, frame.height - delta.height))
        if shape == .circle {
            let change = abs(delta.width) >= abs(delta.height) ? delta.width : -delta.height
            let side = min(maxWidth, maxHeight, max(64, frame.width + change))
            width = side
            height = side
        }
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    static func fitted(_ frame: CGRect, in area: CGRect, shape: CameraShape) -> CGRect {
        let margin: CGFloat = min(12, max(0, (min(area.width, area.height) - 64) / 2))
        let safe = area.insetBy(dx: margin, dy: margin)
        var size = CGSize(
            width: min(safe.width, max(64, frame.width)),
            height: min(safe.height, max(64, frame.height))
        )
        if shape == .circle {
            let side = min(size.width, size.height)
            size = CGSize(width: side, height: side)
        }
        return CGRect(
            x: min(max(frame.minX, safe.minX), safe.maxX - size.width),
            y: min(max(frame.minY, safe.minY), safe.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    /// When leaving a 1:1 circle, widen to a 4:3 landscape so 长方形 doesn't look like a square.
    static func landscape(from size: CGSize, in available: CGRect) -> CGSize {
        let height = max(64, min(size.height, available.height))
        let width = min(max(64, height * 4 / 3), max(64, available.width))
        return CGSize(width: width, height: height)
    }
}

/// Floating camera preview. Must NOT use `sharingType = .none` so ScreenCaptureKit can record it.
final class CameraPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CameraPreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    private let clipLayer = CALayer()
    private let border = CAShapeLayer()
    private let grip = CAShapeLayer()
    private var tracking: NSTrackingArea?

    var shape: CameraShape = .circle {
        didSet { needsLayout = true; window?.invalidateCursorRects(for: self) }
    }
    var onShape: ((CameraShape) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onMoved: (() -> Void)?

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: CGRect(x: 0, y: 0, width: 176, height: 176))
        wantsLayer = true
        clipLayer.masksToBounds = true
        layer?.addSublayer(clipLayer)
        preview.videoGravity = .resizeAspectFill
        clipLayer.addSublayer(preview)
        border.fillColor = NSColor.clear.cgColor
        // 小名 orange #FC6B10
        border.strokeColor = NSColor(calibratedRed: 252 / 255, green: 107 / 255, blue: 16 / 255, alpha: 1).cgColor
        border.lineWidth = 3
        layer?.addSublayer(border)
        grip.strokeColor = NSColor.white.cgColor
        grip.lineWidth = 2
        grip.lineCap = .round
        grip.shadowColor = NSColor.black.cgColor
        grip.shadowOpacity = 0.55
        grip.shadowRadius = 2
        grip.opacity = 0
        layer?.addSublayer(grip)
        setAccessibilityLabel("摄像头小窗：拖动画面移动，拖动右下角调整大小，右键或在「更多」里切换圆形和长方形")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if gripRect.insetBy(dx: -8, dy: -8).contains(local) { return self }
        return shape.contains(local, in: bounds) ? self : nil
    }

    private var gripRect: CGRect {
        let inset: CGFloat = shape == .circle ? bounds.width * 0.20 : 8
        return CGRect(x: bounds.maxX - inset - 20, y: inset, width: 20, height: 20)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = bounds
        clipLayer.cornerRadius = shape == .circle ? min(bounds.width, bounds.height) / 2 : 16
        preview.frame = clipLayer.bounds
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let radius: CGFloat = shape == .circle ? min(rect.width, rect.height) / 2 : 15
        border.frame = bounds
        border.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let handle = gripRect
        let path = CGMutablePath()
        path.move(to: CGPoint(x: handle.minX + 4, y: handle.minY + 4))
        path.addLine(to: CGPoint(x: handle.maxX - 4, y: handle.maxY - 4))
        path.move(to: CGPoint(x: handle.minX + 11, y: handle.minY + 4))
        path.addLine(to: CGPoint(x: handle.maxX - 4, y: handle.maxY - 11))
        grip.frame = bounds
        grip.path = path
        CATransaction.commit()
        window?.invalidateShadow()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { grip.opacity = 1 }
    override func mouseExited(with event: NSEvent) { grip.opacity = 0 }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(gripRect.insetBy(dx: -7, dy: -7), cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if gripRect.insetBy(dx: -8, dy: -8).contains(point) {
            resize(window: window, event: event)
            return
        }
        window.performDrag(with: event)
        onMoved?()
    }

    private func resize(window: NSWindow, event: NSEvent) {
        let initial = window.frame
        let start = NSEvent.mouseLocation
        let area = window.screen?.visibleFrame ?? initial.insetBy(dx: -1000, dy: -1000)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            let delta = CGSize(width: mouse.x - start.x, height: mouse.y - start.y)
            window.setFrame(CameraGeometry.resized(initial, delta: delta, shape: shape, available: area), display: true)
        }
        onResize?(window.frame.size)
        onMoved?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for value in CameraShape.allCases {
            let item = NSMenuItem(title: value.title, action: #selector(selectShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = shape == value ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectShape(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let value = CameraShape(rawValue: raw) {
            onShape?(value)
        }
    }
}

/// Owns the camera session and the floating preview window. The session runs only while the camera is on.
@MainActor
final class CameraController {
    private var panel: CameraPanel?
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "dev.ljm.recorder.camera", qos: .userInitiated)
    var onShapeChange: ((CameraShape) -> Void)?

    var shape = CameraShape(rawValue: UserDefaults.standard.string(forKey: Keys.shape) ?? "") ?? .circle
    private var preferredSize: CGSize = {
        let value = UserDefaults.standard.string(forKey: Keys.size).map(NSSizeFromString) ?? CGSize(width: 176, height: 176)
        return CGSize(width: max(64, value.width), height: max(64, value.height))
    }()
    private var rememberedOrigin: CGPoint? = {
        guard let raw = UserDefaults.standard.string(forKey: Keys.origin) else { return nil }
        let point = NSPointFromString(raw)
        return point
    }()

    var windowID: Int? { panel?.windowNumber }
    var isRunning: Bool { session != nil && panel != nil }

    func setShape(_ value: CameraShape) {
        let previous = shape
        shape = value
        UserDefaults.standard.set(value.rawValue, forKey: Keys.shape)
        // Even if the window is not open, remember a 4:3 size so the next
        // preview is clearly rectangular rather than a leftover circle square.
        if value == .rectangle, previous == .circle, abs(preferredSize.width - preferredSize.height) < 2 {
            let area = panel?.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            preferredSize = CameraGeometry.landscape(from: preferredSize, in: area)
        }
        guard let panel, let view = panel.contentView as? CameraPreviewView else {
            onShapeChange?(value)
            return
        }
        view.shape = value
        let area = panel.screen?.visibleFrame ?? panel.frame
        var frame = panel.frame
        if value == .rectangle, previous == .circle, abs(frame.width - frame.height) < 2 {
            frame.size = CameraGeometry.landscape(from: frame.size, in: area)
        }
        panel.setFrame(CameraGeometry.fitted(frame, in: area, shape: value), display: true)
        rememberFrame(panel.frame)
        onShapeChange?(value)
    }

    /// Starts the preview. Pass `requestAccess: false` only when status is already authorized (e.g. restore on launch).
    func start(on screen: NSScreen, region: CGRect?, requestAccess: Bool) async throws {
        if requestAccess {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CaptureError.message("摄像头尚未授权。请在系统设置 → 隐私与安全性 → 摄像头中允许小名。")
            }
        } else {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CaptureError.message("摄像头尚未授权。请在系统设置 → 隐私与安全性 → 摄像头中允许小名。")
            }
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CaptureError.message("没有找到摄像头。屏幕和声音录制仍可正常使用。")
        }
        stop()

        let capture = AVCaptureSession()
        capture.beginConfiguration()
        if capture.canSetSessionPreset(.hd1280x720) {
            capture.sessionPreset = .hd1280x720
        } else if capture.canSetSessionPreset(.medium) {
            capture.sessionPreset = .medium
        } else {
            capture.sessionPreset = .high
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard capture.canAddInput(input) else {
            throw CaptureError.message("摄像头当前不可用。")
        }
        capture.addInput(input)
        if let frameRate = preferredFrameDuration(for: device) {
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = frameRate
                device.activeVideoMaxFrameDuration = frameRate
                device.unlockForConfiguration()
            } catch {
                device.unlockForConfiguration()
            }
        }
        capture.commitConfiguration()
        session = capture

        let window = CameraPanel(
            contentRect: CGRect(origin: .zero, size: preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.title = "小名 摄像头"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        // Leave sharingType at the default so ScreenCaptureKit records this window.

        let view = CameraPreviewView(session: capture)
        view.shape = shape
        view.onShape = { [weak self] value in self?.setShape(value) }
        view.onResize = { [weak self] size in self?.rememberSize(size) }
        view.onMoved = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.rememberFrame(panel.frame)
        }
        window.contentView = view
        panel = window
        place(on: screen, region: region, initial: true)
        await withCheckedContinuation { continuation in
            queue.async {
                capture.startRunning()
                continuation.resume()
            }
        }
        window.orderFrontRegardless()
    }

    func place(on screen: NSScreen, region: CGRect?, initial: Bool = false) {
        guard let panel else { return }
        let area: CGRect
        if let region {
            area = CGRect(
                x: screen.frame.minX + region.minX,
                y: screen.frame.maxY - region.maxY,
                width: region.width,
                height: region.height
            )
        } else {
            area = screen.visibleFrame
        }
        let frame: CGRect
        var size = preferredSize
        if shape == .rectangle, abs(size.width - size.height) < 2 {
            size = CameraGeometry.landscape(from: size, in: area)
        }
        if initial, let origin = rememberedOrigin {
            frame = CGRect(origin: origin, size: size)
        } else if initial {
            frame = CGRect(
                x: area.maxX - size.width - 16,
                y: area.minY + 16,
                width: size.width,
                height: size.height
            )
        } else {
            frame = panel.frame
        }
        panel.setFrame(CameraGeometry.fitted(frame, in: area, shape: shape), display: true)
        rememberFrame(panel.frame)
    }

    /// Stops the session and releases the camera completely.
    func stop() {
        if let panel {
            rememberFrame(panel.frame)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        if let capture = session {
            session = nil
            queue.async { capture.stopRunning() }
        }
    }

    private func rememberSize(_ size: CGSize) {
        preferredSize = CGSize(width: max(64, size.width), height: max(64, size.height))
        UserDefaults.standard.set(NSStringFromSize(preferredSize), forKey: Keys.size)
    }

    private func rememberFrame(_ frame: CGRect) {
        rememberSize(frame.size)
        rememberedOrigin = frame.origin
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Keys.origin)
    }

    private func preferredFrameDuration(for device: AVCaptureDevice) -> CMTime? {
        let wanted = CMTime(value: 1, timescale: 30)
        let formats = device.formats
        for format in formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.minFrameDuration <= wanted && wanted <= range.maxFrameDuration {
                    return wanted
                }
            }
        }
        return nil
    }

    private enum Keys {
        static let shape = "ljm.cameraShape"
        static let size = "ljm.cameraSize"
        static let origin = "ljm.cameraOrigin"
    }
}

/// Geometry and hit-testing only. Does not open the camera or write a frame.
enum CameraShapeSelfTest {
    static func run() -> String {
        var lines: [String] = []
        let fallback = CameraShape(rawValue: "") ?? .circle
        lines.append("default=\(fallback)")
        lines.append("titles=\(CameraShape.allCases.map(\.title).joined(separator: ","))")
        lines.append("persistRectangle=\(CameraShape(rawValue: "roundedSquare") == .rectangle)")
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        let square = CGRect(x: 100, y: 100, width: 176, height: 176)
        let circleFit = CameraGeometry.fitted(CGRect(x: 100, y: 100, width: 200, height: 120), in: area, shape: .circle)
        lines.append("circle.fittedSquare=\(abs(circleFit.width - circleFit.height) < 0.5)")
        let rectFit = CameraGeometry.fitted(CGRect(x: 100, y: 100, width: 240, height: 140), in: area, shape: .rectangle)
        lines.append("rectangle.fittedFree=\(abs(rectFit.width - 240) < 0.5 && abs(rectFit.height - 140) < 0.5)")
        let grownCircle = CameraGeometry.resized(square, delta: CGSize(width: 40, height: 0), shape: .circle, available: area)
        lines.append("circle.resizeSquare=\(abs(grownCircle.width - grownCircle.height) < 0.5 && grownCircle.width > square.width)")
        let grownRect = CameraGeometry.resized(square, delta: CGSize(width: 40, height: 0), shape: .rectangle, available: area)
        lines.append("rectangle.resizeWide=\(grownRect.width > grownRect.height + 10)")
        let landscape = CameraGeometry.landscape(from: square.size, in: area)
        lines.append("rectangle.landscape=\(abs(landscape.width / landscape.height - 4 / 3) < 0.05)")
        let bounds = CGRect(x: 0, y: 0, width: 176, height: 176)
        let center = CGPoint(x: 88, y: 88)
        let corner = CGPoint(x: 2, y: 2)
        lines.append("hit.circle.center=\(CameraShape.circle.contains(center, in: bounds))")
        lines.append("hit.circle.corner=\(CameraShape.circle.contains(corner, in: bounds))")
        lines.append("hit.rectangle.center=\(CameraShape.rectangle.contains(center, in: bounds))")
        lines.append("hit.rectangle.corner=\(CameraShape.rectangle.contains(corner, in: bounds))")
        return lines.joined(separator: "\n") + "\n"
    }
}
