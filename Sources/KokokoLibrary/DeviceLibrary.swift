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
    /// Metadata of the directories in the projects tree, keyed by path
    /// ("/projects", "/projects/01/groups"). Node ids differ between devices, so an
    /// "active" selection is kept as the path of the node it selects, and left out
    /// when it selects no node in the tree.
    public var projectMetadata: [String: [String: JSONValue]]
    /// Project metadata entries of an older backup that keyed them by node id;
    /// they are not restored.
    public var legacyProjectSettings: Int
    /// What the backup could not capture; not written to the backup folder.
    public var report = BackupReport()
    /// Project archives by project name ("01".."09"), when the scope includes them.
    public var projectArchives: [String: [UInt8]]

    public init(deviceSKU: String, osVersion: String, createdAt: Date,
                sounds: [SoundBackup], projectMetadata: [String: [String: JSONValue]],
                projectArchives: [String: [UInt8]] = [:], legacyProjectSettings: Int = 0) {
        self.deviceSKU = deviceSKU
        self.osVersion = osVersion
        self.createdAt = createdAt
        self.sounds = sounds
        self.projectMetadata = projectMetadata
        self.projectArchives = projectArchives
        self.legacyProjectSettings = legacyProjectSettings
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
        var unread: [String] = []
        if scope != .projects {
            let soundsRoot = try await resolve("/sounds")
            for node in try await files.list(nodeID: soundsRoot) where node.isFile {
                progress?(node.name)
                // get stops at the first empty page, so a short read is not an error by itself.
                let pcm = try await files.get(fileID: node.id).data
                guard pcm.count == Int(node.size) else {
                    throw FileServiceError.truncated(fileID: node.id, expected: Int(node.size), got: pcm.count)
                }
                let meta: [String: JSONValue]
                if let read = try? await files.getMetadata(fileID: node.id) {
                    meta = read
                } else {
                    meta = [:]
                    unread.append(node.name)
                }
                backups.append(SoundBackup(nodeID: node.id, pcm: pcm, metadata: meta))
            }
        }

        var projectMetadata: [String: [String: JSONValue]] = [:]
        var archives: [String: [UInt8]] = [:]
        if scope != .sounds {
            let projectsRoot = try await resolve("/projects")
            let tree = try await walk(projectsRoot, path: "/projects")
            let pathOf = Dictionary(tree.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
            for node in tree where !node.isFile {
                guard var meta = try? await files.getMetadata(fileID: node.id) else {
                    unread.append(node.path)
                    continue
                }
                // A selection that names no node in the tree has nothing to point at elsewhere.
                if let active = meta.removeValue(forKey: "active"),
                   let target = active.intValue.flatMap(UInt16.init(exactly:)).flatMap({ pathOf[$0] }) {
                    meta["active"] = .string(target)
                }
                if !meta.isEmpty { projectMetadata[node.path] = meta }
            }
            for project in try await files.list(nodeID: projectsRoot) {
                progress?("P\(project.name)")
                let archive = try await files.get(fileID: project.id)
                archives[project.name] = archive.data
            }
        }

        var backup = DeviceBackup(deviceSKU: deviceSKU, osVersion: osVersion, createdAt: Date(),
                                  sounds: backups, projectMetadata: projectMetadata,
                                  projectArchives: archives)
        backup.report = BackupReport(unreadMetadata: unread)
        return backup
    }

    /// Every node under the directory `id`, with its path, `id` itself first.
    private func walk(_ id: UInt16, path: String) async throws -> [(path: String, id: UInt16, isFile: Bool)] {
        var nodes = [(path: path, id: id, isFile: false)]
        for child in try await files.list(nodeID: id) {
            let childPath = path + "/" + child.name
            if child.isFile {
                nodes.append((path: childPath, id: child.id, isFile: true))
            } else {
                nodes += try await walk(child.id, path: childPath)
            }
        }
        return nodes
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
    /// on the device is not uploaded. Project metadata goes to the node at the same
    /// path, with "active" pointed at the node at its saved path; metadata whose
    /// node or selection is missing, or whose write fails, is reported, not applied.
    @discardableResult
    public func restore(_ backup: DeviceBackup,
                        progress: (@Sendable (String) -> Void)? = nil) async throws -> RestoreReport {
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
                let newID = try await restoreSound(sound.pcm,
                                                   name: sound.metadata["name"]?.stringValue
                                                       ?? "sound \(sound.nodeID)",
                                                   metadata: sound.metadata, in: soundsRoot, slot: targetID)
                // An assigned slot may equal a later sound's original id; without this
                // that sound is put explicitly into the occupied slot over this one.
                placed.insert(newID)
                // A pad names the first sound restored under an id; a later one with
                // the same original id must not pull the pad away from it.
                if newID != sound.nodeID, !restoredIDs.contains(sound.nodeID) {
                    movedTo[sound.nodeID] = newID
                }
                restoredIDs.insert(sound.nodeID)
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
        }
        var unapplied: [String] = []
        if !backup.projectMetadata.isEmpty {
            let tree = try await walk(try await resolve("/projects"), path: "/projects")
            let idOf = Dictionary(tree.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
            // A skipped project is reported once, not once per directory under it.
            let skippedRoots = skipped.map { "/projects/" + $0 }
            for (path, saved) in backup.projectMetadata.sorted(by: { $0.key < $1.key }) {
                guard let nodeID = idOf[path] else {
                    if !skippedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                        unapplied.append(path)
                    }
                    continue
                }
                var meta = saved
                if let active = meta.removeValue(forKey: "active") {
                    if case .string(let target) = active, let selected = idOf[target] {
                        meta["active"] = .int(Int(selected))
                    } else {
                        unapplied.append("\(path) active")
                    }
                }
                if let sym = meta["sym"]?.intValue, let original = UInt16(exactly: sym),
                   let landed = movedTo[original] {
                    meta["sym"] = .int(Int(landed))
                }
                guard !meta.isEmpty else { continue }
                if (try? await files.setMetadata(fileID: nodeID, meta)) == nil {
                    unapplied.append(path)
                }
            }
        }
        return RestoreReport(skippedProjects: skipped, unappliedSettings: unapplied.sorted(),
                             legacySettings: backup.legacyProjectSettings)
    }

    /// Byte-identical PCM counts as the same sound. A read failure means "not
    /// the same": the caller falls back to an assigned slot instead of aborting.
    private func slot(_ id: UInt16, sized sizes: [UInt16: Int], holds pcm: [UInt8]) async -> Bool {
        guard sizes[id] == pcm.count else { return false }
        return (try? await files.get(fileID: id).data) == pcm
    }

    /// True when `id` is not under `parent` afterwards.
    private func removeIfListed(_ id: UInt16, in parent: UInt16) async -> Bool {
        guard let nodes = try? await files.list(nodeID: parent) else { return false }
        guard nodes.contains(where: { $0.id == id }) else { return true }
        return (try? await files.delete(fileID: id)) != nil
    }

    private func restoreSound(_ pcm: [UInt8], name: String, metadata: [String: JSONValue],
                              in parent: UInt16, slot: UInt16) async throws -> UInt16 {
        let files = files
        return try await restoreSoundSteps(
            slot: slot,
            put: { try await files.put(parentID: parent, name: name, data: pcm, fileID: slot) },
            setMetadata: { try await files.setMetadata(fileID: $0, metadata) },
            delete: { try await files.delete(fileID: $0) },
            removeIfListed: { await self.removeIfListed($0, in: parent) })
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
        let newID = try await restoreSound(sound.pcm, name: entry.name, metadata: sound.metadata,
                                           in: soundsRoot, slot: slot)
        // The sound is back; a stale entry is better than reporting a failure.
        try? bin.remove(entry)
        return newID
    }
}

