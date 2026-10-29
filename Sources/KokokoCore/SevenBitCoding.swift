import Foundation

/// 7-bit packing for SysEx payloads: every group of 7 data bytes is preceded
/// by one header byte holding the high bits (bit i = high bit of byte i).
public enum SevenBitCoding {
    public static func packedLength(for n: Int) -> Int {
        n + (n + 6) / 7
    }

    public static func pack(_ src: [UInt8]) -> [UInt8] {
        if src.isEmpty { return [] }
        var out = [UInt8](repeating: 0, count: packedLength(for: src.count))
        var o = 1
        var hdr = 0
        for (c, b) in src.enumerated() {
            let d = c % 7
            out[hdr] |= (b >> 7) << d
            out[o] = b & 0x7F
            o += 1
            if d == 6 && c < src.count - 1 {
                hdr += 8
                o += 1
            }
        }
        return out
    }

    public static func unpack(_ src: [UInt8]) -> [UInt8] {
        if src.isEmpty { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        var header: UInt8 = 0
        var bit = 0
        var c = 0
        while c < src.count {
            if c == 0 || bit > 6 {
                header = src[c]
                bit = 0
                c += 1
                continue
            }
            let high: UInt8 = (header & (1 << bit)) != 0 ? 0x80 : 0
            out.append(high | (src[c] & 0x7F))
            bit += 1
            c += 1
        }
        return out
    }
}
