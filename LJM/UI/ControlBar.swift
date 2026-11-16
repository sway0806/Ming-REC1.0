import AppKit
import SwiftUI

struct ControlChrome: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.edge {
            case .right:
                HStack(alignment: .center, spacing: Metrics.cardGap) {
                    if model.card != nil { SideCard() }
                    capsule(vertical: true)
                }
            case .left:
                HStack(alignment: .center, spacing: Metrics.cardGap) {
                    capsule(vertical: true)
                    if model.card != nil { SideCard() }
                }
            case .top:
                VStack(alignment: .center, spacing: Metrics.cardGap) {
                    capsule(vertical: false)
                    if model.card != nil { SideCard() }
                }
            case .bottom:
                VStack(alignment: .center, spacing: Metrics.cardGap) {
                    if model.card != nil { SideCard() }
                    capsule(vertical: false)
                }
            }
        }
        .fixedSize()
        .background(alignment: .topLeading) {
            GeometryReader { proxy in
                Color.clear.preference(key: ChromeSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(ChromeSizeKey.self) { size in
            model.noteChromeSize(size)
        }
        .onAppear { model.bumpLayout() }
        .onChange(of: model.edge) { _, _ in model.bumpLayout() }
        .onChange(of: model.card) { _, _ in model.bumpLayout() }
    }

    private func capsule(vertical: Bool) -> some View {
        BarLayout(vertical: vertical) {
            handle(vertical: vertical)
                .zIndex(10)
            gap(Metrics.handleGap, vertical: vertical)
            logo
            gap(Metrics.blockGap, vertical: vertical)
            divider(vertical: vertical)
            gap(Metrics.blockGap, vertical: vertical)
            sourceButton(
                systemName: model.region == nil ? "display" : "viewfinder",
                active: true,
                help: model.sourceHelp,
                label: model.sourceLabel
            ) { model.showSource() }
            gap(Metrics.iconGap, vertical: vertical)
            sourceButton(
                systemName: model.cameraOn ? "video" : "video.slash",
                active: model.cameraOn,
                help: model.cameraHelp,
                label: model.cameraLabel,
                showsBadge: model.cameraOn
            ) { model.toggleCamera() }
            gap(Metrics.iconGap, vertical: vertical)
            sourceButton(
                systemName: model.systemAudioEnabled ? "speaker.wave.2" : "speaker.slash",
                active: model.systemAudioEnabled,
                help: model.systemAudioEnabled ? "系统声音：开" : "系统声音：关",
                label: model.systemAudioEnabled ? "关闭系统声音" : "打开系统声音",
                showsBadge: model.systemAudioEnabled
            ) { model.toggleSystemAudio() }
            gap(Metrics.iconGap, vertical: vertical)
            sourceButton(
                systemName: model.microphoneEnabled ? "mic" : "mic.slash",
                active: model.microphoneEnabled,
                help: model.microphoneHelp,
                label: model.microphoneLabel,
                showsBadge: model.microphoneEnabled
            ) { model.toggleMicrophone() }
            gap(Metrics.blockGap, vertical: vertical)
            divider(vertical: vertical)
            gap(Metrics.blockGap, vertical: vertical)
            RecordButton()
            if model.showsElapsed {
                gap(Metrics.s(10), vertical: vertical)
                elapsedLabel(vertical: vertical)
            }
            if !model.showsElapsed, model.zoomProgress != nil {
                gap(Metrics.s(10), vertical: vertical)
                zoomProgressLabel(vertical: vertical)
            }
            if !model.showsElapsed, model.zoomProgress == nil {
                gap(Metrics.s(10), vertical: vertical)
                readyLabel(vertical: vertical)
            }
            gap(Metrics.blockGap, vertical: vertical)
            divider(vertical: vertical)
            gap(Metrics.blockGap, vertical: vertical)
            utilityButton(systemName: "ellipsis", help: "更多", label: "更多") { model.showMore() }
            gap(Metrics.utilGap, vertical: vertical)
            utilityButton(systemName: "gearshape", help: "保存位置", label: "设置") { model.showSettings() }
        }
        .padding(vertical ? .vertical : .horizontal, Metrics.pad)
        .frame(
            width: vertical ? Metrics.thickness : nil,
            height: vertical ? nil : Metrics.thickness
        )
        .background(WindowDragArea().contentShape(Rectangle()))
        .background(
            LinearGradient(
                colors: [Theme.barTop, Theme.barBottom],
                startPoint: vertical ? .top : .leading,
                endPoint: vertical ? .bottom : .trailing
            )
            .allowsHitTesting(false)
        )
        .clipShape(Capsule())
        .overlay(alignment: vertical ? .top : .leading) {
            // t234: pad + ridges at this end of the capsule, full thickness,
            // so the top 横线 area is a real drag / double-click target again.
            let hit = vertical
                ? CGSize(width: Metrics.thickness, height: Metrics.pad + Metrics.wordmarkHeight)
                : CGSize(width: Metrics.pad + Metrics.wordmarkWidth, height: Metrics.thickness)
            HandleDragArea(size: hit)
                .frame(width: hit.width, height: hit.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("拖动控制条")
                .accessibilityHint("按住并拖动，把控制条移到屏幕四边")
                .accessibilityAddTraits(.isButton)
        }
        .overlay {
            // Thin light rim around the whole body: brightest along the top.
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.rimTop.opacity(1.1), Color.white.opacity(0.16), Color.white.opacity(0.26)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(Metrics.s(1.2), 1)
                )
                .allowsHitTesting(false)
        }
        .overlay {
            Capsule()
                .inset(by: max(Metrics.s(1.2), 1))
                .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("小名 录制控制")
        // Metrics are read at body time; rebuild the bar when the docked
        // mini scale changes so every size (and AppKit hit view) follows.
        .id(model.miniDock)
    }

    private var logo: some View {
        GMark()
            .frame(width: Metrics.logo, height: Metrics.logo)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func handle(vertical: Bool) -> some View {
        // Two glowing ridges (t229). Upright on the horizontal bar, lying flat
        // on the vertical bar. The drag target is the capsule overlay in
        // capsule(vertical:), covering this end's padding plus the ridges.
        Image(nsImage: Theme.glowRidges)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: Metrics.wordmarkWidth, height: Metrics.wordmarkHeight)
            .rotationEffect(.degrees(vertical ? 0 : 90))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func divider(vertical: Bool) -> some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(
                width: vertical ? Metrics.dividerLong : Metrics.dividerShort,
                height: vertical ? Metrics.dividerShort : Metrics.dividerLong
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func gap(_ length: CGFloat, vertical: Bool) -> some View {
        Color.clear
            .frame(width: vertical ? 1 : length, height: vertical ? length : 1)
            .allowsHitTesting(false)
    }

    /// Shown while the 自动缩放 version renders after a take.
    private func zoomProgressLabel(vertical: Bool) -> some View {
        VStack(spacing: 1) {
            Text("缩放")
                .font(.system(size: Metrics.captionSmall, weight: .semibold))
            Text(model.zoomProgressLabel)
                .font(.system(size: Metrics.caption, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(Theme.orange)
        .frame(width: vertical ? Metrics.source : Metrics.captionWidthHorizontal, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityLabel("正在生成自动缩放版 \(model.zoomProgressLabel)")
    }

    private func readyLabel(vertical: Bool) -> some View {
        Text("就绪")
            .font(.system(size: Metrics.caption, weight: .medium))
            .foregroundStyle(Theme.ready)
            .frame(width: vertical ? Metrics.source : Metrics.captionWidthHorizontal, alignment: .center)
            .allowsHitTesting(false)
            .accessibilityLabel("就绪")
    }

    private func elapsedLabel(vertical: Bool) -> some View {
        Text(model.elapsedLabel)
            .font(.system(size: Metrics.caption, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(model.paused ? Theme.orange : Theme.ink)
            .opacity(model.paused ? 0.75 : 1)
            .frame(width: vertical ? Metrics.source : Metrics.captionWidthHorizontal, alignment: .center)
            .allowsHitTesting(false)
            .accessibilityLabel(model.paused ? "已暂停 \(model.elapsedLabel)" : "已录制 \(model.elapsedLabel)")
    }

    private func sourceButton(
        systemName: String,
        active: Bool,
        help: String,
        label: String,
        showsBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        CircleIconButton(
            systemName: systemName,
            active: active,
            diameter: Metrics.source,
            pointSize: Metrics.glyphSource,
            showsBadge: showsBadge,
            help: help,
            label: label,
            action: action
        )
    }

    private func utilityButton(
        systemName: String,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        CircleIconButton(
            systemName: systemName,
            active: false,
            diameter: Metrics.utility,
            pointSize: Metrics.glyphUtility,
            showsBadge: false,
            help: help,
            label: label,
            action: action
        )
    }
}

struct ChromeSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Raised dark disc: a faint gloss on top, a thin rim light that is bright on the
/// upper edge and fades downward, and a soft black shadow so it floats off the bar.
struct FloatingDisc: ViewModifier {
    var prominent: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(prominent ? 0.22 : 0.08),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: UnitPoint(x: 0.5, y: 0),
                            endPoint: UnitPoint(x: 0.5, y: 0.55)
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Theme.rimTop,
                                Theme.rimMid,
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Theme.liftShadow.opacity(prominent ? 0.55 : 0.45),
                radius: Metrics.s(prominent ? 8 : 5),
                x: 0,
                y: Metrics.s(prominent ? 5 : 3)
            )
            .shadow(color: Theme.liftShadow.opacity(0.30), radius: Metrics.s(1.2), x: 0, y: Metrics.s(1))
    }
}

extension View {
    func floatingDisc(prominent: Bool = false) -> some View {
        modifier(FloatingDisc(prominent: prominent))
    }
}

struct CircleIconButton: View {
    var systemName: String
    var active: Bool
    var diameter: CGFloat
    var pointSize: CGFloat
    var showsBadge: Bool
    var help: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: active ? [Theme.discOnTop, Theme.discOnBottom] : [Theme.discTop, Theme.discBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                Image(systemName: systemName)
                    .font(.system(size: pointSize, weight: .regular))
                    .foregroundStyle(active ? Theme.glyph : Theme.glyphOff)
                    .symbolRenderingMode(.monochrome)
                if showsBadge {
                    Circle()
                        .fill(Theme.onDot)
                        .frame(width: Metrics.s(8), height: Metrics.s(8))
                        .shadow(color: Theme.onDot.opacity(0.6), radius: Metrics.s(2), x: 0, y: 0)
                        .offset(x: diameter * 0.30, y: diameter * 0.26)
                }
            }
            .frame(width: diameter, height: diameter)
            .floatingDisc()
            .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(label)
    }
}

struct RecordButton: View {
    @EnvironmentObject private var model: AppModel

    private var isStop: Bool {
        model.phase == .recording || model.phase == .stopping
    }

    var body: some View {
        Button(action: model.toggleRecord) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.recordTop, Theme.recordBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(model.phase == .starting ? 0.55 : 1)
                if isStop {
                    RoundedRectangle(cornerRadius: Metrics.s(5), style: .continuous)
                        .fill(Color.white)
                        .frame(width: Metrics.s(20), height: Metrics.s(20))
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: Metrics.recordHole, height: Metrics.recordHole)
                        .shadow(color: Color.black.opacity(0.25), radius: Metrics.s(1.5), x: 0, y: Metrics.s(1))
                }
            }
            .frame(width: Metrics.record, height: Metrics.record)
            .floatingDisc(prominent: true)
            .background {
                // Outer ring with a faint red-orange glow; drawn outside the layout frame.
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Theme.recordBottom.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .padding(-Metrics.s(6))
                    .shadow(color: Theme.recordBottom.opacity(0.35), radius: Metrics.s(6), x: 0, y: 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
        .focusEffectDisabled()
        .disabled(model.phase == .stopping)
        .help(isStop ? "停止并保存" : "开始录制")
        .accessibilityLabel(isStop ? "停止录制" : "开始录制")
        .accessibilityValue(model.showsElapsed ? model.elapsedLabel : "")
    }
}

/// The "G" mark: black rounded tile, geometric white G drawn from paths (not a
/// system font), with a brand-orange gradient crossbar and a small orange full stop.
struct GMark: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side * 0.25
            let line = side * 0.13
            let c = CGPoint(x: geo.size.width / 2 - side * 0.03, y: geo.size.height / 2)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.logoTop, Theme.logoBottom], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.9
                    )
                GArc(center: c, radius: r)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .butt, lineJoin: .miter))
                Rectangle()
                    .fill(LinearGradient(colors: [Theme.orangeLight, Theme.orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: r + line / 2 - side * 0.02, height: line)
                    .position(x: c.x + side * 0.02 + (r + line / 2 - side * 0.02) / 2, y: c.y)
                Circle()
                    .fill(Theme.orange)
                    .frame(width: line * 0.95, height: line * 0.95)
                    .position(x: c.x + r + line * 1.25, y: c.y + r + line * 0.02)
            }
        }
        .shadow(color: Color.black.opacity(0.5), radius: Metrics.s(5), x: 0, y: Metrics.s(3))
    }
}

/// Open circular arc for the G: from the upper-right (−45°) round through the top,
/// left and bottom to the right-hand midline. Built from points so the direction
/// does not depend on SwiftUI's flipped-axis arc convention.
struct GArc: Shape {
    var center: CGPoint
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 105
        for i in 0...steps {
            let degrees = -45.0 - 315.0 * Double(i) / Double(steps)
            let t = degrees * Double.pi / 180
            let p = CGPoint(x: center.x + radius * CGFloat(cos(t)), y: center.y + radius * CGFloat(sin(t)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hoverLift(isPressed: configuration.isPressed)
    }
}

/// Subtle hover lift, a clearly visible press sink, and a pointing-hand cursor.
/// Tracking uses a pass-through AppKit view so it still works on a nonactivating
/// panel. Visual motion stays in SwiftUI (offset + shadow): hover rises 3pt,
/// press sinks 3.5pt below rest, release while still over the button returns
/// to the lifted state, and leaving returns to rest. Layer transforms are
/// intentionally not applied to hosting ancestors — `wantsLayer` + CATransform
/// on those views broke hit-testing after a few hovers, so the bar could no
/// longer be dragged. Disabled controls neither move nor change the cursor.
/// The move handle never lifts, and its open-hand cursor always wins.
final class HoverFlag: ObservableObject {
    @Published var hovering = false
}

struct HoverLiftModifier: ViewModifier {
    var isPressed: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hover = HoverFlag()

    private enum Motion: Equatable { case rest, lifted, pressed }

    private var motion: Motion {
        if !isEnabled { return .rest }
        if isPressed { return .pressed }
        if hover.hovering { return .lifted }
        return .rest
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(motion == .pressed ? 0.95 : 1)
            .offset(y: motion == .pressed ? 3.5 : (motion == .lifted ? -3 : 0))
            .shadow(
                color: Theme.liftShadow.opacity(motion == .lifted ? 0.40 : (motion == .pressed ? 0.18 : 0)),
                radius: motion == .lifted ? Metrics.s(6) : (motion == .pressed ? Metrics.s(1.2) : 0),
                x: 0,
                y: motion == .lifted ? Metrics.s(4) : (motion == .pressed ? Metrics.s(1) : 0)
            )
            .animation(.easeOut(duration: 0.14), value: motion)
            .overlay {
                PointingHandArea(enabled: isEnabled, hovering: $hover.hovering)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func hoverLift(isPressed: Bool = false) -> some View {
        modifier(HoverLiftModifier(isPressed: isPressed))
    }

    func pointingHandCursor() -> some View {
        hoverLift()
    }
}

struct PointingHandArea: NSViewRepresentable {
    var enabled: Bool
    @Binding var hovering: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(hovering: $hovering)
    }

    final class Coordinator {
        var hovering: Binding<Bool>
        init(hovering: Binding<Bool>) { self.hovering = hovering }
        func setHovering(_ value: Bool) {
            if hovering.wrappedValue != value {
                hovering.wrappedValue = value
            }
        }
    }

    func makeNSView(context: Context) -> PointingHandView {
        let view = PointingHandView()
        view.cursorEnabled = enabled
        view.onHoverChange = { context.coordinator.setHovering($0) }
        return view
    }

    func updateNSView(_ nsView: PointingHandView, context: Context) {
        context.coordinator.hovering = $hovering
        nsView.cursorEnabled = enabled
        nsView.onHoverChange = { context.coordinator.setHovering($0) }
        if !enabled, nsView.hovering {
            nsView.applyHover(false)
        }
        // Do not call ChromePointer.sync here: SwiftUI updates during a press
        // would re-enter the pointer router and can fight an in-flight drag.
    }
}

/// One place decides the pointer over the chrome, so the move handle's open
/// hand always wins over a button's pointing hand, leftover hover flags get
/// cleared on a missed mouseExited, and the cursor is not reset on every move.
enum ChromePointer {
    enum Motion: Equatable { case rest, lifted, pressed }

    static var handleDragging = false
    static var bodyDragging = false
    /// Double-click 横线 move mode: the bar follows the mouse.
    static var moveMode = false
    private static var monitor: Any?

    static func install(on window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        guard monitor == nil else { return }
        // Mouse-moved only. Down/up are left to the button and the drag
        // views' nextEvent loops so this monitor cannot swallow a mouseUp
        // or leave dragging flags set.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            if let window = event.window as? FloatingPanel {
                ChromePointer.sync(in: window)
            }
            return event
        }
    }

    static func sameCursor(_ lhs: NSCursor, _ rhs: NSCursor) -> Bool {
        lhs.image.tiffRepresentation == rhs.image.tiffRepresentation
    }

    static func setIfNeeded(_ cursor: NSCursor) {
        if !sameCursor(NSCursor.current, cursor) {
            cursor.set()
        }
    }

    static func handle(in root: NSView) -> HandleDragView? {
        if let handle = root as? HandleDragView { return handle }
        for child in root.subviews {
            if let found = handle(in: child) { return found }
        }
        return nil
    }

    static func bodyDrag(in root: NSView) -> DragView? {
        if let body = root as? DragView, body.stadium { return body }
        for child in root.subviews {
            if let found = bodyDrag(in: child) { return found }
        }
        return nil
    }

    static func allHands(in root: NSView) -> [PointingHandView] {
        var found: [PointingHandView] = []
        func walk(_ current: NSView) {
            if let hand = current as? PointingHandView {
                found.append(hand)
            }
            for child in current.subviews { walk(child) }
        }
        walk(root)
        return found
    }

    static func containsMouse(_ view: NSView, windowLocation loc: NSPoint) -> Bool {
        let point = view.convert(loc, from: nil)
        return view.bounds.contains(point)
    }

    static func bestHand(in root: NSView, windowLocation loc: NSPoint) -> PointingHandView? {
        var best: PointingHandView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for hand in allHands(in: root) {
            let inside = hand.cursorEnabled
                && hand.bounds.width >= 8
                && hand.bounds.height >= 8
                && containsMouse(hand, windowLocation: loc)
            if inside {
                let area = hand.bounds.width * hand.bounds.height
                if area < bestArea {
                    best = hand
                    bestArea = area
                }
            }
        }
        return best
    }

    static func sync(in window: NSWindow) {
        if handleDragging || bodyDragging || moveMode {
            HandleMotion.shared.set(handleDragging || moveMode ? .pressed : .rest)
            setIfNeeded(NSCursor.closedHand)
            return
        }
        guard let root = window.contentView else { return }
        let loc = window.mouseLocationOutsideOfEventStream
        if let handle = handle(in: root), containsMouse(handle, windowLocation: loc) {
            for hand in allHands(in: root) {
                hand.applyHover(false)
                hand.lastMotion = .rest
            }
            HandleMotion.shared.set(.lifted)
            setIfNeeded(NSCursor.openHand)
            return
        }
        HandleMotion.shared.set(.rest)
        let hands = allHands(in: root)
        let best = bestHand(in: root, windowLocation: loc)
        for hand in hands {
            let hovering = (hand === best)
            hand.applyHover(hovering)
            hand.lastMotion = hovering ? .lifted : .rest
        }
        if best != nil {
            setIfNeeded(NSCursor.pointingHand)
        } else {
            setIfNeeded(NSCursor.arrow)
        }
    }
}

/// Hits pass through to the SwiftUI button underneath. Only the tracking area
/// is used, so this never covers the move handle or steals clicks.
final class PointingHandView: NSView {
    var cursorEnabled = true
    var onHoverChange: ((Bool) -> Void)?
    private(set) var hovering = false {
        didSet {
            if oldValue != hovering {
                onHoverChange?(hovering)
            }
        }
    }
    var lastMotion: ChromePointer.Motion = .rest
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyHover(_ value: Bool) {
        hovering = value
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            ChromePointer.install(on: window)
        }
        refreshTracking()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func cursorUpdate(with event: NSEvent) {
        if let window { ChromePointer.sync(in: window) }
    }

    override func mouseEntered(with event: NSEvent) {
        if let window { ChromePointer.sync(in: window) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let window { ChromePointer.sync(in: window) }
    }

    override func mouseExited(with event: NSEvent) {
        if let window { ChromePointer.sync(in: window) }
    }

    private func refreshTracking() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }
}


/// Hover / press state for the move handle's ridges. Driven by ChromePointer
/// (which HandleDragView's tracking area calls), so it works on the
/// nonactivating panel. Only the SwiftUI ridge visuals move; the
/// HandleDragView hit target never moves or transforms.
final class HandleMotion: ObservableObject {
    static let shared = HandleMotion()
    @Published var state: ChromePointer.Motion = .rest

    func set(_ next: ChromePointer.Motion) {
        if state != next { state = next }
    }
}

struct HandleRidges: View {
    var vertical: Bool
    @ObservedObject private var motion = HandleMotion.shared

    var body: some View {
        let state = motion.state
        Group {
            if vertical {
                VStack(spacing: Metrics.handleRidgeGap) {
                    ridge(width: Metrics.handleLong, height: Metrics.handleShort, verticalBar: true, state: state)
                    ridge(width: Metrics.handleLong, height: Metrics.handleShort, verticalBar: true, state: state)
                }
            } else {
                HStack(spacing: Metrics.handleRidgeGap) {
                    ridge(width: Metrics.handleShort, height: Metrics.handleLong, verticalBar: false, state: state)
                    ridge(width: Metrics.handleShort, height: Metrics.handleLong, verticalBar: false, state: state)
                }
            }
        }
        .offset(y: state == .pressed ? 3.5 : (state == .lifted ? -3 : 0))
        .shadow(
            color: Theme.liftShadow.opacity(state == .lifted ? 0.40 : (state == .pressed ? 0.18 : 0)),
            radius: state == .lifted ? Metrics.s(6) : (state == .pressed ? Metrics.s(1.2) : 0),
            x: 0,
            y: state == .lifted ? Metrics.s(4) : (state == .pressed ? Metrics.s(1) : 0)
        )
        .animation(.easeOut(duration: 0.14), value: state)
    }

    private func ridge(width: CGFloat, height: CGFloat, verticalBar: Bool, state: ChromePointer.Motion) -> some View {
        let start: UnitPoint = verticalBar ? .top : .leading
        let end: UnitPoint = verticalBar ? .bottom : .trailing
        let lifted = state == .lifted
        return Capsule()
            .fill(
                LinearGradient(
                    colors: [Theme.handleHighlight, Theme.handle, Theme.handleShade],
                    startPoint: start,
                    endPoint: end
                )
            )
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(lifted ? 0.12 : 0))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(lifted ? 0.55 : 0.35), lineWidth: 0.6)
            }
            .shadow(color: Theme.liftShadow.opacity(0.45), radius: Metrics.s(1.1), x: 0, y: Metrics.s(1))
            .frame(width: width, height: height)
    }
}

