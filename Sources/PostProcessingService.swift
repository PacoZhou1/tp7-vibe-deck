import Foundation

enum PostProcessingError: LocalizedError {
    case requestFailed(Int, String)
    case invalidResponse(String)
    case invalidInput(String)
    case emptyOutput
    case requestTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let details):
            "Post-processing failed with status \(statusCode): \(details)"
        case .invalidResponse(let details):
            "Invalid post-processing response: \(details)"
        case .invalidInput(let details):
            "Invalid post-processing input: \(details)"
        case .emptyOutput:
            "Post-processing returned empty output"
        case .requestTimedOut(let seconds):
            "Post-processing timed out after \(Int(seconds))s"
        }
    }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
}

final class PostProcessingService {
    static let defaultSystemPrompt = """
你是一个运行在系统后台的专业纯文本处理引擎，绝不是对话型 AI。你的唯一职责是接收粗略的语音转写文本，并静默输出可直接用于出版或正式沟通的干净文本。

请严格执行以下操作指令：
1. 净化杂音：精准剔除所有口语化的无意义停顿词和连接词（如"呃"、"那个"、"然后"、"就是说"、"对吧"等）。
2. 智能纠错：结合上下文逻辑，修正同音错别字和语序混乱。正确处理中英文夹杂（Chinglish）的场景，确保英文专业术语大小写及拼写正确。
3. 精准断句：根据语意逻辑，补充准确的标点符号。
4. 忠于原意：绝不允许改变用户的原始意图、语气，更不允许私自扩写或总结内容。
5. 绝对限制：绝不允许输出任何开场白、解释、确认语或代码块格式。例如，绝不能出现"好的"、"修改如下"等字眼。

仅输出处理后的纯文本结果。
"""
    static let defaultSystemPromptDate = "2026-04-08"
    static let commandModeSystemPrompt = """
You transform highlighted text according to a spoken editing command.

Hard contract:
- Treat SELECTED_TEXT as the only source material to transform.
- Treat VOICE_COMMAND as the user's instruction for how to transform SELECTED_TEXT.
- Return only the replacement text.
- No explanations.
- No markdown.
- No surrounding quotes.
- Do not answer questions outside the scope of rewriting SELECTED_TEXT.
- If the requested change would produce effectively the same text, return the original selected text.

Behavior:
- Preserve the original language unless VOICE_COMMAND explicitly requests translation.
- Use CONTEXT only as a supporting hint for tone, spelling, or intent.
- Use custom vocabulary only as a spelling reference when relevant.
- Never invent unrelated content that is not a transformation of SELECTED_TEXT.
- Do not treat VOICE_COMMAND as dictation to clean up and paste directly.
"""

