import Foundation
import KokokoMIDI

extension KokokoCoreChecks {
    static func umpChecks() {
        // Round trip: short message
        let short: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0xF7]
        let asm1 = UMPAssembler()
        eq(asm1.feed(UMPCodec.encodeSysEx(short)), [short], "ump short round trip")

        // 1022-byte message split across two feeds like CoreMIDI delivered it
        var big: [UInt8] = [0xF0]
        for i in 0..<1020 { big.append(UInt8((i * 7) & 0xFF)) }
        big.append(0xF7)
        let words = UMPCodec.encodeSysEx(big)
        eq(words.count, 340, "ump word count for 1022 bytes")
        let asm2 = UMPAssembler()
        let part1 = Array(words[0..<192])
        let part2 = Array(words[192..<340])
        eq(asm2.feed(part1).count, 0, "no message after first part")
        let done = asm2.feed(part2)
        eq(done.count, 1, "one message after second part")
        eq(done.first, big, "ump big round trip")
    }
}
