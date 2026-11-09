import Foundation
import UIKit

// MARK: - Gemini Live connection state

enum GeminiConnectionState: Equatable {
    case disconnected
    case connecting
    case settingUp
    case ready
    case error(String)
}

struct LiveFunctionCall {
    let id: String
    let name: String
    let args: [String: Any]
}

/// Native BidiGenerateContent WebSocket client.
/// Both app modes receive microphone audio only. Camera JPEGs remain on-device and are
/// sent to Gemini Flash only after Live requests a LEGO check or general scene inspection.
@MainActor
final class GeminiLiveService: ObservableObject {
    @Published private(set) var connectionState: GeminiConnectionState = .disconnected
    @Published private(set) var isModelSpeaking = false
    private(set) var lastConnectionFailure: String?

    var onAudioReceived: ((Data) -> Void)?
    var onInterrupted: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onCameraFramePrepared: ((UIImage, Data, Date, String?) -> Void)?
    var onToolCall: ((LiveFunctionCall) -> Void)?
    var onToolCallCancellation: (([String]) -> Void)?

    private let socketDelegate = LiveSocketDelegate()
    private let socketSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private var connectionID = UUID()
    private let sendQueue = DispatchQueue(label: "gemini.live.send", qos: .userInitiated)
    private let frameEncodeQueue = DispatchQueue(label: "gemini.live.frame-encode", qos: .userInitiated)
    private var systemInstruction = ""
    private var activeMode: AssistantMode = .lego

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        socketSession = URLSession(configuration: configuration,
                                   delegate: socketDelegate,
                                   delegateQueue: nil)
    }

    func connect(mode: AssistantMode, tutorial: LEGOTutorial? = nil) async -> Bool {
        guard let url = GeminiConfig.websocketURL() else {
            connectionState = .error("Please save your Gemini API key first")
            return false
        }
        guard socket == nil else { return connectionState == .ready }
        activeMode = mode
        systemInstruction = GeminiConfig.systemInstruction(mode: mode, tutorial: tutorial)
        lastConnectionFailure = nil
        isModelSpeaking = false
        connectionState = .connecting
        let id = UUID()
        connectionID = id

        return await withCheckedContinuation { continuation in
            connectContinuation = continuation
            socketDelegate.onOpen = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.connectionID == id else { return }
                    self.connectionState = .settingUp
                    self.sendSetupMessage()
                    self.beginReceiving(connectionID: id)
                }
            }
            socketDelegate.onClose = { [weak self] code, reason in
                let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "No reason provided"
                Task { @MainActor [weak self] in
                    self?.fail("WebSocket closed (\(code.rawValue)): \(reasonString)", connectionID: id)
                }
            }
            socketDelegate.onError = { [weak self] error in
                let description = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.fail("WebSocket transport error: \(description)", connectionID: id)
                }
            }
            let task = socketSession.webSocketTask(with: url)
            socket = task
            task.resume()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.connectionID == id else { return }
                if self.connectionState == .connecting || self.connectionState == .settingUp {
                    self.fail("Gemini setup timed out after 15 seconds; no setupComplete", connectionID: id)
                }
            }
        }
    }

    func disconnect() {
        connectionID = UUID()
        receiver?.cancel()
        receiver = nil
        socketDelegate.onOpen = nil
        socketDelegate.onClose = nil
        socketDelegate.onError = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connectionState = .disconnected
        isModelSpeaking = false
        resolveConnect(success: false)
    }

    func sendAudio(_ pcm16kHz: Data) {
        guard connectionState == .ready, let task = socket else { return }
        let id = connectionID
        sendQueue.async { [weak self] in
            self?.sendJSON([
                "realtimeInput": ["audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcm16kHz.base64EncodedString()
                ]]
            ], over: task, connectionID: id)
        }
    }

    /// Encodes each sampled frame once. Both app modes keep camera frames local (sendToLive=false).
    func prepareCameraFrame(_ image: UIImage,
                            capturedAt: Date,
                            cameraMode: String,
                            sendToLive: Bool = false) {
        guard connectionState == .ready else { return }
        let task = socket
        let id = connectionID
        let onPrepared = onCameraFramePrepared
        frameEncodeQueue.async { [weak self] in
            guard let self,
                  let jpeg = image.jpegData(compressionQuality: GeminiConfig.videoJPEGQuality) else { return }
            if sendToLive, let task {
                let payload: [String: Any] = [
                    "realtimeInput": ["video": [
                        "mimeType": "image/jpeg",
                        "data": jpeg.base64EncodedString()
                    ]]
                ]
                self.sendQueue.async { [weak self] in
                    self?.sendJSON(payload, over: task, connectionID: id)
                }
            }
            onPrepared?(image, jpeg, capturedAt, cameraMode)
        }
    }

    /// Initial greeting / text context is a regular user turn in the same Live session.
    func sendClientText(_ text: String, turnComplete: Bool = true) {
        guard connectionState == .ready, let task = socket else { return }
        let id = connectionID
        let payload: [String: Any] = [
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": turnComplete
            ]
        ]
        sendQueue.async { [weak self] in
            self?.sendJSON(payload, over: task, connectionID: id)
        }
    }

    /// After Live emits a visual Function Call, the app immediately starts the
    /// background task and echoes Live's own progress_message back as a separate
    /// clientContent turn. Live speaks it while the original NON_BLOCKING tool
    /// call remains pending. Do NOT use toolResponse here: that would complete
    /// the original call before the visual result is ready.
    func requestProgressSpeech(_ progressMessage: String) {
        let message = progressMessage
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let prompt = """
        APP PROGRESS SPEECH REQUEST (the visual verification tool is already running asynchronously).
        You generated this progress_message in your Function Call. Speak the sentence below aloud
        in Simplified Chinese exactly once, naturally and briefly. Do not call any tool, do not add
        a verdict, and do not claim the inspection is complete. Then return to listening.

        \(message)
        """
        sendClientText(prompt, turnComplete: true)
    }

    /// Returns the final Flash/state-machine result for the original visual Function Call.
    func sendToolResponse(id: String,
                          name: String,
                          response: [String: Any],
                          scheduling: String = "WHEN_IDLE") {
        guard connectionState == .ready, let task = socket else { return }
        let idForConnection = connectionID
        let payload: [String: Any] = [
            "toolResponse": ["functionResponses": [[
                "id": id,
                "name": name,
                "response": response,
                "scheduling": scheduling
            ]]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        sendQueue.async { [weak self] in
            self?.sendSerializedJSON(json, over: task, connectionID: idForConnection)
        }
    }

    func flushCameraFrameQueue(_ done: @escaping () -> Void) {
        frameEncodeQueue.async { [weak self] in
            guard let self else { done(); return }
            self.sendQueue.async { done() }
        }
    }

    private func resolveConnect(success: Bool) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(returning: success)
    }

    private func fail(_ message: String, connectionID id: UUID) {
        guard connectionID == id else { return }
        if case .error = connectionState { return }
        let wasReady = connectionState == .ready
        lastConnectionFailure = message
        connectionState = .error(message)
        isModelSpeaking = false
        resolveConnect(success: false)
        if wasReady { onDisconnected?(message) }
    }

    private func sendSetupMessage() {
        guard let task = socket else { return }
        let setup: [String: Any] = [
            "model": GeminiConfig.model,
            "generationConfig": ["responseModalities": ["AUDIO"]],
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "tools": GeminiConfig.toolSet(mode: activeMode),
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "disabled": false,
                    "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "silenceDurationMs": 500,
                    "prefixPaddingMs": 40
                ],
                "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
            ],
            "inputAudioTranscription": [:] as [String: Any],
            "outputAudioTranscription": [:] as [String: Any]
        ]
        sendJSON(["setup": setup], over: task, connectionID: connectionID)
    }

    private nonisolated func sendJSON(_ object: [String: Any],
                                      over task: URLSessionWebSocketTask,
                                      connectionID id: UUID) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: bytes, encoding: .utf8) else { return }
        sendSerializedJSON(json, over: task, connectionID: id)
    }

    private nonisolated func sendSerializedJSON(_ json: String,
                                                over task: URLSessionWebSocketTask,
                                                connectionID id: UUID) {
        task.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fail("WebSocket send failed: \(error.localizedDescription)", connectionID: id)
            }
        }
    }

    private func beginReceiving(connectionID id: UUID) {
        receiver = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.connectionID == id {
                guard let task = self.socket else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): self.handleMessage(text, connectionID: id)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text, connectionID: id)
                        }
                    @unknown default: break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.fail("WebSocket receive failed: \(error.localizedDescription)", connectionID: id)
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String, connectionID id: UUID) {
        guard connectionID == id,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            connectionState = .ready
            resolveConnect(success: true)
            return
        }
        if let error = json["error"] as? [String: Any] {
            fail("Gemini server error: \(error)", connectionID: id)
            return
        }
        if let toolCall = json["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            for functionCall in functionCalls {
                guard let callID = functionCall["id"] as? String,
                      let name = functionCall["name"] as? String else { continue }
                let args = functionCall["args"] as? [String: Any] ?? [:]
                onToolCall?(LiveFunctionCall(id: callID, name: name, args: args))
            }
            // Do not return here: if a server message also carries serverContent,
            // continue processing it so any spoken progress audio is not dropped.
        }
        if let cancellation = json["toolCallCancellation"] as? [String: Any],
           let ids = cancellation["ids"] as? [String] {
            onToolCallCancellation?(ids)
            // Continue in case the same envelope also contains serverContent.
        }
        if json["goAway"] != nil {
            fail("Gemini server requested session shutdown (goAway)", connectionID: id)
            return
        }

        guard let content = json["serverContent"] as? [String: Any] else { return }
        if content["interrupted"] as? Bool == true {
            isModelSpeaking = false
            onInterrupted?()
        }
        if let turn = content["modelTurn"] as? [String: Any],
           let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inlineData = part["inlineData"] as? [String: Any],
                      let mime = inlineData["mimeType"] as? String,
                      mime.hasPrefix("audio/pcm"),
                      let base64 = inlineData["data"] as? String,
                      let audio = Data(base64Encoded: base64) else { continue }
                isModelSpeaking = true
                onAudioReceived?(audio)
            }
        }
        if let value = content["inputTranscription"] as? [String: Any],
           let transcript = value["text"] as? String, !transcript.isEmpty {
            onInputTranscription?(transcript)
        }
        if let value = content["outputTranscription"] as? [String: Any],
           let transcript = value["text"] as? String, !transcript.isEmpty {
            onOutputTranscription?(transcript)
        }
        if content["turnComplete"] as? Bool == true {
            isModelSpeaking = false
            onTurnComplete?()
        }
    }
}

private final class LiveSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error) -> Void)?

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) { onOpen?() }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) { onClose?(closeCode, reason) }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { onError?(error) }
    }
}
