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
            if state.settingsUnsupported {
                Text("not exposed over midi on this firmware")
                    .foregroundStyle(.secondary)
            } else if state.settingsTree.isEmpty {
                Text(state.progressText ?? "loading...")
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
            if state.settingsTree.isEmpty {
                await state.loadSettings()
            }
        }
    }
}
