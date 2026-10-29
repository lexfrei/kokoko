import Foundation

// Command 5 subcommands.
public enum FileSub {
    public static let initialize: UInt8 = 1
    public static let put: UInt8 = 2
    public static let get: UInt8 = 3
    public static let list: UInt8 = 4
    public static let playback: UInt8 = 5
    public static let delete: UInt8 = 6
    public static let metadata: UInt8 = 7
    public static let info: UInt8 = 11
    public static let move: UInt8 = 12
}

public enum FileCapability {
    public static let read: UInt8 = 4
    public static let write: UInt8 = 8
    public static let delete: UInt8 = 16
    public static let move: UInt8 = 32
    public static let playback: UInt8 = 64
}

public enum FileTypeFlag {
    public static let file: UInt8 = 1
    public static let directory: UInt8 = 2
}

public enum NodeType: Equatable {
    case file
    case directory
}

/// Max raw payload per chunk message, given the device-reported chunkSize.
/// Accounts for the 8-byte header, 2 trailing bytes, the footer, and 7-bit packing.
public func maxChunkPayloadLength(chunkSize: Int) -> Int {
    let overhead = 8 + 2 + 1
    let m = chunkSize - 6
    guard m > overhead else { return 0 }
    let p = m - 1 - overhead
    return p - p / 8
}

func appendZString(_ s: String, to bytes: inout [UInt8]) {
    bytes.append(contentsOf: s.utf8)
    bytes.append(0)
}

func readZString(_ bytes: [UInt8], from offset: Int) -> String {
    var end = offset
    while end < bytes.count && bytes[end] != 0 { end += 1 }
    return String(decoding: bytes[offset..<end], as: UTF8.self)
}

func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}

func appendU16(_ v: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF))
}

func appendU32(_ v: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8((v >> 24) & 0xFF)); bytes.append(UInt8((v >> 16) & 0xFF))
    bytes.append(UInt8((v >> 8) & 0xFF)); bytes.append(UInt8(v & 0xFF))
}

public struct FileInitRequest {
    public var maxResponseLength: UInt32
    public var subscribe: Bool

    public init(maxResponseLength: UInt32, subscribe: Bool) {
        self.maxResponseLength = maxResponseLength
        self.subscribe = subscribe
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.initialize, subscribe ? 1 : 0]
        appendU32(maxResponseLength, to: &out)
        return out
    }
}

public struct FileInitResponse {
    public var chunkSize: UInt32

    public init?(payload: [UInt8]) {
        guard payload.count >= 5 else { return nil }
        chunkSize = readU32(payload, 1)
    }
}

public struct PutInitRequest {
    public var fileID: UInt16
    public var parentID: UInt16
    public var flags: UInt8
    public var fileSize: UInt32
    public var filename: String
    public var metadata: String?

    public init(fileID: UInt16, parentID: UInt16, flags: UInt8, fileSize: UInt32,
                filename: String, metadata: String?) {
        self.fileID = fileID
        self.parentID = parentID
        self.flags = flags
        self.fileSize = fileSize
        self.filename = String(filename.prefix(54))
        self.metadata = metadata
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.put, 0, flags]
        appendU16(fileID, to: &out)
        appendU16(parentID, to: &out)
        appendU32(fileSize, to: &out)
        appendZString(filename, to: &out)
        if let metadata {
            appendZString(metadata, to: &out)
        }
        return out
    }
}

public struct PutInitResponse {
    public var fileID: UInt16

    public init?(payload: [UInt8]) {
        guard payload.count >= 2 else { return nil }
        fileID = readU16(payload, 0)
    }
}

public struct PutDataRequest {
    public var page: UInt16
    public var data: [UInt8]

    public init(page: UInt16, data: [UInt8]) {
        self.page = page
        self.data = data
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.put, 1]
        appendU16(page, to: &out)
        out.append(contentsOf: data)
        return out
    }
}

public struct GetInitRequest {
    public var fileID: UInt16
    public var offset: UInt32
    public var extraArgs: [UInt8]?

