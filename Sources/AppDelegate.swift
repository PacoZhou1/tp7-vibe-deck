import SwiftUI
import Combine
import Darwin
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {
    private let combinedLocalMemorySoftLimitMb = 8_000.0
    private let combinedLocalMemoryHardLimitMb = 9_000.0
    private let backendMemoryCleanupLimitMb = 8_000.0
    private let backendMemoryRestartLimitMb = 9_000.0
    private let backendMemoryMonitorInterval: TimeInterval = 10
    private let backendRestartIdleDelay: TimeInterval = 2
    private let backendSessionToken = UUID().uuidString

    let appState = AppState()
    var setupWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var serverProcess: Process?
    private var healthPollTimer: Timer?
    private var backendMemoryTimer: Timer?
    private var serverLoadStartTime: Date?
    private var hasShownModelError: Bool = false
    private var isTerminating = false
    private var isStoppingLocalInferenceServer = false
    private var isBackendMemoryCleanupInFlight = false
    private var isLocalASRMemoryCleanupInFlight = false
    private var isLocalASRMemoryReleaseInFlight = false
    private var isBackendRestartInProgress = false
    private var serverUsesCustomLLMPostProcessing = false
    private var serverUsesSenseVoiceASR = false
    private var pendingBackendRestartReason: String?
    private var scheduledBackendRestart: DispatchWorkItem?
    private var scheduledIdleMemoryCheck: DispatchWorkItem?
    private var lastBackendMemoryCleanupRequestAt: Date?
    private var lastLocalASRMemoryCleanupRequestAt: Date?
    private var lastLocalASRModelReleaseRequestAt: Date?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.configureLocalBackendSession(token: backendSessionToken)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowOnboarding),
            name: .showOnboarding,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLocalBackendModeChanged),
            name: .localBackendModeChanged,
            object: nil
        )
        observeDictationIdleState()

        // macOS version compatibility check
        checkSystemVersion()

        appState.warmUpLocalASRModel()

        // Auto-start the Python backend for local Gemma correction modes.
        if appState.shouldRunLocalGemmaBackend {
            startLocalInferenceServerIfNeeded()
        }

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            if !appState.hasCompletedOnboarding {
                showOnboardingWindow(markCompletedOnClose: true)
            }
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        hasShownModelError = true
        stopHealthPolling()
        stopBackendMemoryMonitoring()
        stopLocalInferenceServer()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard appState.hasCompletedSetup else { return true }
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    @objc func handleShowSetup() {
        // Single wizard at a time — opening a second leaks the first's
        // willClose observer and breaks the bail-restore.
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wasCompleted = appState.hasCompletedSetup
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()

        // Restore prior state if the user closes the wizard without completing.
        // completeSetup() flips hasCompletedSetup back to true before window.close(),
        // so the !hasCompletedSetup check below correctly skips the restore there.
        if wasCompleted, let window = setupWindow {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if !self.appState.hasCompletedSetup {
                    self.appState.hasCompletedSetup = true
                    self.appState.startHotkeyMonitoring()
                    self.appState.startAccessibilityPolling()
                    NSApp.setActivationPolicy(.accessory)
                }
                self.setupWindow = nil
            }
        }
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    @objc private func handleShowOnboarding() {
        showOnboardingWindow(markCompletedOnClose: false)
    }

    @objc private func handleLocalBackendModeChanged() {
        if appState.asrEngineMode == .qwenNative {
            appState.warmUpLocalASRModel()
        }
        if appState.shouldRunLocalGemmaBackend {
            startLocalInferenceServerIfNeeded()
        } else {
            stopHealthPolling()
            stopBackendMemoryMonitoring()
            stopLocalInferenceServer()
        }
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.setupWindow == nil && self?.onboardingWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self?.settingsWindow = nil
        }
    }

    private func showOnboardingWindow(markCompletedOnClose: Bool) {
        NSApp.setActivationPolicy(.regular)

        if let onboardingWindow, onboardingWindow.isVisible {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView(onComplete: { [weak self] in
            self?.completeOnboarding()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppName.displayName) 新手指引"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 560)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if markCompletedOnClose, !self.appState.hasCompletedOnboarding {
                self.appState.hasCompletedOnboarding = true
            }
            if self.settingsWindow == nil && self.setupWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self.onboardingWindow = nil
        }
    }


    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 680)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        if !appState.hasCompletedOnboarding {
            showOnboardingWindow(markCompletedOnClose: true)
        }
    }

    func completeOnboarding() {
        appState.hasCompletedOnboarding = true
        onboardingWindow?.close()
        onboardingWindow = nil
        if settingsWindow == nil && setupWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Local Inference Server

    private func startLocalInferenceServerIfNeeded() {
        guard appState.shouldRunLocalGemmaBackend else { return }
        if let serverProcess, serverProcess.isRunning {
            if serverUsesSenseVoiceASR != appState.shouldRunSenseVoiceASRBackend {
                stopHealthPolling()
                stopBackendMemoryMonitoring()
                stopLocalInferenceServer()
            } else {
                startBackendMemoryMonitoring()
                return
            }
        }
        if let serverProcess, serverProcess.isRunning {
            startBackendMemoryMonitoring()
            return
        }

        guard startLocalInferenceServer() else { return }
        startHealthPolling()
        startBackendMemoryMonitoring()
    }

    private func startLocalInferenceServer() -> Bool {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return true }
        serverProcess = nil

        guard let resourceURL = Bundle.main.resourceURL else {
            os_log(.error, log: OSLog.default, "[OPEN SPEECH] Cannot find resource path")
            return false
        }
        let backendDir = resourceURL.appendingPathComponent("backend")
        let backendExecutable = backendDir.appendingPathComponent(AppName.displayName)
        let bundledPython = backendDir.appendingPathComponent("python/standalone/bin/python3.13")
        let pythonBin = FileManager.default.fileExists(atPath: backendExecutable.path)
            ? backendExecutable
            : bundledPython
        let serverScript = backendDir.appendingPathComponent("inference_server.py")

        guard FileManager.default.fileExists(atPath: pythonBin.path) else {
            os_log(.error, log: OSLog.default, "[OPEN SPEECH] Python not found: %{public}@", pythonBin.path)
            return false
        }
        guard FileManager.default.fileExists(atPath: serverScript.path) else {
            os_log(.error, log: OSLog.default, "[OPEN SPEECH] Server script not found: %{public}@", serverScript.path)
            return false
        }
        stopOrphanedBackendProcesses()

        // Keep one append-only log so parallel/stale app copies cannot replace
        // the inode while a running backend still owns its file handle.
        let logPath = "\(NSHomeDirectory())/openspeech-server.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let logFH = FileHandle(forWritingAtPath: logPath)
        _ = try? logFH?.seekToEnd()

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = [serverScript.path]
        process.currentDirectoryURL = backendDir
        process.environment = [
            "INFERENCE_PORT": "8001",
            "INFERENCE_HOST": "127.0.0.1",
            "INFERENCE_MEMORY_SOFT_LIMIT_MB": "\(Int(combinedLocalMemorySoftLimitMb))",
            "INFERENCE_MEMORY_CLEANUP_THRESHOLD_MB": "\(Int(backendMemoryCleanupLimitMb))",
            "INFERENCE_MEMORY_RESTART_THRESHOLD_MB": "\(Int(backendMemoryRestartLimitMb))",
            "INFERENCE_MLX_MEMORY_LIMIT_MB": "\(Int(combinedLocalMemoryHardLimitMb))",
            "INFERENCE_MLX_INITIAL_CACHE_LIMIT_MB": "2048",
            "INFERENCE_MLX_CACHE_FLOOR_MB": "256",
            "INFERENCE_MLX_CACHE_HEADROOM_MB": "512",
            "INFERENCE_DISABLE_LOCAL_LLM": "0",
            "INFERENCE_DISABLE_SENSEVOICE_ASR": appState.shouldRunSenseVoiceASRBackend ? "0" : "1",
            "INFERENCE_SESSION_TOKEN": backendSessionToken,
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]
        if let fh = logFH {
            process.standardOutput = fh
            process.standardError = fh
        }

        do {
            try process.run()
            serverProcess = process
            serverUsesCustomLLMPostProcessing = false
            serverUsesSenseVoiceASR = appState.shouldRunSenseVoiceASRBackend
            isStoppingLocalInferenceServer = false
            os_log(.info, log: OSLog.default, "[OPEN SPEECH] Server started PID: %d", process.processIdentifier)

            // Detect unexpected server death
            process.terminationHandler = { [weak self] proc in
                guard let self = self,
                      !self.isTerminating,
                      !self.isStoppingLocalInferenceServer,
                      !self.isBackendRestartInProgress,
                      !self.hasShownModelError else { return }
                if proc.terminationStatus != 0 && proc.terminationReason == .uncaughtSignal {
                    self.stopHealthPolling()
                    self.showModelLoadError(reason: "推理服务异常终止（信号 \(proc.terminationStatus)）")
                }
            }
            return true
        } catch {
            os_log(.error, log: OSLog.default, "[OPEN SPEECH] Failed to start server: %{public}@", error.localizedDescription)
            return false
        }
    }

    private func stopOrphanedBackendProcesses() {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        let patterns = [
            "Open Speech ASR.app/Contents/Resources/backend/.*inference_server.py",
            "Contents/Resources/backend/.*inference_server.py",
            "openspeech-dev/backend/.*inference_server.py",
        ]

        for pattern in patterns {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-f", pattern]
            process.standardOutput = nil
            process.standardError = nil
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                os_log(.debug, log: OSLog.default, "[OPEN SPEECH] pkill unavailable for stale backend cleanup: %{public}@", error.localizedDescription)
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func stopLocalInferenceServer() {
        guard let process = serverProcess else { return }
        isStoppingLocalInferenceServer = true
        process.terminate()
        process.waitUntilExit()
        serverProcess = nil
        serverUsesCustomLLMPostProcessing = false
        serverUsesSenseVoiceASR = false
        isStoppingLocalInferenceServer = false
        os_log(.info, log: OSLog.default, "[OPEN SPEECH] Inference server stopped")
    }

    // MARK: - Backend Memory Supervisor

    private func startBackendMemoryMonitoring() {
        guard backendMemoryTimer == nil, appState.shouldRunLocalGemmaBackend else { return }
        backendMemoryTimer = Timer.scheduledTimer(withTimeInterval: backendMemoryMonitorInterval, repeats: true) { [weak self] _ in
            self?.checkBackendMemory()
        }
        checkBackendMemory()
    }

    private func stopBackendMemoryMonitoring() {
        backendMemoryTimer?.invalidate()
        backendMemoryTimer = nil
        scheduledBackendRestart?.cancel()
        scheduledBackendRestart = nil
        scheduledIdleMemoryCheck?.cancel()
        scheduledIdleMemoryCheck = nil
        pendingBackendRestartReason = nil
        isBackendMemoryCleanupInFlight = false
        isLocalASRMemoryCleanupInFlight = false
        isLocalASRMemoryReleaseInFlight = false
    }

    private func observeDictationIdleState() {
        appState.$isRecording
            .combineLatest(appState.$isTranscribing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isTranscribing in
                guard let self else { return }
                if isRecording || isTranscribing {
                    self.scheduledBackendRestart?.cancel()
                    self.scheduledBackendRestart = nil
                    self.scheduledIdleMemoryCheck?.cancel()
                    self.scheduledIdleMemoryCheck = nil
                    return
                }
                self.schedulePendingBackendRestartIfIdle()
                self.scheduleCombinedMemoryCheckAfterIdle()
            }
            .store(in: &cancellables)
    }

    private func scheduleCombinedMemoryCheckAfterIdle() {
        guard scheduledIdleMemoryCheck == nil,
              appState.shouldRunLocalGemmaBackend,
              !isBackendRestartInProgress,
              !isTerminating else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.appState.isRecording,
                  !self.appState.isTranscribing else { return }
            self.scheduledIdleMemoryCheck = nil
            self.checkBackendMemory()
        }
        scheduledIdleMemoryCheck = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + backendRestartIdleDelay, execute: workItem)
    }

    private struct BackendMemoryMetrics {
        let memoryUsageMb: Double
        let mlxActiveMemoryMb: Double
        let mlxCacheMemoryMb: Double
        let mlxTrackedMemoryMb: Double
        let needsMemoryCleanup: Bool
        let needsBackendRestart: Bool
    }

    private static func backendMemoryMetrics(from json: [String: Any]) -> BackendMemoryMetrics {
        let memoryUsage = doubleValue(json, "memoryUsageMb")
        let active = doubleValue(json, "mlxActiveMemoryMb")
        let cache = doubleValue(json, "mlxCacheMemoryMb")
        let tracked = doubleValue(json, "mlxTrackedMemoryMb")
        return BackendMemoryMetrics(
            memoryUsageMb: memoryUsage,
            mlxActiveMemoryMb: active,
            mlxCacheMemoryMb: cache,
            mlxTrackedMemoryMb: tracked > 0 ? tracked : active + cache,
            needsMemoryCleanup: boolValue(json, "needsMemoryCleanup"),
            needsBackendRestart: boolValue(json, "needsBackendRestart")
        )
    }

    private static func doubleValue(_ json: [String: Any], _ key: String) -> Double {
        if let value = json[key] as? Double { return value }
        if let value = json[key] as? Int { return Double(value) }
        if let value = json[key] as? NSNumber { return value.doubleValue }
        if let value = json[key] as? String, let parsed = Double(value) { return parsed }
        return 0
    }

    private static func boolValue(_ json: [String: Any], _ key: String) -> Bool {
        if let value = json[key] as? Bool { return value }
        if let value = json[key] as? NSNumber { return value.boolValue }
        if let value = json[key] as? String { return value == "true" || value == "1" }
        return false
    }

    private func configureBackendIdentityHeader(_ request: inout URLRequest) {
        request.setValue(backendSessionToken, forHTTPHeaderField: "X-Open-Speech-Session")
    }

    private func isExpectedBackendResponse(_ response: URLResponse?) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse,
              let process = serverProcess,
              process.isRunning else {
            return false
        }
        let responseToken = httpResponse.value(forHTTPHeaderField: "X-Open-Speech-Session")
        let responsePID = httpResponse.value(forHTTPHeaderField: "X-Open-Speech-PID")
        let matches = responseToken == backendSessionToken
            && responsePID == String(process.processIdentifier)
        if !matches {
            os_log(
                .error,
                log: OSLog.default,
                "[OPEN SPEECH] Rejected stale backend response: expected PID=%d",
                process.processIdentifier
            )
        }
        return matches
    }

    private static func currentProcessMemoryUsageMb() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_000_000
    }

    private func checkBackendMemory() {
        guard appState.shouldRunLocalGemmaBackend,
              !isTerminating,
              !isBackendRestartInProgress,
              let process = serverProcess,
              process.isRunning else { return }

        let url = URL(string: "http://127.0.0.1:8001/api/metrics")!
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        configureBackendIdentityHeader(&request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self,
                  error == nil,
                  self.isExpectedBackendResponse(response),
                  let data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let backend = Self.backendMemoryMetrics(from: json)

            Task { [weak self] in
                guard let self else { return }
                let qwen = await self.appState.localASRMemorySnapshot()
                let appMemoryUsage = Self.currentProcessMemoryUsageMb()
                await MainActor.run {
                    guard !self.isTerminating, self.appState.shouldRunLocalGemmaBackend else { return }
                    self.evaluateCombinedLocalMemory(
                        backend: backend,
                        qwen: qwen,
                        appMemoryUsageMb: appMemoryUsage
                    )
                }
            }
        }.resume()
    }

    private func evaluateCombinedLocalMemory(
        backend: BackendMemoryMetrics,
        qwen: LocalMLXMemorySnapshot,
        appMemoryUsageMb: Double
    ) {
        let combinedTracked = backend.mlxTrackedMemoryMb + qwen.mlxTrackedMemoryMb
        let combinedProcess = backend.memoryUsageMb + appMemoryUsageMb
        let qwenBudgetFootprint = max(qwen.mlxTrackedMemoryMb, appMemoryUsageMb)
        let overSoftLimit = combinedTracked >= combinedLocalMemorySoftLimitMb
            || combinedProcess >= combinedLocalMemorySoftLimitMb
            || backend.needsMemoryCleanup
        let overHardLimit = combinedTracked >= combinedLocalMemoryHardLimitMb
            || combinedProcess >= combinedLocalMemoryHardLimitMb
            || backend.needsBackendRestart

        guard overSoftLimit || overHardLimit else { return }

        os_log(
            .info,
            log: OSLog.default,
            "[OPEN SPEECH] Combined local memory: tracked=%.0f MB (qwen=%.0f backend=%.0f), process=%.0f MB (app=%.0f backend=%.0f), soft=%.0f MB",
            combinedTracked,
            qwen.mlxTrackedMemoryMb,
            backend.mlxTrackedMemoryMb,
            combinedProcess,
            appMemoryUsageMb,
            backend.memoryUsageMb,
            combinedLocalMemorySoftLimitMb
        )

        requestLocalASRMemoryCleanupIfNeeded(
            backend: backend,
            combinedTrackedMb: combinedTracked,
            combinedProcessMb: combinedProcess
        )
        requestBackendMemoryCleanupIfNeeded(
            backend: backend,
            peerTrackedMemoryMb: qwen.mlxTrackedMemoryMb,
            peerMemoryFootprintMb: qwenBudgetFootprint,
            combinedTrackedMb: combinedTracked,
            combinedProcessMb: combinedProcess
        )

        if overSoftLimit || overHardLimit {
            requestLocalASRModelReleaseIfIdle(
                qwen: qwen,
                backendTrackedMb: backend.mlxTrackedMemoryMb,
                backendCacheMb: backend.mlxCacheMemoryMb,
                combinedTrackedMb: combinedTracked,
                combinedProcessMb: combinedProcess
            )
            if backend.needsBackendRestart {
                requestBackendRestart(
                    reason: String(
                        format: "backend active memory remained high under combined budget: backend=%.0f MB combined=%.0f MB",
                        backend.mlxTrackedMemoryMb,
                        combinedTracked
                    )
                )
            } else if overHardLimit,
                      !isLocalASRMemoryReleaseInFlight,
                      (qwen.mlxTrackedMemoryMb <= 512
                        || hasRecentLocalASRModelReleaseRequest) {
                requestBackendRestart(
                    reason: String(
                        format: "combined memory remained above 9GB after cache cleanup/model release: tracked=%.0f MB process=%.0f MB",
                        combinedTracked,
                        combinedProcess
                    )
                )
            }
        }
    }

    private func requestLocalASRMemoryCleanupIfNeeded(
        backend: BackendMemoryMetrics,
        combinedTrackedMb: Double,
        combinedProcessMb: Double
    ) {
        guard !isLocalASRMemoryCleanupInFlight else { return }
        if let lastLocalASRMemoryCleanupRequestAt,
           Date().timeIntervalSince(lastLocalASRMemoryCleanupRequestAt) < 30 {
            return
        }

        isLocalASRMemoryCleanupInFlight = true
        lastLocalASRMemoryCleanupRequestAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let result = await self.appState.performLocalASRMemoryMaintenance(
                globalSoftLimitMb: self.combinedLocalMemorySoftLimitMb,
                peerTrackedMemoryMb: max(backend.mlxTrackedMemoryMb, backend.memoryUsageMb),
                reason: "combined-memory-supervisor",
                force: true
            )
            await MainActor.run {
                self.isLocalASRMemoryCleanupInFlight = false
                os_log(
                    .info,
                    log: OSLog.default,
                    "[OPEN SPEECH] Qwen memory cleanup: tracked %.0f -> %.0f MB, cache %.0f -> %.0f MB, combined tracked/process before %.0f/%.0f MB",
                    result.before.mlxTrackedMemoryMb,
                    result.after.mlxTrackedMemoryMb,
                    result.before.mlxCacheMemoryMb,
                    result.after.mlxCacheMemoryMb,
                    combinedTrackedMb,
                    combinedProcessMb
                )
                let estimatedTrackedAfter = backend.mlxTrackedMemoryMb + result.after.mlxTrackedMemoryMb
                let estimatedProcessAfter = backend.memoryUsageMb + Self.currentProcessMemoryUsageMb()
                if estimatedTrackedAfter >= self.combinedLocalMemorySoftLimitMb
                    || estimatedProcessAfter >= self.combinedLocalMemorySoftLimitMb {
                    self.requestLocalASRModelReleaseIfIdle(
                        qwen: result.after,
                        backendTrackedMb: backend.mlxTrackedMemoryMb,
                        backendCacheMb: backend.mlxCacheMemoryMb,
                        combinedTrackedMb: estimatedTrackedAfter,
                        combinedProcessMb: estimatedProcessAfter
                    )
                }
            }
        }
    }

    private func requestBackendMemoryCleanupIfNeeded(
        backend: BackendMemoryMetrics,
        peerTrackedMemoryMb: Double,
        peerMemoryFootprintMb: Double,
        combinedTrackedMb: Double,
        combinedProcessMb: Double
    ) {
        guard !isBackendMemoryCleanupInFlight, !isBackendRestartInProgress else { return }
        if let lastBackendMemoryCleanupRequestAt,
           Date().timeIntervalSince(lastBackendMemoryCleanupRequestAt) < 30 {
            return
        }

        isBackendMemoryCleanupInFlight = true
        lastBackendMemoryCleanupRequestAt = Date()
        os_log(
            .info,
            log: OSLog.default,
            "[OPEN SPEECH] Combined memory soft limit reached: backend_rss=%.0f MB backend_cache=%.0f MB backend_tracked=%.0f MB peer_qwen=%.0f MB combined_tracked=%.0f MB combined_process=%.0f MB; requesting backend cleanup",
            backend.memoryUsageMb,
            backend.mlxCacheMemoryMb,
            backend.mlxTrackedMemoryMb,
            peerMemoryFootprintMb,
            combinedTrackedMb,
            combinedProcessMb
        )

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8001/api/memory/cleanup")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        configureBackendIdentityHeader(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "reason": "combined-memory-supervisor",
            "globalSoftLimitMb": combinedLocalMemorySoftLimitMb,
            "peerMlxTrackedMemoryMb": peerTrackedMemoryMb,
            "peerMemoryFootprintMb": peerMemoryFootprintMb,
        ])
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isBackendMemoryCleanupInFlight = false
            }
            guard error == nil,
                  self.isExpectedBackendResponse(response),
                  let data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let after = Self.doubleValue(json, "memoryUsageMb")
            let afterTracked = Self.doubleValue(json, "mlxTrackedMemoryMb")
            let needsRestart = Self.boolValue(json, "needsBackendRestart")
            os_log(
                .info,
                log: OSLog.default,
                "[OPEN SPEECH] Backend memory cleanup finished: rss=%.0f MB tracked=%.0f MB",
                after,
                afterTracked
            )
            if needsRestart {
                DispatchQueue.main.async {
                    self.requestBackendRestart(
                        reason: String(
                            format: "backend requested restart after cache cleanup: rss=%.0f MB tracked=%.0f MB",
                            after,
                            afterTracked
                        )
                    )
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.backendRestartIdleDelay) {
                    self.checkBackendMemory()
                }
            }
        }.resume()
    }

    private func requestLocalASRModelReleaseIfIdle(
        qwen: LocalMLXMemorySnapshot,
        backendTrackedMb: Double,
        backendCacheMb: Double,
        combinedTrackedMb: Double,
        combinedProcessMb: Double
    ) {
        if let lastLocalASRModelReleaseRequestAt,
           Date().timeIntervalSince(lastLocalASRModelReleaseRequestAt) < 30 {
            return
        }
        guard appState.asrEngineMode == .qwenNative,
              !appState.isRecording,
              !appState.isTranscribing,
              !isLocalASRMemoryReleaseInFlight,
              qwen.mlxCacheMemoryMb <= 128,
              backendCacheMb <= 256,
              qwen.mlxTrackedMemoryMb > 512 else { return }

        isLocalASRMemoryReleaseInFlight = true
        lastLocalASRModelReleaseRequestAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let result = await self.appState.releaseLocalASRModelForMemoryPressure(
                reason: String(
                    format: "combined tracked/process %.0f/%.0f MB over 8GB budget with backend %.0f MB",
                    combinedTrackedMb,
                    combinedProcessMb,
                    backendTrackedMb
                )
            )
            await MainActor.run {
                self.isLocalASRMemoryReleaseInFlight = false
                os_log(
                    .info,
                    log: OSLog.default,
                    "[OPEN SPEECH] Qwen model released under combined memory pressure: tracked %.0f -> %.0f MB",
                    result.before.mlxTrackedMemoryMb,
                    result.after.mlxTrackedMemoryMb
                )
                self.scheduleCombinedMemoryCheckAfterIdle()
            }
        }
    }

    private var hasRecentLocalASRModelReleaseRequest: Bool {
        guard let lastLocalASRModelReleaseRequestAt else { return false }
        return Date().timeIntervalSince(lastLocalASRModelReleaseRequestAt) < 30
    }

    private func requestBackendRestart(reason: String) {
        guard !isBackendRestartInProgress else { return }
        if pendingBackendRestartReason == nil {
            pendingBackendRestartReason = reason
            os_log(.info, log: OSLog.default, "[OPEN SPEECH] Backend restart requested: %{public}@", reason)
        }
        schedulePendingBackendRestartIfIdle()
    }

    private func schedulePendingBackendRestartIfIdle() {
        guard pendingBackendRestartReason != nil,
              scheduledBackendRestart == nil,
              !isBackendRestartInProgress,
              !appState.isRecording,
                  !appState.isTranscribing,
                  appState.shouldRunLocalGemmaBackend else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let reason = self.pendingBackendRestartReason,
                  !self.appState.isRecording,
                  !self.appState.isTranscribing,
                  self.appState.shouldRunLocalGemmaBackend else { return }
            self.scheduledBackendRestart = nil
            self.restartLocalInferenceServer(reason: reason)
        }
        scheduledBackendRestart = workItem
        os_log(
            .info,
            log: OSLog.default,
            "[OPEN SPEECH] Backend restart scheduled after %.1f seconds of dictation idle time",
            backendRestartIdleDelay
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + backendRestartIdleDelay, execute: workItem)
    }

    private func restartLocalInferenceServer(reason: String) {
        guard !isBackendRestartInProgress, !isTerminating else { return }
        isBackendRestartInProgress = true
        pendingBackendRestartReason = nil
        scheduledBackendRestart?.cancel()
        scheduledBackendRestart = nil
        stopBackendMemoryMonitoring()
        stopHealthPolling()

        let startedAt = Date()
        os_log(.info, log: OSLog.default, "[OPEN SPEECH] Restarting local backend: %{public}@", reason)
        stopLocalInferenceServer()
        guard startLocalInferenceServer() else {
            isBackendRestartInProgress = false
            showModelLoadError(reason: "推理服务内存重启后启动失败")
            return
        }
        startHealthPolling()
        waitForRestartedBackendHealthy(startedAt: startedAt, attempt: 0)
    }

    private func waitForRestartedBackendHealthy(startedAt: Date, attempt: Int) {
        guard isBackendRestartInProgress, !isTerminating else { return }
        let url = URL(string: "http://127.0.0.1:8001/health")!
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        configureBackendIdentityHeader(&request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            var isHealthy = false
            if self.isExpectedBackendResponse(response),
               let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let modelLoaded = json["modelLoaded"] as? Bool,
               let asrLoaded = json["asrLoaded"] as? Bool {
                isHealthy = modelLoaded && (!self.appState.shouldRunSenseVoiceASRBackend || asrLoaded)
            }

            DispatchQueue.main.async {
                guard self.isBackendRestartInProgress else { return }
                if isHealthy {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    self.isBackendRestartInProgress = false
                    self.startBackendMemoryMonitoring()
                    os_log(.info, log: OSLog.default, "[OPEN SPEECH] Backend restart healthy in %.2f seconds", elapsed)
                    return
                }

                if attempt >= 120 {
                    self.isBackendRestartInProgress = false
                    self.showModelLoadError(reason: "推理服务内存重启后加载超时")
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.waitForRestartedBackendHealthy(startedAt: startedAt, attempt: attempt + 1)
                }
            }
        }.resume()
    }

    // MARK: - System Version Check

    private func checkSystemVersion() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion < 15 {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "系统版本过低"
                alert.informativeText = """
                当前 macOS 版本：\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)

                Open Speech ASR 建议在 macOS 15 或更高版本上运行。
                低版本系统可能导致 Qwen3-ASR 或 MLX 无法正确加载。

                请考虑升级系统后重试。
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "我知道了")
                alert.runModal()
            }
        }
    }

    // MARK: - Server Health Polling

    private func startHealthPolling() {
        serverLoadStartTime = Date()
        hasShownModelError = false
        healthPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkServerHealth()
        }
    }

    private func stopHealthPolling() {
        healthPollTimer?.invalidate()
        healthPollTimer = nil
        serverLoadStartTime = nil
    }

    private func checkServerHealth() {
        guard !isTerminating, appState.shouldRunLocalGemmaBackend else { return }

        // Check if server process died
        if let process = serverProcess, !process.isRunning {
            stopHealthPolling()
            if !isStoppingLocalInferenceServer {
                showModelLoadError(reason: "推理服务进程意外退出")
            }
            return
        }

        // Timeout: 120 seconds for model loading
        if let startTime = serverLoadStartTime,
           Date().timeIntervalSince(startTime) > 120 {
            stopHealthPolling()
            showModelLoadError(reason: "模型加载超时（超过 120 秒）")
            return
        }

        // Poll /health endpoint
        let url = URL(string: "http://127.0.0.1:8001/health")!
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        configureBackendIdentityHeader(&request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Server not yet responding — that's OK during startup
            if error != nil { return }

            guard self.isExpectedBackendResponse(response),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelLoaded = json["modelLoaded"] as? Bool,
                  let asrLoaded = json["asrLoaded"] as? Bool else {
                return
            }

            let backendReady = modelLoaded && (!self.appState.shouldRunSenseVoiceASRBackend || asrLoaded)
            if backendReady {
                // Models loaded successfully — stop polling
                DispatchQueue.main.async {
                    self.stopHealthPolling()
                    os_log(.info, log: OSLog.default, "[OPEN SPEECH] Local Gemma backend loaded successfully")
                }
            }
        }.resume()
    }

    private func showModelLoadError(reason: String) {
        guard !hasShownModelError else { return }
        hasShownModelError = true

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "本地 Gemma 纠错未正常启动"
            alert.informativeText = "\(reason)。\n\n这会影响「Qwen3-ASR + Gemma E4B」和「SenseVoice + Gemma E4B」模式；你可以临时切到第三方 API 模式继续使用。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
}
