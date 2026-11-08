import SwiftUI
import UniformTypeIdentifiers
import KokokoAudio
import KokokoCore
import KokokoLibrary
import KokokoMIDI

struct ContentView: View {
    // Classic property wrapper on purpose: macro-based @State/@EnvironmentObject
    // need Xcode's SwiftUIMacros plugin; this stays typecheckable with CLT.
    @ObservedObject var state: AppState
    #if os(macOS) && DEBUG
    var rowDropCheck: Bool?
    var rowDropCheckFocus: Binding<SoundFocus?> = .constant(nil)
    var suppressDeviceObservationForCheck = false
    #endif
    @State private var soundListTargeted = false
    @State private var projectListTargeted = false
    @State private var targetedRow: UInt16?
    @FocusState private var focus: SoundFocus?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .font(.system(.body, design: .monospaced))
        // On macOS the rows of a List kept the proportional font with only the line
        // above; the design has to be set on its own as well.
        .fontDesign(.monospaced)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .fileImporter(isPresented: anyPickerBinding,
                      allowedContentTypes: state.panel.picker == .none ? [.audio] : [.folder],
                      allowsMultipleSelection: state.panel.picker == .none) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            state.handleImport(urls)
        }
        .fileExporter(isPresented: exporterBinding,
                      document: state.exportDocument,
                      contentType: .wav,
                      defaultFilename: state.exportName) { _ in
            state.exportDocument = nil
        }
        #if os(macOS) && DEBUG
        .onChange(of: rowDropCheckFocus.wrappedValue) { _, value in
            if rowDropCheck != nil || suppressDeviceObservationForCheck { focus = value }
        }
        .onChange(of: focus) { _, value in
            if rowDropCheck != nil || suppressDeviceObservationForCheck { rowDropCheckFocus.wrappedValue = value }
        }
        #endif
        .task {
            #if os(macOS) && DEBUG
            guard rowDropCheck == nil && !suppressDeviceObservationForCheck else { return }
            #endif
            state.watchDevices()
            if case .idle = state.connection {
                await state.scan()
            }
        }
        .confirmationDialog("delete failed", isPresented: unbinnedDeleteBinding,
                            presenting: state.unbinnedDelete) { pending in
            Button("delete without keeping a copy", role: .destructive) {
                Task { await state.deleteWithoutBin(pending.ids, generation: pending.generation) }
            }
            Button("cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.prompt)
        }
        .confirmationDialog("remove from bin for good?", isPresented: binRemoveBinding,
                            presenting: state.binToRemove) { entry in
            Button("remove \(entry.name)", role: .destructive) { state.removeFromBin(entry) }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog(RestoreSummary.title, isPresented: restoreBinding, presenting: state.pendingRestore) { pending in
            Button("restore", role: .destructive) { Task { await state.restore(pending.backup) } }
            Button("cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.summary.message)
        }
        .confirmationDialog(SwapSummary.title, isPresented: swapBinding, presenting: state.pendingSwap) { pending in
            Button("swap") { Task { await state.moveOrSwap(id: pending.id, toSlot: pending.target) } }
            Button("cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.summary.message)
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { state.pendingRestore != nil }, set: { if !$0 { state.pendingRestore = nil } })
    }

    private var swapBinding: Binding<Bool> {
        Binding(get: { state.pendingSwap != nil }, set: { if !$0 { state.pendingSwap = nil } })
    }

    private var unbinnedDeleteBinding: Binding<Bool> {
        Binding(get: { state.unbinnedDelete != nil }, set: { if !$0 { state.unbinnedDelete = nil } })
    }

    private var binRemoveBinding: Binding<Bool> {
        Binding(get: { state.binToRemove != nil }, set: { if !$0 { state.binToRemove = nil } })
    }

    private var anyPickerBinding: Binding<Bool> {
        Binding(
            get: { state.showImporter || state.picker != .none },
            set: { if !$0 { state.showImporter = false; state.picker = .none } }
        )
    }

    private var exporterBinding: Binding<Bool> {
        Binding(get: { state.exportDocument != nil }, set: { if !$0 { state.exportDocument = nil } })
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                headerTitle
                Spacer()
                connectionStatus
            }
            FlowLayout {
                headerTitle
                connectionStatus
            }
        }
        .padding()
    }

    @ViewBuilder private var headerTitle: some View {
        Text("kokoko")
            .font(.system(.title2, design: .monospaced))
        ForEach(HeaderTab.allCases, id: \.self) { tab in
            tabButton(tab)
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch state.connection {
        case .idle:
            Text("[ idle ]")
        case .scanning:
            Text("[ scan... ]")
        case .connecting(let name):
            Text("[ conn \(name) ]").lineLimit(1)
        case .connected(let name, let serial, let os):
            let line = StatusLine.connected(name: name, serial: serial, os: os, firmware: state.firmwareStatus)
            Text(line.text).lineLimit(1)
                .accessibilityLabel(line.accessibilityLabel)
        case .failed(let why):
            FullTextButton(line: .connectionFailed(why), text: why, lineLimit: 1, presentationChanged: state.setStatusDetail)
        }
    }

    private var isConnected: Bool { state.isConnected }

    private var devicePhase: DevicePhase {
        switch state.connection {
        case .idle, .scanning: .searching
        case .connecting(let name): .connecting(name)
        case .connected: .connected
        case .failed: .failed
        }
    }

    private func tabButton(_ tab: HeaderTab) -> some View {
        Button(tabTitle(tab.title, selected: state.view == tab)) { state.open(tab) }
        .buttonStyle(.plain)
        .foregroundStyle(state.view == tab ? .primary : .secondary)
        .accessibilityLabel(tab.title.capitalized)
        .accessibilityAddTraits(state.view == tab ? .isSelected : [])
    }

    private var content: some View {
        Group {
            if let notice = tabNotice(state.view, device: devicePhase,
                                      waitingForDevice: state.tabLoad.waiting == state.view) {
                deviceNotice(notice)
            } else {
                switch state.view {
                case .projects:
                    projectList
                case .settings:
                    VStack(spacing: 0) {
                        backupRow(.everything, button: .backupAll)
                        Divider()
                        SettingsView(state: state)
                    }
                case .bin:
                    binList
                case .sounds:
                    soundList
                }
            }
        }
    }

    private func deviceNotice(_ notice: String) -> some View {
        VStack(spacing: 12) {
            Text(notice)
            if case .failed = state.connection {
                Text("connect the device over usb-c")
                barButton(.retry) { Task { await state.scan() } }
                    .disabled(state.deviceBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var soundList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                libraryOverview(proxy)
                TextField("filter: name or slot", text: $state.filterText)
                    .focused($focus, equals: .filter)
                    .textFieldStyle(.plain)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()
                soundRows(proxy)
            }
        }
    }

    private func libraryOverview(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(soundCountsText(total: state.listedSoundCount, shown: state.visibleSounds.count, fresh: state.soundsListed))
            Text(state.soundStorage.text).foregroundStyle(.secondary)
            if let message = state.soundStorage.message {
                Text("storage unavailable").foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel("Storage unavailable: \(message)")
                    .help(message)
            }
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) { HStack { rangeBookmarks(proxy) } }
            } else {
                FlowLayout { rangeBookmarks(proxy) }
            }
            if state.soundsListed, !state.deviceBusy,
               let empty = soundListEmpty(total: state.sounds.count, visible: state.visibleSounds.count,
                                          query: state.filterText) {
                Text(empty.text).foregroundStyle(.secondary)
                if empty == .noSounds { barButton(.addSounds) { state.showImporter = true } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func rangeBookmarks(_ proxy: ScrollViewProxy) -> some View {
        ForEach(SoundRange.all) { range in
            Button { proxy.scrollTo(SoundSectionID.range(range.id), anchor: .top) } label: {
                Text("[ \(range.label) ]")
                    .frame(minWidth: 28, minHeight: minHitHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .rangeJump(range.id))
            .accessibilityLabel("Jump to slots \(range.label)")
            .help("jump to slots \(range.label)")
        }
    }

    private func soundRows(_ proxy: ScrollViewProxy) -> some View {
        let visible = state.visibleSounds
        let items = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sections = soundSections(all: state.sounds.map(\.id), visible: Set(visible.map(\.id)))
        return List(selection: $state.selection) {
            ForEach(sections) { section in
                Section {
                    if section.slots.isEmpty {
                        let status = section.emptyText(hasSnapshot: state.listedSoundCount != nil, fresh: state.soundsListed)
                        Text(status)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(section.title): \(status)")
                            .selectionDisabled()
                    } else {
                        ForEach(section.slots, id: \.self) { slot in
                            if let item = items[slot] { soundRow(item) }
                        }
                    }
                } header: {
                    Text(section.title).id(section.id)
                }
            }
        }
        .focused($focus, equals: .soundList)
        .onChange(of: state.filterText) { _, query in
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let groups = soundSections(all: state.sounds.map(\.id), visible: Set(state.visibleSounds.map(\.id)))
            if let first = groups.lazy.flatMap(\.slots).first { proxy.scrollTo(first, anchor: .top) }
        }
        .onKeyPress(.space, phases: .down) { press in
            guard keyboard.target(phase: .down, modified: !press.modifiers.isEmpty) != nil else { return .ignored }
            state.auditionSelected()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard let id = keyboard.target(phase: .down, modified: !press.modifiers.isEmpty),
                  let item = state.visibleSounds.first(where: { $0.id == id }) else { return .ignored }
            beginRename(item)
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { dropBanner(.soundList, targeted: soundListTargeted) }
        .onDrop(of: [.audio], delegate: ListDrop(target: .soundList, types: [.audio], state: state,
                                                 targeted: $soundListTargeted) { providers in
            return receiveDrop(providers, load: { provider, done in
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _, error in
                    done(url, error)
                }
            }, then: { urls in
                await state.upload(urls: urls)
            })
        })
        #if os(macOS)
        .onDeleteCommand(perform: focus == .soundList && state.inlineRename == nil && state.inlineSlotEdit == nil && state.metadataEditing == nil && !state.modalOpen
                         && state.isEnabled(.deleteSelected) ? { state.perform(.deleteSelected) } : nil)
        #endif
    }

    private func soundRow(_ item: SoundItem) -> some View {
        Group {
            #if os(macOS)
            #if DEBUG
            if rowDropCheck == false {
                soundRowContent(item)
                    .onDrop(of: [rowMoveTextType], delegate: SoundRowDrop(target: item, state: state, targeted: $targetedRow))
            } else {
                NativeRowDrop(item: item, state: state, targeted: $targetedRow, content: soundRowContent(item))
            }
            #else
            NativeRowDrop(item: item, state: state, targeted: $targetedRow, content: soundRowContent(item))
            #endif
            #else
            soundRowContent(item)
                .onDrop(of: [rowMoveTextType], delegate: SoundRowDrop(target: item, state: state, targeted: $targetedRow))
            #endif
        }
        .tag(item.id)
        .id(item.id)
    }

    private func soundRowContent(_ item: SoundItem) -> some View {
        let epoch = state.waveformRows.epoch
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                RowDragHandle(item: item, state: state)
                    .frame(width: 28, height: minHitHeight)
                    .help("drag sound to reorder or export")
                slotField(item)
                if let edit = state.inlineRename, edit.id == item.id {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("sound name", text: renameDraft(edit))
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .rename(item.id))
                            .accessibilityLabel("sound name, slot \(item.id)")
                            .disabled(edit.submitting)
                            .onSubmit { submitRename(edit) }
                            .onKeyPress(.escape, phases: .down) { press in
                                guard press.modifiers.isEmpty, edit.canCancel else { return .ignored }
                                if state.cancelInlineRename() { focus = .soundList }
                                return .handled
                            }
                        if let error = edit.error {
                            Text(error).foregroundStyle(Color.errorText)
                        }
                    }
                } else {
                    Text(item.displayName)
                }
                Spacer()
                waveformButton(item)
                if let marker = rowDropMarker(row: item.id, targeted: targetedRow, dragged: state.rowDrag.active?.id,
                                              deviceBusy: state.deviceBusy) {
                    Text(marker)
                } else {
                    Text(formatSize(item.node.size))
                        .foregroundStyle(.secondary)
                }
                let commands = soundCommands(item)
                if collapsesRowActions {
                    Menu {
                        ForEach(commands, id: \.action) { command in
                            Button(command.action.accessibilityLabel, action: command.perform)
                        }
                    } label: {
                        Text(RowAction.actions.glyph)
                            .frame(minWidth: 28, minHeight: minHitHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .rowMenu(item.id))
                    .disabled(state.deviceBusy)
                    .accessibilityLabel(RowAction.actions.accessibilityLabel)
                } else {
                    ForEach(commands, id: \.action) { command in
                        rowButton(command.action, help: command.help, perform: command.perform)
                            .focused($focus, equals: .rowAction(item.id, command.action))
                    }
                }
            }
            slotNote(item)
            metadataDetails(item)
            if let shown = state.waveformShown, shown.id == item.id {
                WaveformDetail(state: state, shown: shown, focus: $focus) { closeWaveform(item.id) }
            }
        }
        .onAppear { state.prepareWaveformRow(item, epoch: epoch) }
        .onDisappear { state.releaseWaveformRow(item, epoch: epoch) }
        .onChange(of: item) { _, _ in state.prepareWaveformRow(item, epoch: epoch) }
        .onChange(of: state.waveformRows.epoch) { _, current in state.prepareWaveformRow(item, epoch: current) }
        .onChange(of: state.soundsListed) { _, listed in if listed { state.prepareWaveformRow(item, epoch: epoch) } }
    }

    private func waveformButton(_ item: SoundItem) -> some View {
        let snapshot = state.waveformRows.snapshot(slot: item.id, size: Int(item.node.size))
        return Button {
            if state.waveformShown?.id == item.id {
                closeWaveform(item.id)
            } else {
                Task { await state.showWaveform(item) }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                if !collapsesRowActions { WaveformThumbnail(snapshot: snapshot, compact: false) }
                WaveformThumbnail(snapshot: snapshot, compact: true)
            }
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .rowAction(item.id, .waveform))
        .disabled(state.deviceBusy)
        .accessibilityLabel("Show waveform, slot \(item.id)")
        .accessibilityValue(snapshot?.description ?? "waveform not loaded")
        .help("show waveform: " + (snapshot?.description ?? "waveform not loaded"))
    }

    private func closeWaveform(_ id: UInt16) {
        guard state.waveformShown?.id == id else { return }
        state.waveformShown = nil
        if focus == nil || focus == .waveformPlay(id) || focus == .waveformRefresh(id)
            || focus == .waveformClose(id) || focus == .rowAction(id, .waveform) { focus = .soundList }
    }

    @ViewBuilder private func slotField(_ item: SoundItem) -> some View {
        if let edit = state.inlineSlotEdit, edit.rowID == item.id {
            TextField("slot", text: slotDraft(edit))
                .textFieldStyle(.plain)
                .frame(width: 64, alignment: .leading)
                .frame(minHeight: minHitHeight)
                .focused($focus, equals: .slot(edit.session))
                .accessibilityLabel("slot number for \(item.displayName)")
                .disabled(edit.submitting)
                .onSubmit { submitSlot(edit) }
                .onKeyPress(.escape, phases: .down) { press in
                    guard press.modifiers.isEmpty, edit.canCancel else { return .ignored }
                    if state.cancelInlineSlot() { focus = .soundList }
                    return .handled
                }
        } else {
            Button { beginSlot(item) } label: {
                Text(String(format: "%03d", item.id))
                    .frame(width: 64, alignment: .leading)
                    .frame(minHeight: minHitHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focused($focus, equals: .slotNumber(item.id))
            .accessibilityLabel(slotNumberLabel(item.id))
            .help("move to another free slot")
            .disabled(state.deviceBusy)
        }
    }

    @ViewBuilder private func slotNote(_ item: SoundItem) -> some View {
        if let edit = state.inlineSlotEdit, edit.rowID == item.id {
            if let error = edit.error {
                Text(error).foregroundStyle(Color.errorText)
            }
            if edit.needsRefresh {
                HStack {
                    if edit.slot == nil { Text("slot unknown; refresh before retrying") }
                    barButton(.refresh) { Task { await state.refreshInlineSlot(session: edit.session) } }
                        .focused($focus, equals: .slotRefresh(edit.session))
                        .disabled(state.deviceBusy)
                }
            }
        }
    }

    private func beginSlot(_ item: SoundItem) {
        state.beginInlineSlot(item)
        if let edit = state.inlineSlotEdit, edit.rowID == item.id { focus = .slot(edit.session) }
    }

    private func slotDraft(_ edit: InlineSlotEdit) -> Binding<String> {
        Binding(get: { state.inlineSlotEdit?.session == edit.session ? state.inlineSlotEdit?.draft ?? "" : "" },
                set: {
                    if state.inlineSlotEdit?.session == edit.session, state.inlineSlotEdit?.submitting == false {
                        state.inlineSlotEdit?.draft = $0
                    }
                })
    }

    private func submitSlot(_ edit: InlineSlotEdit) {
        Task { @MainActor in
            if await state.commitInlineSlot(session: edit.session) {
                if focus == nil || focus == .slot(edit.session) || focus == .soundList { focus = .soundList }
            } else if state.inlineSlotEdit?.session == edit.session, focus == nil {
                focus = .slot(edit.session)
            }
        }
    }

    private var metadataFieldsStacked: Bool { collapsesRowActions || dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder private func metadataDetails(_ item: SoundItem) -> some View {
        if let edit = state.metadataEditing, edit.id == item.id {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if edit.phase == .loading { Text("reading metadata...").foregroundStyle(.secondary) }
                if let form = edit.form {
                    ForEach(MetadataEditForm.keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            let layout = metadataFieldsStacked
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                            layout {
                                if metadataFieldsStacked {
                                    Text(key)
                                } else {
                                    Text(key).frame(width: 160, alignment: .leading)
                                }
                                TextField("", text: metadataDraft(key, edit: edit))
                                    .textFieldStyle(.plain)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(minHeight: minHitHeight)
                                    .focused($focus, equals: .metadataField(edit.session, key))
                                    .accessibilityLabel("\(key), \(edit.name), slot \(edit.id)")
                                    .disabled(edit.phase != .ready || state.deviceBusy)
                                    .onSubmit { submitMetadata(session: edit.session) }
                            }
                            if let error = form.error(for: key) { Text(error).foregroundStyle(Color.errorText) }
                        }
                    }
                }
                if let note = edit.note {
                    Text(note).foregroundStyle(Color.errorText)
                    if edit.form != nil {
                        Text("cancel closes this draft; it does not undo device writes").foregroundStyle(.secondary)
                    }
                }
                if edit.needsReadback { Text("save reads the device before retrying").foregroundStyle(.secondary) }
                if edit.phase == .saving { Text("saving metadata...").foregroundStyle(.secondary) }
                HStack {
                    if edit.phase == .loadFailed {
                        barButton(.retry) { retryMetadata(session: edit.session) }
                            .focused($focus, equals: .metadataRetry(edit.session))
                            .disabled(state.deviceBusy)
                    }
                    if edit.form != nil {
                        barButton(.saveMetadata) { submitMetadata(session: edit.session) }
                            .focused($focus, equals: .metadataSave(edit.session))
                            .disabled(!edit.canSubmit || state.deviceBusy)
                    }
                    barButton(.cancelMetadata) { cancelMetadata(session: edit.session) }
                        .focused($focus, equals: .metadataCancel(edit.session))
                        .disabled(!edit.canCancel)
                }
            }
            .onKeyPress(.escape, phases: .down) { press in
                guard press.modifiers.isEmpty, state.metadataEditing?.session == edit.session,
                      state.metadataEditing?.canCancel == true else { return .ignored }
                cancelMetadata(session: edit.session)
                return .handled
            }
        }
    }

    private func metadataDraft(_ key: String, edit: InlineMetadataEdit) -> Binding<String> {
        Binding(get: { state.metadataEditing?.session == edit.session ? state.metadataEditing?.form?.text[key] ?? "" : "" },
                set: {
                    if state.metadataEditing?.session == edit.session, state.metadataEditing?.phase == .ready {
                        state.metadataEditing?.form?.text[key] = $0
                    }
                })
    }

    private func beginMetadata(_ item: SoundItem) {
        let previous = focus
        Task { @MainActor in
            if let session = await state.editMetadata(item) { focusMetadataIfReady(session: session, previous: previous) }
        }
    }

    private func retryMetadata(session: UUID) {
        let previous = focus
        Task { @MainActor in
            await state.retryMetadata(session: session)
            focusMetadataIfReady(session: session, previous: previous)
        }
    }

    private func focusMetadataIfReady(session: UUID, previous: SoundFocus?) {
        guard state.metadataEditing?.session == session, state.metadataEditing?.phase == .ready,
              focus == nil || focus == previous, let key = MetadataEditForm.keys.first else { return }
        focus = .metadataField(session, key)
    }

    private func metadataOwnsFocus(_ value: SoundFocus?, session: UUID) -> Bool {
        guard let value else { return false }
        switch value {
        case .metadataField(let id, _), .metadataSave(let id), .metadataCancel(let id), .metadataRetry(let id):
            return id == session
        default: return false
        }
    }

    private func submitMetadata(session: UUID) {
        guard state.metadataEditing?.session == session, state.metadataEditing?.canSubmit == true else { return }
        let previous = focus
        Task { @MainActor in
            if await state.saveMetadata(session: session) {
                if focus == nil || metadataOwnsFocus(focus, session: session) { focus = .soundList }
            } else if state.metadataEditing?.session == session, focus == nil {
                if metadataOwnsFocus(previous, session: session) {
                    focus = previous
                } else {
                    focusMetadataIfReady(session: session, previous: nil)
                }
            }
        }
    }

    private func cancelMetadata(session: UUID) {
        if state.cancelMetadata(session: session) { focus = .soundList }
    }

    private var keyboard: SoundKeyboard {
        var input = SoundKeyboard()
        input.focus = focus
        input.tab = state.view
        input.connected = state.isConnected
        input.busy = state.deviceBusy
        input.blocked = state.modalOpen || state.inlineRename != nil || state.inlineSlotEdit != nil || state.metadataEditing != nil || !state.statusDetails.isEmpty
        input.selection = state.selection
        input.visible = Set(state.visibleSounds.map(\.id))
        return input
    }

    private func beginRename(_ item: SoundItem) {
        state.beginInlineRename(item)
        if state.inlineRename?.id == item.id { focus = .rename(item.id) }
    }

    private func renameDraft(_ edit: InlineRename) -> Binding<String> {
        Binding(get: { state.inlineRename?.session == edit.session ? state.inlineRename?.draft ?? "" : "" },
                set: {
                    if state.inlineRename?.session == edit.session, state.inlineRename?.submitting == false {
                        state.inlineRename?.draft = $0
                    }
                })
    }

    private func submitRename(_ edit: InlineRename) {
        Task { @MainActor in
            if await state.commitInlineRename(session: edit.session) {
                if focus == nil || focus == .rename(edit.id) || focus == .soundList { focus = .soundList }
            } else if state.inlineRename?.session == edit.session, focus == nil {
                focus = .rename(edit.id)
            }
        }
    }

    /// On a compact-width iPhone or iPad window a sound row cannot show every
    /// action button next to its name, so they go into one menu.
    private var collapsesRowActions: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private struct RowCommand {
        let action: RowAction
        let help: String
        let perform: () -> Void
    }

    private func soundCommands(_ item: SoundItem) -> [RowCommand] {
        [
            RowCommand(action: .play, help: "play 1s preview on device") { state.requestAudition(item) },
            RowCommand(action: .download, help: "download as wav") {
                Task {
                    if case .success(let result) = await state.download(item) {
                        state.exportName = result.name
                        state.exportDocument = DataDocument(data: Data(result.wav))
                    }
                }
            },
            RowCommand(action: .rename, help: "rename") { beginRename(item) },
            RowCommand(action: .metadata, help: "edit metadata") { beginMetadata(item) },
            RowCommand(action: .delete, help: "delete from device") { Task { await state.delete(item) } },
        ]
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                footerStatus
                Spacer()
                footerActions
            }
            FlowLayout {
                footerStatus
                footerActions
            }
        }
        .padding()
    }

    @ViewBuilder private var footerStatus: some View {
        if let progress = state.progressText {
            Text(progress)
        }
        if let error = state.lastError {
            FullTextButton(line: .error(error), text: error, lineLimit: 2, presentationChanged: state.setStatusDetail)
                .foregroundStyle(Color.errorText)
        }
    }

    @ViewBuilder private var footerActions: some View {
        if case .connected = state.connection, state.view == .sounds {
            if !state.selection.isEmpty {
                Text("sel \(state.selection.count)")
                TextField("to #", text: $state.bulkMoveStart)
                    .focused($focus, equals: .bulkMove)
                    .frame(width: 56)
                barButton(.moveSelection) {
                    if let start = UInt16(state.bulkMoveStart) {
                        Task { await state.moveSelection(startingAt: start) }
                    }
                }
                .disabled(state.deviceBusy)
                barButton(.downloadSelection) { state.picker = .downloadFolder(Array(state.selection)) }
                    .disabled(state.deviceBusy)
                barButton(.deleteSelection) { Task { await state.deleteMany(state.selection) } }
                    .disabled(state.deviceBusy)
            }
            barButton(.addSounds) { state.showImporter = true }
                .disabled(state.deviceBusy)
            barButton(.backupSounds) { state.picker = .backupFolder(.sounds) }
                .disabled(state.deviceBusy)
            barButton(.restoreBackup) { state.picker = .restoreFolder }
                .disabled(state.deviceBusy)
            barButton(.refresh) { Task { await state.refreshSounds() } }
                .disabled(state.deviceBusy)
        }
    }

    private var binList: some View {
        Group {
            if state.binEntries.isEmpty {
                Text("bin is empty")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.binEntries) { entry in
                        HStack {
                            Text(binRowLabel(slot: entry.originalSlot, name: entry.name,
                                             deletedAt: entry.deletedAt))
                            Spacer()
                            rowButton(.restore, help: "restore to the device", needsDevice: true) {
                                Task { await state.restoreFromBin(entry) }
                            }
                            rowButton(.removeFromBin, help: "remove from the bin for good") { state.binToRemove = entry }
                        }
                    }
                }
            }
        }
    }

    private func backupRow(_ scope: DeviceLibrary.Scope, button: BarAction) -> some View {
        FlowLayout {
            barButton(button) { state.picker = .backupFolder(scope) }
                .disabled(state.deviceBusy)
            barButton(.restoreBackup) { state.picker = .restoreFolder }
                .disabled(state.deviceBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            backupRow(.projects, button: .backupProjects)
            Divider()
            projectRows
        }
    }

    private var projectRows: some View {
        List {
            ForEach(state.projects) { project in
                HStack {
                    Text("P\(project.name)")
                    Spacer()
                    rowButton(.downloadArchive, help: "download project archive") {
                        Task {
                            if let result = await state.downloadProject(project) {
                                state.exportName = result.name
                                state.exportDocument = DataDocument(data: Data(result.tar),
                                                                    contentType: .tarArchive)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { dropBanner(.projectList, targeted: projectListTargeted) }
        .onDrop(of: [.tarArchive], delegate: ListDrop(target: .projectList, types: [.tarArchive], state: state,
                                                      targeted: $projectListTargeted) { providers in
            return receiveDrop(providers, load: { provider, done in
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.tarArchive.identifier) { url, _, error in
                    done(url, error)
                }
            }, then: { urls in
                await state.uploadProjects(urls: urls)
            })
        })
    }

    /// At the bottom edge rather than the top, so the rows near the pointer do not move.
    @ViewBuilder private func dropBanner(_ target: DropTarget, targeted: Bool) -> some View {
        if let marker = dropMarker(target, targeted: targeted, deviceBusy: state.deviceBusy) {
            Text(marker)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    /// Copies every dropped file inside its provider callback, then hands the
    /// copies over in drop order once all callbacks finished, one batch, so
    /// uploads run sequentially on the single device session.
    private func receiveDrop(_ providers: [NSItemProvider],
                             load: (NSItemProvider, @escaping @Sendable (URL?, Error?) -> Void) -> Void,
                             then handle: @escaping @MainActor ([URL]) async -> Void) -> Bool {
        let staging: DropStaging
        do {
            staging = try DropStaging(count: providers.count)
        } catch {
            state.noteError("drop: \(error.localizedDescription)")
            return false
        }
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            let name = provider.suggestedName ?? "item \(index + 1)"
            load(provider) { url, error in
                if let url {
                    staging.stage(url, at: index)
                } else {
                    staging.fail(name: name, reason: error?.localizedDescription ?? "unreadable item")
                }
                group.leave()
            }
        }
        let state = state
        let total = providers.count
        group.notify(queue: .main) {
            Task { @MainActor in
                await handle(staging.urls)
                staging.discard()
                // After the handler, whose trailing reload may clear earlier errors;
                // appended so an error from the handler itself stays visible.
                // Not tied to the device generation: these files could not be
                // read, whatever happened to the device.
                if let text = batchFailureText("drop", failures: staging.failures, total: total) {
                    state.noteError(text)
                }
            }
        }
        return true
    }

    /// A row action: its glyph on screen, its name for VoiceOver, and a hit area at
    /// least 28 pt wide (the HIG minimum; wider would crowd a row's name out on iPhone)
    /// and as tall as the HIG default for the platform. The frame and shape sit inside
    /// the label: placed outside the Button, a plain-style button on macOS was measured
    /// still taking clicks only on the glyph.
    private func rowButton(_ action: RowAction, help: String, needsDevice: Bool = false,
                           perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(action.glyph)
                .frame(minWidth: 28, minHeight: minHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.deviceBusy || (needsDevice && !isConnected))
        .help(help)
        .accessibilityLabel(action.accessibilityLabel)
    }

    private func formatSize(_ size: UInt32) -> String {
        if size > 1024 * 1024 {
            return String(format: "%.1fmb", Double(size) / 1048576.0)
        }
        return "\(size / 1024)kb"
    }
}

extension UTType {
    static let soundRowMove = UTType(exportedAs: "la.lex.kokoko.sound-row-move")
    static let tarArchive = UTType(filenameExtension: "tar") ?? .archive
}

func dropContents(_ info: DropInfo) -> DropContents {
    DropContents(rowMove: info.hasItemsConforming(to: [.soundRowMove]), audio: info.hasItemsConforming(to: [.audio]),
                 tarArchive: info.hasItemsConforming(to: [.tarArchive]))
}

struct ListDrop: DropDelegate {
    let target: DropTarget
    let types: [UTType]
    let state: AppState
    @Binding var targeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        dropAccepted(by: target, contents: dropContents(info), deviceBusy: state.deviceBusy)
    }

    func dropEntered(info: DropInfo) {
        targeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return perform(info.itemProviders(for: types))
    }
}

/// Drop target on a sound row: reorders the dragged node into this slot,
/// swapping when occupied.
struct SoundRowDrop: DropDelegate {
    let target: SoundItem
    let state: AppState
    @Binding var targeted: UInt16?

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { targeted = target.id }
    }

    func dropExited(info: DropInfo) {
        if targeted == target.id { targeted = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = nil
        RowDragDiagnostics.event("swiftui target perform slot=\(target.id)")
        guard let token = state.rowDrag.claim(target: target.id, busy: state.deviceBusy) else {
            RowDragDiagnostics.event("swiftui target reject=no-claim")
            return false
        }
        guard let provider = info.itemProviders(for: [rowMoveTextType]).first else {
            RowDragDiagnostics.event("swiftui target reject=no-text-provider")
            return false
        }
        let generation = state.rowDragGeneration
        provider.loadDataRepresentation(forTypeIdentifier: rowMoveTextType.identifier) { data, error in
            RowDragDiagnostics.event("swiftui target text-complete data=\(data != nil) bytes=\(data?.count ?? 0)")
            RowDragDiagnostics.error("swiftui target text", error)
            Task { @MainActor in
                guard generation == state.rowDragGeneration else {
                    RowDragDiagnostics.event("swiftui target reject=device-changed")
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8), token.matches(text) else {
                    RowDragDiagnostics.event("swiftui target reject=payload-mismatch")
                    state.noteError("reorder: \(error?.localizedDescription ?? "invalid drag payload")")
                    return
                }
                guard !state.deviceBusy, state.sounds.contains(where: { $0.id == token.id }),
                      state.sounds.contains(where: { $0.id == target.id }) else {
                    RowDragDiagnostics.event("swiftui target reject=busy-or-missing-sound")
                    state.noteError("reorder: device busy or sound no longer available")
                    return
                }
                RowDragDiagnostics.event("swiftui target request-swap slot=\(target.id)")
                state.requestSwap(id: token.id, onto: target)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let token = state.rowDrag.active, token.id != target.id else {
            RowDragDiagnostics.event("swiftui target validate slot=\(target.id) accepted=false reason=context-or-self")
            return false
        }
        let accepted = !state.deviceBusy && info.hasItemsConforming(to: [rowMoveTextType])
        RowDragDiagnostics.event("swiftui target validate slot=\(target.id) accepted=\(accepted)")
        return accepted
    }
}

extension Color {
    static let errorText: Color = {
        func color(_ rgb: Int) -> (Double, Double, Double) {
            (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
        }
        let (light, dark) = (color(ErrorColor.light), color(ErrorColor.dark))
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }()
}

/// A truncated line that opens its full text in a popover. `.help` alone
/// needs a pointer to hover, which a touch screen does not have.
private struct FullTextButton: View {
    let line: StatusLine
    let text: String
    let lineLimit: Int
    let presentationChanged: (UUID, Bool) -> Void
    @State private var shown = false
    @State private var presentationID = UUID()

    var body: some View {
        Button {
            shown = true
            presentationChanged(presentationID, true)
        } label: {
            Text(line.text).lineLimit(lineLimit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.accessibilityLabel)
        .help(text)
        .onChange(of: shown) { _, value in presentationChanged(presentationID, value) }
        .onDisappear {
            shown = false
            presentationChanged(presentationID, false)
        }
        .popover(isPresented: $shown) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(idealWidth: 420, maxHeight: 320)
        }
    }
}

@MainActor
func barButton(_ action: BarAction, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
        Text(action.text)
            .frame(minWidth: 28, minHeight: minHitHeight)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(action.accessibilityLabel)
}

/// Lays its children out left to right and wraps them onto new lines where the
/// offered width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placement(width: proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = placement(width: bounds.width, subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = placed.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(placed.sizes[index]))
        }
    }

    private func placement(width: CGFloat?, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize, sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let flow = flowPlacement(sizes: sizes, maxWidth: width ?? .infinity, spacing: spacing)
        return (flow.origins, flow.size, sizes)
    }
}

#if os(macOS)
let minHitHeight: CGFloat = 28
#else
let minHitHeight: CGFloat = 44
#endif
