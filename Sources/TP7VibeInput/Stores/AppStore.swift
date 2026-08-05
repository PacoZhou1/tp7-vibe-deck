import AppKit
import AVFoundation
import Foundation
import OSLog
import ServiceManagement

private let appStoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.paco.TP7VibeInput",
    category: "AppStore"
)

@MainActor
final class AppStore: ObservableObject {
    private static let mappingProfileKey = "tp7MappingProfile.v1"
    private static let defaultActionMigrationKey = "tp7MappingProfile.defaultActions.v2.migrated"

    @Published private(set) var audioDevices: [AudioInputDevice] = []
    @Published private(set) var midiEndpoints: [MIDIEndpointInfo] = []
    @Published private(set) var midiEvents: [TP7ControlEvent] = []
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var midiOutputActive = false
    @Published private(set) var openSpeechHoldShortcut = "Unknown"
    @Published private(set) var openSpeechToggleShortcut = "Unknown"
    @Published private(set) var audioWarmupActive = false
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published var showAccessibilityPermissionPrompt = false
    @Published var mappingProfile: TP7MappingProfile {
        didSet {
            saveMappingProfile()
        }
    }
    @Published var selectedInputRole: TP7InputRole = .wheel
    @Published var learningRole: TP7InputRole?
    @Published var statusMessage = "Starting..."

    private let deviceMonitor = TP7DeviceMonitor()
    private let midiListener = TP7MIDIListener()
    private let audioRecorder = AudioRecorder()
    private let audioWarmer = AudioInputWarmer()
    private let injector = TextInjector()
    private let openSpeechBridge = OpenSpeechShortcutBridge()
    private let openSpeechIntegration = OpenSpeechIntegrationService()
    private let hermesLauncher = HermesAgentLauncher()
    private var didStart = false
    private var accessibilityMonitorTimer: Timer?
    private var midiRecoveryTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var cursorHoldTimer: Timer?
    private var cursorHoldAutoStopTimer: Timer?
    private var cursorHoldStartedAt: Date?
    private var cursorHoldDirection: CursorHoldDirection?
    private var cursorHoldSpeed: CursorMoveSpeed = .slow
    private var cursorHoldTimerIsRepeating = false
    private var sideScrollTimer: Timer?
    private var sideScrollSteps: Int32 = 0
    private let sideRockerDeadzone = 600
    private var sideRockerIgnoreUntil: Date?
    private var hermesLaunchTimer: Timer?
    private var hermesLaunchTriggeredThisHold = false

    init() {
        mappingProfile = Self.loadMappingProfile()
    }

    var isRecording: Bool {
        if case .recording = recordingState { true } else { false }
    }

    var menuBarSymbol: String {
        if isRecording { return "record.circle.fill" }
        if hasTP7Audio && hasTP7MIDI { return "waveform.circle.fill" }
        return "waveform.circle"
    }

    var hasTP7Audio: Bool {
        audioDevices.contains(where: \.isTP7)
    }

    var hasTP7MIDI: Bool {
        midiEndpoints.contains { $0.direction == .source && $0.isTP7 }
    }

    var hasTP7MIDIOutput: Bool {
        midiEndpoints.contains { $0.direction == .destination && $0.isTP7 }
    }

    var selectedAudioDevice: AudioInputDevice? {
        audioDevices.first(where: \.isTP7) ?? audioDevices.first
    }

    var openSpeechBridgeActive: Bool {
        openSpeechBridge.isHoldingOpenSpeech
    }

    var selectedMapping: TP7ButtonMapping? {
        mappingProfile.mapping(for: selectedInputRole)
    }

    var openSpeechPresets: [(id: String, name: String)] {
        openSpeechIntegration.availablePresets()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshAccessibilityPermission()
        startAccessibilityPermissionMonitoring()
        startMIDIRecoveryMonitoring()
        refreshLaunchAtLoginStatus()
        refreshDevices()
        refreshOpenSpeechShortcut()
        presentAccessibilityPromptIfNeeded()
        startAudioWarmupIfPossible(reason: "startup")
        startMIDI()
    }

    func refreshDevices() {
        audioDevices = deviceMonitor.listAudioInputDevices()
        midiEndpoints = deviceMonitor.listMIDIEndpoints()
        midiListener.refreshConnections()
        if audioWarmer.activeDeviceUID == nil {
            audioWarmupActive = false
        }
        if hasTP7Audio && hasTP7MIDI && hasTP7MIDIOutput {
            statusMessage = "TP-7 audio and MIDI connected"
        } else if hasTP7Audio {
            statusMessage = "TP-7 audio connected; waiting for MIDI events"
        } else {
            statusMessage = "TP-7 audio input not found"
        }
    }

