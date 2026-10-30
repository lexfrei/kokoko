import SwiftUI
import KokokoCore
import KokokoMIDI
import KokokoAudio

@main
struct KokokoApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
    }
}
