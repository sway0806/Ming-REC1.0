import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import os
import ScreenCaptureKit
import VideoToolbox

/// Writes one MP4 (H.264 + AAC) from ScreenCaptureKit sample buffers.
///
/// First principles: the capture callback must return immediately; the writer
/// queue must only append already-prepared samples, with video tried first so
/// a 60 fps take can stay near the encoder's proven rate. Conversion and
/// system/mic mixing run on a separate prep queue. If the encoder falls
/// behind, intermediate complete frames are dropped (VFR) but the next written
/// frame keeps its real PTS. Idle/blank frames are skipped the same way.
///
/// Realtime capture uses push append only (`expectsMediaDataInRealTime`).
/// `requestMediaDataWhenReady` is not used during the take — mixing push and
/// pull leaves `isReadyForMoreMediaData` false except inside that callback
/// and starves video down to a few frames per second. It is used only at
/// finish, after capture has stopped, to wait until a freeze-frame at the
/// real audio end PTS can be appended.
final class MovieWriter {
    private static let log = Logger(subsystem: "dev.ljm.recorder", category: "writer")
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let maxPreparedAudio = 64

    struct Stats {
        var videoFrames: Int = 0
        var audioFrames: Int = 0
        var droppedVideo: Int = 0
        var droppedAudio: Int = 0
        /// Prepared audio whose PTS fell before the video session start (not written).
        var audioBeforeSession: Int = 0
        /// Short human-readable audio timing summary for logs / self-test.
        var audioNote: String = ""
        /// Host-clock seconds of the first video frame (movie time 0). 0 if never started.
        var sessionStartSeconds: Double = 0
        /// Samples dropped because they were captured while paused.
        var pausedDropped: Int = 0
    }

    let partialURL: URL
    let capturesAudio: Bool
    let mixesMicrophone: Bool

    /// Invoked once on `writerQueue` if the writer fails mid-take.
    var onFailure: (() -> Void)?
    /// Pause intervals for this take (shared with the recorder; survives a BGRA retry).
    var pauseClock: PauseClock?

    private let writerQueue = DispatchQueue(label: "dev.ljm.recorder.writer", qos: .userInteractive)
    private let audioPrepQueue = DispatchQueue(label: "dev.ljm.recorder.audioprep", qos: .userInitiated)
    private let hop = NSLock()

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let audioConverter: AudioSampleConverter
    private let mixer: SystemMicMixer?

    // Hoppers — touched from the sample callback, audio prep, and writer queue.
    private var latestVideo: CMSampleBuffer?
    private var droppedAtHop = 0
    private var preparedAudio: [CMSampleBuffer] = []
    private var droppedAudioAtHop = 0
    private var pumpScheduled = false
    private var hopClosed = false
    // Audio prep queue only: merge tiny mixer/converter chunks into ~21 ms buffers.
    private var coalesceSamples: [Float] = []
    private var coalescePTS: CMTime = .invalid
    private let coalesceFrames = 1_024

    // Writer-queue state.
    private var statsStorage = Stats()
    private var sessionStarted = false
    private var sessionStart: CMTime = .zero
    private var closed = false
    private var inputsMarked = false
    private var audioGaveUp = false
    private var pendingVideo: CMSampleBuffer?
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioEndPTS: CMTime = .invalid
    private var firstPreparedAudioPTS: CMTime = .invalid
    private var mixerNote = ""
    private var failureSignaled = false
    private var finishCompletion: ((Result<Stats, Error>) -> Void)?
    private var finishReadyArmed = false
    private var finishStartedAt: Date?
    private var completing = false

    var stats: Stats { onWriterQueue { statsStorage } }
    var failed: Bool { onWriterQueue { writer.status == .failed } }
    var writerError: Error? { onWriterQueue { writer.error } }

