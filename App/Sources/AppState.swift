import CoreMIDI
import Foundation
import SwiftUI
import KokokoCore
import KokokoMIDI
import KokokoAudio

enum ConnectionState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(deviceName: String, serial: String, osVersion: String)
    case failed(String)
}

struct SoundItem: Identifiable, Equatable {
    let node: FSNode
    var id: UInt16 { node.id }
}

/// Root state: MIDI scan → identify → greet → file service → /sounds listing.
@MainActor
final class AppState: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var sounds: [SoundItem] = []
    @Published var progressText: String?
    @Published var lastError: String?
    @Published var showImporter = false
    @Published var exportDocument: DataDocument?
    @Published var exportName = "sound.wav"

    private var session: SysExSession?
    private var files: DeviceFileService?
    private var soundsRootID: UInt16?

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
            sounds = nodes.filter { $0.isFile }.map(SoundItem.init)
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

    func download(_ item: SoundItem) async -> (name: String, wav: [UInt8])? {
        guard let files else { return nil }
        do {
            progressText = "recv \(item.node.name)"
            let meta = (try? await files.getMetadata(fileID: item.node.id)) ?? [:]
            let channels = meta["channels"]?.intValue ?? 1
            let rate = meta["samplerate"]?.intValue ?? deviceSampleRate
            let result = try await files.get(fileID: item.node.id) { done, total in
                Task { @MainActor in
                    self.progressText = "recv \(item.node.name) \(done * 100 / max(total, 1))%"
                }
            }
            progressText = nil
            return (item.node.name + ".wav",
                    makeWAV(pcm: result.data, channels: channels, sampleRate: rate))
        } catch {
            progressText = nil
            lastError = "download: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ item: SoundItem) async {
        guard let files else { return }
        do {
            try await files.delete(fileID: item.node.id)
            await reload()
        } catch {
            lastError = "delete: \(error.localizedDescription)"
        }
    }

    func audition(_ item: SoundItem) async {
        guard let files else { return }
        try? await files.startPlayback(fileID: item.node.id, offset: 0, length: 1000)
    }
}