    func activateTP7Control() {
        if midiListener.activateControl() {
            midiOutputActive = true
            statusMessage = "Sent TP-7 remote-control test messages"
        } else {
            midiOutputActive = false
            statusMessage = "TP-7 MIDI output not found"
        }
    }

    func requestAccessibilityPermission() {
        injector.requestAccessibilityPermission()
        refreshAccessibilityPermission()
    }

    func requestAccessibilityPermissionFromPrompt() {
        injector.requestAccessibilityPermission()
        injector.openAccessibilitySettings()
        refreshAccessibilityPermission()
        statusMessage = "Enable Accessibility for TP7 Vibe Deck, then press REC again"
    }

    func presentAccessibilityPromptIfNeeded() {
        refreshAccessibilityPermission()
        guard !accessibilityTrusted else { return }
        showAccessibilityPermissionPrompt = true
    }

    func refreshAccessibilityPermission() {
        let trusted = injector.isAccessibilityTrusted
        if trusted != accessibilityTrusted {
            appStoreLog.info("Accessibility permission changed trusted=\(trusted, privacy: .public)")
            if trusted {
                midiListener.rebuild()
            }
        }
        accessibilityTrusted = trusted
        if trusted, showAccessibilityPermissionPrompt {
            showAccessibilityPermissionPrompt = false
            statusMessage = "Accessibility permission enabled"
        }
    }

