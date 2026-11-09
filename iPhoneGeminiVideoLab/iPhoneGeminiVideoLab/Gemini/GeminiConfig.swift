import Foundation
import CoreGraphics

enum AssistantMode: String, CaseIterable, Identifiable {
    case lego = "LEGO 搭建"
    case generalAV = "通用音视频助手"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .lego: return "LEGO 模式"
        case .generalAV: return "通用助手"
        }
    }

    var sessionFolderName: String {
        switch self {
        case .lego: return "LEGOFunctionCalls"
        case .generalAV: return "GeneralAVFunctionCalls"
        }
    }

    var archiveFileName: String {
        switch self {
        case .lego: return "LEGOFunctionCallRequests.zip"
        case .generalAV: return "GeneralAVFunctionCallRequests.zip"
        }
    }
}

// MARK: - Gemini model and media configuration

enum GeminiConfig {
    static let model = "models/gemini-3.8-live"
    static let flashModel = "gemini-3.8-flash"
    static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    static let inputAudioSampleRate: Double = 16_000
    static let outputAudioSampleRate: Double = 24_000
    static let audioChannels: UInt32 = 1
    static let audioBitsPerSample: UInt32 = 16
    static let videoFrameInterval: TimeInterval = 1.0
    static let videoJPEGQuality: CGFloat = 0.9

    static func toolSet(mode: AssistantMode) -> [[String: Any]] {
        switch mode {
        case .lego:
            let requestVerification: [String: Any] = [
                "name": "request_step_verification",
                "description": "MANDATORY whenever the user says 搭好了/做完了 or asks to check the current LEGO step. Call immediately without speaking first. In the same Function Call, generate a short, natural, varied Simplified-Chinese progress_message (one sentence, about 12–30 Chinese characters) that describes what you are about to inspect and asks the user to wait. The iPhone companion app immediately starts a NON_BLOCKING Gemini Flash LOW verification in the background, using a fresh CURRENT JPEG extracted from the Meta glasses HEVC video stream, the matching TARGET AFTER reference image, and the written acceptance criteria. The app then echoes your exact progress_message back to this Live session as a separate text turn so you can speak it while Flash runs. Do NOT judge the images yourself. Do not state a verdict or advance the step until the actual Flash result returns through this original tool call.",
                "behavior": "NON_BLOCKING",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "step": ["type": "INTEGER", "description": "The current step number from the latest iPhone state response."],
                        "progress_message": ["type": "STRING", "description": "A short, natural, varied Simplified-Chinese spoken progress sentence. Ask the user to wait; do not include a verdict. The iPhone will echo this exact sentence back to Live for speech after Flash has started."]
                    ],
                    "required": ["step", "progress_message"]
                ]
            ]
            return [["functionDeclarations": [requestVerification]]]

        case .generalAV:
            let inspectScene: [String: Any] = [
                "name": "inspect_current_scene",
                "description": "Use this tool whenever answering the user's request requires seeing, identifying, reading, locating, counting, comparing, or reasoning about something in the Meta glasses camera view. Call immediately without speaking first. Include the user's visual question and generate a short, natural, varied Simplified-Chinese progress_message in the same Function Call. The iPhone companion app will obtain the latest decoded JPEG from the continuously running Meta glasses HEVC video stream, then start Gemini Flash with LOW thinking level in the background. The iPhone echoes your progress_message back to this Live session while image capture and Flash analysis are underway. Do not guess what is visible and do not give a visual answer until the Flash result returns through this original tool call. For non-visual questions, answer directly without calling this tool.",
                "behavior": "NON_BLOCKING",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "question": ["type": "STRING", "description": "The user's visual question, rewritten clearly and concisely without changing intent."],
                        "progress_message": ["type": "STRING", "description": "A short, natural, varied Simplified-Chinese spoken progress sentence, about 12–30 Chinese characters. Tell the user what you are checking and ask them to wait. Do not include a visual conclusion."]
                    ],
                    "required": ["question", "progress_message"]
                ]
            ]
            return [["functionDeclarations": [inspectScene]]]
        }
    }

    static func systemInstruction(mode: AssistantMode, tutorial: LEGOTutorial? = nil) -> String {
        switch mode {
        case .lego:
            guard let tutorial else {
                return "You are a concise Simplified-Chinese voice assistant. The LEGO tutorial is unavailable."
            }
            return LEGOTutorialRepository.systemInstruction(tutorial: tutorial)

        case .generalAV:
            return """
            You are a helpful, natural, concise Simplified-Chinese real-time audio/video voice assistant running through a Meta Ray-Ban smart-glasses camera and an iPhone companion app.
            Your primary interface is voice. Listen to the user, answer ordinary knowledge or conversational questions directly, and speak naturally.
            The Meta glasses camera is streaming to the iPhone companion app, but camera frames are NOT continuously streamed to you. You cannot see the current scene unless the visual tool returns a result.

            VISUAL TOOL POLICY:
            - If the user asks about anything that requires current camera visual information (what is in front of them, identify an object, read visible text, describe a scene, count objects, inspect a device, compare visible things, etc.), call inspect_current_scene immediately.
            - Do not speak a progress sentence before the Function Call. Call the tool first.
            - In the same Function Call, generate a short, varied, natural Simplified-Chinese `progress_message` that says what you are checking and asks the user to wait. Do not include an answer or verdict in it.
            - Include the user's actual visual question in the `question` argument. Preserve relevant details and context.
            - The iPhone companion app receives the Function Call and obtains a fresh CURRENT JPEG from the latest decoded Meta glasses HEVC video frame. The video stream remains running; there is no standalone camera-photo branch. The app echoes your exact progress_message back to this Live session as a separate user text turn while Flash analysis is underway. Speak that exact sentence aloud once, naturally and briefly. Do not call another tool in response to this progress-speech instruction.
            - Flash LOW is the visual specialist. Do not hallucinate or answer the visual question before the original Function Call response arrives.
            - When the original Function Call response arrives, use its `answer` field to answer the user. Keep the spoken answer concise and conversational. If Flash reports uncertainty, communicate that uncertainty and ask for a clearer view if needed.
            - Do not send a Function Response before Flash finishes. Do not repeat the same visual Function Call unless the user asks again or the previous call failed.
            - For ordinary non-visual questions, do not call the visual tool; answer directly.

            REAL-TIME LATENCY:
            - This is an active audio/video conversation. Keep answers brief.
            - The visual specialist uses LOW thinking level for low latency. It carefully inspects the current image but avoids unnecessary long deliberation.
            - Never expose hidden reasoning or chain-of-thought.
            """
        }
    }

    static func websocketURL() -> URL? {
        guard let key = GeminiKeychain.load(), !key.isEmpty else { return nil }
        guard var components = URLComponents(string: websocketBaseURL) else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url
    }
}
