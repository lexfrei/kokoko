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
        return provider
    }
}
