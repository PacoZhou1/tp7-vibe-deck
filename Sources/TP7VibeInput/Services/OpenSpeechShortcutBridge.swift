import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

private let shortcutBridgeLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.paco.TP7VibeInput",
    category: "OpenSpeechShortcutBridge"
)

final class OpenSpeechShortcutBridge {
    private let integration = OpenSpeechIntegrationService()
    private var activeShortcut: ActiveShortcut?

    var isHoldingOpenSpeech: Bool {
        activeShortcut != nil
    }

    func describeConfiguredHoldShortcut() -> String {
        integration.describeHoldShortcut()
    }

    func describeConfiguredToggleShortcut() -> String {
        integration.describeToggleShortcut()
    }

    func beginHold() throws -> String {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard activeShortcut == nil else {
            return activeShortcut?.binding.displayName ?? "Open Speech"
        }
        guard AXIsProcessTrusted() else {
            throw BridgeError.accessibilityNotTrusted
        }

        let binding = try integration.loadHoldShortcut()
        guard binding.kind != .disabled else {
            throw BridgeError.holdShortcutDisabled
        }

        let shortcut = ActiveShortcut(binding: binding)
        let loadedAt = CFAbsoluteTimeGetCurrent()
        press(shortcut)
        activeShortcut = shortcut
        shortcutBridgeLog.info(
            "beginHold shortcut=\(binding.displayName, privacy: .public) loadMs=\((loadedAt - startedAt) * 1000, format: .fixed(precision: 3)) totalMs=\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000, format: .fixed(precision: 3))"
        )
        return binding.displayName
    }

    func triggerToggle() throws -> String {
        guard AXIsProcessTrusted() else {
            throw BridgeError.accessibilityNotTrusted
        }
        let binding = try integration.loadToggleShortcut()
        let shortcut = ActiveShortcut(binding: binding)
        press(shortcut)
        release(shortcut)
        shortcutBridgeLog.info("triggerToggle shortcut=\(binding.displayName, privacy: .public)")
        return binding.displayName
    }

    func endHold() -> String? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let shortcut = activeShortcut else { return nil }
        release(shortcut)
        activeShortcut = nil
        shortcutBridgeLog.info(
            "endHold shortcut=\(shortcut.binding.displayName, privacy: .public) totalMs=\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000, format: .fixed(precision: 3))"
        )
        return shortcut.binding.displayName
    }

    private func press(_ shortcut: ActiveShortcut) {
        var pressedModifierKeyCodes: Set<UInt16> = []

        for keyCode in shortcut.extraModifierKeyCodes {
            pressedModifierKeyCodes.insert(keyCode)
            postModifier(keyCode: keyCode, isDown: true, pressedModifierKeyCodes: pressedModifierKeyCodes)
        }

        if shortcut.binding.kind == .modifierKey {
            pressedModifierKeyCodes.insert(shortcut.binding.keyCode)
            postModifier(
                keyCode: shortcut.binding.keyCode,
                isDown: true,
                pressedModifierKeyCodes: pressedModifierKeyCodes
            )
        } else {
            postKey(
                keyCode: shortcut.binding.keyCode,
                isDown: true,
                pressedModifierKeyCodes: pressedModifierKeyCodes
            )
        }
    }

    private func release(_ shortcut: ActiveShortcut) {
        var pressedModifierKeyCodes = Set(shortcut.extraModifierKeyCodes)

        if shortcut.binding.kind == .modifierKey {
            pressedModifierKeyCodes.insert(shortcut.binding.keyCode)
            pressedModifierKeyCodes.remove(shortcut.binding.keyCode)
            postModifier(
                keyCode: shortcut.binding.keyCode,
                isDown: false,
                pressedModifierKeyCodes: pressedModifierKeyCodes
            )
        } else {
            postKey(
                keyCode: shortcut.binding.keyCode,
                isDown: false,
                pressedModifierKeyCodes: pressedModifierKeyCodes
            )
        }

        for keyCode in shortcut.extraModifierKeyCodes.reversed() {
            pressedModifierKeyCodes.remove(keyCode)
            postModifier(keyCode: keyCode, isDown: false, pressedModifierKeyCodes: pressedModifierKeyCodes)
        }
    }

    private func postModifier(keyCode: UInt16, isDown: Bool, pressedModifierKeyCodes: Set<UInt16>) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: isDown
        ) else {
            return
        }
        event.type = .flagsChanged
        event.flags = Self.flags(for: pressedModifierKeyCodes)
        event.post(tap: .cghidEventTap)
    }

    private func postKey(keyCode: UInt16, isDown: Bool, pressedModifierKeyCodes: Set<UInt16>) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: isDown
        ) else {
            return
        }
        event.flags = Self.flags(for: pressedModifierKeyCodes)
        event.post(tap: .cghidEventTap)
    }

    private static func flags(for pressedModifierKeyCodes: Set<UInt16>) -> CGEventFlags {
        var rawValue: UInt64 = 0
        for keyCode in pressedModifierKeyCodes {
            rawValue |= rawFlagValue(for: keyCode)
        }
        return CGEventFlags(rawValue: rawValue)
    }

    private static func rawFlagValue(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 54:
            return UInt64(NX_DEVICERCMDKEYMASK) | CGEventFlags.maskCommand.rawValue
        case 55:
            return UInt64(NX_DEVICELCMDKEYMASK) | CGEventFlags.maskCommand.rawValue
        case 56:
            return UInt64(NX_DEVICELSHIFTKEYMASK) | CGEventFlags.maskShift.rawValue
        case 58:
            return UInt64(NX_DEVICELALTKEYMASK) | CGEventFlags.maskAlternate.rawValue
        case 59:
            return UInt64(NX_DEVICELCTLKEYMASK) | CGEventFlags.maskControl.rawValue
        case 60:
            return UInt64(NX_DEVICERSHIFTKEYMASK) | CGEventFlags.maskShift.rawValue
        case 61:
            return UInt64(NX_DEVICERALTKEYMASK) | CGEventFlags.maskAlternate.rawValue
        case 62:
            return UInt64(NX_DEVICERCTLKEYMASK) | CGEventFlags.maskControl.rawValue
        case 63:
            return CGEventFlags.maskSecondaryFn.rawValue
        default:
            return 0
        }
    }
}

