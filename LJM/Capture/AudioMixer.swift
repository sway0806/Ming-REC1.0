import AVFoundation
import CoreMedia

/// Mixes system audio and microphone into one interleaved stereo 48 kHz PCM stream, aligned by PTS.
/// Lives only on the writer's audio prep queue. When a single source is active, do not use this type.
final class SystemMicMixer {
    private let systemConverter = AudioSampleConverter()
    private let micConverter = AudioSampleConverter()
    private var systemPending: [Pending] = []
    private var micPending: [Pending] = []
    private let timescale: CMTimeScale = 48_000
    private let maxHold = CMTime(value: 3_840, timescale: 48_000) // 80 ms
    /// Align starts within 2 ms instead of walking one sample at a time.
    private let alignSlop = 96
    /// Diagnostics for the writer log: first start offset seen between the two
    /// sources (positive = mic later), and how many lead-only realignments ran.
    private(set) var firstOffsetFrames: Int?
    private(set) var realignCount = 0
    private var firstSystemPTS: CMTime = .invalid
    private var firstMicPTS: CMTime = .invalid
    private var systemIn = 0
    private var micIn = 0
    var sourceNote: String {
        let sys = firstSystemPTS.isValid ? String(format: "%.3f", firstSystemPTS.seconds) : "nil"
        let mic = firstMicPTS.isValid ? String(format: "%.3f", firstMicPTS.seconds) : "nil"
        return "systemIn=\(systemIn) micIn=\(micIn) firstSystemPTS=\(sys) firstMicPTS=\(mic)"
    }
    var pendingFrames: (system: Int, mic: Int) {
        (systemPending.reduce(0) { $0 + $1.frames }, micPending.reduce(0) { $0 + $1.frames })
    }

    private struct Pending {
        var pts: CMTime
        var samples: [Float] // interleaved stereo
        var frames: Int { samples.count / 2 }
        var endPTS: CMTime {
            CMTimeAdd(pts, CMTime(value: CMTimeValue(samples.count / 2), timescale: 48_000))
        }
    }

    func ingestSystem(_ sampleBuffer: CMSampleBuffer) -> [CMSampleBuffer] {
        if let pending = convert(sampleBuffer, using: systemConverter) {
            if !firstSystemPTS.isValid { firstSystemPTS = pending.pts }
            systemIn += 1
            systemPending.append(pending)
        }
        return emit(flushing: false)
    }

    func ingestMicrophone(_ sampleBuffer: CMSampleBuffer) -> [CMSampleBuffer] {
        if let pending = convert(sampleBuffer, using: micConverter) {
            if !firstMicPTS.isValid { firstMicPTS = pending.pts }
            micIn += 1
            micPending.append(pending)
        }
        return emit(flushing: false)
    }

    func flush() -> [CMSampleBuffer] {
        emit(flushing: true)
    }

    private func convert(_ sampleBuffer: CMSampleBuffer, using converter: AudioSampleConverter) -> Pending? {
        guard let converted = converter.convertToPCM(sampleBuffer) else { return nil }
        guard let samples = Self.floats(from: converted.buffer), !samples.isEmpty else { return nil }
        return Pending(pts: converted.pts, samples: samples)
    }

