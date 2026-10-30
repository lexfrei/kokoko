import Foundation
import KokokoAudio
import KokokoCore
import KokokoMIDI

/// One sound in a backup: raw PCM plus its device metadata.
public struct SoundBackup: Sendable {
    public var nodeID: UInt16
    public var pcm: [UInt8]
    public var metadata: [String: JSONValue]
}

/// Whole-device state: manifest + sounds + project tree metadata.
public struct DeviceBackup: Sendable {
    public var deviceSKU: String
    public var osVersion: String
    public var createdAt: Date
    public var sounds: [SoundBackup]
    /// Node metadata keyed by node id, for every non-sound node (projects tree).
    public var projectMetadata: [UInt16: [String: JSONValue]]

    public init(deviceSKU: String, osVersion: String, createdAt: Date,
                sounds: [SoundBackup], projectMetadata: [UInt16: [String: JSONValue]]) {
        self.deviceSKU = deviceSKU
        self.osVersion = osVersion
        self.createdAt = createdAt
        self.sounds = sounds
        self.projectMetadata = projectMetadata
    }
}

/// Batch operations and full-state backup/restore over DeviceFileService.
public actor DeviceLibrary {
    private let files: DeviceFileService

    public init(files: DeviceFileService) {
        self.files = files
    }

    /// Walk /sounds and /projects, download everything with metadata.
    public func backup(deviceSKU: String, osVersion: String,
                       progress: (@Sendable (String) -> Void)? = nil) async throws -> DeviceBackup {
        let soundsRoot = try await resolve("/sounds")
        var backups: [SoundBackup] = []
        for node in try await files.list(nodeID: soundsRoot) where node.isFile {
            progress?(node.name)
            let data = try await files.get(fileID: node.id)
            let meta = (try? await files.getMetadata(fileID: node.id)) ?? [:]
            backups.append(SoundBackup(nodeID: node.id, pcm: data.data, metadata: meta))
        }

        var projectMetadata: [UInt16: [String: JSONValue]] = [:]
        let projectsRoot = try await resolve("/projects")
        try await collectMetadata(nodeID: projectsRoot, into: &projectMetadata)

        return DeviceBackup(deviceSKU: deviceSKU, osVersion: osVersion, createdAt: Date(),
                            sounds: backups, projectMetadata: projectMetadata)
    }

    private func collectMetadata(nodeID: UInt16,
                                 into map: inout [UInt16: [String: JSONValue]]) async throws {
        if let meta = try? await files.getMetadata(fileID: nodeID), !meta.isEmpty {
            map[nodeID] = meta
        }
        for child in try await files.list(nodeID: nodeID) where !child.isFile {
            try await collectMetadata(nodeID: child.id, into: &map)
        }
    }

    /// Recreate sounds with their original node ids and metadata.
    public func restore(_ backup: DeviceBackup,
                        progress: (@Sendable (String) -> Void)? = nil) async throws {
        let soundsRoot = try await resolve("/sounds")
        let existing = Set(try await files.list(nodeID: soundsRoot).map(\.id))
        for sound in backup.sounds {
            progress?(sound.metadata["name"]?.stringValue ?? "node \(sound.nodeID)")
            let targetID = existing.contains(sound.nodeID) ? 0 : sound.nodeID
            let newID = try await files.put(parentID: soundsRoot,
                                            name: sound.metadata["name"]?.stringValue
                                                ?? "sound \(sound.nodeID)",
                                            data: sound.pcm, fileID: UInt16(targetID))
            try await files.setMetadata(fileID: newID, sound.metadata)
        }
    }

    public func resolve(_ path: String) async throws -> UInt16 {
        var current: UInt16 = 0
        for part in path.split(separator: "/") {
            let children = try await files.list(nodeID: current)
            guard let next = children.first(where: { $0.name == String(part) }) else {
                throw WireError.noDevice
            }
            current = next.id
        }
        return current
    }

    /// Batch download: each sound as a WAV on the local side.
    public func downloadMany(_ ids: [UInt16],
                             progress: (@Sendable (Int, Int) -> Void)? = nil) async throws
        -> [(name: String, wav: [UInt8])] {
        var out: [(String, [UInt8])] = []
        for (index, id) in ids.enumerated() {
            progress?(index, ids.count)
            let meta = (try? await files.getMetadata(fileID: id)) ?? [:]
            let channels = meta["channels"]?.intValue ?? 1
            let rate = meta["samplerate"]?.intValue ?? deviceSampleRate
            let name = meta["name"]?.stringValue ?? "sound \(id)"
            let result = try await files.get(fileID: id)
            out.append((name + ".wav", makeWAV(pcm: result.data, channels: channels, sampleRate: rate)))
        }
        return out
    }

    public func deleteMany(_ ids: [UInt16],
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        for (index, id) in ids.enumerated() {
            progress?(index, ids.count)
            try await files.delete(fileID: id)
        }
    }
}

