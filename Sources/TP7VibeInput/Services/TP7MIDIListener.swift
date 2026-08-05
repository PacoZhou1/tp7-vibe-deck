import CoreMIDI
import Foundation
import OSLog

private let midiLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.paco.TP7VibeInput",
    category: "MIDI"
)

final class TP7MIDIListener {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var tp7Destination = MIDIEndpointRef()
    private var endpointNames: [MIDIEndpointRef: String] = [:]
    private var connectedSources = Set<MIDIEndpointRef>()
    private var onEvent: ((TP7ControlEvent) -> Void)?

    func start(onEvent: @escaping (TP7ControlEvent) -> Void) {
        self.onEvent = onEvent
        rebuild()
    }

    var hasTP7Destination: Bool {
        tp7Destination != 0
    }

    func refreshConnections() {
        guard client != 0, inputPort != 0, outputPort != 0 else {
            rebuild()
            return
        }
        connectCurrentSources()
        refreshDestination()
    }

    func rebuild() {
        tearDown()

        var status = MIDIClientCreateWithBlock("TP7VibeInput" as CFString, &client) { [weak self] notification in
            self?.handleMIDINotification(notification)
        }
        guard status == noErr else {
            midiLog.error("MIDIClientCreate failed status=\(status)")
            return
        }

        status = MIDIInputPortCreateWithBlock(client, "TP7VibeInputInput" as CFString, &inputPort) { [weak self] packetList, sourceRefCon in
            self?.handle(packetList: packetList, sourceRefCon: sourceRefCon)
        }
        guard status == noErr else {
            midiLog.error("MIDIInputPortCreate failed status=\(status)")
            tearDown()
            return
        }

        status = MIDIOutputPortCreate(client, "TP7VibeInputOutput" as CFString, &outputPort)
        guard status == noErr else {
            midiLog.error("MIDIOutputPortCreate failed status=\(status)")
            tearDown()
            return
        }

        connectCurrentSources()
        refreshDestination()
        midiLog.info("MIDI rebuilt sources=\(self.connectedSources.count) hasTP7Destination=\(self.tp7Destination != 0)")
    }

