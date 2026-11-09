import Foundation

enum FlashThinkingLevel: String, CaseIterable, Identifiable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"

    var id: String { rawValue }
    var apiValue: String { rawValue.lowercased() }

    var description: String {
        switch self {
        case .low: return "Lowest latency"
        case .medium: return "Balanced"
        case .high: return "Deeper reasoning"
        }
    }
}

struct FlashVisionResponse {
    let text: String
    let latencyMilliseconds: Int
    let promptTokenCount: Int?
    let candidateTokenCount: Int?
    let thoughtsTokenCount: Int?
    let rawResponseBody: Data
    let httpStatusCode: Int
}

enum FlashVisionError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gemini Flash API URL"
        case .invalidResponse: return "Gemini Flash returned an unreadable response"
        case .httpError(let status, let detail): return "Gemini Flash HTTP \(status): \(detail)"
        case .emptyResponse: return "Gemini Flash returned no text"
        }
    }
}

/// One-shot image perception for the general audio/video assistant.
final class GeminiFlashVisionService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    func analyze(jpegData: Data,
                 question: String,
                 thinkingLevel: FlashThinkingLevel = .low,
                 apiKey: String,
                 onRequestBuilt: ((Data) -> Void)? = nil) async throws -> FlashVisionResponse {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiConfig.flashModel):generateContent"
        guard let url = URL(string: endpoint) else { throw FlashVisionError.invalidURL }

        let systemPrompt = """
        You are a fast but careful visual perception specialist invoked during an ongoing real-time audio/video call.
        The user and the voice assistant are waiting for your result, so latency is important.
        Carefully inspect the latest image captured by the Meta glasses and answer the user's spoken visual question.
        Use the LOW thinking budget: make a quick evidence-based decision without unnecessary multi-step deliberation.
        Do not produce chain-of-thought, exhaustive scene descriptions, or long explanations.
        Keep the answer concise: normally 1–3 short sentences and no more than 60 words.
        Report only details supported by the image. If something is unclear, explicitly say so rather than guess.
        Do not add greetings, preambles, markdown headings, or generic disclaimers.
        """

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = """
        User's spoken visual question:
        \(cleanQuestion.isEmpty ? "Briefly describe the most relevant visible information." : cleanQuestion)

        Inspect the attached CURRENT Meta glasses image and answer that question directly.
        This is a live audio/video conversation. Decide quickly, but carefully inspect relevant visual details.
        """

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": userPrompt],
                    ["inlineData": [
                        "mimeType": "image/jpeg",
                        "data": jpegData.base64EncodedString()
                    ]]
                ]
            ]],
            "generationConfig": [
                "thinkingConfig": ["thinkingLevel": thinkingLevel.apiValue],
                "maxOutputTokens": 256
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.httpBody = requestBody
        // Called immediately before the network request is dispatched. No API key is included.
        onRequestBuilt?(requestBody)

        let startedAt = Date()
        let (data, response) = try await session.data(for: request)
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)

        guard let http = response as? HTTPURLResponse else { throw FlashVisionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "No response body"
            throw FlashVisionError.httpError(http.statusCode, String(raw.prefix(1200)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw FlashVisionError.invalidResponse
        }

        let answer = parts.compactMap { part -> String? in
            if part["thought"] as? Bool == true { return nil }
            return part["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw FlashVisionError.emptyResponse }

        let usage = json["usageMetadata"] as? [String: Any]
        return FlashVisionResponse(
            text: answer,
            latencyMilliseconds: elapsed,
            promptTokenCount: usage?["promptTokenCount"] as? Int,
            candidateTokenCount: usage?["candidatesTokenCount"] as? Int,
            thoughtsTokenCount: usage?["thoughtsTokenCount"] as? Int,
            rawResponseBody: data,
            httpStatusCode: http.statusCode
        )
    }
}
