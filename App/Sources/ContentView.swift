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
    @State private var renumberText = ""
    @State private var binToRemove: BinEntry?

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
        .frame(minWidth: 420, minHeight: 480)
        .fileImporter(isPresented: anyPickerBinding,
                      allowedContentTypes: state.picker == .none ? [.audio] : [.folder],
                      allowsMultipleSelection: state.picker == .none) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let action = state.picker
            state.picker = .none
            Task {
                switch action {
                case .none:
                    await state.upload(urls: urls)
                case .downloadFolder(let ids):
                    await state.downloadManyToFolder(ids, folder: urls[0])
                case .backupFolder(let scope):
                    await state.backupToFolder(urls[0], scope: scope)
                case .restoreFolder:
                    await state.restoreFromFolder(urls[0])
                }
            }
        }
        .fileExporter(isPresented: exporterBinding,
                      document: state.exportDocument,
                      contentType: .wav,
                      defaultFilename: state.exportName) { _ in
            state.exportDocument = nil
        }
        .task {
            state.watchDevices()
            if case .idle = state.connection {
                await state.scan()
            }
        }
        .alert("rename", isPresented: renameBinding) {
            TextField("name", text: $state.renameText)
                .frame(minWidth: 160)
            Button("ok") {
                if let item = state.renameItem {
                    Task { await state.rename(item, to: state.renameText) }
                }
            }
            Button("cancel", role: .cancel) {}
        }
        .alert("renumber", isPresented: renumberBinding) {
            TextField("slot number", text: $renumberText)
                .frame(minWidth: 120)
            Button("ok") {
                if let item = state.renumberItem, let target = UInt16(renumberText) {
                    Task { await state.renumber(item, to: target) }
                }
            }
            Button("cancel", role: .cancel) {}
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
        .sheet(item: $state.metadataEditing) { _ in
            MetadataSheet(state: state)
        }
        .confirmationDialog("remove from bin for good?", isPresented: binRemoveBinding,
                            presenting: binToRemove) { entry in
            Button("remove \(entry.name)", role: .destructive) { state.removeFromBin(entry) }
            Button("cancel", role: .cancel) {}
        }
    }

    private var unbinnedDeleteBinding: Binding<Bool> {
        Binding(get: { state.unbinnedDelete != nil }, set: { if !$0 { state.unbinnedDelete = nil } })
    }

    private var binRemoveBinding: Binding<Bool> {
        Binding(get: { binToRemove != nil }, set: { if !$0 { binToRemove = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { state.renameItem != nil },
            set: { if !$0 { state.renameItem = nil } }
        )
    }

    private var renumberBinding: Binding<Bool> {
        Binding(
            get: { state.renumberItem != nil },
            set: { if !$0 { state.renumberItem = nil } }
        )
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
        HStack {
            Text("kokoko")
                .font(.system(.title2, design: .monospaced))
            if case .connected = state.connection {
                Button("[ sounds ]") { state.view = .sounds }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.view == .sounds ? .primary : .secondary)
                Button("[ projects ]") {
                    state.view = .projects
                    Task { await state.refreshProjects() }
                }
                .buttonStyle(.plain)
                .disabled(state.deviceBusy)
                .foregroundStyle(state.view == .projects ? .primary : .secondary)
                Button("[ settings ]") { state.view = .settings }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                    .foregroundStyle(state.view == .settings ? .primary : .secondary)
                Button("[ bin ]") {
                    state.view = .bin
                    state.loadBin()
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.view == .bin ? .primary : .secondary)
            }
            Spacer()
            switch state.connection {
            case .idle:
                Text("[ idle ]")
            case .scanning:
                Text("[ scan... ]")
            case .connecting(let name):
                Text("[ conn \(name) ]").lineLimit(1)
            case .connected(let name, let serial, let os):
                Text("[ \(name) \(serial) os \(os)\(state.firmwareSuffix) ]").lineLimit(1)
            case .failed(let why):
                Text("[ !! \(why) ]").lineLimit(1)
                    .help(why)
            }
        }
        .padding()
    }

    private var content: some View {
        Group {
            switch state.connection {
            case .connected:
                if state.view == .projects {
                    projectList
                } else if state.view == .settings {
                    VStack(spacing: 0) {
                        backupRow(.everything, label: "[ backup all ]")
                        Divider()
                        SettingsView(state: state)
                    }
                } else if state.view == .bin {
                    binList
                } else {
                    soundList
                }
            case .failed:
                VStack(spacing: 12) {
                    Text("connect the device over usb-c")
                    Button("[ retry ]") { Task { await state.scan() } }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                Text("scanning for midi devices...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var soundList: some View {
        VStack(spacing: 0) {
            TextField("filter: name or slot", text: $state.filterText)
                .textFieldStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            soundRows
        }
    }

    private var soundRows: some View {
        List(selection: $state.selection) {
            ForEach(state.visibleSounds) { item in
                HStack {
                    Text(String(format: "%03d", item.node.id))
                        .foregroundStyle(.secondary)
                    Text(item.displayName)
                    Spacer()
                    Text(formatSize(item.node.size))
                        .foregroundStyle(.secondary)
                    Button("[>]") { Task { await state.audition(item) } }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                        .help("play 1s preview on device")
                    Button("[v]") {
                        Task {
                            if let result = await state.download(item) {
                                state.exportName = result.name
                                state.exportDocument = DataDocument(data: Data(result.wav))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                    .help("download as wav")
                    Button("[r]") { state.renameText = item.displayName; state.renameItem = item }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                        .help("rename")
                    Button("[#]") { state.renumberItem = item }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                        .help("change slot number")
                    Button("[m]") { Task { await state.editMetadata(item) } }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                        .help("edit metadata")
                    Button("[x]") { Task { await state.delete(item) } }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                        .help("delete from device")
                }
                .tag(item.id)
                .onDrag { state.dragProvider(for: item) }
                .onDrop(of: [.text], delegate: SoundRowDrop(target: item, state: state))
            }
        }
        .onDrop(of: [.audio], isTargeted: nil) { providers in
            guard !state.deviceBusy else { return false }
            return receiveDrop(providers, load: { provider, done in
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _, error in
                    done(url, error)
                }
            }, then: { urls in
                await state.upload(urls: urls)
            })
        }
    }

    private var footer: some View {
        HStack {
            if let progress = state.progressText {
                Text(progress)
            }
            if let error = state.lastError {
                Text("err: \(error)").foregroundStyle(.red).lineLimit(1)
                    .help(error)
            }
            Spacer()
            if case .connected = state.connection, state.view == .sounds {
                if !state.selection.isEmpty {
                    Text("sel \(state.selection.count)")
                    TextField("to #", text: $state.bulkMoveStart)
                        .frame(width: 56)
                    Button("[ move ]") {
                        if let start = UInt16(state.bulkMoveStart) {
                            Task { await state.moveSelection(startingAt: start) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                    Button("[ v to folder ]") {
                        state.picker = .downloadFolder(Array(state.selection))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                    Button("[ x ]") { Task { await state.deleteMany(state.selection) } }
                        .buttonStyle(.plain)
                        .disabled(state.deviceBusy)
                }
                Button("[ + add sounds ]") { state.showImporter = true }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                Button("[ backup sounds ]") { state.picker = .backupFolder(.sounds) }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                Button("[ restore backup ]") { state.picker = .restoreFolder }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                Button("[ refresh ]") { Task { await state.refreshSounds() } }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
            }
        }
        .padding()
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
                            Button("[restore]") { Task { await state.restoreFromBin(entry) } }
                                .buttonStyle(.plain)
                                .disabled(state.deviceBusy)
                                .help("put back on the device")
                            Button("[x]") { binToRemove = entry }
                                .buttonStyle(.plain)
                                .disabled(state.deviceBusy)
                                .help("remove from the bin for good")
                        }
                    }
                }
            }
        }
    }

    private func backupRow(_ scope: DeviceLibrary.Scope, label: String) -> some View {
        HStack {
            Button(label) { state.picker = .backupFolder(scope) }
                .buttonStyle(.plain)
                .disabled(state.deviceBusy)
            Button("[ restore backup ]") { state.picker = .restoreFolder }
                .buttonStyle(.plain)
                .disabled(state.deviceBusy)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            backupRow(.projects, label: "[ backup projects ]")
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
                    Button("[v tar]") {
                        Task {
                            if let result = await state.downloadProject(project) {
                                state.exportName = result.name
                                state.exportDocument = DataDocument(data: Data(result.tar),
                                                                    contentType: UTType(filenameExtension: "tar") ?? .data)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(state.deviceBusy)
                    .help("download project archive")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !state.deviceBusy else { return false }
            return receiveDrop(providers, load: { provider, done in
                _ = provider.loadObject(ofClass: URL.self) { url, error in done(url, error) }
            }, then: { urls in
                await state.uploadProjects(urls: urls)
            })
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
            state.lastError = "drop: \(error.localizedDescription)"
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
                // After the handler, whose trailing reload clears stale errors;
                // appended so an error from the handler itself stays visible.
                if let text = batchFailureText("drop", failures: staging.failures, total: total) {
                    state.lastError = appendingError(state.lastError, text)
                }
            }
        }
        return true
    }

    private func formatSize(_ size: UInt32) -> String {
        if size > 1024 * 1024 {
            return String(format: "%.1fmb", Double(size) / 1048576.0)
        }
        return "\(size / 1024)kb"
    }
}

/// Drop target on a sound row: reorders the dragged node into this slot,
/// swapping when occupied.
struct SoundRowDrop: DropDelegate {
    let target: SoundItem
    let state: AppState

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data,
                  let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("node:"),
                  let id = UInt16(text.dropFirst(5)) else { return }
            Task { @MainActor in
                await state.moveOrSwap(id: id, toSlot: target.id)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        !state.deviceBusy && info.hasItemsConforming(to: [.text])
    }
}

struct MetadataSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let editing = state.metadataEditing {
            VStack(alignment: .leading, spacing: 8) {
                Text("metadata: \(editing.name)")
                    .font(.system(.headline, design: .monospaced))
                Grid(alignment: .leading) {
                    ForEach(MetadataEditForm.keys, id: \.self) { key in
                        GridRow {
                            Text(key)
                            TextField("", text: field(key))
                                .frame(minWidth: 120)
                            Text(editing.form.error(for: key) ?? "")
                                .foregroundStyle(.red)
                        }
                    }
                }
                if let note = editing.note {
                    Text(note)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("cancel") { state.metadataEditing = nil }
                        .disabled(state.deviceBusy)
                    Button("save") { Task { await state.saveMetadata() } }
                        .disabled(state.deviceBusy || editing.form.changes == nil)
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding()
            .interactiveDismissDisabled(state.deviceBusy)
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(get: { state.metadataEditing?.form.text[key] ?? "" },
                set: { state.metadataEditing?.form.text[key] = $0 })
    }
}
