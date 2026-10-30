import Foundation
import KokokoAudio

extension KokokoCoreChecks {
    static func audioChecks() throws {
        // WAV round trip: make → parse
        let pcm: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80]
        let wav = makeWAV(pcm: pcm, channels: 1, sampleRate: 46875)
        let info = try parseWAV(wav)
        eq(info.channels, 1, "wav channels")
        eq(info.sampleRate, 46875, "wav rate")
        eq(info.bitsPerSample, 16, "wav bits")
        eq(Array(wav[info.dataRange]), pcm, "wav data round trip")

        // Fast path: device-format WAV passes through untouched
        let prepared = try prepareForUpload(fileData: Data(wav), fileName: "kick.wav")
        eq(prepared.pcm, pcm, "fast path raw pcm")
        eq(prepared.sampleRate, 46875, "fast path rate")
        eq(prepared.channels, 1, "fast path channels")
        eq(prepared.metadata["samplerate"]?.intValue, 46875, "fast path metadata")

        // Resample path: 93750 Hz mono s16 → 46875
        var srcPCM: [UInt8] = []
        for i in 0..<2000 {
            let v = Int16(sin(Double(i) / 10.0) * 10000)
            srcPCM.append(UInt8(UInt16(bitPattern: v) & 0xFF))
            srcPCM.append(UInt8(UInt16(bitPattern: v) >> 8))
        }
        let srcWAV = makeWAV(pcm: srcPCM, channels: 1, sampleRate: 93750)
        let resampled = try prepareForUpload(fileData: Data(srcWAV), fileName: "hihat.wav")
        eq(resampled.sampleRate, 46875, "resampled rate")
        let expectedFrames = 1000 // 2000 frames at 2x rate → 1000 at 1x
        let gotFrames = resampled.pcm.count / 2
        check(abs(gotFrames - expectedFrames) <= 8,
              "resampled length ~\(expectedFrames) frames, got \(gotFrames)")

        // Too-long rejection
        let longPCM = [UInt8](repeating: 0, count: 46875 * 2 * 41)
        let longWAV = makeWAV(pcm: longPCM, channels: 1, sampleRate: 44100)
        do {
            _ = try prepareForUpload(fileData: Data(longWAV), fileName: "long.wav")
            check(false, "too-long accepted")
        } catch SoundPrepError.tooLong {
            check(true, "too-long rejected")
        }
    }
}
