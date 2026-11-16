import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Cursor path + clicks recorded during a take (sidecar `LJM-…-cursor.json`).
/// Times are host-clock seconds, the same clock as ScreenCaptureKit PTS, so
/// `t - sessionStart` is the time inside the movie. x/y are normalised to the
/// recorded area with a top-left origin (same orientation as the picture).
struct CursorTrack: Codable {
    struct Sample: Codable {
        var t: Double
        var x: Double
        var y: Double
        /// 0 = move, 1 = left click, 2 = right click.
        var c: Int
    }

    var version = 1
    var sessionStart: Double
    var fps: Int
    var areaWidth: Double
    var areaHeight: Double
    var samples: [Sample]

    var clickCount: Int { samples.filter { $0.c != 0 }.count }
}

/// Logs the pointer while a take runs. Mouse events need no extra permission.
/// Event-driven only (no timers); moves are thinned to ≤120 per second.
@MainActor
final class CursorTracker {
    private var monitors: [Any] = []
    private var samples: [CursorTrack.Sample] = []
    private var screenFrame: CGRect = .zero
    /// Recorded area in top-left display points.
    private var area: CGRect = .zero
    private var lastMoveTime: Double = 0
    private(set) var isRunning = false

    var areaSize: CGSize { area.size }

    static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func start(screen: NSScreen, region: CGRect?) {
        stopMonitors()
        samples.removeAll(keepingCapacity: true)
        screenFrame = screen.frame
        let full = CGRect(origin: .zero, size: screen.frame.size)
        if let region {
            let clipped = region.intersection(full)
            area = (clipped.width >= 2 && clipped.height >= 2) ? clipped : full
        } else {
            area = full
        }
        isRunning = true
        record(NSEvent.mouseLocation, kind: 0)
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(type, at: location) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(type, at: location) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() -> [CursorTrack.Sample] {
        stopMonitors()
        isRunning = false
        let result = samples
        samples.removeAll()
        return result
    }

    private func stopMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func handle(_ type: NSEvent.EventType, at location: NSPoint) {
        switch type {
        case .leftMouseDown: record(location, kind: 1)
        case .rightMouseDown: record(location, kind: 2)
        default: record(location, kind: 0)
        }
    }

    /// Global bottom-left point. Public so the self-test can feed a path and clicks.
    func record(_ location: NSPoint, kind: Int) {
        guard isRunning, area.width > 0, area.height > 0 else { return }
        let now = Self.hostNow()
        if kind == 0, now - lastMoveTime < 1.0 / 120.0 { return }
        if kind == 0 { lastMoveTime = now }
        let localX = location.x - screenFrame.minX - area.minX
        let localY = (screenFrame.maxY - location.y) - area.minY
        samples.append(.init(t: now, x: Double(localX / area.width), y: Double(localY / area.height), c: kind))
    }
}

/// Zoom camera over time. Click → ease in to `zoom`, hold while clicking,
/// ease out after a quiet spell. The centre follows the pointer through a
/// one-pole low-pass (no overshoot, so it never swings or "breathes").
final class ZoomPlan {
    struct State: Equatable {
        var scale: Double
        var cx: Double
        var cy: Double
    }

    static let lead = 0.15
    static let inDuration = 0.55
    static let hold = 1.6
    static let outDuration = 0.75
    static let followTau = 0.32

    private let zoom: Double
    private var segments: [(start: Double, end: Double)] = []
    private let times: [Double]
    private let xs: [Double]
    private let ys: [Double]
    private var lastTime: Double?
    private var cx = 0.5
    private var cy = 0.5

    init(track: CursorTrack, zoom: Double) {
        self.zoom = max(1, zoom)
        let sorted = track.samples.sorted { $0.t < $1.t }
        times = sorted.map { $0.t - track.sessionStart }
        xs = sorted.map { min(max($0.x, 0), 1) }
        ys = sorted.map { min(max($0.y, 0), 1) }
        for sample in sorted where sample.c != 0 {
            let t = sample.t - track.sessionStart
            if var last = segments.last, t <= last.end + Self.outDuration {
                last.end = max(last.end, t + Self.hold)
                segments[segments.count - 1] = last
            } else {
                segments.append((t, t + Self.hold))
            }
        }
    }

    var hasZoom: Bool { !segments.isEmpty }
    var segmentSummary: String {
        segments.map { String(format: "%.2f-%.2f", $0.start - Self.lead, $0.end + Self.outDuration) }.joined(separator: ",")
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10) // smootherstep
    }

