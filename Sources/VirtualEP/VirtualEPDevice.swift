import CoreMIDI
import Foundation
import KokokoCore
import KokokoMIDI

/// In-memory EP-family device simulator speaking the SysEx file protocol over
/// virtual CoreMIDI endpoints. Exists so client code can be exercised
/// end-to-end without hardware.
public final class VirtualEPDevice: @unchecked Sendable {
    struct VNode {
        var id: UInt16
        var parentID: UInt16
        var name: String
        var flags: UInt8
        var data: [UInt8] = []
        var metadata: [String: JSONValue] = [:]
        var complete = true
    }

    public private(set) var name: String
    private let chunkSize: UInt32 = 96
    private let readChunk = 64
    private let deviceID: UInt8 = 0x42

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private let assembler = UMPAssembler()

    private var nodes: [UInt16: VNode] = [:]
    private var nextID: UInt16 = 1
    private var pendingPut: (nodeID: UInt16, nextPage: UInt16)?
    private var pendingMeta: (nodeID: UInt16, buffer: [UInt8], nextPage: UInt16)?

    public init(name: String = "kokoko-vep") {
        self.name = name
        seed()
    }

    private func seed() {
        nodes[0] = VNode(id: 0, parentID: 0, name: "", flags: FileTypeFlag.directory)
        let sounds = allocNode(parentID: 0, name: "sounds", flags: FileTypeFlag.directory | 0x7C)
        allocNode(parentID: 0, name: "projects", flags: FileTypeFlag.directory)

        let kick = allocNode(parentID: sounds, name: "kick", flags: FileTypeFlag.file | 0x7C)
        nodes[kick]?.data = Array(repeating: 0, count: 2000)
        nodes[kick]?.metadata = ["channels": .int(1), "samplerate": .int(46875)]

        let snare = allocNode(parentID: sounds, name: "snare", flags: FileTypeFlag.file | 0x7C)
        nodes[snare]?.data = Array(repeating: 1, count: 2048)
        nodes[snare]?.metadata = ["channels": .int(1), "samplerate": .int(46875)]
    }

    @discardableResult
    private func allocNode(parentID: UInt16, name: String, flags: UInt8) -> UInt16 {
        let id = nextID
        nodes[id] = VNode(id: id, parentID: parentID, name: name, flags: flags)
        nextID += 1
        return id
    }

