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

struct PendingRestore {
    let backup: DeviceBackup
    let summary: RestoreSummary
}

struct WaveformShown: Identifiable {
    let item: SoundItem
    let record: WaveformPeakRecord?
    let loopStart: Int?
    let loopEnd: Int?
    let cached: Bool
    let metadataConfirmed: Bool
    var id: UInt16 { item.id }
}

struct PendingSwap {
    let id: UInt16
    let target: UInt16
    let summary: SwapSummary
}

/// Root state: MIDI scan → identify → greet → file service → /sounds listing.
@MainActor
final class AppState: ObservableObject {
    @Published var rowDrag = RowDragContext()
    private(set) var rowDragGeneration = UUID()
    @Published var connection: ConnectionState = .idle
    @Published var sounds: [SoundItem] = [] {
        didSet { pruneSelection() }
    }
    @Published var selection = Set<UInt16>() {
        didSet { invalidateInlineEditors() }
    }
    /// Old row addresses are unusable after an unrefreshed move or a missing source.
    @Published private(set) var soundsListed = false
    @Published private(set) var listedSoundCount: Int?
    @Published private(set) var soundStorage = SoundStorageState()
    @Published private(set) var soundRange: SoundRange? {
        didSet { pruneSelection() }
    }
    @Published private(set) var filterText = "" {
        didSet { pruneSelection() }
    }
    @Published private(set) var progress = ProgressLine()
    var progressText: String? { progress.text }
    /// Written through reportOperationError, reportLocalError and noteError.
    /// A failed device watch is pinned until a later try replaces it or, once
    /// the watch starts, takes it back. Besides an operation's first error
    /// replacing the line's messages, as ErrorLine does, the messages are
    /// cleared only when a device connects and after a successful sounds
    /// reload; a successful projects or settings load withdraws only its own
    /// earlier failure.
    @Published private(set) var errorLine = ErrorLine()
    var lastError: String? { errorLine.text }
    @Published var showImporter = false {
        didSet { if showImporter { panel.open(.none, generation: hotplug.currentGeneration()) } }
    }
    @Published var exportDocument: DataDocument?
    @Published var exportName = "sound.wav"
    @Published var picker: PendingPicker = .none {
        didSet { if picker != .none { panel.open(picker, generation: hotplug.currentGeneration()) } }
    }
    /// What the open panel was shown for. A device leaving resets `picker`;
    /// if that lands between the user's choice and the panel's callback,
    /// reading `picker` there sends the chosen folder to upload, and the
    /// panel's own settings would switch to upload's while it closes.
    @Published private(set) var panel = PanelRequest()
    @Published var inlineSlotEdit: InlineSlotEdit?
    @Published var inlineRename: InlineRename?
    @Published var statusDetails = Set<UUID>()
    @Published var metadataEditing: InlineMetadataEdit?
    @Published var firmwareStatus: FirmwareStatus?
    @Published var settingsTree: [SettingsGroupModel] = []
    @Published var settingsHelp: [String: String] = [:]
    @Published var settingsStatus: SettingsStatus = .notLoaded
    @Published var view: HeaderTab = .sounds {
        didSet { invalidateInlineEditors() }
    }
    @Published var projects: [ProjectItem] = []
    @Published var binEntries: [BinEntry] = []
    @Published var binToRemove: BinEntry?
    @Published var pendingRestore: PendingRestore?
    @Published var pendingSwap: PendingSwap?
    @Published var waveformShown: WaveformShown? {
        didSet {
            if waveformShown == nil {
                waveformIntent.invalidate()
                waveformLease?.cancel()
            }
        }
    }
    private static let waveformCacheRoot = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("kokoko/waveform-peaks", isDirectory: true)
    private let waveformCache: WaveformCacheStore
    private var waveformCacheSession: UUID?
    private var waveformLease: WaveformCacheLease?
    private struct WaveformLookup {
        let item: SoundItem
        let generation: Int
        let session: UUID
        let request: WaveformRows.Request
    }
    private var waveformLookups: [WaveformLookup] = []
    private var waveformLookupTask: Task<Void, Never>?
    private var waveformIntent = WaveformIntent()
    @Published private(set) var waveformRows = WaveformRows()
    @Published private var deviceAdmission = DeviceAdmission()
    var deviceBusy: Bool { deviceAdmission.operation }
    private var deviceOccupied: Bool { deviceAdmission.occupied }
    /// The sound a delete into the bin failed on, offered for a delete without a copy.
    @Published var unbinnedDelete: (ids: Set<UInt16>, prompt: String, generation: Int)?
    @Published var bulkMoveStart = ""

    init(waveformCache: WaveformCacheStore? = nil) {
        self.waveformCache = waveformCache ?? WaveformCacheStore(root: Self.waveformCacheRoot)
    }

    #if DEBUG
    convenience init(listedSounds: [SoundItem]) {
        self.init()
        sounds = listedSounds
        soundsListed = true
        listedSoundCount = listedSounds.count
    }
    #endif

    var visibleSounds: [SoundItem] {
        sounds.filter { soundMatches(name: $0.displayName, slot: $0.id, query: filterText, range: soundRange) }
    }

    var soundFilterChangeBlocked: Bool {
        inlineRename?.blocksFilterChange == true || inlineSlotEdit?.blocksFilterChange == true
            || metadataEditing?.blocksFilterChange == true
    }

    @discardableResult func setSoundRange(_ range: SoundRange?) -> Bool {
        guard range != soundRange else { return true }
        guard prepareSoundFilterChange() else { return false }
        soundRange = range
        return true
    }

    @discardableResult func setFilterText(_ query: String) -> Bool {
        guard query != filterText else { return true }
        guard prepareSoundFilterChange() else { return false }
        filterText = query
        return true
    }

    private func prepareSoundFilterChange() -> Bool {
        guard !soundFilterChangeBlocked else { return false }
        inlineRename = nil
        inlineSlotEdit = nil
        metadataEditing = nil
        return true
    }

    private func pruneSelection() {
        let pruned = visibleSelection(selection,
                                      items: sounds.map { (slot: $0.id, name: $0.displayName) },
                                      query: filterText, range: soundRange)
        if pruned != selection { selection = pruned }
        invalidateInlineEditors()
    }

    /// Selection is keyed by slot, so every slot change on the device must
    /// carry it along, one completed move at a time: a failure halfway
    /// through a swap still leaves each selected sound selected where it is.
    private func move(_ files: DeviceFileService, _ id: UInt16, to target: UInt16,
                      root: UInt16) async throws {
        await invalidateWaveformContent(slots: [id, target])
        invalidateMetadataIntent(affecting: [id, target])
        try await files.move(fileID: id, toParent: root, newFileID: target)
        selection = remapSelection(selection, moves: [(from: id, to: target)])
    }

    /// One move outside a plan. A failed reply does not mean the move did not
    /// run, so the slots are read again and the selection follows a sound that
    /// landed; the reload that follows would otherwise prune it.
    private func moveOne(_ files: DeviceFileService, _ id: UInt16, to target: UInt16,
                         root: UInt16) async throws {
        do {
            try await move(files, id, to: target, root: root)
        } catch {
            let occupied = (try? await files.list(nodeID: root)).map { Set($0.map(\.id)) }
            selection = selectionAfterFailedMove(selection, move: (from: id, to: target), occupied: occupied)
            throw error
        }
    }

    /// Runs `steps` in order. When one fails, re-reads the slots and undoes
    /// as much as they allow, stopping at the first undo that is unsafe or
    /// refused; if the re-read fails, nothing is undone. Then rethrows the
    /// original error. A failed reply does not mean the move did not run,
    /// hence the re-read instead of a blind undo.
    private func runMoves(_ steps: [(from: UInt16, to: UInt16)], files: DeviceFileService,
                          root: UInt16, op: ProgressLine.Operation? = nil) async throws {
        var done: [(from: UInt16, to: UInt16)] = []
        do {
            for (index, step) in steps.enumerated() {
                if let op { progress.update(op, "move \(index + 1)/\(steps.count)") }
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
                if let op { progress.update(op, "undo \(index + 1)/\(undo.count)") }
                do {
                    try await move(files, step.from, to: step.to, root: root)
                } catch {
                    break
                }
            }
            throw error
        }
    }