    public init(fileID: UInt16, offset: UInt32, extraArgs: [UInt8]? = nil) {
        self.fileID = fileID
        self.offset = offset
        self.extraArgs = extraArgs
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.get, 0]
        appendU16(fileID, to: &out)
        appendU32(offset, to: &out)
        if let extraArgs {
            out.append(contentsOf: [UInt8](repeating: 0, count: 8))
            out.append(contentsOf: extraArgs)
        }
        return out
    }
}

public struct GetInitResponse {
    public var fileID: UInt16
    public var flags: UInt8
    public var fileSize: UInt32
    public var fileName: String

    public init?(payload: [UInt8]) {
        guard payload.count >= 7 else { return nil }
        fileID = readU16(payload, 0)
        flags = payload[2]
        fileSize = readU32(payload, 3)
        fileName = readZString(payload, from: 7)
    }
}

public struct GetDataRequest {
    public var page: UInt16

    public init(page: UInt16) { self.page = page }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.get, 1]
        appendU16(page, to: &out)
        return out
    }
}

public struct GetDataResponse {
    public var page: UInt16
    public var nextPage: UInt16
    public var data: [UInt8]

    public init?(payload: [UInt8]) {
        guard payload.count >= 2 else { return nil }
        page = readU16(payload, 0)
        nextPage = page &+ 1
        data = Array(payload[2...])
    }
}

public struct ListRequest {
    public var page: UInt16
    public var nodeID: UInt16

    public init(page: UInt16, nodeID: UInt16) {
        self.page = page
        self.nodeID = nodeID
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.list]
        appendU16(page, to: &out)
        appendU16(nodeID, to: &out)
        return out
    }
}

public struct ListEntry: Equatable {
    public var nodeID: UInt16
    public var flags: UInt8
    public var fileSize: UInt32
    public var fileName: String

    public var type: NodeType {
        (flags & FileTypeFlag.file) != 0 ? .file : .directory
    }
}

public struct ListResponse {
    public var page: UInt16
    public var entries: [ListEntry]

    public init?(payload: [UInt8]) {
        guard payload.count >= 2 else { return nil }
        page = readU16(payload, 0)
        var entries: [ListEntry] = []
        var offset = 2
        while offset < payload.count {
            guard offset + 7 <= payload.count else { return nil }
            let nodeID = readU16(payload, offset)
            let flags = payload[offset + 2]
            let fileSize = readU32(payload, offset + 3)
            let name = readZString(payload, from: offset + 7)
            entries.append(ListEntry(nodeID: nodeID, flags: flags, fileSize: fileSize, fileName: name))
            offset += 7 + name.utf8.count + 1
        }
        self.entries = entries
    }
}

public struct FileInfoRequest {
    public var fileID: UInt16

    public init(fileID: UInt16) { self.fileID = fileID }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.info]
        appendU16(fileID, to: &out)
        return out
    }
}

public struct FileInfoResponse {
    public var nodeID: UInt16
    public var parentID: UInt16
    public var flags: UInt8
    public var fileSize: UInt32
    public var fileName: String

    public init?(payload: [UInt8]) {
        guard payload.count >= 9 else { return nil }
        nodeID = readU16(payload, 0)
        parentID = readU16(payload, 2)
        flags = payload[4]
        fileSize = readU32(payload, 5)
        fileName = readZString(payload, from: 9)
    }
}

public struct DeleteRequest {
    public var fileID: UInt16

    public init(fileID: UInt16) { self.fileID = fileID }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.delete]
        appendU16(fileID, to: &out)
        return out
    }
}

public enum PlaybackAction: UInt8 {
    case start = 1
    case stop = 2
}

public struct PlaybackRequest {
    public var fileID: UInt16
    public var action: PlaybackAction
    public var offset: UInt32
    public var length: UInt32

    public init(fileID: UInt16, action: PlaybackAction, offset: UInt32, length: UInt32) {
        self.fileID = fileID
        self.action = action
        self.offset = offset
        self.length = length
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.playback, action.rawValue]
        appendU16(fileID, to: &out)
        appendU32(offset, to: &out)
        appendU32(length, to: &out)
        return out
    }
}

