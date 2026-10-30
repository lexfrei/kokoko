import Foundation

/// MIDI 1.0 SysEx over UMP (message type 3, SysEx7): each 64-bit UMP packet
/// carries up to 6 data bytes with start/continue/end framing. F0/F7 are not
/// transmitted; the decoder re-adds them.
public enum UMPCodec {
    /// Encode one complete SysEx message (F0 ... F7) into UMP words.
    public static func encodeSysEx(_ message: [UInt8]) -> [UInt32] {
        var data = message
        if data.first == 0xF0 { data.removeFirst() }
        if data.last == 0xF7 { data.removeLast() }

        var words: [UInt32] = []
        var offset = 0
        while true {
            let remaining = data.count - offset
            let chunkCount = min(remaining, 6)
            let status: UInt32
            if offset == 0 && remaining <= 6 {
                status = 0 // complete
            } else if offset == 0 {
                status = 1 // start
            } else if remaining <= 6 {
                status = 3 // end
            } else {
                status = 2 // continue
            }
            var dataBytes: [UInt8] = Array(data[offset..<(offset + chunkCount)])
            while dataBytes.count < 6 { dataBytes.append(0) }
            let word0 = (0x3 << 28) | (0 << 24) | (status << 20) | (UInt32(chunkCount) << 16)
                | (UInt32(dataBytes[0]) << 8) | UInt32(dataBytes[1])
            let word1 = (UInt32(dataBytes[2]) << 24) | (UInt32(dataBytes[3]) << 16)
                | (UInt32(dataBytes[4]) << 8) | UInt32(dataBytes[5])
            words.append(word0)
            words.append(word1)
            offset += chunkCount
            if remaining <= 6 { break }
        }
        if data.isEmpty {
            // Complete empty SysEx: F0 F7 only.
            words = [(0x3 << 28) | (0 << 20) | (2 << 16), 0]
        }
        return words
    }
}

/// Stateful UMP SysEx7 decoder: feed words, get complete F0..F7 messages.
public final class UMPAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var partial: [UInt8] = []
    public var onMessage: (@Sendable ([UInt8]) -> Void)?

    public init() {}

    /// Returns complete messages contained in the given words.
    public func feed(_ words: [UInt32]) -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        var out: [[UInt8]] = []
        var i = 0
        while i + 1 < words.count {
            let w0 = words[i], w1 = words[i + 1]
            i += 2
            guard (w0 >> 28) & 0xF == 0x3 else { continue }
            let status = (w0 >> 20) & 0xF
            let count = Int((w0 >> 16) & 0xF)
            let bytes: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
                                  UInt8((w1 >> 24) & 0xFF), UInt8((w1 >> 16) & 0xFF),
                                  UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
            let chunk = Array(bytes.prefix(count))
            switch status {
            case 0:
                out.append([0xF0] + chunk + [0xF7])
                partial = []
            case 1:
                partial = chunk
            case 2:
                partial.append(contentsOf: chunk)
            case 3:
                partial.append(contentsOf: chunk)
                out.append([0xF0] + partial + [0xF7])
                partial = []
            default:
                break
            }
        }
        return out
    }
}