private struct ActiveShortcut {
    let binding: OpenSpeechStoredShortcut
    let extraModifierKeyCodes: [UInt16]

    init(binding: OpenSpeechStoredShortcut) {
        self.binding = binding
        self.extraModifierKeyCodes = binding.orderedExtraModifierKeyCodes
    }
}

private enum BridgeError: LocalizedError {
    case accessibilityNotTrusted
    case holdShortcutMissing
    case holdShortcutDisabled

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "TP7 Vibe Deck needs Accessibility permission to press the Open Speech shortcut"
        case .holdShortcutMissing:
            return "Open Speech hold shortcut was not found"
        case .holdShortcutDisabled:
            return "Open Speech hold shortcut is disabled"
        }
    }
}

struct OpenSpeechShortcutModifiers: OptionSet, Decodable, Equatable {
    let rawValue: Int

    static let command = OpenSpeechShortcutModifiers(rawValue: 1 << 0)
    static let control = OpenSpeechShortcutModifiers(rawValue: 1 << 1)
    static let option = OpenSpeechShortcutModifiers(rawValue: 1 << 2)
    static let shift = OpenSpeechShortcutModifiers(rawValue: 1 << 3)
    static let function = OpenSpeechShortcutModifiers(rawValue: 1 << 4)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }
}

enum OpenSpeechShortcutBindingKind: String, Decodable {
    case disabled
    case key
    case modifierKey
}

struct OpenSpeechStoredShortcut: Decodable {
    let keyCode: UInt16
    let keyDisplay: String
    let kind: OpenSpeechShortcutBindingKind
    let modifiers: OpenSpeechShortcutModifiers
    let exactModifierKeyCodes: Set<UInt16>?

    var displayName: String {
        if kind == .disabled { return "Disabled" }
        let modifierNames = orderedExtraModifierKeyCodes.compactMap(Self.modifierDisplayName)
        return (modifierNames + [keyDisplay]).joined(separator: " + ")
    }

    var orderedExtraModifierKeyCodes: [UInt16] {
        var keyCodes = exactModifierKeyCodes ?? Self.exactModifierKeyCodes(for: modifiers)
        if kind == .modifierKey {
            keyCodes.remove(keyCode)
        }
        return Self.modifierDisplayOrder.filter(keyCodes.contains)
    }

    private static let modifierDisplayOrder: [UInt16] = [55, 54, 59, 62, 58, 61, 56, 60, 63]

    private static func exactModifierKeyCodes(for modifiers: OpenSpeechShortcutModifiers) -> Set<UInt16> {
        var keyCodes: Set<UInt16> = []
        if modifiers.contains(.command) { keyCodes.insert(55) }
        if modifiers.contains(.control) { keyCodes.insert(59) }
        if modifiers.contains(.option) { keyCodes.insert(58) }
        if modifiers.contains(.shift) { keyCodes.insert(56) }
        if modifiers.contains(.function) { keyCodes.insert(63) }
        return keyCodes
    }

    private static func modifierDisplayName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55:
            return "Cmd"
        case 54:
            return "Right Cmd"
        case 59:
            return "Ctrl"
        case 62:
            return "Right Ctrl"
        case 58:
            return "Option"
        case 61:
            return "Right Option"
        case 56:
            return "Shift"
        case 60:
            return "Right Shift"
        case 63:
            return "Fn"
        default:
            return nil
        }
    }
}