    func refreshDestination() {
        tp7Destination = 0
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            if Self.name(for: destination).localizedCaseInsensitiveContains("TP-7") {
                tp7Destination = destination
                return
            }
        }
    }

    @discardableResult
    func activateControl() -> Bool {
        refreshConnections()
        guard tp7Destination != 0 else { return false }

        // Mirrors the safe connection sync used by the community Web MIDI controller.
        // It is intentionally conservative: no cue trigger, no record arm, no transport start.
        for channel in UInt8(1)...UInt8(6) {
            sendCC(7, value: 127, channel: channel)
            sendCC(120, value: 0, channel: channel)
        }
        for channel in UInt8(1)...UInt8(3) {
            sendCC(9, value: 0, channel: channel)
        }
        sendPitchBend(0, channel: 1)
        sendCC(18, value: 64, channel: 1)
        sendCC(16, value: 0, channel: 1)
        return true
    }

    @discardableResult
    func sendCC(_ controller: UInt8, value: UInt8, channel: UInt8 = 1) -> Bool {
        let status = UInt8(0xB0 | min(max(channel, 1), 16) - 1)
        return send([status, controller, min(value, 127)])
    }

    @discardableResult
    func sendPitchBend(_ value: Int, channel: UInt8 = 1) -> Bool {
        let clamped = min(max(value, -8192), 8191) + 8192
        let lsb = UInt8(clamped & 0x7F)
        let msb = UInt8((clamped >> 7) & 0x7F)
        let status = UInt8(0xE0 | min(max(channel, 1), 16) - 1)
        return send([status, lsb, msb])
    }

    private func send(_ bytes: [UInt8]) -> Bool {
        guard outputPort != 0, tp7Destination != 0, !bytes.isEmpty else { return false }
        var packetList = MIDIPacketList()
        withUnsafeMutablePointer(to: &packetList) { packetListPointer in
            var packet = MIDIPacketListInit(packetListPointer)
            bytes.withUnsafeBufferPointer { bytesPointer in
                guard let baseAddress = bytesPointer.baseAddress else { return }
                packet = MIDIPacketListAdd(
                    packetListPointer,
                    1024,
                    packet,
                    0,
                    bytesPointer.count,
                    baseAddress
                )
            }
        }
        let status = MIDISend(outputPort, tp7Destination, &packetList)
        if status != noErr {
            midiLog.error("MIDISend failed status=\(status)")
        }
        return status == noErr
    }

    deinit {
        tearDown()
    }

    private func connectCurrentSources() {
        guard inputPort != 0 else { return }

        var currentSources = Set<MIDIEndpointRef>()
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            currentSources.insert(source)
            endpointNames[source] = Self.name(for: source)
            guard !connectedSources.contains(source) else { continue }

            let status = MIDIPortConnectSource(inputPort, source, UnsafeMutableRawPointer(bitPattern: UInt(source)))
            if status == noErr {
                connectedSources.insert(source)
                midiLog.info("Connected MIDI source \(self.endpointNames[source] ?? "unknown", privacy: .public)")
            } else {
                midiLog.error("Failed to connect MIDI source status=\(status)")
            }
        }

        for staleSource in connectedSources.subtracting(currentSources) {
            MIDIPortDisconnectSource(inputPort, staleSource)
            connectedSources.remove(staleSource)
            endpointNames.removeValue(forKey: staleSource)
        }
    }

    private func tearDown() {
        if inputPort != 0 {
            for source in connectedSources {
                MIDIPortDisconnectSource(inputPort, source)
            }
            MIDIPortDispose(inputPort)
        }
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
        client = 0
        inputPort = 0
        outputPort = 0
        tp7Destination = 0
        connectedSources.removeAll()
        endpointNames.removeAll()
    }

    private func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        let messageID = notification.pointee.messageID
        midiLog.info("MIDI notification messageID=\(messageID.rawValue)")
        switch messageID {
        case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.rebuild()
            }
        default:
            DispatchQueue.main.async { [weak self] in
                self?.refreshConnections()
            }
        }
    }

    private func handle(packetList: UnsafePointer<MIDIPacketList>, sourceRefCon: UnsafeMutableRawPointer?) {
        let sourceID = MIDIEndpointRef(UInt(bitPattern: sourceRefCon))
        let endpointName = endpointNames[sourceID] ?? "MIDI"
        var packet = packetList.pointee.packet

        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) { rawBuffer in
                Array(rawBuffer.prefix(Int(packet.length)))
            }
            if let event = Self.parse(bytes: bytes, endpointName: endpointName) {
                onEvent?(event)
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private static func parse(bytes: [UInt8], endpointName: String) -> TP7ControlEvent? {
        guard !bytes.isEmpty else { return nil }
        let timestamp = Date()
        guard bytes.count >= 3 else {
            return TP7ControlEvent(timestamp: timestamp, endpointName: endpointName, kind: .raw(bytes))
        }

        let status = bytes[0]
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0:
            return TP7ControlEvent(
                timestamp: timestamp,
                endpointName: endpointName,
                kind: .controlChange(channel: channel, controller: bytes[1], value: bytes[2])
            )
        case 0x90:
            return TP7ControlEvent(
                timestamp: timestamp,
                endpointName: endpointName,
                kind: .note(channel: channel, note: bytes[1], velocity: bytes[2], isOn: bytes[2] > 0)
            )
        case 0x80:
            return TP7ControlEvent(
                timestamp: timestamp,
                endpointName: endpointName,
                kind: .note(channel: channel, note: bytes[1], velocity: bytes[2], isOn: false)
            )
        case 0xE0:
            let value = (Int(bytes[1]) | (Int(bytes[2]) << 7)) - 8192
            return TP7ControlEvent(
                timestamp: timestamp,
                endpointName: endpointName,
                kind: .pitchBend(channel: channel, value: value)
            )
        default:
            return TP7ControlEvent(timestamp: timestamp, endpointName: endpointName, kind: .raw(bytes))
        }
    }

    private static func name(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &unmanagedName)
        return unmanagedName?.takeRetainedValue() as String? ?? "MIDI Endpoint \(endpoint)"
    }
}
