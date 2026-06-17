import Foundation
@preconcurrency import AVFoundation
import MLX
@preconcurrency import Qwen3ASR
import os.log

private let qwenASRLog = OSLog(subsystem: "com.openspeech.app", category: "Qwen3ASR")

struct TranscriptionResult: Sendable {
    let text: String
    let language: String?
    let durationSeconds: Double
    let inferenceSeconds: Double
    let rtf: Double
    let modelID: String
}

protocol ASRProvider {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

struct LocalMLXMemorySnapshot: Sendable {
    let mlxActiveMemoryMb: Double
    let mlxCacheMemoryMb: Double
    let mlxTrackedMemoryMb: Double
    let mlxPeakMemoryMb: Double
    let mlxCacheLimitMb: Double
    let mlxMemoryLimitMb: Double
}

struct LocalMLXCleanupResult: Sendable {
    let triggered: Bool
    let before: LocalMLXMemorySnapshot
    let after: LocalMLXMemorySnapshot
    let targetCacheLimitMb: Double
    let effectiveSoftLimitMb: Double
    let restartRecommended: Bool
}

enum Qwen3ASRLoadState: Equatable {
    case idle
    case downloading(progress: Double, message: String)
    case loading(message: String)
    case ready
    case failed(String)

    var displayText: String {
        switch self {
        case .idle:
            return "空闲"
        case .downloading(let progress, let message):
            return "\(message) \(Int(progress * 100))%"
        case .loading(let message):
            return message
        case .ready:
            return "就绪"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    var progress: Double {
        switch self {
        case .idle:
            return 0
        case .downloading(let progress, _):
            return progress
        case .loading:
            return 0.85
        case .ready:
            return 1
        case .failed:
            return 0
        }
    }
}

actor Qwen3ASRProvider: ASRProvider {
    static let shared = Qwen3ASRProvider()

    let modelID = "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
    private let bundledModelDirectoryName = "qwen3-asr-1.7b-4bit"
    private let sampleRate = 24_000
    private let defaultGlobalSoftLimitMb = 8_000.0
    private let memoryHardLimitMb = 9_500.0
    private let initialCacheLimitMb = 256.0
    private let cacheFloorMb = 128.0
    private let cacheHeadroomMb = 512.0
    private var model: Qwen3ASRModel?
    private var loadTask: Task<Qwen3ASRModel, Error>?
    private var memoryPolicyConfigured = false

    func warmUp(progressHandler: (@Sendable (Qwen3ASRLoadState) -> Void)? = nil) async throws {
        _ = try await loadModel(progressHandler: progressHandler)
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let audio = try Self.loadMonoSamples(url: audioURL, targetSampleRate: sampleRate)
        let duration = audio.isEmpty ? 0 : Double(audio.count) / Double(sampleRate)
        let loadedModel = try await loadModel(progressHandler: nil)

        let startedAt = Date()
        let text = autoreleasepool {
            loadedModel.transcribe(audio: audio, sampleRate: sampleRate)
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let rtf = duration > 0 ? elapsed / duration : 0
        os_log(
            .info,
            log: qwenASRLog,
            "Qwen3-ASR transcribed %{public}@ duration=%.3f inference=%.3f rtf=%.4f chars=%d",
            audioURL.lastPathComponent,
            duration,
            elapsed,
            rtf,
            text.count
        )
        let cleanup = performMemoryMaintenance(
            reason: "post-qwen-asr",
            globalSoftLimitMb: defaultGlobalSoftLimitMb,
            peerTrackedMemoryMb: 0,
            force: true
        )
        logCleanupResult(cleanup, reason: "post-qwen-asr")

        return TranscriptionResult(
            text: text,
            language: nil,
            durationSeconds: duration,
            inferenceSeconds: elapsed,
            rtf: rtf,
            modelID: modelID
        )
    }

    func memorySnapshot() -> LocalMLXMemorySnapshot {
        Self.makeMemorySnapshot()
    }

    func performMemoryMaintenance(
        reason: String,
        globalSoftLimitMb: Double,
        peerTrackedMemoryMb: Double,
        force: Bool = false
    ) -> LocalMLXCleanupResult {
        configureMemoryPolicyIfNeeded()
        let before = Self.makeMemorySnapshot()
        let effectiveSoftLimitMb = effectiveSoftLimit(
            globalSoftLimitMb: globalSoftLimitMb,
            peerTrackedMemoryMb: peerTrackedMemoryMb
        )
        let targetCacheLimitMb = targetCacheLimit(
            activeMemoryMb: before.mlxActiveMemoryMb,
            effectiveSoftLimitMb: effectiveSoftLimitMb
        )
        let shouldCleanup = force
            || before.mlxTrackedMemoryMb >= effectiveSoftLimitMb
            || before.mlxCacheMemoryMb > targetCacheLimitMb

        guard shouldCleanup else {
            return LocalMLXCleanupResult(
                triggered: false,
                before: before,
                after: before,
                targetCacheLimitMb: targetCacheLimitMb,
                effectiveSoftLimitMb: effectiveSoftLimitMb,
                restartRecommended: false
            )
        }

        Memory.cacheLimit = Self.bytes(fromMegabytes: targetCacheLimitMb)
        Self.synchronizeMLXWork()
        Memory.clearCache()
        let after = Self.makeMemorySnapshot()
        let restartRecommended = after.mlxActiveMemoryMb >= memoryHardLimitMb
            || (after.mlxTrackedMemoryMb >= memoryHardLimitMb && after.mlxCacheMemoryMb <= cacheFloorMb)
        return LocalMLXCleanupResult(
            triggered: true,
            before: before,
            after: after,
            targetCacheLimitMb: targetCacheLimitMb,
            effectiveSoftLimitMb: effectiveSoftLimitMb,
            restartRecommended: restartRecommended
        )
    }

    func releaseModelForMemoryPressure(reason: String) -> LocalMLXCleanupResult {
        let before = Self.makeMemorySnapshot()
        loadTask?.cancel()
        loadTask = nil
        model = nil
        Memory.cacheLimit = 0
        Self.synchronizeMLXWork()
        Memory.clearCache()
        memoryPolicyConfigured = false
        let after = Self.makeMemorySnapshot()
        os_log(
            .info,
            log: qwenASRLog,
            "Qwen3-ASR model released for memory pressure (%{public}@): tracked %.0f -> %.0f MB",
            reason,
            before.mlxTrackedMemoryMb,
            after.mlxTrackedMemoryMb
        )
        return LocalMLXCleanupResult(
            triggered: true,
            before: before,
            after: after,
            targetCacheLimitMb: 0,
            effectiveSoftLimitMb: 0,
            restartRecommended: false
        )
    }

    private func loadModel(
        progressHandler: (@Sendable (Qwen3ASRLoadState) -> Void)?
    ) async throws -> Qwen3ASRModel {
        configureMemoryPolicyIfNeeded()
        if let model {
            progressHandler?(.ready)
            return model
        }
        if let loadTask {
            let loaded = try await loadTask.value
            progressHandler?(.ready)
            return loaded
        }

        let bundledModelURL = Self.bundledModelURL(named: bundledModelDirectoryName)
        let usesBundledModel = bundledModelURL != nil
        os_log(
            .info,
            log: qwenASRLog,
            "Loading Qwen3-ASR, bundled=%{public}@ path=%{public}@",
            usesBundledModel ? "yes" : "no",
            bundledModelURL?.path ?? "speech-swift cache"
        )
        progressHandler?(
            usesBundledModel
                ? .loading(message: "加载内置 Qwen3-ASR 模型")
                : .downloading(progress: 0, message: "准备下载 Qwen3-ASR")
        )
        let modelID = self.modelID
        let task = Task {
            try await Qwen3ASRModel.fromPretrained(
                modelId: modelID,
                cacheDir: bundledModelURL,
                offlineMode: usesBundledModel
            ) { progress, status in
                let state: Qwen3ASRLoadState
                if usesBundledModel {
                    state = progress < 1.0 ? .loading(message: status) : .ready
                } else if progress < 0.80 {
                    state = .downloading(progress: max(0, min(progress, 1)), message: status)
                } else if progress < 1.0 {
                    state = .loading(message: status)
                } else {
                    state = .ready
                }
                progressHandler?(state)
            }
        }
        loadTask = task

        do {
            let loaded = try await task.value
            model = loaded
            loadTask = nil
            os_log(.info, log: qwenASRLog, "Qwen3-ASR loaded")
            let cleanup = performMemoryMaintenance(
                reason: "post-qwen-load",
                globalSoftLimitMb: defaultGlobalSoftLimitMb,
                peerTrackedMemoryMb: 0,
                force: true
            )
            logCleanupResult(cleanup, reason: "post-qwen-load")
            progressHandler?(.ready)
            return loaded
        } catch {
            loadTask = nil
            os_log(.error, log: qwenASRLog, "Qwen3-ASR load failed: %{public}@", error.localizedDescription)
            progressHandler?(.failed(error.localizedDescription))
            throw error
        }
    }

    private static func bundledModelURL(named directoryName: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent(directoryName, isDirectory: true)
        let requiredFiles = ["model.safetensors", "vocab.json", "merges.txt", "tokenizer_config.json"]
        let hasRequiredFiles = requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        if !hasRequiredFiles {
            os_log(.error, log: qwenASRLog, "Bundled Qwen3-ASR model missing required files at %{public}@", url.path)
        }
        return hasRequiredFiles ? url : nil
    }

    private func configureMemoryPolicyIfNeeded() {
        guard !memoryPolicyConfigured else { return }
        Memory.memoryLimit = Self.bytes(fromMegabytes: memoryHardLimitMb)
        Memory.cacheLimit = Self.bytes(fromMegabytes: initialCacheLimitMb)
        memoryPolicyConfigured = true
        os_log(
            .info,
            log: qwenASRLog,
            "Qwen3-ASR MLX memory policy configured: global_soft=%.0f MB hard=%.0f MB initial_cache=%.0f MB",
            defaultGlobalSoftLimitMb,
            memoryHardLimitMb,
            initialCacheLimitMb
        )
    }

    private func effectiveSoftLimit(globalSoftLimitMb: Double, peerTrackedMemoryMb: Double) -> Double {
        guard globalSoftLimitMb > 0 else { return defaultGlobalSoftLimitMb }
        return max(0, globalSoftLimitMb - max(0, peerTrackedMemoryMb))
    }

    private func targetCacheLimit(activeMemoryMb: Double, effectiveSoftLimitMb: Double) -> Double {
        let remaining = effectiveSoftLimitMb - activeMemoryMb - cacheHeadroomMb
        guard remaining > 0 else { return 0 }
        return max(cacheFloorMb, min(initialCacheLimitMb, remaining))
    }

    private func logCleanupResult(_ result: LocalMLXCleanupResult, reason: String) {
        guard result.triggered else { return }
        os_log(
            .info,
            log: qwenASRLog,
            "Qwen3-ASR MLX cleanup (%{public}@): tracked %.0f -> %.0f MB, cache %.0f -> %.0f MB, target_cache=%.0f MB, soft=%.0f MB",
            reason,
            result.before.mlxTrackedMemoryMb,
            result.after.mlxTrackedMemoryMb,
            result.before.mlxCacheMemoryMb,
            result.after.mlxCacheMemoryMb,
            result.targetCacheLimitMb,
            result.effectiveSoftLimitMb
        )
    }

    private static func makeMemorySnapshot() -> LocalMLXMemorySnapshot {
        let snapshot = Memory.snapshot()
        return LocalMLXMemorySnapshot(
            mlxActiveMemoryMb: megabytes(fromBytes: snapshot.activeMemory),
            mlxCacheMemoryMb: megabytes(fromBytes: snapshot.cacheMemory),
            mlxTrackedMemoryMb: megabytes(fromBytes: snapshot.activeMemory + snapshot.cacheMemory),
            mlxPeakMemoryMb: megabytes(fromBytes: snapshot.peakMemory),
            mlxCacheLimitMb: megabytes(fromBytes: Memory.cacheLimit),
            mlxMemoryLimitMb: megabytes(fromBytes: Memory.memoryLimit)
        )
    }

    private static func synchronizeMLXWork() {
        Stream.gpu.synchronize()
    }

    private static func bytes(fromMegabytes megabytes: Double) -> Int {
        Int(max(0, megabytes) * 1024 * 1024)
    }

    private static func megabytes(fromBytes bytes: Int) -> Double {
        Double(bytes) / 1_000_000
    }

    private static func loadMonoSamples(url: URL, targetSampleRate: Int) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw Qwen3ASRProviderError.bufferCreationFailed
        }
        try audioFile.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw Qwen3ASRProviderError.noFloatData
        }

        let channelCount = max(1, Int(format.channelCount))
        let frameLength = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frameLength)
        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: floatData[channel], count: frameLength)
            for index in 0..<frameLength {
                mono[index] += channelSamples[index] / Float(channelCount)
            }
        }

        let inputSampleRate = Int(format.sampleRate)
        if inputSampleRate == targetSampleRate {
            return mono
        }
        return resample(mono, from: inputSampleRate, to: targetSampleRate)
    }

    private static func resample(_ samples: [Float], from inputRate: Int, to outputRate: Int) -> [Float] {
        guard inputRate != outputRate, !samples.isEmpty else { return samples }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(inputRate),
            channels: 1,
            interleaved: false
        ),
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(outputRate),
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return samples
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                sourceBuffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
            }
        }

        let outputFrameCount = AVAudioFrameCount(Double(samples.count) * Double(outputRate) / Double(inputRate))
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return samples
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard error == nil, targetBuffer.frameLength > 0, let output = targetBuffer.floatChannelData else {
            return samples
        }
        return Array(UnsafeBufferPointer(start: output[0], count: Int(targetBuffer.frameLength)))
    }
}

enum Qwen3ASRProviderError: LocalizedError {
    case bufferCreationFailed
    case noFloatData

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .noFloatData:
            return "No float audio data"
        }
    }
}
