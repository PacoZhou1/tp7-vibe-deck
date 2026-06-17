import SwiftUI
import AVFoundation
import ApplicationServices
import CoreGraphics
import Combine

struct OnboardingView: View {
    var onComplete: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var currentStep: OnboardingStep = .menuBar
    @State private var micPermissionGranted = false
    @State private var accessibilityTimer: Timer?
    @State private var permissionTimer: Timer?
    @State private var testPhase: OnboardingTestPhase = .idle
    @State private var testAudioRecorder: AudioRecorder?
    @State private var testAudioLevel: Float = 0
    @State private var testTranscript = ""
    @State private var testError: String?
    @State private var testAudioLevelCancellable: AnyCancellable?

    private enum OnboardingStep: Int, CaseIterable, Identifiable {
        case menuBar
        case permissions
        case shortcuts
        case test
        case ready

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .menuBar: return "找到入口"
            case .permissions: return "打开权限"
            case .shortcuts: return "设置快捷键"
            case .test: return "测试转录"
            case .ready: return "完成"
            }
        }

        var subtitle: String {
            switch self {
            case .menuBar: return "OPEN SPEECH 常驻在顶部菜单栏，不会显示 Dock 主窗口。"
            case .permissions: return "麦克风用于录音，辅助功能用于把文字粘贴回当前 App。"
            case .shortcuts: return "建议保留一个长按快捷键和一个点击开关，后续可以随时改。"
            case .test: return "说一句话，确认麦克风、模型和转录链路都工作正常。"
            case .ready: return "之后只需要按快捷键，或者从顶部菜单栏开始录音。"
            }
        }
    }

    private enum OnboardingTestPhase: Equatable {
        case idle
        case recording
        case transcribing
        case done
    }

    private var currentStepIndex: Int {
        OnboardingStep.allCases.firstIndex(of: currentStep) ?? 0
    }

    private var isLastStep: Bool {
        currentStep == .ready
    }

    private var canAdvance: Bool {
        switch currentStep {
        case .permissions:
            return micPermissionGranted && appState.hasAccessibility
        case .test:
            return testPhase == .done && testError == nil && !testTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 210)

                Divider()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            header
                            currentContent
                        }
                        .padding(28)
                    }

                    Divider()
                    footer
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .onAppear {
            refreshPermissions()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
            stopTestRecording()
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 54, height: 54)

                Text("快速开始")
                    .font(.title2.weight(.semibold))

                Text("三分钟完成第一次录音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    onboardingStepRow(step)
                }
            }

            Spacer()
        }
        .padding(22)
        .background(.regularMaterial)
    }

    private func onboardingStepRow(_ step: OnboardingStep) -> some View {
        let isActive = step == currentStep
        let isDone = step.rawValue < currentStep.rawValue

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                currentStep = step
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.accentColor : (isDone ? Color.green : Color.secondary.opacity(0.18)))
                        .frame(width: 24, height: 24)

                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step.rawValue + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isActive ? .white : .secondary)
                    }
                }

                Text(step.title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentStep.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Text(currentStep.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var currentContent: some View {
        switch currentStep {
        case .menuBar:
            menuBarIntro
        case .permissions:
            permissionsContent
        case .shortcuts:
            shortcutsContent
        case .test:
            testContent
        case .ready:
            readyContent
        }
    }

    private var menuBarIntro: some View {
        VStack(alignment: .leading, spacing: 20) {
            MenuBarTeachingAnimation()
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingInfoRow(
                    icon: "waveform",
                    title: "顶部状态栏图标就是入口",
                    detail: "点击它可以开始/停止录音、切换提示词预设、打开设置和查看历史。"
                )
                OnboardingInfoRow(
                    icon: "record.circle",
                    title: "也可以直接点「开始录音」",
                    detail: "第一次不知道快捷键时，从下拉菜单点开始录音是最稳的方式。"
                )
                OnboardingInfoRow(
                    icon: "keyboard",
                    title: "熟悉后用快捷键更快",
                    detail: appState.shortcutStatusText
                )
            }
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            permissionCard(
                title: "麦克风",
                detail: "必须开启。用于录制你的语音。",
                icon: "mic.fill",
                granted: micPermissionGranted,
                required: true,
                actionTitle: "授权麦克风",
                action: {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
            )

            permissionCard(
                title: "辅助功能",
                detail: "必须开启。用于把转录后的文字粘贴到当前输入框。",
                icon: "hand.raised.fill",
                granted: appState.hasAccessibility,
                required: true,
                actionTitle: "打开系统设置",
                action: {
                    appState.openAccessibilitySettings()
                }
            )

            permissionCard(
                title: "屏幕录制",
                detail: "可选但推荐。用于理解当前 App 和窗口上下文，让纠错更准确。",
                icon: "camera.viewfinder",
                granted: appState.hasScreenRecordingPermission,
                required: false,
                actionTitle: "授权屏幕录制",
                action: {
                    appState.requestScreenCapturePermission()
                }
            )

            if !canAdvance {
                Label("至少完成麦克风和辅助功能授权后，再继续测试转录。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            DictationShortcutEditor(showsIntroText: false) { isCapturing in
                if isCapturing {
                    appState.suspendHotkeyMonitoringForShortcutCapture()
                } else {
                    appState.resumeHotkeyMonitoringAfterShortcutCapture()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("推荐用法", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text("长按适合一句话输入；点击开关适合比较长的段落。两个都可以保留，不冲突。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private var testContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("麦克风", selection: $appState.selectedMicrophoneID) {
                Text("系统默认").tag("default")
                ForEach(appState.availableMicrophones) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .frame(maxWidth: 360)

            VStack(spacing: 18) {
                testVisualizer

                switch testPhase {
                case .idle:
                    Text("按下方按钮录一小段，或者稍后从状态栏菜单点「开始录音」。")
                        .foregroundStyle(.secondary)
                case .recording:
                    Text("正在听，请说一句话。")
                        .font(.headline)
                        .foregroundStyle(.blue)
                case .transcribing:
                    VStack(spacing: 10) {
                        OnboardingTranscribingDots()
                        Text("正在转录...")
                            .foregroundStyle(.secondary)
                    }
                case .done:
                    testResult
                }

                HStack(spacing: 10) {
                    Button(testButtonTitle) {
                        handleTestButton()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(testPhase == .transcribing)

                    if testPhase == .done {
                        Button("再试一次") {
                            resetTest()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .cornerRadius(10)
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
        }
    }

    private var testVisualizer: some View {
        ZStack {
            Circle()
                .fill(testPhase == .recording ? Color.blue.opacity(0.72) : Color.blue.opacity(0.14))
                .frame(width: 104, height: 104)
                .scaleEffect(testPhase == .recording ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: testPhase == .recording)

            Image(systemName: testPhase == .done && testError == nil ? "checkmark" : "mic.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(testPhase == .done && testError == nil ? .green : .white)

            if testPhase == .recording {
                WaveformView(audioLevel: testAudioLevel)
                    .offset(y: 34)
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        if let testError {
            VStack(spacing: 8) {
                Label("测试没有完成", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(testError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("转录成功", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(testTranscript.isEmpty ? "没有识别到内容，可以再试一次。" : testTranscript)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 6) {
                    Text("可以开始用了")
                        .font(.title2.weight(.semibold))
                    Text("OPEN SPEECH 会留在顶部状态栏，随时等待录音。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingInfoRow(icon: "keyboard", title: "快捷键", detail: appState.shortcutStatusText)
                OnboardingInfoRow(icon: "menubar.rectangle", title: "状态栏菜单", detail: "点击顶部图标，可以手动开始录音、切换预设、打开设置。")
                OnboardingInfoRow(icon: "gearshape", title: "以后想改", detail: "菜单栏里点「设置」，可以调整权限、快捷键、提示词和麦克风。")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("稍后") {
                onComplete()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("上一步") {
                goBack()
            }
            .disabled(currentStep == .menuBar)

            Button(isLastStep ? "开始使用" : advanceButtonTitle) {
                if isLastStep {
                    onComplete()
                } else {
                    goForward()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var advanceButtonTitle: String {
        switch currentStep {
        case .permissions where !canAdvance:
            return "稍后设置，继续"
        case .test where !canAdvance:
            return "跳过测试"
        default:
            return "继续"
        }
    }

    private var testButtonTitle: String {
        switch testPhase {
        case .idle: return "开始测试录音"
        case .recording: return "停止并转录"
        case .transcribing: return "转录中..."
        case .done: return "完成"
        }
    }

    private func permissionCard(
        title: String,
        detail: String,
        icon: String,
        granted: Bool,
        required: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(granted ? .green : .blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(required ? "必需" : "推荐")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(required ? .orange : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((required ? Color.orange : Color.secondary).opacity(0.12)))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle) {
                    action()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        .cornerRadius(10)
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: max(0, currentStep.rawValue - 1)) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            currentStep = previous
        }
    }

    private func goForward() {
        if currentStep == .test {
            stopTestRecording()
        }
        guard let next = OnboardingStep(rawValue: min(OnboardingStep.ready.rawValue, currentStep.rawValue + 1)) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            currentStep = next
        }
    }

    private func refreshPermissions() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        appState.hasAccessibility = AXIsProcessTrusted()
        appState.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshPermissions()
            }
        }
    }

    private func stopPermissionPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func handleTestButton() {
        switch testPhase {
        case .idle:
            startTestRecording()
        case .recording:
            finishTestRecording()
        case .transcribing:
            break
        case .done:
            goForward()
        }
    }

    private func startTestRecording() {
        if !micPermissionGranted {
            appState.requestMicrophoneAccess { granted in
                micPermissionGranted = granted
                if granted {
                    startTestRecording()
                }
            }
            return
        }

        resetTest(clearPhase: false)
        do {
            let recorder = AudioRecorder()
            recorder.onRecordingFailure = { error in
                Task { @MainActor in
                    testError = error.localizedDescription
                    stopTestRecording()
                    withAnimation {
                        testPhase = .done
                    }
                }
            }
            try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
            testAudioRecorder = recorder
            testAudioLevelCancellable = recorder.$audioLevel
                .receive(on: DispatchQueue.main)
                .sink { level in
                    testAudioLevel = level
                }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                testPhase = .recording
            }
        } catch {
            testError = error.localizedDescription
            withAnimation {
                testPhase = .done
            }
        }
    }

    private func finishTestRecording() {
        guard let recorder = testAudioRecorder else { return }
        testAudioLevelCancellable?.cancel()
        testAudioLevelCancellable = nil
        testAudioLevel = 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            testPhase = .transcribing
        }

        recorder.stopRecording { url in
            guard let url else {
                Task { @MainActor in
                    testError = "没有生成录音文件，请再试一次。"
                    testAudioRecorder = nil
                    recorder.cleanup()
                    withAnimation {
                        testPhase = .done
                    }
                }
                return
            }

            Task {
                do {
                    let transcript = try await appState.transcribeAudioForCurrentMode(fileURL: url)
                    await MainActor.run {
                        testTranscript = transcript
                        testError = nil
                        testAudioRecorder = nil
                        recorder.cleanup()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            testPhase = .done
                        }
                    }
                } catch {
                    await MainActor.run {
                        testError = error.localizedDescription
                        testAudioRecorder = nil
                        recorder.cleanup()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            testPhase = .done
                        }
                    }
                }
            }
        }
    }

    private func stopTestRecording() {
        testAudioLevelCancellable?.cancel()
        testAudioLevelCancellable = nil
        if let recorder = testAudioRecorder, recorder.isRecording {
            recorder.cancelRecording()
        }
        testAudioRecorder = nil
        testAudioLevel = 0
    }

    private func resetTest(clearPhase: Bool = true) {
        stopTestRecording()
        testTranscript = ""
        testError = nil
        if clearPhase {
            withAnimation {
                testPhase = .idle
            }
        }
    }
}

private struct MenuBarTeachingAnimation: View {
    @State private var pulse = false
    @State private var menuOpen = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red.opacity(0.65))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(.yellow.opacity(0.75))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(.green.opacity(0.75))
                        .frame(width: 10, height: 10)
                }

                Spacer()

                HStack(spacing: 14) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(menuOpen ? 0.18 : 0.08))
                            .frame(width: 36, height: 28)
                            .scaleEffect(pulse ? 1.08 : 1.0)
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(pulse ? 0.85 : 0.25), lineWidth: 1.5)
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            if menuOpen {
                VStack(alignment: .leading, spacing: 10) {
                    Label("打开新手指引", systemImage: "questionmark.circle")
                    Divider()
                    Label("开始录音", systemImage: "record.circle")
                    Label("长按识别", systemImage: "keyboard")
                    Label("提示词预设", systemImage: "text.bubble")
                    Divider()
                    Label("设置", systemImage: "gearshape")
                }
                .font(.callout)
                .padding(14)
                .frame(width: 230, alignment: .leading)
                .background(.regularMaterial)
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .cornerRadius(12)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.55)) {
                menuOpen = true
            }
        }
    }
}

private struct OnboardingInfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        .cornerRadius(10)
    }
}

private struct OnboardingTranscribingDots: View {
    @State private var activeDot = 0
    private let timer = Timer.publish(every: 0.36, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue.opacity(activeDot == index ? 1.0 : 0.28))
                    .frame(width: 11, height: 11)
                    .scaleEffect(activeDot == index ? 1.25 : 1.0)
                    .animation(.easeInOut(duration: 0.24), value: activeDot)
            }
        }
        .onReceive(timer) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}
