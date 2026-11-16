import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Screen Recording covers the display and ScreenCaptureKit system audio.
/// Microphone and camera use their own TCC prompts, requested only when the user turns them on.
enum Permissions {
    static func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Adds 小名 to the Screen Recording list and shows the system prompt when macOS still will.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain,
           ns.code == SCStreamError.Code.userDeclined.rawValue {
            return true
        }
        // CGPreflightScreenCaptureAccess is often false even after the
        // user has already allowed Screen Recording (especially with an
        // ad-hoc signature), so it is not used as a fallback here.
        let text = (ns.localizedDescription + " " + (ns.localizedFailureReason ?? "")).lowercased()
        return text.contains("declin")
            || text.contains("not authorized")
            || text.contains("not permitted")
            || text.contains("未授权")
            || text.contains("拒绝")
    }

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func cameraAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Tries the current System Settings URL, then the Ventura-era one.
    static func openScreenRecordingSettings() {
        openPrivacySettings("Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        openPrivacySettings("Privacy_Microphone")
    }

    static func openCameraSettings() {
        openPrivacySettings("Privacy_Camera")
    }

    private static func openPrivacySettings(_ pane: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
