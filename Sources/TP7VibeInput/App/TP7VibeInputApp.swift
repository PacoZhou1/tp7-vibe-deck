import SwiftUI

@main
struct TP7VibeInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("TP7 Vibe Deck", id: "main") {
            ContentView()
                .environmentObject(store)
                .task {
                    store.start()
                }
        }
        .defaultSize(width: 1180, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("TP-7") {
                Button("Refresh Devices") {
                    store.refreshDevices()
                }
                .keyboardShortcut("r")

                Button("Cancel Recording") {
                    store.cancelRecording(trigger: "keyboard")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
