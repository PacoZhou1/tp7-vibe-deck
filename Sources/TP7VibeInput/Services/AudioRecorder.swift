import AudioToolbox
import Foundation

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case cannotCreateDirectory
    case cannotCreateQueue(OSStatus)
    case cannotSelectDevice(OSStatus)
    case cannotCreateFile(OSStatus)
    case cannotAllocateBuffer(OSStatus)
    case cannotStartQueue(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Already recording"
        case .notRecording: "Not recording"
        case .cannotCreateDirectory: "Could not create recordings directory"
        case let .cannotCreateQueue(status): "Could not create audio queue: \(status)"
        case let .cannotSelectDevice(status): "Could not select TP-7 input: \(status)"
        case let .cannotCreateFile(status): "Could not create WAV file: \(status)"
        case let .cannotAllocateBuffer(status): "Could not allocate audio buffer: \(status)"
        case let .cannotStartQueue(status): "Could not start audio queue: \(status)"
        }
    }
}

final class AudioRecorder {
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var audioFile: AudioFileID?
    private var currentURL: URL?
    private var packetIndex: Int64 = 0
    private var isRecording = false
    private var format = AudioStreamBasicDescription()

    func start(device: AudioInputDevice?) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        guard queue == nil else { throw AudioRecorderError.alreadyRecording }

        let channels = UInt32(max(1, min(device?.inputChannels ?? 1, 2)))
        let sampleRate = device?.sampleRate ?? 48_000
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
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var status = AudioQueueNewInput(
            &format,
            Self.inputCallback,
            selfPointer,
            nil,
            nil,
            0,
            &queueRef
        )
        guard status == noErr, let queueRef else {
            throw AudioRecorderError.cannotCreateQueue(status)
        }

        if let uid = device?.uid, !uid.isEmpty {
            var deviceUID = uid as CFString
            status = AudioQueueSetProperty(
                queueRef,
                kAudioQueueProperty_CurrentDevice,
                &deviceUID,
                UInt32(MemoryLayout<CFString>.size)
            )
            guard status == noErr else {
                AudioQueueDispose(queueRef, true)
                throw AudioRecorderError.cannotSelectDevice(status)
            }
        }

        let url = try makeRecordingURL()
        var fileID: AudioFileID?
        status = AudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &format,
            .eraseFile,
            &fileID
        )
        guard status == noErr, let fileID else {
            AudioQueueDispose(queueRef, true)
            throw AudioRecorderError.cannotCreateFile(status)
        }

        queue = queueRef
        audioFile = fileID
        currentURL = url
        packetIndex = 0
        isRecording = true

        let bufferByteSize: UInt32 = max(format.mBytesPerFrame * 4096, 16_384)
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queueRef, bufferByteSize, &buffer)
            guard status == noErr, let buffer else {
                cleanupLocked(removeFile: true)
                throw AudioRecorderError.cannotAllocateBuffer(status)
            }
            status = AudioQueueEnqueueBuffer(queueRef, buffer, 0, nil)
            guard status == noErr else {
                cleanupLocked(removeFile: true)
                throw AudioRecorderError.cannotAllocateBuffer(status)
            }
        }

        status = AudioQueueStart(queueRef, nil)
        guard status == noErr else {
            cleanupLocked(removeFile: true)
            throw AudioRecorderError.cannotStartQueue(status)
        }

        return url
    }

    func stop() throws -> URL {
        lock.lock()
        guard let queue, let url = currentURL else {
            lock.unlock()
            throw AudioRecorderError.notRecording
        }
        isRecording = false
        lock.unlock()

        AudioQueueStop(queue, true)

        lock.lock()
        cleanupLocked(removeFile: false)
        lock.unlock()
        return url
    }

    func cancel() {
        lock.lock()
        let queue = queue
        isRecording = false
        lock.unlock()

        if let queue {
            AudioQueueStop(queue, true)
        }

        lock.lock()
        cleanupLocked(removeFile: true)
        lock.unlock()
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, startTime, packetCount, packetDescriptions in
        guard let userData else { return }
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue()
        recorder.handleInputBuffer(
            queue: queue,
            buffer: buffer,
            packetCount: packetCount,
            packetDescriptions: packetDescriptions
        )
    }

    private func handleInputBuffer(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        packetCount: UInt32,
        packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
    ) {
        lock.lock()
        guard isRecording, let audioFile else {
            lock.unlock()
            return
        }

        var packets = packetCount
        if packets == 0, format.mBytesPerPacket > 0 {
            packets = buffer.pointee.mAudioDataByteSize / format.mBytesPerPacket
        }
        var localPacketIndex = packetIndex
        lock.unlock()

        if packets > 0 {
            let status = AudioFileWritePackets(
                audioFile,
                false,
                buffer.pointee.mAudioDataByteSize,
                packetDescriptions,
                localPacketIndex,
                &packets,
                buffer.pointee.mAudioData
            )
            if status == noErr {
                localPacketIndex += Int64(packets)
                lock.lock()
                packetIndex = localPacketIndex
                lock.unlock()
            } else {
                NSLog("TP7VibeInput AudioFileWritePackets failed: \(status)")
            }
        }

        lock.lock()
        let shouldContinue = isRecording
        lock.unlock()
        if shouldContinue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func cleanupLocked(removeFile: Bool) {
        if let queue {
            AudioQueueDispose(queue, true)
        }
        if let audioFile {
            AudioFileClose(audioFile)
        }
        let url = currentURL
        queue = nil
        audioFile = nil
        currentURL = nil
        packetIndex = 0
        isRecording = false

        if removeFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeRecordingURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AudioRecorderError.cannotCreateDirectory
        }
        let directory = support.appendingPathComponent("TP7VibeInput/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let safeStamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("tp7-\(safeStamp).wav")
    }
}
