import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        repairMainWindowWhenReady()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func repairMainWindowWhenReady(attempt: Int = 0) {
        if repairMainWindow() {
            return
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.repairMainWindowWhenReady(attempt: attempt + 1)
        }
    }

    @discardableResult
    private func repairMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "TP7 Vibe Deck" }) else {
            return false
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < 1120 || window.frame.height < 700 {
            window.setFrame(NSRect(x: 0, y: 0, width: 1180, height: 740), display: true)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
