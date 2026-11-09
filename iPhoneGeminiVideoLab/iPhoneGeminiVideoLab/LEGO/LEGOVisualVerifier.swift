import Foundation

struct LEGOVisualInspection {
    let verdict: String
    let evidence: String
    let correction: String
    let checks: [String: String]
    let model: String
    let rawJSON: String
    let rawResponseBody: Data?
    let httpStatusCode: Int?
    let errorMessage: String?
    let latencyMilliseconds: Int
    let promptTokenCount: Int?
    let candidateTokenCount: Int?
    let thoughtsTokenCount: Int?
}

enum LEGOVisualVerifierError: LocalizedError {
    case noAPIKey
    case invalidImage
    case invalidServerResponse
    case httpError(Int, String)
    case mismatchedStep
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Gemini API key is missing"
        case .invalidImage: return "Unable to read the current or target LEGO image"
        case .invalidServerResponse: return "Gemini Flash returned an unreadable response"
        case .httpError(let code, let detail): return "Gemini Flash HTTP \(code): \(detail)"
        case .mismatchedStep: return "Flash returned a different step number"
        case .emptyResponse: return "Gemini Flash returned an empty response"
        }
    }
}

/// One-shot step verifier. Sends only CURRENT + TARGET + written criteria to Flash.
struct LEGOVisualVerifier {
    private static let checks = ["image_quality", "part_identity", "part_count", "placement", "orientation"]