    func progress(at t: Double) -> Double {
        var p = 0.0
        for segment in segments {
            let a = segment.start - Self.lead
            if t < a || t > segment.end + Self.outDuration { continue }
            let q: Double
            if t < a + Self.inDuration {
                q = Self.ease((t - a) / Self.inDuration)
            } else if t <= segment.end {
                q = 1
            } else {
                q = 1 - Self.ease((t - segment.end) / Self.outDuration)
            }
            p = max(p, q)
        }
        return p
    }

    private func cursor(at t: Double) -> (Double, Double) {
        guard !times.isEmpty else { return (0.5, 0.5) }
        if t <= times[0] { return (xs[0], ys[0]) }
        if t >= times[times.count - 1] { return (xs[xs.count - 1], ys[ys.count - 1]) }
        var low = 0
        var high = times.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= t { low = mid } else { high = mid }
        }
        let span = times[high] - times[low]
        let f = span > 0 ? (t - times[low]) / span : 0
        return (xs[low] + (xs[high] - xs[low]) * f, ys[low] + (ys[high] - ys[low]) * f)
    }

    /// Call with non-decreasing `t` (the filter is stateful).
    func state(at t: Double) -> State {
        let p = progress(at: t)
        let scale = 1 + (zoom - 1) * p
        let target = cursor(at: t)
        if p <= 0.0001 || lastTime == nil {
            cx = target.0
            cy = target.1
        } else {
            let dt = max(0, t - (lastTime ?? t))
            let a = 1 - exp(-dt / Self.followTau)
            cx += (target.0 - cx) * a
            cy += (target.1 - cy) * a
        }
        lastTime = t
        let half = 0.5 / scale
        return State(scale: scale, cx: min(max(cx, half), 1 - half), cy: min(max(cy, half), 1 - half))
    }
}

/// Offline render of `LJM-…-zoom.mp4`. Decodes the original, crops/scales
/// each frame with Core Image on the GPU, re-encodes H.264 at ≥ the source
/// bitrate and the same size, and copies the AAC track untouched (passthrough),
/// so audio timing is exactly the original's. Source frames keep their real
/// PTS (VFR); while the camera is moving over a still picture, in-between
/// frames are added on the take's frame grid so the zoom stays smooth.
enum ZoomRenderer {
    struct Result {
        var frames: Int
        var filledFrames: Int
        var bitRate: Int
        var sourceBitRate: Int
        var segments: String
        /// One line per written frame: pts,scale,cx,cy,filled(0/1). For self-tests.
        var trace: [String] = []
    }

