import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingStatusInfo = false

    var body: some View {
        LiquidGlassGroup {
            ZStack(alignment: .topTrailing) {
                appBackground

                deviceStage

                statusActionPanel
                    .frame(width: 190)
                    .padding(.leading, 22)
                    .padding(.top, 132)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zIndex(1)

                inspector
                    .frame(width: 360)
                    .padding(.trailing, 22)
                    .padding(.top, 124)
                    .padding(.bottom, 90)
                    .zIndex(1)

                topControls
                    .padding(.top, 18)
                    .padding(.trailing, 22)
                    .zIndex(3)

                if showingStatusInfo {
                    StatusInfoPopover()
                        .environmentObject(store)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(.white.opacity(0.28), lineWidth: 0.8)
                        }
                        .shadow(color: .black.opacity(0.10), radius: 22, y: 12)
                        .padding(.top, 64)
                        .padding(.trailing, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                        .zIndex(4)
                }
            }
        }
        .tint(.purple)
    }

    private var appBackground: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.34),
                    Color.accentColor.opacity(0.035),
                    Color.black.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var deviceStage: some View {
        ZStack {
            TP7DeviceSceneView(selectedRole: store.selectedInputRole)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 122)
                .padding(.bottom, 98)
                .padding(.leading, 205)
                .padding(.trailing, 376)

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.vertical, 15)
                    .liquidGlassPanel(cornerRadius: 18)

                Spacer(minLength: 0)

                inputStrip
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlassPanel(cornerRadius: 18, shadow: false)
            }
            .padding(22)
        }
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            Button {
                showingStatusInfo.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Circle())
            .help("Connection and permission status")

            Button {
                store.refreshDevices()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Circle())
            .help("Refresh devices")
        }
    }

    private var statusActionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelSectionTitle("Status")

            VStack(alignment: .leading, spacing: 18) {
                sideStatusRow(
                    title: "Audio Warmup",
                    detail: store.audioWarmupActive ? "Active" : "Idle",
                    systemImage: "waveform",
                    active: store.audioWarmupActive
                )
                sideStatusRow(
                    title: "Mic Warmup",
                    detail: store.hasTP7Audio ? "Active" : "Missing",
                    systemImage: "mic",
                    active: store.hasTP7Audio
                )
            }

            Divider()

            panelSectionTitle("Quick Actions")

            VStack(spacing: 8) {
                quickAction("Open Speech", systemImage: "waveform.badge.mic") {
                    store.selectedInputRole = .rec
                }
                quickAction("Hold", systemImage: "record.circle") {
                    store.selectedInputRole = .rec
                }
                quickAction("Toggle", systemImage: "switch.2") {
                    store.selectedInputRole = .play
                }
                quickAction("Mic Warmup", systemImage: "mic") {
                    store.startAudioWarmupIfPossible(reason: "quick action")
                }
            }

            Divider()

            panelSectionTitle("MIDI Events")

            Text(store.midiEvents.first?.summary ?? "Press a TP-7 control to see events.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.30), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.075), radius: 22, y: 12)
    }

    private func panelSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func sideStatusRow(title: String, detail: String, systemImage: String, active: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(active ? Color.green : .secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 24)
        }
    }

    private func quickAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 0.7)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("TP7 Vibe Deck")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Circle()
                        .fill(store.hasTP7Audio ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(store.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                statusPill(
                    title: "Audio",
                    active: store.hasTP7Audio,
                    systemImage: store.hasTP7Audio ? "waveform.circle.fill" : "waveform.circle"
                )
                statusPill(
                    title: "MIDI",
                    active: store.hasTP7MIDI,
                    systemImage: store.hasTP7MIDI ? "dot.radiowaves.left.and.right" : "exclamationmark.circle"
                )
                statusPill(
                    title: "Mic",
                    active: store.audioWarmupActive,
                    systemImage: "mic.circle"
                )
            }
        }
    }

    private func statusPill(title: String, active: Bool, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .liquidGlassControl(selected: active, cornerRadius: 13)
            .help(active ? "\(title) ready" : "\(title) not ready")
    }

    private var inputStrip: some View {
        DragScrollableHorizontalView {
            HStack(spacing: 10) {
                ForEach(inputStripRoles) { role in
                    RolePill(
                        role: role,
                        selected: store.selectedInputRole == role,
                        learned: role.isWheel || store.mappingProfile.mapping(for: role)?.signature != nil
                    ) {
                        store.selectedInputRole = role
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .frame(height: 54)
    }

    private var inputStripRoles: [TP7InputRole] {
        [
            .rec,
            .play,
            .stop,
            .wheel,
            .plus,
            .minus,
            .sideForward,
            .sideBackward,
            .memo,
            .menu,
            .learned1,
            .learned2,
            .learned3,
            .learned4
        ]
    }

    private var inspector: some View {
        LiquidGlassGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    selectedInputHeader

                    if store.selectedInputRole.isWheel {
                        inspectorSection("Wheel", systemImage: "dial.medium") {
                            wheelEditor
                        }
                    } else {
                        inspectorSection("Mapping", systemImage: "slider.horizontal.3") {
                            buttonEditor
                        }
                    }

                    inspectorSection("Open Speech", systemImage: "waveform.badge.mic") {
                        openSpeechStatus
                    }

                    inspectorSection("MIDI Events", systemImage: "list.bullet.rectangle") {
                        midiEvents
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 28, y: 14)
            .frame(maxHeight: 650, alignment: .top)
        }
    }

    private var selectedInputHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: store.selectedInputRole.systemImage)
                .font(.title3)
                .frame(width: 38, height: 38)
                .liquidGlassControl(selected: true, cornerRadius: 15)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.selectedInputRole.title)
                    .font(.title3.weight(.semibold))
                Text(selectedInputSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()
        }
    }

    private var selectedInputSubtitle: String {
        if let mapping = store.selectedMapping, let signature = mapping.signature {
            return signature.title
        }
        if store.selectedInputRole.isWheel {
            return "CC ch1 #30"
        }
        return "Not learned yet"
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)

            content()
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 0.7)
        }
    }

    private var buttonEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Action", selection: actionBinding) {
                ForEach(TP7ActionKind.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .frame(maxWidth: 230)

            if actionBinding.wrappedValue == .openSpeechPreset {
                Picker("Preset", selection: presetBinding) {
                    ForEach(store.openSpeechPresets, id: \.id) { preset in
                        Text("\(preset.id.uppercased()) - \(preset.name)").tag(preset.id)
                    }
                }
                .frame(maxWidth: 230)
            }

            if actionBinding.wrappedValue == .customShortcut {
                ShortcutRecorderView(shortcut: shortcutBinding)
            }

            if actionBinding.wrappedValue == .cursorLeftHold || actionBinding.wrappedValue == .cursorRightHold {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cursor speed")
                        .font(.callout.weight(.semibold))
                    Picker("Cursor speed", selection: cursorSpeedBinding) {
                        ForEach(CursorMoveSpeed.allCases) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 230)
                }
            }

            if actionBinding.wrappedValue == .verticalScroll {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Scroll speed")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(scrollSensitivityBinding.wrappedValue, specifier: "%.1f")x")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: scrollSensitivityBinding, in: 0.1...5.0, step: 0.1)
                    HStack {
                        Text("0.1x")
                        Spacer()
                        Text("1x")
                        Spacer()
                        Text("5x")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    store.startLearning(store.selectedInputRole)
                } label: {
                    Label("Learn MIDI", systemImage: "dot.radiowaves.left.and.right")
                }

                if store.learningRole == store.selectedInputRole {
                    Button("Cancel") {
                        store.cancelLearning()
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var wheelEditor: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                    .font(.callout.weight(.semibold))
                Picker("Mode", selection: wheelModeBinding) {
                    ForEach(WheelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 6) {
                        Text("Sensitivity")
                            .font(.callout.weight(.semibold))
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(store.mappingProfile.wheel.sensitivity, specifier: "%.2f")x")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: wheelSensitivityBinding, in: 0.1...5.0, step: 0.1)
                HStack {
                    Text("0.1x")
                    Spacer()
                    Text("1x")
                    Spacer()
                    Text("2x")
                    Spacer()
                    Text("5x")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if store.mappingProfile.wheel.mode == .cursorMove {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cursor speed")
                        .font(.callout.weight(.semibold))
                    Picker("Cursor speed", selection: wheelCursorSpeedBinding) {
                        ForEach(CursorMoveSpeed.allCases) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 230)
                }
            }

            Toggle("Invert direction", isOn: wheelInvertedBinding)
                .font(.callout.weight(.medium))
                .toggleStyle(.switch)
        }
    }

    private var openSpeechStatus: some View {
        VStack(alignment: .leading, spacing: 9) {
            statusLine("Hold", value: store.openSpeechHoldShortcut, symbol: "record.circle")
            statusLine("Toggle", value: store.openSpeechToggleShortcut, symbol: "switch.2")
            statusLine("Mic warmup", value: store.audioWarmupActive ? "Active" : "Idle", symbol: "waveform.circle")
        }
    }

    private func statusLine(_ title: String, value: String, symbol: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
    }

    private var midiEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.midiEvents.isEmpty {
                Text("Press a TP-7 control to see events.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.midiEvents.prefix(8)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formatters.eventTime.string(from: event.timestamp))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(event.summary)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var actionBinding: Binding<TP7ActionKind> {
        Binding {
            store.selectedMapping?.action.kind ?? .none
        } set: {
            store.updateAction(for: store.selectedInputRole, kind: $0)
        }
    }

    private var presetBinding: Binding<String> {
        Binding {
            store.selectedMapping?.action.presetID ?? store.openSpeechPresets.first?.id ?? "a"
        } set: {
            store.updatePreset(for: store.selectedInputRole, presetID: $0)
        }
    }

    private var shortcutBinding: Binding<ShortcutBinding?> {
        Binding {
            store.selectedMapping?.action.shortcut
        } set: { shortcut in
            if let shortcut {
                store.updateShortcut(for: store.selectedInputRole, shortcut: shortcut)
            }
        }
    }

    private var cursorSpeedBinding: Binding<CursorMoveSpeed> {
        Binding {
            store.selectedMapping?.action.cursorSpeed ?? .medium
        } set: {
            store.updateCursorSpeed(for: store.selectedInputRole, speed: $0)
        }
    }

    private var scrollSensitivityBinding: Binding<Double> {
        Binding {
            store.selectedMapping?.action.scrollSensitivity ?? 1.0
        } set: {
            store.updateScrollSensitivity(for: store.selectedInputRole, sensitivity: $0)
        }
    }

    private var wheelModeBinding: Binding<WheelMode> {
        Binding {
            store.mappingProfile.wheel.mode
        } set: {
            store.updateWheel(mode: $0)
        }
    }

    private var wheelSensitivityBinding: Binding<Double> {
        Binding {
            store.mappingProfile.wheel.sensitivity
        } set: {
            store.updateWheel(sensitivity: $0)
        }
    }

    private var wheelInvertedBinding: Binding<Bool> {
        Binding {
            store.mappingProfile.wheel.inverted
        } set: {
            store.updateWheel(inverted: $0)
        }
    }

    private var wheelCursorSpeedBinding: Binding<CursorMoveSpeed> {
        Binding {
            store.mappingProfile.wheel.cursorSpeed
        } set: {
            store.updateWheel(cursorSpeed: $0)
        }
    }
}

private struct RolePill: View {
    let role: TP7InputRole
    let selected: Bool
    let learned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if role == .plus || role == .minus {
                    Text(role.title)
                        .font(.callout.weight(selected ? .bold : .semibold))
                        .frame(minWidth: 18)
                } else {
                    Image(systemName: role.systemImage)
                        .font(.caption.weight(selected ? .bold : .semibold))
                    Text(role.title)
                        .font(.caption.weight(selected ? .bold : .medium))
                        .lineLimit(1)
                }
                if !learned && role != .plus && role != .minus {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 6))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.95) : .white.opacity(0.16), lineWidth: selected ? 1.5 : 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(role.title)
    }
}

