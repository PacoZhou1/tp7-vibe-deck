import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem

final class TextInjector {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendShortcut(.commandV)
    }

    func pressCopy() {
        sendShortcut(.commandC)
    }

    func pressPaste() {
        sendShortcut(.commandV)
    }

    func pressReturn() {
        sendShortcut(.returnKey)
    }

    func clearText() {
        sendShortcut(.selectAll)
        sendKey(keyCode: 51, flags: [])
    }

    func pressLeftArrow(repeatCount: Int = 1) {
        pressKey(keyCode: 123, repeatCount: repeatCount)
    }

    func pressRightArrow(repeatCount: Int = 1) {
        pressKey(keyCode: 124, repeatCount: repeatCount)
    }

    func sendShortcut(_ shortcut: ShortcutBinding) {
        sendKey(keyCode: CGKeyCode(shortcut.keyCode), flags: shortcut.flags)
    }

    func scroll(vertical: Int32 = 0, horizontal: Int32 = 0) {
        guard vertical != 0 || horizontal != 0,
              let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
              ) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    func adjustVolume(steps: Int) {
        postSystemKey(steps >= 0 ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN, repeatCount: min(abs(steps), 8))
    }

    func adjustBrightness(steps: Int) {
        postSystemKey(steps >= 0 ? NX_KEYTYPE_BRIGHTNESS_UP : NX_KEYTYPE_BRIGHTNESS_DOWN, repeatCount: min(abs(steps), 8))
    }

    private func sendKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func pressKey(keyCode: CGKeyCode, repeatCount: Int) {
        guard repeatCount > 0 else { return }
        for _ in 0..<repeatCount {
            sendKey(keyCode: keyCode, flags: [])
        }
    }

    private func postSystemKey(_ key: Int32, repeatCount: Int) {
        guard repeatCount > 0 else { return }
        for _ in 0..<repeatCount {
            postSystemKey(key, isDown: true)
            postSystemKey(key, isDown: false)
        }
    }

    private func postSystemKey(_ key: Int32, isDown: Bool) {
        let flags = isDown ? 0xA00 : 0xB00
        let data1 = (Int(key) << 16) | flags
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent else {
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
