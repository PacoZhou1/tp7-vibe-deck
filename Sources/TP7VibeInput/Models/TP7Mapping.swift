import CoreGraphics
import Foundation

enum TP7InputRole: String, Codable, CaseIterable, Identifiable {
    case rec
    case play
    case stop
    case plus
    case minus
    case sideForward
    case sideBackward
    case memo
    case menu
    case wheel
    case learned1
    case learned2
    case learned3
    case learned4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rec: "REC"
        case .play: "PLAY"
        case .stop: "STOP"
        case .plus: "+"
        case .minus: "-"
        case .sideForward: "Side Forward"
        case .sideBackward: "Side Backward"
        case .memo: "Memo"
        case .menu: "Menu"
        case .wheel: "Wheel"
        case .learned1: "Learned 1"
        case .learned2: "Learned 2"
        case .learned3: "Learned 3"
        case .learned4: "Learned 4"
        }
    }

    var systemImage: String {
        switch self {
        case .rec: "record.circle"
        case .play: "play.fill"
        case .stop: "stop.fill"
        case .plus: "plus"
        case .minus: "minus"
        case .sideForward: "forward.fill"
        case .sideBackward: "backward.fill"
        case .memo: "waveform.badge.mic"
        case .menu: "line.3.horizontal"
        case .wheel: "dial.medium"
        case .learned1, .learned2, .learned3, .learned4: "sparkle.magnifyingglass"
        }
    }

    var isWheel: Bool { self == .wheel }

    var defaultSignature: MIDIInputSignature? {
        switch self {
        case .rec: .controlChange(channel: 1, controller: 22)
        case .play: .controlChange(channel: 1, controller: 23)
        case .stop: .controlChange(channel: 1, controller: 24)
        case .minus: .controlChange(channel: 1, controller: 25)
        case .plus: .controlChange(channel: 1, controller: 26)
        case .memo: .controlChange(channel: 1, controller: 27)
        case .menu: .controlChange(channel: 1, controller: 28)
        case .wheel: .controlChange(channel: 1, controller: 30)
        default: nil
        }
    }

    static let primaryButtons: [TP7InputRole] = [
        .rec, .play, .stop, .plus, .minus, .sideForward, .sideBackward, .memo, .menu
    ]

    static let learnableButtons: [TP7InputRole] = [
        .plus, .minus, .sideForward, .sideBackward, .memo, .menu, .learned1, .learned2, .learned3, .learned4
    ]
}

enum MIDIInputSignature: Codable, Hashable {
    case controlChange(channel: Int, controller: UInt8)
    case note(channel: Int, note: UInt8)

    var title: String {
        switch self {
        case let .controlChange(channel, controller):
            "CC ch\(channel) #\(controller)"
        case let .note(channel, note):
            "Note ch\(channel) #\(note)"
        }
    }

    init?(event: TP7ControlEvent) {
        switch event.kind {
        case let .controlChange(channel, controller, _):
            self = .controlChange(channel: channel, controller: controller)
        case let .note(channel, note, _, _):
            self = .note(channel: channel, note: note)
        case .pitchBend, .raw:
            return nil
        }
    }

    func matches(_ event: TP7ControlEvent) -> Bool {
        switch (self, event.kind) {
        case let (.controlChange(channel, controller), .controlChange(eventChannel, eventController, _)):
            channel == eventChannel && controller == eventController
        case let (.note(channel, note), .note(eventChannel, eventNote, _, _)):
            channel == eventChannel && note == eventNote
        default:
            false
        }
    }
}

enum TP7ActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    case openSpeechHold
    case openSpeechToggle
    case openSpeechPreset
    case openSpeechNextPreset
    case openSpeechPreviousPreset
    case commandC
    case commandV
    case returnKey
    case clearText
    case cursorLeftHold
    case cursorRightHold
    case verticalScroll
    case launchHermesAgent
    case launchHermesOpenSpeechHold
    case customShortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No Action"
        case .openSpeechHold: "Open Speech Hold"
        case .openSpeechToggle: "Open Speech Toggle"
        case .openSpeechPreset: "Open Speech Preset"
        case .openSpeechNextPreset: "Next Preset"
        case .openSpeechPreviousPreset: "Previous Preset"
        case .commandC: "Command-C"
        case .commandV: "Command-V"
        case .returnKey: "Return"
        case .clearText: "Delete / Clear Text"
        case .cursorLeftHold: "Hold Cursor Left"
        case .cursorRightHold: "Hold Cursor Right"
        case .verticalScroll: "Vertical Scroll"
        case .launchHermesAgent: "Launch Hermes Agent"
        case .launchHermesOpenSpeechHold: "Hermes + Open Speech Hold"
        case .customShortcut: "Custom Shortcut"
        }
    }
}

struct TP7ActionConfig: Codable, Equatable {
    var kind: TP7ActionKind
    var presetID: String?
    var shortcut: ShortcutBinding?
    var cursorSpeed: CursorMoveSpeed?
    var scrollSensitivity: Double?

    static let none = TP7ActionConfig(kind: .none)
    static let openSpeechHold = TP7ActionConfig(kind: .openSpeechHold)
    static let openSpeechToggle = TP7ActionConfig(kind: .openSpeechToggle)
    static let commandC = TP7ActionConfig(kind: .commandC)
    static let commandV = TP7ActionConfig(kind: .commandV)
    static let returnKey = TP7ActionConfig(kind: .returnKey)
    static let clearText = TP7ActionConfig(kind: .clearText)
    static let cursorLeftHold = TP7ActionConfig(kind: .cursorLeftHold, cursorSpeed: .medium)
    static let cursorRightHold = TP7ActionConfig(kind: .cursorRightHold, cursorSpeed: .medium)
    static let verticalScroll = TP7ActionConfig(kind: .verticalScroll, scrollSensitivity: 1.0)
    static let launchHermesAgent = TP7ActionConfig(kind: .launchHermesAgent)
    static let launchHermesOpenSpeechHold = TP7ActionConfig(kind: .launchHermesOpenSpeechHold)

