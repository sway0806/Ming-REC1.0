import AppKit
import QuartzCore

/// Compact in-recording control, excluded from the capture (own process + sharingType none).
/// Expanded: rec indicator, elapsed time, file size / free space, pause, stop.
/// After the pointer leaves for 5 seconds it shrinks to pause + stop, staying where
/// it was. A 1.5s dwell on the non-button chrome expands it again; hovering or
/// clicking the buttons does not. Each new take starts at the bottom-right of the
/// recorded screen or region. The bar is draggable from every area except the buttons.
@MainActor
final class RecordingBarController {
    /// Overridden in self-tests so we do not wait a full 5 seconds.
    var shrinkDelay: TimeInterval = 5
    /// Time the pointer must rest on non-button chrome before a shrunk bar expands.
    var expandDelay: TimeInterval = 1.5
    /// Comfortable inset from the recorded area (or visible frame) edges.
    static let edgeMargin: CGFloat = 16

    private var panel: NSPanel?
    private var root: RecordingBarView?
    private var shrinkTimer: Timer?
    private var expandTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pointerZone: RecordingBarPointerZone = .outside
    /// When set, self-tests own the pointer zone and live mouse monitors must
    /// not overwrite it (a real cursor elsewhere would cancel the 1.5s dwell).
    private var simulatedZone: RecordingBarPointerZone?
    private var dragging = false
    private weak var model: AppModel?
    /// Recorded area used only for the initial default placement of this take.
    private var placementArea = NSRect.zero

    var isVisible: Bool { panel?.isVisible == true }
    var isExpanded: Bool { root?.expanded ?? true }
    var windowFrame: NSRect? { panel?.frame }

    func attach(model: AppModel) {
        self.model = model
    }

    func show(on screen: NSScreen, region: CGRect?) {
        hide()
        let recorded = RecordingChromeGeometry.area(on: screen, region: region)
        let area = Self.placementArea(recorded: recorded, screen: screen, region: region)
        placementArea = area
        let view = RecordingBarView(model: model)
        view.expanded = true
        view.onPause = { [weak self] in self?.model?.togglePause() }
        view.onStop = { [weak self] in self?.model?.toggleRecord() }
        view.onDragStart = { [weak self] in self?.dragDidStart() }
        view.onDragEnd = { [weak self] moved in self?.dragDidEnd(moved: moved) }
        let size = view.preferredSize
        let frame = Self.defaultFrame(size: size, in: area)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.title = "小名录像条"
        panel.isMovable = false
        panel.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        self.root = view
        view.reload()
        installMouseMonitor()
        syncHoverFromMouse()
    }

    func hide() {
        cancelTimers()
        removeMouseMonitors()
        pointerZone = .outside
        simulatedZone = nil
        dragging = false
        placementArea = .zero
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        root = nil
    }

    /// Test hook: pretend the pointer entered or left the bar. Entering maps to
    /// the non-button chrome; it no longer expands a shrunk bar immediately.
    func simulateHover(_ inside: Bool) {
        simulateZone(inside ? .chrome : .outside)
    }

    func simulateZone(_ zone: RecordingBarPointerZone) {
        simulatedZone = zone
        noteZone(zone)
    }

    func reload() {
        root?.reload()
        refit(animated: false)
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        cancelTimers()
        guard let root, let panel, root.expanded != expanded else { return }
        root.expanded = expanded
        root.reload()
        refit(animated: animated)
        panel.invalidateShadow()
    }

    // MARK: - Test hooks

    func zone(atViewPoint point: NSPoint) -> RecordingBarPointerZone {
        root?.zone(atViewPoint: point) ?? .outside
    }

    /// A point in the left padding, used as the chrome / drag / dwell target.
    func chromeTestPoint() -> NSPoint? {
        root?.chromeTestPoint()
    }

    /// Center of the pause button.
    func buttonTestPoint() -> NSPoint? {
        root?.buttonTestPoint()
    }

