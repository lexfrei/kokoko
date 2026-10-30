import SwiftUI
import UniformTypeIdentifiers
import KokokoCore
import KokokoMIDI
import KokokoAudio

struct ContentView: View {
    // Classic property wrapper on purpose: macro-based @State/@EnvironmentObject
    // need Xcode's SwiftUIMacros plugin; this stays typecheckable with CLT.
    @ObservedObject var state: AppState

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
        .fileImporter(isPresented: importerBinding,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await state.upload(urls: urls) }
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
    }

    private var importerBinding: Binding<Bool> {
        Binding(get: { state.showImporter }, set: { state.showImporter = $0 })
    }

    private var exporterBinding: Binding<Bool> {
        Binding(get: { state.exportDocument != nil }, set: { if !$0 { state.exportDocument = nil } })
    }

    private var header: some View {
        HStack {
            Text("kokoko")
                .font(.system(.title2, design: .monospaced))
            Spacer()
            switch state.connection {
            case .idle:
                Text("[ idle ]")
            case .scanning:
                Text("[ scan... ]")
            case .connecting(let name):
                Text("[ conn \(name) ]").lineLimit(1)
            case .connected(let name, let serial, let os):
                Text("[ \(name) \(serial) os \(os) ]").lineLimit(1)
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
                soundList
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
        List {
            ForEach(state.sounds) { item in
                HStack {
                    Text(item.node.name)
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
                    Button("[x]") { Task { await state.delete(item) } }
                        .buttonStyle(.plain)
                        .help("delete from device")
                }
            }
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
            if case .connected = state.connection {
                Button("[ + add sounds ]") { state.showImporter = true }
                    .buttonStyle(.plain)
                Button("[ refresh ]") { Task { await state.reload() } }
                    .buttonStyle(.plain)
            }
        }
        .padding()
    }

    private func formatSize(_ size: UInt32) -> String {
        if size > 1024 * 1024 {
            return String(format: "%.1fmb", Double(size) / 1048576.0)
        }
        return "\(size / 1024)kb"
    }
}
