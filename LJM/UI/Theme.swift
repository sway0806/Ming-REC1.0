import AppKit
import SwiftUI

/// Graphite control bar ("G" edition). Approved mock: dark body with a thin light rim,
/// dark discs whose top edge catches a faint highlight, red-orange record key.
/// Side cards share the same palette so the bar and its cards read as one object.
enum Theme {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// Side-card fill (graphite).
    static let surface = rgb(44, 45, 49)
    /// Bar body gradient, top to bottom.
    static let barTop = rgb(58, 59, 64)
    static let barBottom = rgb(36, 37, 41)
    /// Brand orange #FC6B10 — G accent, prominent card buttons, progress text.
    static let orange = rgb(252, 107, 16)
    /// Warm highlight end of the orange accent gradient.
    static let orangeLight = rgb(255, 176, 92)
    /// Record key: red-orange gradient.
    static let recordTop = rgb(255, 106, 60)
    static let recordBottom = rgb(226, 50, 30)
    /// Card buttons: selected / normal.
    static let peach = rgb(74, 75, 82)
    static let beige = rgb(58, 59, 65)
    /// Bar discs: idle and switched-on (a touch brighter).
    static let discTop = rgb(70, 71, 77)
    static let discBottom = rgb(45, 46, 51)
    static let discOnTop = rgb(86, 87, 94)
    static let discOnBottom = rgb(56, 57, 63)
    /// Glyph colours on discs.
    static let glyph = rgb(226, 227, 231)
    static let glyphOff = rgb(170, 171, 177)
    /// "On" status dot.
    static let onDot = rgb(52, 199, 89)
    /// Drag-handle pill and ridges.
    static let handlePill = rgb(30, 31, 35)
    static let handleHighlight = rgb(222, 223, 228)
    static let handle = rgb(178, 179, 185)
    static let handleShade = rgb(138, 139, 145)
    /// Short hairline between groups.
    static let hairline = Color.white.opacity(0.10)
    /// Light text on graphite (cards, timer).
    static let ink = rgb(236, 237, 241)
    static let inkSoft = rgb(236, 237, 241).opacity(0.66)
    /// "就绪" caption.
    static let ready = rgb(160, 161, 167)
    /// Thin card / field border.
    static let edge = Color.white.opacity(0.14)
    /// Rim light: bright on the top edge, fading downward.
    static let rimTop = Color.white.opacity(0.50)
    static let rimMid = Color.white.opacity(0.10)
    /// Shadow under floating discs (neutral black on graphite).
    static let liftShadow = Color.black
    /// G tile.
    static let logoTop = rgb(26, 26, 29)
    static let logoBottom = rgb(9, 9, 11)

    /// Bundled 84-point seamless 宣纸帘纹 tile. Loaded once, then drawn with a cheap tiled blit.
    static let xuanPaper: NSImage = {
        if let image = NSImage(named: "XuanPaper") {
            return image
        }
        let fallback = NSImage(size: NSSize(width: 84, height: 84))
        fallback.lockFocus()
        NSColor(red: 231 / 255, green: 241 / 255, blue: 250 / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 84, height: 84).fill()
        fallback.unlockFocus()
        fallback.isTemplate = false
        return fallback
    }()

    /// Two glowing ivory ridges (t229). Bundled square PNG, 1x/2x/3x.
    /// Drawn horizontal; rotated upright on the horizontal bar.
    static let glowRidges: NSImage = {
        if let image = NSImage(named: "GlowRidges") {
            return image
        }
        return NSImage(size: NSSize(width: 40, height: 40))
    }()
}

/// Static 宣纸 fill for the control bar. Laid lines run along the long axis.
/// Tiled from a bundled image — no animation, no Core Image, no per-frame work.
struct XuanPaperFill: View {
    var vertical: Bool

