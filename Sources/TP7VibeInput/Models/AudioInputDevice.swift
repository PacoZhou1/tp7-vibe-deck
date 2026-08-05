import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let sampleRate: Double

    var isTP7: Bool {
        name.localizedCaseInsensitiveContains("TP-7")
    }
}
