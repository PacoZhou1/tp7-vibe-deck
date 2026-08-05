import Foundation
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        LiquidGlassGroup {
            VStack(alignment: .leading, spacing: 14) {
                Text("Status")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                StatusRow(
                    title: "TP-7 Audio",
                    detail: store.hasTP7Audio ? "Connected" : "Missing",
                    systemImage: store.hasTP7Audio ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                StatusRow(
                    title: "TP-7 MIDI In",
                    detail: store.hasTP7MIDI ? "Connected" : "Missing",
                    systemImage: store.hasTP7MIDI ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                StatusRow(
                    title: "TP-7 MIDI Out",
                    detail: store.hasTP7MIDIOutput ? (store.midiOutputActive ? "Activated" : "Available") : "Missing",
                    systemImage: store.hasTP7MIDIOutput ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                StatusRow(
                    title: "Accessibility",
                    detail: store.accessibilityTrusted ? "Enabled" : "Needs permission",
                    systemImage: store.accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised"
                )
                StatusRow(
                    title: "Wheel",
                    detail: "\(store.mappingProfile.wheel.mode.title) \(String(format: "%.2fx", store.mappingProfile.wheel.sensitivity))",
                    systemImage: "dial.medium"
                )
                StatusRow(
                    title: "Open Speech Hold",
                    detail: store.openSpeechHoldShortcut,
                    systemImage: "record.circle"
                )
                StatusRow(
                    title: "Open Speech Toggle",
                    detail: store.openSpeechToggleShortcut,
                    systemImage: "switch.2"
                )

                Spacer(minLength: 0)
            }
            .padding(14)
            .liquidGlassPanel(cornerRadius: 24)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(systemImage == "checkmark.circle.fill" ? .primary : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