    var body: some View {
        GeometryReader { geo in
            let short = vertical ? geo.size.width : geo.size.height
            let long = vertical ? geo.size.height : geo.size.width
            Image(nsImage: Theme.xuanPaper)
                .resizable(resizingMode: .tile)
                .frame(width: short, height: long)
                .rotationEffect(vertical ? .zero : .degrees(90))
                .frame(width: geo.size.width, height: geo.size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum Metrics {
    /// One knob for the whole control bar's size (t177: 整体缩小 30%). Cards are not scaled.
    static let baseScale: CGFloat = 0.7
    /// 1 when floating; 0.5 when docked to a screen edge (t194: 靠近边缘再缩小 50%).
    static var dockFactor: CGFloat = 1
    static var isMini: Bool { dockFactor < 0.99 }
    static var scale: CGFloat { baseScale * dockFactor }
    /// Scales a design-time point value (designed at 1.0).
    static func s(_ value: CGFloat) -> CGFloat { value * scale }
    /// Minimum hit size for anything clickable on the bar, so it stays easy to hit.
    /// The docked mini bar allows a slightly smaller floor so it really is half size.
    static var minHit: CGFloat { isMini ? 20 : 28 }

    /// Short side of the capsule, in points (100 × scale).
    static var thickness: CGFloat { s(100) }
    static var pad: CGFloat { s(20) }
    static var handleGap: CGFloat { s(12) }
    static var blockGap: CGFloat { s(16) }
    static var iconGap: CGFloat { s(12) }
    static var utilGap: CGFloat { s(14) }

    static var logo: CGFloat { s(52) }
    static var source: CGFloat { max(s(64), minHit) }
    static var utility: CGFloat { max(s(52), minHit) }
    static var record: CGFloat { max(s(72), minHit) }
    /// Inner dot of the idle record key.
    static var recordHole: CGFloat { s(26) }
    /// Length of each drag-handle ridge, along the bar's short axis.
    static var handleLong: CGFloat { s(46) }
    /// Thickness of one ridge. Two ridges plus the gap between them are easier to aim than a single hairline.
    static var handleShort: CGFloat { max(s(7), 2) }
    /// Air between the two parallel ridges.
    static var handleRidgeGap: CGFloat { max(s(7), 2) }
    /// Hit target for the drag handle, larger than the visible ridges; never below minHit.
    static var handleHit: CGFloat { max(s(48), minHit) }
    /// Length of the dark pill along the bar's short axis (across the ridges).
    static var handlePillAcross: CGFloat { handleLong + s(16) }
    /// Thickness of the dark pill along the bar (padding above and below the ridges).
    static var handlePillAlong: CGFloat {
        let visual = handleShort * 2 + handleRidgeGap
        return max(handleHit, visual + s(16))
    }
    /// Size of the visible handle pill (and its drag hit view) for a vertical bar.
    /// Swap width/height for a horizontal bar.
    static var handlePillSize: CGSize { CGSize(width: handlePillAcross, height: handlePillAlong) }
    /// Frameless Ming signature, including a little relief-shadow padding.
    /// Letter ink is about 15% smaller than the approved mock (t220).
    static var wordmarkWidth: CGFloat { s(57) }
    static var wordmarkHeight: CGFloat { s(57) }
    static var dividerLong: CGFloat { s(46) }
    static let dividerShort: CGFloat = 1

    static var glyphSource: CGFloat { s(30) }
    static var glyphUtility: CGFloat { s(22) }
    /// Caption under the record key (就绪 / timer), and the small 缩放 label.
    /// 就绪 and the recording timer: never smaller than 9 pt (t178), except in the
    /// explicitly requested docked mini bar.
    static var caption: CGFloat { max(s(11), isMini ? 6.5 : 9) }
    static var captionSmall: CGFloat { max(s(9), isMini ? 5.5 : 0) }
    static var captionWidthHorizontal: CGFloat { s(44) }

    // Side cards keep their full size.
    static let cardWidth: CGFloat = 280
    static let cardGap: CGFloat = 12
}

enum DockEdge: String, Equatable {
    case left, right, top, bottom

    var isVertical: Bool {
        switch self {
        case .left, .right: return true
        case .top, .bottom: return false
        }
    }
}
