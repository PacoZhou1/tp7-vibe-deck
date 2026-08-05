import Foundation
import os.log

private let localLog = OSLog(subsystem: "com.openspeech.app", category: "LocalBackend")

/// Calls the local MLX inference backend (localhost:8001) for text polishing.
enum LocalBackendClient {
    static let defaultBaseURL = "http://127.0.0.1:8001"
    private static let sessionHeader = "X-Open-Speech-Session"

    // MARK: - ASR (SenseVoice)

    static func transcribe(
        fileURL: URL,
        sessionToken: String,
        baseURL: String = defaultBaseURL
    ) async throws -> String {
        let url = URL(string: "\(baseURL)/asr")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(sessionToken, forHTTPHeaderField: sessionHeader)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = createMultipartBody(fileURL: fileURL, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalBackendError.invalidResponse
        }
        try validateIdentity(response: httpResponse, expectedSessionToken: sessionToken)
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            os_log(.error, log: localLog, "ASR failed: HTTP %d body=%@", httpResponse.statusCode, body)
            throw LocalBackendError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        struct ASRResponse: Decodable { let text: String }
        return try JSONDecoder().decode(ASRResponse.self, from: data).text
    }

    // MARK: - Polish (Text Correction)

    /// Polish / correct text via the bundled local LLM backend.
    /// - Parameters:
    ///   - text: Raw transcription text
    ///   - customVocabulary: User vocabulary to bias correction spelling
    ///   - context: Optional app/window context summary
    ///   - baseURL: Backend base URL
    /// - Returns: Corrected text
    static func polish(
        text: String,
        customPrompt: String = "",
        customVocabulary: String = "",
        context: String = "",
        sessionToken: String,
        baseURL: String = defaultBaseURL
    ) async throws -> String {
        let url = URL(string: "\(baseURL)/polish")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionToken, forHTTPHeaderField: sessionHeader)
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "text": text,
            "prompt": customPrompt,
            "vocabulary": customVocabulary,
            "context": context
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalBackendError.invalidResponse
        }
        try validateIdentity(response: httpResponse, expectedSessionToken: sessionToken)
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            os_log(.error, log: localLog, "Polish failed: HTTP %d body=%@", httpResponse.statusCode, body)
            throw LocalBackendError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        struct PolishResponse: Decodable { let polished: String }
        let decoded = try JSONDecoder().decode(PolishResponse.self, from: data)
        return decoded.polished
    }

    private static func validateIdentity(
        response: HTTPURLResponse,
        expectedSessionToken: String
    ) throws {
        let actualSessionToken = response.value(forHTTPHeaderField: sessionHeader) ?? ""
        guard !expectedSessionToken.isEmpty, actualSessionToken == expectedSessionToken else {
            os_log(
                .error,
                log: localLog,
                "Rejected response from stale or foreign local backend"
            )
            throw LocalBackendError.backendIdentityMismatch
        }
    }

    private static func createMultipartBody(fileURL: URL, boundary: String) -> Data {
        var body = Data()
        let filename = fileURL.lastPathComponent

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append(fileData)
        }
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

enum LocalBackendError: LocalizedError {
    case invalidResponse
    case backendIdentityMismatch
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from local backend"
        case .backendIdentityMismatch:
            return "Local backend identity mismatch; a stale Open Speech process may still own port 8001"
        case .httpError(let code, let body):
            return "Local backend HTTP \(code): \(body)"
        }
    }
}
