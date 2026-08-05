import AppKit
import Foundation
import OSLog

private let hermesLauncherLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.paco.TP7VibeInput",
    category: "HermesAgentLauncher"
)

final class HermesAgentLauncher {
    private var commandURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["TP7_HERMES_PATH"], !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath)
        }

        let candidates = [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/hermes").path
        ]
        return candidates.lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func launch() throws {
        guard let commandURL else {
            throw HermesAgentLauncherError.commandMissing
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp7-launch-hermes.command")
        let script = """
        #!/bin/zsh -l
        clear
        exec "\(commandURL.path)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL(), configuration: configuration) { _, error in
            if let error {
                hermesLauncherLog.error("Failed to launch Hermes in Terminal: \(error.localizedDescription, privacy: .public)")
            }
        }
        hermesLauncherLog.info("Launching Hermes command at \(commandURL.path, privacy: .public)")
    }

    private func terminalURL() -> URL {
        URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }
}

enum HermesAgentLauncherError: LocalizedError {
    case commandMissing

    var errorDescription: String? {
        switch self {
        case .commandMissing:
            return "Hermes command was not found. Set TP7_HERMES_PATH or install hermes in a standard bin directory."
        }
    }
}