    func refreshOpenSpeechShortcut() {
        openSpeechHoldShortcut = openSpeechBridge.describeConfiguredHoldShortcut()
        openSpeechToggleShortcut = openSpeechBridge.describeConfiguredToggleShortcut()
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.statusMessage = granted ? "Microphone permission granted" : "Microphone permission denied"
                if granted {
                    self?.startAudioWarmupIfPossible(reason: "microphone permission")
                }
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            statusMessage = enabled ? "TP7 Vibe Deck will open at login" : "TP7 Vibe Deck removed from login items"
            appStoreLog.info("Launch at login changed enabled=\(enabled, privacy: .public)")
        } catch {
            refreshLaunchAtLoginStatus()
            statusMessage = "Could not update launch at login: \(error.localizedDescription)"
            appStoreLog.error("Launch at login update failed enabled=\(enabled, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func startAudioWarmupIfPossible(reason: String) {
        guard !audioWarmupActive else { return }
        guard let device = selectedAudioDevice, device.isTP7 else { return }
        do {
            try audioWarmer.start(device: device)
            audioWarmupActive = true
            statusMessage = "TP-7 audio warmup active"
            appStoreLog.info("Audio warmup active reason=\(reason, privacy: .public)")
        } catch AudioInputWarmerError.alreadyRunning {
            audioWarmupActive = true
        } catch {
            audioWarmupActive = false
            statusMessage = "TP-7 audio warmup failed: \(error.localizedDescription)"
            appStoreLog.error("Audio warmup failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func startRecording(trigger: String) {
        guard !isRecording else { return }
        do {
            let device = selectedAudioDevice
            let url = try audioRecorder.start(device: device)
            lastRecordingURL = url
            recordingState = .recording(startedAt: Date())
            statusMessage = "Recording from \(device?.name ?? "default input")"
        } catch {
            recordingState = .error(error.localizedDescription)
            statusMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording(trigger: String) {
        guard isRecording else { return }
        do {
            let url = try audioRecorder.stop()
            lastRecordingURL = url
            recordingState = .idle
            statusMessage = "Saved WAV: \(url.lastPathComponent)"
        } catch {
            recordingState = .error(error.localizedDescription)
            statusMessage = "Stop failed: \(error.localizedDescription)"
        }
    }

    func cancelRecording(trigger: String) {
        guard isRecording else { return }
        audioRecorder.cancel()
        recordingState = .idle
        statusMessage = "Recording cancelled"
    }

    func pasteDiagnosticText() {
        injector.paste("TP7 Vibe Deck diagnostic paste")
    }

    func beginOpenSpeechHold(trigger: String) {
        startAudioWarmupIfPossible(reason: trigger)
        refreshOpenSpeechShortcut()
        refreshAccessibilityPermission()
        do {
            let shortcut = try openSpeechBridge.beginHold()
            openSpeechHoldShortcut = shortcut
            statusMessage = "TP-7 REC holding Open Speech: \(shortcut)"
        } catch {
            refreshAccessibilityPermission()
            if !accessibilityTrusted {
                showAccessibilityPermissionPrompt = true
            }
            statusMessage = error.localizedDescription
        }
    }

    func endOpenSpeechHold(trigger: String) {
        if let shortcut = openSpeechBridge.endHold() {
            statusMessage = "TP-7 REC released Open Speech: \(shortcut)"
        }
    }

    func pressReturnFromTP7(trigger: String) {
        refreshAccessibilityPermission()
        guard accessibilityTrusted else {
            showAccessibilityPermissionPrompt = true
            statusMessage = "Accessibility permission required for PLAY to Return"
            return
        }
        injector.pressReturn()
        statusMessage = "TP-7 PLAY pressed Return"
        appStoreLog.info("PLAY mapped to Return trigger=\(trigger, privacy: .public)")
    }

    func scrollFromTP7Wheel(value: UInt8) {
        dispatchWheel(rawValue: value)
    }

    func startLearning(_ role: TP7InputRole) {
        learningRole = role
        selectedInputRole = role
        statusMessage = "Press the TP-7 control for \(role.title)"
    }

    func cancelLearning() {
        learningRole = nil
        statusMessage = "Learning cancelled"
    }

    func updateAction(for role: TP7InputRole, kind: TP7ActionKind) {
        var mapping = mappingProfile.mapping(for: role) ?? TP7ButtonMapping(role: role, signature: role.defaultSignature, action: .none)
        mapping.action.kind = kind
        if kind != .openSpeechPreset {
            mapping.action.presetID = nil
        } else if mapping.action.presetID == nil {
            mapping.action.presetID = openSpeechIntegration.selectedPresetID
        }
        if kind != .customShortcut {
            mapping.action.shortcut = nil
        }
        if kind == .cursorLeftHold || kind == .cursorRightHold {
            mapping.action.cursorSpeed = mapping.action.cursorSpeed ?? .slow
        } else {
            mapping.action.cursorSpeed = nil
        }
        if kind == .verticalScroll {
            mapping.action.scrollSensitivity = mapping.action.scrollSensitivity ?? 1.0
        } else {
            mapping.action.scrollSensitivity = nil
        }
        mappingProfile.updateMapping(mapping)
    }

    func updateCursorSpeed(for role: TP7InputRole, speed: CursorMoveSpeed) {
        var mapping = mappingProfile.mapping(for: role) ?? TP7ButtonMapping(role: role, signature: role.defaultSignature, action: .none)
        mapping.action.cursorSpeed = speed
        mappingProfile.updateMapping(mapping)
    }

    func updateScrollSensitivity(for role: TP7InputRole, sensitivity: Double) {
        var mapping = mappingProfile.mapping(for: role) ?? TP7ButtonMapping(role: role, signature: role.defaultSignature, action: .none)
        mapping.action.scrollSensitivity = Self.clampWheelSensitivity(sensitivity)
        mappingProfile.updateMapping(mapping)
    }

    func updatePreset(for role: TP7InputRole, presetID: String) {
        var mapping = mappingProfile.mapping(for: role) ?? TP7ButtonMapping(role: role, signature: role.defaultSignature, action: .none)
        mapping.action.kind = .openSpeechPreset
        mapping.action.presetID = presetID
        mappingProfile.updateMapping(mapping)
    }

    func updateShortcut(for role: TP7InputRole, shortcut: ShortcutBinding) {
        var mapping = mappingProfile.mapping(for: role) ?? TP7ButtonMapping(role: role, signature: role.defaultSignature, action: .none)
        mapping.action.kind = .customShortcut
        mapping.action.shortcut = shortcut
        mappingProfile.updateMapping(mapping)
    }

    func updateWheel(
        mode: WheelMode? = nil,
        sensitivity: Double? = nil,
        inverted: Bool? = nil,
        cursorSpeed: CursorMoveSpeed? = nil
    ) {
        if let mode {
            mappingProfile.wheel.mode = mode
        }
        if let sensitivity {
            mappingProfile.wheel.sensitivity = Self.clampWheelSensitivity(sensitivity)
        }
        if let inverted {
            mappingProfile.wheel.inverted = inverted
        }
        if let cursorSpeed {
            mappingProfile.wheel.cursorSpeed = cursorSpeed
        }
    }

    func resetMappings() {
        mappingProfile = .defaults
        selectedInputRole = .wheel
        learningRole = nil
        statusMessage = "Mappings reset"
    }

    private func dispatchWheel(rawValue value: UInt8) {
        let relative = Self.signedSevenBitRelative(value)
        guard relative != 0 else { return }
        refreshAccessibilityPermission()
        guard accessibilityTrusted else {
            showAccessibilityPermissionPrompt = true
            statusMessage = "Accessibility permission required for wheel scrolling"
            return
        }
        let direction = mappingProfile.wheel.inverted ? -relative : relative
        let scaled = Double(direction) * mappingProfile.wheel.sensitivity
        var adjusted = Int(scaled.rounded(.toNearestOrAwayFromZero))
        if adjusted == 0 {
            adjusted = direction > 0 ? 1 : -1
        }
        let steps = max(-24, min(24, adjusted))
        switch mappingProfile.wheel.mode {
        case .verticalScroll:
            injector.scroll(vertical: Int32(steps))
        case .horizontalScroll:
            injector.scroll(horizontal: Int32(steps))
        case .cursorMove:
            let repeatCount = mappingProfile.wheel.cursorSpeed.wheelStepCount
            if direction > 0 {
                sendCursorMove(direction: .right, repeatCount: repeatCount)
                statusMessage = "TP-7 wheel cursor right"
            } else {
                sendCursorMove(direction: .left, repeatCount: repeatCount)
                statusMessage = "TP-7 wheel cursor left"
            }
            appStoreLog.info("Wheel cursor mode raw=\(value) relative=\(relative) direction=\(direction) repeatCount=\(repeatCount)")
        case .volume:
            injector.adjustVolume(steps: steps)
        case .brightness:
            injector.adjustBrightness(steps: steps)
        }
        statusMessage = "TP-7 wheel \(mappingProfile.wheel.mode.title): \(steps)"
        appStoreLog.info("Wheel mapped raw=\(value) relative=\(relative) steps=\(steps)")
    }

    private func startMIDI() {
        midiListener.start { [weak self] event in
            Task { @MainActor in
                self?.handleMIDIEvent(event)
            }
        }
    }

    private func handleMIDIEvent(_ event: TP7ControlEvent) {
        let handledAt = CFAbsoluteTimeGetCurrent()
        midiEvents.insert(event, at: 0)
        if midiEvents.count > 80 {
            midiEvents.removeLast(midiEvents.count - 80)
        }

        if let learningRole, let signature = MIDIInputSignature(event: event), Self.isTriggerDown(event) {
            if let existingRole = mappingProfile.role(for: signature), existingRole != learningRole {
                statusMessage = "\(signature.title) is already used by \(existingRole.title)"
                appStoreLog.info("MIDI learn rejected role=\(learningRole.title, privacy: .public) signature=\(signature.title, privacy: .public) existing=\(existingRole.title, privacy: .public)")
                return
            }
            var mapping = mappingProfile.mapping(for: learningRole) ?? TP7ButtonMapping(role: learningRole, signature: nil, action: .none)
            mapping.signature = signature
            mappingProfile.updateMapping(mapping)
            self.learningRole = nil
            statusMessage = "\(learningRole.title) learned \(signature.title)"
            return
        }

        if dispatchSideRockerIfNeeded(event) {
            return
        }

        guard let signature = MIDIInputSignature(event: event) else {
            statusMessage = event.summary
            return
        }

        if signature == TP7InputRole.wheel.defaultSignature,
           case let .controlChange(_, _, value) = event.kind {
            dispatchWheel(rawValue: value)
            return
        }

        guard let role = mappingProfile.role(for: signature),
              let mapping = mappingProfile.mapping(for: role) else {
            if autoBindSelectedRole(to: signature, event: event) {
                return
            }
            statusMessage = event.summary
            appStoreLog.info("MIDI unmatched \(event.summary, privacy: .public)")
            return
        }

        execute(mapping: mapping, event: event)
        appStoreLog.info("MIDI handled role=\(role.title, privacy: .public) totalMs=\((CFAbsoluteTimeGetCurrent() - handledAt) * 1000, format: .fixed(precision: 3))")
    }

    private func autoBindSelectedRole(to signature: MIDIInputSignature, event: TP7ControlEvent) -> Bool {
        guard selectedInputRole != .wheel,
              Self.isTriggerDown(event),
              var mapping = mappingProfile.mapping(for: selectedInputRole),
              mapping.signature == nil,
              mapping.action.kind != .none else {
            return false
        }
        if let existingRole = mappingProfile.role(for: signature), existingRole != selectedInputRole {
            statusMessage = "\(signature.title) is already used by \(existingRole.title)"
            appStoreLog.info("MIDI auto-bind rejected role=\(self.selectedInputRole.title, privacy: .public) signature=\(signature.title, privacy: .public) existing=\(existingRole.title, privacy: .public)")
            return true
        }

        mapping.signature = signature
        mappingProfile.updateMapping(mapping)
        statusMessage = "\(selectedInputRole.title) learned \(signature.title)"
        appStoreLog.info("MIDI auto-bound role=\(self.selectedInputRole.title, privacy: .public) signature=\(signature.title, privacy: .public)")
        execute(mapping: mapping, event: event)
        return true
    }

    private func dispatchSideRockerIfNeeded(_ event: TP7ControlEvent) -> Bool {
        guard case let .pitchBend(channel, value) = event.kind,
              channel == 1 else {
            return false
        }

        if let sideRockerIgnoreUntil, Date() < sideRockerIgnoreUntil {
            appStoreLog.info("Side rocker pitch ignored during release cooldown value=\(value)")
            return true
        }

        if abs(value) <= sideRockerDeadzone {
            endCursorHold(role: .sideForward)
            endCursorHold(role: .sideBackward)
            endSideScroll()
            sideRockerIgnoreUntil = Date().addingTimeInterval(0.18)
            appStoreLog.info("Side rocker pitch release value=\(value)")
            return true
        }

        let role: TP7InputRole = value > 0 ? .sideForward : .sideBackward
        guard let mapping = mappingProfile.mapping(for: role) else { return true }
        appStoreLog.info("Side rocker pitch role=\(role.title, privacy: .public) value=\(value)")

        switch mapping.action.kind {
        case .cursorRightHold:
            beginCursorHold(direction: .right, role: role, speed: mapping.action.cursorSpeed ?? .medium)
        case .cursorLeftHold:
            beginCursorHold(direction: .left, role: role, speed: mapping.action.cursorSpeed ?? .medium)
        case .verticalScroll:
            scrollFromSideRocker(value: value, mapping: mapping)
        default:
            execute(mapping: mapping, event: event)
        }
        return true
    }

    private func scrollFromSideRocker(value: Int, mapping: TP7ButtonMapping) {
        refreshAccessibilityPermission()
        guard accessibilityTrusted else {
            showAccessibilityPermissionPrompt = true
            statusMessage = "Accessibility permission required for side scrolling"
            return
        }
        let normalized = min(1.0, max(0.15, Double(abs(value)) / 8192.0))
        let sensitivity = mapping.action.scrollSensitivity ?? 1.0
        var steps = Int((normalized * 4.0 * sensitivity).rounded(.toNearestOrAwayFromZero))
        if steps == 0 { steps = 1 }
        steps = min(12, max(1, steps))
        let direction = value > 0 ? steps : -steps
        beginSideScroll(steps: Int32(direction), role: mapping.role)
    }

    private func beginSideScroll(steps: Int32, role: TP7InputRole) {
        guard steps != 0 else { return }
        if sideScrollSteps != steps {
            sideScrollSteps = steps
        }
        if sideScrollTimer == nil {
            injector.scroll(vertical: sideScrollSteps)
            sideScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tickSideScroll()
                }
            }
        }
        statusMessage = "\(role.title) vertical scroll \(sideScrollSteps)"
    }

    private func tickSideScroll() {
        guard sideScrollSteps != 0 else {
            endSideScroll()
            return
        }
        injector.scroll(vertical: sideScrollSteps)
    }

    private func endSideScroll() {
        sideScrollTimer?.invalidate()
        sideScrollTimer = nil
        sideScrollSteps = 0
    }

    private func execute(mapping: TP7ButtonMapping, event: TP7ControlEvent) {
        let isDown = Self.isTriggerDown(event)
        let isUp = Self.isTriggerUp(event)
        let role = mapping.role

        if role == .stop, mapping.action.kind == .none, isDown {
            if openSpeechBridgeActive {
                endOpenSpeechHold(trigger: "\(role.title) default")
            } else if isRecording {
                cancelRecording(trigger: "\(role.title) default")
            } else {
                statusMessage = "STOP received"
            }
            return
        }

        switch mapping.action.kind {
        case .none:
            if isDown {
                statusMessage = "\(role.title): no action"
            }
        case .openSpeechHold:
            if isDown {
                beginOpenSpeechHold(trigger: "\(role.title) hold")
            } else if isUp {
                endOpenSpeechHold(trigger: "\(role.title) release")
            }
        case .openSpeechToggle:
            guard isDown else { return }
            refreshAccessibilityPermission()
            do {
                let shortcut = try openSpeechBridge.triggerToggle()
                statusMessage = "\(role.title) toggled Open Speech: \(shortcut)"
            } catch {
                if !accessibilityTrusted {
                    showAccessibilityPermissionPrompt = true
                }
                statusMessage = error.localizedDescription
            }
        case .openSpeechPreset:
            guard isDown else { return }
            let presetID = mapping.action.presetID ?? openSpeechIntegration.selectedPresetID
            if openSpeechIntegration.applyPreset(presetID) {
                statusMessage = "\(role.title) selected Open Speech \(openSpeechIntegration.presetName(for: presetID))"
            } else {
                statusMessage = "Open Speech preset \(presetID.uppercased()) unavailable"
            }
        case .openSpeechNextPreset:
            guard isDown else { return }
            if let presetID = openSpeechIntegration.applyNextPreset(delta: 1) {
                statusMessage = "\(role.title) selected Open Speech \(openSpeechIntegration.presetName(for: presetID))"
            }
        case .openSpeechPreviousPreset:
            guard isDown else { return }
            if let presetID = openSpeechIntegration.applyNextPreset(delta: -1) {
                statusMessage = "\(role.title) selected Open Speech \(openSpeechIntegration.presetName(for: presetID))"
            }
        case .commandC:
            guard isDown else { return }
            if ensureAccessibility(for: "\(role.title) Command-C") {
                injector.pressCopy()
                statusMessage = "\(role.title) pressed Command-C"
            }
        case .commandV:
            guard isDown else { return }
            if ensureAccessibility(for: "\(role.title) Command-V") {
                injector.pressPaste()
                statusMessage = "\(role.title) pressed Command-V"
            }
        case .returnKey:
            guard isDown else { return }
            if ensureAccessibility(for: "\(role.title) Return") {
                injector.pressReturn()
                statusMessage = "\(role.title) pressed Return"
            }
        case .clearText:
            guard isDown else { return }
            if ensureAccessibility(for: "\(role.title) Clear Text") {
                injector.clearText()
                statusMessage = "\(role.title) cleared text"
            }
        case .cursorLeftHold:
            if isDown {
                beginCursorHold(direction: .left, role: role, speed: mapping.action.cursorSpeed ?? .medium)
            } else if isUp {
                endCursorHold(role: role)
            }
        case .cursorRightHold:
            if isDown {
                beginCursorHold(direction: .right, role: role, speed: mapping.action.cursorSpeed ?? .medium)
            } else if isUp {
                endCursorHold(role: role)
            }
        case .verticalScroll:
            guard isDown else { return }
            injector.scroll(vertical: Int32(mapping.action.scrollSensitivity ?? 1.0))
        case .launchHermesAgent:
            if isDown {
                beginHermesLaunchHold(role: role)
            } else if isUp {
                cancelHermesLaunchHold(role: role)
            }
        case .launchHermesOpenSpeechHold:
            if isDown {
                beginHermesOpenSpeechHold(role: role)
            } else if isUp {
                endHermesOpenSpeechHold(role: role)
            }
        case .customShortcut:
            guard isDown else { return }
            guard let shortcut = mapping.action.shortcut else {
                statusMessage = "\(role.title) needs a recorded shortcut"
                return
            }
            if ensureAccessibility(for: "\(role.title) \(shortcut.displayName)") {
                injector.sendShortcut(shortcut)
                statusMessage = "\(role.title) pressed \(shortcut.displayName)"
            }
        }
    }

    private func beginCursorHold(
        direction: CursorHoldDirection,
        role: TP7InputRole,
        speed: CursorMoveSpeed,
        autoStopAfter: TimeInterval? = nil
    ) {
        guard ensureAccessibility(for: "\(role.title) cursor move") else { return }
        if cursorHoldDirection != direction || cursorHoldSpeed != speed {
            endCursorHold(role: role)
        }
        if cursorHoldTimer != nil {
            if let autoStopAfter {
                scheduleCursorHoldAutoStop(role: role, after: autoStopAfter)
            }
            return
        }
        sendCursorMove(direction: direction, repeatCount: 1)
        appStoreLog.info("Cursor move role=\(role.title, privacy: .public) direction=\(direction.title, privacy: .public) speed=\(speed.title, privacy: .public)")
        if let autoStopAfter {
            scheduleCursorHoldAutoStop(role: role, after: autoStopAfter)
        }
        guard cursorHoldTimer == nil else { return }
        cursorHoldDirection = direction
        cursorHoldSpeed = speed
        cursorHoldStartedAt = Date()
        cursorHoldTimerIsRepeating = false
        cursorHoldTimer = Timer.scheduledTimer(withTimeInterval: speed.firstRepeatDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.tickCursorHold()
            }
        }
        statusMessage = "\(role.title) moving cursor \(direction.title) (\(speed.title.lowercased()))"
    }

    private func scheduleCursorHoldAutoStop(role: TP7InputRole, after delay: TimeInterval) {
        cursorHoldAutoStopTimer?.invalidate()
        cursorHoldAutoStopTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endCursorHold(role: role)
            }
        }
    }

