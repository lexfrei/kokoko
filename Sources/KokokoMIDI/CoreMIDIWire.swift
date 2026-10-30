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
    return pairs
}

/// SysEx reassembly: MIDIPackets split long SysEx arbitrarily, so bytes are
/// accumulated until F7. Complete messages go to onMessage.
final class SysExAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var partial: [UInt8] = []
    var onMessage: (@Sendable ([UInt8]) -> Void)?

    func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        let completed: [[UInt8]] = {
            var done: [[UInt8]] = []
            for b in bytes {
                if b == 0xF0 { partial = [b]; continue }
                if partial.isEmpty { continue }
                partial.append(b)
                if b == 0xF7 {
                    done.append(partial)
                    partial = []
                }
            }
            return done
        }()
        let handler = onMessage
        lock.unlock()
        for message in completed { handler?(message) }
    }
}

/// Legacy (pre-UMP) CoreMIDI transport. SysEx-capable and sufficient for this
/// protocol; the modern event-list API adds UMP fragmentation with no benefit here.
public final class CoreMIDIWire: MIDIWire, @unchecked Sendable {
    private let client: MIDIClientRef
    private let inputPort: MIDIPortRef
    private let outputPort: MIDIPortRef
    private let destination: MIDIEndpointRef
    private let assembler = SysExAssembler()

    public init(pair: MIDIEndpointPair) throws {
        var status: OSStatus
        var client = MIDIClientRef()
        status = MIDIClientCreate("kokoko" as CFString, nil, nil, &client)
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDIClientCreate", status) }
        self.client = client

        let assembler = self.assembler
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        var input = MIDIPortRef()
        status = MIDIInputPortCreateWithBlock(client, "kokoko-in" as CFString, &input) { packetList, _ in
            withUnsafePointer(to: packetList.pointee.packet) { first in
                var ptr = UnsafePointer(first)
                for _ in 0..<packetList.pointee.numPackets {
                    let length = Int(ptr.pointee.length)
                    let dataStart = UnsafeRawPointer(ptr).advanced(by: dataOffset)
                        .assumingMemoryBound(to: UInt8.self)
                    assembler.append(UnsafeBufferPointer(start: dataStart, count: length))
                    ptr = UnsafePointer(MIDIPacketNext(ptr))
                }
            }
        }
        guard status == noErr else {
            MIDIClientDispose(client)
            throw CoreMIDIError.osStatus("MIDIInputPortCreateWithBlock", status)
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
        // MIDIPacketList is capped at 65536 bytes total (CoreMIDI docs); our
        // chunks are far below that.
        let listSize = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
            + MemoryLayout<MIDIPacket>.size + bytes.count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                   alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { raw.deallocate() }
        let packetList = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(packetList)
        packet = bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(packetList, listSize, packet, 0, bytes.count,
                              buffer.baseAddress!)
        }
        guard packet != nil else { throw CoreMIDIError.osStatus("MIDIPacketListAdd", -1) }
        let status = MIDISend(outputPort, destination, packetList)
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDISend", status) }
    }
}
