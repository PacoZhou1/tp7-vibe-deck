import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - Shared Helpers

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private let iso8601DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private enum APIConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded(String)
    case failed(String)
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.visibleCases) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        SettingsSidebarRow(title: tab.title, icon: tab.icon)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.selectedSettingsTab == tab
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .prompts:
                    PromptsSettingsView()
                case .macros:
                    VoiceMacrosSettingsView()
                case .runLog:
                    RunLogView()
                case .debug:
                    DebugSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 16, height: 16, alignment: .center)
                .foregroundStyle(.primary)

            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
}

// MARK: - Debug Settings

struct DebugSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Debug")
                    .font(.largeTitle.bold())

                SettingsCard("Overlay", icon: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show the recording overlay with simulated audio levels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                            appState.toggleDebugOverlay()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @State private var apiKeyInput: String = ""
    @State private var apiBaseURLInput: String = ""
    @State private var customLLMModelInput: String = ""
    @State private var customLLMContextLimitInput: String = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var keyValidationSuccess = false
    @State private var customLLMTestState: APIConnectionTestState = .idle
    @State private var customVocabularyInput: String = ""
    @State private var micPermissionGranted = false
    @State private var showMutedHint = false
    @State private var copiedBuildInfo = false
    @State private var copiedBuildInfoResetWorkItem: DispatchWorkItem?

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "\(AppName.displayName)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "FreeFlowBuildTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var appArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var buildDiagnosticsText: String {
        "\(appDisplayName) \(appVersion) (\(appBuildNumber))\nmacOS \(macOSVersion) (\(appArchitecture))"
    }

    private var qwen3ASRStatusIcon: String {
        switch appState.qwen3ASRLoadState {
        case .idle:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
        case .loading:
            return "gearshape.2"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var qwen3ASRStatusColor: Color {
        switch appState.qwen3ASRLoadState {
        case .ready:
            return .green
        case .failed:
            return .red
        case .downloading, .loading:
            return .blue
        case .idle:
            return .secondary
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App branding header
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text(AppName.displayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))

                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Presented by Paco")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 4)

                SettingsCard("新手指引", icon: "questionmark.circle.fill") {
                    onboardingSection
                }
                SettingsCard("App", icon: "power") {
                    startupSection
                }
                SettingsCard("识别引擎", icon: "waveform.badge.magnifyingglass") {
                    apiKeySection
                }
                SettingsCard("输出语言", icon: "globe") {
                    outputLanguageSection
                }
                SettingsCard("快捷键", icon: "keyboard.fill") {
                    hotkeySection
                }
                SettingsCard("录音时静音", icon: "speaker.slash.fill") {
                    dictationAudioSection
                }
                SettingsCard("Edit Mode", icon: "pencil") {
                    commandModeSection
                }
                SettingsCard("剪贴板", icon: "doc.on.clipboard") {
                    clipboardSection
                }
                SettingsCard("麦克风", icon: "mic.fill") {
                    microphoneSection
                }
                SettingsCard("音量", icon: "speaker.wave.2.fill") {
                    soundVolumeSection
                }
                SettingsCard("自定义词库", icon: "text.book.closed.fill") {
                    vocabularySection
                }
                SettingsCard("权限", icon: "lock.shield.fill") {
                    permissionsSection
                }
                SettingsCard("关于", icon: "info.circle.fill") {
                    buildInfoSection
                }
            }
            .padding(24)
        }
        .onAppear {
            apiKeyInput = appState.apiKey
            apiBaseURLInput = appState.apiBaseURL
            customLLMModelInput = appState.postProcessingModel
            customLLMContextLimitInput = "\(appState.customLLMContextLimit)"
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
            appState.refreshLaunchAtLoginStatus()
        }
        .onChange(of: appState.postProcessingModel) { _, value in
            if customLLMModelInput != value {
                customLLMModelInput = value
            }
        }
        .onChange(of: appState.customLLMContextLimit) { _, value in
            customLLMContextLimitInput = "\(value)"
        }
    }

    // MARK: Onboarding

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("重新打开首次使用导览，快速检查状态栏入口、权限、快捷键和测试转录流程。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                onboardingStatusPill(
                    title: "麦克风",
                    granted: micPermissionGranted,
                    icon: "mic.fill"
                )
                onboardingStatusPill(
                    title: "键盘监听",
                    granted: appState.hasKeyboardMonitoringPermission,
                    icon: "keyboard"
                )
                onboardingStatusPill(
                    title: "快捷键",
                    granted: appState.hasEnabledHoldShortcut || appState.hasEnabledToggleShortcut,
                    icon: "keyboard"
                )
                Spacer()
            }

            Button {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            } label: {
                Label("打开新手指引", systemImage: "arrow.up.right.square")
            }
            .font(.caption)
        }
    }

    private func onboardingStatusPill(title: String, granted: Bool, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .foregroundStyle(granted ? .green : .secondary)
            Text(title)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill((granted ? Color.green : Color.secondary).opacity(0.10)))
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("开机自动启动", isOn: $appState.launchAtLogin)
            Toggle("顶部菜单栏图标", isOn: $showMenuBarIcon)

            if SMAppService.mainApp.status == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("需要先在系统设置中批准登录项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打开登录项设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Build

    private var buildInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Build number")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(appBuildNumber)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 12) {
                Text(buildDiagnosticsText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    copyBuildDiagnostics()
                } label: {
                    Label(copiedBuildInfo ? "Copied" : "Copy", systemImage: copiedBuildInfo ? "checkmark" : "doc.on.doc")
                }
                .font(.caption)
            }
        }
    }

    private func copyBuildDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildDiagnosticsText, forType: .string)
        copiedBuildInfo = true

        copiedBuildInfoResetWorkItem?.cancel()

        let resetWorkItem = DispatchWorkItem {
            copiedBuildInfo = false
            copiedBuildInfoResetWorkItem = nil
        }
        copiedBuildInfoResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("识别引擎", selection: $appState.asrEngineMode) {
                ForEach(ASREngineMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: appState.asrEngineMode.systemImage)
                    .foregroundStyle(.blue)
                    .frame(width: 18)
                Text(appState.asrEngineMode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch appState.asrEngineMode {
            case .qwenNative:
                qwenNativeStatusSection
            case .senseVoiceGemma:
                senseVoiceGemmaStatusSection
            case .thirdPartyAPI:
                thirdPartyAPISettingsSection
            }
        }
    }

    private var qwenNativeStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: qwen3ASRStatusIcon)
                    .foregroundStyle(qwen3ASRStatusColor)
                Text("Qwen3-ASR：\(appState.qwen3ASRLoadState.displayText)")
                    .font(.caption.weight(.semibold))
            }
            if appState.qwen3ASRLoadState.progress > 0,
               appState.qwen3ASRLoadState.progress < 1 {
                ProgressView(value: appState.qwen3ASRLoadState.progress)
                    .controlSize(.small)
            }
            Text("当前包内置 Qwen3-ASR-1.7B 4bit 模型；识别完成后会用本地 Gemma E4B 执行提示词、纠错和常用词库。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label("本地纠错：Gemma E4B 会读取「提示词」和「常用词库」设置。", systemImage: "wand.and.stars")
                .foregroundStyle(.green)
                .font(.caption)

            Text("此模式会启动打包内 Python 后端，但只加载 Gemma 纠错模型，不加载 SenseVoice ASR。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var senseVoiceGemmaStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本地后端：SenseVoice ASR + Gemma E4B", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text("切到此模式时会启动打包内的 Python 后端；如果模型加载超时或异常退出，会在前端弹出明确错误。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var thirdPartyAPISettingsSection: some View {
        customLLMAPISettingsSection(
            title: "第三方 API：音频识别 + LLM 纠错",
            systemImage: "network",
            description: nil
        )
    }

    private func customLLMAPISettingsSection(
        title: String,
        systemImage: String,
        description: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.green)
                .font(.caption)

            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("上下文长度限制")
                    .font(.caption.weight(.semibold))

                HStack(spacing: 8) {
                    TextField("\(AppState.defaultCustomLLMContextLimit)", text: $customLLMContextLimitInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 180)
                        .onSubmit {
                            commitCustomLLMContextLimit()
                        }
                        .onChange(of: customLLMContextLimitInput) { _, value in
                            let filtered = value.filter { $0.isNumber }
                            if filtered != value {
                                customLLMContextLimitInput = filtered
                            }
                        }

                    Stepper(
                        "",
                        value: $appState.customLLMContextLimit,
                        in: AppState.minCustomLLMContextLimit...AppState.maxCustomLLMContextLimit,
                        step: 512
                    )
                    .labelsHidden()
                }

                Text("默认 8192。长文本失败时可以调低，例如 4096；模型稳定且内存充足时可以调高。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Base URL")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("填写 API Base URL", text: $apiBaseURLInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit {
                                commitCustomLLMSettings()
                            }
                            .onChange(of: apiBaseURLInput) { _, value in
                                appState.apiBaseURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                customLLMTestState = .idle
                            }

                        Button {
                            testCustomLLMConnection()
                        } label: {
                            Image(systemName: customLLMTestIcon)
                                .frame(width: 16, height: 16)
                        }
                        .help("测试 API 端口")
                        .disabled(customLLMTestState == .testing)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Model ID")
                        .font(.caption.weight(.semibold))
                    TextField("deepseek-v4-flash", text: $customLLMModelInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            commitCustomLLMSettings()
                            }
                        .onChange(of: customLLMModelInput) { _, value in
                            let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            appState.postProcessingModel = model
                            appState.postProcessingFallbackModel = model
                            customLLMTestState = .idle
                        }
                }

                HStack(spacing: 8) {
                    SecureField("API key (本地模型可填 local)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isValidatingKey)
                        .onChange(of: apiKeyInput) { _, _ in
                            keyValidationError = nil
                            keyValidationSuccess = false
                        }

                    Button(isValidatingKey ? "Saving..." : "Save") {
                        validateAndSaveKey()
                    }
                    .disabled(isValidatingKey)
                }

                customLLMTestStatus
            }

            if let error = keyValidationError {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if keyValidationSuccess {
                Label("API settings saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    private var customLLMTestIcon: String {
        switch customLLMTestState {
        case .idle:
            "network"
        case .testing:
            "hourglass"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        }
    }

    @ViewBuilder
    private var customLLMTestStatus: some View {
        switch customLLMTestState {
        case .idle:
            EmptyView()
        case .testing:
            Label("正在测试模型反馈...", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .succeeded(let message):
            Label("模型有反馈：\(message)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func commitCustomLLMSettings() {
        let baseURL = apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = customLLMModelInput.trimmingCharacters(in: .whitespacesAndNewlines)

        apiBaseURLInput = baseURL
        customLLMModelInput = model
        appState.apiBaseURL = baseURL
        appState.postProcessingModel = model
        appState.postProcessingFallbackModel = model
    }

    private func commitCustomLLMContextLimit() {
        let value = Int(customLLMContextLimitInput.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? AppState.defaultCustomLLMContextLimit
        let normalized = AppState.normalizedCustomLLMContextLimit(value)
        customLLMContextLimitInput = "\(normalized)"
        appState.customLLMContextLimit = normalized
    }

    private func testCustomLLMConnection() {
        commitCustomLLMSettings()
        guard !apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            customLLMTestState = .failed("请先填写 API Base URL")
            return
        }
        guard !customLLMModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            customLLMTestState = .failed("请先填写 Model ID")
            return
        }
        customLLMTestState = .testing

        Task {
            do {
                let response = try await PostProcessingService.testConnection(
                    apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                    baseURL: apiBaseURLInput,
                    model: customLLMModelInput
                )
                let snippet = shortStatusSnippet(response)
                await MainActor.run {
                    customLLMTestState = .succeeded(snippet)
                }
            } catch {
                await MainActor.run {
                    customLLMTestState = .failed("测试失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func shortStatusSnippet(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= 120 {
            return singleLine
        }
        return String(singleLine.prefix(120)) + "..."
    }

    private func validateAndSaveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        commitCustomLLMSettings()
        let resolvedBaseURL = apiBaseURLInput
        guard !resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            keyValidationError = "请先填写 API Base URL"
            keyValidationSuccess = false
            return
        }
        isValidatingKey = true
        keyValidationError = nil
        keyValidationSuccess = false

        Task {
            // Local server — skip API key validation
            if resolvedBaseURL.contains("127.0.0.1") || resolvedBaseURL.contains("localhost") {
                await MainActor.run {
                    isValidatingKey = false
                    appState.apiKey = key
                    keyValidationSuccess = true
                }
                return
            }
            let valid = await TranscriptionService.validateAPIKey(
                key,
                baseURL: resolvedBaseURL
            )
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    keyValidationSuccess = true
                } else {
                    keyValidationError = "Validation failed. Please check your API key and provider settings, then try again."
                }
            }
        }
    }

    // MARK: Output Language

    private static let outputLanguageOptions = [
        "",
        "英语",
        "简体中文",
        "繁体中文",
        "西班牙语",
        "法语",
        "日语",
        "韩语",
        "德语",
        "葡萄牙语",
    ]

    private var outputLanguageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("语言", selection: $appState.outputLanguage) {
                Text("与说话语言相同").tag("")
                ForEach(Self.outputLanguageOptions.dropFirst(), id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
            .pickerStyle(.menu)

            Text("When set, OPEN SPEECH translates your speech into the selected language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Dictation Shortcuts

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DictationShortcutEditor { isCapturing in
                if isCapturing {
                    appState.suspendHotkeyMonitoringForShortcutCapture()
                } else {
                    appState.resumeHotkeyMonitoringAfterShortcutCapture()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("快捷键启动延迟")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(appState.shortcutStartDelayMilliseconds) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $appState.shortcutStartDelay,
                    in: 0...0.5,
                    step: 0.025
                )

                Text("适用于长按和点击两种触发方式，停止仍然即时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dictationAudioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "录制开始时系统静音",
                isOn: $appState.dictationAudioInterruptionEnabled
            )

            Text("录制结束后自动恢复之前的音量状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commandModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("内容跟随联想纠正", isOn: Binding(
                get: { appState.isCommandModeEnabled },
                set: { newValue in
                    _ = appState.setCommandModeEnabled(newValue)
                }
            ))

            Text("选中文本后，通过语音指令对其进行转换而非覆盖录入。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("触发方式", selection: Binding(
                get: { appState.commandModeStyle },
                set: { newValue in
                    _ = appState.setCommandModeStyle(newValue)
                }
            )) {
                ForEach(CommandModeStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!appState.isCommandModeEnabled)

            Group {
                switch appState.commandModeStyle {
                case .automatic:
                    Text("选中文本后，正常录音快捷键将转换所选内容而非覆盖录入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .manual:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("按住额外修饰键同时按下录音快捷键来转换选中文本。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Extra Modifier", selection: Binding(
                            get: { appState.commandModeManualModifier },
                            set: { newValue in
                                _ = appState.setCommandModeManualModifier(newValue)
                            }
                        )) {
                            ForEach(CommandModeManualModifier.allCases) { modifier in
                                Text(modifier.title).tag(modifier)
                            }
                        }
                        .disabled(!appState.isCommandModeEnabled || appState.commandModeStyle != .manual)
                    }
                }
            }
            .opacity(appState.isCommandModeEnabled ? 1 : 0.5)

            if let validationMessage = appState.commandModeManualModifierValidationMessage {
                Label(validationMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPEN SPEECH 会在转写完成后把文本复制到剪贴板。需要输入到其他 App 时，请手动使用 Command-V。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择用于录音的麦克风设备。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                MicrophoneOptionRow(
                    name: "System Default",
                    isSelected: appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty,
                    action: { appState.selectedMicrophoneID = "default" }
                )
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(
                        name: device.name,
                        isSelected: appState.selectedMicrophoneID == device.uid,
                        action: { appState.selectedMicrophoneID = device.uid }
                    )
                }
            }
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
        }
    }

    // MARK: Sound Volume

    private var soundVolumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Play alert sounds", isOn: $appState.alertSoundsEnabled)

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $appState.soundVolume, in: 0...1, step: 0.1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("\(Int(appState.soundVolume * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!appState.alertSoundsEnabled)
            .opacity(appState.alertSoundsEnabled ? 1 : 0.5)

            HStack(spacing: 8) {
                Button("Preview") {
                    let muted = SystemAudioStatus.isDefaultOutputMuted()
                    let volume = SystemAudioStatus.defaultOutputVolume()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMutedHint = muted || (volume ?? 1) < 0.10
                    }
                    appState.playAlertSound(named: "Tink")
                }
                .font(.caption)
                .disabled(!appState.alertSoundsEnabled)

                if showMutedHint {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.orange)
                        Text("System volume is muted or very low. Unmute to hear the preview.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .transition(.opacity)
                }
            }
        }
        .onChange(of: appState.alertSoundsEnabled) { _, enabled in
            if !enabled { showMutedHint = false }
        }
    }

    // MARK: Custom Vocabulary

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("要在后处理中保留的词汇和短语，每行一个。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customVocabularyInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customVocabularyInput) { _, newValue in
                    appState.customVocabulary = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }

            Text("Separate entries with commas, new lines, or semicolons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Microphone",
                icon: "mic.fill",
                granted: micPermissionGranted,
                action: {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
            )

            permissionRow(
                title: "Input Monitoring",
                icon: "keyboard.fill",
                granted: appState.hasKeyboardMonitoringPermission,
                action: {
                    appState.requestKeyboardMonitoringAccess()
                }
            )

            permissionRow(
                title: "Screen Recording",
                icon: "camera.viewfinder",
                granted: appState.hasScreenRecordingPermission,
                action: {
                    appState.requestScreenCapturePermission()
                }
            )
        }
    }

    private func permissionRow(title: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access") {
                    action()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

}

// MARK: - Microphone Option Row

struct MicrophoneOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Prompts Settings

struct PromptsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var customSystemPromptInput: String = ""
    @State private var customContextPromptInput: String = ""
    @State private var showDefaultSystemPrompt = false
    @State private var showDefaultContextPrompt = false
    @State private var isApplyingSystemPromptProgrammatically = false

    // Context prompt test state
    @State private var contextTestRunning = false
    @State private var contextTestOutput: String? = nil
    @State private var contextTestError: String? = nil
    @State private var contextTestPrompt: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("系统提示词", icon: "text.bubble.fill") {
                    systemPromptSection
                }
            }
            .padding(24)
        }
        .onAppear {
            customSystemPromptInput = appState.customSystemPrompt
            customContextPromptInput = appState.customContextPrompt.isEmpty
                ? AppContextService.defaultContextPrompt
                : appState.customContextPrompt
        }
        .onChange(of: appState.customSystemPrompt) { _, value in
            if customSystemPromptInput != value {
                isApplyingSystemPromptProgrammatically = true
                customSystemPromptInput = value
            }
        }
    }

    // MARK: System Prompt

    private var systemPromptSection: some View {
        let activePresetName = appState.systemPromptPresetName(for: appState.selectedSystemPromptPreset)
        let isCustom = !appState.customSystemPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customSystemPromptLastModified.isEmpty
            && appState.customSystemPromptLastModified < PostProcessingService.defaultSystemPromptDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("Controls how raw transcriptions are cleaned up.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNewerDefault {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("A newer default prompt is available.")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("View Default") {
                        showDefaultSystemPrompt.toggle()
                    }
                    .font(.caption)
                    Button("Switch to Default") {
                        appState.selectedSystemPromptPreset = .a
                        appState.updateSystemPromptPresetPrompt(.a, to: PostProcessingService.defaultSystemPrompt)
                        customSystemPromptInput = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPromptLastModified = iso8601DayFormatter.string(from: Date())
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if showDefaultSystemPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default System Prompt")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Hide") {
                            showDefaultSystemPrompt = false
                        }
                        .font(.caption)
                    }
                    Text(PostProcessingService.defaultSystemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            TextEditor(text: $customSystemPromptInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
	                .onChange(of: customSystemPromptInput) { _, newValue in
                    if isApplyingSystemPromptProgrammatically {
                        isApplyingSystemPromptProgrammatically = false
                        return
                    }

                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.customSystemPrompt = trimmed
                    appState.updateSelectedSystemPromptPresetPrompt(trimmed)
                    let today = iso8601DayFormatter.string(from: Date())
                    if appState.customSystemPromptLastModified != today {
                        appState.customSystemPromptLastModified = today
                    }
                }

            promptPresetPicker

            HStack {
                Label("当前预设：\(activePresetName)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Spacer()
                Button("恢复当前预设默认文本") {
                    let defaultPrompt = appState.selectedSystemPromptPreset.defaultPrompt
                    appState.updateSelectedSystemPromptPresetPrompt(defaultPrompt)
                    customSystemPromptInput = defaultPrompt
                    appState.customSystemPrompt = defaultPrompt
                    appState.customSystemPromptLastModified = iso8601DayFormatter.string(from: Date())
                }
                .font(.caption)
            }

        }
    }

    private var promptPresetPicker: some View {
        let activePreset = appState.activeSystemPromptPreset()

        return VStack(alignment: .leading, spacing: 8) {
            Text("提示词预设")
                .font(.caption.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(SystemPromptPreset.allCases) { preset in
                    Button {
                        appState.applySystemPromptPreset(preset)
                        customSystemPromptInput = appState.systemPromptPresetPrompt(for: preset)
                    } label: {
                        HStack(spacing: 6) {
                            if activePreset == preset {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(appState.systemPromptPresetName(for: preset))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(spacing: 6) {
                ForEach(SystemPromptPreset.allCases) { preset in
                    HStack(spacing: 8) {
                        Text(preset.shortTitle)
                            .font(.caption.weight(.semibold))
                            .frame(width: 20)
                        TextField(
                            preset.defaultName,
                            text: Binding(
                                get: { appState.systemPromptPresetName(for: preset) },
                                set: { appState.renameSystemPromptPreset(preset, to: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }
                }
            }

            Text("点击预设会切换到该预设当前保存的提示词；编辑上方文本会自动保存到当前选中的预设。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Context Prompt

    private var contextPromptSection: some View {
        let isCustom = !appState.customContextPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customContextPromptLastModified.isEmpty
            && appState.customContextPromptLastModified < AppContextService.defaultContextPromptDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("Controls how \(AppName.displayName) infers your current activity from app metadata and screenshots.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNewerDefault {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("A newer default prompt is available.")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("View Default") {
                        showDefaultContextPrompt.toggle()
                    }
                    .font(.caption)
                    Button("Switch to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if showDefaultContextPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Context Prompt")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Hide") {
                            showDefaultContextPrompt = false
                        }
                        .font(.caption)
                    }
                    Text(AppContextService.defaultContextPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            TextEditor(text: $customContextPromptInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customContextPromptInput) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultTrimmed = AppContextService.defaultContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == defaultTrimmed || trimmed.isEmpty {
                        if !appState.customContextPrompt.isEmpty {
                            appState.customContextPrompt = ""
                            appState.customContextPromptLastModified = ""
                        }
                    } else {
                        appState.customContextPrompt = trimmed
                        let today = iso8601DayFormatter.string(from: Date())
                        if appState.customContextPromptLastModified != today {
                            appState.customContextPromptLastModified = today
                        }
                    }
                }

            HStack {
                if isCustom {
                    Label("Using custom prompt", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label("Using default", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCustom {
                    Button("Reset to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Screenshot Resolution")
                    .font(.caption.weight(.semibold))

                Text("Controls the maximum image dimension sent for context inference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $appState.contextScreenshotMaxDimension) {
                    ForEach(AppState.contextScreenshotDimensionOptions, id: \.self) { dimension in
                        Text("\(dimension) px").tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Screenshot Resolution")

                HStack {
                    if appState.contextScreenshotMaxDimension == AppState.defaultContextScreenshotMaxDimension {
                        Label("Using default", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Using custom value", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    if appState.contextScreenshotMaxDimension != AppState.defaultContextScreenshotMaxDimension {
                        Button("Reset to Default") {
                            appState.contextScreenshotMaxDimension = AppState.defaultContextScreenshotMaxDimension
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            // Test section
            VStack(alignment: .leading, spacing: 8) {
                Text("Test Context Prompt")
                    .font(.caption.weight(.semibold))
                Text("Captures a screenshot and metadata from the frontmost app, then runs the context prompt to infer activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    runContextPromptTest()
                } label: {
                    HStack(spacing: 6) {
                        if contextTestRunning {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test Context Prompt")
                        }
                    }
                }
                .disabled(contextTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("API key required to test", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = contextTestError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let output = contextTestOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result:")
                            .font(.caption.weight(.semibold))
                        Text(output.isEmpty ? "(empty — no output)" : output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(6)
                    }
                }

                if let prompt = contextTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runContextPromptTest() {
        contextTestRunning = true
        contextTestOutput = nil
        contextTestError = nil
        contextTestPrompt = nil

        let service = appState.makeAppContextService()

        Task {
            let context = await service.collectContext()
            await MainActor.run {
                if let prompt = context.contextPrompt {
                    contextTestOutput = context.contextSummary
                    contextTestPrompt = prompt
                } else {
                    contextTestError = "Context inference returned no result. This may be a permissions issue or the API could not be reached."
                    contextTestOutput = context.contextSummary
                }
                contextTestRunning = false
            }
        }
    }

}

// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Log")
                        .font(.headline)
                    Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Clear History") {
                    appState.clearPipelineHistory()
                }
                .disabled(appState.pipelineHistory.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if appState.pipelineHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs yet. Use dictation to populate history.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.pipelineHistory) { item in
                            RunLogEntryView(item: item)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

// MARK: - Run Log Entry

struct RunLogEntryView: View {
    private let actionIconSize: CGFloat = 28
    let item: PipelineHistoryItem
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false
    @State private var isRetrying = false
    @State private var showContextPrompt = false
    @State private var showPostProcessingPrompt = false
    @State private var copiedTranscript = false
    @State private var copiedTranscriptResetWorkItem: DispatchWorkItem?
    @State private var copiedRawTranscript = false
    @State private var copiedRawTranscriptResetWorkItem: DispatchWorkItem?
    @State private var copiedCleanedTranscript = false
    @State private var copiedCleanedTranscriptResetWorkItem: DispatchWorkItem?

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var copyableTranscript: String {
        if !item.postProcessedTranscript.isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    @ViewBuilder
    private func actionIconButton(
        systemName: String,
        color: Color = .secondary,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: actionIconSize, height: actionIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            HStack(spacing: 0) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: actionIconSize, height: actionIconSize)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        if isError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.timestamp.formatted(date: .numeric, time: .standard))
                                .font(.subheadline.weight(.semibold))
                            Text(item.postProcessedTranscript.isEmpty ? "(no transcript)" : item.postProcessedTranscript)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    if isError && item.audioFileName != nil {
                        Button {
                            appState.retryTranscription(item: item)
                        } label: {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: actionIconSize, height: actionIconSize)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: actionIconSize, height: actionIconSize)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetrying)
                        .help("Retry transcription")
                    } else {
                        Color.clear
                            .frame(width: actionIconSize, height: actionIconSize)
                    }

                    actionIconButton(systemName: "square.and.arrow.up", help: "Export run log") {
                        TestCaseExporter.exportWithSavePanel(
                            item: item,
                            audioDirURL: AppState.audioStorageDirectory()
                        )
                    }

                    actionIconButton(
                        systemName: copiedTranscript ? "checkmark" : "doc.on.doc",
                        color: copiedTranscript ? .green : .secondary,
                        help: copiedTranscript ? "Copied transcript" : "Copy transcript",
                        disabled: copyableTranscript.isEmpty
                    ) {
                        copyTranscriptToPasteboard()
                    }

                    actionIconButton(systemName: "trash", help: "Delete this run") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.deleteHistoryEntry(id: item.id)
                        }
                    }
                }
            }
            .padding(12)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 16) {
                    // Audio player
                    if let audioFileName = item.audioFileName {
                        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
                        AudioPlayerView(audioURL: audioURL)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("No audio recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Custom vocabulary
                    if !item.customVocabulary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom Vocabulary")
                                .font(.caption.weight(.semibold))
                            FlowLayout(spacing: 4) {
                                ForEach(parseVocabulary(item.customVocabulary), id: \.self) { word in
                                    Text(word)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }

                    // Pipeline steps
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pipeline")
                            .font(.caption.weight(.semibold))

                        // Step 1: Context Capture
                        PipelineStepView(
                            number: 1,
                            title: "Capture Context",
                            content: {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let dataURL = item.contextScreenshotDataURL,
                                       let image = imageFromDataURL(dataURL) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 120)
                                            .cornerRadius(4)
                                    }

                                    if let prompt = item.contextPrompt, !prompt.isEmpty {
                                        Button {
                                            showContextPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(showContextPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(.caption)
                                                Image(systemName: showContextPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.caption2)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        if showContextPrompt {
                                            Text(prompt)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.contextSummary.isEmpty {
                                        Text(item.contextSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    } else {
                                        Text("No context captured")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 2: Transcribe Audio
                        PipelineStepView(
                            number: 2,
                            title: "Transcribe Audio",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Sent audio to the configured transcription model")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    if !item.rawTranscript.isEmpty {
                                        Text(item.rawTranscript)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .padding(.trailing, 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    copyRawTranscriptToPasteboard()
                                                } label: {
                                                    Image(systemName: copiedRawTranscript ? "checkmark" : "doc.on.doc")
                                                        .font(.caption)
                                                        .foregroundStyle(copiedRawTranscript ? .green : .secondary)
                                                        .padding(6)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .help(copiedRawTranscript ? "Copied literal transcript" : "Copy literal transcript")
                                            }
                                    } else {
                                        Text("(empty transcript)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 3: Post-Process
                        PipelineStepView(
                            number: 3,
                            title: "Post-Process",
                            content: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.postProcessingStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)

                                    if let prompt = item.postProcessingPrompt, !prompt.isEmpty {
                                        Button {
                                            showPostProcessingPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(showPostProcessingPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(.caption)
                                                Image(systemName: showPostProcessingPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.caption2)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        if showPostProcessingPrompt {
                                            Text(prompt)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.postProcessedTranscript.isEmpty {
                                        Text(item.postProcessedTranscript)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .padding(.trailing, 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    copyCleanedTranscriptToPasteboard()
                                                } label: {
                                                    Image(systemName: copiedCleanedTranscript ? "checkmark" : "doc.on.doc")
                                                        .font(.caption)
                                                        .foregroundStyle(copiedCleanedTranscript ? .green : .secondary)
                                                        .padding(6)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .help(copiedCleanedTranscript ? "Copied cleaned transcript" : "Copy cleaned transcript")
                                            }
                                    }
                                }
                            }
                        )
                    }

                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onReceive(appState.$retryingItemIDs) { ids in
            isRetrying = ids.contains(item.id)
        }
    }

    private func parseVocabulary(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func copyTranscriptToPasteboard() {
        guard !copyableTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableTranscript, forType: .string)
        copiedTranscript = true

        copiedTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedTranscript = false
            copiedTranscriptResetWorkItem = nil
        }
        copiedTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    private func copyRawTranscriptToPasteboard() {
        guard !item.rawTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.rawTranscript, forType: .string)
        copiedRawTranscript = true

        copiedRawTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedRawTranscript = false
            copiedRawTranscriptResetWorkItem = nil
        }
        copiedRawTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    private func copyCleanedTranscriptToPasteboard() {
        guard !item.postProcessedTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.postProcessedTranscript, forType: .string)
        copiedCleanedTranscript = true

        copiedCleanedTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedCleanedTranscript = false
            copiedCleanedTranscriptResetWorkItem = nil
        }
        copiedCleanedTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }
}

// MARK: - Pipeline Step View

struct PipelineStepView<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Audio Player

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * progress), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            loadDuration()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func loadDuration() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        if let p = try? AVAudioPlayer(contentsOf: audioURL) {
            duration = p.duration
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = {
                    self.stopPlayback()
                }
                p.delegate = delegate
                p.play()
                player = p
                isPlaying = true
                elapsed = 0
                startProgressTimer()
            } catch {}
        }
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let p = player, p.isPlaying {
                elapsed = p.currentTime
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Voice Macros Settings

struct VoiceMacrosSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddMacro = false
    @State private var editingMacro: VoiceMacro?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Voice Macros", icon: "music.mic") {
                    macrosSection
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingAddMacro, onDismiss: { editingMacro = nil }) {
            VoiceMacroEditorView(isPresented: $showingAddMacro, macro: $editingMacro)
        }
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                    Text("Bypass post-processing and immediately copy your predefined text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingAddMacro = true }) {
                    Text("Add Macro")
                }
            }

            if appState.voiceMacros.isEmpty {
                VStack {
                    Image(systemName: "music.mic")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                    Text("No Voice Macros Yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Click 'Add Macro' to define your first voice macro.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(appState.voiceMacros.enumerated()), id: \.element.id) { index, macro in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(macro.command)
                                    .font(.headline)
                                Spacer()
                                Button("Edit") {
                                    editingMacro = macro
                                    showingAddMacro = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                
                                Button("Delete") {
                                    appState.voiceMacros.removeAll { $0.id == macro.id }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Text(macro.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    }
                }
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }
}

struct VoiceMacroEditorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @Binding var macro: VoiceMacro?

    @State private var command: String = ""
    @State private var payload: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(macro == nil ? "Add Macro" : "Edit Macro")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Voice Command (What you say)")
                    .font(.caption.weight(.semibold))
                TextField("e.g. debugging prompt", text: $command)
                    .textFieldStyle(.roundedBorder)

                Text("Text (What gets copied)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 8)
                TextEditor(text: $payload)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                    macro = nil
                }
                Spacer()
                Button("Save") {
                    let newMacro = VoiceMacro(
                        id: macro?.id ?? UUID(),
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                        payload: payload
                    )
                    
                    if let existingIndex = appState.voiceMacros.firstIndex(where: { $0.id == newMacro.id }) {
                        appState.voiceMacros[existingIndex] = newMacro
                    } else {
                        appState.voiceMacros.append(newMacro)
                    }
                    isPresented = false
                    macro = nil
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || payload.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let m = macro {
                command = m.command
                payload = m.payload
            }
        }
    }
}