    /// Moves the bar as a completed chrome drag would. Button-zone calls are a no-op.
    @discardableResult
    func performTestDrag(from zone: RecordingBarPointerZone, delta: CGPoint) -> NSRect? {
        guard let panel else { return nil }
        guard zone == .chrome else { return panel.frame }
        dragDidStart()
        var frame = panel.frame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        panel.setFrame(frame, display: true)
        clampToCurrentScreen()
        dragDidEnd(moved: true)
        return panel.frame
    }

    var edgeMargin: CGFloat { Self.edgeMargin }

    // MARK: - Layout

    private func refit(animated: Bool) {
        guard let root, let panel else { return }
        let size = root.preferredSize
        let area = clampArea(for: panel)
        let frame = Self.resizedFrame(size: size, previous: panel.frame, in: area)
        root.frame = NSRect(origin: .zero, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func noteZone(_ zone: RecordingBarPointerZone) {
        if dragging { return }
        let previous = pointerZone
        pointerZone = zone

        if zone != .outside {
            shrinkTimer?.invalidate()
            shrinkTimer = nil
        }

        if zone == .chrome, root?.expanded == false {
            if expandTimer == nil {
                startExpandTimer()
            }
        } else if previous == .chrome || expandTimer != nil {
            // Leaving the non-button area (onto a button or off the bar)
            // cancels a pending expand. Hovering the buttons never starts it.
            expandTimer?.invalidate()
            expandTimer = nil
        }

        if zone == .outside, root?.expanded == true, shrinkTimer == nil {
            startShrinkTimer()
        }
    }

    private func startShrinkTimer() {
        shrinkTimer?.invalidate()
        let delay = shrinkDelay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.setExpanded(false, animated: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        shrinkTimer = timer
    }

    private func startExpandTimer() {
        expandTimer?.invalidate()
        let delay = expandDelay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.pointerZone == .chrome, self.root?.expanded == false else { return }
                self.setExpanded(true, animated: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expandTimer = timer
    }

    private func cancelTimers() {
        shrinkTimer?.invalidate()
        shrinkTimer = nil
        expandTimer?.invalidate()
        expandTimer = nil
    }

    private func cancelChromeAnimation() {
        guard let panel else { return }
        let current = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(current, display: false)
        }
        panel.setFrame(current, display: true)
    }

    private func dragDidStart() {
        dragging = true
        cancelTimers()
        cancelChromeAnimation()
        pointerZone = .chrome
    }

    private func dragDidEnd(moved: Bool) {
        dragging = false
        if moved {
            clampToCurrentScreen()
        }
        syncHoverFromMouse()
    }

    private func installMouseMonitor() {
        removeMouseMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.syncHoverFromMouse()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async { self?.syncHoverFromMouse() }
        }
    }

    private func removeMouseMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func syncHoverFromMouse() {
        guard simulatedZone == nil else { return }
        guard let panel, panel.isVisible, let root, !dragging else { return }
        let screenPoint = NSEvent.mouseLocation
        guard NSMouseInRect(screenPoint, panel.frame, false) else {
            noteZone(.outside)
            return
        }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let inRoot = root.convert(windowPoint, from: nil)
        noteZone(root.zone(atViewPoint: inRoot))
    }

    private func clampToCurrentScreen() {
        guard let panel else { return }
        let area = clampArea(for: panel)
        let frame = Self.clamped(panel.frame, in: area)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func clampArea(for panel: NSPanel) -> NSRect {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? panel.frame
    }

    /// Full-display takes sit in the visible frame so the bar is not hidden by the Dock.
    /// Region takes use the recorded region's bottom-right.
    static func placementArea(recorded: NSRect, screen: NSScreen, region: CGRect?) -> NSRect {
        if region == nil {
            let visible = screen.visibleFrame
            let overlap = recorded.intersection(visible)
            return overlap.isNull || overlap.isEmpty ? visible : overlap
        }
        return recorded
    }

    static func defaultFrame(size: CGSize, in area: NSRect) -> NSRect {
        let origin = NSPoint(
            x: area.maxX - size.width - edgeMargin,
            y: area.minY + edgeMargin
        )
        return clamped(NSRect(origin: origin, size: size), in: area)
    }

    /// Shrink / expand keeps the trailing (right) and bottom edges so pause and stop stay put.
    static func resizedFrame(size: CGSize, previous: NSRect, in area: NSRect) -> NSRect {
        let origin = NSPoint(
            x: previous.maxX - size.width,
            y: previous.minY
        )
        return clamped(NSRect(origin: origin, size: size), in: area)
    }

    static func clamped(_ frame: NSRect, in area: NSRect) -> NSRect {
        var origin = frame.origin
        let size = frame.size
        let minX = area.minX + edgeMargin
        let maxX = area.maxX - size.width - edgeMargin
        if maxX >= minX {
            origin.x = min(max(origin.x, minX), maxX)
        } else {
            origin.x = area.midX - size.width / 2
        }
        let minY = area.minY + edgeMargin
        let maxY = area.maxY - size.height - edgeMargin
        if maxY >= minY {
            origin.y = min(max(origin.y, minY), maxY)
        } else {
            origin.y = area.minY + edgeMargin
        }
        return NSRect(origin: origin, size: size)
    }
}

enum RecordingBarPointerZone: Equatable {
    case outside
    case chrome
    case button
}

private final class RecordingBarView: NSView {
    weak var model: AppModel?
    var expanded = true
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((Bool) -> Void)?

    private let fill = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let timeLabel = NSTextField(labelWithString: "00:00:00")
    private let storageLabel = NSTextField(labelWithString: "")
    private let pauseButton = RecordingBarButton()
    private let stopButton = RecordingBarButton()
    private var pulse: Timer?

    /// Shrunk size keeps a real left / vertical / trailing pad around the two buttons
    /// so there is a drag target and a 1.5s dwell-to-expand target.
    var preferredSize: CGSize {
        expanded ? CGSize(width: 408, height: 44) : CGSize(width: 112, height: 44)
    }

    init(model: AppModel?) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: 408, height: 44)))
        wantsLayer = true
        layer?.masksToBounds = false
        fill.colors = [
            NSColor(srgbRed: 58 / 255, green: 59 / 255, blue: 64 / 255, alpha: 0.97).cgColor,
            NSColor(srgbRed: 36 / 255, green: 37 / 255, blue: 41 / 255, alpha: 0.97).cgColor
        ]
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(fill)
        rim.fillColor = nil
        rim.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        rim.lineWidth = 1
        layer?.addSublayer(rim)
        dot.fillColor = NSColor(srgbRed: 226 / 255, green: 50 / 255, blue: 30 / 255, alpha: 1).cgColor
        layer?.addSublayer(dot)

