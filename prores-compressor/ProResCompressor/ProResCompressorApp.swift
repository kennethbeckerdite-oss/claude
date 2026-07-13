import SwiftUI

@main
struct ProResCompressorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("ProRes Compressor", id: "main") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 520, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
