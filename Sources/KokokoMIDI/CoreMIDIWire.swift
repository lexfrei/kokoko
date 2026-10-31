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
/// Standalone virtual endpoints (no entity) are paired by name. A name used
/// by more than one loose source or destination is skipped: CoreMIDI does not
/// say which source belongs with which destination.
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

    func loose(_ endpoints: [MIDIEndpointRef]) -> [MIDIEndpointRef] {
        endpoints.filter { endpoint in
            var entity = MIDIEntityRef()
            return !(MIDIEndpointGetEntity(endpoint, &entity) == noErr && entity != 0)
        }
    }
    let looseSources = Dictionary(grouping: loose((0..<MIDIGetNumberOfSources()).map(MIDIGetSource)),
                                  by: midiName(of:))
    let looseDestinations = loose((0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination))
    let destinationNameCounts = Dictionary(looseDestinations.map { (midiName(of: $0), 1) }, uniquingKeysWith: +)
    for destination in looseDestinations {
        let name = midiName(of: destination)
        guard destinationNameCounts[name] == 1, let sources = looseSources[name], sources.count == 1 else { continue }
        let source = sources[0]
        var uid: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &uid)
        pairs.append(MIDIEndpointPair(id: uid, name: name,
                                      source: source, destination: destination))
    }
    return pairs
}

/// Iterate all UMP words in an event list, across every packet.
public func forEachWord(in eventList: UnsafePointer<MIDIEventList>,
                 _ body: (UInt32) -> Void) {
    for packet in eventList.unsafeSequence() {
        for word in packet.words() {
            body(word)
        }
    }
}

/// CoreMIDI transport over UMP event lists (protocol MIDI 1.0). UMP carries
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
        // 64-word lists match MIDIEventPacket's inline capacity. Whether real
        // devices need the split is unverified; keep it until checked on hardware.
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