private struct StatusInfoPopover: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.headline)
                .foregroundStyle(.secondary)

            StatusInfoRow(
                title: "TP-7 Audio",
                detail: store.hasTP7Audio ? "Connected" : "Missing",
                systemImage: store.hasTP7Audio ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            StatusInfoRow(
                title: "TP-7 MIDI In",
                detail: store.hasTP7MIDI ? "Connected" : "Missing",
                systemImage: store.hasTP7MIDI ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            StatusInfoRow(
                title: "TP-7 MIDI Out",
                detail: store.hasTP7MIDIOutput ? (store.midiOutputActive ? "Activated" : "Available") : "Missing",
                systemImage: store.hasTP7MIDIOutput ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            StatusInfoRow(
                title: "Accessibility",
                detail: store.accessibilityTrusted ? "Enabled" : "Needs permission",
                systemImage: store.accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised"
            )
            StatusInfoRow(
                title: "Wheel",
                detail: "\(store.mappingProfile.wheel.mode.title) \(String(format: "%.2fx", store.mappingProfile.wheel.sensitivity))",
                systemImage: "dial.medium"
            )
            StatusInfoRow(
                title: "Open Speech Hold",
                detail: store.openSpeechHoldShortcut,
                systemImage: "record.circle"
            )
            StatusInfoRow(
                title: "Open Speech Toggle",
                detail: store.openSpeechToggleShortcut,
                systemImage: "switch.2"
            )
        }
        .padding(18)
        .frame(width: 280)
    }
}

