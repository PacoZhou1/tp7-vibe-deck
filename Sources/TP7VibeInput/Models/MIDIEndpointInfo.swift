import CoreMIDI
import Foundation

struct MIDIEndpointInfo: Identifiable, Equatable {
    enum Direction: String {
        case source = "Source"
        case destination = "Destination"
    }

    let id: MIDIEndpointRef
    let name: String
    let direction: Direction

    var isTP7: Bool {
        name.localizedCaseInsensitiveContains("TP-7")
    }
}
