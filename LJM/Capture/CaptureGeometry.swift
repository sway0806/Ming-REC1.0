import CoreGraphics
import Foundation

enum CaptureGeometry {
    /// Selection uses AppKit's bottom-left global coordinates.
    /// ScreenCaptureKit's `sourceRect` uses top-left points relative to the display,
    /// which is how left-of-main (negative origin) screens stay correct.
    static func sourceRect(selectionInScreen: CGRect, screenFrame: CGRect) -> CGRect {
        let clipped = selectionInScreen.intersection(screenFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return .zero }
        return CGRect(
            x: clipped.minX - screenFrame.minX,
            y: screenFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    /// Never upscales a smaller display or region. H.264 needs even dimensions.
    static func outputSize(points: CGSize, scale: CGFloat, maxSide: Int) -> (width: Int, height: Int, scaled: Bool) {
        let nativeW = points.width * scale
        let nativeH = points.height * scale
        guard nativeW > 1, nativeH > 1 else { return (2, 2, true) }
        let cap = CGFloat(max(2, maxSide))
        let ratio = min(1, cap / max(nativeW, nativeH))
        let width = max(2, Int(floor(nativeW * ratio / 2)) * 2)
        let height = max(2, Int(floor(nativeH * ratio / 2)) * 2)
        let evenNativeW = max(2, Int(floor(nativeW / 2)) * 2)
        let evenNativeH = max(2, Int(floor(nativeH / 2)) * 2)
        let scaled = width != evenNativeW || height != evenNativeH
        return (width, height, scaled)
    }

    /// mm:ss, even past one hour (e.g. 83:12), updated by a 1 Hz timer only.
    static func elapsedLabel(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// `00:00:13` for the in-recording compact bar and the review list.
    static func elapsedHMS(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let remainder = value % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }
}
