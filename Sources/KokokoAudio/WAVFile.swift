import Foundation

/// Minimal RIFF/WAV reader: enough to find fmt/data/smpl chunks.
public struct WAVInfo: Equatable, Sendable {
    public var channels: Int
    public var sampleRate: Int
    public var bitsPerSample: Int
    public var dataRange: Range<Int>
    public var midiRootNote: Int?
    public var loopStart: UInt32?
    public var loopEnd: UInt32?
}

public enum WAVError: Error {
    case notRIFF
    case notWAVE
    case missingFormat
    case missingData
}

public func parseWAV(_ bytes: [UInt8]) throws -> WAVInfo {
    func u32(_ o: Int) -> UInt32 {
        UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
    }
    func u16(_ o: Int) -> UInt16 {
        UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
    }
    guard bytes.count >= 12,
          bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 // RIFF
    else { throw WAVError.notRIFF }
    guard bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 // WAVE
    else { throw WAVError.notWAVE }

    var channels = 0, sampleRate = 0, bits = 0
    var dataRange: Range<Int>?
    var rootNote: Int?
    var loopStart: UInt32?, loopEnd: UInt32?

    var offset = 12
    while offset + 8 <= bytes.count {
        let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
        let size = Int(u32(offset + 4))
        let body = offset + 8
        guard body + size <= bytes.count else { break }
        switch id {
        case "fmt ":
            guard size >= 16 else { break }
            channels = Int(u16(body + 2))
            sampleRate = Int(u32(body + 4))
            bits = Int(u16(body + 14))
        case "data":
            dataRange = body..<(body + size)
        case "smpl":
            // smpl: 9 u32 header, then loop count + sampler data, then loops
            if size >= 36 {
                rootNote = Int(u32(body + 12))
                let loopCount = Int(u32(body + 28))
                if loopCount > 0, size >= 36 + 24 {
                    loopStart = u32(body + 36 + 8)
                    loopEnd = u32(body + 36 + 12)
                }
            }
        default:
            break
        }
        offset = body + size + (size & 1)
    }

    guard channels > 0, sampleRate > 0, bits > 0 else { throw WAVError.missingFormat }
    guard let dataRange else { throw WAVError.missingData }
    return WAVInfo(channels: channels, sampleRate: sampleRate, bitsPerSample: bits,
                   dataRange: dataRange, midiRootNote: rootNote,
                   loopStart: loopStart, loopEnd: loopEnd)
}

/// Write a canonical 16-bit PCM WAV.
public func makeWAV(pcm: [UInt8], channels: Int, sampleRate: Int) -> [UInt8] {
    let byteRate = UInt32(sampleRate * channels * 2)
    let blockAlign = UInt16(channels * 2)
    var out: [UInt8] = []
    func appendASCII(_ s: String) { out.append(contentsOf: s.utf8) }
    func appendU32LE(_ v: UInt32) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }
    func appendU16LE(_ v: UInt16) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    }
    appendASCII("RIFF")
    appendU32LE(UInt32(36 + pcm.count))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendU32LE(16)
    appendU16LE(1) // PCM
    appendU16LE(UInt16(channels))
    appendU32LE(UInt32(sampleRate))
    appendU32LE(byteRate)
    appendU16LE(blockAlign)
    appendU16LE(16)
    appendASCII("data")
    appendU32LE(UInt32(pcm.count))
    out.append(contentsOf: pcm)
    return out
}
