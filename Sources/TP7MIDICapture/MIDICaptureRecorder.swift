import AppKit
import CoreMIDI
import Foundation

struct CapturedMIDIEvent: Identifiable, Codable {
    enum Kind: String, Codable {
        case controlChange
        case noteOn
        case noteOff
        case pitchBend
        case raw
        case marker
    }

    let id: UUID
    let index: Int
    let timestamp: Date
    let deltaMilliseconds: Double
    let endpointName: String
    let rawBytes: [UInt8]
    let kind: Kind
    let channel: Int?
    let controller: UInt8?
    let note: UInt8?
    let value: UInt8?
    let signedValue: Int?
    let label: String?

    var rawHex: String {
        rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var summary: String {
        switch kind {
        case .controlChange:
            "CC ch\(channel ?? 0) #\(controller ?? 0) value \(value ?? 0) signed \(signedValue ?? 0)"
        case .noteOn:
            "Note On ch\(channel ?? 0) note \(note ?? 0) velocity \(value ?? 0)"
        case .noteOff:
            "Note Off ch\(channel ?? 0) note \(note ?? 0) velocity \(value ?? 0)"
        case .pitchBend:
            "Pitch Bend ch\(channel ?? 0) value \(signedValue ?? 0)"
        case .raw:
            "Raw \(rawHex)"
        case .marker:
            "MARK \(label ?? "")"
        }
    }
}

@MainActor
final class MIDICaptureRecorder: ObservableObject {
    @Published private(set) var events: [CapturedMIDIEvent] = []
    @Published private(set) var endpoints: [String] = []
    @Published private(set) var isRecording = false
    @Published var status = "Ready"

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources = Set<MIDIEndpointRef>()
    private var endpointNames: [MIDIEndpointRef: String] = [:]
    private var firstTimestamp: Date?
    private var nextIndex = 1

    func start() {
        guard !isRecording else { return }
        rebuildMIDI()
        isRecording = true
        firstTimestamp = Date()
        status = "Recording MIDI..."
    }

    func stop() {
        isRecording = false
        status = "Stopped with \(events.count) events"
    }

    func clear() {
        events.removeAll()
        firstTimestamp = isRecording ? Date() : nil
        nextIndex = 1
        status = isRecording ? "Recording MIDI..." : "Ready"
    }

    func addMarker(_ label: String) {
        append(
            endpointName: "MARK",
            bytes: [],
            kind: .marker,
            channel: nil,
            controller: nil,
            note: nil,
            value: nil,
            label: label
        )
    }

    func exportJSON() {
        do {
            let url = exportURL(extension: "json")
            let data = try JSONEncoder.pretty.encode(events)
            try data.write(to: url)
            reveal(url)
            status = "Exported \(url.lastPathComponent)"
        } catch {
            status = "JSON export failed: \(error.localizedDescription)"
        }
    }

    func exportCSV() {
        do {
            let url = exportURL(extension: "csv")
            try csvString().write(to: url, atomically: true, encoding: .utf8)
            reveal(url)
            status = "Exported \(url.lastPathComponent)"
        } catch {
            status = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func rebuildMIDI() {
        tearDown()
        var status = MIDIClientCreateWithBlock("TP7MIDICapture" as CFString, &client) { [weak self] _ in
            Task { @MainActor in
                self?.connectSources()
            }
        }
        guard status == noErr else {
            self.status = "MIDI client failed: \(status)"
            return
        }

        status = MIDIInputPortCreateWithBlock(client, "TP7MIDICaptureInput" as CFString, &inputPort) { [weak self] packetList, sourceRefCon in
            let sourceID = MIDIEndpointRef(UInt(bitPattern: sourceRefCon))
            let packets = Self.extractPackets(packetList: packetList)
            Task { @MainActor in
                self?.handlePackets(packets, sourceID: sourceID)
            }
        }
        guard status == noErr else {
            self.status = "MIDI input failed: \(status)"
            tearDown()
            return
        }

        connectSources()
    }

    private func connectSources() {
        guard inputPort != 0 else { return }
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            let name = Self.name(for: source)
            names.append(name)
            endpointNames[source] = name
            guard !connectedSources.contains(source) else { continue }
            let status = MIDIPortConnectSource(inputPort, source, UnsafeMutableRawPointer(bitPattern: UInt(source)))
            if status == noErr {
                connectedSources.insert(source)
            }
        }
        endpoints = names.sorted()
    }

    private func handlePackets(_ packets: [[UInt8]], sourceID: MIDIEndpointRef) {
        guard isRecording else { return }
        let endpointName = endpointNames[sourceID] ?? Self.name(for: sourceID)
        for bytes in packets {
            parseAndAppend(bytes: bytes, endpointName: endpointName)
        }
    }

    private func parseAndAppend(bytes: [UInt8], endpointName: String) {
        guard bytes.count >= 3 else {
            append(endpointName: endpointName, bytes: bytes, kind: .raw, channel: nil, controller: nil, note: nil, value: nil, label: nil)
            return
        }

        let status = bytes[0]
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0:
            append(endpointName: endpointName, bytes: bytes, kind: .controlChange, channel: channel, controller: bytes[1], note: nil, value: bytes[2], label: nil)
        case 0x90:
            append(endpointName: endpointName, bytes: bytes, kind: bytes[2] == 0 ? .noteOff : .noteOn, channel: channel, controller: nil, note: bytes[1], value: bytes[2], label: nil)
        case 0x80:
            append(endpointName: endpointName, bytes: bytes, kind: .noteOff, channel: channel, controller: nil, note: bytes[1], value: bytes[2], label: nil)
        case 0xE0:
            let value = (Int(bytes[1]) | (Int(bytes[2]) << 7)) - 8192
            appendPitchBend(endpointName: endpointName, bytes: bytes, channel: channel, value: value)
        default:
            append(endpointName: endpointName, bytes: bytes, kind: .raw, channel: channel, controller: nil, note: nil, value: nil, label: nil)
        }
    }

