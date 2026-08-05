import AudioToolbox
import Foundation
import OSLog

private let audioWarmerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.paco.TP7VibeInput",
    category: "AudioInputWarmer"
)

enum AudioInputWarmerError: LocalizedError {
    case alreadyRunning
    case missingDevice
    case cannotCreateQueue(OSStatus)
    case cannotSelectDevice(OSStatus)
    case cannotAllocateBuffer(OSStatus)
    case cannotStartQueue(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Audio input warmer is already running"
        case .missingDevice:
            return "TP-7 audio input was not found"
        case .cannotCreateQueue(let status):
            return "Could not create TP-7 warmup queue: \(status)"
        case .cannotSelectDevice(let status):
            return "Could not select TP-7 warmup input: \(status)"
        case .cannotAllocateBuffer(let status):
            return "Could not allocate TP-7 warmup buffer: \(status)"
        case .cannotStartQueue(let status):
            return "Could not start TP-7 warmup queue: \(status)"
        }
    }
}

final class AudioInputWarmer {
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var isRunning = false
    private var format = AudioStreamBasicDescription()
    private var warmedDeviceUID: String?

    deinit {
        stop()
    }

    var activeDeviceUID: String? {
        lock.lock()
        defer { lock.unlock() }
        return isRunning ? warmedDeviceUID : nil
    }

    func start(device: AudioInputDevice?) throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }

        guard queue == nil else { throw AudioInputWarmerError.alreadyRunning }
        guard let device else { throw AudioInputWarmerError.missingDevice }

        let channels = UInt32(max(1, min(device.inputChannels, 2)))
        let sampleRate = device.sampleRate > 0 ? device.sampleRate : 48_000
        format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 2,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var queueRef: AudioQueueRef?
        var status = AudioQueueNewInput(
            &format,
            Self.inputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &queueRef
        )
        guard status == noErr, let queueRef else {
            throw AudioInputWarmerError.cannotCreateQueue(status)
        }

        if !device.uid.isEmpty {
            var deviceUID = device.uid as CFString
            status = AudioQueueSetProperty(
                queueRef,
                kAudioQueueProperty_CurrentDevice,
                &deviceUID,
                UInt32(MemoryLayout<CFString>.size)
            )
            guard status == noErr else {
                AudioQueueDispose(queueRef, true)
                throw AudioInputWarmerError.cannotSelectDevice(status)
            }
        }

        let bufferByteSize: UInt32 = max(format.mBytesPerFrame * 1024, 8_192)
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queueRef, bufferByteSize, &buffer)
            guard status == noErr, let buffer else {
                AudioQueueDispose(queueRef, true)
                throw AudioInputWarmerError.cannotAllocateBuffer(status)
            }
            status = AudioQueueEnqueueBuffer(queueRef, buffer, 0, nil)
            guard status == noErr else {
                AudioQueueDispose(queueRef, true)
                throw AudioInputWarmerError.cannotAllocateBuffer(status)
            }
        }

        status = AudioQueueStart(queueRef, nil)
        guard status == noErr else {
            AudioQueueDispose(queueRef, true)
            throw AudioInputWarmerError.cannotStartQueue(status)
        }

        queue = queueRef
        isRunning = true
        warmedDeviceUID = device.uid
        audioWarmerLog.info(
            "warmup started device=\(device.name, privacy: .public) uid=\(device.uid, privacy: .public) sampleRate=\(sampleRate, format: .fixed(precision: 0)) channels=\(channels) totalMs=\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000, format: .fixed(precision: 3))"
        )
    }

    func stop() {
        lock.lock()
        let queueRef = queue
        queue = nil
        isRunning = false
        warmedDeviceUID = nil
        lock.unlock()

        if let queueRef {
            AudioQueueStop(queueRef, true)
            AudioQueueDispose(queueRef, true)
            audioWarmerLog.info("warmup stopped")
        }
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        let warmer = Unmanaged<AudioInputWarmer>.fromOpaque(userData).takeUnretainedValue()
        warmer.handleInputBuffer(queue: queue, buffer: buffer)
    }

    private func handleInputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        lock.lock()
        let shouldContinue = isRunning
        lock.unlock()

        if shouldContinue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }
}
