import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        DetailView()
        .background(.regularMaterial)
        .frame(minWidth: 1120, minHeight: 700)
        .alert("Enable Accessibility", isPresented: $store.showAccessibilityPermissionPrompt) {
            Button("Authorize") {
                store.requestAccessibilityPermissionFromPrompt()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("TP7 Vibe Deck needs Accessibility permission to run TP-7 mappings such as Open Speech, shortcuts, scrolling, volume, and brightness.")
        }
    }
}