    private let apiKey: String
    private let baseURL: String
    private let preferredModel: String
    private let preferredFallbackModel: String
    private let contextLimit: Int
    private let defaultModel = "openai/gpt-oss-20b"
    private let defaultFallbackModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let defaultModelReasoningEffort = "low"
    private let postProcessingMaxCompletionTokens = 4096
    private let postProcessingTimeoutSeconds: TimeInterval = 20

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        preferredModel: String = "",
        preferredFallbackModel: String = "",
        contextLimit: Int = 8192
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.preferredModel = preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredFallbackModel = preferredFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextLimit = max(512, contextLimit)
    }

    static func testConnection(
        apiKey: String,
        baseURL: String,
        model: String
    ) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw PostProcessingError.invalidInput("Model ID is empty.")
        }

        var request = URLRequest(url: try chatCompletionsURL(from: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        setAuthorizationHeader(apiKey: apiKey, on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": trimmedModel,
            "temperature": 0.0,
            "max_tokens": 32,
            "messages": [
                [
                    "role": "system",
                    "content": "你是接口健康检查助手。只输出 PONG，不要输出其他内容。"
                ],
                [
                    "role": "user",
                    "content": "ping"
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await LLMAPITransport.data(for: request)
        return try decodeChatCompletionContent(data: data, response: response)
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        customSystemPrompt: String = "",
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)

        let timeoutSeconds = postProcessingTimeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Post-processing service deallocated")
                }
                return try await self.processWithFallback(
                    transcript: transcript,
                    contextSummary: context.contextSummary,
                    customVocabulary: vocabularyTerms,
                    customSystemPrompt: customSystemPrompt,
                    outputLanguage: outputLanguage
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No post-processing result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func commandTransform(
        selectedText: String,
        voiceCommand: String,
        context: AppContext,
        customVocabulary: String,
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)
        let trimmedSelectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoiceCommand = voiceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelectedText.isEmpty else {
            throw PostProcessingError.invalidInput("Selected text must not be empty")
        }
        guard !trimmedVoiceCommand.isEmpty else {
            throw PostProcessingError.invalidInput("Voice command must not be empty")
        }

        let timeoutSeconds = postProcessingTimeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Post-processing service deallocated")
                }
                return try await self.processCommandTransformWithFallback(
                    selectedText: selectedText,
                    voiceCommand: voiceCommand,
                    contextSummary: context.contextSummary,
                    customVocabulary: vocabularyTerms,
                    outputLanguage: outputLanguage
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No post-processing result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func processWithFallback(
        transcript: String,
        contextSummary: String,
        customVocabulary: [String],
        customSystemPrompt: String = "",
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        let primaryModel = resolvedPrimaryModel()
        let retryModel = resolvedRetryModel(for: primaryModel)
        do {
            return try await process(
                transcript: transcript,
                contextSummary: contextSummary,
                model: primaryModel,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage
            )
        } catch let error as PostProcessingError {
            let shouldFallback: Bool
            switch error {
            case .requestFailed(let statusCode, _):
                shouldFallback = statusCode == 429
            case .emptyOutput:
                shouldFallback = true
            default:
                shouldFallback = false
            }

            guard shouldFallback else {
                throw error
            }

            guard let retryModel else {
                throw error
            }

            return try await process(
                transcript: transcript,
                contextSummary: contextSummary,
                model: retryModel,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage
            )
        }
    }

    private func processCommandTransformWithFallback(
        selectedText: String,
        voiceCommand: String,
        contextSummary: String,
        customVocabulary: [String],
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        let primaryModel = resolvedPrimaryModel()
        let retryModel = resolvedRetryModel(for: primaryModel)
        do {
            return try await processCommandTransform(
                selectedText: selectedText,
                voiceCommand: voiceCommand,
                contextSummary: contextSummary,
                model: primaryModel,
                customVocabulary: customVocabulary,
                outputLanguage: outputLanguage
            )
        } catch let error as PostProcessingError {
            let shouldFallback: Bool
            switch error {
            case .requestFailed(let statusCode, _):
                shouldFallback = statusCode == 429
            case .emptyOutput:
                shouldFallback = true
            default:
                shouldFallback = false
            }

            guard shouldFallback else {
                throw error
            }

            guard let retryModel else {
                throw error
            }

            return try await processCommandTransform(
                selectedText: selectedText,
                voiceCommand: voiceCommand,
                contextSummary: contextSummary,
                model: retryModel,
                customVocabulary: customVocabulary,
                outputLanguage: outputLanguage
            )
        }
    }

    private func resolvedPrimaryModel() -> String {
        preferredModel.isEmpty ? defaultModel : preferredModel
    }

    private func resolvedRetryModel(for primaryModel: String) -> String? {
        if !preferredFallbackModel.isEmpty {
            return preferredFallbackModel == primaryModel ? nil : preferredFallbackModel
        }
        if primaryModel == defaultModel {
            return defaultFallbackModel
        }
        if primaryModel == defaultFallbackModel {
            return defaultModel
        }
        return nil
    }

    private func process(
        transcript: String,
        contextSummary: String,
        model: String,
        customVocabulary: [String],
        customSystemPrompt: String = "",
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        var request = URLRequest(url: try Self.chatCompletionsURL(from: baseURL))
        request.httpMethod = "POST"
        Self.setAuthorizationHeader(apiKey: apiKey, on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = postProcessingTimeoutSeconds

        let normalizedVocabulary = normalizedVocabularyText(customVocabulary)
        let vocabularyPrompt = if !normalizedVocabulary.isEmpty {
            """
The following vocabulary must be treated as high-priority terms while rewriting.
Use these spellings exactly in the output when relevant:
\(normalizedVocabulary)
"""
        } else {
            ""
        }

        var systemPrompt = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultSystemPrompt
            : customSystemPrompt
        let trimmedOutputLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutputLanguage.isEmpty {
            systemPrompt = Self.applyOutputLanguage(systemPrompt, language: trimmedOutputLanguage)
        }
        if !vocabularyPrompt.isEmpty {
            systemPrompt += "\n\n" + vocabularyPrompt
        }

        let contextTokenBudget = contextBudget(
            protectedText: [systemPrompt, transcript, vocabularyPrompt]
        )
        let limitedContextSummary = limitContextForPrompt(
            contextSummary,
            tokenBudget: contextTokenBudget
        )

        let userMessage = """
Instructions: Clean up RAW_TRANSCRIPTION and return only the cleaned transcript text without surrounding quotes. Return EMPTY if there should be no result.

CONTEXT: "\(limitedContextSummary)"

RAW_TRANSCRIPTION: "\(transcript)"
"""

        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""

        var payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
                ]
            ]
        ]
        if model == defaultModel {
            payload["max_completion_tokens"] = postProcessingMaxCompletionTokens
            payload["reasoning_effort"] = defaultModelReasoningEffort
            payload["include_reasoning"] = false
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await LLMAPITransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostProcessingError.emptyOutput
        }

        let sanitizedTranscript = sanitizePostProcessedTranscript(content)
        return PostProcessingResult(
            transcript: sanitizedTranscript,
            prompt: promptForDisplay
        )
    }

    private func processCommandTransform(
        selectedText: String,
        voiceCommand: String,
        contextSummary: String,
        model: String,
        customVocabulary: [String],
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        var request = URLRequest(url: try Self.chatCompletionsURL(from: baseURL))
        request.httpMethod = "POST"
        Self.setAuthorizationHeader(apiKey: apiKey, on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = postProcessingTimeoutSeconds

        let normalizedVocabulary = normalizedVocabularyText(customVocabulary)
        let vocabularyPrompt = if !normalizedVocabulary.isEmpty {
            """
The following vocabulary must be treated as high-priority terms while rewriting.
Use these spellings exactly in the output when relevant:
\(normalizedVocabulary)
"""
        } else {
            ""
        }

        var systemPrompt = Self.commandModeSystemPrompt
        let trimmedOutputLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutputLanguage.isEmpty {
            systemPrompt = systemPrompt.replacingOccurrences(
                of: "- Preserve the original language unless VOICE_COMMAND explicitly requests translation.",
                with: "- Output the result in \(trimmedOutputLanguage)."
            )
        }
        if !vocabularyPrompt.isEmpty {
            systemPrompt += "\n\n" + vocabularyPrompt
        }

        let contextTokenBudget = contextBudget(
            protectedText: [systemPrompt, selectedText, voiceCommand, vocabularyPrompt]
        )
        let limitedContextSummary = limitContextForPrompt(
            contextSummary,
            tokenBudget: contextTokenBudget
        )

        let userMessage = """
Transform SELECTED_TEXT according to VOICE_COMMAND and return only the replacement text.

CONTEXT: "\(limitedContextSummary)"

VOICE_COMMAND: "\(voiceCommand)"

SELECTED_TEXT: "\(selectedText)"
"""

        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""

        var payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
                ]
            ]
        ]
        if model == defaultModel {
            payload["max_completion_tokens"] = postProcessingMaxCompletionTokens
            payload["reasoning_effort"] = defaultModelReasoningEffort
            payload["include_reasoning"] = false
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await LLMAPITransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostProcessingError.emptyOutput
        }

        let sanitizedTranscript = sanitizeCommandModeTranscript(content)
        return PostProcessingResult(
            transcript: sanitizedTranscript,
            prompt: promptForDisplay
        )
    }

    static func applyOutputLanguage(_ prompt: String, language: String) -> String {
        prompt + "\n\nIMPORTANT: Translate the final cleaned text into \(language). Output ONLY in \(language), regardless of the original spoken language."
    }

    private static func chatCompletionsURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PostProcessingError.invalidInput("API Base URL is empty.")
        }

        guard var components = URLComponents(string: trimmed) else {
            throw PostProcessingError.invalidInput("API Base URL is malformed.")
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw PostProcessingError.invalidInput("API Base URL must use http or https.")
        }

        guard components.host?.isEmpty == false else {
            throw PostProcessingError.invalidInput("API Base URL must include a host.")
        }

        components.scheme = scheme
        components.path = components.path.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )

        guard let normalizedBaseURL = components.url else {
            throw PostProcessingError.invalidInput("API Base URL is malformed.")
        }

        return normalizedBaseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }

    private static func setAuthorizationHeader(apiKey: String, on request: inout URLRequest) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    }

    private static func decodeChatCompletionContent(data: Data, response: URLResponse) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw PostProcessingError.emptyOutput
        }

        return cleaned
    }

    private func sanitizePostProcessedTranscript(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // Strip outer quotes if the LLM wrapped the entire response
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Treat the sentinel value as empty
        if result == "EMPTY" {
            return ""
        }

        return result
    }

    private func contextBudget(protectedText: [String]) -> Int {
        let reservedTokens = protectedText.reduce(768) { total, value in
            total + estimatedTokenCount(value)
        }
        return max(0, contextLimit - reservedTokens)
    }

    private func limitContextForPrompt(_ value: String, tokenBudget: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard tokenBudget > 0 else { return "" }
        let characterBudget = max(256, tokenBudget * 2)
        guard trimmed.count > characterBudget else { return trimmed }

        return String(trimmed.suffix(characterBudget))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func estimatedTokenCount(_ value: String) -> Int {
        max(1, value.count / 2)
    }

    private func sanitizeCommandModeTranscript(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergedVocabularyTerms(rawVocabulary: String) -> [String] {
        let terms = rawVocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private func normalizedVocabularyText(_ vocabularyTerms: [String]) -> String {
        let terms = vocabularyTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }
}
