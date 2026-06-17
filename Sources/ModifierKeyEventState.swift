import AppKit

enum ModifierKeyEventState {
    static func isKeyDown(for event: NSEvent) -> Bool? {
        guard let mappedFlag = mappedFlag(for: event.keyCode) else {
            return nil
        }
        return event.modifierFlags.contains(mappedFlag)
    }

    static func pressedModifierKeyCodes(
        for event: NSEvent,
        trustedFunctionKeyIsDown: Bool? = nil
    ) -> Set<UInt16> {
        ShortcutBinding.modifierKeyCodes.filter { keyCode in
            // macOS sets NSEvent.ModifierFlags.function for arrow keys, F-keys,
            // and navigation keys (Home/End/Page Up/Page Down/Forward Delete)
            // regardless of whether the physical Fn key is held. When the caller
            // can provide an authoritative Fn-down state (tracked from
            // flagsChanged events), prefer it over the unreliable event flag.
            if keyCode == fnKeyCode, let trustedFunctionKeyIsDown {
                return trustedFunctionKeyIsDown
            }
            guard let mappedFlag = mappedFlag(for: keyCode) else {
                return false
            }
            return event.modifierFlags.contains(mappedFlag)
        }
    }

    static let fnKeyCode: UInt16 = 63

    /// Reads the current system-wide Fn state. Useful for seeding a backend's
    /// tracked Fn state at start or after a tap reset, since flagsChanged events
    /// don't fire for keys already held when a monitor begins.
    static func currentFunctionKeyIsDown() -> Bool {
        NSEvent.modifierFlags.contains(.function)
    }

    private static func mappedFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54:
            return .rightCommand
        case 55:
            return .leftCommand
        case 56:
            return .leftShift
        case 58:
            return .leftOption
        case 59:
            return .leftControl
        case 60:
            return .rightShift
        case 61:
            return .rightOption
        case 62:
            return .rightControl
        case 63:
            return .function
        default:
            return nil
        }
    }
}

private extension NSEvent.ModifierFlags {
    // Raw device-side modifier bits formerly exposed as Carbon HIToolbox
    // NX_DEVICE* masks. Keeping the values here preserves left/right modifier
    // shortcut behavior without linking the deprecated Carbon framework.
    static let leftControl = Self(rawValue: 0x0000_0001)
    static let leftShift = Self(rawValue: 0x0000_0002)
    static let rightShift = Self(rawValue: 0x0000_0004)
    static let leftCommand = Self(rawValue: 0x0000_0008)
    static let rightCommand = Self(rawValue: 0x0000_0010)
    static let leftOption = Self(rawValue: 0x0000_0020)
    static let rightOption = Self(rawValue: 0x0000_0040)
    static let rightControl = Self(rawValue: 0x0000_2000)
}
