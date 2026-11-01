import SwiftUI
import KokokoCore
import KokokoMIDI
import KokokoLibrary

struct SettingsEntryModel: Identifiable {
    let id: Int
    let title: String
    let value: JSONValue
    let range: String?

    var isIdentifiable: Int { id }
}

struct SettingsGroupModel: Identifiable {
    let title: String
    let entries: [SettingsEntryModel]

    var id: String { title }
}

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        List {
            if let placeholder = state.settingsStatus.placeholder(isEmpty: state.settingsTree.isEmpty) {
                Text(state.settingsStatus == .notLoaded ? state.progressText ?? placeholder : placeholder)
                    .foregroundStyle(.secondary)
                if state.settingsStatus == .failed {
                    barButton(.retry) { Task { await state.loadSettings() } }
                        .disabled(state.deviceBusy)
                }
            }
            ForEach(state.settingsTree) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(entry.title)
                                Spacer()
                                Text(entry.value.displayText)
                                    .foregroundStyle(.secondary)
                            }
                            if let help = state.settingsHelp[entry.title.lowercased()] {
                                Text(help)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task {
            // While the device is busy, the scan that holds it loads the settings itself.
            if state.settingsStatus.loadsWhenOpened && !state.deviceBusy {
                await state.loadSettings()
            }
        }
    }
}