    init(partialURL: URL, width: Int, height: Int, capturesAudio: Bool, mixesMicrophone: Bool = false, framesPerSecond: Int) throws {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw CaptureError.exportFailed("画面尺寸无效。")
        }
        self.partialURL = partialURL
        self.capturesAudio = capturesAudio
        self.mixesMicrophone = mixesMicrophone && capturesAudio
        let audioConverter = AudioSampleConverter()
        self.audioConverter = audioConverter
        self.mixer = self.mixesMicrophone ? SystemMicMixer() : nil
        let fps = max(framesPerSecond, 1)
        writerQueue.setSpecific(key: Self.queueKey, value: 1)

        let parts: WriterParts
        do {
            parts = try Self.makeWriterParts(
                partialURL: partialURL,
                width: width,
                height: height,
                capturesAudio: capturesAudio,
                framesPerSecond: fps,
                audioConverter: audioConverter,
                requireHardware: true
            )
            Self.log.info("H.264 encoder: hardware required fps=\(fps)")
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            Self.log.error("hardware-required encoder failed, retrying without Require: \(error.localizedDescription, privacy: .public)")
            parts = try Self.makeWriterParts(
                partialURL: partialURL,
                width: width,
                height: height,
                capturesAudio: capturesAudio,
                framesPerSecond: fps,
                audioConverter: audioConverter,
                requireHardware: false
            )
            Self.log.info("H.264 encoder: hardware enabled (not required) fps=\(fps)")
        }