        configureLabel(timeLabel, size: 13, weight: .semibold, mono: true)
        configureLabel(storageLabel, size: 11, weight: .medium, mono: true)
        storageLabel.textColor = NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 0.66)

        pauseButton.toolTip = "暂停或继续"
        pauseButton.onPress = { [weak self] in self?.onPause?() }
        stopButton.toolTip = "停止并保存"
        stopButton.usesRecordChrome = true
        stopButton.onPress = { [weak self] in self?.onStop?() }
        addSubview(timeLabel)
        addSubview(storageLabel)
        addSubview(pauseButton)
        addSubview(stopButton)
        startPulse()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pulse?.invalidate()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// `hitTest` receives a point in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let hit = pauseButton.hitTest(local) { return hit }
        if let hit = stopButton.hitTest(local) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startOrigin = window.frame.origin
        let startMouse = NSEvent.mouseLocation
        var dragged = false
        onDragStart?()
        NSCursor.closedHand.push()
        NSCursor.closedHand.set()
        defer {
            NSCursor.pop()
            window.invalidateCursorRects(for: self)
            onDragEnd?(dragged)
        }
        dragged = PanelDragLoop.run(window: window, from: startOrigin, startMouse: startMouse)
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        let radius = bounds.height / 2
        fill.cornerRadius = radius
        let rimPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        rim.path = rimPath
        rim.frame = bounds
        let button: CGFloat = 28
        let trailing: CGFloat = 12
        let gap: CGFloat = 8
        let pauseX = bounds.maxX - trailing - button * 2 - gap
        let stopX = bounds.maxX - trailing - button
        let buttonY = (bounds.height - button) / 2
        pauseButton.frame = NSRect(x: pauseX, y: buttonY, width: button, height: button)
        stopButton.frame = NSRect(x: stopX, y: buttonY, width: button, height: button)
        if expanded {
            dot.opacity = 1
            dot.path = CGPath(ellipseIn: CGRect(x: 16, y: (bounds.height - 8) / 2, width: 8, height: 8), transform: nil)
            timeLabel.isHidden = false
            storageLabel.isHidden = false
            timeLabel.frame = NSRect(x: 32, y: (bounds.height - 16) / 2, width: 78, height: 16)
            storageLabel.frame = NSRect(x: 112, y: (bounds.height - 16) / 2, width: max(40, pauseX - 124), height: 16)
        } else {
            dot.opacity = 0
            timeLabel.isHidden = true
            storageLabel.isHidden = true
        }
        CATransaction.commit()
    }

    func reload() {
        let seconds = model?.elapsedSeconds ?? 0
        timeLabel.stringValue = CaptureGeometry.elapsedHMS(seconds)
        let paused = model?.paused == true
        timeLabel.textColor = paused
            ? NSColor(srgbRed: 252 / 255, green: 107 / 255, blue: 16 / 255, alpha: 1)
            : NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 1)
        let note = model?.liveStorageNote ?? ""
        storageLabel.stringValue = note
        pauseButton.symbolName = paused ? "play.fill" : "pause.fill"
        pauseButton.toolTip = paused ? "继续录制" : "暂停录制"
        pauseButton.needsDisplay = true
        stopButton.symbolName = "stop.fill"
        needsLayout = true
    }

    func zone(atViewPoint point: NSPoint) -> RecordingBarPointerZone {
        guard bounds.contains(point) else { return .outside }
        if pauseButton.frame.contains(point) || stopButton.frame.contains(point) {
            return .button
        }
        return .chrome
    }

    func chromeTestPoint() -> NSPoint {
        // Mid-height of the leading pad, clearly left of the pause button.
        let padRight = pauseButton.frame.minX
        return NSPoint(x: min(14, max(6, padRight / 2)), y: bounds.midY)
    }

    func buttonTestPoint() -> NSPoint {
        NSPoint(x: pauseButton.frame.midX, y: pauseButton.frame.midY)
    }

    private func startPulse() {
        pulse?.invalidate()
        pulse = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.expanded else { return }
                let on = self.model?.paused != true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.45
                    self.dot.opacity = on ? (self.dot.opacity > 0.7 ? 0.35 : 1) : 0.45
                }
            }
        }
        if let pulse { RunLoop.main.add(pulse, forMode: .common) }
    }

    private func configureLabel(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight, mono: Bool) {
        label.font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 1)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingMiddle
    }
}

private final class RecordingBarButton: NSView {
    var symbolName = "pause.fill"
    var usesRecordChrome = false
    var onPress: (() -> Void)?
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        // App-level tracking: window.nextEvent can miss the mouse-up on a
        // nonactivating panel and is not used here.
        while true {
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseUp {
                let local = convert(next.locationInWindow, from: nil)
                if bounds.contains(local) { onPress?() }
                break
            }
        }
        pressed = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: pressed ? 1 : 0, dy: pressed ? 1 : 0)
        let path = NSBezierPath(ovalIn: rect)
        if usesRecordChrome {
            NSColor(srgbRed: 226 / 255, green: 50 / 255, blue: 30 / 255, alpha: 1).setFill()
        } else {
            NSColor(srgbRed: 70 / 255, green: 71 / 255, blue: 77 / 255, alpha: 1).setFill()
        }
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let color: NSColor = usesRecordChrome ? .white : NSColor(srgbRed: 226 / 255, green: 227 / 255, blue: 231 / 255, alpha: 1)
        if let image {
            let tinted = image.copy() as? NSImage ?? image
            tinted.isTemplate = true
            let size = tinted.size
            let dest = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            color.set()
            tinted.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