    static func render(
        source: URL,
        output: URL,
        track: CursorTrack,
        zoom: Double,
        progress: @escaping (Double) -> Void
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try renderSync(source: source, output: output, track: track, zoom: zoom, progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func renderSync(
        source: URL,
        output: URL,
        track: CursorTrack,
        zoom: Double,
        progress: @escaping (Double) -> Void
    ) throws -> Result {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw CaptureError.exportFailed("原片里没有画面。")
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let width = Int(videoTrack.naturalSize.width.rounded())
        let height = Int(videoTrack.naturalSize.height.rounded())
        guard width > 0, height > 0 else { throw CaptureError.exportFailed("原片尺寸无效。") }
        let duration = max(asset.duration.seconds, 0.001)
        let fps = max(track.fps, 1)
        let sourceBitRate = Int(videoTrack.estimatedDataRate)
        let bitRate = min(max(Int(Double(sourceBitRate) * 1.3), 8_000_000), 80_000_000)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            audioOutput = out
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTrack.preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioTrack, let hint = audioTrack.formatDescriptions.first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: (hint as! CMFormatDescription))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw reader.error ?? CaptureError.exportFailed("读不了原片。")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? CaptureError.exportFailed("写不了缩放版。")
        }
        writer.startSession(atSourceTime: .zero)

        let plan = ZoomPlan(track: track, zoom: zoom)
        let context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
        let W = Double(width)
        let H = Double(height)
        let step = 1.0 / Double(fps)
        let group = DispatchGroup()
        let lock = NSLock()
        var failure: Error?

        func fail(_ error: Error) {
            lock.lock()
            if failure == nil { failure = error }
            lock.unlock()
        }

        // ---- video ----
        var pending: [(image: CIImage, pts: CMTime, state: ZoomPlan.State, filled: Bool)] = []
        var trace: [String] = []
        var previous: (image: CIImage, pts: CMTime)?
        var lastEmitted: ZoomPlan.State?
        var readerDone = false
        var videoFinished = false
        var frames = 0
        var filled = 0
        var lastReported = -1.0

        func changed(_ a: ZoomPlan.State, _ b: ZoomPlan.State) -> Bool {
            abs(a.scale - b.scale) > 0.0005 || abs(a.cx - b.cx) * W > 0.5 || abs(a.cy - b.cy) * H > 0.5
        }

        func framed(_ image: CIImage, _ state: ZoomPlan.State) -> CIImage {
            guard state.scale > 1.0005 else { return image }
            let w = W / state.scale
            let h = H / state.scale
            let x = min(max(state.cx * W - w / 2, 0), W - w)
            let y = min(max((1 - state.cy) * H - h / 2, 0), H - h)
            let transform = CGAffineTransform(translationX: -x, y: -y)
                .concatenating(CGAffineTransform(scaleX: state.scale, y: state.scale))
            return image.clampedToExtent()
                .transformed(by: transform)
                .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        }

        let videoQueue = DispatchQueue(label: "dev.ljm.zoom.video", qos: .userInitiated)
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            func finishVideo() {
                guard !videoFinished else { return }
                videoFinished = true
                videoInput.markAsFinished()
                group.leave()
            }
            while videoInput.isReadyForMoreMediaData {
                if failure != nil { finishVideo(); return }
                if pending.isEmpty {
                    if readerDone { finishVideo(); return }
                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                        readerDone = true
                        continue
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard pts.isValid else { continue }
                    let image = CIImage(cvPixelBuffer: pixelBuffer)
                    if let previous, let last = lastEmitted {
                        var reference = last
                        // Spread in-between frames evenly across the gap (≈ the take's
                        // frame interval) so spacing stays uniform right up to the
                        // next real frame instead of leaving one short/long step.
                        let gap = pts.seconds - previous.pts.seconds
                        let slots = Int((gap / step).rounded())
                        let spacing = slots > 0 ? gap / Double(slots) : gap
                        for slot in stride(from: 1, to: max(slots, 1), by: 1) {
                            let t = previous.pts.seconds + spacing * Double(slot)
                            let state = plan.state(at: t)
                            if changed(state, reference) {
                                pending.append((previous.image, CMTime(seconds: t, preferredTimescale: max(pts.timescale, 600)), state, true))
                                reference = state
                                filled += 1
                            }
                        }
                    }
                    let state = plan.state(at: pts.seconds)
                    pending.append((image, pts, state, false))
                    lastEmitted = state
                    previous = (image, pts)
                    continue
                }
                let item = pending.removeFirst()
                guard let pool = adaptor.pixelBufferPool else {
                    fail(CaptureError.exportFailed("缩放版画面缓冲不可用。"))
                    finishVideo()
                    return
                }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let out else {
                    fail(CaptureError.exportFailed("缩放版画面缓冲不足。"))
                    finishVideo()
                    return
                }
                CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                context.render(framed(item.image, item.state), to: out, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: nil)
                if !adaptor.append(out, withPresentationTime: item.pts) {
                    fail(writer.error ?? CaptureError.exportFailed("缩放版写入失败。"))
                    finishVideo()
                    return
                }
                frames += 1
                trace.append(String(format: "%.6f,%.5f,%.5f,%.5f,%d", item.pts.seconds, item.state.scale, item.state.cx, item.state.cy, item.filled ? 1 : 0))
                let fraction = min(1, item.pts.seconds / duration)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }

        // ---- audio (passthrough) ----
        if let audioInput, let audioOutput {
            let audioQueue = DispatchQueue(label: "dev.ljm.zoom.audio", qos: .userInitiated)
            var audioFinished = false
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    if audioFinished { return }
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioFinished = true
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if !audioInput.append(sample) {
                        fail(writer.error ?? CaptureError.exportFailed("缩放版声音写入失败。"))
                        audioFinished = true
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        group.wait()
        if let failure {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw failure
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw reader.error ?? CaptureError.exportFailed("读取原片中断。")
        }
        // End exactly where the original's picture ends, so the last frame
        // keeps its real length instead of inheriting the previous gap.
        // (Never earlier than the audio's end, or the copied sound gets clipped.)
        var sessionEnd = videoTrack.timeRange.end
        if let audioEnd = audioTrack?.timeRange.end, audioEnd.isValid,
           !sessionEnd.isValid || CMTimeCompare(audioEnd, sessionEnd) > 0 {
            sessionEnd = audioEnd
        }
        if sessionEnd.isValid, sessionEnd.seconds > 0 {
            writer.endSession(atSourceTime: sessionEnd)
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? CaptureError.exportFailed("缩放版没能完成。")
        }
        progress(1)
        return Result(frames: frames, filledFrames: filled, bitRate: bitRate, sourceBitRate: sourceBitRate, segments: plan.segmentSummary, trace: trace)
    }
}