        self.writer = parts.writer
        self.videoInput = parts.videoInput
        self.audioInput = parts.audioInput
    }

    func onWriterQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return writerQueue.sync(execute: body)
    }

    func asyncOnWriter(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
            return
        }
        writerQueue.async(execute: body)
    }

    /// Non-blocking. Keeps only the latest complete frame if the writer is busy (VFR).
    func enqueueVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return
        }
        guard Self.frameStatus(sampleBuffer) == .complete else { return }
        hop.lock()
        if hopClosed {
            hop.unlock()
            return
        }
        if latestVideo != nil {
            droppedAtHop += 1
        }
        latestVideo = sampleBuffer
        hop.unlock()
        schedulePump()
    }

    /// Non-blocking. Raw system audio is converted/mixed off the writer queue.
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        enqueueRawAudio(sampleBuffer, microphone: false)
    }

    func enqueueMicrophone(_ sampleBuffer: CMSampleBuffer) {
        enqueueRawAudio(sampleBuffer, microphone: true)
    }

    /// Drain leftover samples, extend the last picture to the audio end if needed, then finish the file.
    /// Must be called after the capture callback queue has been drained.
    func finalize(completion: @escaping (Result<Stats, Error>) -> Void) {
        hop.lock()
        hopClosed = true
        hop.unlock()
        audioPrepQueue.async { [self] in
            if let mixer, mixesMicrophone {
                let held = mixer.pendingFrames
                let flushed = mixer.flush()
                let note = "flushBuffers=\(flushed.count) heldSystem=\(held.system) heldMic=\(held.mic) firstOffset=\(mixer.firstOffsetFrames ?? 0) realigns=\(mixer.realignCount) \(mixer.sourceNote)"
                Self.log.info("mixer \(note, privacy: .public)")
                writerQueue.async { self.mixerNote = note }
                coalescePreparedAudio(flushed, flushing: true)
            } else {
                emitCoalescedAudio(flushing: true)
            }
            writerQueue.async {
                self.finishCompletion = completion
                self.finishStartedAt = Date()
                self.continueFinishing()
            }
        }
    }

    func cancel() {
        onWriterQueue {
            self.closed = true
            self.hop.lock()
            self.hopClosed = true
            self.latestVideo = nil
            self.preparedAudio.removeAll(keepingCapacity: false)
            self.hop.unlock()
            if self.writer.status == .writing {
                self.writer.cancelWriting()
            }
        }
    }

    private func enqueueRawAudio(_ sampleBuffer: CMSampleBuffer, microphone: Bool) {
        hop.lock()
        let closed = hopClosed
        hop.unlock()
        guard !closed else { return }
        audioPrepQueue.async { self.prepareAudio(sampleBuffer, microphone: microphone) }
    }

    private func prepareAudio(_ sampleBuffer: CMSampleBuffer, microphone: Bool) {
        let outgoing: [CMSampleBuffer]
        if let mixer, mixesMicrophone {
            outgoing = microphone ? mixer.ingestMicrophone(sampleBuffer) : mixer.ingestSystem(sampleBuffer)
        } else if let converted = audioConverter.convert(sampleBuffer) {
            outgoing = [converted]
        } else {
            hop.lock()
            droppedAudioAtHop += 1
            hop.unlock()
            return
        }
        coalescePreparedAudio(outgoing, flushing: false)
        schedulePump()
    }

    private func coalescePreparedAudio(_ buffers: [CMSampleBuffer], flushing: Bool) {
        for buffer in buffers {
            absorbForCoalesce(buffer)
        }
        emitCoalescedAudio(flushing: flushing)
    }

    private func absorbForCoalesce(_ buffer: CMSampleBuffer) {
        guard let samples = Self.interleavedStereoFloats(from: buffer), !samples.isEmpty else {
            hop.lock()
            droppedAudioAtHop += 1
            hop.unlock()
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if coalesceSamples.isEmpty {
            coalescePTS = pts
        }
        coalesceSamples.append(contentsOf: samples)
    }

    private func emitCoalescedAudio(flushing: Bool) {
        while coalesceSamples.count >= coalesceFrames * 2 || (flushing && !coalesceSamples.isEmpty) {
            let frames = min(coalesceFrames, coalesceSamples.count / 2)
            guard frames > 0 else { break }
            let slice = Array(coalesceSamples.prefix(frames * 2))
            coalesceSamples.removeFirst(frames * 2)
            let duration = CMTime(value: CMTimeValue(frames), timescale: 48_000)
            let pts = coalescePTS
            if pts.isValid {
                coalescePTS = CMTimeAdd(pts, duration)
            }
            if let outgoing = audioConverter.makeSampleBuffer(samples: slice, frames: frames, pts: pts, duration: duration) {
                hop.lock()
                // The final flush is bounded and runs after capture stopped; keep
                // every sample of it instead of applying the realtime cap.
                if preparedAudio.count >= Self.maxPreparedAudio && !flushing {
                    droppedAudioAtHop += 1
                } else {
                    preparedAudio.append(outgoing)
                }
                hop.unlock()
            } else {
                hop.lock()
                droppedAudioAtHop += 1
                hop.unlock()
            }
        }
    }

    private static func interleavedStereoFloats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= MemoryLayout<Float>.size * 2, length % MemoryLayout<Float>.size == 0 else { return nil }
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(1) }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr, !data.isEmpty else { return nil }
        return data
    }

    private func schedulePump() {
        hop.lock()
        if pumpScheduled {
            hop.unlock()
            return
        }
        pumpScheduled = true
        hop.unlock()
        writerQueue.async { self.pump() }
    }

    private func pump() {
        var madeProgress = true
        while madeProgress, !closed, writer.status == .writing, finishCompletion == nil {
            madeProgress = false
            pullVideoFromHop()
            startSessionIfNeeded()
            if flushPendingVideo() {
                madeProgress = true
            }
            if sessionStarted, flushPreparedAudio(limit: 4) {
                madeProgress = true
            }
        }
        hop.lock()
        let moreVideo = latestVideo != nil
        let moreAudio = !preparedAudio.isEmpty
        pumpScheduled = false
        hop.unlock()
        if !closed, finishCompletion == nil, madeProgress, moreVideo || moreAudio {
            schedulePump()
        }
    }

    private func pullVideoFromHop() {
        hop.lock()
        let buffer = latestVideo
        latestVideo = nil
        let overflow = droppedAtHop
        droppedAtHop = 0
        hop.unlock()
        if overflow > 0 {
            statsStorage.droppedVideo += overflow
        }
        guard let raw = buffer else { return }
        guard let buffer = applyPause(to: raw) else { return }
        if lastVideoPTS.isValid,
           CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer), lastVideoPTS) <= 0 {
            return
        }
        if pendingVideo != nil {
            statsStorage.droppedVideo += 1
        }
        pendingVideo = buffer
    }

    private func startSessionIfNeeded() {
        guard !sessionStarted, writer.status == .writing, let buffer = pendingVideo else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid && !pts.isIndefinite else { return }
        writer.startSession(atSourceTime: pts)
        sessionStarted = true
        sessionStart = pts
    }

    @discardableResult
    private func flushPendingVideo() -> Bool {
        guard !closed, writer.status == .writing, sessionStarted, let buffer = pendingVideo else {
            return false
        }
        guard videoInput.isReadyForMoreMediaData else { return false }
        if appendVideoNow(buffer) {
            pendingVideo = nil
            return true
        }
        return false
    }

    @discardableResult
    private func appendVideoNow(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if videoInput.append(sampleBuffer) {
            statsStorage.videoFrames += 1
            lastVideoSample = sampleBuffer
            lastVideoPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            return true
        }
        if writer.status == .failed {
            handleFailure()
        }
        return false
    }

    @discardableResult
    private func flushPreparedAudio(limit: Int) -> Bool {
        var appended = false
        var taken = 0
        while taken < limit, !closed, !audioGaveUp, sessionStarted, writer.status == .writing {
            hop.lock()
            let drops = droppedAudioAtHop
            droppedAudioAtHop = 0
            let hasBuffer = !preparedAudio.isEmpty
            let buffer = hasBuffer ? preparedAudio.removeFirst() : nil
            hop.unlock()
            if drops > 0 {
                statsStorage.droppedAudio += drops
            }
            guard let buffer else { break }
            guard let audioInput else { break }
            guard audioInput.isReadyForMoreMediaData else {
                hop.lock()
                preparedAudio.insert(buffer, at: 0)
                hop.unlock()
                break
            }
            taken += 1
            if writePreparedAudio(buffer) {
                appended = true
            }
        }
        return appended
    }

    /// Drops samples captured while paused and shifts later ones earlier by the paused time.
    private func applyPause(to buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let pauseClock else { return buffer }
        guard let shift = pauseClock.shift(for: CMSampleBufferGetPresentationTimeStamp(buffer)) else {
            statsStorage.pausedDropped += 1
            return nil
        }
        return PauseClock.shifted(buffer, by: shift)
    }

    @discardableResult
    private func writePreparedAudio(_ rawSample: CMSampleBuffer) -> Bool {
        guard !closed, sessionStarted, !audioGaveUp, writer.status == .writing else { return false }
        guard let audioInput else { return false }
        guard CMSampleBufferDataIsReady(rawSample), CMSampleBufferGetNumSamples(rawSample) > 0 else {
            return false
        }
        // Inside a pause: consumed without writing (return true so the queue keeps moving).
        guard let sampleBuffer = applyPause(to: rawSample) else { return true }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastAudioEndPTS.isValid, CMTimeSubtract(lastAudioEndPTS, pts).seconds > 0.001 {
            // Overlaps the audio written before a pause boundary; skip this chunk.
            statsStorage.pausedDropped += 1
            return true
        }
        if !firstPreparedAudioPTS.isValid { firstPreparedAudioPTS = pts }
        guard pts.isValid, CMTimeCompare(pts, sessionStart) >= 0 else {
            statsStorage.audioBeforeSession += 1
            return false
        }
        guard audioInput.isReadyForMoreMediaData else {
            return false
        }
        if audioInput.append(sampleBuffer) {
            statsStorage.audioFrames += 1
            rememberAudioEnd(sampleBuffer)
            return true
        }
        statsStorage.droppedAudio += 1
        if writer.status == .failed {
            handleFailure()
        } else if statsStorage.droppedAudio > 30 && statsStorage.audioFrames == 0 {
            audioGaveUp = true
        }
        return false
    }

    private func rememberAudioEnd(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite else { return }
        // End time is PTS plus the sample-count duration. A declared duration
        // on ScreenCaptureKit buffers can be valid but wrong.
        let samples = max(CMSampleBufferGetNumSamples(sampleBuffer), 0)
        let counted = CMTime(value: CMTimeValue(samples), timescale: 48_000)
        let end = samples > 0 ? CMTimeAdd(pts, counted) : pts
        if !lastAudioEndPTS.isValid || CMTimeCompare(end, lastAudioEndPTS) > 0 {
            lastAudioEndPTS = end
        }
    }

    private func handleFailure() {
        closed = true
        hop.lock()
        hopClosed = true
        hop.unlock()
        guard !failureSignaled else { return }
        failureSignaled = true
        onFailure?()
    }

    private func continueFinishing() {
        guard let completion = finishCompletion, !completing, !inputsMarked else { return }
        guard !closed || writer.status == .writing else {
            completeWriting(completion: completion)
            return
        }
        pullVideoFromHop()
        startSessionIfNeeded()
        _ = flushPendingVideo()
        _ = flushPreparedAudio(limit: 128)

        hop.lock()
        let audioLeft = !preparedAudio.isEmpty
        hop.unlock()
        let videoBlocked = pendingVideo != nil && !videoInput.isReadyForMoreMediaData
        let audioBlocked = audioLeft && !(audioInput?.isReadyForMoreMediaData ?? true)
        let waited = Date().timeIntervalSince(finishStartedAt ?? Date())

        if (videoBlocked || audioBlocked), writer.status == .writing, waited < 20 {
            armFinishWait()
            return
        }

        if let end = timelineEndPTS(),
           lastVideoPTS.isValid,
           CMTimeCompare(end, lastVideoPTS) > 0,
           CMTimeSubtract(end, lastVideoPTS).seconds > 0.02,
           let source = lastVideoSample,
           writer.status == .writing {
            let gap = CMTimeSubtract(end, lastVideoPTS).seconds
            if let freeze = Self.retimedSample(from: source, at: end) {
                if videoInput.isReadyForMoreMediaData, appendVideoNow(freeze) {
                    Self.log.info("extended last video frame to end PTS, gap=\(gap, format: .fixed(precision: 3))s")
                } else if waited < 20 {
                    armFinishWait()
                    return
                } else {
                    Self.log.error("could not append freeze frame after \(waited, format: .fixed(precision: 2))s, gap=\(gap, format: .fixed(precision: 3))s")
                }
            } else {
                Self.log.error("could not build freeze frame to align video with audio")
            }
        }

        completeWriting(completion: completion)
    }

    private func armFinishWait() {
        if !finishReadyArmed {
            finishReadyArmed = true
            // Pull-only wait after capture has stopped. Do not use this during the take.
            videoInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
                self?.continueFinishing()
            }
            audioInput?.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
                self?.continueFinishing()
            }
        }
        writerQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.continueFinishing()
        }
    }

    private func timelineEndPTS() -> CMTime? {
        var end: CMTime = .invalid
        if lastAudioEndPTS.isValid {
            end = lastAudioEndPTS
        }
        if lastVideoPTS.isValid, !end.isValid || CMTimeCompare(lastVideoPTS, end) > 0 {
            end = lastVideoPTS
        }
        return end.isValid ? end : nil
    }

    private func completeWriting(completion: @escaping (Result<Stats, Error>) -> Void) {
        guard !completing else { return }
        completing = true
        finishCompletion = nil
        let firstAudio = firstPreparedAudioPTS.isValid ? String(format: "%.3f", firstPreparedAudioPTS.seconds) : "nil"
        let audioEnd = lastAudioEndPTS.isValid ? String(format: "%.3f", lastAudioEndPTS.seconds) : "nil"
        statsStorage.audioNote = "sessionStart=\(String(format: "%.3f", sessionStart.seconds)) firstAudioPTS=\(firstAudio) audioEnd=\(audioEnd) beforeSession=\(statsStorage.audioBeforeSession) \(mixerNote)"
        statsStorage.sessionStartSeconds = sessionStarted ? sessionStart.seconds : 0
        let current = statsStorage
        Self.log.info("writer audio \(current.audioNote, privacy: .public)")
        Self.log.info("writer finish video=\(current.videoFrames) audio=\(current.audioFrames) droppedVideo=\(current.droppedVideo) droppedAudio=\(current.droppedAudio)")
        if writer.status == .failed || current.videoFrames == 0 {
            let error = writer.error ?? CaptureError.nothingRecorded
            if writer.status == .writing {
                writer.cancelWriting()
            }
            closed = true
            completion(.failure(error))
            return
        }
        guard !inputsMarked else {
            completion(.failure(CaptureError.exportFailed("写入已结束。")))
            return
        }
        inputsMarked = true
        closed = true
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? CaptureError.exportFailed("未知错误")))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer] in
            if writer.status == .completed {
                completion(.success(current))
            } else {
                let message = writer.error?.localizedDescription ?? "未知错误"
                completion(.failure(CaptureError.exportFailed(message)))
            }
        }
    }

    private static func retimedSample(from source: CMSampleBuffer, at pts: CMTime) -> CMSampleBuffer? {
        guard let image = CMSampleBufferGetImageBuffer(source) else { return nil }
        var format = CMSampleBufferGetFormatDescription(source)
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: image,
                formatDescriptionOut: &format
            )
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else { return nil }
        return output
    }

    private static func bitRate(width: Int, height: Int, framesPerSecond: Int) -> Int {
        let pixels = Double(width * height)
        let fps = Double(max(framesPerSecond, 1))
        // About 0.12 bits per pixel at the selected fps, clamped so 1080p stays near 8 Mbps at 30 fps and 4K stays real-time.
        let estimate = pixels * fps * 0.12
        return Int(min(max(estimate, 6_000_000), 20_000_000))
    }

    private struct WriterParts {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
    }

    private static func videoSettings(width: Int, height: Int, framesPerSecond: Int, requireHardware: Bool) -> [String: Any] {
        var encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]
        if requireHardware {
            encoderSpec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        let fps = max(framesPerSecond, 1)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoEncoderSpecificationKey: encoderSpec,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(width: width, height: height, framesPerSecond: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                kVTCompressionPropertyKey_RealTime as String: true
            ]
        ]
    }

    private static func makeWriterParts(
        partialURL: URL,
        width: Int,
        height: Int,
        capturesAudio: Bool,
        framesPerSecond: Int,
        audioConverter: AudioSampleConverter,
        requireHardware: Bool
    ) throws -> WriterParts {
        let writer = try AVAssetWriter(outputURL: partialURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        // Periodic fragments make a crash more likely to leave a usable .partial.mp4.
        // This does not finish or reopen the writer mid-take; finishWriting still finalizes the file.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(width: width, height: height, framesPerSecond: framesPerSecond, requireHardware: requireHardware)
        )
        videoInput.expectsMediaDataInRealTime = true
        videoInput.performsMultiPassEncodingIfSupported = false
        guard writer.canAdd(videoInput) else {
            throw CaptureError.exportFailed("无法添加 H.264 视频轨。")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if capturesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: NSNumber(value: UInt32(kAudioFormatMPEG4AAC)),
                AVSampleRateKey: NSNumber(value: 48_000),
                AVNumberOfChannelsKey: NSNumber(value: 2),
                AVEncoderBitRateKey: NSNumber(value: 128_000)
            ]
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings,
                sourceFormatHint: audioConverter.outputFormatHint
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "LJM" as NSString
        let software = AVMutableMetadataItem()
        software.identifier = .commonIdentifierSoftware
        software.value = "LJM" as NSString
        writer.metadata = [title, software]

        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.exportFailed("AVAssetWriter 无法开始。")
        }
        return WriterParts(writer: writer, videoInput: videoInput, audioInput: audioInput)
    }

    static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
              let dictionary = attachments.first else {
            return nil
        }
        let key = SCStreamFrameInfo.status.rawValue as NSString
        if let number = dictionary[key] as? NSNumber {
            return SCFrameStatus(rawValue: number.intValue)
        }
        return nil
    }
}

