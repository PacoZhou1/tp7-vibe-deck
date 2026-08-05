import CoreAudio
import CoreMIDI
import Foundation

final class TP7DeviceMonitor {
    func listAudioInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            let channels = inputChannelCount(for: deviceID)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: deviceID,
                name: stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Audio Device \(deviceID)",
                uid: stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) ?? "",
                inputChannels: channels,
                sampleRate: nominalSampleRate(for: deviceID)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isTP7 != rhs.isTP7 { return lhs.isTP7 }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func listMIDIEndpoints() -> [MIDIEndpointInfo] {
        var endpoints: [MIDIEndpointInfo] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            endpoints.append(MIDIEndpointInfo(id: endpoint, name: midiName(for: endpoint), direction: .source))
        }
        for index in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            endpoints.append(MIDIEndpointInfo(id: endpoint, name: midiName(for: endpoint), direction: .destination))
        }
        return endpoints.sorted { lhs, rhs in
            if lhs.isTP7 != rhs.isTP7 { return lhs.isTP7 }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPointer) == noErr else {
            return 0
        }

        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String
    }

    private func midiName(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &unmanagedName)
        return unmanagedName?.takeRetainedValue() as String? ?? "MIDI Endpoint \(endpoint)"
    }
}