    public func start() throws {
        var status = MIDIClientCreate(name as CFString, nil, nil, &client)
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDIClientCreate", status) }

        status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { [assembler] eventList, _ in
            var words: [UInt32] = []
            forEachWord(in: eventList) { words.append($0) }
            for message in assembler.feed(words) {
                assembler.onMessage?(message)
            }
        }
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDIDestinationCreate", status) }

        status = MIDISourceCreate(client, name as CFString, &source)
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDISourceCreate", status) }

        assembler.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    private func handle(_ message: [UInt8]) {
        if message == Identity.requestBytes {
            sendRaw([0xF0, 0x7E, deviceID, 0x06, 0x02, 0x00, 0x20, 0x76,
                     32, 0, 1, 0, 2, 1, 0, 0, 0xF7])
            return
        }
        guard let frame = TEFrame.parse(message), frame.kind == .request else { return }
        switch frame.command {
        case TECommand.greet:
            let text = "chip_id:vep;mode:normal;os_version:2.1.0;product:ep-133;serial:VEP0001;sku:TE032AS001;sw_version:2.1.0;base_sku:TE032AS001;"
            respond(to: frame, status: 0, payload: Array(text.utf8))
        case TECommand.echo:
            respond(to: frame, status: 0, payload: frame.payload)
        case TECommand.file:
            handleFile(frame)
        default:
            respond(to: frame, status: 2, payload: [])
        }
    }

    private func handleFile(_ frame: TEFrame) {
        guard let sub = frame.payload.first else {
            respond(to: frame, status: 3, payload: [])
            return
        }
        let p = frame.payload
        switch sub {
        case FileSub.initialize:
            respond(to: frame, status: 0,
                    payload: [0, UInt8((chunkSize >> 24) & 0xFF), UInt8((chunkSize >> 16) & 0xFF),
                              UInt8((chunkSize >> 8) & 0xFF), UInt8(chunkSize & 0xFF)])

        case FileSub.put:
            if p[1] == 0 { // init
                let fileID = readU16(p, 3)
                let parent = readU16(p, 5)
                let flags = p[2]
                let name = readZString(p, from: 11)
                let id = fileID == 0 ? allocNode(parentID: parent, name: name, flags: flags) : fileID
                if fileID != 0 {
                    nodes[id] = VNode(id: id, parentID: parent, name: name, flags: flags)
                }
                nodes[id]?.complete = false
                nodes[id]?.data = []
                pendingPut = (id, 0)
                respond(to: frame, status: 0, payload: [UInt8(id >> 8), UInt8(id & 0xFF)])
            } else { // data
                let page = readU16(p, 2)
                guard var put = pendingPut else {
                    respond(to: frame, status: 3, payload: [])
                    return
                }
                let chunk = Array(p[4...])
                if chunk.isEmpty {
                    nodes[put.nodeID]?.complete = true
                    pendingPut = nil
                    respond(to: frame, status: 0, payload: [])
                    emitEvent([0x08, UInt8(put.nodeID >> 8), UInt8(put.nodeID & 0xFF),
                               0, 0,
                               UInt8((nodes[put.nodeID]?.data.count ?? 0) >> 24 & 0xFF),
                               UInt8((nodes[put.nodeID]?.data.count ?? 0) >> 16 & 0xFF),
                               UInt8((nodes[put.nodeID]?.data.count ?? 0) >> 8 & 0xFF),
                               UInt8((nodes[put.nodeID]?.data.count ?? 0) & 0xFF)]
                               + Array((nodes[put.nodeID]?.name ?? "").utf8) + [0])
                    return
                }
                guard page == put.nextPage else {
                    respond(to: frame, status: 3, payload: [])
                    return
                }
                nodes[put.nodeID]?.data.append(contentsOf: chunk)
                put.nextPage &+= 1
                pendingPut = put
                respond(to: frame, status: 0, payload: [])
            }

        case FileSub.get:
            if p[1] == 0 { // init
                let fileID = readU16(p, 2)
                guard let node = nodes[fileID] else {
                    respond(to: frame, status: 16, payload: [])
                    return
                }
                lastGetFileID = fileID
                respond(to: frame, status: 0,
                        payload: [UInt8(fileID >> 8), UInt8(fileID & 0xFF), node.flags,
                                  UInt8((node.data.count >> 24) & 0xFF),
                                  UInt8((node.data.count >> 16) & 0xFF),
                                  UInt8((node.data.count >> 8) & 0xFF),
                                  UInt8(node.data.count & 0xFF)]
                                + Array(node.name.utf8) + [0])
            } else { // data
                let page = Int(readU16(p, 2))
                let fileID = lastGetFileID
                guard let node = nodes[fileID] else {
                    respond(to: frame, status: 16, payload: [])
                    return
                }
                let offset = page * readChunk
                let slice: [UInt8] = offset < node.data.count
                    ? Array(node.data[offset..<min(offset + readChunk, node.data.count)])
                    : []
                respond(to: frame, status: 0,
                        payload: [UInt8(page >> 8), UInt8(page & 0xFF)] + slice)
            }

        case FileSub.list:
            let page = readU16(p, 1)
            let parent = readU16(p, 3)
            if page > 0 {
                respond(to: frame, status: 0, payload: [UInt8(page >> 8), UInt8(page & 0xFF)])
                return
            }
            var payload: [UInt8] = [UInt8(page >> 8), UInt8(page & 0xFF)]
            for node in nodes.values.sorted(by: { $0.id < $1.id }) where node.parentID == parent && node.id != 0 {
                payload.append(UInt8(node.id >> 8))
                payload.append(UInt8(node.id & 0xFF))
                payload.append(node.flags)
                payload.append(contentsOf: [
                    UInt8((node.data.count >> 24) & 0xFF), UInt8((node.data.count >> 16) & 0xFF),
                    UInt8((node.data.count >> 8) & 0xFF), UInt8(node.data.count & 0xFF)])
                payload.append(contentsOf: Array(node.name.utf8))
                payload.append(0)
            }
            respond(to: frame, status: 0, payload: payload)

        case FileSub.delete:
            let fileID = readU16(p, 1)
            nodes.removeValue(forKey: fileID)
            respond(to: frame, status: 0, payload: [])
            emitEvent([0x0A, UInt8(fileID >> 8), UInt8(fileID & 0xFF)])

        case FileSub.playback:
            respond(to: frame, status: 0, payload: [])

        case FileSub.metadata:
            handleMetadata(frame, p)

        case FileSub.info:
            let fileID = readU16(p, 1)
            guard let node = nodes[fileID] else {
                respond(to: frame, status: 16, payload: [])
                return
            }
            respond(to: frame, status: 0,
                    payload: [UInt8(node.id >> 8), UInt8(node.id & 0xFF),
                              UInt8(node.parentID >> 8), UInt8(node.parentID & 0xFF),
                              node.flags,
                              UInt8((node.data.count >> 24) & 0xFF),
                              UInt8((node.data.count >> 16) & 0xFF),
                              UInt8((node.data.count >> 8) & 0xFF),
                              UInt8(node.data.count & 0xFF)]
                            + Array(node.name.utf8) + [0])

        case FileSub.move:
            let fileID = readU16(p, 1)
            let parent = readU16(p, 3)
            let newID = readU16(p, 5)
            nodes[fileID]?.parentID = parent
            respond(to: frame, status: 0,
                    payload: [UInt8(fileID >> 8), UInt8(fileID & 0xFF),
                              UInt8(parent >> 8), UInt8(parent & 0xFF),
                              UInt8(newID >> 8), UInt8(newID & 0xFF)])

        default:
            respond(to: frame, status: 2, payload: [])
        }
    }

    private var lastGetFileID: UInt16 = 0

    private func handleMetadata(_ frame: TEFrame, _ p: [UInt8]) {
        guard p.count >= 2 else {
            respond(to: frame, status: 3, payload: [])
            return
        }
        switch p[1] {
        case 1: // set
            let fileID = readU16(p, 2)
            let json = readZString(p, from: 4)
            if let data = json.data(using: .utf8),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (key, value) in dict {
                    nodes[fileID]?.metadata[key] = JSONValue(any: value)
                }
            }
            respond(to: frame, status: 0, payload: [])
        case 2: // get
            let fileID = readU16(p, 2)
            let page = readU16(p, 4)
            if page > 0 {
                respond(to: frame, status: 0, payload: [UInt8(page >> 8), UInt8(page & 0xFF), 0])
                return
            }
            let dict = nodes[fileID]?.metadata.mapValues(\.anyValue) ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
            respond(to: frame, status: 0,
                    payload: [0, 0] + Array(data) + [0])
        case 4: // set paged
            if p[2] == 0 { // init
                let fileID = readU16(p, 3)
                pendingMeta = (fileID, [], 0)
                respond(to: frame, status: 0, payload: [])
            } else { // data
                let page = readU16(p, 3)
                guard var meta = pendingMeta else {
                    respond(to: frame, status: 3, payload: [])
                    return
                }
                let chunk = Array(p[5...])
                if chunk.isEmpty {
                    if let dict = (try? JSONSerialization.jsonObject(with: Data(meta.buffer))) as? [String: Any] {
                        for (key, value) in dict {
                            nodes[meta.nodeID]?.metadata[key] = JSONValue(any: value)
                        }
                    }
                    pendingMeta = nil
                    respond(to: frame, status: 0, payload: [])
                    return
                }
                guard page == meta.nextPage else {
                    respond(to: frame, status: 3, payload: [])
                    return
                }
                meta.buffer.append(contentsOf: chunk)
                meta.nextPage &+= 1
                pendingMeta = meta
                respond(to: frame, status: 0, payload: [])
            }
        default:
            respond(to: frame, status: 2, payload: [])
        }
    }