/// Converts ScreenCaptureKit audio into interleaved stereo Float32 at 48 kHz,
/// which is what the AAC `AVAssetWriterInput` is configured to accept.
final class AudioSampleConverter {
    let outputFormat: AVAudioFormat
    let outputFormatHint: CMFormatDescription?
    private var converter: AVAudioConverter?
    private var converterInputSignature: String?

    init() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        outputFormat = format
        outputFormatHint = Self.makeFormatHint(format)
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let converted = convertToPCM(sampleBuffer) else { return nil }
        return Self.makeSampleBuffer(from: converted.buffer, pts: converted.pts, duration: converted.duration, formatHint: outputFormatHint)
    }

    func convertToPCM(_ sampleBuffer: CMSampleBuffer) -> (buffer: AVAudioPCMBuffer, pts: CMTime, duration: CMTime)? {
        guard let inputFormat = Self.inputFormat(of: sampleBuffer) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        let signature = "\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(inputFormat.commonFormat.rawValue)-\(inputFormat.isInterleaved)"
        if converter == nil || converterInputSignature != signature {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputSignature = signature
        }
        guard let converter else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else {
            return nil
        }
        inputBuffer.frameLength = frames
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copied == noErr else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var conversionError: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil, status != .error, outputBuffer.frameLength > 0 else {
            return nil
        }
        // Always derive duration from the converted PCM. A declared duration on
        // the source buffer can be valid but wrong, which would desync the file.
        duration = CMTime(
            value: CMTimeValue(outputBuffer.frameLength),
            timescale: CMTimeScale(outputFormat.sampleRate)
        )
        return (outputBuffer, pts, duration)
    }

    func makeSampleBuffer(samples: [Float], frames: Int, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        guard frames > 0, samples.count >= frames * 2 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let data = list.first?.mData else { return nil }
        samples.prefix(frames * 2).withUnsafeBufferPointer { pointer in
            data.copyMemory(from: pointer.baseAddress!, byteCount: frames * 2 * MemoryLayout<Float>.size)
        }
        return Self.makeSampleBuffer(from: buffer, pts: pts, duration: duration, formatHint: outputFormatHint)
    }

    private static func inputFormat(of sampleBuffer: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }
        let asbd = pointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else {
            return nil
        }
        var copy = asbd
        if let format = withUnsafePointer(to: &copy, { AVAudioFormat(streamDescription: $0) }) {
            return format
        }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let common: AVAudioCommonFormat
        if isFloat && asbd.mBitsPerChannel == 32 {
            common = .pcmFormatFloat32
        } else if !isFloat && asbd.mBitsPerChannel == 16 {
            common = .pcmFormatInt16
        } else if !isFloat && asbd.mBitsPerChannel == 32 {
            common = .pcmFormatInt32
        } else {
            return nil
        }
        return AVAudioFormat(
            commonFormat: common,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(max(1, asbd.mChannelsPerFrame)),
            interleaved: interleaved
        )
    }

    private static func makeFormatHint(_ format: AVAudioFormat) -> CMFormatDescription? {
        var asbd = format.streamDescription.pointee
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        pts: CMTime,
        duration: CMTime,
        formatHint: CMFormatDescription?
    ) -> CMSampleBuffer? {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let first = audioBuffers.first, let data = first.mData else { return nil }
        let dataSize = Int(first.mDataByteSize)
        guard dataSize > 0 else { return nil }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = CMBlockBufferReplaceDataBytes(
            with: data,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        guard status == kCMBlockBufferNoErr else { return nil }

        let format = formatHint ?? makeFormatHint(buffer.format)
        guard let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
