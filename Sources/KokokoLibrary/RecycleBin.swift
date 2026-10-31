import Foundation
import KokokoCore
import KokokoMIDI

/// One deleted sound kept in the bin.
public struct BinEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let originalSlot: UInt16
    public let name: String
    public let deletedAt: Date
}

/// Local store for the last copy of deleted sounds: one directory per entry
/// holding `sound.pcm` and `info.json` (slot, deletion time, device metadata).
public struct RecycleBin: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private static let pcmFile = "sound.pcm"
    // Written last: a directory without it is an interrupted add and is skipped.
    private static let infoFile = "info.json"

    @discardableResult
    public func add(_ sound: SoundBackup, deletedAt: Date = Date()) throws -> BinEntry {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try Data(sound.pcm).write(to: dir.appendingPathComponent(Self.pcmFile), options: .atomic)
            let info: [String: Any] = [
                "slot": Int(sound.nodeID),
                "deletedAt": deletedAt.timeIntervalSince1970,
                "metadata": sound.metadata.mapValues(\.anyValue),
            ]
            // JSONSerialization raises an uncatchable exception (e.g. on NaN) instead of throwing.
            guard JSONSerialization.isValidJSONObject(info) else {
                throw FileServiceError.metadataParse("unserializable metadata for slot \(sound.nodeID)")
            }
            let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
            try data.write(to: dir.appendingPathComponent(Self.infoFile), options: .atomic)
            return try entry(id: id)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Entries newest first.
    public func entries() throws -> [BinEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .compactMap { try? entry(id: $0) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    public func load(_ entry: BinEntry) throws -> SoundBackup {
        let dir = root.appendingPathComponent(entry.id)
        let pcm = try Data(contentsOf: dir.appendingPathComponent(Self.pcmFile))
        return SoundBackup(nodeID: entry.originalSlot, pcm: Array(pcm),
                           metadata: try info(id: entry.id).metadata)
    }

    public func remove(_ entry: BinEntry) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.id))
    }

    private func info(id: String) throws
        -> (slot: UInt16, deletedAt: Date, metadata: [String: JSONValue]) {
        let url = root.appendingPathComponent(id).appendingPathComponent(Self.infoFile)
        guard let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let slot = dict["slot"] as? Int, let slot16 = UInt16(exactly: slot),
              let deletedAt = dict["deletedAt"] as? Double else {
            throw FileServiceError.metadataParse(url.path)
        }
        let raw = dict["metadata"] as? [String: Any] ?? [:]
        return (slot16, Date(timeIntervalSince1970: deletedAt), raw.compactMapValues { JSONValue(any: $0) })
    }

    private func entry(id: String) throws -> BinEntry {
        let info = try info(id: id)
        return BinEntry(id: id, originalSlot: info.slot,
                        name: info.metadata["name"]?.stringValue ?? "sound \(info.slot)",
                        deletedAt: info.deletedAt)
    }
}
