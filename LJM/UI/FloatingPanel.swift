import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

final class FloatingPanel: NSPanel {
    var onDragStart: (() -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    var onMoveModeRequest: (() -> Void)?

    /// t194: double-click on the 横线 asks the controller to pick the bar up.
    func requestMoveMode() {
        onMoveModeRequest?()
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        title = "小名"
        isRestorable = false
        animationBehavior = .none
        sharingType = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func dragDidStart() {
        onDragStart?()
    }

    func dragDidEnd(moved: Bool) {
        onDragEnd?(moved)
    }
}

/// Press-drag on a nonactivating panel must read events from the app, not
/// only from that window: `window.nextEvent` can miss the mouse-up if a
/// local monitor (move mode) swallowed it, which left the bar stuck.
enum PanelDragLoop {
    @discardableResult
    static func run(window: NSWindow, from startOrigin: NSPoint, startMouse: NSPoint) -> Bool {
        var dragged = false
        while true {
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseUp { break }
            NSCursor.closedHand.set()
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            if hypot(dx, dy) > 3 { dragged = true }
            if dragged {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            }
        }
        return dragged
    }
}

struct WindowDragArea: NSViewRepresentable {
    /// true: capsule bar (stadium hit shape). false: side card (rectangle).
    var stadium: Bool = true
    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.stadium = stadium
        return view
    }
    func updateNSView(_ nsView: DragView, context: Context) { nsView.stadium = stadium }
}

final class DragView: NSView {
    var stadium = true
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if stadium, !containsStadium(local) { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startOrigin = window.frame.origin
        let startMouse = NSEvent.mouseLocation
        var dragged = false
        (window as? FloatingPanel)?.dragDidStart()
        // Press-and-drag on the body still grabs, but hover does not change the
        // cursor here — only the move handle shows the open hand.
        ChromePointer.bodyDragging = true
        NSCursor.closedHand.push()
        NSCursor.closedHand.set()
        defer {
            NSCursor.pop()
            ChromePointer.bodyDragging = false
            ChromePointer.sync(in: window)
            (window as? FloatingPanel)?.dragDidEnd(moved: dragged)
        }
        dragged = PanelDragLoop.run(window: window, from: startOrigin, startMouse: startMouse)
    }

    private func containsStadium(_ point: NSPoint) -> Bool {
        let bounds = self.bounds
        let radius = min(bounds.width, bounds.height) / 2
        guard radius > 0 else { return false }
        if bounds.height >= bounds.width {
            if point.y < radius {
                return hypot(point.x - radius, point.y - radius) <= radius + 1
            }
            if point.y > bounds.height - radius {
                let cy = bounds.height - radius
                return hypot(point.x - radius, point.y - cy) <= radius + 1
            }
            return point.x >= -1 && point.x <= bounds.width + 1
        }
        if point.x < radius {
            return hypot(point.x - radius, point.y - radius) <= radius + 1
        }
        if point.x > bounds.width - radius {
            let cx = bounds.width - radius
            return hypot(point.x - cx, point.y - radius) <= radius + 1
        }
        return point.y >= -1 && point.y <= bounds.height + 1
    }
}

@MainActor
final class PanelController: NSObject {
    let model: AppModel
    private let panel = FloatingPanel()
    private let hosting: NSHostingView<AnyView>
    private var cancellables: Set<AnyCancellable> = []
    private var along: CGFloat = 0
    private var placed = false
    private var dragging = false
    private var snapGeneration = 0
    private var freeCenter: NSPoint?
    private var moveTimer: Timer?
    private var moveOffset = NSPoint.zero
    private var lastFollowMouse = NSPoint(x: -1, y: -1)
    private var moveMonitors: [Any] = []
    private var swallowNextUp = false
    /// Capsule within this many points of a screen's visible edge docks there.
    static let dockThreshold: CGFloat = 32

