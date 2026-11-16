import CoreMedia
import Foundation

/// Pause intervals of one take, in host-clock time (the clock ScreenCaptureKit
/// stamps samples with). Samples inside a pause are dropped; samples after a
/// pause are shifted earlier by the total paused time, so the file stays
/// continuous and audio/video stay in sync. Thread-safe.
final class PauseClock: @unchecked Sendable {
    private struct Interval {
        var start: CMTime
        var end: CMTime?
    }

    private let lock = NSLock()
    private var intervals: [Interval] = []

    static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return intervals.last.map { $0.end == nil } ?? false
    }

    var pauseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return intervals.count
    }

    /// Total closed + open paused seconds up to now.
    var pausedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Self.now()
        return intervals.reduce(0) { sum, interval in
            sum + CMTimeSubtract(interval.end ?? now, interval.start).seconds
        }
    }

    func reset() {
        lock.lock()
        intervals.removeAll()
        lock.unlock()
    }

    func pause(at time: CMTime = PauseClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        if let last = intervals.last, last.end == nil { return }
        intervals.append(Interval(start: time, end: nil))
    }

    func resume(at time: CMTime = PauseClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        guard var last = intervals.last, last.end == nil else { return }
        last.end = CMTimeMaximum(time, last.start)
        intervals[intervals.count - 1] = last
    }

    /// nil means "drop this sample" (it falls inside a pause); otherwise the
    /// amount to subtract from its presentation time.
    func shift(for pts: CMTime) -> CMTime? {
        guard pts.isValid, !pts.isIndefinite else { return .zero }
        lock.lock()
        defer { lock.unlock() }
        var total = CMTime.zero
        for interval in intervals {
            if CMTimeCompare(pts, interval.start) < 0 { break }
            guard let end = interval.end else { return nil }
            if CMTimeCompare(pts, end) < 0 { return nil }
            total = CMTimeAdd(total, CMTimeSubtract(end, interval.start))
        }
        return total
    }

    /// Copy of `buffer` moved earlier by `shift` (timing only; data shared).
    static func shifted(_ buffer: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(shift, .zero) == 0 { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, shift)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, shift)
            }
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }
}
