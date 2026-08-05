import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Open at Login",
                    isOn: Binding {
                        store.launchAtLoginEnabled
                    } set: {
                        store.setLaunchAtLoginEnabled($0)
                    }
                )
                Text("Start TP7 Vibe Deck automatically after you sign in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(store.accessibilityTrusted ? "Enabled" : "Needs permission")
                        .foregroundStyle(.secondary)
                    Button("Open Prompt") {
                        store.requestAccessibilityPermission()
                    }
                }

                Button("Request Microphone Permission") {
                    store.requestMicrophonePermission()
                }
            }

            Section("Open Speech") {
                HStack {
                    Text("Hold Shortcut")
                    Spacer()
                    Text(store.openSpeechHoldShortcut)
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        store.refreshOpenSpeechShortcut()
                    }
                }
            }

            Section("TP-7 Controls") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Wheel Sensitivity")
                        Spacer()
                        Text("\(store.mappingProfile.wheel.sensitivity, specifier: "%.2f")x")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding {
                            store.mappingProfile.wheel.sensitivity
                        } set: {
                            store.updateWheel(sensitivity: $0)
                        },
                        in: 0.25...4.0,
                        step: 0.25
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480)
        .onAppear {
            store.refreshLaunchAtLoginStatus()
        }
    }
}