struct HandlePill: View {
    @ObservedObject private var motion = HandleMotion.shared

    var body: some View {
        let lifted = motion.state == .lifted
        Capsule()
            .fill(Theme.handlePill)
            .overlay {
                Capsule().fill(Color.white.opacity(lifted ? 0.035 : 0))
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(lifted ? 0.34 : 0.26), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
            .animation(.easeOut(duration: 0.14), value: motion.state)
    }
}

/// Dedicated hit target for the two-ridge drag handle.
/// Hover shows the system open-hand cursor; press-and-drag shows the closed-hand grab cursor.
struct HandleDragArea: NSViewRepresentable {
    var size: CGSize

    func makeNSView(context: Context) -> HandleDragView {
        let view = HandleDragView()
        view.expectedSize = size
        return view
    }

    func updateNSView(_ nsView: HandleDragView, context: Context) {
        nsView.expectedSize = size
        if nsView.bounds.size != size, size.width > 0, size.height > 0 {
            nsView.setFrameSize(size)
        }
    }
}

final class HandleDragView: NSView {
    var expectedSize: NSSize = .zero {
        didSet {
            if oldValue != expectedSize {
                invalidateIntrinsicContentSize()
            }
        }
    }

    private var tracking: NSTrackingArea?
    private var hovering = false
    private var dragging = false

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize {
        expectedSize.width > 0 && expectedSize.height > 0 ? expectedSize : super.intrinsicContentSize
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Nonactivating panels ignore cursor rects unless they also see mouse-moved events.
        if let window {
            ChromePointer.install(on: window)
        }
        refreshTracking()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        // A non-opaque panel lets clicks fall through pixels below the
        // window-server alpha threshold. The glow ridges are mostly
        // transparent, so paint a 1% fill to keep this end hittable.
        NSColor(white: 1, alpha: 0.01).setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest's point is in the superview's coordinate space.
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        // Kept as a fallback when the panel happens to be key; the tracking-area
        // path below is what works on a nonactivating float.
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func cursorUpdate(with event: NSEvent) {
        if !dragging, let window { ChromePointer.sync(in: window) }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !dragging, let window { ChromePointer.sync(in: window) }
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = true
        if !dragging, let window { ChromePointer.sync(in: window) }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging, let window { ChromePointer.sync(in: window) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // t194: double-click 横线 = pick the bar up; it follows the mouse until
        // the next single click. The first click of the pair already ran (and
        // finished) a normal press-drag below, so this cannot hijack a drag.
        if event.clickCount >= 2, let panel = window as? FloatingPanel {
            panel.requestMoveMode()
            return
        }
        let startOrigin = window.frame.origin
        let startMouse = NSEvent.mouseLocation
        var dragged = false
        dragging = true
        ChromePointer.handleDragging = true
        HandleMotion.shared.set(.pressed)
        (window as? FloatingPanel)?.dragDidStart()
        NSCursor.closedHand.push()
        NSCursor.closedHand.set()
        defer {
            NSCursor.pop()
            dragging = false
            ChromePointer.handleDragging = false
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovering = bounds.contains(point)
            ChromePointer.sync(in: window)
            (window as? FloatingPanel)?.dragDidEnd(moved: dragged)
        }
        dragged = PanelDragLoop.run(window: window, from: startOrigin, startMouse: startMouse)
    }

    private func refreshTracking() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }
}

/// Stacks children on the vertical or horizontal axis without introducing its own spacing.
struct BarLayout: Layout {
    var vertical: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if vertical {
            return CGSize(
                width: sizes.map(\.width).max() ?? 0,
                height: sizes.reduce(0) { $0 + $1.height }
            )
        }
        return CGSize(
            width: sizes.reduce(0) { $0 + $1.width },
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursor = vertical ? bounds.minY : bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if vertical {
                let x = bounds.midX - size.width / 2
                subview.place(
                    at: CGPoint(x: x, y: cursor),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                cursor += size.height
            } else {
                let y = bounds.midY - size.height / 2
                subview.place(
                    at: CGPoint(x: cursor, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                cursor += size.width
            }
        }
    }
}

#if DEBUG
struct ControlChrome_Previews: PreviewProvider {
    static var previews: some View {
        ControlChrome()
            .environmentObject(AppModel())
            .padding(32)
            .background(Color(red: 0.988, green: 0.949, blue: 0.918))
    }
}
#endif