// MARK: - Backup folder serialization

public struct BackupReport: Equatable, Sendable {
    public var unreadMetadata: [String] = []

    public init(unreadMetadata: [String] = []) {
        self.unreadMetadata = unreadMetadata
    }

    public var message: String? {
        guard !unreadMetadata.isEmpty else { return nil }
        return "metadata not read, backed up without it: " + unreadMetadata.joined(separator: ", ")
    }
}

public struct RestoreReport: Equatable, Sendable {
    public var skippedProjects: [String]
    public var unappliedSettings: [String]
    public var legacySettings: Int

    public init(skippedProjects: [String] = [], unappliedSettings: [String] = [], legacySettings: Int = 0) {
        self.skippedProjects = skippedProjects
        self.unappliedSettings = unappliedSettings
        self.legacySettings = legacySettings
    }

    public var message: String? {
        var parts: [String] = []
        if !skippedProjects.isEmpty {
            parts.append(skippedProjects.map { "P\($0)" }.joined(separator: ", ")
                + " skipped: no such project slot on the device")
        }
        if !unappliedSettings.isEmpty {
            parts.append("settings not applied: " + unappliedSettings.joined(separator: ", "))
        }
        if legacySettings > 0 {
            parts.append("\(legacySettings) project settings from an older backup not applied")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
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
            backup.projectMetadata.map { ($0.key, $0.value.mapValues(\.anyValue)) })
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
        var projectMetadata: [String: [String: JSONValue]] = [:]
        var legacy = 0
        if let raw = manifest["projectMetadata"] as? [String: Any] {
            for (key, value) in raw {
                // Older backups keyed this by node id, which means nothing on another device.
                guard key.hasPrefix("/") else {
                    legacy += 1
                    continue
                }
                if let dict = value as? [String: Any] {
                    projectMetadata[key] = dict.compactMapValues { JSONValue(any: $0) }
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
                            projectArchives: archives, legacyProjectSettings: legacy)
    }
}
