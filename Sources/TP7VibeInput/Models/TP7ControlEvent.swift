import Foundation

struct TP7ControlEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case controlChange(channel: Int, controller: UInt8, value: UInt8)
        case note(channel: Int, note: UInt8, velocity: UInt8, isOn: Bool)
        case pitchBend(channel: Int, value: Int)
        case raw([UInt8])
    }

    let id = UUID()
    let timestamp: Date
    let endpointName: String
    let kind: Kind

    var summary: String {
        switch kind {
        case let .controlChange(channel, controller, value):
            "CC ch=\(channel) cc=\(controller) value=\(value)"
        case let .note(channel, note, velocity, isOn):
            "\(isOn ? "Note On" : "Note Off") ch=\(channel) note=\(note) velocity=\(velocity)"
        case let .pitchBend(channel, value):
            "Pitch Bend ch=\(channel) value=\(value)"
        case let .raw(bytes):
            "Raw " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}
