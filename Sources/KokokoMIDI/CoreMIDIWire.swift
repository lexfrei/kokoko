import CoreMIDI
import Foundation
import KokokoCore

public struct MIDIEndpointPair: Sendable, Identifiable {
    public let id: MIDIUniqueID
    public let name: String
    public let source: MIDIEndpointRef
    public let destination: MIDIEndpointRef
}

public enum CoreMIDIError: Error {
    case osStatus(String, OSStatus)
}

func midiName(of object: MIDIObjectRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(object, kMIDIPropertyName, &name)
    return (name?.takeUnretainedValue() as String?) ?? "unknown"
}

/// Enumerate MIDI entities that expose both a source and a destination.
/// Standalone virtual endpoints (no entity) are paired by name.
public func enumerateMIDIPairs() -> [MIDIEndpointPair] {
    var pairs: [MIDIEndpointPair] = []
    let deviceCount = MIDIGetNumberOfDevices()
    for d in 0..<deviceCount {
        let device = MIDIGetDevice(d)
        let entityCount = MIDIDeviceGetNumberOfEntities(device)
        for e in 0..<entityCount {
            let entity = MIDIDeviceGetEntity(device, e)
            let source = MIDIEntityGetSource(entity, 0)
            let destination = MIDIEntityGetDestination(entity, 0)
            guard source != 0, destination != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &uid)
            pairs.append(MIDIEndpointPair(id: uid, name: midiName(of: destination),
                                          source: source, destination: destination))
        }
    }

    var looseSources: [String: MIDIEndpointRef] = [:]
    for i in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(i)
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0 { continue }
        looseSources[midiName(of: source)] = source
    }
    for i in 0..<MIDIGetNumberOfDestinations() {
        let destination = MIDIGetDestination(i)
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(destination, &entity) == noErr, entity != 0 { continue }
        let name = midiName(of: destination)
        guard let source = looseSources[name] else { continue }
        var uid: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &uid)
        pairs.append(MIDIEndpointPair(id: uid, name: name,
                                      source: source, destination: destination))
    }
    return pairs
}

/// Iterate all UMP words in an event list (word counts may exceed the inline
/// tuple capacity, so walk by raw pointer).
public func forEachWord(in eventList: UnsafePointer<MIDIEventList>,
                 _ body: (UInt32) -> Void) {
    let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
    withUnsafePointer(to: eventList.pointee.packet) { first in
        var ptr = UnsafePointer(first)
        for _ in 0..<eventList.pointee.numPackets {
            let wordCount = Int(ptr.pointee.wordCount)
            let base = UnsafeRawPointer(ptr).advanced(by: wordsOffset)
                .assumingMemoryBound(to: UInt32.self)
            for w in 0..<wordCount {
                body(base[w])
            }
            // MIDIEventPacketNext is a header-only inline; advance manually:
            // next packet follows immediately after the words.
            ptr = UnsafePointer(UnsafeRawPointer(ptr)
                .advanced(by: 8 + wordCount * 4)
                .assumingMemoryBound(to: MIDIEventPacket.self))
        }
    }
}

/// CoreMIDI transport over UMP event lists (protocol MIDI 1.0). The legacy
/// packet-list API corrupts long SysEx when coalesced by CoreMIDI; UMP carries
/// SysEx7 in 6-byte words with explicit framing, and CoreMIDI translates for
/// MIDI 1.0 devices automatically.
public final class CoreMIDIWire: MIDIWire, @unchecked Sendable {
    private let client: MIDIClientRef
    private let inputPort: MIDIPortRef
    private let outputPort: MIDIPortRef
    private let destination: MIDIEndpointRef
    private let assembler = UMPAssembler()
    private var handler: (@Sendable ([UInt8]) -> Void)?

    public init(pair: MIDIEndpointPair) throws {
        var status: OSStatus
        var client = MIDIClientRef()
        status = MIDIClientCreate("kokoko" as CFString, nil, nil, &client)
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDIClientCreate", status) }
        self.client = client

        let assembler = self.assembler
        var input = MIDIPortRef()
        status = MIDIInputPortCreateWithProtocol(client, "kokoko-in" as CFString,
                                                 ._1_0, &input) { eventList, _ in
            var words: [UInt32] = []
            forEachWord(in: eventList) { words.append($0) }
            for message in assembler.feed(words) {
                assembler.onMessage?(message)
            }
        }
        guard status == noErr else {
            MIDIClientDispose(client)
            throw CoreMIDIError.osStatus("MIDIInputPortCreateWithProtocol", status)
        }
        self.inputPort = input

        var output = MIDIPortRef()
        status = MIDIOutputPortCreate(client, "kokoko-out" as CFString, &output)
        guard status == noErr else {
            MIDIClientDispose(client)
            throw CoreMIDIError.osStatus("MIDIOutputPortCreate", status)
        }
        self.outputPort = output
        self.destination = pair.destination

        status = MIDIPortConnectSource(input, pair.source, nil)
        guard status == noErr else {
            MIDIClientDispose(client)
            throw CoreMIDIError.osStatus("MIDIPortConnectSource", status)
        }
    }

    deinit {
        MIDIClientDispose(client)
    }

    public func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        assembler.onMessage = handler
    }

    public func send(_ bytes: [UInt8]) async throws {
        let words = UMPCodec.encodeSysEx(bytes)
        // Deliver in event packets of at most 64 words: the inline capacity of
        // MIDIEventPacket, which CoreMIDI's virtual-endpoint delivery respects.
        var offset = 0
        while offset < words.count {
            let group = Array(words[offset..<min(offset + 64, words.count)])
            let listSize = 16 + MemoryLayout<MIDIEventPacket>.size + group.count * 4
            let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                       alignment: MemoryLayout<MIDIEventList>.alignment)
            defer { raw.deallocate() }
            let eventList = raw.assumingMemoryBound(to: MIDIEventList.self)
            let packet = MIDIEventListInit(eventList, ._1_0)
            group.withUnsafeBufferPointer { buffer in
                _ = MIDIEventListAdd(eventList, listSize, packet, 0, group.count, buffer.baseAddress!)
            }
            let status = MIDISendEventList(outputPort, destination, eventList)
            guard status == noErr else { throw CoreMIDIError.osStatus("MIDISendEventList", status) }
            offset += 64
        }
    }
}