    /// Response frame: request id echoed, status byte, packed payload.
    private func respond(to request: TEFrame, status: UInt8, payload: [UInt8]) {
        var out: [UInt8] = [0xF0, 0x00, 0x20, 0x76, deviceID, 0x40,
                            0x20 | UInt8((request.requestID >> 7) & 31),
                            UInt8(request.requestID & 127),
                            request.command, status]
        out.append(contentsOf: SevenBitCoding.pack(payload))
        out.append(0xF7)
        sendRaw(out)
    }

    /// Device-initiated event: IS_REQUEST set, no request id.
    /// Deferred: CoreMIDI drops a second MIDIReceivedEventList issued in the
    /// same runloop turn as the response it follows.
    private func emitEvent(_ payload: [UInt8]) {
        var out: [UInt8] = [0xF0, 0x00, 0x20, 0x76, deviceID, 0x40, 0x40, 0x00, TECommand.file]
        out.append(contentsOf: SevenBitCoding.pack(payload))
        out.append(0xF7)
        DispatchQueue.global().async { [weak self] in
            self?.sendRaw(out)
        }
    }

    private func sendRaw(_ bytes: [UInt8]) {
        let words = UMPCodec.encodeSysEx(bytes)
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
            MIDIReceivedEventList(source, eventList)
            offset += 64
        }
    }
}
