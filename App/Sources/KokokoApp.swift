import SwiftUI
import KokokoCore
import KokokoMIDI
import KokokoAudio

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
        WindowGroup {
            ContentView(state: state)
        }
    }
}
