import SwiftUI
import KokokoCore
import KokokoMIDI
import KokokoAudio
import KokokoLibrary

@main
struct KokokoApp: App {
    @StateObject private var state = AppState()

    init() {
        #if os(macOS)
        // SPM smoke runs have no app bundle; without this the window stays backgrounded.
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // One window: closing it quits, so no command can run without the
        // window, and no second window shares the one state.
        Window("kokoko", id: "main") {
            ContentView(state: state)
        }
        .commands { KokokoCommands(state: state) }
        #else
        WindowGroup {
            ContentView(state: state)
        }
        .commands { KokokoCommands(state: state) }
        #endif
    }
}

struct KokokoCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            item(.addSounds)
            item(.downloadSelected)
            Divider()
            item(.backupSounds)
            item(.backupProjects)
            item(.backupAll)
            item(.restoreBackup)
        }
        CommandGroup(before: .toolbar) {
            item(.showSounds)
            item(.showProjects)
            item(.showSettings)
            item(.showBin)
            Divider()
            item(.refresh)
            item(.scan)
            Divider()
        }
    }

    private func item(_ command: AppCommand) -> some View {
        Button(command.title) { state.perform(command) }
            .keyboardShortcut(command.shortcut.map {
                KeyboardShortcut(KeyEquivalent($0.key), modifiers: $0.shift ? [.command, .shift] : .command)
            })
            .disabled(!state.isEnabled(command))
    }
}
