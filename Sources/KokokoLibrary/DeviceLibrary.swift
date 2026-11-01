import Foundation
import KokokoAudio
import KokokoCore
import KokokoMIDI

/// One sound in a backup: raw PCM plus its device metadata.
public struct SoundBackup: Sendable {
    public var nodeID: UInt16
    public var pcm: [UInt8]
    public var metadata: [String: JSONValue]

    public init(nodeID: UInt16, pcm: [UInt8], metadata: [String: JSONValue]) {
        self.nodeID = nodeID
        self.pcm = pcm
        self.metadata = metadata
    }
}

/// Whole-device state: manifest + sounds + project tree metadata.
public struct DeviceBackup: Sendable {
    public var deviceSKU: String
    public var osVersion: String
    public var createdAt: Date
    public var sounds: [SoundBackup]
    /// Node metadata keyed by node id, for every non-sound node (projects tree).
    public var projectMetadata: [UInt16: [String: JSONValue]]
    /// Project archives by project name ("01".."09"), when the scope includes them.
    public var projectArchives: [String: [UInt8]]

    public init(deviceSKU: String, osVersion: String, createdAt: Date,
                sounds: [SoundBackup], projectMetadata: [UInt16: [String: JSONValue]],
                projectArchives: [String: [UInt8]] = [:]) {
        self.deviceSKU = deviceSKU
        self.osVersion = osVersion
        self.createdAt = createdAt
        self.sounds = sounds
        self.projectMetadata = projectMetadata
        self.projectArchives = projectArchives
    }
}