    static func verify(step: LEGOStep,
                        currentJPEG: Data,
                        onRequestBuilt: ((Data, Data) -> Void)? = nil) async throws -> LEGOVisualInspection {
        guard !currentJPEG.isEmpty else { throw LEGOVisualVerifierError.invalidImage }
        guard let apiKey = GeminiKeychain.load(), !apiKey.isEmpty else {
            throw LEGOVisualVerifierError.noAPIKey
        }
        let targetJPEG = try LEGOTutorialRepository.imageData(relativePath: step.afterImage)
        guard !targetJPEG.isEmpty else { throw LEGOVisualVerifierError.invalidImage }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "step": ["type": "integer"],
                "judgement": ["type": "string", "enum": ["correct", "incorrect", "uncertain"]],
                "image_quality": ["type": "string", "enum": ["pass", "fail", "unknown"]],
                "part_identity": ["type": "string", "enum": ["pass", "fail", "unknown"]],
                "part_count": ["type": "string", "enum": ["pass", "fail", "unknown"]],
                "placement": ["type": "string", "enum": ["pass", "fail", "unknown"]],
                "orientation": ["type": "string", "enum": ["pass", "fail", "unknown"]],
                "evidence": ["type": "string"],
                "correction": ["type": "string"]
            ],
            "required": ["step", "judgement"] + checks + ["evidence", "correction"]
        ]

        let systemPrompt = """
        You are a fast but careful visual verifier for an ongoing real-time audio/video LEGO assembly call.
        The user and voice assistant are waiting for this step-level decision. Latency matters.
        Inspect the supplied TARGET reference image and CURRENT glasses-video frame carefully, make a direct evidence-based decision, and avoid unnecessary long reasoning.
        Do not produce chain-of-thought or a long explanation. Return only the required compact JSON.
        Do not guess. If a detail is blurred, occluded, or cannot be compared reliably, mark that check unknown and judgement uncertain.
        A color match alone is never sufficient: inspect part geometry, stud count, placement, connection and orientation.
        """

        let criteria = step.verification.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let userPrompt = """
        REAL-TIME STEP VERIFICATION — STEP \(step.step): \(step.title)
        New part: \(step.newPart)
        Assembly instruction: \(step.instruction)
        Acceptance criteria:
        \(criteria)
        Known common mistake: \(step.likelyError)
        Reference orientation note: left/right are defined from the TARGET reference photo viewpoint. Account for camera rotation and perspective; do not mechanically compare screen-left to screen-left.

        IMAGE 1 is TARGET_AFTER: the official completed reference state for Step \(step.step).
        IMAGE 2 is CURRENT: the latest JPEG extracted from the Meta Ray-Ban glasses' HEVC video stream. It shows the user's actual build. Judge the user's build from IMAGE 2 only, comparing it against IMAGE 1.

        Return JSON fields: step, judgement, image_quality, part_identity, part_count, placement, orientation, evidence, correction.
        Each check must be pass, fail, or unknown. Set correct only when image_quality, part_identity, part_count, placement and orientation are ALL pass and evidence cites a concrete visible geometric/connection detail. Set incorrect if a clearly visible required part, count, placement or orientation is wrong. Otherwise set uncertain.
        Keep evidence to one concise sentence and correction to one concise action. For correct, correction must be an empty string.
        This is an active audio/video call: decide quickly and answer concisely, without exhaustive deliberation.
        """

        func textPart(_ text: String) -> [String: Any] { ["text": text] }
        func imagePart(_ bytes: Data) -> [String: Any] {
            ["inlineData": ["mimeType": "image/jpeg", "data": bytes.base64EncodedString()]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [textPart(systemPrompt)]],
            "contents": [[
                "role": "user",
                "parts": [
                    textPart(userPrompt),
                    textPart("IMAGE 1 — TARGET_AFTER reference. This is the required completed state, NOT the user's current build."),
                    imagePart(targetJPEG),
                    textPart("IMAGE 2 — CURRENT frame from the Meta Ray-Ban glasses HEVC video stream. This is the user's actual build. Base the verdict on this image."),
                    imagePart(currentJPEG)
                ]
            ]],
            "generationConfig": [
                "thinkingConfig": ["thinkingLevel": "low"],
                "responseMimeType": "application/json",
                "responseJsonSchema": schema,
                "maxOutputTokens": 256
            ]
        ]

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiConfig.flashModel):generateContent") else {
            throw LEGOVisualVerifierError.invalidServerResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.httpBody = requestBody
        // Persist the exact REST request body (without API key headers) together
        // with the two JPEGs only when this verification Function Call occurs.
        onRequestBuilt?(requestBody, targetJPEG)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse else { throw LEGOVisualVerifierError.invalidServerResponse }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(1200), as: UTF8.self)
            throw LEGOVisualVerifierError.httpError(http.statusCode, detail)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LEGOVisualVerifierError.invalidServerResponse
        }
        let rawText = parts.compactMap { part -> String? in
            if part["thought"] as? Bool == true { return nil }
            return part["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty,
              let parsedData = rawText.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: parsedData) as? [String: Any] else {
            throw LEGOVisualVerifierError.emptyResponse
        }
        guard let returnedStep = parsed["step"] as? Int, returnedStep == step.step else {
            throw LEGOVisualVerifierError.mismatchedStep
        }

        let rawJudgement = (parsed["judgement"] as? String ?? "uncertain").lowercased()
        let evidence = (parsed["evidence"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let correction = (parsed["correction"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var statuses: [String: String] = [:]
        for field in checks { statuses[field] = (parsed[field] as? String ?? "unknown").lowercased() }

        let verdict: String
        if statuses["image_quality"] != "pass" {
            verdict = "uncertain"
        } else if ["part_identity", "part_count", "placement", "orientation"].contains(where: { statuses[$0] == "fail" }) {
            verdict = "incorrect"
        } else if rawJudgement == "correct", statuses.values.allSatisfy({ $0 == "pass" }), evidence.count >= 10 {
            verdict = "correct"
        } else if rawJudgement == "incorrect", ["part_identity", "part_count", "placement", "orientation"].contains(where: { statuses[$0] == "fail" }) {
            verdict = "incorrect"
        } else {
            verdict = "uncertain"
        }

        let usage = root["usageMetadata"] as? [String: Any]
        return LEGOVisualInspection(
            verdict: verdict,
            evidence: evidence,
            correction: correction,
            checks: statuses,
            model: GeminiConfig.flashModel,
            rawJSON: rawText,
            rawResponseBody: data,
            httpStatusCode: http.statusCode,
            errorMessage: nil,
            latencyMilliseconds: latency,
            promptTokenCount: usage?["promptTokenCount"] as? Int,
            candidateTokenCount: usage?["candidatesTokenCount"] as? Int,
            thoughtsTokenCount: usage?["thoughtsTokenCount"] as? Int
        )
    }
}
