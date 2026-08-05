import SwiftUI

@main
struct TP7MIDICaptureApp: App {
    @StateObject private var recorder = MIDICaptureRecorder()

    var body: some Scene {
        WindowGroup {
            CaptureView()
                .environmentObject(recorder)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