/// Batch operations and full-state backup/restore over DeviceFileService.
public actor DeviceLibrary {
    private let files: DeviceFileService

    public init(files: DeviceFileService) {
        self.files = files
    }

    public enum Scope: Sendable {
        case sounds
        case projects
        case everything
    }

    /// Backup by scope. Sounds carry pcm + metadata; projects carry their .tar
    /// archive plus the metadata of the whole projects subtree.
    public func backup(deviceSKU: String, osVersion: String, scope: Scope = .everything,
                       progress: (@Sendable (String) -> Void)? = nil) async throws -> DeviceBackup {
        var backups: [SoundBackup] = []
        if scope != .projects {
            let soundsRoot = try await resolve("/sounds")
            for node in try await files.list(nodeID: soundsRoot) where node.isFile {
                progress?(node.name)
                // get stops at the first empty page, so a short read is not an error by itself.
                let pcm = try await files.get(fileID: node.id).data
                guard pcm.count == Int(node.size) else {
                    throw FileServiceError.truncated(fileID: node.id, expected: Int(node.size), got: pcm.count)
                }
                let meta = (try? await files.getMetadata(fileID: node.id)) ?? [:]
                backups.append(SoundBackup(nodeID: node.id, pcm: pcm, metadata: meta))
            }
        }

        var projectMetadata: [UInt16: [String: JSONValue]] = [:]
        var archives: [String: [UInt8]] = [:]
        if scope != .sounds {
            let projectsRoot = try await resolve("/projects")
            try await collectMetadata(nodeID: projectsRoot, into: &projectMetadata)
            for project in try await files.list(nodeID: projectsRoot) {
                progress?("P\(project.name)")
                let archive = try await files.get(fileID: project.id)
                archives[project.name] = archive.data
            }
        }

        return DeviceBackup(deviceSKU: deviceSKU, osVersion: osVersion, createdAt: Date(),
                            sounds: backups, projectMetadata: projectMetadata,
                            projectArchives: archives)
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

    /// Recreate sounds in their original slots, or in a device-assigned slot when
    /// the original holds a different sound or cannot be read back. A sound whose
    /// original slot already holds the same PCM only gets its metadata reapplied,
    /// so repeating a restore does not upload it again; a sound that went to a
    /// device-assigned slot is uploaded again on every repeat.
    /// Upload project archives back into their slots; reapply project metadata
    /// (active selections, pad assignments). A pad's "sym" that names a sound which
    /// moved is pointed at the slot it landed in; references inside the project
    /// archives themselves are not rewritten. An archive whose project slot is not
    /// on the device is not uploaded; the names of those archives are returned.
    @discardableResult
    public func restore(_ backup: DeviceBackup,
                        progress: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        // Original id → the slot a sound actually landed in, for sounds that moved.
        var movedTo: [UInt16: UInt16] = [:]
        if !backup.sounds.isEmpty {
            let soundsRoot = try await resolve("/sounds")
            // Sizes in bytes of what was on the device before this restore started.
            var listed: [UInt16: Int] = [:]
            for node in try await files.list(nodeID: soundsRoot) {
                listed[node.id] = Int(node.size)
            }
            // Only slots from the initial listing are candidates for "already there":
            // a slot this run filled holds another backup sound, even with equal PCM.
            var placed: Set<UInt16> = []
            // Original ids of backup sounds already handled by this run.
            var restoredIDs: Set<UInt16> = []
            for sound in backup.sounds {
                progress?(sound.metadata["name"]?.stringValue ?? "node \(sound.nodeID)")
                if !placed.contains(sound.nodeID), await slot(sound.nodeID, sized: listed, holds: sound.pcm) {
                    // Already there, e.g. from an interrupted earlier restore.
                    try await files.setMetadata(fileID: sound.nodeID, sound.metadata)
                    placed.insert(sound.nodeID)
                    restoredIDs.insert(sound.nodeID)
                    continue
                }
                let taken = listed[sound.nodeID] != nil || placed.contains(sound.nodeID)
                let targetID = taken ? 0 : sound.nodeID
                let newID: UInt16
                do {
                    newID = try await files.put(parentID: soundsRoot,
                                                name: sound.metadata["name"]?.stringValue
                                                    ?? "sound \(sound.nodeID)",
                                                data: sound.pcm, fileID: targetID)
                } catch {
                    // Once init has named the node it is known to be ours; before
                    // that, only an explicit slot is.
                    if case FileServiceError.putIncomplete(let partial, _) = error {
                        await removeIfListed(partial, in: soundsRoot)
                    } else if targetID != 0 {
                        await removeIfListed(targetID, in: soundsRoot)
                    }
                    throw error
                }
                // An assigned slot may equal a later sound's original id; without this
                // that sound is put explicitly into the occupied slot over this one.
                placed.insert(newID)
                // A pad names the first sound restored under an id; a later one with
                // the same original id must not pull the pad away from it.
                if newID != sound.nodeID, !restoredIDs.contains(sound.nodeID) {
                    movedTo[sound.nodeID] = newID
                }
                restoredIDs.insert(sound.nodeID)
                do {
                    try await files.setMetadata(fileID: newID, sound.metadata)
                } catch {
                    try? await files.delete(fileID: newID)
                    throw error
                }
            }
        }
        var skipped: [String] = []
        if !backup.projectArchives.isEmpty {
            let projectsRoot = try await resolve("/projects")
            let slots = try await files.list(nodeID: projectsRoot)
            for (name, archive) in backup.projectArchives.sorted(by: { $0.key < $1.key }) {
                guard let slot = slots.first(where: { $0.name == name }) else {
                    skipped.append(name)
                    continue
                }
                progress?("P\(name)")
                _ = try await files.put(parentID: projectsRoot, name: name, data: archive,
                                        fileID: slot.id, capabilities: [FileCapability.read],
                                        timeout: .seconds(60))
            }
            for (nodeID, meta) in backup.projectMetadata {
                var meta = meta
                if let sym = meta["sym"]?.intValue, let original = UInt16(exactly: sym),
                   let landed = movedTo[original] {
                    meta["sym"] = .int(Int(landed))
                }
                try? await files.setMetadata(fileID: nodeID, meta)
            }
        }
        return skipped
    }

    /// Byte-identical PCM counts as the same sound. A read failure means "not
    /// the same": the caller falls back to an assigned slot instead of aborting.
    private func slot(_ id: UInt16, sized sizes: [UInt16: Int], holds pcm: [UInt8]) async -> Bool {
        guard sizes[id] == pcm.count else { return false }
        return (try? await files.get(fileID: id).data) == pcm
    }

    private func removeIfListed(_ id: UInt16, in parent: UInt16) async {
        if let nodes = try? await files.list(nodeID: parent), nodes.contains(where: { $0.id == id }) {
            try? await files.delete(fileID: id)
        }
    }

    public func resolve(_ path: String) async throws -> UInt16 {
        var current: UInt16 = 0
        for part in path.split(separator: "/") {
            let children = try await files.list(nodeID: current)
            guard let next = children.first(where: { $0.name == String(part) }) else {
                throw FileServiceError.pathNotFound(path)
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

    /// With a bin, each sound is copied into it before the device delete; a
    /// sound whose copy is not byte-complete is not deleted. After a failed
    /// delete the copy is kept unless the sound is still listed on the device.
    public func deleteMany(_ ids: [UInt16], into bin: RecycleBin? = nil,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        var sizes: [UInt16: UInt32] = [:]
        if bin != nil {
            for node in try await files.list(nodeID: try await resolve("/sounds")) where node.isFile {
                sizes[node.id] = node.size
            }
            if let stray = ids.first(where: { sizes[$0] == nil }) {
                throw RecycleBinError.notASound(stray)
            }
        }
        for (index, id) in ids.enumerated() {
            progress?(index, ids.count)
            guard let bin else {
                try await files.delete(fileID: id)
                continue
            }
            guard let size = sizes[id] else { throw RecycleBinError.notASound(id) }
            let pcm = try await files.get(fileID: id).data
            guard pcm.count == Int(size) else {
                throw RecycleBinError.incompleteCopy(slot: id, expected: Int(size), got: pcm.count)
            }
            let metadata = try await files.getMetadata(fileID: id)
            let entry = try bin.add(SoundBackup(nodeID: id, pcm: pcm, metadata: metadata))
            do {
                try await files.delete(fileID: id)
            } catch {
                // A sound still listed was not deleted; its copy would restore as a duplicate.
                if let left = try? await files.list(nodeID: try await resolve("/sounds")),
                   left.contains(where: { $0.id == id }) {
                    try? bin.remove(entry)
                }
                throw error
            }
        }
    }

    /// Put a binned sound back into its original slot, or a device-assigned
    /// one when that slot is taken. A slot that already holds the same PCM and
    /// metadata means the sound is back, so only the entry is dropped; a sound an
    /// earlier restore put into a device-assigned slot is uploaded again. Returns
    /// the slot it is in.
    public func restore(_ entry: BinEntry, from bin: RecycleBin) async throws -> UInt16 {
        let sound = try bin.load(entry)
        let soundsRoot = try await resolve("/sounds")
        var sizes: [UInt16: Int] = [:]
        for node in try await files.list(nodeID: soundsRoot) {
            sizes[node.id] = Int(node.size)
        }
        // Already back, settings included: an earlier restore could not drop the entry.
        // With other settings the entry is their only copy, so it is restored normally.
        if await self.slot(sound.nodeID, sized: sizes, holds: sound.pcm),
           let current = try? await files.getMetadata(fileID: sound.nodeID),
           current.mapValues(\.normalizedNumbers) == sound.metadata.mapValues(\.normalizedNumbers) {
            try? bin.remove(entry)
            return sound.nodeID
        }
        let slot: UInt16 = sizes[sound.nodeID] == nil ? sound.nodeID : 0
        let newID: UInt16
        do {
            newID = try await files.put(parentID: soundsRoot, name: entry.name, data: sound.pcm,
                                        fileID: slot)
        } catch {
            if case FileServiceError.putIncomplete(let partial, _) = error {
                let removed = (try? await files.delete(fileID: partial)) != nil
                if !removed && slot == 0 {
                    throw RecycleBinError.partialSoundMayRemain(underlying: error.localizedDescription)
                }
                throw error
            }
            guard slot != 0 else {
                throw RecycleBinError.partialSoundMayRemain(underlying: error.localizedDescription)
            }
            // Without this a retry finds the original slot taken by the partial copy.
            await removeIfListed(slot, in: soundsRoot)
            throw error
        }
        do {
            try await files.setMetadata(fileID: newID, sound.metadata)
        } catch {
            try? await files.delete(fileID: newID)
            throw error
        }
        // The sound is back; a stale entry is better than reporting a failure.
        try? bin.remove(entry)
        return newID
    }
}

// MARK: - Backup folder serialization

public enum RestoreSkip {
    public static func message(projects: [String]) -> String? {
        guard !projects.isEmpty else { return nil }
        return projects.map { "P\($0)" }.joined(separator: ", ") + " skipped: no such project slot on the device"
    }
}

public enum BackupStore {
    /// Write a backup as a directory: manifest.json + sounds/NNN.pcm + .json sidecars.
    public static func write(_ backup: DeviceBackup, to dir: URL) throws {
        let fm = FileManager.default
        var manifest: [String: Any] = [
            "deviceSKU": backup.deviceSKU,
            "osVersion": backup.osVersion,
            "createdAt": ISO8601DateFormatter().string(from: backup.createdAt),
            "soundCount": backup.sounds.count,
        ]
        manifest["projectMetadata"] = Dictionary(uniqueKeysWithValues:
            backup.projectMetadata.map { (String($0.key), $0.value.mapValues(\.anyValue)) })
        if !backup.projectArchives.isEmpty {
            manifest["projectArchives"] = backup.projectArchives.keys.sorted()
        }
        // Checked up front: JSONSerialization raises an uncatchable exception on NaN, and
        // a refused backup should not leave a half-written folder behind.
        let soundMetadata = backup.sounds.map { $0.metadata.mapValues(\.anyValue) }
        guard JSONSerialization.isValidJSONObject(manifest),
              soundMetadata.allSatisfy(JSONSerialization.isValidJSONObject) else {
            throw FileServiceError.unserializableMetadata
        }
        let soundsDir = dir.appendingPathComponent("sounds")
        try fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))

        if !backup.projectArchives.isEmpty {
            let projectsDir = dir.appendingPathComponent("projects")
            try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            for (name, archive) in backup.projectArchives {
                try Data(archive).write(to: projectsDir.appendingPathComponent("P\(name).tar"))
            }
        }

        for (sound, metadata) in zip(backup.sounds, soundMetadata) {
            let base = String(format: "%03d", sound.nodeID)
            try Data(sound.pcm).write(to: soundsDir.appendingPathComponent("\(base).pcm"))
            let metaData = try JSONSerialization.data(withJSONObject: metadata,
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
        var archives: [String: [UInt8]] = [:]
        let projectsDir = dir.appendingPathComponent("projects")
        if let names = try? fm.contentsOfDirectory(atPath: projectsDir.path) {
            for name in names where name.hasSuffix(".tar") {
                let slot = String(name.dropFirst().dropLast(4))
                if let data = try? Data(contentsOf: projectsDir.appendingPathComponent(name)) {
                    archives[slot] = Array(data)
                }
            }
        }
        let createdAt = ISO8601DateFormatter().date(from: manifest["createdAt"] as? String ?? "") ?? Date()
        return DeviceBackup(deviceSKU: manifest["deviceSKU"] as? String ?? "",
                            osVersion: manifest["osVersion"] as? String ?? "",
                            createdAt: createdAt,
                            sounds: sounds, projectMetadata: projectMetadata,
                            projectArchives: archives)
    }
}
