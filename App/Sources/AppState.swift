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
    case settings
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
    case backupFolder(DeviceLibrary.Scope)
    case restoreFolder
}

/// Root state: MIDI scan → identify → greet → file service → /sounds listing.
@MainActor
final class AppState: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var sounds: [SoundItem] = [] {
        didSet { pruneSelection() }
    }
    @Published var selection = Set<UInt16>()
    @Published var filterText = "" {
        didSet { pruneSelection() }
    }
    @Published var progressText: String?
    @Published var lastError: String?
    @Published var showImporter = false
    @Published var exportDocument: DataDocument?
    @Published var exportName = "sound.wav"
    @Published var picker: PendingPicker = .none
    @Published var renumberItem: SoundItem?
    @Published var renameItem: SoundItem?
    @Published var renameText = ""
    @Published var firmwareNote: String?

    /// Short suffix for the header: " ✓" when current, " → x.y.z" when behind.
    var firmwareSuffix: String {
        guard let note = firmwareNote else { return "" }
        if let arrow = note.range(of: " → ") {
            return " " + note[arrow.lowerBound...].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "→ ", with: "→ ")
                .description
        }
        return " ✓"
    }
    @Published var settingsTree: [SettingsGroupModel] = []
    @Published var settingsHelp: [String: String] = [:]
    @Published var settingsUnsupported = false
    @Published var view: AppView = .sounds
    @Published var projects: [ProjectItem] = []
    @Published var bulkMoveStart = ""

    var visibleSounds: [SoundItem] {
        sounds.filter { soundMatches(name: $0.displayName, slot: $0.id, query: filterText) }
    }

    private func pruneSelection() {
        let pruned = visibleSelection(selection,
                                      items: sounds.map { (slot: $0.id, name: $0.displayName) },
                                      query: filterText)
        if pruned != selection { selection = pruned }
    }

    /// Selection is keyed by slot, so every slot change on the device must
    /// carry it along, one completed move at a time: a failure halfway
    /// through a swap still leaves each selected sound selected where it is.
    private func move(_ files: DeviceFileService, _ id: UInt16, to target: UInt16,
                      root: UInt16) async throws {
        try await files.move(fileID: id, toParent: root, newFileID: target)
        selection = remapSelection(selection, moves: [(from: id, to: target)])
    }

    /// Runs `steps` in order. When one fails, re-reads the slots and undoes
    /// as much as they allow, stopping at the first undo that is unsafe or
    /// refused; if the re-read fails, nothing is undone. Then rethrows the
    /// original error. A failed reply does not mean the move did not run,
    /// hence the re-read instead of a blind undo.
    private func runMoves(_ steps: [(from: UInt16, to: UInt16)], files: DeviceFileService,
                          root: UInt16, progress: Bool = false) async throws {
        var done: [(from: UInt16, to: UInt16)] = []
        do {
            for (index, step) in steps.enumerated() {
                if progress { progressText = "move \(index + 1)/\(steps.count)" }
                try await move(files, step.from, to: step.to, root: root)
                done.append(step)
            }
        } catch {
            guard let nodes = try? await files.list(nodeID: root) else { throw error }
            let occupied = Set(nodes.map(\.id))
            let failed = steps[done.count]
            if stepLanded(failed, occupied: occupied) {
                selection = remapSelection(selection, moves: [failed])
                done.append(failed)
            }
            let undo = rollbackMoves(done, occupied: occupied)
            for (index, step) in undo.enumerated() {
                if progress { progressText = "undo \(index + 1)/\(undo.count)" }
                do {
                    try await move(files, step.from, to: step.to, root: root)
                } catch {
                    break
                }
            }
            throw error
        }
    }

    private var session: SysExSession?
    private var files: DeviceFileService?
    private var library: DeviceLibrary?
    private var settings: SettingsService?
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
                self.settings = SettingsService(session: session)
                deviceMeta = meta
                connection = .connected(deviceName: pair.name,
                                        serial: meta.serial,
                                        osVersion: meta.osVersion)
                Task { await self.checkFirmware(baseSKU: meta.baseSKU.isEmpty ? meta.sku : meta.baseSKU,
                                                current: meta.osVersion) }
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
        var failures: [String] = []
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
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // After the reload, whose success path clears lastError; appended so
        // a failed reload stays visible too.
        await reload()
        if let text = batchFailureText("upload", failures: failures, total: urls.count) {
            lastError = appendingError(lastError, text)
        }
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
            // A partial failure still changed the device: reload so the list
            // and the selection show what is really there. Its success path
            // clears lastError, so the error is set after it.
            await reload()
            lastError = "batch delete: \(error.localizedDescription)"
        }
    }

    // MARK: - backup / restore

    func backupToFolder(_ folder: URL, scope: DeviceLibrary.Scope = .everything) async {
        guard let library else { return }
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            progressText = "backup..."
            let backup = try await library.backup(deviceSKU: deviceMeta.sku,
                                                  osVersion: deviceMeta.osVersion,
                                                  scope: scope) { [weak self] name in
                Task { @MainActor in self?.progressText = "backup \(name)" }
            }
            let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
                .replacingOccurrences(of: ":", with: "-")
            let label = scope == .sounds ? "sounds" : scope == .projects ? "projects" : "all"
            let target = folder.appendingPathComponent("kokoko-backup-\(label)-\(stamp)")
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
            await reload()
            lastError = "restore: \(error.localizedDescription)"
        }
    }

    // MARK: - rename

    /// Display name lives in metadata; the wire filename stays NNN.pcm.
    func rename(_ item: SoundItem, to name: String) async {
        guard let files else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await files.setMetadata(fileID: item.node.id, ["name": .string(trimmed)])
            await reload()
        } catch {
            lastError = "rename: \(error.localizedDescription)"
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
            try await move(files, item.node.id, to: target, root: root)
            await reload()
        } catch {
            lastError = "renumber: \(error.localizedDescription)"
        }
    }

    /// Bulk move: selected sounds land on consecutive slots starting at
    /// `start`, in slot order; see planBulkMove. The selection stays on the
    /// moved sounds.
    func moveSelection(startingAt start: UInt16) async {
        guard let files, let root = soundsRootID, !selection.isEmpty else { return }
        do {
            let nodes = try await files.list(nodeID: root)
            guard let plan = planBulkMove(selected: Array(selection),
                                          occupied: Set(nodes.map(\.id)), start: start) else {
                lastError = "bulk move: not enough free slots from \(start)"
                return
            }
            try await runMoves(plan, files: files, root: root, progress: true)
            progressText = nil
            await reload()
        } catch {
            progressText = nil
            await reload()
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
                try await runMoves([(id, temp), (occupant.id, id), (temp, target)],
                                   files: files, root: root)
            } else {
                try await move(files, id, to: target, root: root)
            }
            await reload()
        } catch {
            await reload()
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

    /// Upload .tar project archives; each name carries the target slot (P01..P09).
    func uploadProjects(urls: [URL]) async {
        guard let files else { return }
        var failures: [String] = []
        for url in urls {
            do {
                try await sendProject(url: url, files: files)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progressText = nil
        }
        // After the reload, whose success path clears lastError; appended so
        // a failed reload stays visible too.
        await loadProjects()
        if let text = batchFailureText("project upload", failures: failures, total: urls.count) {
            lastError = appendingError(lastError, text)
        }
    }

    private struct ProjectUploadError: LocalizedError {
        let errorDescription: String?
    }

    private func sendProject(url: URL, files: DeviceFileService) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let match = url.lastPathComponent.range(of: #"P(\d{2})\.tar$"#,
                                                      options: .regularExpression) else {
            throw ProjectUploadError(errorDescription: "project archive must be named like P01.tar")
        }
        let slot = String(url.lastPathComponent[match].dropFirst().dropLast(4))
        let data = Array(try Data(contentsOf: url))
        let projectsRoot = try await resolvePath("/projects")
        guard let parent = try await files.list(nodeID: projectsRoot)
            .first(where: { $0.name == slot }) else {
            throw ProjectUploadError(errorDescription: "no project slot P\(slot) on device")
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
    }

    // MARK: - settings

    func loadSettings() async {
        guard let settings else { return }
        do {
            progressText = "settings..."
            try await settings.initialize()
            let all = try await settings.getAll()
            settingsTree = Self.parseSettingsTree(all)
            progressText = nil
        } catch SessionError.deviceError(.commandNotFound, _) {
            progressText = nil
            settingsUnsupported = true
        } catch {
            progressText = nil
            lastError = "settings: \(error.localizedDescription)"
        }
    }

    /// Walk {settings: [{title, settings:[...] | id, value, ...}]} tolerantly.
    static func parseSettingsTree(_ json: [String: JSONValue]) -> [SettingsGroupModel] {
        func entries(_ value: JSONValue) -> [SettingsEntryModel] {
            guard case .array(let items) = value else { return [] }
            return items.compactMap { item in
                guard case .object(let dict) = item,
                      let id = dict["id"]?.intValue else { return nil }
                let title = dict["title"]?.stringValue ?? dict["name"]?.stringValue ?? "setting \(id)"
                let value = dict["value"] ?? dict["current"] ?? .null
                return SettingsEntryModel(id: id, title: title, value: value, range: nil)
            }
        }
        guard case .array(let groups)? = json["settings"] else { return [] }
        return groups.compactMap { group in
            guard case .object(let dict) = group else { return nil }
            let title = dict["title"]?.stringValue ?? dict["name"]?.stringValue ?? "group"
            let children = dict["settings"].map { entries($0) } ?? []
            return SettingsGroupModel(title: title, entries: children)
        }
    }

    // MARK: - firmware

    /// Compare device os_version against the latest published release.
    func checkFirmware(baseSKU: String, current: String) async {
        struct Release: Decodable { let sku: String; let version: String }
        struct Registry: Decodable { let devices: [Release] }
        do {
            let url = URL(string: "https://teenage.engineering/_software/releases.json")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let registry = try JSONDecoder().decode(Registry.self, from: data)
            guard let latest = registry.devices.first(where: { $0.sku == baseSKU }) else { return }
            let latestVersion = latest.version.split(separator: "+").first.map(String.init) ?? latest.version
            firmwareNote = current == latestVersion ? "fw \(current) ✓" : "fw \(current) → \(latestVersion)"
        } catch {
            firmwareNote = nil
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
