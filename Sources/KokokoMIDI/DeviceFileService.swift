import Foundation
import KokokoCore

public enum FileServiceError: Error {
    case notInitialized
    case unexpectedPage(expected: UInt16, got: UInt16)
    case missingResponse
    case metadataParse(String)
    case pathNotFound(String)
    case truncated(fileID: UInt16, expected: Int, got: Int)
}

extension FileServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInitialized: "file service is not initialized"
        case .unexpectedPage(let expected, let got): "device sent page \(got), expected \(expected)"
        case .missingResponse: "device sent no usable response"
        case .metadataParse(let json): "could not parse metadata: \(json.prefix(200))"
        case .pathNotFound(let path): "path not found on device: \(path)"
        case .truncated(let id, let expected, let got): "node \(id) read \(got) of \(expected) bytes"
        }
    }
}

public struct FSNode: Equatable, Sendable, Identifiable {
    public let id: UInt16
    public let parentID: UInt16
    public let name: String
    public let flags: UInt8
    public let size: UInt32

    public var isFile: Bool { (flags & FileTypeFlag.file) != 0 }
    public var isReadable: Bool { (flags & FileCapability.read) != 0 }
    public var isWritable: Bool { (flags & FileCapability.write) != 0 }
    public var isDeletable: Bool { (flags & FileCapability.delete) != 0 }
    public var isMovable: Bool { (flags & FileCapability.move) != 0 }
    public var isPlayable: Bool { (flags & FileCapability.playback) != 0 }
}