    private func appendPitchBend(endpointName: String, bytes: [UInt8], channel: Int, value: Int) {
        let now = Date()
        if firstTimestamp == nil {
            firstTimestamp = now
        }
        let delta = now.timeIntervalSince(firstTimestamp ?? now) * 1000
        let event = CapturedMIDIEvent(
            id: UUID(),
            index: nextIndex,
            timestamp: now,
            deltaMilliseconds: delta,
            endpointName: endpointName,
            rawBytes: bytes,
            kind: .pitchBend,
            channel: channel,
            controller: nil,
            note: nil,
            value: nil,
            signedValue: value,
            label: nil
        )
        nextIndex += 1
        events.insert(event, at: 0)
        if events.count > 1000 {
            events.removeLast(events.count - 1000)
        }
    }

    private func append(
        endpointName: String,
        bytes: [UInt8],
        kind: CapturedMIDIEvent.Kind,
        channel: Int?,
        controller: UInt8?,
        note: UInt8?,
        value: UInt8?,
        label: String?
    ) {
        let now = Date()
        if firstTimestamp == nil {
            firstTimestamp = now
        }
        let delta = now.timeIntervalSince(firstTimestamp ?? now) * 1000
        let event = CapturedMIDIEvent(
            id: UUID(),
            index: nextIndex,
            timestamp: now,
            deltaMilliseconds: delta,
            endpointName: endpointName,
            rawBytes: bytes,
            kind: kind,
            channel: channel,
            controller: controller,
            note: note,
            value: value,
            signedValue: value.map(Self.signedSevenBitRelative),
            label: label
        )
        nextIndex += 1
        events.insert(event, at: 0)
        if events.count > 1000 {
            events.removeLast(events.count - 1000)
        }
    }

    private func csvString() -> String {
        var rows = ["index,delta_ms,endpoint,kind,channel,controller,note,value,signed,raw,label"]
        for event in events.reversed() {
            let index = String(event.index)
            let delta = String(format: "%.3f", event.deltaMilliseconds)
            let endpoint = event.endpointName.csvEscaped
            let kind = event.kind.rawValue
            let channel = event.channel.map(String.init) ?? ""
            let controller = event.controller.map(String.init) ?? ""
            let note = event.note.map(String.init) ?? ""
            let value = event.value.map(String.init) ?? ""
            let signed = event.signedValue.map(String.init) ?? ""
            let raw = event.rawHex.csvEscaped
            let label = (event.label ?? "").csvEscaped
            rows.append([index, delta, endpoint, kind, channel, controller, note, value, signed, raw, label].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func exportURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("tp7-midi-capture-\(formatter.string(from: Date())).\(ext)")
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func tearDown() {
        if inputPort != 0 {
            for source in connectedSources {
                MIDIPortDisconnectSource(inputPort, source)
            }
            MIDIPortDispose(inputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
        client = 0
        inputPort = 0
        connectedSources.removeAll()
        endpointNames.removeAll()
    }

    private static func extractPackets(packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) { rawBuffer in
                Array(rawBuffer.prefix(Int(packet.length)))
            }
            result.append(bytes)
            packet = MIDIPacketNext(&packet).pointee
        }
        return result
    }

    private static func signedSevenBitRelative(_ value: UInt8) -> Int {
        value < 64 ? Int(value) : Int(value) - 128
    }

    private static func name(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &unmanagedName)
        return unmanagedName?.takeRetainedValue() as String? ?? "MIDI Endpoint \(endpoint)"
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension String {
    var csvEscaped: String {
        let escaped = replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