// MARK: - Backup folder serialization

public enum BackupStore {
    /// Write a backup as a directory: manifest.json + sounds/NNN.pcm + .json sidecars.
    public static func write(_ backup: DeviceBackup, to dir: URL) throws {
        let fm = FileManager.default
        let soundsDir = dir.appendingPathComponent("sounds")
        try fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)

        var manifest: [String: Any] = [
            "deviceSKU": backup.deviceSKU,
            "osVersion": backup.osVersion,
            "createdAt": ISO8601DateFormatter().string(from: backup.createdAt),
            "soundCount": backup.sounds.count,
        ]
        manifest["projectMetadata"] = Dictionary(uniqueKeysWithValues:
            backup.projectMetadata.map { (String($0.key), $0.value.mapValues(\.anyValue)) })
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))

        for sound in backup.sounds {
            let base = String(format: "%03d", sound.nodeID)
            try Data(sound.pcm).write(to: soundsDir.appendingPathComponent("\(base).pcm"))
            let metaData = try JSONSerialization.data(
                withJSONObject: sound.metadata.mapValues(\.anyValue),
                options: [.prettyPrinted, .sortedKeys])
            try metaData.write(to: soundsDir.appendingPathComponent("\(base).json"))
        }
    }

    public static func read(from dir: URL) throws -> DeviceBackup {
        let fm = FileManager.default
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw FileServiceError.metadataParse("manifest.json")
        }
        let soundsDir = dir.appendingPathComponent("sounds")
        var sounds: [SoundBackup] = []
        let names = try fm.contentsOfDirectory(atPath: soundsDir.path).filter { $0.hasSuffix(".pcm") }.sorted()
        for name in names {
            let base = String(name.dropLast(4))
            guard let nodeID = UInt16(base) else { continue }
            let pcm = try Data(contentsOf: soundsDir.appendingPathComponent(name))
            var metadata: [String: JSONValue] = [:]
            let jsonURL = soundsDir.appendingPathComponent("\(base).json")
            if let data = try? Data(contentsOf: jsonURL),
               let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                metadata = dict.compactMapValues { JSONValue(any: $0) }
            }
            sounds.append(SoundBackup(nodeID: nodeID, pcm: Array(pcm), metadata: metadata))
        }
        var projectMetadata: [UInt16: [String: JSONValue]] = [:]
        if let raw = manifest["projectMetadata"] as? [String: Any] {
            for (key, value) in raw {
                if let id = UInt16(key), let dict = value as? [String: Any] {
                    projectMetadata[id] = dict.compactMapValues { JSONValue(any: $0) }
                }
            }
        }
        let createdAt = ISO8601DateFormatter().date(from: manifest["createdAt"] as? String ?? "") ?? Date()
        return DeviceBackup(deviceSKU: manifest["deviceSKU"] as? String ?? "",
                            osVersion: manifest["osVersion"] as? String ?? "",
                            createdAt: createdAt,
                            sounds: sounds, projectMetadata: projectMetadata)
    }
}
