import BobWobCore
import SwiftUI

@main
struct BobWobApp: App {
    @State private var session = CleanupSession()

    var body: some Scene {
        Window("BobWob", id: "main") {
            ContentView(session: session)
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Lancer le scan") { session.startScan() }
                    .keyboardShortcut("r")
                    .disabled(session.phase == .scanning || session.phase == .cleaning)
                Button("Arrêter") { session.stop() }
                    .keyboardShortcut(".")
                    .disabled(session.phase != .scanning && session.phase != .cleaning)
            }
        }
    }
}
