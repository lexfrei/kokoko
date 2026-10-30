import CoreMIDI
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import KokokoAudio
import KokokoCore
import KokokoLibrary
import KokokoMIDI

enum ConnectionState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(deviceName: String, serial: String, osVersion: String)
    case failed(String)
}

enum AppView {
    case sounds
    case projects
}

struct ProjectItem: Identifiable, Equatable {
    let id: UInt16
    let name: String
    let size: UInt32
}

struct SoundItem: Identifiable, Equatable {
    let node: FSNode
    let displayName: String
    var id: UInt16 { node.id }
}

enum PendingPicker: Equatable {
    case none
    case downloadFolder([UInt16])
    case backupFolder
    case restoreFolder
}

/// Root state: MIDI scan → identify → greet → file service → /sounds listing.
@MainActor
final class AppState: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var sounds: [SoundItem] = []
    @Published var selection = Set<UInt16>()
    @Published var progressText: String?
    @Published var lastError: String?
    @Published var showImporter = false
    @Published var exportDocument: DataDocument?
    @Published var exportName = "sound.wav"
    @Published var picker: PendingPicker = .none
    @Published var renumberItem: SoundItem?
    @Published var view: AppView = .sounds
    @Published var projects: [ProjectItem] = []
    @Published var bulkMoveStart = ""

    private var session: SysExSession?
    private var files: DeviceFileService?
    private var library: DeviceLibrary?
    private var soundsRootID: UInt16?
    private var deviceMeta = GreetMetadata()

    func scan() async {
        connection = .scanning
        // Offline entries are cached ghosts of unplugged devices; they can
        // never answer and each would burn the full identity timeout.
        let pairs = enumerateMIDIPairs().filter {
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty($0.destination, kMIDIPropertyOffline, &offline)
            return offline == 0
        }
        for pair in pairs {
            do {
                connection = .connecting(pair.name)
                let wire = try CoreMIDIWire(pair: pair)
                guard let reply = try? await identifyDevice(on: wire) else {
                    continue
                }
                let session = SysExSession(wire: wire, identityCode: reply.deviceID)
                let meta = try await session.greet()
                let service = DeviceFileService(session: session)
                try await service.initialize()
                self.session = session
                self.files = service
                self.library = DeviceLibrary(files: service)
                deviceMeta = meta
                connection = .connected(deviceName: pair.name,
                                        serial: meta.serial,
                                        osVersion: meta.osVersion)
                await reload()
                return
            } catch {
                continue
            }
        }
        connection = .failed("no device found")
    }

    func reload() async {
        guard let files else { return }
        do {
            let root = try await resolvePath("/sounds")
            soundsRootID = root
            let nodes = try await files.list(nodeID: root)
            var items: [SoundItem] = []
            for node in nodes where node.isFile {
                let meta = try? await files.getMetadata(fileID: node.id)
                let display = meta?["name"]?.stringValue ?? node.name
                items.append(SoundItem(node: node, displayName: display))
            }
            sounds = items
            lastError = nil
        } catch {
            lastError = "list failed: \(error.localizedDescription)"
        }
    }

    /// Resolve a path like "/sounds" by walking the tree from the root (id 0).
    private func resolvePath(_ path: String) async throws -> UInt16 {
        guard let files else { throw WireError.noDevice }
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

    // MARK: - upload

    func upload(urls: [URL]) async {
        guard let files, let root = soundsRootID else { return }
        for url in urls {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                progressText = "prep \(url.lastPathComponent)"
                let prepared = try prepareForUpload(fileData: data, fileName: url.lastPathComponent)
                let name = normalizedDeviceFileName(url.lastPathComponent)
                progressText = "send \(name)"
                let fileID = try await files.put(parentID: root, name: name, data: prepared.pcm) { done, total in
                    Task { @MainActor in
                        self.progressText = "send \(name) \(done * 100 / max(total, 1))%"
                    }
                }
                var meta = prepared.metadata
                meta["name"] = .string(name)
                try await files.setMetadata(fileID: fileID, meta)
                progressText = nil
            } catch {
                progressText = nil
                lastError = "upload \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        await reload()
    }

    // MARK: - download (single + batch)

    func download(_ item: SoundItem) async -> (name: String, wav: [UInt8])? {
        guard let files else { return nil }
        do {
            progressText = "recv \(item.displayName)"
            let meta = (try? await files.getMetadata(fileID: item.node.id)) ?? [:]
            let channels = meta["channels"]?.intValue ?? 1
            let rate = meta["samplerate"]?.intValue ?? deviceSampleRate
            let result = try await files.get(fileID: item.node.id) { done, total in
                Task { @MainActor in
                    self.progressText = "recv \(item.displayName) \(done * 100 / max(total, 1))%"
                }
            }
            progressText = nil
            return (item.displayName + ".wav",
                    makeWAV(pcm: result.data, channels: channels, sampleRate: rate))
        } catch {
            progressText = nil
            lastError = "download: \(error.localizedDescription)"
            return nil
        }
    }

    func downloadManyToFolder(_ ids: [UInt16], folder: URL) async {
        guard let library else { return }
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let wavs = try await library.downloadMany(ids) { [weak self] done, total in
                Task { @MainActor in self?.progressText = "recv \(done)/\(total)" }
            }
            for wav in wavs {
                try Data(wav.wav).write(to: folder.appendingPathComponent(wav.name))
            }
            progressText = nil
        } catch {
            progressText = nil
            lastError = "batch download: \(error.localizedDescription)"
        }
    }

    // MARK: - delete

    func delete(_ item: SoundItem) async {
        guard let files else { return }
        do {
            try await files.delete(fileID: item.node.id)
            await reload()
        } catch {
            lastError = "delete: \(error.localizedDescription)"
        }
    }

    func deleteMany(_ ids: Set<UInt16>) async {
        guard let library else { return }
        do {
            try await library.deleteMany(Array(ids)) { [weak self] done, total in
                Task { @MainActor in self?.progressText = "del \(done)/\(total)" }
            }
            selection = []
            progressText = nil
            await reload()
        } catch {
            progressText = nil
            lastError = "batch delete: \(error.localizedDescription)"
        }
    }

    // MARK: - backup / restore

    func backupToFolder(_ folder: URL) async {
        guard let library else { return }
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            progressText = "backup..."
            let backup = try await library.backup(deviceSKU: deviceMeta.sku,
                                                  osVersion: deviceMeta.osVersion) { [weak self] name in
                Task { @MainActor in self?.progressText = "backup \(name)" }
            }
            let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
                .replacingOccurrences(of: ":", with: "-")
            let target = folder.appendingPathComponent("kokoko-backup-\(stamp)")
            try BackupStore.write(backup, to: target)
            progressText = nil
        } catch {
            progressText = nil
            lastError = "backup: \(error.localizedDescription)"
        }
    }

    func restoreFromFolder(_ folder: URL) async {
        guard let library else { return }
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let backup = try BackupStore.read(from: folder)
            progressText = "restore..."
            try await library.restore(backup) { [weak self] name in
                Task { @MainActor in self?.progressText = "restore \(name)" }
            }
            progressText = nil
            await reload()
        } catch {
            progressText = nil
            lastError = "restore: \(error.localizedDescription)"
        }
    }

    // MARK: - renumber

    /// Move a sound to a different slot number (node id). Fails if occupied.
    func renumber(_ item: SoundItem, to target: UInt16) async {
        guard let files, let root = soundsRootID else { return }
        do {
            let nodes = try await files.list(nodeID: root)
            if nodes.contains(where: { $0.id == target }) {
                lastError = "slot \(target) is occupied"
                return
            }
            try await files.move(fileID: item.node.id, toParent: root, newFileID: target)
            await reload()
        } catch {
            lastError = "renumber: \(error.localizedDescription)"
        }
    }

    /// Bulk move: selected sounds land on consecutive slots starting at `start`.
    /// Everything moves out to temporary ids first, then into place — order is
    /// preserved and occupied targets never collide.
    func moveSelection(startingAt start: UInt16) async {
        guard let files, let root = soundsRootID, !selection.isEmpty else { return }
        do {
            let ids = selection.sorted()
            let nodes = try await files.list(nodeID: root)
            let occupied = Set(nodes.map(\.id))
            var temp: UInt16 = 65000
            var tempMap: [(from: UInt16, temp: UInt16)] = []
            progressText = "move out..."
            for id in ids {
                while occupied.contains(temp) { temp &-= 1 }
                try await files.move(fileID: id, toParent: root, newFileID: temp)
                tempMap.append((id, temp))
                temp &-= 1
            }
            var target = start
            for (index, pair) in tempMap.enumerated() {
                progressText = "move \(index + 1)/\(tempMap.count)"
                // Skip slots still held by members of the selection in flight.
                while occupied.contains(target) && !ids.contains(target) { target &+= 1 }
                if pair.from == target { continue }
                try await files.move(fileID: pair.temp, toParent: root, newFileID: target)
                target &+= 1
            }
            selection = []
            progressText = nil
            await reload()
        } catch {
            progressText = nil
            lastError = "bulk move: \(error.localizedDescription)"
        }
    }

    /// Drag reorder: move to the target slot; swap with the occupant if taken.
    func moveOrSwap(id: UInt16, toSlot target: UInt16) async {
        guard let files, let root = soundsRootID, id != target else { return }
        do {
            let nodes = try await files.list(nodeID: root)
            if let occupant = nodes.first(where: { $0.id == target }) {
                var temp: UInt16 = 65000
                while nodes.contains(where: { $0.id == temp }) { temp &-= 1 }
                try await files.move(fileID: id, toParent: root, newFileID: temp)
                try await files.move(fileID: occupant.id, toParent: root, newFileID: id)
                try await files.move(fileID: temp, toParent: root, newFileID: target)
            } else {
                try await files.move(fileID: id, toParent: root, newFileID: target)
            }
            await reload()
        } catch {
            lastError = "move: \(error.localizedDescription)"
        }
    }

    // MARK: - projects

    func loadProjects() async {
        guard let files else { return }
        do {
            let root = try await resolvePath("/projects")
            let nodes = try await files.list(nodeID: root)
            projects = nodes.map { ProjectItem(id: $0.id, name: $0.name, size: $0.size) }
            lastError = nil
        } catch {
            lastError = "projects: \(error.localizedDescription)"
        }
    }

    /// Download a project as its .tar archive (same shape the original tool uses).
    func downloadProject(_ project: ProjectItem) async -> (name: String, tar: [UInt8])? {
        guard let files else { return nil }
        do {
            progressText = "recv P\(project.name)"
            let result = try await files.get(fileID: project.id)
            progressText = nil
            return ("P\(project.name).tar", result.data)
        } catch {
            progressText = nil
            lastError = "project download: \(error.localizedDescription)"
            return nil
        }
    }

    /// Upload a .tar project archive; the name carries the target slot (P01..P09).
    func uploadProject(url: URL) async {
        guard let files else { return }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let match = url.lastPathComponent.range(of: #"P(\d{2})\.tar$"#,
                                                          options: .regularExpression) else {
                lastError = "project archive must be named like P01.tar"
                return
            }
            let slot = String(url.lastPathComponent[match].dropFirst().dropLast(4))
            let data = Array(try Data(contentsOf: url))
            let projectsRoot = try await resolvePath("/projects")
            guard let parent = try await files.list(nodeID: projectsRoot)
                .first(where: { $0.name == slot }) else {
                lastError = "no project slot P\(slot) on device"
                return
            }
            progressText = "send P\(slot)"
            _ = try await files.put(parentID: projectsRoot, name: slot, data: data,
                                    fileID: parent.id, capabilities: [FileCapability.read],
                                    progress: { [weak self] done, total in
                                        Task { @MainActor in
                                            self?.progressText = "send P\(slot) \(done * 100 / max(total, 1))%"
                                        }
                                    },
                                    timeout: .seconds(60))
            progressText = nil
            await loadProjects()
        } catch {
            progressText = nil
            lastError = "project upload: \(error.localizedDescription)"
        }
    }

    // MARK: - misc

    func audition(_ item: SoundItem) async {
        guard let files else { return }
        try? await files.startPlayback(fileID: item.node.id, offset: 0, length: 1000)
    }

    /// Drag-out provider: downloads the sound on demand and hands over a WAV file.
    func dragProvider(for item: SoundItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.wav.identifier,
                                            visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                if let result = await self.download(item) {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(result.name)
                    do {
                        try Data(result.wav).write(to: temp)
                        progress.completedUnitCount = 1
                        completion(temp, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                } else {
                    completion(nil, false, self.lastError.map { NSError(domain: "kokoko", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]) })
                }
            }
            return progress
        }
        provider.suggestedName = item.displayName + ".wav"
        // In-app reorder payload alongside the exported file representation.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            visibility: .all) { completion in
            completion("node:\(item.id)".data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}