    private func tickCursorHold() {
        guard let direction = cursorHoldDirection,
              let cursorHoldStartedAt else { return }
        let elapsed = Date().timeIntervalSince(cursorHoldStartedAt)
        sendCursorMove(direction: direction, repeatCount: cursorHoldSpeed.repeatCount(elapsed: elapsed))
        if !cursorHoldTimerIsRepeating {
            cursorHoldTimer?.invalidate()
            cursorHoldTimerIsRepeating = true
            cursorHoldTimer = Timer.scheduledTimer(withTimeInterval: cursorHoldSpeed.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tickCursorHold()
                }
            }
        }
    }

    private func endCursorHold(role: TP7InputRole) {
        cursorHoldTimer?.invalidate()
        cursorHoldAutoStopTimer?.invalidate()
        cursorHoldTimer = nil
        cursorHoldAutoStopTimer = nil
        cursorHoldTimerIsRepeating = false
        cursorHoldStartedAt = nil
        if let direction = cursorHoldDirection {
            statusMessage = "\(role.title) stopped cursor \(direction.title)"
        }
        cursorHoldDirection = nil
    }

    private func sendCursorMove(direction: CursorHoldDirection, repeatCount: Int) {
        switch direction {
        case .left:
            injector.pressLeftArrow(repeatCount: repeatCount)
        case .right:
            injector.pressRightArrow(repeatCount: repeatCount)
        }
    }

    private func beginHermesLaunchHold(role: TP7InputRole) {
        hermesLaunchTimer?.invalidate()
        hermesLaunchTriggeredThisHold = false
        hermesLaunchTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hermesLaunchTimer = nil
                self?.launchHermesAgentOnce(role: role)
            }
        }
        statusMessage = "Hold \(role.title) to launch Hermes"
    }

    private func cancelHermesLaunchHold(role: TP7InputRole) {
        hermesLaunchTimer?.invalidate()
        hermesLaunchTimer = nil
        if !hermesLaunchTriggeredThisHold {
            statusMessage = "\(role.title) Hermes launch cancelled"
        }
        hermesLaunchTriggeredThisHold = false
    }

    private func beginHermesOpenSpeechHold(role: TP7InputRole) {
        hermesLaunchTimer?.invalidate()
        hermesLaunchTriggeredThisHold = false
        hermesLaunchTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hermesLaunchTimer = nil
                self.launchHermesAgentOnce(role: role)
                self.beginOpenSpeechHold(trigger: "\(role.title) Hermes hold")
            }
        }
        statusMessage = "Tap \(role.title) for Hermes, hold for Hermes + Open Speech"
    }

    private func endHermesOpenSpeechHold(role: TP7InputRole) {
        if hermesLaunchTimer != nil {
            hermesLaunchTimer?.invalidate()
            hermesLaunchTimer = nil
            launchHermesAgentOnce(role: role)
        } else {
            endOpenSpeechHold(trigger: "\(role.title) Hermes release")
        }
        hermesLaunchTriggeredThisHold = false
    }

    private func launchHermesAgentOnce(role: TP7InputRole) {
        guard !hermesLaunchTriggeredThisHold else { return }
        hermesLaunchTriggeredThisHold = true
        do {
            try hermesLauncher.launch()
            statusMessage = "\(role.title) launched Hermes Agent"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func ensureAccessibility(for action: String) -> Bool {
        refreshAccessibilityPermission()
        guard accessibilityTrusted else {
            showAccessibilityPermissionPrompt = true
            statusMessage = "Accessibility permission required for \(action)"
            return false
        }
        return true
    }

    private static func signedSevenBitRelative(_ value: UInt8) -> Int {
        value < 64 ? Int(value) : Int(value) - 128
    }

    private static func clampWheelSensitivity(_ value: Double) -> Double {
        min(max(value, 0.1), 5.0)
    }

    private static func isTriggerDown(_ event: TP7ControlEvent) -> Bool {
        switch event.kind {
        case let .controlChange(_, _, value):
            value > 0
        case let .note(_, _, _, isOn):
            isOn
        case let .pitchBend(_, value):
            value != 0
        case .raw:
            false
        }
    }

    private static func isTriggerUp(_ event: TP7ControlEvent) -> Bool {
        switch event.kind {
        case let .controlChange(_, _, value):
            value == 0
        case let .note(_, _, _, isOn):
            !isOn
        case let .pitchBend(_, value):
            value == 0
        case .raw:
            false
        }
    }

    private static func loadMappingProfile() -> TP7MappingProfile {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: mappingProfileKey),
              var profile = try? JSONDecoder().decode(TP7MappingProfile.self, from: data) else {
            return .defaults
        }
        var didMigrateDefaults = false
        if !defaults.bool(forKey: defaultActionMigrationKey) {
            migrateDefaultActionIfNeeded(role: .sideForward, action: .cursorRightHold, profile: &profile)
            migrateDefaultActionIfNeeded(role: .sideBackward, action: .cursorLeftHold, profile: &profile)
            migrateDefaultActionIfNeeded(role: .memo, action: .launchHermesAgent, profile: &profile)
            defaults.set(true, forKey: defaultActionMigrationKey)
            didMigrateDefaults = true
        }
        let cleanedDuplicates = removeDuplicateSignatures(from: &profile)
        let repairedCursorMappings = repairCursorMappings(in: &profile)
        let filledDefaultSignatures = fillMissingDefaultSignatures(in: &profile)
        if cleanedDuplicates || repairedCursorMappings || filledDefaultSignatures || didMigrateDefaults,
           let migratedData = try? JSONEncoder().encode(profile) {
            defaults.set(migratedData, forKey: mappingProfileKey)
        }
        return profile
    }

    private static func repairCursorMappings(in profile: inout TP7MappingProfile) -> Bool {
        var changed = false
        let plusSignature = MIDIInputSignature.controlChange(channel: 1, controller: 26)

        if let sideForwardIndex = profile.buttons.firstIndex(where: { $0.role == .sideForward }),
           profile.buttons[sideForwardIndex].signature == plusSignature {
            profile.buttons[sideForwardIndex].signature = nil
            changed = true
        }

        if let plusIndex = profile.buttons.firstIndex(where: { $0.role == .plus }),
           profile.buttons[plusIndex].signature == nil,
           profile.role(for: plusSignature) == nil {
            profile.buttons[plusIndex].signature = plusSignature
            changed = true
        }

        if let sideForwardIndex = profile.buttons.firstIndex(where: { $0.role == .sideForward }),
           profile.buttons[sideForwardIndex].action.kind == .none {
            profile.buttons[sideForwardIndex].action = .cursorRightHold
            changed = true
        }

        if let sideBackwardIndex = profile.buttons.firstIndex(where: { $0.role == .sideBackward }),
           profile.buttons[sideBackwardIndex].action.kind == .none {
            profile.buttons[sideBackwardIndex].action = .cursorLeftHold
            changed = true
        }

        return changed
    }

    private static func fillMissingDefaultSignatures(in profile: inout TP7MappingProfile) -> Bool {
        var changed = false
        for index in profile.buttons.indices where profile.buttons[index].signature == nil {
            guard let signature = profile.buttons[index].role.defaultSignature,
                  profile.role(for: signature) == nil else { continue }
            profile.buttons[index].signature = signature
            changed = true
        }
        return changed
    }

    @discardableResult
    private static func removeDuplicateSignatures(from profile: inout TP7MappingProfile) -> Bool {
        var seen: [MIDIInputSignature: TP7InputRole] = [:]
        var changed = false
        for index in profile.buttons.indices {
            guard let signature = profile.buttons[index].signature else { continue }
            if seen[signature] != nil {
                profile.buttons[index].signature = nil
                changed = true
            } else {
                seen[signature] = profile.buttons[index].role
            }
        }
        return changed
    }

    private static func migrateDefaultActionIfNeeded(
        role: TP7InputRole,
        action: TP7ActionConfig,
        profile: inout TP7MappingProfile
    ) {
        guard let existing = profile.mapping(for: role),
              existing.action.kind == .none else { return }
        var migrated = existing
        migrated.action = action
        profile.updateMapping(migrated)
    }

    private func saveMappingProfile() {
        guard let data = try? JSONEncoder().encode(mappingProfile) else { return }
        UserDefaults.standard.set(data, forKey: Self.mappingProfileKey)
    }

    private func startAccessibilityPermissionMonitoring() {
        guard accessibilityMonitorTimer == nil else { return }
        accessibilityMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermission()
            }
        }

        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermission()
            }
        }
    }

    private func startMIDIRecoveryMonitoring() {
        guard midiRecoveryTimer == nil else { return }
        midiRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.midiListener.refreshConnections()
            }
        }
    }

    deinit {
        accessibilityMonitorTimer?.invalidate()
        midiRecoveryTimer?.invalidate()
        cursorHoldTimer?.invalidate()
        cursorHoldAutoStopTimer?.invalidate()
        sideScrollTimer?.invalidate()
        hermesLaunchTimer?.invalidate()
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }
}

private enum CursorHoldDirection {
    case left
    case right

    var title: String {
        switch self {
        case .left: "left"
        case .right: "right"
        }
    }
}
