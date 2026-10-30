import SwiftUI
import UniformTypeIdentifiers
import KokokoAudio
import KokokoCore
import KokokoMIDI

struct ContentView: View {
    // Classic property wrapper on purpose: macro-based @State/@EnvironmentObject
    // need Xcode's SwiftUIMacros plugin; this stays typecheckable with CLT.
    @ObservedObject var state: AppState
    @State private var renumberText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .font(.system(.body, design: .monospaced))
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
                    Task { await state.loadProjects() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.view == .projects ? .primary : .secondary)
                Button("[ settings ]") { state.view = .settings }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.view == .settings ? .primary : .secondary)
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
                Text("[ !! \(why) ]")
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
                    SettingsView(state: state)
                } else {
                    soundList
                }
            case .failed:
                VStack(spacing: 12) {
                    Text("connect the device over usb-c")
                    Button("[ retry ]") { Task { await state.scan() } }
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                Text("scanning for midi devices...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var soundList: some View {
        List(selection: $state.selection) {
            ForEach(state.sounds) { item in
                HStack {
                    Text(String(format: "%03d", item.node.id))
                        .foregroundStyle(.secondary)
                    Text(item.displayName)
                    Spacer()
                    Text(formatSize(item.node.size))
                        .foregroundStyle(.secondary)
                    Button("[>]") { Task { await state.audition(item) } }
                        .buttonStyle(.plain)
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
                    .help("download as wav")
                    Button("[r]") { state.renameText = item.displayName; state.renameItem = item }
                        .buttonStyle(.plain)
                        .help("rename")
                    Button("[#]") { state.renumberItem = item }
                        .buttonStyle(.plain)
                        .help("change slot number")
                    Button("[x]") { Task { await state.delete(item) } }
                        .buttonStyle(.plain)
                        .help("delete from device")
                }
                .tag(item.id)
                .onDrag { state.dragProvider(for: item) }
                .onDrop(of: [.text], delegate: SoundRowDrop(target: item, state: state))
            }
        }
        .onDrop(of: [.audio], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _, _ in
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                Task { await state.upload(urls: urls) }
            }
            return true
        }
    }

    private var footer: some View {
        HStack {
            if let progress = state.progressText {
                Text(progress)
            }
            if let error = state.lastError {
                Text("err: \(error)").foregroundStyle(.red).lineLimit(1)
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
                    Button("[ v to folder ]") {
                        state.picker = .downloadFolder(Array(state.selection))
                    }
                    .buttonStyle(.plain)
                    Button("[ x ]") { Task { await state.deleteMany(state.selection) } }
                        .buttonStyle(.plain)
                }
                if state.view == .sounds {
                    Button("[ + add sounds ]") { state.showImporter = true }
                        .buttonStyle(.plain)
                    Button("[ backup sounds ]") { state.picker = .backupFolder(.sounds) }
                        .buttonStyle(.plain)
                    Button("[ restore sounds ]") { state.picker = .restoreFolder }
                        .buttonStyle(.plain)
                } else if state.view == .projects {
                    Button("[ backup projects ]") { state.picker = .backupFolder(.projects) }
                        .buttonStyle(.plain)
                    Button("[ restore ]") { state.picker = .restoreFolder }
                        .buttonStyle(.plain)
                } else {
                    Button("[ backup all ]") { state.picker = .backupFolder(.everything) }
                        .buttonStyle(.plain)
                    Button("[ restore all ]") { state.picker = .restoreFolder }
                        .buttonStyle(.plain)
                }
                Button("[ refresh ]") {
                    Task {
                        if state.view == .projects { await state.loadProjects() } else { await state.reload() }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    private var projectList: some View {
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
                    .help("download project archive")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _, _ in
                    if let url {
                        Task { await state.uploadProject(url: url) }
                    }
                }
            }
            return true
        }
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
        info.hasItemsConforming(to: [.text])
    }
}
