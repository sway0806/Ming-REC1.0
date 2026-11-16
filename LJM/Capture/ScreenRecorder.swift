import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// Capture of a chosen display or region, optionally mixed with system audio and microphone.
///
/// Sample buffers are handled only on `sampleQueue`. `AVAssetWriter` is not thread-safe,
/// so the writer is created, appended, and finished on that queue. `start` / `stop` are
/// safe to call from the main actor; `stop` can be called more than once and finalizes once.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let log = Logger(subsystem: "dev.ljm.recorder", category: "capture")
    private let sampleQueue = DispatchQueue(label: "dev.ljm.recorder.samples", qos: .userInitiated)
    private let stateLock = NSLock()

    /// Remembered for the rest of this process launch so a 420v failure
    /// does not loop on every take (or mid-take self-test retry).
    private static var preferBGRAPixelFormat = false

    private var acceptSamples = false
    private var stream: SCStream?
    private var writer: MovieWriter?
    private var access: SaveLocation.Access?
    private var paths: SaveLocation.RecordingPaths?
    private var capturesAudio = false
    private var capturesMicrophone = false
    private var lastSystemAudio = false
    private var lastMicrophone = false
    private var lastCameraWindowID: Int?
    /// 小名's own recordable overlays (cursor halo / click ripples / watermark).
    private var lastOverlayWindowIDs: [Int] = []
    private var audioFellBack = false
    private var microphoneFellBack = false
    private var usesBGRAPixelFormat = false
    private var pixelFormatFallbackStarted = false
    private var fallbackTask: Task<Void, Never>?
    private var stopTask: Task<StopResult, Never>?
    private var failurePosted = false
    private var captureStarted = false
    private var watchdog: DispatchWorkItem?
    private var takeDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var takeRegion: CGRect?
    private var takeMaxSide: Int = 3840
    private var takeFPS: Int = 30
    private var lastOutputSize: (width: Int, height: Int) = (0, 0)

    /// Pause intervals of the current take.
    let pauseClock = PauseClock()

    var isPaused: Bool { pauseClock.isPaused }
    var pausedSeconds: Double { pauseClock.pausedSeconds }
    var pauseCount: Int { pauseClock.pauseCount }

    func pause() { pauseClock.pause() }
    func resume() { pauseClock.resume() }

    /// The `.partial.mp4` being written for the current take (for live size display).
    var currentPartialURL: URL? { paths?.partial }
    var currentFolderURL: URL? { access?.directory }

    /// Invoked on the main queue if the stream stops by itself or the encoder fails.
    var onInterrupted: ((StopResult) -> Void)?
    /// Snapshot from the most recent `stop()` / finalize. Used by the self-test report.
    private(set) var lastStats: MovieWriter.Stats?

    func start(
        systemAudio: Bool,
        microphone: Bool = false,
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        region: CGRect? = nil,
        maxSide: Int = 3840,
        framesPerSecond: Int = 30,
        cameraWindowID: Int? = nil,
        overlayWindowIDs: [Int] = []
    ) async throws {
        resetStopState()
        lastStats = nil
        pauseClock.reset()
        takeDisplayID = displayID
        takeRegion = region
        takeMaxSide = max(2, maxSide)
        takeFPS = max(1, framesPerSecond)
        lastCameraWindowID = cameraWindowID
        lastOverlayWindowIDs = overlayWindowIDs
        let content = try await shareableContent()
        guard let display = pickDisplay(from: content, preferred: displayID) else {
            throw CaptureError.noDisplay
        }

        let folder = try SaveLocation.beginAccess()
        access = folder
        do {
            try SaveLocation.ensureFreeSpace(at: folder.directory)
            paths = SaveLocation.makePaths(in: folder.directory)
        } catch {
            access?.stop()
            access = nil
            paths = nil
            throw error
        }

        lastSystemAudio = systemAudio
        lastMicrophone = microphone
        usesBGRAPixelFormat = Self.preferBGRAPixelFormat
        do {
            try await openStream(
                content: content,
                display: display,
                systemAudio: systemAudio,
                microphone: microphone
            )
        } catch {
            await discardAttempt()
            access?.stop()
            access = nil
            paths = nil
            throw error
        }

        // lastSystemAudio / lastMicrophone already reflect the running config
        // (openStream updates them if it had to fall back).
        setCaptureStarted(true)
        armWatchdog()
        let pixel = usesBGRAPixelFormat ? "BGRA" : "420v"
        let size = lastOutputSize
        log.info("capture started \(size.width)x\(size.height) audio=\(self.capturesAudio) mic=\(self.capturesMicrophone) fallback=\(self.audioFellBack) pixel=\(pixel, privacy: .public) fps=\(self.takeFPS) maxSide=\(self.takeMaxSide)")
    }

    func stop() async -> StopResult {
        stateLock.lock()
        if let existing = stopTask {
            stateLock.unlock()
            return await existing.value
        }
        let pendingFallback = fallbackTask
        let task = Task {
            if let pendingFallback {
                await pendingFallback.value
            }
            return await self.finishPipeline()
        }
        stopTask = task
        stateLock.unlock()
        return await task.value
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isAccepting() else { return }
        switch type {
        case .screen:
            writer?.enqueueVideo(sampleBuffer)
        case .audio:
            writer?.enqueueAudio(sampleBuffer)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                writer?.enqueueMicrophone(sampleBuffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Ignore failures that happen while startCapture is still throwing; that path cleans up itself.
        guard isCaptureStarted(), stream === self.stream else { return }
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        postFailure(Permissions.isPermissionError(error)
            ? "没有屏幕录制权限。请在系统设置里允许小名，然后退出并重新打开。"
            : "录制被系统中断。\(error.localizedDescription)")
    }

    // MARK: - Start

    private func openStream(
        content: SCShareableContent,
        display: SCDisplay,
        systemAudio: Bool,
        microphone: Bool
    ) async throws {
        do {
            try await buildStream(content: content, display: display, systemAudio: systemAudio, microphone: microphone)
            capturesAudio = systemAudio || microphone
            capturesMicrophone = microphone
        } catch {
            guard !Permissions.isPermissionError(error) else { throw error }
            if microphone {
                log.error("microphone failed, retrying without it: \(error.localizedDescription, privacy: .public)")
                await discardAttempt()
                microphoneFellBack = true
                do {
                    try await buildStream(content: content, display: display, systemAudio: systemAudio, microphone: false)
                    capturesAudio = systemAudio
                    capturesMicrophone = false
                    lastMicrophone = false
                    return
                } catch {
                    guard systemAudio, !Permissions.isPermissionError(error) else { throw error }
                }
            }
            guard systemAudio else { throw error }
            log.error("system audio failed, retrying video only: \(error.localizedDescription, privacy: .public)")
            await discardAttempt()
            audioFellBack = true
            try await buildStream(content: content, display: display, systemAudio: false, microphone: false)
            capturesAudio = false
            capturesMicrophone = false
            lastSystemAudio = false
            lastMicrophone = false
        }
    }

    private func buildStream(
        content: SCShareableContent,
        display: SCDisplay,
        systemAudio: Bool,
        microphone: Bool
    ) async throws {
        guard let paths else { throw CaptureError.exportFailed("没有输出路径。") }
        let filter = makeFilter(content: content, display: display)
        let sourceRect = clampedRegion(takeRegion, filter: filter)
        if takeRegion != nil && sourceRect == nil {
            throw CaptureError.invalidRegion
        }
        let points = sourceRect?.size ?? filter.contentRect.size
        let size = CaptureGeometry.outputSize(
            points: points,
            scale: CGFloat(filter.pointPixelScale),
            maxSide: takeMaxSide
        )
        guard size.width >= 2, size.height >= 2 else {
            throw CaptureError.noDisplay
        }
        lastOutputSize = (size.width, size.height)
        let wantAudio = systemAudio || microphone
        let configuration = makeConfiguration(
            size: size,
            systemAudio: systemAudio,
            microphone: microphone,
            sourceRect: sourceRect
        )

        let movieWriter = try MovieWriter(
            partialURL: paths.partial,
            width: size.width,
            height: size.height,
            capturesAudio: wantAudio,
            mixesMicrophone: systemAudio && microphone,
            framesPerSecond: takeFPS
        )
        movieWriter.pauseClock = pauseClock
        movieWriter.onFailure = { [weak self] in
            guard let self else { return }
            if self.shouldRetryWithBGRA() {
                self.beginBGRAFallback()
                return
            }
            let message = movieWriter.writerError?.localizedDescription ?? "编码器中途停止了。"
            self.postFailure(message)
        }
        // Publish before startCapture so callbacks can enqueue immediately.
        self.writer = movieWriter

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if microphone {
            if #available(macOS 15.0, *) {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            } else {
                throw CaptureError.message("当前系统版本不能采集麦克风。")
            }
        }
        self.stream = stream
        setAccepting(true)
        do {
            try await stream.startCapture()
        } catch {
            setAccepting(false)
            throw error
        }
    }

    /// On-screen windows first; fall back to all windows if a window we must
    /// keep in the recording (camera PIP, effects overlay) is not listed yet.
    private func shareableContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wanted = (lastCameraWindowID.map { [$0] } ?? []) + lastOverlayWindowIDs
        let missing = wanted.contains { id in !content.windows.contains(where: { Int($0.windowID) == id }) }
        guard missing else { return content }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    private func makeFilter(content: SCShareableContent, display: SCDisplay) -> SCContentFilter {
        let bundleID = Bundle.main.bundleIdentifier
        let pid = ProcessInfo.processInfo.processIdentifier
        // Exclude 小名's own UI (capsule, SideCards, selection overlay) but keep the camera preview.
        let excluded = content.applications.filter { app in
            app.processID == pid || (bundleID != nil && app.bundleIdentifier == bundleID)
        }
        var excepted: [SCWindow] = []
        if let cameraID = lastCameraWindowID {
            let camera = content.windows.filter { Int($0.windowID) == cameraID }
            if camera.isEmpty {
                log.error("camera window \(cameraID) was not in shareable content; PIP may be missing from the file")
            } else {
                log.info("including camera window \(cameraID) in the capture")
            }
            excepted += camera
        }
        for overlayID in lastOverlayWindowIDs {
            let overlay = content.windows.filter { Int($0.windowID) == overlayID }
            if overlay.isEmpty {
                log.error("effects overlay \(overlayID) was not in shareable content; halo/watermark may be missing")
            } else {
                log.info("including effects overlay \(overlayID) in the capture")
            }
            excepted += overlay
        }
        log.info("excluding \(excluded.count) app(s) from the capture, excepting \(excepted.count) window(s)")
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: excepted)
    }

    private func makeConfiguration(
        size: (width: Int, height: Int, scaled: Bool),
        systemAudio: Bool,
        microphone: Bool,
        sourceRect: CGRect?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = size.scaled
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        if Self.preferBGRAPixelFormat {
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            usesBGRAPixelFormat = true
            log.info("pixel format=BGRA")
        } else {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            usesBGRAPixelFormat = false
            log.info("pixel format=420v")
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(takeFPS, 1)))
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = systemAudio
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = microphone
        }
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }

    private func pickDisplay(from content: SCShareableContent, preferred: CGDirectDisplayID) -> SCDisplay? {
        content.displays.first { $0.displayID == preferred }
            ?? content.displays.first { $0.displayID == CGMainDisplayID() }
            ?? content.displays.first
    }

    /// Crop is in top-left display points. Discard a region that no longer fits this display.
    private func clampedRegion(_ region: CGRect?, filter: SCContentFilter) -> CGRect? {
        guard let region else { return nil }
        let bounds = CGRect(origin: .zero, size: filter.contentRect.size)
        let clipped = region.intersection(bounds)
        guard clipped.width >= 2, clipped.height >= 2 else { return nil }
        return clipped
    }

    // MARK: - Stop

    private func finishPipeline() async -> StopResult {
        setCaptureStarted(false)
        watchdog?.cancel()
        watchdog = nil
        setAccepting(false)

        let activeStream = stream
        stream = nil
        if let activeStream {
            try? await activeStream.stopCapture()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async { continuation.resume() }
        }

        let movieWriter = writer
        let output = paths
        let wantedAudio = capturesAudio
        let wantedMic = capturesMicrophone
        let fellBack = audioFellBack
        let micFellBack = microphoneFellBack
        writer = nil

        // Keep the security-scoped folder access alive until every file
        // operation (finalize, rename, cleanup) is done. Releasing it first
        // is what made a Desktop (or other user-picked) folder fail with
        // “没有访问桌面的许可” after a successful encode.
        defer {
            access?.stop()
            access = nil
        }

        guard let movieWriter, let output else {
            if let partial = output?.partial {
                try? FileManager.default.removeItem(at: partial)
            }
            return .failed(CaptureError.cancelled.errorDescription ?? "已取消。")
        }

        let writeResult: Result<MovieWriter.Stats, Error> = await withCheckedContinuation { continuation in
            movieWriter.asyncOnWriter {
                movieWriter.finalize { continuation.resume(returning: $0) }
            }
        }

        switch writeResult {
        case .failure(let error):
            lastStats = movieWriter.stats
            try? FileManager.default.removeItem(at: output.partial)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("finish failed: \(message, privacy: .public) video=\(self.lastStats?.videoFrames ?? 0) droppedVideo=\(self.lastStats?.droppedVideo ?? 0)")
            return .failed(message)
        case .success(let stats):
            lastStats = stats
            do {
                if FileManager.default.fileExists(atPath: output.final.path) {
                    try FileManager.default.removeItem(at: output.final)
                }
                try FileManager.default.moveItem(at: output.partial, to: output.final)
            } catch {
                // Leave the finished .partial.mp4 in place so the take is not lost.
                log.error("rename failed, leaving partial: \(error.localizedDescription, privacy: .public)")
                return .failed("保存文件失败。\(error.localizedDescription) 录好的画面还在：\(output.partial.lastPathComponent)")
            }
            log.info("saved \(output.final.path, privacy: .public) video=\(stats.videoFrames) audio=\(stats.audioFrames) droppedVideo=\(stats.droppedVideo) droppedAudio=\(stats.droppedAudio)")
            let note = audioNote(wantedAudio: wantedAudio, wantedMic: wantedMic, fellBack: fellBack, micFellBack: micFellBack, audioFrames: stats.audioFrames)
            return .saved(output.final, note: note)
        }
    }

    private func audioNote(wantedAudio: Bool, wantedMic: Bool, fellBack: Bool, micFellBack: Bool, audioFrames: Int) -> String? {
        if fellBack {
            return "画面已保存。声音没能开始采集，这条是无声视频。"
        }
        if micFellBack && wantedAudio {
            return "画面已保存。麦克风没能开始采集，这条只有系统声音。"
        }
        if micFellBack {
            return "画面已保存。麦克风没能开始采集，这条是无声视频。"
        }
        if wantedAudio && audioFrames == 0 {
            if wantedMic {
                return "画面已保存，但没有写入声音。"
            }
            return "画面已保存，但没有写入系统声音。"
        }
        return nil
    }

    private func discardAttempt() async {
        setAccepting(false)
        let activeStream = stream
        stream = nil
        if let activeStream {
            try? await activeStream.stopCapture()
        }
        let partial = paths?.partial
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async { continuation.resume() }
        }
        writer?.cancel()
        writer = nil
        if let partial {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let alreadyStopping = self.stopTask != nil
            self.stateLock.unlock()
            guard !alreadyStopping else { return }
            self.stateLock.lock()
            let fallbackRunning = self.fallbackTask != nil
            self.stateLock.unlock()
            guard !fallbackRunning else { return }
            let frames = self.writer?.stats.videoFrames ?? 0
            guard frames == 0 else { return }
            self.postFailure("几秒内没有收到画面。请确认已经允许屏幕录制；如果刚刚才允许，退出小名再打开一次。")
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func postFailure(_ message: String) {
        stateLock.lock()
        let already = failurePosted
        failurePosted = true
        stateLock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task {
                let result = await self.stop()
                let delivered: StopResult
                if case .failed = result {
                    delivered = .failed(message)
                } else {
                    delivered = result
                }
                DispatchQueue.main.async {
                    self.onInterrupted?(delivered)
                }
            }
        }
    }

    // MARK: - 420v → BGRA fallback

    private func shouldRetryWithBGRA() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if Self.preferBGRAPixelFormat || usesBGRAPixelFormat || pixelFormatFallbackStarted {
            return false
        }
        if stopTask != nil { return false }
        let frames = writer?.stats.videoFrames ?? 0
        return frames == 0
    }

    private func beginBGRAFallback() {
        stateLock.lock()
        pixelFormatFallbackStarted = true
        Self.preferBGRAPixelFormat = true
        let task = Task { await self.retryThisTakeWithBGRA() }
        fallbackTask = task
        stateLock.unlock()
        setAccepting(false)
        watchdog?.cancel()
        watchdog = nil
        log.error("H.264 rejected early 420v frames; retrying this take with BGRA")
    }

    private func clearFallbackTask() {
        stateLock.lock()
        fallbackTask = nil
        stateLock.unlock()
    }

    private func retryThisTakeWithBGRA() async {
        defer { clearFallbackTask() }
        if isStopping() {
            log.info("BGRA fallback aborted because stop was already requested")
            return
        }
        await discardAttempt()
        if isStopping() {
            log.info("BGRA fallback aborted after teardown because stop was requested")
            return
        }
        usesBGRAPixelFormat = true
        do {
            let content = try await shareableContent()
            guard let display = pickDisplay(from: content, preferred: takeDisplayID) else {
                if !isStopping() {
                    postFailure(CaptureError.noDisplay.errorDescription ?? "没有找到可用的显示器。")
                }
                return
            }
            try await openStream(
                content: content,
                display: display,
                systemAudio: lastSystemAudio,
                microphone: lastMicrophone
            )
            if isStopping() {
                // Leave the restarted stream for finishPipeline to stop.
                return
            }
            setCaptureStarted(true)
            armWatchdog()
            let size = lastOutputSize
            log.info("capture restarted with BGRA \(size.width)x\(size.height) audio=\(self.capturesAudio) fps=\(self.takeFPS)")
        } catch {
            if isStopping() { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("BGRA fallback failed: \(message, privacy: .public)")
            postFailure(message)
        }
    }

    private func isStopping() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopTask != nil
    }

    private func resetStopState() {

        stateLock.lock()
        stopTask = nil
        failurePosted = false
        pixelFormatFallbackStarted = false
        fallbackTask = nil
        stateLock.unlock()
        audioFellBack = false
        microphoneFellBack = false
        setCaptureStarted(false)
    }

    private func setCaptureStarted(_ value: Bool) {
        stateLock.lock()
        captureStarted = value
        stateLock.unlock()
    }

    private func isCaptureStarted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureStarted
    }

    private func setAccepting(_ value: Bool) {
        stateLock.lock()
        acceptSamples = value
        stateLock.unlock()
    }

    private func isAccepting() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptSamples
    }
}