public struct SetMetadataRequest {
    public var fileID: UInt16
    public var json: String

    public init(fileID: UInt16, json: String) {
        self.fileID = fileID
        self.json = json
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.metadata, 1]
        appendU16(fileID, to: &out)
        appendZString(json, to: &out)
        return out
    }
}

public struct GetMetadataRequest {
    public var fileID: UInt16
    public var page: UInt16
    public var key: String?

    public init(fileID: UInt16, page: UInt16, key: String? = nil) {
        self.fileID = fileID
        self.page = page
        self.key = key
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.metadata, 2]
        appendU16(fileID, to: &out)
        appendU16(page, to: &out)
        if let key {
            appendZString(key, to: &out)
        }
        return out
    }
}

public struct GetMetadataResponse {
    public var page: UInt16
    public var fragment: String
    /// Device terminates the listing with a fragment ending in a 0 byte.
    public var isLast: Bool

    public init?(payload: [UInt8]) {
        guard payload.count >= 3 else { return nil }
        page = readU16(payload, 0)
        isLast = payload.last == 0
        fragment = readZString(payload, from: 2)
    }
}

public struct SetMetadataPagedInitRequest {
    public var fileID: UInt16
    public var totalSize: UInt32

    public init(fileID: UInt16, totalSize: UInt32) {
        self.fileID = fileID
        self.totalSize = totalSize
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.metadata, 4, 0]
        appendU16(fileID, to: &out)
        appendU32(totalSize, to: &out)
        return out
    }
}

public struct SetMetadataPagedDataRequest {
    public var page: UInt16
    public var data: [UInt8]

    public init(page: UInt16, data: [UInt8]) {
        self.page = page
        self.data = data
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.metadata, 4, 1]
        appendU16(page, to: &out)
        out.append(contentsOf: data)
        return out
    }
}

public struct MoveRequest {
    public var fileID: UInt16
    public var parentID: UInt16
    public var newFileID: UInt16

    public init(fileID: UInt16, parentID: UInt16, newFileID: UInt16) {
        self.fileID = fileID
        self.parentID = parentID
        self.newFileID = newFileID
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [FileSub.move]
        appendU16(fileID, to: &out)
        appendU16(parentID, to: &out)
        appendU16(newFileID, to: &out)
        return out
    }
}

public struct MoveResponse {
    public var oldFileID: UInt16
    public var parentID: UInt16
    public var newFileID: UInt16

    public init?(payload: [UInt8]) {
        guard payload.count >= 6 else { return nil }
        oldFileID = readU16(payload, 0)
        parentID = readU16(payload, 2)
        newFileID = readU16(payload, 4)
    }
}

public enum FileEvent: Equatable {
    case metadataUpdated(nodeID: UInt16, json: String)
    case addedUpdated(nodeID: UInt16, fileSize: UInt32, name: String)
    case deleted(nodeID: UInt16)
    case moved(oldNodeID: UInt16, parentID: UInt16, newNodeID: UInt16)

    public static func parse(_ payload: [UInt8]) -> FileEvent? {
        guard let kind = payload.first else { return nil }
        switch kind {
        case 3:
            guard payload.count >= 4 else { return nil }
            return .metadataUpdated(nodeID: readU16(payload, 1),
                                    json: readZString(payload, from: 3))
        case 8, 9:
            guard payload.count >= 10 else { return nil }
            return .addedUpdated(nodeID: readU16(payload, 1),
                                 fileSize: readU32(payload, 5),
                                 name: readZString(payload, from: 9))
        case 10:
            guard payload.count >= 3 else { return nil }
            return .deleted(nodeID: readU16(payload, 1))
        case 13:
            guard payload.count >= 7 else { return nil }
            return .moved(oldNodeID: readU16(payload, 1),
                          parentID: readU16(payload, 3),
                          newNodeID: readU16(payload, 5))
        default:
            return nil
        }
    }
}
