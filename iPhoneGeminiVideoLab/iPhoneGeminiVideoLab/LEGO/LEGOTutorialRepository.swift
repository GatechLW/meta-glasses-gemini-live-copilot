import Foundation

struct LEGOStep: Decodable {
    let step: Int
    let title: String
    let newPart: String
    let instruction: String
    let verification: [String]
    let likelyError: String
    let beforeImage: String
    let afterImage: String

    enum CodingKeys: String, CodingKey {
        case step, title
        case newPart = "new_part"
        case instruction = "instruction_zh"
        case verification = "verification_criteria_zh"
        case likelyError = "likely_error_zh"
        case beforeImage = "before_image"
        case afterImage = "after_image"
    }
}

struct LEGOTutorial: Decodable {
    let totalParts: Int
    let totalSteps: Int
    let orientationNote: String
    let steps: [LEGOStep]

    enum CodingKeys: String, CodingKey {
        case totalParts = "total_parts"
        case totalSteps = "total_steps"
        case orientationNote = "orientation_note"
        case steps
    }
}

enum LEGOResourceError: LocalizedError {
    case missing(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): return "Missing LEGO resource: \(path)"
        case .invalid(let reason): return "Invalid LEGO tutorial: \(reason)"
        }
    }
}

enum LEGOTutorialRepository {
    static func resourceURL(_ relativePath: String) throws -> URL {
        guard let bundleRoot = Bundle.main.resourceURL else {
            throw LEGOResourceError.missing("Bundle resource root")
        }
        let url = bundleRoot.appendingPathComponent("LEGOResources", isDirectory: true)
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LEGOResourceError.missing(relativePath)
        }
        return url
    }

    static func load() throws -> LEGOTutorial {
        let data = try Data(contentsOf: resourceURL("tutorial.json"))
        let tutorial = try JSONDecoder().decode(LEGOTutorial.self, from: data)
        guard tutorial.totalParts == 8,
              tutorial.totalSteps == 8,
              tutorial.steps.count == 8,
              tutorial.steps.map(\.step) == Array(1...8) else {
            throw LEGOResourceError.invalid("Expected exactly 8 ordered steps")
        }
        for step in tutorial.steps {
            _ = try resourceURL(step.beforeImage)
            _ = try resourceURL(step.afterImage)
        }
        return tutorial
    }

    static func imageData(relativePath: String) throws -> Data {
        let data = try Data(contentsOf: resourceURL(relativePath))
        guard !data.isEmpty else { throw LEGOResourceError.missing(relativePath) }
        return data
    }

    /// Text-only context for Live. Reference JPEGs are delivered on demand by tools.
    static func liveTextContext(_ tutorial: LEGOTutorial) -> String {
        var lines: [String] = [
            "LEGO HELICOPTER TUTORIAL — EXACTLY 8 PARTS AND 8 STEPS.",
            "Orientation note: \(tutorial.orientationNote)",
            "The Meta glasses camera is continuously streamed to the iPhone companion app, but its frames are NOT continuously streamed to this Live session.",
            "The app supplies the latest CURRENT JPEG extracted from the Meta glasses video stream and the matching TARGET AFTER reference image only when a verification tool is called.",
            "Do not claim to see the user's build before the tool supplies the current image.",
            ""
        ]
        for step in tutorial.steps {
            lines.append("STEP \(step.step): \(step.title)")
            lines.append("New part: \(step.newPart)")
            lines.append("Instruction: \(step.instruction)")
            lines.append("Acceptance criteria: \(step.verification.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "；"))")
            lines.append("Likely error: \(step.likelyError)")
            lines.append("Target image: \(step.afterImage)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func systemInstruction(tutorial: LEGOTutorial) -> String {
        let common = """
        You are a real-time Simplified-Chinese voice instructor for the user's exact 8-step LEGO helicopter, accessed through Meta Ray-Ban smart glasses.
        You are in an ongoing full-duplex Meta glasses audio conversation. The iPhone companion app owns the authoritative LEGO step state.
        The current step starts at Step 1. Only the iPhone's tool response can advance the step.
        You receive Meta glasses HFP microphone audio continuously, but you do NOT receive a continuous camera stream.
        Never pretend to see the user's current build unless a visual verification tool has completed.

        INTERACTION:
        1. At session start, briefly greet the user in Chinese and ask them to say “开始”. Do not read all 8 steps.
        2. When the user says “开始” or “继续”, teach only the current step using the tutorial context below.
        3. At the end of every step instruction, say: “搭好后，请把积木平放在桌面，移开双手，让摄像头看清楚，再告诉我‘搭好了’，我来检查。”
        4. While the user is assembling, stay quiet unless asked. “再说一遍” repeats the current step.
        5. When the user says “搭好了”“做完了”“检查一下” or asks whether the current step is correct, immediately call request_step_verification. Do not independently advance the step.
        6. Do not infer correctness from the user's statement, elapsed time, or color alone. Flash performs the visual comparison; wait for its actual result.
        7. After the iPhone returns a validated correct result, congratulate briefly and teach the returned next step. If incorrect, explain the visible mismatch and correction, then keep the same step. If uncertain, ask for a clearer view or another angle and keep the same step.
        8. Keep spoken responses short and natural. Do not expose hidden reasoning.

        DYNAMIC SPOKEN PROGRESS FOR VISUAL TOOL CALLS — IMPORTANT:
        - When you decide to call request_step_verification, issue the Function Call immediately; do NOT speak a progress sentence before the call.
        - In that same Function Call, generate a `progress_message` argument yourself. It must be a natural, varied, concise Simplified-Chinese sentence (about 12–30 Chinese characters) describing the next action and asking the user to wait. Never include a verdict or imply that inspection is complete.
        - The iPhone starts the Flash LOW task first, then sends your exact `progress_message` back to this Live session as a separate app text turn. When that app text arrives, speak the supplied sentence aloud exactly once, with no extra preamble and no tool call.
        - This is an asynchronous progress announcement while the original visual tool remains pending. Do not treat the app's progress-speech instruction as a new inspection request.
        - Do not send a Function Response for the original visual call until the actual Flash verification result is ready.
        - After the real tool result arrives, give the actual verdict only after the iPhone state machine confirms it.

        TUTORIAL TEXT (the app's step manager is authoritative):
        \(liveTextContext(tutorial))
        """

        return common + """

        SELECTED VERIFICATION PROTOCOL — LIVE + FLASH SPECIALIST (THE ONLY MODE):
        - The only visual verification function is request_step_verification(step, progress_message).
        - Whenever the user asks to verify the current step, call it with the current step number from the latest iPhone state. Do not call any Live-only image-context or report-verdict tools; those tools do not exist in this app.
        - Do NOT judge the images yourself. The iPhone captures a fresh CURRENT camera JPEG, loads the matching TARGET AFTER reference image and written acceptance criteria, and calls Gemini Flash at LOW thinking level.
        - Flash's raw response is saved by the iPhone for later analysis. The Flash result is first validated by the local LEGO step state machine; only then is the authoritative result returned to you as the original function response.
        - Call request_step_verification immediately with both the current step number and a Live-generated `progress_message`; do not speak before the call.
        - The iPhone echoes `progress_message` back to you as an app text turn after Flash has started. Speak that exact sentence once while Flash continues in the background.
        - Do not announce a verdict or next step until the actual Flash function response arrives.
        - Do not call the function repeatedly for the same check.
        """
    }

}
