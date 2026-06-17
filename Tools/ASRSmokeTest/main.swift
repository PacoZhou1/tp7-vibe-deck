import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Qwen3ASR

@main
struct ASRSmokeTest {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else {
                fputs("Usage: asr-smoke-test <audio-file> <model-dir> [language]\n", stderr)
                Foundation.exit(2)
            }

            let audioURL = URL(fileURLWithPath: args[1])
            let modelURL = URL(fileURLWithPath: args[2], isDirectory: true)
            let language = args.count >= 4 && !args[3].isEmpty ? args[3] : nil
            let sampleRate = 24_000
            let audio = try loadMonoSamples(url: audioURL, targetSampleRate: sampleRate)
            let duration = Double(audio.count) / Double(sampleRate)

            let loadStart = Date()
            let model = try await Qwen3ASRModel.fromPretrained(
                modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
                cacheDir: modelURL,
                offlineMode: true
            ) { progress, status in
                let percent = Int(progress * 100)
                print("LOAD \(percent)% \(status)")
            }
            let loadElapsed = Date().timeIntervalSince(loadStart)

            let inferStart = Date()
            let transcript = model.transcribe(audio: audio, sampleRate: sampleRate, language: language)
            let inferElapsed = Date().timeIntervalSince(inferStart)
            let rtf = duration > 0 ? inferElapsed / duration : 0

            print("AUDIO=\(audioURL.path)")
            print(String(format: "DURATION=%.3f", duration))
            print(String(format: "LOAD_SECONDS=%.3f", loadElapsed))
            print(String(format: "INFERENCE_SECONDS=%.3f", inferElapsed))
            print(String(format: "RTF=%.4f", rtf))
            print("TRANSCRIPT=\(transcript)")
        } catch {
            fputs("ASR smoke test failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func loadMonoSamples(url: URL, targetSampleRate: Int) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SmokeTestError.bufferCreationFailed
        }
        try audioFile.read(into: buffer)
        guard let floatData = buffer.floatChannelData else {
            throw SmokeTestError.noFloatData
        }

        let channels = max(1, Int(format.channelCount))
        let count = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let samples = UnsafeBufferPointer(start: floatData[channel], count: count)
            for index in 0..<count {
                mono[index] += samples[index] / Float(channels)
            }
        }

        let inputRate = Int(format.sampleRate)
        return inputRate == targetSampleRate
            ? mono
            : resample(mono, from: inputRate, to: targetSampleRate)
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
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
        let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(Double(samples.count) * Double(outputRate) / Double(inputRate))
        ) else {
            return samples
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                sourceBuffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
            }
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

enum SmokeTestError: LocalizedError {
    case bufferCreationFailed
    case noFloatData

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: return "Failed to create audio buffer"
        case .noFloatData: return "No float audio data"
        }
    }
}