    /// Last copies of deleted sounds, kept outside the device.
    let bin = RecycleBin(root: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("kokoko/recycle-bin", isDirectory: true))

    private var session: SysExSession?
    private var hotplug = HotplugPolicy(debounce: 1)
    private var hotplugWatcher: HotplugWatcher?
    /// The session the running scan opened; an unplug closes it like the connected one.
    private var scanning: (pair: MIDIEndpointPair, session: SysExSession)?
    private var connectedPair: MIDIEndpointPair?
    private var files: DeviceFileService?
    private var library: DeviceLibrary?
    private var settings: SettingsService?
    private var soundsRootID: UInt16?
    private var deviceMeta = GreetMetadata()

    private func reportOperationError(_ text: String, kind: ErrorKind? = nil, token: Int) {
        errorLine.report(text, kind: kind, deviceIsCurrent: hotplug.isCurrent(token))
    }

    /// For messages that stay true whatever happens to the device; during an
    /// operation they take its first place like its own errors.
    private func reportLocalError(_ text: String, kind: ErrorKind? = nil) {
        errorLine.report(text, kind: kind, deviceIsCurrent: true)
    }

    /// For messages that belong to no operation, such as refusals and bin
    /// errors.
    func noteError(_ text: String) {
        errorLine.note(text)
    }

    private static let busyText = "device busy: wait for the current operation"

    /// Claims the device for one user action; false while another runs.
    /// A refusal is reported, since a drag to Finder or a drop that slipped
    /// past the disabled controls would otherwise fail without a word.
    func enterDevice() -> Bool {
        guard deviceAdmission.beginOperation() else {
            noteError(Self.busyText)
            return false
        }
        errorLine.start()
        return true
    }

    private func leaveDevice() {
        if deviceAdmission.endOperation() { deviceReleased() }
    }

    private func deviceReleased() {
        errorLine.finish()
        if let tab = tabLoad.deviceReleased(showing: view, needsLoad: tabNeedsLoad(view)) {
            Task { await loadOpenedTab(tab) }
        }
        rescanIfDue()
    }

    var isConnected: Bool {
        if case .connected = connection { true } else { false }
    }

    /// A tab that reads from the device waits while the device is busy and,
    /// if it is still open and, for settings, still not loaded, loads once
    /// the device is released, instead of being refused.
    @Published private(set) var tabLoad = PendingTabLoad()

    func open(_ tab: HeaderTab) {
        let current = view
        view = tab
        if tab == .bin { loadBin() }
        if let load = tabLoad.open(tab, showing: current, needsLoad: tabNeedsLoad(tab), deviceBusy: deviceOccupied) {
            Task { await loadOpenedTab(load) }
        }
    }

    private func tabNeedsLoad(_ tab: HeaderTab) -> Bool {
        isConnected && (tab != .settings || settingsStatus.loadsWhenOpened)
    }

    private func loadOpenedTab(_ tab: HeaderTab) async {
        // Claimed by the rescan first, or by a click in the same moment: the
        // tab waits again rather than putting a busy refusal on the line.
        if deviceOccupied {
            _ = tabLoad.open(tab, needsLoad: tabNeedsLoad(tab), deviceBusy: true)
            return
        }
        switch tab {
        case .projects: await refreshProjects()
        case .settings: await loadSettings()
        case .sounds, .bin: break
        }
    }

    /// The files or folder the open panel returned, routed by what it was opened for.
    func handleImport(_ urls: [URL]) {
        picker = .none
        guard let action = panel.route(currentGeneration: hotplug.currentGeneration()) else {
            noteError("the device changed, the chosen folder was not used")
            return
        }
        Task {
            switch action {
            case .none:
                await upload(urls: urls)
            case .downloadFolder(let ids):
                await downloadManyToFolder(ids, folder: urls[0])
            case .backupFolder(let scope):
                await backupToFolder(urls[0], scope: scope)
            case .restoreFolder:
                prepareRestore(from: urls[0])
            }
        }
    }

    func setStatusDetail(_ id: UUID, shown: Bool) {
        if shown { statusDetails.insert(id) } else { statusDetails.remove(id) }
    }

    /// A file panel, alert, dialog or sheet is up over the window.
    var modalOpen: Bool {
        showImporter || picker != .none || exportDocument != nil
            || unbinnedDelete != nil || binToRemove != nil
            || pendingRestore != nil || pendingSwap != nil
    }

    func isEnabled(_ command: AppCommand) -> Bool {
        command.isEnabled(tab: view, connected: isConnected, busy: deviceOccupied, selection: selection.count,
                          modalOpen: modalOpen || (command == .auditionSelected && (inlineRename != nil || inlineSlotEdit != nil || metadataEditing != nil || !statusDetails.isEmpty)))
    }

    func perform(_ command: AppCommand) {
        guard isEnabled(command) else {
            if deviceOccupied, command != .auditionSelected, command.selectsTab == nil || command.opensPanel {
                noteError(Self.busyText)
            }
            return
        }
        if let tab = command.selectsTab { open(tab) }
        switch command {
        case .addSounds: showImporter = true
        case .downloadSelected: picker = .downloadFolder(Array(selection))
        case .deleteSelected:
            let ids = selection
            Task { await deleteMany(ids) }
        case .backupSounds: picker = .backupFolder(.sounds)
        case .backupProjects: picker = .backupFolder(.projects)
        case .backupAll: picker = .backupFolder(.everything)
        case .restoreBackup: picker = .restoreFolder
        case .showSounds, .showProjects, .showSettings, .showBin: break
        case .refresh:
            switch view {
            case .sounds: Task { await refreshSounds() }
            case .projects: Task { await refreshProjects() }
            case .settings: Task { await loadSettings() }
            case .bin: loadBin()
            }
        case .scan: Task { await scan() }
        case .auditionSelected: auditionSelected()
        }
    }

    func auditionSelected() {
        guard isEnabled(.auditionSelected), selection.count == 1,
              let item = visibleSounds.first(where: { selection.contains($0.id) }) else { return }
        requestAudition(item, selected: selection)
    }

    func refreshSounds() async {
        if let edit = inlineSlotEdit, edit.needsRefresh {
            await refreshInlineSlot(session: edit.session)
            return
        }
        guard enterDevice() else { return }
        defer { leaveDevice() }
        await reload()
    }

