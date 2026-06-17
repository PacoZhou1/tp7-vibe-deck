import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var recentHistoryItems: [PipelineHistoryItem] {
        Array(appState.pipelineHistory.filter { !transcriptText(for: $0).isEmpty }.prefix(10))
    }

    private func transcriptText(for item: PipelineHistoryItem) -> String {
        let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        return item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFull(for item: PipelineHistoryItem) -> String {
        if !item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    private func transcriptSnippet(for item: PipelineHistoryItem) -> String {
        let text = transcriptText(for: item)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "(无内容)" }
        return text.count > 48 ? String(text.prefix(48)) + "..." : text
    }

    private func copyTranscriptToPasteboard(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func openRunLog() {
        appState.selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(AppName.displayName) v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            Divider()

            // Status
            if appState.isRecording {
                Label("录音中...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label(appState.debugStatusMessage, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Text(appState.shortcutStatusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            Button(appState.hasCompletedOnboarding ? "新手指引" : "打开新手指引") {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }

            Divider()

            Menu("识别引擎") {
                ForEach(ASREngineMode.allCases) { mode in
                    Button {
                        appState.asrEngineMode = mode
                    } label: {
                        if appState.asrEngineMode == mode {
                            Text("✓ \(mode.menuTitle)")
                        } else {
                            Text("  \(mode.menuTitle)")
                        }
                    }
                }
            }

            // Manual toggle
            Button(appState.isRecording ? "停止录音" : "开始录音") {
                appState.toggleRecording()
            }
            .disabled(appState.isTranscribing)

            if let hotkeyError = appState.hotkeyMonitoringErrorMessage {
                Divider()
                Text(hotkeyError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            Divider()

            if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                Text(appState.lastTranscript.count > 35
                    ? String(appState.lastTranscript.prefix(35)) + "…"
                    : appState.lastTranscript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .lineLimit(4)
                    .frame(maxWidth: 280, alignment: .leading)

                Button("复制最近识别") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.lastTranscript, forType: .string)
                }
            }

            Menu("历史记录") {
                if recentHistoryItems.isEmpty {
                    Text("暂无记录")
                } else {
                    ForEach(recentHistoryItems) { item in
                        let transcript = transcriptText(for: item)
                        Button {
                            copyTranscriptToPasteboard(transcriptFull(for: item))
                        } label: {
                            Text(transcriptSnippet(for: item))
                        }
                        .disabled(transcript.isEmpty)
                    }

                    Divider()
                }

                Button("打开运行日志") {
                    openRunLog()
                }
            }

            Divider()

            Menu("长按识别") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .hold)
                } label: {
                    if appState.holdShortcut.isDisabled {
                        Text("✓ 已禁用")
                    } else {
                        Text("  已禁用")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .hold)
                    } label: {
                        if appState.holdShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.toggleShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .hold) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .hold)
                    } label: {
                        if appState.holdShortcut == savedCustomShortcut {
                            Text("✓ 自定义: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  自定义: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("自定义...") {
                    appState.selectedSettingsTab = .general
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("点击触发") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .toggle)
                } label: {
                    if appState.toggleShortcut.isDisabled {
                        Text("✓ 已禁用")
                    } else {
                        Text("  已禁用")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .toggle)
                    } label: {
                        if appState.toggleShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.holdShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .toggle) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .toggle)
                    } label: {
                        if appState.toggleShortcut == savedCustomShortcut {
                            Text("✓ 自定义: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  自定义: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("自定义...") {
                    appState.selectedSettingsTab = .general
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("麦克风") {
                Button {
                    appState.selectedMicrophoneID = "default"
                } label: {
                    if appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty {
                        Text("✓ 系统默认")
                    } else {
                        Text("  系统默认")
                    }
                }
                ForEach(appState.availableMicrophones) { device in
                    Button {
                        appState.selectedMicrophoneID = device.uid
                    } label: {
                        if appState.selectedMicrophoneID == device.uid {
                            Text("✓ \(device.name)")
                        } else {
                            Text("  \(device.name)")
                        }
                    }
                }
            }

            Menu("提示词预设") {
                let activePreset = appState.activeSystemPromptPreset()
                ForEach(SystemPromptPreset.allCases) { preset in
                    Button {
                        appState.applySystemPromptPreset(preset)
                    } label: {
                        let name = appState.systemPromptPresetName(for: preset)
                        if activePreset == preset {
                            Text("✓ \(name)")
                        } else {
                            Text("  \(name)")
                        }
                    }
                }
            }

            Button("设置") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }

            Divider()

            Button("退出 \(AppName.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}
