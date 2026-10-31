import CoreMIDI
import KokokoMIDI

extension KokokoCoreChecks {
    static func eventListChecks() {
        // CoreMIDI may coalesce separate deliveries into one list; distinct
        // timestamps keep MIDIEventListAdd from merging them into one packet.
        let first: [UInt32] = (0..<100).map { 0x3020_0000 | UInt32($0) }
        let second: [UInt32] = (100..<110).map { 0x3030_0000 | UInt32($0) }
        let size = 4096
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIEventList.self)
        var packet = MIDIEventListInit(list, ._1_0)
        first.withUnsafeBufferPointer { packet = MIDIEventListAdd(list, size, packet, 1, $0.count, $0.baseAddress!) }
        second.withUnsafeBufferPointer { packet = MIDIEventListAdd(list, size, packet, 2, $0.count, $0.baseAddress!) }
        eq(list.pointee.numPackets, 2, "event list holds two packets")

        var words: [UInt32] = []
        forEachWord(in: list) { words.append($0) }
        eq(words, first + second, "forEachWord walks every packet in order")

        var empty = MIDIEventList()
        empty.protocol = ._1_0
        var emptyWords: [UInt32] = []
        forEachWord(in: &empty) { emptyWords.append($0) }
        eq(emptyWords, [], "forEachWord on an empty list yields nothing")
    }
}