    func refreshProjects() async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        await loadProjects()
    }

    /// Starts following MIDI devices coming and going. If that fails, only
    /// the retry button rescans.
    func watchDevices() {
        guard hotplugWatcher == nil else { return }
        do {
            hotplugWatcher = try HotplugWatcher { [weak self] _ in
                Task { @MainActor in self?.devicesChanged() }
            }
            // A window opened again retries; a watch that starts takes the failure back.
            errorLine.unpin(.deviceWatch)
        } catch {
            // Without it the app does not notice a device coming or going, which
            // the startup scan's reload must not hide.
            errorLine.unpin(.deviceWatch)
            errorLine.pin("device watch: \(error.localizedDescription)", kind: .deviceWatch)
        }
    }

    // The debounce sleeps on ContinuousClock, so the policy reads the same clock.
    private let clockStart = ContinuousClock.now
    private var clockSeconds: Double {
        let elapsed = (ContinuousClock.now - clockStart).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func devicesChanged() {
        if let scanning, !pairIsOnline(scanning.pair) {
            let session = scanning.session
            Task { await session.close() }
        }
        let online = connectedPair.map(pairIsOnline) ?? false
        if hotplug.changed(now: clockSeconds, pairOnline: online) == .disconnect {
            let reason = connectedPair.map { "\($0.name) disconnected" } ?? "device disconnected"
            forgetDevice()
            connection = .failed(reason)
            // Reported, not noted: it takes the running operation's first place,
            // so what that operation reports next joins the reason instead of
            // replacing it.
            reportLocalError(reason)
        }
        Task {
            try? await Task.sleep(for: .seconds(hotplug.debounce))
            rescanIfDue()
        }
    }

    private func forgetDevice() {
        // Operations still running on the old session fail when it closes, not after their timeouts.
        if let old = session { Task { await old.close() } }
        connectedPair = nil
        session = nil
        files = nil
        library = nil
        settings = nil
        soundsRootID = nil
        sounds = []
        soundsListed = false
        listedSoundCount = nil
        soundStorage = SoundStorageState()
        projects = []
        selection = []
        unbinnedDelete = nil
        inlineRename = nil
        inlineSlotEdit = nil
        metadataEditing = nil
        picker = .none
        firmwareStatus = nil
        settingsTree = []
        settingsStatus = .notLoaded
        pendingRestore = nil
        pendingSwap = nil
        rowDrag = RowDragContext()
        rowDragGeneration = UUID()
        waveformShown = nil
        waveformCacheSession = nil
        waveformLookups = []
        waveformRows.invalidate(slots: nil)
    }

    private func rescanIfDue() {
        // Checked inside the task: scan() claims the device before its first
        // await, so nothing can take the device between the check and the scan.
        Task {
            guard hotplug.takeRescan(now: clockSeconds, busy: deviceOccupied) else { return }
            await scan()
        }
    }

    func scan() async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        let token = hotplug.currentGeneration()
        connection = .scanning
        // Offline entries are cached ghosts of unplugged devices; they can
        // never answer and each would burn the full identity timeout.
        let pairs = enumerateMIDIPairs().filter {
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty($0.destination, kMIDIPropertyOffline, &offline)
            return offline == 0
        }
        var failures: [String] = []
        for pair in pairs {
            do {
                connection = .connecting(pair.name)
                let wire = try CoreMIDIWire(pair: pair)
                let reply: Identity.Reply
                do {
                    reply = try await identifyDevice(on: wire)
                } catch where isNoIdentityReply(error) {
                    // No identity reply: not a sampler, skipped without a failure.
                    continue
                }
                let session = SysExSession(wire: wire, identityCode: reply.deviceID)
                scanning = (pair, session)
                defer { scanning = nil }
                let meta = try await session.greet()
                let service = DeviceFileService(session: session)
                try await service.initialize()
                guard pairIsOnline(pair) else { continue }
                guard hotplug.commitConnection(token: token) else { break }
                errorLine.clear()
                connectedPair = pair
                self.session = session
                self.files = service
                self.library = DeviceLibrary(files: service)
                self.settings = SettingsService(session: session)
                deviceMeta = meta
                let cacheSession = await waveformCache.configure(model: meta.baseSKU.isEmpty ? meta.sku : meta.baseSKU,
                                                                  serial: meta.serial)
                guard hotplug.isCurrent(token) else { return }
                waveformCacheSession = cacheSession
                connection = .connected(deviceName: pair.name,
                                        serial: meta.serial,
                                        osVersion: meta.osVersion)
                Task { await self.checkFirmware(baseSKU: meta.baseSKU.isEmpty ? meta.sku : meta.baseSKU,
                                                current: meta.osVersion, token: token) }
                // The tab on screen may have been opened before the device was there.
                switch view {
                case .projects: await reloadSoundsAndProjects()
                case .settings:
                    await reload()
                    await fetchSettings()
                case .sounds, .bin: await reload()
                }
                return
            } catch {
                failures.append("\(pair.name): \(error.localizedDescription)")
            }
        }
        connection = .failed(failures.isEmpty ? "no device found" : failures.joined(separator: "; "))
    }

    /// False when the listing failed, so `sounds` may be stale.
    @discardableResult
    func reload() async -> Bool {
        guard let files else {
            soundsListed = false
            soundStorage.invalidate()
            return false
        }
        waveformShown = nil
        waveformRows.invalidate(slots: nil)
        let token = hotplug.currentGeneration()
        let request = soundStorage.begin(generation: token)
        soundsListed = false
        let root: UInt16
        do {
            root = try await resolve("/sounds")
        } catch {
            guard hotplug.isCurrent(token) else { return false }
            let storage: Result<SoundStorage, any Error>
            if let knownRoot = soundsRootID {
                storage = await readSoundStorage(files: files, root: knownRoot)
            } else {
                storage = .failure(error)
            }
            _ = soundStorage.finish(request: request, generation: hotplug.currentGeneration(), result: storage)
            reportOperationError("list failed: \(error.localizedDescription)", token: token)
            return false
        }
        guard hotplug.isCurrent(token) else { return false }
        soundsRootID = root
        let read = await readSoundDirectory(files: files, root: root)
        guard hotplug.isCurrent(token) else { return false }
        _ = soundStorage.finish(request: request, generation: token, result: read.storage)
        let nodes: [FSNode]
        switch read.nodes {
        case .success(let listed): nodes = listed
        case .failure(let error):
            reportOperationError("list failed: \(error.localizedDescription)", token: token)
            return false
        }
        var items: [SoundItem] = []
        for node in nodes where node.isFile {
            let meta = try? await files.getMetadata(fileID: node.id)
            let display = meta?["name"]?.stringValue ?? node.name
            items.append(SoundItem(node: node, displayName: display))
        }
        guard hotplug.isCurrent(token) else { return false }
        if var edit = inlineSlotEdit, edit.submitting, edit.generation == token {
            let carried = edit.reconcile(occupied: Set(items.map(\.id)))
            inlineSlotEdit = edit
            selection = remapSelection(selection, moves: carried)
        }
        sounds = items
        listedSoundCount = items.count
        soundsListed = true
        errorLine.clear()
        return true
    }

    private func resolve(_ path: String) async throws -> UInt16 {
        guard let library else { throw WireError.noDevice }
        return try await library.resolve(path)
    }

    // MARK: - upload

    func upload(urls: [URL]) async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        // A drop, or a panel that stayed open across an unplug, reaches here
        // with sounds the user picked; leaving without a word loses them.
        guard let files else {
            reportLocalError("upload: no device connected")
            return
        }
        guard let root = soundsRootID else {
            reportLocalError("upload: the sounds folder was not found")
            return
        }
        let token = hotplug.currentGeneration()
        var failures: [String] = []
        for url in urls {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                progress.update(op, "prep \(url.lastPathComponent)")
                let prepared = try prepareForUpload(fileData: data, fileName: url.lastPathComponent)
                let name = normalizedDeviceFileName(url.lastPathComponent)
                progress.update(op, "send \(name)")
                await invalidateWaveformContent()
                invalidateMetadataIntent()
                _ = try await uploadSound(files: files, parent: root, name: name, pcm: prepared.pcm,
                                          metadata: prepared.metadata) { done, total in
                    Task { @MainActor in
                        self.progress.update(op, "send \(name) \(done * 100 / max(total, 1))%")
                    }
                }
                progress.update(op, nil)
            } catch {
                progress.update(op, nil)
                failures.append("\(url.lastPathComponent): \(readFailureText(error))")
            }
        }
        // After the reload, whose success path clears the line's messages; appended so
        // a failed reload stays visible too.
        await reload()
        if let text = batchFailureText("upload", failures: failures, total: urls.count) {
            reportOperationError(text, token: token)
        }
    }

    // MARK: - download (single + batch)

    struct DownloadFailure: LocalizedError {
        let errorDescription: String?
    }

    /// The failure carries its own text, since the error line may hold other
    /// operations' errors or drop this one for a device that has left.
    func download(_ item: SoundItem) async -> Result<(name: String, wav: [UInt8]), DownloadFailure> {
        guard enterDevice() else { return .failure(DownloadFailure(errorDescription: Self.busyText)) }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let files else { return .failure(DownloadFailure(errorDescription: "download: no device connected")) }
        let token = hotplug.currentGeneration()
        do {
            progress.update(op, "recv \(item.displayName)")
            // Without the format the WAV header would be a guess, so the read must succeed.
            let meta = try await files.getMetadata(fileID: item.node.id)
            let channels = meta["channels"]?.intValue ?? 1
            let rate = meta["samplerate"]?.intValue ?? deviceSampleRate
            let result = try await files.getWhole(fileID: item.node.id) { done, total in
                Task { @MainActor in
                    self.progress.update(op, "recv \(item.displayName) \(done * 100 / max(total, 1))%")
                }
            }
            progress.update(op, nil)
            return .success((item.displayName + ".wav",
                             makeWAV(pcm: result.data, channels: channels, sampleRate: rate)))
        } catch {
            progress.update(op, nil)
            let text = "download: \(error.localizedDescription)"
            reportOperationError(text, token: token)
            return .failure(DownloadFailure(errorDescription: text))
        }
    }

    func downloadManyToFolder(_ ids: [UInt16], folder: URL) async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let library else { return }
        let token = hotplug.currentGeneration()
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let wavs = try await library.downloadMany(ids) { [weak self] done, total in
                Task { @MainActor in self?.progress.update(op, "recv \(done)/\(total)") }
            }
            for wav in wavs {
                try Data(wav.wav).write(to: folder.appendingPathComponent(wav.name))
            }
            progress.update(op, nil)
        } catch {
            progress.update(op, nil)
            reportOperationError("batch download: \(error.localizedDescription)", token: token)
        }
    }

    // MARK: - delete

    func delete(_ item: SoundItem) async {
        await deleteIntoBin([item.node.id], label: "delete")
    }

    func deleteMany(_ ids: Set<UInt16>) async {
        // The reload afterwards prunes deleted slots from the selection.
        await deleteIntoBin(ids, label: "batch delete")
    }

    /// When a delete fails, the sound it stopped on is offered for a delete
    /// without a bin copy: a sound the device cannot read back would
    /// otherwise be impossible to delete from the app.
    private func deleteIntoBin(_ ids: Set<UInt16>, label: String) async {
        guard let library, enterDevice() else { return }
        await invalidateWaveformContent(slots: ids)
        invalidateMetadataIntent(affecting: ids)
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        let ordered = Array(ids)
        let started = StartedIndex()
        let token = hotplug.currentGeneration()
        do {
            try await library.deleteMany(ordered, into: bin) { [weak self] done, total in
                started.set(done)
                Task { @MainActor in self?.progress.update(op, "bin \(done + 1)/\(total)") }
            }
            progress.update(op, nil)
            await reload()
        } catch {
            progress.update(op, nil)
            // A partial failure still changed the device: reload so the list
            // and the selection show what is really there. Its success path
            // clears the line's messages, so the error is set after it.
            let listed = await reload() ? Set(sounds.map(\.id)) : []
            reportOperationError("\(label): \(error.localizedDescription)", token: token)
            let offer = binFallbackCandidates(ids: ordered, lastStarted: started.current,
                                              error: error, listed: listed)
            if let slot = offer.first, hotplug.isCurrent(token) {
                let name = sounds.first(where: { $0.id == slot })?.displayName ?? "sound \(slot)"
                unbinnedDelete = (offer, binFallbackPrompt(slot: slot, name: name,
                                                           reason: error.localizedDescription), token)
            }
        }
    }

    /// `generation` is the device the offer was made for; a later device
    /// gets nothing deleted, since the same slot number names another sound.
    func deleteWithoutBin(_ ids: Set<UInt16>, generation: Int) async {
        guard hotplug.isCurrent(generation) else {
            noteError("the device changed, nothing was deleted")
            return
        }
        guard let library, enterDevice() else { return }
        await invalidateWaveformContent(slots: ids)
        invalidateMetadataIntent(affecting: ids)
        defer { leaveDevice() }
        let op = progress.begin("delete without copy")
        defer { progress.end(op) }
        do {
            try await library.deleteMany(Array(ids))
            await reload()
        } catch {
            await reload()
            reportOperationError("delete: \(error.localizedDescription)", token: generation)
        }
    }

    // MARK: - recycle bin

    func loadBin() {
        do {
            binEntries = try bin.entries()
        } catch {
            noteError("bin: \(error.localizedDescription)")
        }
    }

    func restoreFromBin(_ entry: BinEntry) async {
        guard let library, enterDevice() else { return }
        await invalidateWaveformContent()
        invalidateMetadataIntent()
        defer { leaveDevice() }
        let op = progress.begin("restore \(entry.name)")
        defer { progress.end(op) }
        let token = hotplug.currentGeneration()
        do {
            _ = try await library.restore(entry, from: bin)
            await reload()
        } catch {
            await reload()
            reportOperationError("restore \(entry.name): \(error.localizedDescription)", token: token)
        }
        loadBin()
    }

    func removeFromBin(_ entry: BinEntry) {
        do {
            try bin.remove(entry)
        } catch {
            noteError("bin: \(error.localizedDescription)")
        }
        loadBin()
    }

    // MARK: - backup / restore

    func backupToFolder(_ folder: URL, scope: DeviceLibrary.Scope = .everything) async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let library else { return }
        let token = hotplug.currentGeneration()
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            progress.update(op, "backup...")
            let backup = try await library.backup(deviceSKU: deviceMeta.sku,
                                                  osVersion: deviceMeta.osVersion,
                                                  scope: scope) { [weak self] name in
                Task { @MainActor in self?.progress.update(op, "backup \(name)") }
            }
            let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
                .replacingOccurrences(of: ":", with: "-")
            let label = scope == .sounds ? "sounds" : scope == .projects ? "projects" : "all"
            let target = folder.appendingPathComponent("kokoko-backup-\(label)-\(stamp)")
            try BackupStore.write(backup, to: target)
            progress.update(op, nil)
            // Not tied to the device generation: the incomplete backup is already on disk.
            if let note = backup.report.message {
                reportLocalError("backup: \(note)")
            }
        } catch {
            progress.update(op, nil)
            reportOperationError("backup: \(error.localizedDescription)", token: token)
        }
    }

    /// Reads the backup and asks before anything is written to the device.
    func prepareRestore(from folder: URL) {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        do {
            let backup = try BackupStore.read(from: folder)
            pendingRestore = PendingRestore(backup: backup, summary: RestoreSummary(backup))
        } catch {
            noteError("restore: \(error.localizedDescription)")
        }
    }

    func restore(_ backup: DeviceBackup) async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let library else { return }
        let token = hotplug.currentGeneration()
        do {
            progress.update(op, "restore...")
            await invalidateWaveformContent()
            invalidateMetadataIntent()
            let report = try await library.restore(backup) { [weak self] name in
                Task { @MainActor in self?.progress.update(op, "restore \(name)") }
            }
            progress.update(op, nil)
            await reloadSoundsAndProjects()
            // Not tied to the device generation: these writes are already done.
            if let note = report.message {
                reportLocalError("restore: \(note)")
            }
        } catch {
            progress.update(op, nil)
            await reloadSoundsAndProjects()
            reportOperationError("restore: \(error.localizedDescription)", token: token)
        }
    }

    /// A restore can change both lists. A successful sounds reload clears the
    /// line's messages, so a projects failure is put back after it; after a
    /// failed one it is still on the line.
    private func reloadSoundsAndProjects() async {
        let projectsError = await loadProjects()
        if await reload(), let projectsError { reportLocalError(projectsError, kind: .projects) }
    }

    // MARK: - rename

    private func inlineRenameIsCurrent(_ edit: InlineRename) -> Bool {
        edit.isCurrent(selection: selection, visible: Set(visibleSounds.map(\.id)), tab: view,
                       generation: hotplug.currentGeneration())
    }

    private func inlineSlotIsCurrent(_ edit: InlineSlotEdit) -> Bool {
        edit.isCurrent(selection: selection, visible: Set(visibleSounds.map(\.id)), tab: view,
                       generation: hotplug.currentGeneration())
    }

    private func metadataIsCurrent(_ edit: InlineMetadataEdit) -> Bool {
        edit.isCurrent(selection: selection, visible: Set(visibleSounds.map(\.id)), tab: view,
                       generation: hotplug.currentGeneration())
    }

    private func invalidateMetadataIntent(affecting ids: Set<UInt16>? = nil, listingMayChange: Bool = true) {
        soundStorage.invalidate()
        if listingMayChange { soundsListed = false }
        guard let edit = metadataEditing else { return }
        if let ids, !ids.contains(edit.id) { return }
        metadataEditing = nil
    }

    private func invalidateInlineEditors() {
        if let shown = waveformShown,
           view != .sounds || !visibleSounds.contains(where: { $0.node == shown.item.node }) { waveformShown = nil }
        if let edit = inlineRename, !inlineRenameIsCurrent(edit) { inlineRename = nil }
        if let edit = inlineSlotEdit, !inlineSlotIsCurrent(edit) { inlineSlotEdit = nil }
        if let edit = metadataEditing, !metadataIsCurrent(edit) { metadataEditing = nil }
    }

    func beginInlineRename(_ item: SoundItem) {
        guard metadataEditing == nil else {
            noteError("save or cancel the metadata edit first")
            return
        }
        guard isConnected, !deviceBusy, !modalOpen, statusDetails.isEmpty, view == .sounds,
              visibleSounds.contains(where: { $0.id == item.id }), inlineRename?.submitting != true,
              inlineSlotEdit?.submitting != true else { return }
        waveformShown = nil
        inlineSlotEdit = nil
        selection = [item.id]
        inlineRename = InlineRename(id: item.id, generation: hotplug.currentGeneration(), name: item.displayName)
    }

    func cancelInlineRename() -> Bool {
        guard let edit = inlineRename, edit.canCancel else { return false }
        let restore = inlineRenameIsCurrent(edit)
        inlineRename = nil
        return restore
    }

    func commitInlineRename(session: UUID) async -> Bool {
        guard var edit = inlineRename, edit.session == session, inlineRenameIsCurrent(edit),
              !modalOpen, statusDetails.isEmpty else { return false }
        switch edit.prepare() {
        case .invalid, .waiting:
            inlineRename = edit
            return false
        case .unchanged:
            inlineRename = nil
            return true
        case .write(let name):
            inlineRename = edit
            let result = await rename(id: edit.id, to: name, generation: edit.generation)
            guard var current = inlineRename, current.session == edit.session,
                  inlineRenameIsCurrent(current) else { return false }
            switch result {
            case .saved:
                _ = current.finish(error: nil)
                inlineRename = nil
                return true
            case .failed(let error):
                _ = current.finish(error: error)
                inlineRename = current
            case .stale:
                inlineRename = nil
            }
            return false
        }
    }

    enum RenameResult { case saved, failed(String), stale }

    /// Display name lives in metadata; the wire filename stays NNN.pcm.
    private func rename(id: UInt16, to name: String, generation: Int) async -> RenameResult {
        guard hotplug.isCurrent(generation), sounds.contains(where: { $0.id == id }) else { return .stale }
        guard let files, enterDevice() else { return .failed("device unavailable or busy") }
        defer { leaveDevice() }
        do {
            invalidateMetadataIntent(affecting: [id])
            try await files.setMetadata(fileID: id, ["name": .string(name)])
            guard hotplug.isCurrent(generation) else { return .stale }
            let reloaded = await reload()
            guard hotplug.isCurrent(generation) else { return .stale }
            return reloaded ? .saved : .failed("name saved, but the sound list could not be refreshed")
        } catch {
            reportOperationError("rename: \(error.localizedDescription)", token: generation)
            return hotplug.isCurrent(generation) ? .failed(error.localizedDescription) : .stale
        }
    }

    // MARK: - metadata

    func editMetadata(_ item: SoundItem) async -> UUID? {
        if let edit = metadataEditing {
            if edit.id == item.id, metadataIsCurrent(edit) { return edit.session }
            noteError("save or cancel the metadata edit first")
            return nil
        }
        guard inlineRename == nil, inlineSlotEdit == nil else {
            noteError("finish the current inline edit first")
            return nil
        }
        guard soundsListed else {
            noteError("refresh the sound list before editing metadata")
            return nil
        }
        guard isConnected, !deviceBusy, !modalOpen, statusDetails.isEmpty, view == .sounds,
              visibleSounds.contains(where: { $0.id == item.id }), let files, enterDevice() else { return nil }
        defer { leaveDevice() }
        waveformShown = nil
        selection = [item.id]
        let edit = InlineMetadataEdit(id: item.id, name: item.displayName, generation: hotplug.currentGeneration())
        metadataEditing = edit
        await readMetadata(edit, files: files)
        return metadataEditing?.session == edit.session ? edit.session : nil
    }

    private func readMetadata(_ edit: InlineMetadataEdit, files: DeviceFileService) async {
        guard let request = edit.request else { return }
        let op = progress.begin("read metadata")
        defer { progress.end(op) }
        do {
            let metadata = try await files.getMetadata(fileID: edit.id)
            guard hotplug.isCurrent(edit.generation), var current = metadataEditing,
                  current.session == edit.session, metadataIsCurrent(current),
                  current.loaded(request: request, metadata: metadata, error: nil) else { return }
            metadataEditing = current
        } catch {
            guard hotplug.isCurrent(edit.generation), var current = metadataEditing,
                  current.session == edit.session, metadataIsCurrent(current),
                  current.loaded(request: request, metadata: nil, error: error.localizedDescription) else { return }
            metadataEditing = current
            reportOperationError("metadata: \(error.localizedDescription)", token: edit.generation)
        }
    }

    func retryMetadata(session: UUID) async {
        guard var edit = metadataEditing, edit.session == session, metadataIsCurrent(edit),
              !modalOpen, statusDetails.isEmpty, edit.beginLoad() != nil, let files, enterDevice() else { return }
        metadataEditing = edit
        defer { leaveDevice() }
        await readMetadata(edit, files: files)
    }

    func cancelMetadata(session: UUID) -> Bool {
        guard let edit = metadataEditing, edit.session == session, edit.canCancel else { return false }
        let restore = metadataIsCurrent(edit)
        metadataEditing = nil
        return restore
    }

    func saveMetadata(session: UUID) async -> Bool {
        guard var edit = metadataEditing, edit.session == session, metadataIsCurrent(edit),
              !modalOpen, statusDetails.isEmpty else { return false }
        switch edit.prepareSave() {
        case .invalid, .waiting:
            return false
        case .unchanged:
            metadataEditing = nil
            return true
        case .write(let request, let form, let refreshBeforeWrite):
            metadataEditing = edit
            guard let files, enterDevice() else {
                _ = edit.finished(request: request, result: .failed(form: form, message: "device unavailable or busy",
                                                                   needsReadback: refreshBeforeWrite))
                metadataEditing = edit
                return false
            }
            defer { leaveDevice() }
            let op = progress.begin("save metadata")
            defer { progress.end(op) }
            soundStorage.invalidate()
            let result = await saveMetadataDraft(files: files, fileID: edit.id, form: form,
                                                 refreshBeforeWrite: refreshBeforeWrite,
                                                 isCurrent: { await MainActor.run {
                guard let current = self.metadataEditing, current.session == session, current.request == request,
                      current.phase == .saving else { return false }
                return self.metadataIsCurrent(current) && !self.modalOpen && self.statusDetails.isEmpty
            } })
            guard hotplug.isCurrent(edit.generation) else { return false }
            if case .failed(_, let message, _) = result { reportOperationError("metadata: \(message)", token: edit.generation) }
            guard var current = metadataEditing, current.session == session, metadataIsCurrent(current),
                  current.finished(request: request, result: result) else { return false }
            if case .saved = result {
                metadataEditing = nil
                return true
            }
            metadataEditing = current
            return false
        }
    }

    // MARK: - renumber

    func beginInlineSlot(_ item: SoundItem) {
        guard metadataEditing == nil else {
            noteError("save or cancel the metadata edit first")
            return
        }
        guard soundsListed, inlineSlotEdit?.needsRefresh != true else {
            noteError("refresh the sound list before starting another slot edit")
            return
        }
        guard isConnected, !deviceBusy, !modalOpen, statusDetails.isEmpty, view == .sounds,
              visibleSounds.contains(where: { $0.id == item.id }), inlineRename?.submitting != true,
              inlineSlotEdit?.submitting != true else { return }
        waveformShown = nil
        inlineRename = nil
        selection = [item.id]
        inlineSlotEdit = InlineSlotEdit(id: item.id, generation: hotplug.currentGeneration())
    }

    func cancelInlineSlot() -> Bool {
        guard let edit = inlineSlotEdit, edit.canCancel else { return false }
        let restore = inlineSlotIsCurrent(edit)
        inlineSlotEdit = nil
        return restore
    }

    func commitInlineSlot(session: UUID) async -> Bool {
        guard var edit = inlineSlotEdit, edit.session == session, inlineSlotIsCurrent(edit),
              !modalOpen, statusDetails.isEmpty else { return false }
        switch edit.prepare() {
        case .invalid, .waiting:
            inlineSlotEdit = edit
            return false
        case .unchanged:
            inlineSlotEdit = nil
            return true
        case .write(let from, let to):
            inlineSlotEdit = edit
            guard let files, let root = soundsRootID, enterDevice() else {
                _ = edit.finish(at: from, error: "device unavailable or busy", listed: nil)
                inlineSlotEdit = edit
                return false
            }
            defer { leaveDevice() }
            let generation = edit.generation
            await invalidateWaveformContent(slots: [from, to])
            invalidateMetadataIntent(affecting: [from, to], listingMayChange: false)
            let result = await moveToFreeSlot(files: files, root: root, from: from, to: to,
                                              isCurrent: { await MainActor.run { self.hotplug.isCurrent(generation) } })
            guard hotplug.isCurrent(generation) else { return false }
            let at: UInt16?
            var message: String?
            switch result {
            case .moved:
                soundsListed = false
                at = to
            case .unchanged: at = from
            case .refused(let reason):
                if var current = inlineSlotEdit, current.session == session {
                    _ = current.finish(at: from, error: reason, listed: Set(sounds.map(\.id)))
                    inlineSlotEdit = inlineSlotIsCurrent(current) ? current : nil
                }
                reportOperationError("move to slot: \(reason)", token: generation)
                return false
            case .failed(let reason, let location):
                soundsListed = false
                at = location
                message = reason
            case .missing:
                if inlineSlotEdit?.session == session { inlineSlotEdit = nil }
                soundsListed = false
                await reload()
                reportOperationError("move to slot: sound is no longer available", token: generation)
                return false
            case .stale:
                return false
            }
            if at == to { selection = remapSelection(selection, moves: [(from: from, to: to)]) }
            if inlineSlotEdit?.session == session { inlineSlotEdit?.recordLocation(at: at) }
            let refreshed = await reload()
            guard hotplug.isCurrent(generation) else { return false }
            if !refreshed { soundsListed = false }
            guard var current = inlineSlotEdit, current.session == session else {
                if let message { reportOperationError("move to slot: \(message)", token: generation) }
                return false
            }
            if message == nil, !refreshed { message = "move was confirmed, but the sound list could not be refreshed" }
            if refreshed, let slot = current.slot, !sounds.contains(where: { $0.id == slot }) {
                current.recordLocation(at: nil)
                message = "sound placement could not be confirmed in the refreshed list"
            }
            if let reason = message {
                if let slot = current.slot { message = "\(reason); sound is in slot \(slot)" }
                reportOperationError("move to slot: \(message ?? reason)", token: generation)
            }
            let saved = current.finish(at: current.slot, error: message,
                                       listed: refreshed ? Set(sounds.map(\.id)) : nil)
            guard inlineSlotIsCurrent(current) else {
                inlineSlotEdit = nil
                return false
            }
            inlineSlotEdit = saved ? nil : current
            return saved
        }
    }

    func refreshInlineSlot(session: UUID) async {
        guard var edit = inlineSlotEdit, edit.session == session, inlineSlotIsCurrent(edit),
              edit.beginRefresh(), enterDevice() else { return }
        inlineSlotEdit = edit
        defer { leaveDevice() }
        let refreshed = await reload()
        guard hotplug.isCurrent(edit.generation), var current = inlineSlotEdit, current.session == session else { return }
        var message = refreshed ? edit.error : "sound list could not be refreshed"
        if refreshed, let slot = current.slot, !sounds.contains(where: { $0.id == slot }) {
            current.recordLocation(at: nil)
            message = "sound placement could not be confirmed in the refreshed list"
        }
        _ = current.finish(at: current.slot, error: message,
                           listed: refreshed ? Set(sounds.map(\.id)) : nil)
        inlineSlotEdit = inlineSlotIsCurrent(current) ? current : nil
        if current.slot == nil, let message { reportOperationError("move to slot: \(message)", token: edit.generation) }
    }

    /// Bulk move: selected sounds land on consecutive slots starting at
    /// `start`, in slot order; see planBulkMove. The selection stays on the
    /// moved sounds.
    func moveSelection(startingAt start: UInt16) async {
        guard enterDevice() else { return }
        inlineSlotEdit = nil
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let files, let root = soundsRootID, !selection.isEmpty else { return }
        let token = hotplug.currentGeneration()
        do {
            let nodes = try await files.list(nodeID: root)
            guard let plan = planBulkMove(selected: Array(selection),
                                          occupied: Set(nodes.map(\.id)), start: start) else {
                reportOperationError("bulk move: not enough free slots from \(start)", token: token)
                return
            }
            try await runMoves(plan, files: files, root: root, op: op)
            progress.update(op, nil)
            await reload()
        } catch {
            progress.update(op, nil)
            await reloadAfterFailedMove("bulk move: \(error.localizedDescription)", token: token)
        }
    }

    /// A row is listed only for an occupied slot, so a drop onto one asks before swapping.
    func requestSwap(id: UInt16, onto target: SoundItem) {
        guard id != target.id else { return }
        let name = sounds.first { $0.id == id }?.displayName ?? "sound"
        pendingSwap = PendingSwap(id: id, target: target.id,
                                  summary: SwapSummary(dragged: (id, name), target: (target.id, target.displayName)))
    }

    /// Drag reorder: move to the target slot; swap with the occupant if taken.
    func moveOrSwap(id: UInt16, toSlot target: UInt16) async {
        guard enterDevice() else { return }
        inlineSlotEdit = nil
        defer { leaveDevice() }
        guard let files, let root = soundsRootID, id != target else { return }
        let token = hotplug.currentGeneration()
        do {
            let nodes = try await files.list(nodeID: root)
            if nodes.contains(where: { $0.id == target }) {
                try await runMoves(planSwap(id, target, occupied: Set(nodes.map(\.id))),
                                   files: files, root: root)
            } else {
                try await moveOne(files, id, to: target, root: root)
            }
            await reload()
        } catch {
            await reloadAfterFailedMove("move: \(error.localizedDescription)", token: token)
        }
    }

    /// A move whose reply failed may still have happened on the device, so the
    /// list is read again. A successful reload clears the line's messages, so the move's
    /// error goes after it, next to any error of the reload itself.
    private func reloadAfterFailedMove(_ text: String, token: Int) async {
        await reload()
        reportOperationError(text, token: token)
    }

    // MARK: - projects

    /// The error it reported, if any.
    @discardableResult
    func loadProjects() async -> String? {
        guard let files else { return nil }
        let token = hotplug.currentGeneration()
        do {
            let root = try await resolve("/projects")
            let nodes = try await files.list(nodeID: root)
            guard hotplug.isCurrent(token) else { return nil }
            projects = nodes.map { ProjectItem(id: $0.id, name: $0.name, size: $0.size) }
            errorLine.withdraw(.projects)
            return nil
        } catch {
            let text = "projects: \(error.localizedDescription)"
            reportOperationError(text, kind: .projects, token: token)
            return hotplug.isCurrent(token) ? text : nil
        }
    }

    /// Download a project as its .tar archive (same shape the original tool uses).
    func downloadProject(_ project: ProjectItem) async -> (name: String, tar: [UInt8])? {
        guard enterDevice() else { return nil }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let files else { return nil }
        let token = hotplug.currentGeneration()
        do {
            progress.update(op, "recv P\(project.name)")
            let tar = try await files.getWhole(fileID: project.id).data
            progress.update(op, nil)
            guard isValidProjectArchive(tar) else {
                reportOperationError("project download: P\(project.name) is not a valid tar archive", token: token)
                return nil
            }
            return ("P\(project.name).tar", tar)
        } catch {
            progress.update(op, nil)
            reportOperationError("project download: \(error.localizedDescription)", token: token)
            return nil
        }
    }

    /// Upload .tar project archives; each name carries the target slot (P01..P09).
    func uploadProjects(urls: [URL]) async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
        guard let files else { return }
        let token = hotplug.currentGeneration()
        var failures: [String] = []
        for url in urls {
            do {
                try await sendProject(url: url, files: files, op: op)
            } catch {
                failures.append("\(url.lastPathComponent): \(readFailureText(error))")
            }
            progress.update(op, nil)
        }
        // After the reload, so a failed reload's error comes first.
        await loadProjects()
        if let text = batchFailureText("project upload", failures: failures, total: urls.count) {
            reportOperationError(text, token: token)
        }
    }

    private struct ProjectUploadError: LocalizedError {
        let errorDescription: String?
    }

    private func sendProject(url: URL, files: DeviceFileService,
                             op: ProgressLine.Operation) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let slot = projectSlot(droppedArchiveName: url.lastPathComponent) else {
            throw ProjectUploadError(errorDescription: "project archive must be named like P01.tar")
        }
        let data = Array(try Data(contentsOf: url))
        guard isValidProjectArchive(data) else {
            throw ProjectUploadError(errorDescription: "\(url.lastPathComponent) is not a valid project archive")
        }
        let projectsRoot = try await resolve("/projects")
        guard let parent = try await files.list(nodeID: projectsRoot)
            .first(where: { $0.name == slot }) else {
            throw ProjectUploadError(errorDescription: "no project slot P\(slot) on device")
        }
        progress.update(op, "send P\(slot)")
        invalidateMetadataIntent()
        _ = try await files.put(parentID: projectsRoot, name: slot, data: data,
                                fileID: parent.id, capabilities: [FileCapability.read],
                                progress: { [weak self] done, total in
                                    Task { @MainActor in
                                        self?.progress.update(op, "send P\(slot) \(done * 100 / max(total, 1))%")
                                    }
                                },
                                timeout: .seconds(60))
    }

    // MARK: - settings

    func loadSettings() async {
        guard enterDevice() else { return }
        defer { leaveDevice() }
        await fetchSettings()
    }

    /// The caller holds the device.
    private func fetchSettings() async {
        let op = progress.begin()
        defer { progress.end(op) }
        guard let settings else { return }
        let token = hotplug.currentGeneration()
        settingsStatus = .notLoaded
        do {
            progress.update(op, "settings...")
            try await settings.initialize()
            let all = try await settings.getAll()
            if hotplug.isCurrent(token) {
                settingsTree = Self.parseSettingsTree(all)
                settingsStatus = .loaded
                errorLine.withdraw(.settings)
            }
            progress.update(op, nil)
        } catch SessionError.deviceError(.commandNotFound, _) {
            progress.update(op, nil)
            if hotplug.isCurrent(token) {
                settingsStatus = .unsupported
                errorLine.withdraw(.settings)
            }
        } catch {
            progress.update(op, nil)
            if hotplug.isCurrent(token) { settingsStatus = .failed }
            reportOperationError("settings: \(error.localizedDescription)", kind: .settings, token: token)
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
                // "value": null means unset; fall back to "current".
                let value = [dict["value"], dict["current"]].compactMap { $0 }.first { $0 != .null } ?? .null
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
    func checkFirmware(baseSKU: String, current: String, token: Int) async {
        struct Release: Decodable { let sku: String; let version: String }
        struct Registry: Decodable { let devices: [Release] }
        do {
            let url = URL(string: "https://teenage.engineering/_software/releases.json")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let registry = try JSONDecoder().decode(Registry.self, from: data)
            guard let latest = registry.devices.first(where: { $0.sku == baseSKU }) else { return }
            guard hotplug.isCurrent(token) else { return }
            firmwareStatus = KokokoLibrary.firmwareStatus(device: current, published: latest.version)
        } catch {
            if hotplug.isCurrent(token) { firmwareStatus = nil }
        }
    }

    // MARK: - misc

    private func invalidateWaveformContent(slots: Set<UInt16>? = nil) async {
        waveformIntent.invalidate()
        waveformLease?.cancel()
        waveformRows.invalidate(slots: slots)
        if let shown = waveformShown, slots == nil || slots!.contains(shown.id) { waveformShown = nil }
        if let session = waveformCacheSession { await waveformCache.invalidate(slots: slots, session: session) }
    }

    func prepareWaveformRow(_ item: SoundItem, epoch: UUID) {
        guard epoch == waveformRows.epoch, isConnected, soundsListed, view == .sounds, let session = waveformCacheSession,
              sounds.contains(where: { $0.node == item.node }) else { return }
        waveformLookups.removeAll { !waveformRows.isCurrent($0.request) || !hotplug.isCurrent($0.generation) }
        guard waveformLookups.count < 64,
              let request = waveformRows.beginLookup(slot: item.id, size: Int(item.node.size)) else { return }
        waveformLookups.append(WaveformLookup(item: item, generation: hotplug.currentGeneration(),
                                              session: session, request: request))
        guard waveformLookupTask == nil else { return }
        waveformLookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !waveformLookups.isEmpty {
                let lookup = waveformLookups.removeFirst()
                guard waveformLookupIsCurrent(lookup) else {
                    waveformRows.cancelLookup(lookup.request)
                    continue
                }
                let record = await waveformCache.load(session: lookup.session, slot: lookup.item.id,
                                                       size: Int(lookup.item.node.size))
                guard waveformLookupIsCurrent(lookup) else {
                    waveformRows.cancelLookup(lookup.request)
                    continue
                }
                waveformRows.finishLookup(lookup.request, record: record)
            }
            waveformLookupTask = nil
        }
    }

    func releaseWaveformRow(_ item: SoundItem, epoch: UUID) {
        guard epoch == waveformRows.epoch else { return }
        waveformRows.forget(slot: item.id, size: Int(item.node.size), epoch: epoch)
        waveformLookups.removeAll { $0.item.node == item.node }
        if waveformShown?.item.node == item.node { waveformShown = nil }
    }

    private func waveformLookupIsCurrent(_ lookup: WaveformLookup) -> Bool {
        hotplug.isCurrent(lookup.generation) && waveformCacheSession == lookup.session
            && waveformRows.isCurrent(lookup.request) && soundsListed && view == .sounds
            && visibleSounds.contains(where: { $0.node == lookup.item.node })
    }

    private func waveformIsCurrent(_ request: WaveformIntent.Request, lease: WaveformCacheLease) -> Bool {
        lease.isCurrent && waveformIntent.isCurrent(request, generation: hotplug.currentGeneration())
    }

    func showWaveform(_ item: SoundItem, forceRefresh: Bool = false) async {
        guard inlineRename == nil, inlineSlotEdit == nil, metadataEditing == nil else {
            noteError("finish the inline edit before opening a waveform")
            return
        }
        guard isConnected, view == .sounds, !modalOpen, statusDetails.isEmpty, soundsListed,
              visibleSounds.contains(where: { $0.node == item.node }), enterDevice() else { return }
        defer { leaveDevice() }
        guard let files, let cacheSession = waveformCacheSession else { return }
        let token = hotplug.currentGeneration()
        waveformLease?.cancel()
        let lease = WaveformCacheLease()
        waveformLease = lease
        let request = waveformIntent.begin(slot: item.id, generation: token)
        let op = progress.begin()
        defer { progress.end(op) }
        let local = forceRefresh ? nil : waveformRows.snapshot(slot: item.id, size: Int(item.node.size))?.record
        waveformShown = WaveformShown(item: item, record: local, loopStart: nil, loopEnd: nil,
                                      cached: local != nil, metadataConfirmed: false)
        if forceRefresh {
            waveformRows.invalidate(slots: [item.id])
            await waveformCache.invalidate(slots: [item.id], session: cacheSession)
        }
        guard waveformIsCurrent(request, lease: lease), let cacheToken = await waveformCache.token(session: cacheSession),
              waveformIsCurrent(request, lease: lease) else { return }
        var cached = forceRefresh ? nil : await waveformCache.load(session: cacheSession, slot: item.id, size: Int(item.node.size))
        guard waveformIsCurrent(request, lease: lease) else { return }
        waveformRows.reconcileCache(slot: item.id, size: Int(item.node.size), record: cached)
        waveformShown = WaveformShown(item: item, record: cached, loopStart: nil, loopEnd: nil,
                                      cached: cached != nil, metadataConfirmed: false)
        do {
            let meta = try await files.getMetadata(fileID: item.id)
            guard waveformIsCurrent(request, lease: lease) else { return }
            let channels = meta["channels"]?.intValue ?? cached?.channels ?? 1
            let sampleRate = meta["samplerate"]?.intValue ?? cached?.sampleRate ?? deviceSampleRate
            if cached != nil {
                cached = await waveformCache.load(session: cacheSession, slot: item.id, size: Int(item.node.size),
                                                  channels: channels, sampleRate: sampleRate)
                guard waveformIsCurrent(request, lease: lease) else { return }
                waveformRows.reconcileCache(slot: item.id, size: Int(item.node.size), record: cached)
                if cached == nil {
                    waveformShown = WaveformShown(item: item, record: nil, loopStart: nil, loopEnd: nil,
                                                  cached: false, metadataConfirmed: true)
                }
            }
            guard (1...2).contains(channels), (1...65535).contains(sampleRate) else {
                throw DownloadFailure(errorDescription: "unsupported audio format")
            }
            let record: WaveformPeakRecord
            if let cached {
                record = cached
            } else {
                progress.update(op, "recv \(item.displayName)")
                let pcm = try await files.getWhole(fileID: item.id) { done, total in
                    Task { @MainActor in
                        self.progress.update(op, "recv \(item.displayName) \(done * 100 / max(total, 1))%")
                    }
                }.data
                guard waveformIsCurrent(request, lease: lease) else { return }
                let computed = await Task.detached(priority: .userInitiated) {
                    WaveformPeakRecord(pcm: pcm, channels: channels, sampleRate: sampleRate)
                }.value
                guard waveformIsCurrent(request, lease: lease) else { return }
                guard let computed else { throw DownloadFailure(errorDescription: "unsupported or incomplete audio format") }
                record = computed
                guard await waveformCache.store(record, slot: item.id, token: cacheToken, lease: lease),
                      waveformIsCurrent(request, lease: lease) else { return }
            }
            guard waveformIsCurrent(request, lease: lease) else { return }
            waveformRows.remember(slot: item.id, size: Int(item.node.size), record: record, cached: cached != nil)
            let confirmed = SoundItem(node: item.node, displayName: meta["name"]?.stringValue ?? item.displayName)
            waveformShown = WaveformShown(item: confirmed, record: record,
                                          loopStart: meta["sound.loopstart"]?.intValue,
                                          loopEnd: meta["sound.loopend"]?.intValue,
                                          cached: cached != nil, metadataConfirmed: true)
            progress.update(op, nil)
        } catch {
            guard waveformIsCurrent(request, lease: lease) else { return }
            progress.update(op, nil)
            if waveformShown?.record == nil { waveformShown = nil }
            reportOperationError("waveform: \(error.localizedDescription)", token: token)
        }
    }

    func requestAudition(_ item: SoundItem, selected: Set<UInt16>? = nil) {
        guard isConnected, let files, sounds.contains(where: { $0.id == item.id }),
              let ownership = deviceAdmission.beginPreview() else { return }
        let generation = hotplug.currentGeneration()
        errorLine.start()
        Task { @MainActor in
            defer {
                if self.deviceAdmission.endPreview(ownership) { self.deviceReleased() }
            }
            guard self.hotplug.isCurrent(generation), self.sounds.contains(where: { $0.id == item.id }) else { return }
            if let selected {
                guard self.selection == selected, self.visibleSounds.contains(where: { $0.id == item.id }),
                      AppCommand.auditionSelected.isEnabled(tab: self.view, connected: self.isConnected,
                          busy: self.deviceBusy, selection: selected.count,
                          modalOpen: self.modalOpen || self.inlineRename != nil || !self.statusDetails.isEmpty) else { return }
            }
            do {
                try await files.startPlayback(fileID: item.node.id, offset: 0, length: 1000)
            } catch {
                self.reportOperationError("preview: \(error.localizedDescription)", token: generation)
            }
        }
    }

    func dragProvider(for item: SoundItem, token: RowDragToken) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.wav.identifier,
                                            visibility: .all) { completion in
            RowDragDiagnostics.event("provider wav-request")
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                RowDragDiagnostics.event("provider wav-entered-main")
                self.rowDrag.end(token)
                switch await self.download(item) {
                case .success(let result):
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(result.name)
                    do {
                        try Data(result.wav).write(to: temp)
                        progress.completedUnitCount = 1
                        RowDragDiagnostics.event("provider wav-complete success=true")
                        completion(temp, true, nil)
                    } catch {
                        RowDragDiagnostics.error("provider wav-write", error)
                        completion(nil, false, error)
                    }
                case .failure(let failure):
                    RowDragDiagnostics.error("provider wav-download", failure)
                    completion(nil, false, failure)
                }
            }
            return progress
        }
        provider.suggestedName = item.displayName + ".wav"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.soundRowMove.identifier,
                                            visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: rowMoveTextType.identifier,
                                            visibility: .all) { completion in
            RowDragDiagnostics.event("provider text-request")
            completion(Data(token.payload.utf8), nil)
            return nil
        }
        return provider
    }
}

/// The index a batch call reported last, written from the library's actor
/// and read back on the main actor once the call threw.
private final class StartedIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    func set(_ index: Int) { lock.withLock { value = index } }

    var current: Int? { lock.withLock { value } }
}
