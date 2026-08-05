import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button(store.statusMessage) {}
            .disabled(true)

        Divider()

        Button("Refresh Devices") {
            store.refreshDevices()
        }

        Button(store.isRecording ? "Stop Recording" : "Start Recording") {
            if store.isRecording {
                store.stopRecording(trigger: "menu")
            } else {
                store.startRecording(trigger: "menu")
            }
        }

        Button("Cancel Recording") {
            store.cancelRecording(trigger: "menu")
        }
        .disabled(!store.isRecording)

        Divider()

        SettingsLink()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