private struct StatusInfoRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
        }
    }
}

private struct DragScrollableHorizontalView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> DragHorizontalScrollView {
        let scrollView = DragHorizontalScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = false

        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        ])
        return scrollView
    }

    func updateNSView(_ nsView: DragHorizontalScrollView, context: Context) {
        guard let hostingView = nsView.documentView as? NSHostingView<Content> else { return }
        hostingView.rootView = content()
    }
}

private final class DragHorizontalScrollView: NSScrollView {
    private var panStartOrigin: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installPanRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installPanRecognizer()
    }

    override func scrollWheel(with event: NSEvent) {
        let dominantDelta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        scrollHorizontally(by: dominantDelta)
    }

    private func installPanRecognizer() {
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(recognizer)
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            panStartOrigin = contentView.bounds.origin.x
        case .changed:
            let translation = recognizer.translation(in: self)
            scrollToX(panStartOrigin - translation.x)
        default:
            break
        }
    }

    private func scrollHorizontally(by delta: CGFloat) {
        scrollToX(contentView.bounds.origin.x + delta)
    }

    private func scrollToX(_ proposedX: CGFloat) {
        guard let documentView else { return }
        let maxX = max(documentView.frame.width - contentView.bounds.width, 0)
        let nextX = min(max(proposedX, 0), maxX)
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView)
    }
}
