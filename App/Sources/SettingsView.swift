import SwiftUI
import KokokoCore
import KokokoMIDI

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
            if state.settingsTree.isEmpty {
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

extension JSONValue {
    var displayText: String {
        switch self {
        case .int(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .string(let v): return v
        case .bool(let v): return v ? "on" : "off"
        case .array: return "[…]"
        case .object: return "{…}"
        case .null: return "-"
        }
    }
}
