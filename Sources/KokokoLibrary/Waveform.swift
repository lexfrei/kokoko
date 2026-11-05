import Foundation

/// A sound reduced to one peak per column of the waveform view, with its loop
/// points when the metadata holds a usable pair.
public struct Waveform: Equatable, Sendable {
    public let frameCount: Int
    public let sampleRate: Int
    /// Loudest sample of each column, 0 for silence to 1 for full scale.
    public let peaks: [Double]
    public let loopStart: Int?
    public let loopEnd: Int?
    /// Why the metadata's loop points are not drawn, when it has any.
    private let loopProblem: String?

    /// `pcm` is signed 16-bit little-endian, channels interleaved. Loop points
    /// are frame indexes, the end included; a pair outside the sound or out of
    /// order is not shown.
    public init(pcm: [UInt8], channels: Int, sampleRate: Int, columns: Int, loopStart: Int?, loopEnd: Int?) {
        let width = max(channels, 1) * 2
        let frames = pcm.count / width
        func sample(_ index: Int) -> Int {
            Int(Int16(bitPattern: UInt16(pcm[index]) | UInt16(pcm[index + 1]) << 8))
        }
        let peaks: [Double] = (0..<max(columns, 0)).map { column in
            guard frames > 0 else { return 0 }
            var loudest = 0
            for frame in Self.frames(ofColumn: column, columns: columns, frameCount: frames) {
                for channel in 0..<max(channels, 1) {
                    loudest = max(loudest, abs(sample(frame * width + channel * 2)))
                }
            }
            return Double(loudest) / 32768
        }
        self.init(frameCount: frames, sampleRate: sampleRate, peaks: peaks, loopStart: loopStart, loopEnd: loopEnd)
    }

    public init(record: WaveformPeakRecord, columns: Int, loopStart: Int?, loopEnd: Int?) {
        let count = min(max(columns, 0), 512)
        let peaks = (0..<count).map { column in
            let lower = column * record.peaks.count / count
            let upper = max(lower + 1, (column + 1) * record.peaks.count / count)
            return record.peaks[lower..<upper].max() ?? 0
        }
        self.init(frameCount: record.frameCount, sampleRate: record.sampleRate, peaks: peaks,
                  loopStart: loopStart, loopEnd: loopEnd)
    }

    private init(frameCount: Int, sampleRate: Int, peaks: [Double], loopStart: Int?, loopEnd: Int?) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.peaks = peaks
        switch (loopStart, loopEnd) {
        case (nil, nil):
            loopProblem = nil
        case (let start?, let end?):
            // The end is the last frame played, as in a WAV smpl chunk.
            loopProblem = start < 0 || end >= frameCount ? "loop points outside the sound"
                : start > end ? "loop end before loop start"
                : nil
        default:
            loopProblem = "only one loop point"
        }
        let usable = loopStart != nil && loopEnd != nil && loopProblem == nil
        self.loopStart = usable ? loopStart : nil
        self.loopEnd = usable ? loopEnd : nil
    }

    /// The frames a column's peak is taken from. With fewer frames than
    /// columns, one frame spans several columns.
    private static func frames(ofColumn column: Int, columns: Int, frameCount: Int) -> Range<Int> {
        let lower = min(column * frameCount / columns, frameCount - 1)
        let upper = max(lower + 1, min((column + 1) * frameCount / columns, frameCount))
        return lower..<upper
    }

    private func frames(ofColumn column: Int) -> Range<Int> {
        Self.frames(ofColumn: column, columns: peaks.count, frameCount: frameCount)
    }

    /// The first column whose peak includes `frame`.
    public func column(ofFrame frame: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let clamped = min(max(frame, 0), frameCount - 1)
        return peaks.indices.first { frames(ofColumn: $0).contains(clamped) } ?? 0
    }

    /// The columns whose peaks include a frame of the loop.
    public var loopColumns: ClosedRange<Int>? {
        let inside = peaks.indices.filter(isInsideLoop)
        guard let first = inside.first, let last = inside.last else { return nil }
        return first...last
    }

    public func isInsideLoop(column: Int) -> Bool {
        guard let loopStart, let loopEnd, frameCount > 0, peaks.indices.contains(column) else { return false }
        let range = frames(ofColumn: column)
        return range.lowerBound <= loopEnd && range.upperBound > loopStart
    }

    /// The loop as shown under the drawing and read by VoiceOver.
    public var loopDescription: String {
        guard let loopStart, let loopEnd else { return loopProblem ?? "no loop points" }
        return "loop from \(seconds(loopStart)) to \(seconds(loopEnd))"
    }

    /// What VoiceOver reads for the whole waveform.
    public var summary: String { "Waveform, \(seconds(frameCount)), \(loopDescription)" }

    private func seconds(_ frames: Int) -> String {
        String(format: "%.2f s", Double(frames) / Double(max(sampleRate, 1)))
    }
}