    var displayTitle: String {
        switch kind {
        case .openSpeechPreset:
            "Preset \(presetID?.uppercased() ?? "A")"
        case .customShortcut:
            shortcut?.displayName ?? kind.title
        default:
            kind.title
        }
    }
}

enum CursorMoveSpeed: String, Codable, CaseIterable, Identifiable {
    case slow
    case medium
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow: "Low"
        case .medium: "Medium"
        case .fast: "High"
        }
    }

    var tickInterval: TimeInterval {
        switch self {
        case .slow: 0.18
        case .medium: 0.11
        case .fast: 0.065
        }
    }

    var firstRepeatDelay: TimeInterval {
        switch self {
        case .slow: 0.42
        case .medium: 0.36
        case .fast: 0.20
        }
    }

    var wheelStepCount: Int {
        switch self {
        case .slow: 1
        case .medium: 3
        case .fast: 5
        }
    }

    func repeatCount(elapsed: TimeInterval) -> Int {
        switch self {
        case .slow:
            switch elapsed {
            case ..<0.9: return 1
            case ..<2.0: return 1
            case ..<3.5: return 2
            case ..<5.0: return 3
            default: return 4
            }
        case .medium:
            switch elapsed {
            case ..<0.7: return 1
            case ..<1.5: return 2
            case ..<2.6: return 3
            case ..<4.0: return 5
            default: return 8
            }
        case .fast:
            switch elapsed {
            case ..<0.5: return 2
            case ..<1.0: return 4
            case ..<1.8: return 6
            case ..<3.0: return 10
            default: return 14
            }
        }
    }
}

enum WheelMode: String, Codable, CaseIterable, Identifiable {
    case verticalScroll
    case horizontalScroll
    case cursorMove
    case volume
    case brightness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verticalScroll: "Vertical Scroll"
        case .horizontalScroll: "Horizontal Scroll"
        case .cursorMove: "Cursor Left / Right"
        case .volume: "Volume"
        case .brightness: "Brightness"
        }
    }
}

struct WheelMapping: Codable, Equatable {
    var mode: WheelMode = .verticalScroll
    var sensitivity: Double = 1.0
    var inverted = false
    var cursorSpeed: CursorMoveSpeed = .medium
}

struct TP7ButtonMapping: Codable, Identifiable, Equatable {
    var id: TP7InputRole { role }
    var role: TP7InputRole
    var signature: MIDIInputSignature?
    var action: TP7ActionConfig
}

struct TP7MappingProfile: Codable, Equatable {
    var buttons: [TP7ButtonMapping]
    var wheel: WheelMapping

    static let defaults = TP7MappingProfile(
        buttons: TP7InputRole.primaryButtons.map { role in
            TP7ButtonMapping(
                role: role,
                signature: role.defaultSignature,
                action: {
                    switch role {
                    case .rec: .openSpeechHold
                    case .play: .openSpeechToggle
                    case .stop: .returnKey
                    case .sideForward: .verticalScroll
                    case .sideBackward: .verticalScroll
                    case .memo: .launchHermesOpenSpeechHold
                    case .menu: .clearText
                    default: .none
                    }
                }()
            )
        },
        wheel: WheelMapping(mode: .cursorMove, sensitivity: 1.0, inverted: false, cursorSpeed: .slow)
    )

    func mapping(for role: TP7InputRole) -> TP7ButtonMapping? {
        buttons.first { $0.role == role }
    }

    mutating func updateMapping(_ mapping: TP7ButtonMapping) {
        if let index = buttons.firstIndex(where: { $0.role == mapping.role }) {
            buttons[index] = mapping
        } else {
            buttons.append(mapping)
        }
    }

    func role(for signature: MIDIInputSignature) -> TP7InputRole? {
        buttons.first { $0.signature == signature }?.role
    }
}

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiersRawValue: UInt64
    var keyDisplay: String

    var flags: CGEventFlags {
        CGEventFlags(rawValue: modifiersRawValue)
    }

    var displayName: String {
        var parts: [String] = []
        if flags.contains(.maskCommand) { parts.append("Cmd") }
        if flags.contains(.maskControl) { parts.append("Ctrl") }
        if flags.contains(.maskAlternate) { parts.append("Option") }
        if flags.contains(.maskShift) { parts.append("Shift") }
        if flags.contains(.maskSecondaryFn) { parts.append("Fn") }
        parts.append(keyDisplay)
        return parts.joined(separator: " + ")
    }

    static let commandC = ShortcutBinding(keyCode: 8, modifiersRawValue: CGEventFlags.maskCommand.rawValue, keyDisplay: "C")
    static let commandV = ShortcutBinding(keyCode: 9, modifiersRawValue: CGEventFlags.maskCommand.rawValue, keyDisplay: "V")
    static let selectAll = ShortcutBinding(keyCode: 0, modifiersRawValue: CGEventFlags.maskCommand.rawValue, keyDisplay: "A")
    static let returnKey = ShortcutBinding(keyCode: 36, modifiersRawValue: 0, keyDisplay: "Return")
}