    private func emit(flushing: Bool) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        while let buffer = popChunk(flushing: flushing) {
            output.append(buffer)
        }
        return output
    }

    private func popChunk(flushing: Bool) -> CMSampleBuffer? {
        dropEmpty()
        let hasSystem = !systemPending.isEmpty
        let hasMic = !micPending.isEmpty
        guard hasSystem || hasMic else { return nil }

        if hasSystem && hasMic {
            let systemStart = systemPending[0].pts
            let micStart = micPending[0].pts
            let lead = frames(from: systemStart, to: micStart)
            let lag = frames(from: micStart, to: systemStart)
            if firstOffsetFrames == nil {
                firstOffsetFrames = lead > 0 ? lead : -lag
            }
            // A sub-sample or few-sample offset used to emit 1-frame chunks in a
            // tight loop and flood the writer (millions of drops, audio stopping early).
            if lead <= alignSlop && lag <= alignSlop {
                if systemStart < micStart {
                    micPending[0].pts = systemStart
                } else if micStart < systemStart {
                    systemPending[0].pts = micStart
                }
                let overlap = min(systemPending[0].frames, micPending[0].frames)
                return consume(system: true, mic: true, frames: max(overlap, 1))
            }
            // Offset is larger than the snap window. The later source can never
            // deliver anything earlier than its first pending PTS, so the lead of
            // the earlier source is final: emit it now. (This used to wait for
            // the lead to reach ~10 ms. A steady 2–10 ms offset between the
            // system and mic clocks never grows, so the mixer held everything
            // until stop and the flush burst overflowed the writer: ~0.4 s of
            // audio in a 30 s take.) Small pieces are merged downstream into
            // ~1024-frame buffers, so this does not flood the writer.
            if systemStart < micStart {
                realignCount += 1
                return consume(system: true, mic: false, frames: max(lead, 1))
            }
            if micStart < systemStart {
                realignCount += 1
                return consume(system: false, mic: true, frames: max(lag, 1))
            }
            let overlap = min(systemPending[0].frames, micPending[0].frames)
            return consume(system: true, mic: true, frames: overlap)
        }

        if !flushing {
            let pending = hasSystem ? systemPending[0] : micPending[0]
            let queued = CMTimeSubtract((hasSystem ? systemPending.last! : micPending.last!).endPTS, pending.pts)
            if queued < maxHold { return nil }
        }
        let frames = hasSystem ? systemPending[0].frames : micPending[0].frames
        return consume(system: hasSystem, mic: hasMic, frames: frames)
    }

    private func consume(system: Bool, mic: Bool, frames: Int) -> CMSampleBuffer? {
        let start: CMTime
        if system, let first = systemPending.first {
            start = first.pts
        } else if mic, let first = micPending.first {
            start = first.pts
        } else {
            return nil
        }
        var mixed = [Float](repeating: 0, count: frames * 2)
        if system { add(from: &systemPending, into: &mixed, frames: frames) }
        if mic { add(from: &micPending, into: &mixed, frames: frames) }
        clamp(&mixed)
        let duration = CMTime(value: CMTimeValue(frames), timescale: timescale)
        return systemConverter.makeSampleBuffer(samples: mixed, frames: frames, pts: start, duration: duration)
    }

    private func add(from queue: inout [Pending], into mixed: inout [Float], frames: Int) {
        var remaining = frames
        var offset = 0
        while remaining > 0, !queue.isEmpty {
            let take = min(remaining, queue[0].frames)
            let count = take * 2
            let slice = queue[0].samples.prefix(count)
            for (index, value) in slice.enumerated() {
                mixed[offset + index] += value
            }
            offset += count
            remaining -= take
            if take == queue[0].frames {
                queue.removeFirst()
            } else {
                queue[0].samples.removeFirst(count)
                queue[0].pts = CMTimeAdd(queue[0].pts, CMTime(value: CMTimeValue(take), timescale: timescale))
            }
        }
    }

    private func clamp(_ samples: inout [Float]) {
        for i in samples.indices {
            if samples[i] > 1 { samples[i] = 1 }
            else if samples[i] < -1 { samples[i] = -1 }
        }
    }

    private func frames(from start: CMTime, to end: CMTime) -> Int {
        let seconds = CMTimeSubtract(end, start).seconds
        return max(0, Int((seconds * Double(timescale)).rounded(.down)))
    }

    private func dropEmpty() {
        systemPending.removeAll { $0.frames == 0 }
        micPending.removeAll { $0.frames == 0 }
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let count = frames * 2
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let data = list.first?.mData else { return nil }
        let pointer = data.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}
