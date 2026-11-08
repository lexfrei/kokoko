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
    let metadataConfirmed: Bool
    var loading = false
    var id: UInt16 { item.id }
    var description: String { record != nil ? "Waveform" : loading ? "loading waveform…" : "waveform unavailable" }
}

struct PendingSwap {
    let session = UUID()
    let generation: UUID
    let connection: ConnectionState
    let files: DeviceFileService?
    let source: SoundItem
    let destination: SoundItem
    var submitting = false
    var id: UInt16 { source.id }
    var target: UInt16 { destination.id }
    var summary: SwapSummary {
        SwapSummary(dragged: (id, source.displayName), target: (target, destination.displayName))
    }
}

enum FileProcessing: Equatable, Sendable {
    case processed, notStarted
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
        didSet {
            if showImporter { panel.open(.none, generation: hotplug.currentGeneration()) }
            scheduleAutomaticViewportUpdate()
        }
    }
    @Published var exportDocument: DataDocument? { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var exportName = "sound.wav"
    @Published var picker: PendingPicker = .none {
        didSet {
            if picker != .none { panel.open(picker, generation: hotplug.currentGeneration()) }
            scheduleAutomaticViewportUpdate()
        }
    }
    /// What the open panel was shown for. A device leaving resets `picker`;
    /// if that lands between the user's choice and the panel's callback,
    /// reading `picker` there sends the chosen folder to upload, and the
    /// panel's own settings would switch to upload's while it closes.
    @Published private(set) var panel = PanelRequest()
    @Published var inlineSlotEdit: InlineSlotEdit? { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var inlineRename: InlineRename? { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var statusDetails = Set<UUID>() { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var metadataEditing: InlineMetadataEdit? { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var firmwareStatus: FirmwareStatus?
    @Published var settingsTree: [SettingsGroupModel] = []
    @Published var settingsHelp: [String: String] = [:]
    @Published var settingsStatus: SettingsStatus = .notLoaded
    @Published var view: HeaderTab = .sounds {
        didSet { invalidateInlineEditors(); scheduleAutomaticViewportUpdate() }
    }
    @Published var projects: [ProjectItem] = []
    @Published var binEntries: [BinEntry] = []
    @Published var binToRemove: BinEntry? { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var pendingRestore: PendingRestore? { didSet { scheduleAutomaticViewportUpdate() } }
    @Published var pendingSwap: PendingSwap? { didSet { scheduleAutomaticViewportUpdate() } }
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
    private var waveformContentEpoch = UUID() {
        didSet { resetAutomaticWaveforms() }
    }
    static let waveformMaximumBytes = 16 * 1024 * 1024
    private var waveformLease: WaveformCacheLease?
    private struct ConfirmedWaveformMetadata: Equatable {
        let node: FSNode
        let descriptor: WaveformDescriptor
        let loopStart: Int?
        let loopEnd: Int?
        let loopMetadataAvailable: Bool

        init?(item: SoundItem, values: [String: JSONValue]) {
            guard let descriptor = WaveformDescriptor(size: Int(item.node.size), metadata: values) else { return nil }
            node = item.node
            self.descriptor = descriptor
            loopStart = values["sound.loopstart"]?.intValue
            loopEnd = values["sound.loopend"]?.intValue
            loopMetadataAvailable = ["sound.loopstart", "sound.loopend"].allSatisfy { key in
                guard let value = values[key], value != .null else { return true }
                return value.intValue != nil
            }
        }
    }
    private var waveformMetadata: [UInt16: ConfirmedWaveformMetadata] = [:]
    private struct WaveformLookup {
        let item: SoundItem
        let generation: Int
        let session: UUID
        let request: WaveformRows.Request
        let metadata: ConfirmedWaveformMetadata
    }
    private var waveformLookups: [WaveformLookup] = []
    private var waveformLookupTask: Task<Void, Never>?
    #if os(macOS)
    private struct AutomaticViewport {
        let context: SoundViewportContext
        let owner: UUID
        weak var view: ViewportView?
        var sample: SoundViewportSample
    }
    private struct AutomaticWaveformJob: Equatable {
        let context: SoundViewportContext
        let owner: UUID
    }
    private var automaticViewports: [UInt16: AutomaticViewport] = [:]
    private var automaticWaveformQueue: [AutomaticWaveformJob] = []
    private var automaticWaveformTask: Task<Void, Never>?
    private var automaticViewportTask: Task<Void, Never>?
    private var automaticViewportDirty = false
    private var automaticWaveformActive: (job: AutomaticWaveformJob, lease: WaveformCacheLease)?
    @Published private var automaticWaveformFailures: [UInt16: SoundViewportContext] = [:]
    private var automaticViewportPins = Set<UInt16>()
    #if DEBUG
    var allowAutomaticPolicyFactsForCheck = false
    var automaticReductionForCheck: (@Sendable () async -> Void)?
    private(set) var automaticPCMBufferCountForCheck = 0
    private(set) var automaticMaximumPCMBufferCountForCheck = 0
    var automaticWaveformInFlightForCheck: Bool { automaticWaveformTask != nil || automaticViewportTask != nil }
    var automaticWaveformPendingCountForCheck: Int { automaticWaveformQueue.count }
    var automaticViewportPinCountForCheck: Int { automaticViewportPins.count }
    var automaticWaveformFailureCountForCheck: Int { automaticWaveformFailures.count }
    #endif
    #endif
    #if DEBUG
    private(set) var waveformDiskLoadsForCheck = 0
    var waveformDiskLookupInFlightForCheck: Bool { waveformLookupTask != nil }
    #endif
    private var waveformIntent = WaveformIntent()
    @Published private(set) var waveformRows = WaveformRows()
    @Published private var deviceAdmission = DeviceAdmission()
    private var foregroundWaiter: (owner: UUID, continuation: CheckedContinuation<Bool, Never>)?
    var deviceBusy: Bool { deviceAdmission.operation || deviceAdmission.foregroundWaiting }
    private var deviceOccupied: Bool { deviceAdmission.occupied }
    /// The sound a delete into the bin failed on, offered for a delete without a copy.
    @Published var unbinnedDelete: (ids: Set<UInt16>, prompt: String, generation: Int)? {
        didSet { scheduleAutomaticViewportUpdate() }
    }
    @Published var bulkMoveStart = ""

    init(waveformCache: WaveformCacheStore? = nil) {
        self.waveformCache = waveformCache ?? WaveformCacheStore(root: Self.waveformCacheRoot)
    }

    #if DEBUG
    var beginFileScopeForCheck: ((URL) -> Bool)?
    var endFileScopeForCheck: ((URL) -> Void)?

    convenience init(listedSounds: [SoundItem], waveformCache: WaveformCacheStore? = nil,
                     files: DeviceFileService? = nil, cacheSession: UUID? = nil,
                     listingMetadata: [UInt16: [String: JSONValue]] = [:],
                     waveformRecords: [UInt16: WaveformPeakRecord] = [:], soundRootID: UInt16? = nil) {
        self.init(waveformCache: waveformCache)
        self.files = files
        if let files { library = DeviceLibrary(files: files) }
        waveformCacheSession = cacheSession
        soundsRootID = soundRootID
        for item in listedSounds {
            waveformMetadata[item.id] = listingMetadata[item.id].flatMap { ConfirmedWaveformMetadata(item: item, values: $0) }
            if let record = waveformRecords[item.id] {
                waveformRows.remember(slot: item.id, size: Int(item.node.size), record: record)
            }
        }
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
        scheduleAutomaticViewportUpdate()
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
        guard soundMoveSlots.contains(id), soundMoveSlots.contains(target) else { throw SoundMoveError.invalidSlot }
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
        guard steps.allSatisfy({ soundMoveSlots.contains($0.from) && soundMoveSlots.contains($0.to) }) else {
            throw SoundMoveError.invalidSlot
        }
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

    private static let fileNotQueuedText = "device busy: another action is running or waiting; this action was not queued"

    private func enterFileDevice(generation: Int, files: DeviceFileService) async -> Bool {
        guard !Task.isCancelled, hotplug.isCurrent(generation), self.files === files else {
            noteError("file action not started: cancelled or device changed")
            return false
        }
        switch deviceAdmission.requestForeground() {
        case .refused:
            noteError(Self.fileNotQueuedText)
            return false
        case .started:
            errorLine.start()
            return true
        case .waiting(let owner):
            let waiting = progress.begin("waiting for current audio read")
            defer { progress.end(waiting) }
            let admitted: Bool = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        _ = deviceAdmission.cancelForeground(owner)
                        continuation.resume(returning: false)
                    } else {
                        foregroundWaiter = (owner, continuation)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelFileWaiter(owner) }
            }
            guard admitted else { return false }
            guard !Task.isCancelled, hotplug.isCurrent(generation), self.files === files else {
                leaveDevice()
                noteError("file action not started: cancelled or device changed")
                return false
            }
            errorLine.start()
            return true
        }
    }

    private func cancelFileWaiter(_ owner: UUID) {
        guard deviceAdmission.cancelForeground(owner), let waiting = foregroundWaiter, waiting.owner == owner else { return }
        foregroundWaiter = nil
        waiting.continuation.resume(returning: false)
        noteError("file action cancelled before starting")
    }

    func beginWaveformRead() -> UUID? { deviceAdmission.beginBackground() }

    func endWaveformRead(_ owner: UUID) {
        switch deviceAdmission.endBackground(owner) {
        case .stale: break
        case .idle: deviceAvailable()
        case .foreground(let token):
            if let waiting = foregroundWaiter, waiting.owner == token {
                foregroundWaiter = nil
                waiting.continuation.resume(returning: true)
            } else {
                _ = deviceAdmission.endOperation()
                deviceAvailable()
            }
        }
    }

    private func beginFileScope(_ url: URL) -> Bool {
        #if DEBUG
        if let beginFileScopeForCheck { return beginFileScopeForCheck(url) }
        #endif
        return url.startAccessingSecurityScopedResource()
    }

    private func endFileScope(_ url: URL) {
        #if DEBUG
        if let endFileScopeForCheck { endFileScopeForCheck(url); return }
        #endif
        url.stopAccessingSecurityScopedResource()
    }

    private func leaveDevice() {
        if deviceAdmission.endOperation() { deviceReleased() }
    }

    private func deviceReleased() {
        errorLine.finish()
        deviceAvailable()
    }

    private func deviceAvailable() {
        if let tab = tabLoad.deviceReleased(showing: view, needsLoad: tabNeedsLoad(view)) {
            Task { await loadOpenedTab(tab) }
        }
        rescanIfDue()
        scheduleAutomaticViewportUpdate()
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

    var modalOpen: Bool {
        showImporter || picker != .none || exportDocument != nil
            || unbinnedDelete != nil || binToRemove != nil
            || pendingRestore != nil || pendingSwap != nil
    }

    func isEnabled(_ command: AppCommand) -> Bool {
        command.isEnabled(tab: view, connected: isConnected, busy: deviceAdmission.userOccupied, selection: selection.count,
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

    func forgetDevice() {
        if let owner = foregroundWaiter?.owner { cancelFileWaiter(owner) }
        waveformContentEpoch = UUID()
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
        waveformMetadata.removeAll()
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
        waveformContentEpoch = UUID()
        let listingEpoch = waveformContentEpoch
        waveformShown = nil
        waveformMetadata.removeAll()
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
        var confirmed: [UInt16: ConfirmedWaveformMetadata] = [:]
        for node in nodes where node.isFile {
            let meta = try? await files.getMetadata(fileID: node.id)
            let display = meta?["name"]?.stringValue ?? node.name
            let item = SoundItem(node: node, displayName: display)
            items.append(item)
            confirmed[node.id] = meta.flatMap { ConfirmedWaveformMetadata(item: item, values: $0) }
        }
        guard hotplug.isCurrent(token), waveformContentEpoch == listingEpoch else { return false }
        if var edit = inlineSlotEdit, edit.submitting, edit.generation == token {
            let carried = edit.reconcile(occupied: Set(items.map(\.id)))
            inlineSlotEdit = edit
            selection = remapSelection(selection, moves: carried)
        }
        waveformMetadata = confirmed
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

    @discardableResult
    func upload(urls: [URL]) async -> FileProcessing {
        let scoped = urls.filter { beginFileScope($0) }
        defer { scoped.forEach { endFileScope($0) } }
        let token = hotplug.currentGeneration()
        guard let files else { noteError("upload: no device connected"); return .notStarted }
        guard let root = soundsRootID else { noteError("upload: the sounds folder was not found"); return .notStarted }
        guard await enterFileDevice(generation: token, files: files) else { return .notStarted }
        defer { leaveDevice() }
        guard soundsRootID == root else { noteError("upload: the sounds folder changed; action not started"); return .notStarted }
        let op = progress.begin()
        defer { progress.end(op) }
        var failures: [String] = []
        for url in urls {
            do {
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
        return .processed
    }

    // MARK: - download (single + batch)

    struct DownloadFailure: LocalizedError {
        let errorDescription: String?
    }

    /// The failure carries its own text, since the error line may hold other
    /// operations' errors or drop this one for a device that has left.
    func download(_ item: SoundItem) async -> Result<(name: String, wav: [UInt8]), DownloadFailure> {
        let token = hotplug.currentGeneration()
        guard let files, sounds.contains(where: { $0.node == item.node }) else {
            return .failure(DownloadFailure(errorDescription: "download: no device connected or sound changed"))
        }
        guard await enterFileDevice(generation: token, files: files) else {
            return .failure(DownloadFailure(errorDescription: lastError ?? Self.fileNotQueuedText))
        }
        defer { leaveDevice() }
        guard sounds.contains(where: { $0.node == item.node }) else {
            noteError("download: sound changed; action not started")
            return .failure(DownloadFailure(errorDescription: "download: sound changed; action not started"))
        }
        let op = progress.begin()
        defer { progress.end(op) }
        let observationIsCurrent = waveformObservationGuard(for: item, generation: token)
        do {
            progress.update(op, "recv \(item.displayName)")
            guard let meta = try await observedSoundMetadata(item, files: files, generation: token) else {
                return .failure(DownloadFailure(errorDescription: "download: sound changed or device disconnected"))
            }
            let channels = meta["channels"]?.intValue ?? 1
            let rate = meta["samplerate"]?.intValue ?? deviceSampleRate
            let result = try await files.getWhole(fileID: item.node.id) { done, total in
                Task { @MainActor in
                    self.progress.update(op, "recv \(item.displayName) \(done * 100 / max(total, 1))%")
                }
            }
            guard observationIsCurrent() else {
                return .failure(DownloadFailure(errorDescription: "download: sound changed or device disconnected"))
            }
            progress.update(op, nil)
            return .success((item.displayName + ".wav",
                             makeWAV(pcm: result.data, channels: channels, sampleRate: rate)))
        } catch {
            progress.update(op, nil)
            let text = "download: \(error.localizedDescription)"
            if observationIsCurrent() {
                updateWaveformMetadata(nil, for: item)
                reportOperationError(text, token: token)
            }
            return .failure(DownloadFailure(errorDescription: text))
        }
    }

    func downloadManyToFolder(_ ids: [UInt16], folder: URL) async {
        let accessing = beginFileScope(folder)
        defer { if accessing { endFileScope(folder) } }
        let token = hotplug.currentGeneration()
        let nodes = ids.compactMap { id in sounds.first(where: { $0.id == id })?.node }
        guard let files, nodes.count == ids.count else { noteError("batch download: no device connected or sounds changed"); return }
        guard await enterFileDevice(generation: token, files: files) else { return }
        defer { leaveDevice() }
        guard let library, nodes.allSatisfy({ node in sounds.contains(where: { $0.node == node }) }) else {
            noteError("batch download: sounds changed; action not started")
            return
        }
        let op = progress.begin()
        defer { progress.end(op) }
        do {
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
        let token = hotplug.currentGeneration()
        let root = soundsRootID
        let nodes = sounds.filter { ids.contains($0.id) }.map(\.node)
        guard let files, nodes.count == ids.count else { noteError("delete: no device connected or sounds changed"); return }
        guard await enterFileDevice(generation: token, files: files) else { return }
        defer { leaveDevice() }
        guard let library, soundsRootID == root, nodes.allSatisfy({ node in sounds.contains(where: { $0.node == node }) }) else {
            noteError("delete: sounds or folder changed; action not started")
            return
        }
        await invalidateWaveformContent(slots: ids)
        invalidateMetadataIntent(affecting: ids)
        let op = progress.begin()
        defer { progress.end(op) }
        let ordered = Array(ids)
        let started = StartedIndex()
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
        let root = soundsRootID
        let nodes = sounds.filter { ids.contains($0.id) }.map(\.node)
        guard hotplug.isCurrent(generation), let files, nodes.count == ids.count else {
            noteError("the device or sounds changed, nothing was deleted")
            return
        }
        guard await enterFileDevice(generation: generation, files: files) else { return }
        defer { leaveDevice() }
        guard let library, soundsRootID == root, nodes.allSatisfy({ node in sounds.contains(where: { $0.node == node }) }) else {
            noteError("the sounds or folder changed, nothing was deleted")
            return
        }
        await invalidateWaveformContent(slots: ids)
        invalidateMetadataIntent(affecting: ids)
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
        let token = hotplug.currentGeneration()
        let root = soundsRootID
        guard let files else { noteError("bin restore: no device connected"); return }
        guard await enterFileDevice(generation: token, files: files) else { return }
        defer { leaveDevice() }
        guard let library, soundsRootID == root, binEntries.contains(where: { $0.id == entry.id }) else {
            noteError("bin restore: entry or device folder changed; action not started")
            return
        }
        await invalidateWaveformContent()
        invalidateMetadataIntent()
        let op = progress.begin("restore \(entry.name)")
        defer { progress.end(op) }
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
        let accessing = beginFileScope(folder)
        defer { if accessing { endFileScope(folder) } }
        let token = hotplug.currentGeneration()
        let root = soundsRootID
        guard let files else { noteError("backup: no device connected"); return }
        guard await enterFileDevice(generation: token, files: files) else { return }
        defer { leaveDevice() }
        guard let library, soundsRootID == root else { noteError("backup: device folders changed; action not started"); return }
        let op = progress.begin()
        defer { progress.end(op) }
        do {
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
        let token = hotplug.currentGeneration()
        let root = soundsRootID
        guard let files else { noteError("restore: no device connected"); return }
        guard await enterFileDevice(generation: token, files: files) else { return }
        defer { leaveDevice() }
        guard let library, soundsRootID == root else { noteError("restore: device folders changed; action not started"); return }
        let op = progress.begin()
        defer { progress.end(op) }
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
        waveformContentEpoch = UUID()
        soundStorage.invalidate()
        if listingMayChange { soundsListed = false }
        guard let edit = metadataEditing else { return }
        if let ids, !ids.contains(edit.id) { return }
        metadataEditing = nil
    }

    private func invalidateInlineEditors() {
        if let pending = pendingSwap, !pending.submitting, !swapIsCurrent(pending) { pendingSwap = nil }
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
        guard let request = edit.request, let item = sounds.first(where: { $0.id == edit.id }) else { return }
        let observationIsCurrent = waveformObservationGuard(for: item, generation: edit.generation)
        let op = progress.begin("read metadata")
        defer { progress.end(op) }
        do {
            guard let metadata = try await observedSoundMetadata(item, files: files, generation: edit.generation) else { return }
            guard var current = metadataEditing,
                  current.session == edit.session, metadataIsCurrent(current),
                  current.loaded(request: request, metadata: metadata, error: nil) else { return }
            metadataEditing = current
        } catch {
            guard observationIsCurrent() else { return }
            reportOperationError("metadata: \(error.localizedDescription)", token: edit.generation)
            guard var current = metadataEditing,
                  current.session == edit.session, metadataIsCurrent(current),
                  current.loaded(request: request, metadata: nil, error: error.localizedDescription) else { return }
            metadataEditing = current
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
            waveformContentEpoch = UUID()
            let observedItem = sounds.first(where: { $0.id == edit.id })
            let observationIsCurrent = observedItem.map { waveformObservationGuard(for: $0, generation: edit.generation) }
            if let observedItem { updateWaveformMetadata(nil, for: observedItem) }
            let result = await saveMetadataDraft(files: files, fileID: edit.id, form: form,
                                                 refreshBeforeWrite: refreshBeforeWrite,
                                                 isCurrent: { await MainActor.run {
                guard let current = self.metadataEditing, current.session == session, current.request == request,
                      current.phase == .saving else { return false }
                return self.metadataIsCurrent(current) && !self.modalOpen && self.statusDetails.isEmpty
            } })
            guard hotplug.isCurrent(edit.generation) else { return false }
            if case .failed(_, let message, _) = result { reportOperationError("metadata: \(message)", token: edit.generation) }
            switch result {
            case .saved(let confirmed), .failed(let confirmed, _, false):
                if observationIsCurrent?() == true, let observedItem {
                    updateWaveformMetadata(confirmed.confirmedMetadata, for: observedItem)
                }
            default: break
            }
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

    func moveSelectionFromDraft() async {
        guard !bulkMoveStart.isEmpty, bulkMoveStart.utf8.allSatisfy({ (48...57).contains($0) }),
              let start = UInt16(bulkMoveStart), soundMoveSlots.contains(start) else {
            noteError("bulk move: enter a slot from 1 to 999 using digits only")
            return
        }
        await moveSelection(startingAt: start)
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
        guard soundMoveSlots.contains(start), selection.allSatisfy(soundMoveSlots.contains) else {
            reportOperationError("bulk move: \(SoundMoveError.invalidSlot.localizedDescription)", token: token)
            return
        }
        do {
            let nodes = try await files.list(nodeID: root)
            guard let plan = planBulkMove(selected: Array(selection),
                                          occupied: Set(nodes.map(\.id)), start: start) else {
                reportOperationError("bulk move: selected sounds unavailable or not enough free target and scratch slots from \(start)", token: token)
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

    func requestSwap(id: UInt16, onto target: SoundItem) {
        guard pendingSwap == nil, isConnected, !deviceBusy, !modalOpen, view == .sounds,
              soundMoveSlots.contains(id), soundMoveSlots.contains(target.id), id != target.id,
              let source = visibleSounds.first(where: { $0.id == id }), visibleSounds.contains(target) else { return }
        pendingSwap = PendingSwap(generation: rowDragGeneration, connection: connection, files: files,
                                  source: source, destination: target)
    }

    private func swapIsCurrent(_ pending: PendingSwap) -> Bool {
        isConnected && view == .sounds && pending.generation == rowDragGeneration
            && pending.connection == connection && pending.files === files
            && visibleSounds.contains(pending.source) && visibleSounds.contains(pending.destination)
    }

    var canConfirmSwap: Bool {
        guard let pending = pendingSwap else { return false }
        return !pending.submitting && !deviceBusy && swapIsCurrent(pending)
    }

    @discardableResult
    func cancelSwap(session: UUID) -> Bool {
        guard let pending = pendingSwap, pending.session == session, !pending.submitting else { return false }
        let restore = swapIsCurrent(pending)
        pendingSwap = nil
        return restore
    }

    func confirmSwap(session: UUID) async {
        guard let pending = pendingSwap, pending.session == session, !pending.submitting else { return }
        guard swapIsCurrent(pending) else { pendingSwap = nil; return }
        guard enterDevice() else { return }
        pendingSwap?.submitting = true
        inlineSlotEdit = nil
        defer {
            if pendingSwap?.session == session { pendingSwap = nil }
            leaveDevice()
        }
        guard let files, let root = soundsRootID else { return }
        let token = hotplug.currentGeneration()
        do {
            let nodes = try await files.list(nodeID: root)
            guard self.files === files, rowDragGeneration == pending.generation, hotplug.isCurrent(token),
                  connection == pending.connection else { return }
            guard swapIsCurrent(pending),
                  nodes.contains(pending.source.node), nodes.contains(pending.destination.node) else {
                reportOperationError("swap not started: sounds or device changed; drop again", token: token)
                return
            }
            for item in [pending.source, pending.destination] {
                let meta = try await files.getMetadata(fileID: item.id)
                guard self.files === files, rowDragGeneration == pending.generation, hotplug.isCurrent(token),
                      connection == pending.connection else { return }
                guard swapIsCurrent(pending),
                      (meta["name"]?.stringValue ?? item.node.name) == item.displayName else {
                    reportOperationError("swap not started: sounds or device changed; drop again", token: token)
                    return
                }
            }
            guard let plan = planSwap(pending.id, pending.target, occupied: Set(nodes.map(\.id))) else {
                reportOperationError("swap: no free sound slot for scratch", token: token)
                return
            }
            try await runMoves(plan, files: files, root: root)
            await reload()
        } catch {
            await reloadAfterFailedMove("swap: \(error.localizedDescription)", token: token)
        }
    }

    /// Drag reorder: move to the target slot; swap with the occupant if taken.
    func moveOrSwap(id: UInt16, toSlot target: UInt16) async {
        guard enterDevice() else { return }
        inlineSlotEdit = nil
        defer { leaveDevice() }
        guard let files, let root = soundsRootID else { return }
        let token = hotplug.currentGeneration()
        guard soundMoveSlots.contains(id), soundMoveSlots.contains(target) else {
            reportOperationError("move: \(SoundMoveError.invalidSlot.localizedDescription)", token: token)
            return
        }
        guard id != target else { return }
        do {
            let nodes = try await files.list(nodeID: root)
            guard nodes.contains(where: { $0.id == id }) else {
                await reloadAfterFailedMove("move: sound is no longer available", token: token)
                return
            }
            if nodes.contains(where: { $0.id == target }) {
                guard let plan = planSwap(id, target, occupied: Set(nodes.map(\.id))) else {
                    reportOperationError("swap: no free sound slot for scratch", token: token)
                    return
                }
                try await runMoves(plan, files: files, root: root)
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
        let token = hotplug.currentGeneration()
        guard let files, projects.contains(project) else { noteError("project download: no device connected or project changed"); return nil }
        guard await enterFileDevice(generation: token, files: files) else { return nil }
        defer { leaveDevice() }
        guard projects.contains(project) else { noteError("project download: project changed; action not started"); return nil }
        let op = progress.begin()
        defer { progress.end(op) }
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
    @discardableResult
    func uploadProjects(urls: [URL]) async -> FileProcessing {
        let scoped = urls.filter { beginFileScope($0) }
        defer { scoped.forEach { endFileScope($0) } }
        let token = hotplug.currentGeneration()
        guard let files else { noteError("project upload: no device connected"); return .notStarted }
        guard await enterFileDevice(generation: token, files: files) else { return .notStarted }
        defer { leaveDevice() }
        let op = progress.begin()
        defer { progress.end(op) }
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
        return .processed
    }

    private struct ProjectUploadError: LocalizedError {
        let errorDescription: String?
    }

    private func sendProject(url: URL, files: DeviceFileService,
                             op: ProgressLine.Operation) async throws {
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

    private func waveformObservationGuard(for item: SoundItem, generation: Int) -> @MainActor () -> Bool {
        let epoch = waveformContentEpoch
        let cacheSession = waveformCacheSession
        return {
            self.hotplug.isCurrent(generation) && self.waveformCacheSession == cacheSession
                && self.waveformContentEpoch == epoch && self.sounds.contains(where: { $0.node == item.node })
        }
    }

    private func observedSoundMetadata(_ item: SoundItem, files: DeviceFileService, generation: Int) async throws -> [String: JSONValue]? {
        let observationIsCurrent = waveformObservationGuard(for: item, generation: generation)
        do {
            let values = try await files.getMetadata(fileID: item.id)
            guard observationIsCurrent() else { return nil }
            updateWaveformMetadata(values, for: item)
            return values
        } catch {
            guard observationIsCurrent() else { return nil }
            updateWaveformMetadata(nil, for: item)
            throw error
        }
    }

    func waveformSnapshot(for item: SoundItem) -> WaveformRowSnapshot? {
        guard Int(item.node.size) <= Self.waveformMaximumBytes,
              let metadata = waveformMetadata[item.id], metadata.node == item.node,
              let snapshot = waveformRows.snapshot(slot: item.id, size: Int(item.node.size)),
              metadata.descriptor.matches(snapshot.record) else { return nil }
        return snapshot
    }

    @discardableResult
    private func updateWaveformMetadata(_ values: [String: JSONValue]?, for item: SoundItem) -> ConfirmedWaveformMetadata? {
        let confirmed = values.flatMap { ConfirmedWaveformMetadata(item: item, values: $0) }
        let previous = waveformMetadata[item.id]
        waveformMetadata[item.id] = confirmed
        if previous != confirmed {
            waveformRows.invalidate(slots: [item.id])
            #if os(macOS)
            automaticWaveformFailures[item.id] = nil
            #endif
            scheduleAutomaticViewportUpdate()
        }
        if let shown = waveformShown, shown.id == item.id {
            waveformShown = waveformPresentation(shown.item, record: shown.record, metadata: confirmed, loading: shown.loading)
        }
        return confirmed
    }

    private func waveformPresentation(_ item: SoundItem, record: WaveformPeakRecord?, metadata: ConfirmedWaveformMetadata?, loading: Bool = false) -> WaveformShown {
        let accepted = record.flatMap { metadata?.node == item.node && metadata?.descriptor.matches($0) == true ? $0 : nil }
        let loopsKnown = metadata?.loopMetadataAvailable == true
        return WaveformShown(item: item, record: accepted,
                             loopStart: loopsKnown ? metadata?.loopStart : nil,
                             loopEnd: loopsKnown ? metadata?.loopEnd : nil,
                             metadataConfirmed: loopsKnown, loading: loading)
    }

    func invalidateWaveformContent(slots: Set<UInt16>? = nil) async {
        waveformContentEpoch = UUID()
        waveformIntent.invalidate()
        waveformLease?.cancel()
        if let slots {
            for slot in slots { waveformMetadata[slot] = nil }
        } else {
            waveformMetadata.removeAll()
        }
        waveformRows.invalidate(slots: slots)
        if let shown = waveformShown, slots == nil || slots!.contains(shown.id) { waveformShown = nil }
        if let session = waveformCacheSession { await waveformCache.invalidate(slots: slots, session: session) }
    }

    func waveformAvailability(for item: SoundItem) -> String {
        if Int(item.node.size) > Self.waveformMaximumBytes || !item.node.isReadable
            || (soundsListed && waveformMetadata[item.id] == nil) { return "waveform unavailable" }
        #if os(macOS)
        if automaticWaveformFailures[item.id] == waveformViewportContext(for: item) { return "waveform unavailable" }
        #endif
        return "waveform not loaded"
    }

    private func resetAutomaticWaveforms() {
        #if os(macOS)
        automaticWaveformActive?.lease.cancel()
        automaticViewports.removeAll()
        automaticWaveformQueue.removeAll()
        automaticWaveformFailures.removeAll()
        if !automaticViewportPins.isEmpty {
            automaticViewportPins.removeAll()
            waveformRows.setViewportPins([])
        }
        #endif
    }

    #if os(macOS)
    func waveformViewportContext(for item: SoundItem) -> SoundViewportContext {
        let descriptor = waveformMetadata[item.id].flatMap { $0.node == item.node ? $0.descriptor : nil }
        return SoundViewportContext(node: item.node, generation: hotplug.currentGeneration(), session: waveformCacheSession,
                                    content: waveformContentEpoch, descriptor: descriptor)
    }

    private func automaticContextIsCurrent(_ context: SoundViewportContext) -> Bool {
        guard isConnected, let item = sounds.first(where: { $0.id == context.node.id }) else { return false }
        return context == waveformViewportContext(for: item)
    }

    func registerWaveformViewport(_ context: SoundViewportContext, owner: UUID, view: ViewportView? = nil) {
        guard automaticContextIsCurrent(context) else { return }
        if view == nil {
            #if DEBUG
            guard allowAutomaticPolicyFactsForCheck else { return }
            #else
            return
            #endif
        }
        if let existing = automaticViewports[context.node.id], existing.context == context, existing.owner == owner { return }
        if automaticWaveformActive?.job.context.node.id == context.node.id { automaticWaveformActive?.lease.cancel() }
        let empty = SoundViewportSample(rect: .zero, clipped: .zero, attached: false, active: false, shown: false,
                                        hidden: true, blocked: false, clipCount: 0, tracksScroll: false, owner: owner)
        automaticViewports[context.node.id] = AutomaticViewport(context: context, owner: owner, view: view, sample: empty)
        scheduleAutomaticViewportUpdate()
    }

    func observeWaveformViewport(_ context: SoundViewportContext, sample: SoundViewportSample) {
        guard let existing = automaticViewports[context.node.id], existing.context == context,
              existing.owner == sample.owner else { return }
        if sample.retired { automaticViewports[context.node.id] = nil }
        else {
            guard existing.sample != sample else { return }
            automaticViewports[context.node.id]?.sample = sample
        }
        if !sample.eligible, automaticWaveformActive?.job.owner == sample.owner { automaticWaveformActive?.lease.cancel() }
        scheduleAutomaticViewportUpdate()
    }

    private func automaticSample(_ viewport: AutomaticViewport) -> SoundViewportSample? {
        if let view = viewport.view {
            guard view.context == viewport.context, view.slot == viewport.context.node.id else { return nil }
            return view.currentSample()
        }
        #if DEBUG
        if allowAutomaticPolicyFactsForCheck { return viewport.sample }
        #endif
        return nil
    }

    private var automaticViewportAllowed: Bool {
        isConnected && soundsListed && view == .sounds && !modalOpen && statusDetails.isEmpty
    }

    private var automaticReadsAllowed: Bool {
        automaticViewportAllowed && !deviceOccupied && waveformLookupTask == nil
            && inlineRename == nil && inlineSlotEdit == nil && metadataEditing == nil
    }

    private func automaticViewportIsEligible(_ viewport: AutomaticViewport, sample: SoundViewportSample? = nil) -> Bool {
        guard automaticViewportAllowed, automaticContextIsCurrent(viewport.context), viewport.context.session != nil,
              viewport.context.descriptor != nil, viewport.context.node.isReadable,
              Int(viewport.context.node.size) <= Self.waveformMaximumBytes,
              let sample = sample ?? automaticSample(viewport), sample.owner == viewport.owner, sample.eligible,
              let item = sounds.first(where: { $0.node == viewport.context.node }) else { return false }
        return soundMatches(name: item.displayName, slot: item.id, query: filterText, range: soundRange)
    }

    private func automaticJobIsCurrent(_ job: AutomaticWaveformJob) -> Bool {
        guard let viewport = automaticViewports[job.context.node.id], viewport.owner == job.owner,
              viewport.context == job.context else { return false }
        return automaticViewportIsEligible(viewport)
    }

    private func reconcileAutomaticViewport() {
        automaticViewports = automaticViewports.compactMapValues { viewport in
            guard automaticContextIsCurrent(viewport.context), let sample = automaticSample(viewport) else { return nil }
            var current = viewport
            current.sample = sample
            return current
        }
        let eligible = automaticViewports.values.filter { automaticViewportIsEligible($0, sample: $0.sample) }
        let pins = Set(eligible.map { $0.context.node.id })
        if pins != automaticViewportPins {
            automaticViewportPins = pins
            waveformRows.setViewportPins(pins)
        }
        if let active = automaticWaveformActive, !automaticJobIsCurrent(active.job) { active.lease.cancel() }
        let ordered = eligible.sorted {
            let left = $0.sample.rect.maxY
            let right = $1.sample.rect.maxY
            return left == right ? $0.context.node.id < $1.context.node.id : left > right
        }
        automaticWaveformQueue = Array(ordered.compactMap { viewport -> AutomaticWaveformJob? in
            let context = viewport.context
            let job = AutomaticWaveformJob(context: context, owner: viewport.owner)
            let accepted = waveformRows.snapshot(slot: context.node.id, size: Int(context.node.size))
                .map { context.descriptor?.matches($0.record) == true } ?? false
            guard automaticWaveformActive?.job != job, automaticWaveformFailures[context.node.id] != context,
                  !accepted else { return nil }
            return job
        }.prefix(32))
    }

    func retryAutomaticWaveform(for item: SoundItem) {
        automaticWaveformFailures[item.id] = nil
        scheduleAutomaticViewportUpdate()
    }

    private func startAutomaticWaveforms() {
        guard automaticWaveformTask == nil, automaticReadsAllowed, !automaticWaveformQueue.isEmpty else { return }
        automaticWaveformTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                automaticWaveformTask = nil
                scheduleAutomaticViewportUpdate()
            }
            while automaticReadsAllowed, !automaticWaveformQueue.isEmpty {
                let job = automaticWaveformQueue.removeFirst()
                guard automaticJobIsCurrent(job) else { continue }
                await fillAutomaticWaveform(job)
                reconcileAutomaticViewport()
            }
        }
    }

    private func fillAutomaticWaveform(_ job: AutomaticWaveformJob) async {
        guard let session = job.context.session, let descriptor = job.context.descriptor, let files else { return }
        let lease = WaveformCacheLease()
        automaticWaveformActive = (job, lease)
        defer { automaticWaveformActive = nil }
        let candidate = await loadWaveformCandidate(session: session, slot: job.context.node.id, descriptor: descriptor)
        guard lease.isCurrent, automaticJobIsCurrent(job) else { return }
        if let candidate {
            publishAutomaticWaveform(candidate, job: job)
            return
        }
        let token = await waveformCache.token(session: session)
        guard lease.isCurrent, automaticJobIsCurrent(job), automaticReadsAllowed else { return }
        guard let token else { automaticWaveformFailures[job.context.node.id] = job.context; return }
        guard let owner = beginWaveformRead() else { return }
        defer { endWaveformRead(owner) }
        do {
            guard let record = try await readAutomaticWaveform(job, files: files, descriptor: descriptor, lease: lease),
                  lease.isCurrent, automaticJobIsCurrent(job) else { return }
            let stored = await waveformCache.store(record, slot: job.context.node.id, token: token, lease: lease)
            guard lease.isCurrent, automaticJobIsCurrent(job) else { return }
            guard stored else { automaticWaveformFailures[job.context.node.id] = job.context; return }
            publishAutomaticWaveform(record, job: job)
        } catch {
            if automaticContextIsCurrent(job.context) { automaticWaveformFailures[job.context.node.id] = job.context }
        }
    }

    private func readAutomaticWaveform(_ job: AutomaticWaveformJob, files: DeviceFileService,
                                       descriptor: WaveformDescriptor, lease: WaveformCacheLease) async throws -> WaveformPeakRecord? {
        var pcm = try await files.getWhole(fileID: job.context.node.id, maximumBytes: Self.waveformMaximumBytes).data
        defer { pcm.removeAll(keepingCapacity: false) }
        #if DEBUG
        automaticPCMBufferCountForCheck += 1
        automaticMaximumPCMBufferCountForCheck = max(automaticMaximumPCMBufferCountForCheck, automaticPCMBufferCountForCheck)
        defer { automaticPCMBufferCountForCheck -= 1 }
        let barrier = automaticReductionForCheck
        #endif
        guard lease.isCurrent, automaticJobIsCurrent(job) else { return nil }
        guard pcm.count == descriptor.size else { throw DownloadFailure(errorDescription: "sound size changed during waveform read") }
        let record = await Task.detached(priority: .utility) { [pcm] in
            #if DEBUG
            if let barrier { await barrier() }
            #endif
            return WaveformPeakRecord(pcm: pcm, channels: descriptor.channels, sampleRate: descriptor.sampleRate)
        }.value
        guard let record, descriptor.matches(record) else { throw DownloadFailure(errorDescription: "unsupported or changed audio format") }
        return record
    }

    private func publishAutomaticWaveform(_ record: WaveformPeakRecord, job: AutomaticWaveformJob) {
        guard automaticJobIsCurrent(job), job.context.descriptor?.matches(record) == true else { return }
        waveformRows.remember(slot: job.context.node.id, size: Int(job.context.node.size), record: record)
        if let shown = waveformShown, shown.item.node == job.context.node {
            waveformShown = waveformPresentation(shown.item, record: record, metadata: waveformMetadata[shown.id], loading: shown.loading)
        }
    }
    #endif

    private func scheduleAutomaticViewportUpdate() {
        #if os(macOS)
        automaticViewportDirty = true
        guard automaticViewportTask == nil else { return }
        automaticViewportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                automaticViewportDirty = false
                reconcileAutomaticViewport()
            } while automaticViewportDirty
            automaticViewportTask = nil
            startAutomaticWaveforms()
        }
        #endif
    }

    private func loadWaveformCandidate(session: UUID, slot: UInt16, descriptor: WaveformDescriptor) async -> WaveformPeakRecord? {
        #if DEBUG
        waveformDiskLoadsForCheck += 1
        #endif
        return await waveformCache.load(session: session, slot: slot, descriptor: descriptor)
    }

    func prepareWaveformRow(_ item: SoundItem, epoch: UUID) {
        guard epoch == waveformRows.epoch, isConnected, soundsListed, view == .sounds, let session = waveformCacheSession,
              sounds.contains(where: { $0.node == item.node }),
              let metadata = waveformMetadata[item.id], metadata.node == item.node else { return }
        waveformLookups.removeAll { !waveformRows.isCurrent($0.request) || !hotplug.isCurrent($0.generation) }
        guard waveformLookups.count < 64,
              let request = waveformRows.beginLookup(slot: item.id, size: Int(item.node.size)) else { return }
        waveformLookups.append(WaveformLookup(item: item, generation: hotplug.currentGeneration(),
                                              session: session, request: request, metadata: metadata))
        guard waveformLookupTask == nil else { return }
        waveformLookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !waveformLookups.isEmpty {
                let lookup = waveformLookups.removeFirst()
                guard waveformLookupIsCurrent(lookup) else {
                    waveformRows.cancelLookup(lookup.request)
                    continue
                }
                let record = await loadWaveformCandidate(session: lookup.session, slot: lookup.item.id,
                                                       descriptor: lookup.metadata.descriptor)
                guard waveformLookupIsCurrent(lookup) else {
                    waveformRows.cancelLookup(lookup.request)
                    continue
                }
                waveformRows.finishLookup(lookup.request, record: record)
            }
            waveformLookupTask = nil
            scheduleAutomaticViewportUpdate()
        }
    }

    func releaseWaveformRow(_ item: SoundItem, epoch: UUID) {
        guard epoch == waveformRows.epoch else { return }
        #if os(macOS)
        if let viewport = automaticViewports[item.id], automaticViewportIsEligible(viewport) { return }
        #endif
        waveformRows.forget(slot: item.id, size: Int(item.node.size), epoch: epoch)
        waveformLookups.removeAll { $0.item.node == item.node }
        if waveformShown?.item.node == item.node { waveformShown = nil }
    }

    private func waveformLookupIsCurrent(_ lookup: WaveformLookup) -> Bool {
        hotplug.isCurrent(lookup.generation) && waveformCacheSession == lookup.session
            && waveformMetadata[lookup.item.id] == lookup.metadata
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
              visibleSounds.contains(where: { $0.node == item.node }) else { return }
        guard Int(item.node.size) <= Self.waveformMaximumBytes else {
            waveformShown = nil
            noteError("waveform: audio exceeds the 16 MiB preview budget")
            return
        }
        #if os(macOS)
        retryAutomaticWaveform(for: item)
        #endif
        guard enterDevice() else { return }
        defer { leaveDevice() }
        guard let files, let cacheSession = waveformCacheSession else { return }
        let token = hotplug.currentGeneration()
        let observationIsCurrent = waveformObservationGuard(for: item, generation: token)
        waveformLease?.cancel()
        let lease = WaveformCacheLease()
        waveformLease = lease
        let request = waveformIntent.begin(slot: item.id, generation: token)
        let op = progress.begin()
        defer { progress.end(op) }
        let known = waveformMetadata[item.id].flatMap { $0.node == item.node ? $0 : nil }
        var candidate = forceRefresh ? nil : waveformSnapshot(for: item)?.record
        waveformShown = waveformPresentation(item, record: candidate, metadata: known, loading: true)
        if forceRefresh {
            waveformRows.invalidate(slots: [item.id])
            await waveformCache.invalidate(slots: [item.id], session: cacheSession)
        }
        guard waveformIsCurrent(request, lease: lease), let cacheToken = await waveformCache.token(session: cacheSession),
              waveformIsCurrent(request, lease: lease) else { return }
        if !forceRefresh, candidate == nil, let known {
            candidate = await loadWaveformCandidate(session: cacheSession, slot: item.id, descriptor: known.descriptor)
            guard waveformIsCurrent(request, lease: lease), waveformMetadata[item.id] == known else { return }
            waveformRows.reconcileCache(slot: item.id, size: Int(item.node.size), record: candidate)
            waveformShown = waveformPresentation(item, record: candidate, metadata: known, loading: true)
        }
        do {
            guard let meta = try await observedSoundMetadata(item, files: files, generation: token) else { return }
            guard let confirmed = ConfirmedWaveformMetadata(item: item, values: meta) else {
                throw DownloadFailure(errorDescription: "sound format metadata unavailable or unsupported")
            }
            guard waveformIsCurrent(request, lease: lease), observationIsCurrent() else { return }
            candidate = candidate.flatMap { confirmed.descriptor.matches($0) ? $0 : nil }
            waveformShown = waveformPresentation(item, record: candidate, metadata: confirmed, loading: true)
            if !forceRefresh, candidate == nil {
                candidate = await loadWaveformCandidate(session: cacheSession, slot: item.id, descriptor: confirmed.descriptor)
                guard waveformIsCurrent(request, lease: lease), waveformMetadata[item.id] == confirmed else { return }
            }
            waveformRows.reconcileCache(slot: item.id, size: Int(item.node.size), record: candidate)
            waveformShown = waveformPresentation(item, record: candidate, metadata: confirmed, loading: true)
            let record: WaveformPeakRecord
            if let candidate {
                record = candidate
            } else {
                progress.update(op, "recv \(item.displayName)")
                let pcm = try await files.getWhole(fileID: item.id, maximumBytes: Self.waveformMaximumBytes) { done, total in
                    Task { @MainActor in
                        self.progress.update(op, "recv \(item.displayName) \(done * 100 / max(total, 1))%")
                    }
                }.data
                guard waveformIsCurrent(request, lease: lease), waveformMetadata[item.id] == confirmed else { return }
                let descriptor = confirmed.descriptor
                let computed = await Task.detached(priority: .userInitiated) {
                    WaveformPeakRecord(pcm: pcm, channels: descriptor.channels, sampleRate: descriptor.sampleRate)
                }.value
                guard waveformIsCurrent(request, lease: lease), waveformMetadata[item.id] == confirmed else { return }
                guard let computed, descriptor.matches(computed) else {
                    throw DownloadFailure(errorDescription: "unsupported or changed audio format")
                }
                record = computed
                guard await waveformCache.store(record, slot: item.id, token: cacheToken, lease: lease),
                      waveformIsCurrent(request, lease: lease), waveformMetadata[item.id] == confirmed else { return }
            }
            guard waveformIsCurrent(request, lease: lease), waveformMetadata[item.id] == confirmed else { return }
            waveformRows.remember(slot: item.id, size: Int(item.node.size), record: record)
            let shownItem = SoundItem(node: item.node, displayName: meta["name"]?.stringValue ?? item.displayName)
            waveformShown = waveformPresentation(shownItem, record: record, metadata: confirmed)
            progress.update(op, nil)
        } catch {
            guard observationIsCurrent() else { return }
            updateWaveformMetadata(nil, for: item)
            if waveformIsCurrent(request, lease: lease) { waveformShown = nil }
            progress.update(op, nil)
            let message = if case FileServiceError.readLimitExceeded = error {
                "audio exceeds the 16 MiB preview budget"
            } else { error.localizedDescription }
            reportOperationError("waveform: \(message)", token: token)
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