    init(model: AppModel) {
        self.model = model
        let host = FirstMouseHostingView(rootView: AnyView(ControlChrome().environmentObject(model)))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = true
        self.hosting = host
        super.init()
        panel.contentView = host
        panel.onDragStart = { [weak self] in
            MainActor.assumeIsolated {
                self?.cancelSnapAnimation()
                self?.dragging = true
            }
        }
        panel.onDragEnd = { [weak self] moved in
            MainActor.assumeIsolated {
                self?.dragging = false
                if moved { self?.drop() }
            }
        }
        panel.onMoveModeRequest = { [weak self] in
            MainActor.assumeIsolated { self?.enterMoveMode() }
        }
        if let stored = UserDefaults.standard.object(forKey: Keys.along) as? Double {
            along = CGFloat(stored)
        }
        if let x = UserDefaults.standard.object(forKey: Keys.freeX) as? Double,
           let y = UserDefaults.standard.object(forKey: Keys.freeY) as? Double {
            freeCenter = NSPoint(x: x, y: y)
        }
        model.$layoutTick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefit() }
            .store(in: &cancellables)
        model.$chromeSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefit() }
            .store(in: &cancellables)
        model.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRefit()
                AppDelegate.shared?.refreshStatusItemTitle()
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.refit(animated: false)
            self?.panel.alphaValue = 1
            DispatchQueue.main.async { self?.refit(animated: false) }
        }
    }

    func orderFront() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// Test hook (--self-test-ui-snapshot): the bar is `sharingType = .none`, so a
    /// normal screenshot cannot see it. Briefly allow capture of this one window,
    /// grab it with ScreenCaptureKit, then put `.none` back.
    func snapshotPNG(to url: URL) async -> String {
        let previous = panel.sharingType
        panel.sharingType = .readOnly
        defer { panel.sharingType = previous }
        try? await Task.sleep(nanoseconds: 400_000_000)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == panel.windowNumber }) else {
                return "panel window not in shareable content"
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = panel.backingScaleFactor
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return "png encode failed" }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return "ok \(image.width)x\(image.height)"
        } catch {
            return "snapshot failed: \(error.localizedDescription)"
        }
    }

    /// Hidden hook for --self-test-cursor. Probes the handle, every button
    /// tracking view, gaps, a synthetic disabled control, and the more/settings
    /// side cards. Warps the pointer, syncs hover state, then restores it.
    func runCursorSelfTest() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            var lines: [String] = []
            let saved = NSEvent.mouseLocation
            // t194 tests move the bar; put the user's saved placement back at the end.
            let defaults = UserDefaults.standard
            let placementKeys = [Keys.edge, Keys.along, Keys.floating, Keys.freeX, Keys.freeY]
            let savedPlacement = placementKeys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in savedPlacement {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
                Self.warpCursor(saved)
                Self.writeCursorReport(lines)
                NSApp.terminate(nil)
            }

            lines.append("wordmark.loaded=\(Theme.glowRidges.size.width > 0 && Theme.glowRidges.size.height > 0)")
            lines.append("wordmark.pointSize=\(Int(Metrics.wordmarkWidth.rounded()))x\(Int(Metrics.wordmarkHeight.rounded()))")
            lines.append("acceptsMoved=\(panel.acceptsMouseMovedEvents)")

            // Full-size checks run with the bar floating mid-screen.
            let screen = panel.screen ?? NSScreen.main!
            let mid = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
            model.edge = .right
            float(center: mid, on: screen)
            try? await Task.sleep(nanoseconds: 700_000_000)
            let fullThickness = min(panel.frame.width, panel.frame.height)
            lines.append("float.mini=\(model.miniDock) thickness=\(Int(fullThickness.rounded()))")

            await probeRegion("bar", lines: &lines)

            model.card = .more
            model.bumpLayout()
            try? await Task.sleep(nanoseconds: 450_000_000)
            hosting.layoutSubtreeIfNeeded()
            await probeRegion("more", lines: &lines)

            model.card = .settings
            model.bumpLayout()
            try? await Task.sleep(nanoseconds: 450_000_000)
            hosting.layoutSubtreeIfNeeded()
            refit(animated: false)
            let visibleH = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 0
            let cap = capsuleRect()
            lines.append("settings.window=\(Int(panel.frame.width))x\(Int(panel.frame.height)) fitting=\(Int(hosting.fittingSize.width))x\(Int(hosting.fittingSize.height)) visibleH=\(Int(visibleH))")
            lines.append("settings.capsule=\(Int(cap.width))x\(Int(cap.height)) y=\(Int(cap.minY)) visible=\(cap.maxY <= ((panel.screen ?? NSScreen.main)?.visibleFrame.maxY ?? 0) + 1 && cap.minY >= ((panel.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0) - 1)")
            await probeRegion("settings", lines: &lines)

            model.card = nil
            model.bumpLayout()
            try? await Task.sleep(nanoseconds: 500_000_000)

            await runMoveDockSelfTest(fullThickness: fullThickness, lines: &lines)
        }
    }

    /// t194: double-click enters move mode, the bar follows the mouse, a single
    /// click drops it (free placement keeps position and full size), a drop
    /// near an edge docks at 50%, and moving away restores full size.
    private func runMoveDockSelfTest(fullThickness: CGFloat, lines: inout [String]) async {
        lines.append("move.handleGone=\(ChromePointer.handle(in: hosting) == nil)")
        let startCap = capsuleRect()
        let handleScreen = NSPoint(x: startCap.midX, y: startCap.midY)
        Self.warpCursor(handleScreen)
        try? await Task.sleep(nanoseconds: 250_000_000)
        enterMoveMode()
        try? await Task.sleep(nanoseconds: 400_000_000)
        lines.append("move.enter=\(model.moveMode)")
        lines.append("move.ridges=\(String(describing: HandleMotion.shared.state))")
        lines.append("move.cursorClosed=\(ChromePointer.sameCursor(NSCursor.current, NSCursor.closedHand))")

        let before = capsuleRect()
        for step in 1...6 {
            Self.warpCursor(NSPoint(x: handleScreen.x - CGFloat(step) * 25, y: handleScreen.y - CGFloat(step) * 15))
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let followed = capsuleRect()
        let dx = followed.midX - before.midX
        let dy = followed.midY - before.midY
        lines.append("move.follow=\(abs(dx + 150) < 3 && abs(dy + 90) < 3) dx=\(Int(dx.rounded())) dy=\(Int(dy.rounded()))")

        let dropAt = panel.mouseLocationOutsideOfEventStream
        Self.postClick(at: dropAt, in: panel, clickCount: 1)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let dropped = capsuleRect()
        lines.append("move.exit=\(!model.moveMode)")
        lines.append("move.flagsClear=\(!ChromePointer.moveMode && !ChromePointer.handleDragging && !ChromePointer.bodyDragging && !dragging)")
        lines.append("free.floating=\(model.floating) mini=\(model.miniDock)")
        lines.append("free.kept=\(abs(dropped.midX - followed.midX) < 3 && abs(dropped.midY - followed.midY) < 3)")
        lines.append("free.fullSize=\(abs(min(panel.frame.width, panel.frame.height) - fullThickness) < 2)")

        // Drop near the right edge -> dock at full size.
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let cap = capsuleRect()
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + (visible.maxX - 12 - cap.maxX), y: panel.frame.origin.y))
        Self.warpCursor(NSPoint(x: capsuleRect().midX, y: capsuleRect().midY))
        try? await Task.sleep(nanoseconds: 150_000_000)
        drop()
        try? await Task.sleep(nanoseconds: 900_000_000)
        let dockThickness = min(panel.frame.width, panel.frame.height)
        lines.append("dock.edge=\(model.edge.rawValue) floating=\(model.floating) mini=\(model.miniDock) factor=\(Metrics.dockFactor)")
        lines.append("dock.fullSize=\(abs(dockThickness - fullThickness) < 2) thickness=\(Int(dockThickness.rounded()))")
        lines.append("dock.atEdge=\(abs(visible.maxX - 14 - capsuleRect().maxX) < 3)")
        await probeRegion("docked", lines: &lines)

        // Move it away from the edge -> floats, still full size, stays where dropped.
        let mid = NSPoint(x: visible.midX, y: visible.midY)
        let now = capsuleRect()
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + (mid.x - now.midX), y: panel.frame.origin.y + (mid.y - now.midY)))
        Self.warpCursor(mid)
        try? await Task.sleep(nanoseconds: 150_000_000)
        drop()
        try? await Task.sleep(nanoseconds: 900_000_000)
        let restored = capsuleRect()
        lines.append("undock.floating=\(model.floating) mini=\(model.miniDock)")
        lines.append("undock.fullSize=\(abs(min(panel.frame.width, panel.frame.height) - fullThickness) < 2)")
        lines.append("undock.kept=\(abs(restored.midX - mid.x) < 3 && abs(restored.midY - mid.y) < 3)")
        lines.append("undock.handleGone=\(ChromePointer.handle(in: hosting) == nil)")
    }

    private static func postClick(at point: NSPoint, in window: NSWindow, clickCount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: now,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: type == .leftMouseDown ? 1 : 0
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func probeRegion(_ tag: String, lines: inout [String]) async {
        hosting.layoutSubtreeIfNeeded()
        let window = panel
        let hands = ChromePointer.allHands(in: hosting).filter {
            $0.bounds.width >= 16 && $0.bounds.height >= 12
        }
        let enabledHands = hands.filter(\.cursorEnabled)
        let panelScreen = window.frame
        let visibleHands = enabledHands.filter { hand in
            let r = window.convertToScreen(hand.convert(hand.bounds, to: nil))
            return r.intersects(panelScreen.insetBy(dx: 1, dy: 1))
        }
        let panelArea = max(panel.frame.width * panel.frame.height, 1)
        let tooBig = hands.filter { $0.bounds.width * $0.bounds.height > panelArea * 0.6 }
        lines.append("\(tag).buttons=\(enabledHands.count)")
        lines.append("\(tag).buttonsVisible=\(visibleHands.count)")
        lines.append("\(tag).tooBig=\(tooBig.count)")
        for (index, oversized) in tooBig.enumerated() {
            lines.append("\(tag).tooBig\(index)=\(Int(oversized.bounds.width))x\(Int(oversized.bounds.height))")
        }

        var pointingOK = 0
        var hoverOK = 0
        var liftOK = 0
        for (index, hand) in visibleHands.enumerated() {
            let target = Self.screenPoint(of: hand, fallbackWindow: window)
            await Self.warpAndSync(target, window: window)
            let cursor = NSCursor.current
            let pointing = ChromePointer.sameCursor(cursor, NSCursor.pointingHand)
            let open = ChromePointer.sameCursor(cursor, NSCursor.openHand)
            if pointing && !open && hand.hovering {
                pointingOK += 1
                hoverOK += 1
            } else {
                lines.append("\(tag).button\(index) pointing=\(pointing) open=\(open) hovering=\(hand.hovering) size=\(Int(hand.bounds.width))x\(Int(hand.bounds.height))")
            }
            if hand.hovering, hand.lastMotion == .lifted {
                liftOK += 1
            } else {
                lines.append("\(tag).button\(index)Lift=hovering=\(hand.hovering) motion=\(String(describing: hand.lastMotion))")
            }
        }

        lines.append("\(tag).buttonPointing=\(pointingOK)/\(visibleHands.count)")
        lines.append("\(tag).buttonHover=\(hoverOK)/\(visibleHands.count)")
        lines.append("\(tag).buttonLift=\(liftOK)/\(visibleHands.count)")
        lines.append("\(tag).handleMotionOnButton=\(String(describing: HandleMotion.shared.state))")

        // Glow-ridge area is the move handle again (t234).
        let cap = capsuleRect()
        let verticalBar = cap.height > cap.width
        let markScreen = verticalBar
            ? NSPoint(x: cap.midX, y: cap.maxY - 12)
            : NSPoint(x: cap.minX + 16, y: cap.midY)
        await Self.warpAndSync(markScreen, window: window)
        let markCursor = NSCursor.current
        lines.append("\(tag).wordmarkOpen=\(ChromePointer.sameCursor(markCursor, NSCursor.openHand))")
        lines.append("\(tag).wordmarkPointing=\(ChromePointer.sameCursor(markCursor, NSCursor.pointingHand))")
        lines.append("\(tag).wordmarkArrow=\(ChromePointer.sameCursor(markCursor, NSCursor.arrow))")
        let markWin = window.convertFromScreen(NSRect(origin: markScreen, size: .zero)).origin
        let markInHost = hosting.convert(markWin, from: nil)
        let markHit = hosting.hitTestInLocalCoordinates(markInHost)
        lines.append("\(tag).wordmarkIsHandle=\(markHit is HandleDragView)")
        lines.append("\(tag).wordmarkDrags=\(markHit is HandleDragView || (markHit as? DragView)?.stadium == true)")
        // Side card padding is a drag area too (t230).
        func cardDrag(_ v: NSView) -> DragView? {
            if let d = v as? DragView, !d.stadium { return d }
            for c in v.subviews { if let f = cardDrag(c) { return f } }
            return nil
        }
        if let card = cardDrag(hosting) {
            let probe = NSPoint(x: card.bounds.minX + 6, y: card.bounds.midY)
            let inHost = hosting.convert(probe, from: card)
            let hit = hosting.hitTestInLocalCoordinates(inHost)
            lines.append("\(tag).cardDrags=\(hit === card)")
        }
        lines.append("\(tag).handleMissing=\(ChromePointer.handle(in: hosting) == nil)")
        let lingering = enabledHands.filter(\.hovering).count
        let lingeringMotion = enabledHands.filter { $0.lastMotion != .rest }.count
        lines.append("\(tag).lingeringHover=\(lingering)")
        lines.append("\(tag).lingeringMotion=\(lingeringMotion)")
        if let body = ChromePointer.bodyDrag(in: hosting),

           let gap = Self.findGap(in: hosting, window: window, handle: ChromePointer.handle(in: hosting), hands: hands) {
            let gapWin = window.convertFromScreen(NSRect(origin: gap, size: .zero)).origin
            let gapInHost = hosting.convert(gapWin, from: nil)
            let bodyHit = hosting.hitTestInLocalCoordinates(gapInHost)
            // The handle has priority; a gap should still land on the body drag view
            // or at least not be swallowed by a button tracking view.
            let bodyOK = (bodyHit === body) || (bodyHit is DragView) || !(bodyHit is PointingHandView)
            lines.append("\(tag).bodyHit=\(bodyOK)")
            if !bodyOK {
                lines.append("\(tag).bodyHitView=\(String(describing: type(of: bodyHit as Any)))")
            }
        }


        if let gap = Self.findGap(in: hosting, window: window, handle: ChromePointer.handle(in: hosting), hands: hands) {
            await Self.warpAndSync(gap, window: window)
            let gapCursor = NSCursor.current
            lines.append("\(tag).gapArrow=\(ChromePointer.sameCursor(gapCursor, NSCursor.arrow))")
            lines.append("\(tag).gapPointing=\(ChromePointer.sameCursor(gapCursor, NSCursor.pointingHand))")
            lines.append("\(tag).gapOpen=\(ChromePointer.sameCursor(gapCursor, NSCursor.openHand))")
            lines.append("\(tag).gapLingeringHover=\(enabledHands.filter(\.hovering).count)")
            lines.append("\(tag).handleMotionOnGap=\(String(describing: HandleMotion.shared.state))")
        } else {
            lines.append("\(tag).gapFound=false")
        }

        // Synthetic disabled control: same hit area, no finger and no lift flag.
        if let sample = enabledHands.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            sample.cursorEnabled = false
            let target = Self.screenPoint(of: sample, fallbackWindow: window)
            await Self.warpAndSync(target, window: window)
            let disabledCursor = NSCursor.current
            lines.append("\(tag).disabledPointing=\(ChromePointer.sameCursor(disabledCursor, NSCursor.pointingHand))")
            lines.append("\(tag).disabledHover=\(sample.hovering)")
            sample.cursorEnabled = true
        }
    }

    private static func findGap(in root: NSView, window: NSWindow, handle: HandleDragView?, hands: [PointingHandView]) -> NSPoint? {
        guard let content = window.contentView else { return nil }
        let step: CGFloat = 8
        var y = content.bounds.minY + 8
        while y < content.bounds.maxY - 8 {
            var x = content.bounds.minX + 8
            while x < content.bounds.maxX - 8 {
                let local = NSPoint(x: x, y: y)
                let winPoint = content.convert(local, to: nil)
                if let handle, ChromePointer.containsMouse(handle, windowLocation: winPoint) {
                    x += step
                    continue
                }
                var onButton = false
                for hand in hands where ChromePointer.containsMouse(hand, windowLocation: winPoint) {
                    onButton = true
                    break
                }
                if !onButton, content.hitTest(local) != nil {
                    return window.convertToScreen(NSRect(origin: winPoint, size: .zero)).origin
                }
                x += step
            }
            y += step
        }
        return nil
    }

    private static func screenPoint(of view: NSView, fallbackWindow: NSWindow) -> NSPoint {
        let window = view.window ?? fallbackWindow
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let inWindow = view.convert(local, to: nil)
        return window.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
    }

    private static func warpAndSync(_ point: NSPoint, window: NSWindow) async {
        warpCursor(point)
        try? await Task.sleep(nanoseconds: 120_000_000)
        warpCursor(NSPoint(x: point.x + 2, y: point.y + 2))
        ChromePointer.sync(in: window)
        try? await Task.sleep(nanoseconds: 220_000_000)
    }

    private static func warpCursor(_ point: NSPoint) {
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? point.y
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: maxY - point.y))
    }

    private static func writeCursorReport(_ lines: [String]) {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LJM", isDirectory: true)
        guard let movies else { return }
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?
            .write(to: movies.appendingPathComponent("cursor-self-test-result.txt"), options: .atomic)
    }

    @objc nonisolated private func screensChanged() {
        Task { @MainActor [weak self] in
            self?.refit(animated: false)
        }
    }

    private func scheduleRefit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.dragging else { return }
            self.refit(animated: false)
        }
    }

    /// Stop an in-flight 0.22s snap so the next press can start a drag immediately.
    private func cancelSnapAnimation() {
        snapGeneration += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.setFrame(panel.frame, display: true)
        }
    }

    // MARK: - t194 move mode, free placement, docked mini bar

    /// Double-click 横线: the bar follows the mouse (no button held) until the
    /// next single click (or Esc), which drops it where it is.
    func enterMoveMode() {
        guard !model.moveMode else { return }
        removeMoveMonitors()
        cancelSnapAnimation()
        let mouse = NSEvent.mouseLocation
        moveOffset = NSPoint(x: mouse.x - panel.frame.origin.x, y: mouse.y - panel.frame.origin.y)
        lastFollowMouse = mouse
        dragging = true
        model.moveMode = true
        ChromePointer.moveMode = true
        // Only swallow the pending mouse-up if the button is still down.
        swallowNextUp = (NSEvent.pressedMouseButtons & 1) != 0
        HandleMotion.shared.set(.pressed)
        NSCursor.closedHand.set()

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer

        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                let type = event.type
                let keyCode = type == .keyDown ? event.keyCode : 0
                let consume = MainActor.assumeIsolated {
                    self?.shouldConsumeMoveModeEvent(type: type, keyCode: keyCode) ?? false
                }
                return consume ? nil : event
            }
        ) {
            moveMonitors.append(local)
        }
        // A click that lands outside the bar (very fast flick) still drops it;
        // global monitors cannot swallow that click.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                if event.type == .keyDown, event.keyCode != 53 { return }
                MainActor.assumeIsolated {
                    guard let self, self.model.moveMode else { return }
                    self.exitMoveMode()
                }
            }
        ) {
            moveMonitors.append(global)
        }
    }

    /// Returns true when the event should be swallowed.
    private func shouldConsumeMoveModeEvent(type: NSEvent.EventType, keyCode: UInt16) -> Bool {
        switch type {
        case .leftMouseUp:
            if swallowNextUp {
                swallowNextUp = false
                let steal = !(ChromePointer.handleDragging || ChromePointer.bodyDragging)
                if !model.moveMode { removeMoveMonitors() }
                return steal
            }
            return false
        case .leftMouseDown, .rightMouseDown:
            guard model.moveMode else { return false }
            // The ending click only drops the bar; it must not press a button.
            swallowNextUp = type == .leftMouseDown
            exitMoveMode()
            return true
        case .keyDown:
            guard model.moveMode, keyCode == 53 else { return false }
            exitMoveMode()
            return true
        default:
            return false
        }
    }

    private func removeMoveMonitors() {
        let monitors = moveMonitors
        moveMonitors = []
        swallowNextUp = false
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    private func followMouse() {
        guard model.moveMode else { return }
        let mouse = NSEvent.mouseLocation
        guard mouse != lastFollowMouse else { return }
        lastFollowMouse = mouse
        panel.setFrameOrigin(NSPoint(x: mouse.x - moveOffset.x, y: mouse.y - moveOffset.y))
        NSCursor.closedHand.set()
    }

    func exitMoveMode() {
        guard model.moveMode else { return }
        moveTimer?.invalidate()
        moveTimer = nil
        model.moveMode = false
        ChromePointer.moveMode = false
        dragging = false
        drop()
        ChromePointer.sync(in: panel)
        // Keep the local monitor only long enough to eat this click's mouseUp.
        // A leftover monitor that swallows a later mouse-up starves the
        // press-drag loop and the bar appears to stop responding.
        if !swallowNextUp {
            removeMoveMonitors()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.model.moveMode else { return }
                self.removeMoveMonitors()
            }
        }
    }

    /// Capsule (not the side card) in screen coordinates.
    private func capsuleRect() -> NSRect {
        if let body = ChromePointer.bodyDrag(in: hosting), body.window != nil {
            let inWindow = body.convert(body.bounds, to: nil)
            return panel.convertToScreen(inWindow)
        }
        let center = capsuleCenter()
        let t = Metrics.thickness
        return NSRect(x: center.x - t / 2, y: center.y - t / 2, width: t, height: t)
    }

    /// After a drag or move mode: near a screen edge -> dock there at 50%;
    /// anywhere else -> stay exactly where dropped at full size.
    func drop() {
        guard let screen = screenUnderMouse() ?? panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let cap = capsuleRect()
        let distances: [(DockEdge, CGFloat)] = [
            (.left, cap.minX - visible.minX),
            (.right, visible.maxX - cap.maxX),
            (.bottom, cap.minY - visible.minY),
            (.top, visible.maxY - cap.maxY)
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }) else { return }
        if nearest.1 <= Self.dockThreshold {
            dock(to: nearest.0, along: nearest.0.isVertical ? cap.midY : cap.midX)
        } else {
            float(center: NSPoint(x: cap.midX, y: cap.midY), on: screen)
        }
    }

    func dock(to edge: DockEdge, along value: CGFloat) {
        let orientationChanged = edge.isVertical != model.edge.isVertical
        let scaleChanged = model.miniDock
        model.floating = false
        model.edge = edge
        along = value
        persistPlacement()
        model.applyDockScale(mini: false) // docked bars stay full size
        if orientationChanged {
            var room = panel.frame
            room.size = CGSize(width: max(room.width, 1100), height: max(room.height, 1100))
            panel.setFrame(room, display: false)
            refitSoon()
        } else if scaleChanged {
            refitSoon()
        } else {
            refit(animated: true)
        }
    }

    func float(center: NSPoint, on screen: NSScreen) {
        let wasMini = model.miniDock
        let visible = screen.visibleFrame
        // Keep the orientation; open side cards toward the roomier half.
        let side: DockEdge = model.edge.isVertical
            ? (center.x >= visible.midX ? .right : .left)
            : (center.y >= visible.midY ? .top : .bottom)
        model.floating = true
        model.edge = side
        freeCenter = center
        persistPlacement()
        model.applyDockScale(mini: false)
        if wasMini {
            refitSoon()
        } else {
            refit(animated: false)
        }
    }

    private func refitSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refit(animated: false)
            DispatchQueue.main.async { self?.refit(animated: false) }
        }
    }

    private func persistPlacement() {
        let defaults = UserDefaults.standard
        defaults.set(model.edge.rawValue, forKey: Keys.edge)
        defaults.set(Double(along), forKey: Keys.along)
        defaults.set(model.floating, forKey: Keys.floating)
        if let freeCenter {
            defaults.set(Double(freeCenter.x), forKey: Keys.freeX)
            defaults.set(Double(freeCenter.y), forKey: Keys.freeY)
        }
    }

    private func floatingFrame(for size: CGSize, center: NSPoint) -> NSRect {
        let t = Metrics.thickness
        var origin = NSPoint.zero
        switch model.edge {
        case .right:
            origin = NSPoint(x: center.x - (size.width - t / 2), y: center.y - size.height / 2)
        case .left:
            origin = NSPoint(x: center.x - t / 2, y: center.y - size.height / 2)
        case .top:
            origin = NSPoint(x: center.x - size.width / 2, y: center.y - (size.height - t / 2))
        case .bottom:
            origin = NSPoint(x: center.x - size.width / 2, y: center.y - t / 2)
        }
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? panel.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin = clamp(origin, size: size, to: visible, keepingCapsuleOn: model.edge)
        }
        return NSRect(origin: origin, size: size)
    }

    private func refit(animated: Bool) {
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if !looksLikeChrome(size) {
            size = hosting.intrinsicContentSize
        }
        if !looksLikeChrome(size), looksLikeChrome(model.chromeSize) {
            size = model.chromeSize
        }
        if !looksLikeChrome(size) {
            size = fallbackSize()
        }
        guard let screen = panel.screen ?? screenUnderMouse() ?? NSScreen.main else { return }
        if !placed {
            if UserDefaults.standard.object(forKey: Keys.along) == nil {
                along = model.edge.isVertical ? screen.visibleFrame.midY : screen.visibleFrame.midX
            }
            placed = true
        }
        if model.floating, freeCenter == nil {
            freeCenter = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        }
        let target: NSRect
        if model.floating, let freeCenter {
            target = floatingFrame(for: size, center: freeCenter)
        } else {
            target = frame(for: size, edge: model.edge, along: along, on: screen)
        }
        if animated {
            snapGeneration += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    /// When the window is taller or wider than the visible frame, pin it so
    /// the capsule stays on the docked edge instead of being pushed off-screen.
    private func clamp(_ origin: CGPoint, size: CGSize, to visible: NSRect, keepingCapsuleOn edge: DockEdge) -> CGPoint {
        var origin = origin
        if size.height >= visible.height - 0.5 {
            switch edge {
            case .top:
                origin.y = visible.maxY - size.height
            case .bottom:
                origin.y = visible.minY
            case .left, .right:
                origin.y = visible.midY - size.height / 2
            }
        } else {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        if size.width >= visible.width - 0.5 {
            switch edge {
            case .left:
                origin.x = visible.minX
            case .right:
                origin.x = visible.maxX - size.width
            case .top, .bottom:
                origin.x = visible.midX - size.width / 2
            }
        } else {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        return origin
    }

    private func frame(for size: CGSize, edge: DockEdge, along: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        var origin = CGPoint.zero
        switch edge {
        case .right:
            origin.x = visible.maxX - size.width
            origin.y = along - size.height / 2
        case .left:
            origin.x = visible.minX
            origin.y = along - size.height / 2
        case .top:
            origin.y = visible.maxY - size.height
            origin.x = along - size.width / 2
        case .bottom:
            origin.y = visible.minY
            origin.x = along - size.width / 2
        }
        origin = clamp(origin, size: size, to: visible, keepingCapsuleOn: edge)
        return NSRect(origin: origin, size: size)
    }

    /// Center of the capsule, not the whole window, so an open card does not shift the anchor.
    private func capsuleCenter() -> NSPoint {
        let frame = panel.frame
        switch model.edge {
        case .right:
            return NSPoint(x: frame.maxX - Metrics.thickness / 2, y: frame.midY)
        case .left:
            return NSPoint(x: frame.minX + Metrics.thickness / 2, y: frame.midY)
        case .top:
            return NSPoint(x: frame.midX, y: frame.maxY - Metrics.thickness / 2)
        case .bottom:
            return NSPoint(x: frame.midX, y: frame.minY + Metrics.thickness / 2)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    /// Rejects the placeholder window frame. The capsule's short side stays near `thickness`
    /// until a card is attached, and the long side is the stack of controls.
    private func looksLikeChrome(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite else { return false }
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        guard long > 120, long < 2600, short > 20, short < 1200 else { return false }
        if model.card == nil {
            return abs(short - Metrics.thickness) < 12
        }
        return short + 0.5 >= Metrics.thickness - 8
    }

    private func fallbackSize() -> CGSize {
        let capsule = model.edge.isVertical
            ? CGSize(width: Metrics.thickness, height: 720)
            : CGSize(width: 720, height: Metrics.thickness)
        guard model.card != nil else { return capsule }
        switch model.edge {
        case .left, .right:
            return CGSize(width: capsule.width + Metrics.cardGap + Metrics.cardWidth, height: max(capsule.height, 720))
        case .top, .bottom:
            return CGSize(width: max(capsule.width, Metrics.cardWidth), height: capsule.height + Metrics.cardGap + 640)
        }
    }

    private enum Keys {
        static let along = "ljm.along"
        static let edge = "ljm.edge"
        static let floating = "ljm.floating"
        static let freeX = "ljm.freeX"
        static let freeY = "ljm.freeY"
    }
}

extension NSView {
    /// `hitTest(_:)` takes a point in the superview's coordinates. Use this
    /// when the point is already in this view's own coordinate space.
    func hitTestInLocalCoordinates(_ pointInSelf: NSPoint) -> NSView? {
        hitTest(convert(pointInSelf, to: superview))
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The move handle must keep receiving mouseDown even if a nearby button
    /// is mid-lift or a hosting subview has a leftover layer. Prefer the
    /// handle whenever the point is inside its bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space, not this view's.
        if let handle = ChromePointer.handle(in: self) {
            let local = handle.convert(point, from: superview)
            if handle.bounds.contains(local) {
                return handle
            }
        }
        return super.hitTest(point)
    }
}
