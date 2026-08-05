import AppKit
import Foundation
import OSLog

private let openSpeechIntegrationLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.paco.TP7VibeInput",
    category: "OpenSpeechIntegration"
)

final class OpenSpeechIntegrationService {
    static let bundleID = "com.openspeech.asr"
    static let refreshNotificationName = Notification.Name("com.paco.TP7VibeInput.openSpeechPresetChanged")

    private enum DefaultsKey {
        static let holdShortcut = "hold_shortcut"
        static let toggleShortcut = "toggle_shortcut"
        static let presetNames = "system_prompt_preset_names"
        static let presetPrompts = "system_prompt_preset_prompts"
        static let selectedPreset = "selected_system_prompt_preset"
        static let customSystemPrompt = "custom_system_prompt"
        static let customSystemPromptLastModified = "custom_system_prompt_last_modified"
    }

    private let defaults = UserDefaults(suiteName: bundleID)

    var selectedPresetID: String {
        readString(DefaultsKey.selectedPreset) ?? "a"
    }

    func availablePresets() -> [(id: String, name: String)] {
        let names = readDictionary(DefaultsKey.presetNames)
        return ["a", "b", "c", "d"].map { id in
            (id, names[id] ?? "Preset \(id.uppercased())")
        }
    }

    func presetName(for id: String) -> String {
        availablePresets().first { $0.id == id }?.name ?? "Preset \(id.uppercased())"
    }

    func applyPreset(_ id: String) -> Bool {
        let normalized = normalizedPresetID(id)
        let prompts = readDictionary(DefaultsKey.presetPrompts)
        let prompt = prompts[normalized] ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            openSpeechIntegrationLog.error("Preset \(normalized, privacy: .public) has no prompt")
            return false
        }

        write(normalized, forKey: DefaultsKey.selectedPreset)
        write(prompt, forKey: DefaultsKey.customSystemPrompt)
        write(Self.todayString(), forKey: DefaultsKey.customSystemPromptLastModified)
        defaults?.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Self.refreshNotificationName,
            object: normalized,
            userInfo: ["preset": normalized],
            deliverImmediately: true
        )
        openSpeechIntegrationLog.info("Applied Open Speech preset \(normalized, privacy: .public)")
        return true
    }

    func applyNextPreset(delta: Int) -> String? {
        let ids = ["a", "b", "c", "d"]
        let current = selectedPresetID
        let currentIndex = ids.firstIndex(of: current) ?? 0
        let nextIndex = (currentIndex + delta + ids.count) % ids.count
        let nextID = ids[nextIndex]
        return applyPreset(nextID) ? nextID : nil
    }

    func loadHoldShortcut() throws -> OpenSpeechStoredShortcut {
        try loadShortcut(forKey: DefaultsKey.holdShortcut)
    }

    func loadToggleShortcut() throws -> OpenSpeechStoredShortcut {
        try loadShortcut(forKey: DefaultsKey.toggleShortcut)
    }

    func describeHoldShortcut() -> String {
        (try? loadHoldShortcut().displayName) ?? "Unavailable"
    }

    func describeToggleShortcut() -> String {
        (try? loadToggleShortcut().displayName) ?? "Unavailable"
    }

    private func loadShortcut(forKey key: String) throws -> OpenSpeechStoredShortcut {
        guard let data = readData(key) else {
            throw OpenSpeechIntegrationError.shortcutMissing
        }
        let binding = try JSONDecoder().decode(OpenSpeechStoredShortcut.self, from: data)
        if binding.kind == .disabled {
            throw OpenSpeechIntegrationError.shortcutDisabled
        }
        return binding
    }

    private func normalizedPresetID(_ id: String) -> String {
        let lowered = id.lowercased()
        return ["a", "b", "c", "d"].contains(lowered) ? lowered : "a"
    }

    private func readData(_ key: String) -> Data? {
        defaults?.synchronize()
        if let data = defaults?.data(forKey: key) {
            return data
        }
        return UserDefaults.standard.persistentDomain(forName: Self.bundleID)?[key] as? Data
    }

    private func readString(_ key: String) -> String? {
        defaults?.synchronize()
        return defaults?.string(forKey: key)
            ?? UserDefaults.standard.persistentDomain(forName: Self.bundleID)?[key] as? String
    }

    private func readDictionary(_ key: String) -> [String: String] {
        defaults?.synchronize()
        if let dict = defaults?.dictionary(forKey: key) as? [String: String] {
            return dict
        }
        return UserDefaults.standard.persistentDomain(forName: Self.bundleID)?[key] as? [String: String] ?? [:]
    }

    private func write(_ value: String, forKey key: String) {
        defaults?.set(value, forKey: key)
        var domain = UserDefaults.standard.persistentDomain(forName: Self.bundleID) ?? [:]
        domain[key] = value
        UserDefaults.standard.setPersistentDomain(domain, forName: Self.bundleID)
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

enum OpenSpeechIntegrationError: LocalizedError {
    case shortcutMissing
    case shortcutDisabled

    var errorDescription: String? {
        switch self {
        case .shortcutMissing: "Open Speech shortcut was not found"
        case .shortcutDisabled: "Open Speech shortcut is disabled"
        }
    }
}