/// File operations over command 5, one per device. Port of the observed
/// SysExFileHandler semantics from the original tool.
public actor DeviceFileService {
    private let session: SysExSession
    private var chunkSize: Int = 0

    public init(session: SysExSession) {
        self.session = session
    }

    public func initialize(maxResponseLength: UInt32 = 4 * 1024 * 1024, subscribe: Bool = true) async throws {
        let request = FileInitRequest(maxResponseLength: maxResponseLength, subscribe: subscribe)
        let reply = try await session.call(command: TECommand.file, payload: request.bytes)
        guard let response = FileInitResponse(payload: reply.payload) else {
            throw FileServiceError.missingResponse
        }
        chunkSize = Int(response.chunkSize)
    }

    private var maxPayload: Int {
        maxChunkPayloadLength(chunkSize: chunkSize)
    }

    private func call(_ payload: [UInt8], timeout: Duration = .seconds(20)) async throws -> [UInt8] {
        let reply = try await session.call(command: TECommand.file, payload: payload, timeout: timeout)
        return reply.payload
    }

    public func list(nodeID: UInt16) async throws -> [FSNode] {
        var nodes: [FSNode] = []
        var page: UInt16 = 0
        while true {
            let payload = try await call(ListRequest(page: page, nodeID: nodeID).bytes)
            if payload.count <= 2 { break }
            guard let response = ListResponse(payload: payload) else {
                throw FileServiceError.missingResponse
            }
            guard response.page == page else {
                throw FileServiceError.unexpectedPage(expected: page, got: response.page)
            }
            for entry in response.entries {
                nodes.append(FSNode(id: entry.nodeID, parentID: nodeID, name: entry.fileName,
                                    flags: entry.flags, size: entry.fileSize))
            }
            page += 1
        }
        return nodes
    }

    public func info(fileID: UInt16) async throws -> FSNode {
        let payload = try await call(FileInfoRequest(fileID: fileID).bytes)
        guard let response = FileInfoResponse(payload: payload) else {
            throw FileServiceError.missingResponse
        }
        return FSNode(id: response.nodeID, parentID: response.parentID, name: response.fileName,
                      flags: response.flags, size: response.fileSize)
    }

    /// Upload data as a file under parentID. Empty final data message terminates.
    public func put(parentID: UInt16, name: String, data: [UInt8], fileID: UInt16 = 0,
                    capabilities: [UInt8] = [FileCapability.read],
                    metadata: [String: JSONValue]? = nil,
                    isDirectory: Bool = false,
                    progress: (@Sendable (Int, Int) -> Void)? = nil,
                    timeout: Duration = .seconds(20)) async throws -> UInt16 {
        var flags = capabilities.reduce(0) { $0 | $1 }
        flags |= isDirectory ? FileTypeFlag.directory : FileTypeFlag.file
        let metadataJSON: String? = metadata.flatMap {
            (try? JSONSerialization.data(withJSONObject: $0.mapValues(\.anyValue))).flatMap { String(data: $0, encoding: .utf8) }
        }
        let initReply = try await call(
            PutInitRequest(fileID: fileID, parentID: parentID, flags: flags,
                           fileSize: UInt32(data.count), filename: name,
                           metadata: metadataJSON).bytes,
            timeout: timeout
        )
        guard let initResponse = PutInitResponse(payload: initReply) else {
            throw FileServiceError.missingResponse
        }
        progress?(0, data.count)

        var offset = 0
        var page: UInt16 = 0
        let chunk = maxPayload
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            _ = try await call(PutDataRequest(page: page, data: Array(data[offset..<end])).bytes,
                               timeout: timeout)
            offset = end
            page &+= 1
            progress?(offset, data.count)
        }
        _ = try await call(PutDataRequest(page: page, data: []).bytes, timeout: timeout)
        return initResponse.fileID
    }

    /// Download a whole file, verifying page order.
    public func get(fileID: UInt16, offset: UInt32 = 0,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> (name: String, data: [UInt8]) {
        let initPayload = try await call(GetInitRequest(fileID: fileID, offset: offset).bytes)
        guard let initResponse = GetInitResponse(payload: initPayload) else {
            throw FileServiceError.missingResponse
        }
        var data: [UInt8] = []
        data.reserveCapacity(Int(initResponse.fileSize))
        let total = Int(initResponse.fileSize) - Int(offset)
        var page: UInt16 = 0
        while data.count < total {
            let payload = try await call(GetDataRequest(page: page).bytes)
            guard let response = GetDataResponse(payload: payload) else {
                throw FileServiceError.missingResponse
            }
            guard response.page == page else {
                throw FileServiceError.unexpectedPage(expected: page, got: response.page)
            }
            if response.data.isEmpty { break }
            data.append(contentsOf: response.data)
            progress?(data.count, total)
            page = response.nextPage
        }
        return (initResponse.fileName, data)
    }

    public func delete(fileID: UInt16) async throws {
        _ = try await call(DeleteRequest(fileID: fileID).bytes)
    }

    public func move(fileID: UInt16, toParent parentID: UInt16, newFileID: UInt16 = 0) async throws {
        _ = try await call(MoveRequest(fileID: fileID, parentID: parentID, newFileID: newFileID).bytes)
    }

    public func startPlayback(fileID: UInt16, offset: UInt32 = 0, length: UInt32 = 0) async throws {
        _ = try await call(PlaybackRequest(fileID: fileID, action: .start,
                                           offset: offset, length: length).bytes)
    }

    public func stopPlayback(fileID: UInt16) async throws {
        _ = try await call(PlaybackRequest(fileID: fileID, action: .stop,
                                           offset: 0, length: 0).bytes)
    }

    /// Read full metadata JSON for a node (paged).
    public func getMetadata(fileID: UInt16, key: String? = nil) async throws -> [String: JSONValue] {
        var json = ""
        var page: UInt16 = 0
        while true {
            let payload = try await call(GetMetadataRequest(fileID: fileID, page: page, key: key).bytes)
            if payload.count <= 2 { break }
            guard let response = GetMetadataResponse(payload: payload) else {
                throw FileServiceError.missingResponse
            }
            guard response.page == page else {
                throw FileServiceError.unexpectedPage(expected: page, got: response.page)
            }
            json += response.fragment
            page += 1
            if response.isLast { break }
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw FileServiceError.metadataParse(json)
        }
        return dict.compactMapValues { JSONValue(any: $0) }
    }

    /// Set metadata; switches to the paged variant when the JSON is large.
    public func setMetadata(fileID: UInt16, _ metadata: [String: JSONValue]) async throws {
        let data = try JSONSerialization.data(withJSONObject: metadata.mapValues(\.anyValue))
        guard let json = String(data: data, encoding: .utf8) else { return }
        if json.utf8.count <= chunkSize - 8 {
            _ = try await call(SetMetadataRequest(fileID: fileID, json: json).bytes)
            return
        }
        let bytes = Array(json.utf8)
        _ = try await call(SetMetadataPagedInitRequest(fileID: fileID,
                                                       totalSize: UInt32(bytes.count)).bytes)
        var offset = 0
        var page: UInt16 = 0
        let chunk = maxPayload
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            _ = try await call(SetMetadataPagedDataRequest(page: page,
                                                           data: Array(bytes[offset..<end])).bytes)
            offset = end
            page &+= 1
        }
        _ = try await call(SetMetadataPagedDataRequest(page: page, data: []).bytes)
    }
}
