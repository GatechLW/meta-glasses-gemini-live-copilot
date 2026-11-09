import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var selectedMode: AssistantMode = .generalAV

    @Published private(set) var latestGlassesFrame: UIImage?
    @Published private(set) var glassesStatus = "尚未连接 Meta 眼镜"
    @Published private(set) var audioRouteStatus = "尚未启动音频会话"
    @Published private(set) var actualFrameDimensions = "—"
    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    @Published private(set) var hasAPIKey = GeminiKeychain.load() != nil
    @Published private(set) var recordedFrameCount = 0
    @Published private(set) var captureStatus = "视觉 Function Call 发生时才保存图片和请求"
    @Published private(set) var connectionStatus = "未连接"
    @Published private(set) var errorMessage: String?
    @Published private(set) var userTranscript = ""
    @Published private(set) var aiTranscript = ""
    @Published private(set) var zipURL: URL?
    @Published private(set) var isExporting = false
    @Published private(set) var isCaptureFinalized = false

    @Published private(set) var currentStepNumber = 1
    @Published private(set) var totalSteps = 8
    @Published private(set) var currentStepTitle = "摆放白色短底板"
    @Published private(set) var stepPhaseText = LEGOPhase.preparing.rawValue
    @Published private(set) var lastStepVerdict = "尚未验收"
    @Published private(set) var stepEventLog: [String] = []
    @Published private(set) var targetPreviewImage: UIImage?

    @Published private(set) var flashStatus = "等待 Live 请求 Step 验收"
    @Published private(set) var flashResultText = ""
    @Published private(set) var flashLatencyMilliseconds: Int?
    @Published private(set) var flashRequestCount = 0
    @Published private(set) var latestFrameAgeText = "尚无摄像头帧"
    @Published private(set) var diagnosticLogText = "等待启动诊断日志…"
    @Published private(set) var diagnosticLogCount = 0
    @Published private(set) var diagnosticLogURL: URL?

    private var diagnosticLogLines: [String] = []
    private var diagnosticLogFileURL: URL?

    private let glasses = MetaGlassesDATManager()
    private let gemini = GeminiLiveService()
    private let audio = AudioManager()
    private var recorder = GeminiInputFrameRecorder()
    private var stepManager: LEGOStepManager?
    private var tutorial: LEGOTutorial?
    private var activeMode: AssistantMode = .generalAV
    private var activeSessionID = UUID()
    private var latestFrameJPEG: Data?
    private var latestFrameCapturedAt: Date?
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var frameWaiter: FrameWaiter?
    private var lastGeminiFrameUptime: TimeInterval = -1

    private struct CameraFrameSnapshot {
        let jpeg: Data
        let capturedAt: Date
        let width: Int
        let height: Int
        let imageSource: String
    }

    private struct FrameWaiter {
        let id: UUID
        let after: Date
        let continuation: CheckedContinuation<CameraFrameSnapshot?, Never>
    }

    var isCompleted: Bool { currentStepNumber > totalSteps }
    var flashThinkingLevelLabel: String { "LOW（固定）" }

    var liveRoutingLabel: String {
        switch selectedMode {
        case .lego:
            return "麦克风 → Live；CURRENT + TARGET + 步骤标准 → Flash LOW；验收结果 → Live"
        case .generalAV:
            return "麦克风 → Live；视觉问题触发 Function Call；CURRENT + 问题 → Flash LOW；文字结果 → Live"
        }
    }

    var flashLatencyLabel: String {
        guard let value = flashLatencyMilliseconds else { return "—" }
        return String(format: "%.2f s", Double(value) / 1000.0)
    }

    var diagnosticLogPreview: String {
        diagnosticLogLines.suffix(18).joined(separator: "\n")
    }

    init() {
        glasses.onFrame = { [weak self] image, timestamp in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestGlassesFrame = image
                let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
                let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
                self.actualFrameDimensions = "\(width) × \(height)"
                self.latestFrameAgeText = "Meta 眼镜画面：\(Self.timeString(timestamp)) · \(width)×\(height)"

                // Preview may update at up to 5 FPS, but Gemini's local image cache
                // remains deliberately limited to 1 FPS.
                let uptime = ProcessInfo.processInfo.systemUptime
                guard self.isRunning,
                      self.lastGeminiFrameUptime < 0 ||
                      uptime - self.lastGeminiFrameUptime >= GeminiConfig.videoFrameInterval else {
                    return
                }
                self.lastGeminiFrameUptime = uptime
                self.gemini.prepareCameraFrame(
                    image,
                    capturedAt: timestamp,
                    cameraMode: "Meta DAT 1.0.1 HEVC High 720x1280",
                    sendToLive: false
                )
            }
        }

        glasses.onDiagnosticLog = { [weak self] message in
            Task { @MainActor [weak self] in self?.appendDiagnostic(message) }
        }
        glasses.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.glassesStatus = status
            }
        }
        glasses.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.errorMessage = message
                self.appendDiagnostic("APP_ERROR Meta DAT: \(message)")
            }
        }

        // Full-duplex glasses audio: the Meta glasses HFP microphone remains live
        // while Gemini is speaking. The glasses/HFP voice path performs its own
        // near-end processing; server VAD + START_OF_ACTIVITY_INTERRUPTS handles
        // user barge-in. Never gate this on isModelSpeaking.
        audio.onAudioCaptured = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.gemini.sendAudio(data)
            }
        }

        audio.onPlaybackDrained = { [weak self] in
            guard let self else { return }
            self.stepManager?.modelAudioDrained()
            self.syncStepState()
        }
        audio.onRouteChanged = { [weak self] route in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioRouteStatus = route
                self.appendDiagnostic("AUDIO_ROUTE \(route)")
            }
        }
        audio.onRouteInvalidated = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, self.isStarting || self.isRunning else { return }
                self.appendDiagnostic("AUDIO_ROUTE_INVALIDATED \(reason)")
                self.stop()
                self.errorMessage = "眼镜音频连接中断：\(reason)"
            }
        }

        // VisionClaw's working ordering: wait for DAT DeviceSession.started,
        // select the glasses Bluetooth HFP route, wait for iOS to switch it,
        // and only then let MetaGlassesDATManager start the camera stream.
        glasses.beforeStreamStart = { [weak self] in
            guard let self else {
                throw GlassesAudioRouteError.bluetoothHFPInputUnavailable(available: "SessionViewModel released")
            }
            try await self.audio.requireGlassesHFPRoute()
            self.appendDiagnostic("AUDIO_ROUTE strict_glasses_HFP_preflight_confirmed")
        }
        gemini.onAudioReceived = { [weak self] data in
            self?.audio.playAudio(data: data)
        }
        gemini.onInterrupted = { [weak self] in
            self?.audio.stopPlayback()
        }
        gemini.onTurnComplete = { [weak self] in
            self?.audio.markServerTurnComplete()
        }
        gemini.onInputTranscription = { [weak self] text in
            guard let self else { return }
            self.userTranscript += text
            self.stepManager?.heardUser(text)
            self.syncStepState()
        }
        gemini.onOutputTranscription = { [weak self] text in
            self?.aiTranscript += text
        }
        gemini.onToolCall = { [weak self] call in
            self?.handleLiveToolCall(call)
        }
        gemini.onToolCallCancellation = { [weak self] ids in
            guard let self else { return }
            for id in ids {
                self.pendingTasks[id]?.cancel()
                self.pendingTasks[id] = nil
            }
            if !ids.isEmpty {
                self.stepManager?.cancelVerification(reason: "Live cancelled the tool call")
                self.flashStatus = "验收已被 Live 取消"
                self.syncStepState()
            }
        }
        gemini.onDisconnected = { [weak self] reason in
            guard let self else { return }
            self.stop()
            self.errorMessage = "连接中断：\(reason)"
        }
    }

    private func beginDiagnosticLogSession() {
        diagnosticLogLines.removeAll()
        diagnosticLogText = ""
        diagnosticLogCount = 0
        diagnosticLogURL = nil
        diagnosticLogFileURL = nil

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetaGlassesDiagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("MetaGlasses_\(stamp).log")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            diagnosticLogFileURL = url
            diagnosticLogURL = url
            appendDiagnostic("========== NEW SESSION ==========")
            appendDiagnostic("APP_VERSION=2.4.0-build5 DAT_SDK=1.0.1 mode=\(selectedMode.rawValue) capture_source=meta_video_stream strict_audio_route=bluetooth_hfp")
            appendDiagnostic("DEVICE=\(UIDevice.current.model) iOS=\(UIDevice.current.systemVersion)")
        } catch {
            appendDiagnostic("LOG_FILE_CREATE_FAILED \(error.localizedDescription)")
        }
    }

    private func appendDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)"
        diagnosticLogLines.append(line)
        if diagnosticLogLines.count > 800 {
            diagnosticLogLines.removeFirst(diagnosticLogLines.count - 800)
        }
        diagnosticLogCount = diagnosticLogLines.count
        diagnosticLogText = diagnosticLogLines.joined(separator: "\n")

        if let url = diagnosticLogFileURL,
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
        NSLog("[A/V Diagnostic] %@", line)
    }

    func copyDiagnosticLogs() {
        appendDiagnostic("USER_ACTION copied_diagnostic_log_to_clipboard")
        // Read the on-disk session log so the clipboard receives the complete run,
        // even if the in-memory UI preview has been bounded for long sessions.
        let completeLog = diagnosticLogFileURL.flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        } ?? diagnosticLogText
        UIPasteboard.general.string = completeLog
    }

    func saveAPIKey(_ key: String) -> Bool {
        let ok = GeminiKeychain.save(key)
        hasAPIKey = GeminiKeychain.load() != nil
        if !ok {
            errorMessage = "无法将 Gemini API Key 保存到 Keychain"
        } else {
            errorMessage = nil
        }
        return ok
    }

    func registerMetaGlasses() {
        Task {
            do {
                try await glasses.registerWithMetaAI()
            } catch {
                errorMessage = "Meta AI 注册 / 授权失败：\(error.localizedDescription)"
            }
        }
    }

    func handleMetaURL(_ url: URL) {
        Task {
            do {
                try await glasses.handleMetaURL(url)
            } catch {
                errorMessage = "处理 Meta Wearables 回调失败：\(error.localizedDescription)"
            }
        }
    }

    func start() async {
        guard !isRunning, !isStarting else { return }

        beginDiagnosticLogSession()
        errorMessage = nil
        zipURL = nil
        activeMode = selectedMode
        appendDiagnostic("APP_START requested mode=\(activeMode.rawValue) capture_source=meta_video_stream flash_model=\(GeminiConfig.flashModel) live_model=\(GeminiConfig.model)")

        guard GeminiKeychain.load() != nil else {
            errorMessage = "请先输入并保存 Gemini API Key"
            return
        }

        let microphoneAllowed = await requestMicrophonePermission()
        appendDiagnostic("MICROPHONE_PERMISSION granted=\(microphoneAllowed)")
        guard microphoneAllowed else {
            errorMessage = "麦克风权限未开启，请在 iOS 设置中允许访问麦克风。"
            return
        }

        let loadedTutorial: LEGOTutorial?
        switch activeMode {
        case .lego:
            do {
                let loaded = try LEGOTutorialRepository.load()
                tutorial = loaded
                stepManager = LEGOStepManager(tutorial: loaded)
                loadedTutorial = loaded
                syncStepState()
            } catch {
                errorMessage = "无法加载内置 LEGO 教程：\(error.localizedDescription)"
                appendDiagnostic("LEGO_TUTORIAL_LOAD_FAILED \(error.localizedDescription)")
                return
            }

        case .generalAV:
            tutorial = nil
            stepManager = nil
            targetPreviewImage = nil
            loadedTutorial = nil
        }

        isStarting = true
        isRunning = false
        connectionStatus = "正在准备 Meta 眼镜及其 HFP 音频…"
        actualFrameDimensions = "—"
        latestGlassesFrame = nil
        userTranscript = ""
        aiTranscript = ""
        flashStatus = activeMode == .lego
            ? "等待 Live 调用 request_step_verification"
            : "等待 Live 识别视觉问题并调用 inspect_current_scene"
        flashResultText = ""
        flashLatencyMilliseconds = nil
        flashRequestCount = 0
        latestFrameJPEG = nil
        latestFrameCapturedAt = nil
        latestFrameAgeText = "等待 Meta 眼镜视频帧"
        recordedFrameCount = 0
        captureStatus = "普通视频帧只保留在内存；只有视觉 Function Call 才保存 CURRENT JPEG、Flash request 和响应。"
        isCaptureFinalized = false
        pendingTasks.removeAll()
        completeFrameWaiter(nil)
        activeSessionID = UUID()
        let runID = activeSessionID
        lastGeminiFrameUptime = -1
        recorder = GeminiInputFrameRecorder()

        // Keep the VisionClaw glasses audio-session configuration. The strict HFP
        // route itself is selected and verified after DAT DeviceSession.started,
        // immediately before the camera stream starts.
        do {
            try audio.setupAudioSession()
            appendDiagnostic("AUDIO_SESSION configured playAndRecord/videoChat with Bluetooth HFP enabled")
        } catch {
            failStartup("眼镜音频会话初始化失败：\(error.localizedDescription)")
            return
        }

        do {
            appendDiagnostic("META_START begin DAT DeviceSession + HEVC High 720x1280 / 15 FPS")
            try await glasses.startStreaming()
            appendDiagnostic("META_START success video stream active; strict HFP route preflight passed")
        } catch {
            failStartup("Meta 眼镜视频流 / 严格 HFP 音频初始化失败：\(error.localizedDescription)")
            return
        }
        guard isStarting, activeSessionID == runID else { return }

        // Meta glasses frames are decoded locally. Keep only a 1-FPS JPEG cache;
        // never send a continuous image stream to Live. Function Calls fetch a fresh frame.
        gemini.onCameraFramePrepared = { [weak self] image, jpegData, timestamp, _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == runID else { return }
                let width = image.cgImage?.width ?? 0
                let height = image.cgImage?.height ?? 0
                self.latestFrameJPEG = jpegData
                self.latestFrameCapturedAt = timestamp
                self.latestFrameAgeText = "Meta 视频流最新缓存：\(Self.timeString(timestamp)) · \(width)×\(height)"
                if let waiter = self.frameWaiter, timestamp > waiter.after {
                    self.completeFrameWaiter(CameraFrameSnapshot(
                        jpeg: jpegData,
                        capturedAt: timestamp,
                        width: width,
                        height: height,
                        imageSource: "meta_video_frame"
                    ))
                }
            }
        }

        connectionStatus = "Meta 眼镜视频流已启动，正在连接 Gemini Live…"
        appendDiagnostic("GEMINI_LIVE connect begin mode=\(activeMode.rawValue)")
        let connected = await gemini.connect(mode: activeMode, tutorial: loadedTutorial)
        guard isStarting, activeSessionID == runID else { return }
        appendDiagnostic("GEMINI_LIVE connect result=\(connected)")
        guard connected else {
            let detail: String
            if case .error(let message) = gemini.connectionState {
                detail = message
            } else {
                detail = gemini.lastConnectionFailure ?? "没有收到 setupComplete"
            }
            failStartup(detail)
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recorder.startNewCapture(
                sessionFolderName: activeMode.sessionFolderName,
                archiveFileName: activeMode.archiveFileName
            ) { continuation.resume(returning: ()) }
        }
        guard isStarting, activeSessionID == runID else { return }

        isStarting = false
        isRunning = true
        connectionStatus = activeMode == .lego
            ? "Gemini Live 已连接 · LEGO 语音助手 · Meta 眼镜 HFP"
            : "Gemini Live 已连接 · 通用音视频助手 · Meta 眼镜 HFP"
        captureStatus = "DAT HEVC High 720×1280 / 15 FPS；本地解码预览约 5 FPS；Gemini 视觉图片缓存 1 FPS。"
        stepManager?.contextSent()
        syncStepState()

        do {
            try audio.startCapture()
            appendDiagnostic("AUDIO_CAPTURE started; mic=Meta Bluetooth HFP; speaker=Meta Bluetooth HFP; full_duplex=true")
            connectionStatus += " · 眼镜 HFP 双向音频已确认"
        } catch {
            failStartup("眼镜 HFP 麦克风 / 扬声器启动失败：\(error.localizedDescription)")
            return
        }

        appendDiagnostic("SESSION_READY mode=\(activeMode.rawValue) awaiting user voice and visual Function Calls")
        switch activeMode {
        case .lego:
            gemini.sendClientText("请用简体中文简短欢迎用户，告诉用户准备好后说‘开始’，然后只讲解第 1 步。不要一次性朗读全部步骤。")
        case .generalAV:
            gemini.sendClientText("请用简体中文简短欢迎用户，告诉用户可以直接和你交谈，也可以询问眼镜镜头里的人、物体、文字或场景。需要视觉信息时请调用 inspect_current_scene 工具。")
        }
    }

    func stop() {
        guard isStarting || isRunning else { return }
        appendDiagnostic("APP_STOP requested")
        isRunning = false
        isStarting = false
        connectionStatus = "未连接"
        completeFrameWaiter(nil)
        audio.stopCapture()
        glasses.stop()
        for (_, task) in pendingTasks { task.cancel() }
        pendingTasks.removeAll()
        stepManager?.cancelVerification(reason: "Session stopped")
        gemini.disconnect()

        let stoppingID = activeSessionID
        gemini.flushCameraFrameQueue { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == stoppingID else { return }
                self.gemini.onCameraFramePrepared = nil
                self.isCaptureFinalized = true
            }
        }

        if recordedFrameCount == 0 {
            captureStatus = "本次会话没有触发视觉 Function Call；未保存任何视频帧图片或模型请求"
        } else {
            captureStatus = "会话已停止：保存了 \(recordedFrameCount) 次视频帧视觉 Function Call 请求记录"
        }
        flashStatus = "会话已停止"
        appendDiagnostic("APP_STOP completed; diagnostic_file=\(diagnosticLogFileURL?.lastPathComponent ?? "unavailable")")
        latestFrameJPEG = nil
        latestFrameCapturedAt = nil
        latestGlassesFrame = nil
    }

    func exportCaptureZIP() {
        guard !isRunning, !isStarting, isCaptureFinalized,
              !isExporting, recordedFrameCount > 0 else { return }
        isExporting = true
        captureStatus = "正在打包视频流 CURRENT JPEG、Flash request.json 和模型结果…"
        recorder.export { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success(let archive):
                    self.zipURL = archive
                    self.captureStatus = "ZIP 已就绪：\(self.recordedFrameCount) 次视觉请求记录"
                case .failure(let error):
                    self.captureStatus = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Live function routing

    private func handleLiveToolCall(_ call: LiveFunctionCall) {
        switch activeMode {
        case .lego:
            guard call.name == "request_step_verification" else {
                sendToolError(call, message: "当前 LEGO Agent 不支持工具：\(call.name)")
                return
            }
            startFlashStepVerification(call)

        case .generalAV:
            guard call.name == "inspect_current_scene" else {
                sendToolError(call, message: "当前通用音视频助手不支持工具：\(call.name)")
                return
            }
            startGeneralVisualInspection(call)
        }
    }

    private func progressMessage(for call: LiveFunctionCall, fallback: String) -> String {
        let raw = (call.args["progress_message"] as? String ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return fallback }
        // Keep the spoken filler short and prevent malformed tool arguments from
        // creating a long or multi-line Live turn. The phrase itself is model-generated.
        return String(raw.prefix(48))
    }

    // MARK: - General audio/video assistant visual routing

    private func startGeneralVisualInspection(_ call: LiveFunctionCall) {
        let question = (call.args["question"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveQuestion = question.isEmpty
            ? userTranscript.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300).description
            : question
        let progressMessage = progressMessage(
            for: call,
            fallback: "我来仔细看一下眼镜镜头里的内容，请稍等。"
        )
        appendDiagnostic("VISION_INSPECTION begin call_id=\(call.id) source=meta_video_frame question=\(effectiveQuestion)")
        appendDiagnostic("LIVE_PROGRESS_MESSAGE generated=\(progressMessage)")

        flashRequestCount += 1
        flashStatus = "等待 Meta 视频流的最新画面…"
        flashResultText = ""
        flashLatencyMilliseconds = nil

        let sessionID = activeSessionID
        let requestedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            let overallStart = Date()

            guard let frame = await self.waitForFreshFrame(after: requestedAt),
                  self.activeSessionID == sessionID,
                  self.isRunning,
                  !Task.isCancelled else {
                guard self.activeSessionID == sessionID, self.isRunning, !Task.isCancelled else { return }
                self.finishGeneralVisualTool(
                    call: call,
                    question: effectiveQuestion,
                    frame: nil,
                    response: nil,
                    errorMessage: "没有及时获得新的 Meta 眼镜视频帧。请保持眼镜连接，并将目标放入画面后重试。",
                    latency: Int(Date().timeIntervalSince(overallStart) * 1000)
                )
                return
            }

            self.flashStatus = "Gemini Flash LOW 正在理解 \(frame.width)×\(frame.height) 视频帧…"
            self.appendDiagnostic("FLASH_REQUEST begin source=meta_video_frame dimensions=\(frame.width)x\(frame.height) jpeg_bytes=\(frame.jpeg.count) thinking=LOW")
            let recorderTarget = self.recorder
            let currentCapturedAtISO = Self.isoString(frame.capturedAt)
            let service = GeminiFlashVisionService()

            guard let apiKey = GeminiKeychain.load(), !apiKey.isEmpty else {
                self.finishGeneralVisualTool(
                    call: call,
                    question: effectiveQuestion,
                    frame: frame,
                    response: nil,
                    errorMessage: "Gemini API Key 不可用。",
                    latency: Int(Date().timeIntervalSince(overallStart) * 1000)
                )
                return
            }

            do {
                let response = try await service.analyze(
                    jpegData: frame.jpeg,
                    question: effectiveQuestion,
                    thinkingLevel: .low,
                    apiKey: apiKey,
                    onRequestBuilt: { requestJSON in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeSessionID == sessionID, self.isRunning else { return }
                            self.gemini.requestProgressSpeech(progressMessage)
                            self.appendDiagnostic("FLASH_REQUEST body_built bytes=\(requestJSON.count); request dispatch follows")
                        }
                        recorderTarget.recordGeneralVision(
                            callID: call.id,
                            currentJPEG: frame.jpeg,
                            requestJSON: requestJSON,
                            metadata: [
                                "transport": "HTTP POST generateContent",
                                "model": GeminiConfig.flashModel,
                                "thinking_level": "low",
                                "endpoint": "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiConfig.flashModel):generateContent",
                                "function_name": call.name,
                                "question": effectiveQuestion,
                                "progress_message": progressMessage,
                                "image_source": "meta_video_frame",
                                "current_image_captured_at": currentCapturedAtISO,
                                "current_image_width": frame.width,
                                "current_image_height": frame.height,
                                "camera_image_format": "JPEG",
                                "camera_jpeg_quality_requested": 0.9,
                                "target_image_used": false
                            ]
                        ) { count, error in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeSessionID == sessionID else { return }
                                self.recordedFrameCount = count
                                if let error {
                                    self.captureStatus = "视觉请求保存失败：\(error)"
                                    self.appendDiagnostic("IMAGE_SAVE failed error=\(error)")
                                } else {
                                    self.captureStatus = "已保存 \(count) 次：Meta 视频流 CURRENT JPEG + request.json + Flash 返回结果"
                                    self.appendDiagnostic("IMAGE_SAVE success index=\(count) current_bytes=\(frame.jpeg.count) request_json_bytes=\(requestJSON.count)")
                                }
                            }
                        }
                    }
                )

                guard self.activeSessionID == sessionID, self.isRunning, !Task.isCancelled else { return }
                self.appendDiagnostic("FLASH_RESPONSE success latency_ms=\(response.latencyMilliseconds) text=\(response.text)")
                self.finishGeneralVisualTool(
                    call: call,
                    question: effectiveQuestion,
                    frame: frame,
                    response: response,
                    errorMessage: nil,
                    latency: response.latencyMilliseconds
                )
            } catch {
                self.appendDiagnostic("FLASH_RESPONSE FAILED localized=\(error.localizedDescription) raw=\(String(describing: error))")
                guard self.activeSessionID == sessionID, self.isRunning, !Task.isCancelled else { return }
                self.finishGeneralVisualTool(
                    call: call,
                    question: effectiveQuestion,
                    frame: frame,
                    response: nil,
                    errorMessage: error.localizedDescription,
                    latency: Int(Date().timeIntervalSince(overallStart) * 1000)
                )
            }
        }
        pendingTasks[call.id] = task
    }

    private func finishGeneralVisualTool(call: LiveFunctionCall,
                                         question: String,
                                         frame: CameraFrameSnapshot?,
                                         response: FlashVisionResponse?,
                                         errorMessage: String?,
                                         latency: Int) {
        pendingTasks[call.id] = nil
        flashLatencyMilliseconds = latency

        let answer: String
        let toolPayload: [String: Any]
        if let response {
            answer = response.text
            flashStatus = "视觉理解完成 · Gemini Flash LOW · \(String(format: "%.2f", Double(response.latencyMilliseconds) / 1000.0)) s"
            flashResultText = response.text
            toolPayload = [
                "status": "ok",
                "question": question,
                "answer": response.text,
                "model": GeminiConfig.flashModel,
                "thinking_level": "low",
                "latency_ms": response.latencyMilliseconds,
                "image_source": frame?.imageSource ?? "unknown",
                "image_width": frame?.width ?? 0,
                "image_height": frame?.height ?? 0
            ]
        } else {
            answer = errorMessage ?? "视觉理解暂时失败，请再试一次。"
            flashStatus = "视觉理解失败 · Gemini Flash LOW"
            flashResultText = answer
            toolPayload = [
                "status": "error",
                "question": question,
                "answer": "我暂时无法可靠地分析当前画面。\(answer)",
                "error": answer,
                "model": GeminiConfig.flashModel,
                "thinking_level": "low",
                "latency_ms": latency,
                "image_source": frame?.imageSource ?? "unknown",
                "image_width": frame?.width ?? 0,
                "image_height": frame?.height ?? 0
            ]
        }

        if let frame {
            var normalizedResult: [String: Any] = [
                "mode": "general_audio_video_assistant",
                "question": question,
                "answer": response?.text ?? "",
                "status": response == nil ? "error" : "ok",
                "model": GeminiConfig.flashModel,
                "thinking_level": "low",
                "latency_ms": latency,
                "image_source": frame.imageSource,
                "image_width": frame.width,
                "image_height": frame.height,
                "function_response_to_live": toolPayload
            ]
            if let response {
                if let value = response.promptTokenCount { normalizedResult["prompt_tokens"] = value }
                if let value = response.candidateTokenCount { normalizedResult["candidate_tokens"] = value }
                if let value = response.thoughtsTokenCount { normalizedResult["thoughts_tokens"] = value }
                normalizedResult["http_status"] = response.httpStatusCode
            }
            if let errorMessage { normalizedResult["error"] = errorMessage }

            var responseMetadata: [String: Any] = [
                "flash_model": GeminiConfig.flashModel,
                "flash_thinking_level": "low",
                "flash_latency_ms": latency,
                "flash_question": question,
                "image_source": frame.imageSource,
                "image_width": frame.width,
                "image_height": frame.height,
                "flash_response_received": response != nil,
                "flash_candidate_text_available": !(response?.text.isEmpty ?? true)
            ]
            if let response {
                responseMetadata["flash_http_status"] = response.httpStatusCode
                if let value = response.promptTokenCount { responseMetadata["flash_prompt_tokens"] = value }
                if let value = response.candidateTokenCount { responseMetadata["flash_candidate_tokens"] = value }
                if let value = response.thoughtsTokenCount { responseMetadata["flash_thoughts_tokens"] = value }
            }
            if let errorMessage { responseMetadata["flash_error"] = errorMessage }

            let sessionID = activeSessionID
            recorder.recordFlashResponse(
                callID: call.id,
                responseBody: response?.rawResponseBody,
                candidateText: response?.text ?? "",
                normalizedResult: normalizedResult,
                metadata: responseMetadata
            ) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.activeSessionID == sessionID else { return }
                    if let error {
                        self.captureStatus = "Flash 已完成，但响应日志保存失败：\(error)"
                    } else {
                        self.captureStatus = "已保存 \(self.recordedFrameCount) 次通用视觉请求及 Flash 返回结果"
                    }
                }
            }
        }

        // The original Live tool call remains pending until Flash has produced text.
        // Live then speaks the returned answer through its existing audio output.
        appendDiagnostic("LIVE_FUNCTION_RESPONSE send call_id=\(call.id) status=\(response == nil ? "error" : "ok")")
        gemini.sendToolResponse(
            id: call.id,
            name: call.name,
            response: toolPayload,
            scheduling: "WHEN_IDLE"
        )
    }

    private func startFlashStepVerification(_ call: LiveFunctionCall) {
        guard let manager = stepManager,
              let requestedStep = Self.intValue(call.args["step"]) else {
            sendToolError(call, message: "缺少 step 参数，或 LEGO 状态机尚未初始化")
            return
        }
        if let rejection = manager.beginVerification(step: requestedStep, callID: call.id) {
            gemini.sendToolResponse(id: call.id, name: call.name, response: rejection, scheduling: "WHEN_IDLE")
            syncStepState()
            return
        }
        guard let step = manager.currentStepData else {
            manager.cancelVerification(reason: "No current step data")
            sendToolError(call, message: "当前 LEGO 步骤不存在")
            syncStepState()
            return
        }
        let progressMessage = progressMessage(
            for: call,
            fallback: "我正在对照这一步的标准图片检查，请稍等。"
        )

        flashRequestCount += 1
        flashStatus = "正在等待 Step \(step.step) 的新摄像头画面…"
        flashResultText = ""
        flashLatencyMilliseconds = nil
        syncStepState()

        let sessionID = activeSessionID
        let requestedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            let overallStart = Date()
            guard let frame = await self.waitForFreshFrame(after: requestedAt),
                  self.activeSessionID == sessionID,
                  self.isRunning,
                  !Task.isCancelled else {
                guard self.activeSessionID == sessionID, self.isRunning, !Task.isCancelled else { return }
                let inspection = self.uncertainInspection(
                    step: step.step,
                    reason: "没有及时获得新的摄像头画面。请保持积木完整入镜、移开双手后重试。",
                    latency: Int(Date().timeIntervalSince(overallStart) * 1000)
                )
                self.finishFlashTool(call: call, inspection: inspection, frame: nil)
                return
            }

            self.flashStatus = "Gemini Flash LOW 正在验收 Step \(step.step)：CURRENT + TARGET…"
            let recorderTarget = self.recorder
            let currentCapturedAtISO = Self.isoString(frame.capturedAt)
            do {
                let inspection = try await LEGOVisualVerifier.verify(
                    step: step,
                    currentJPEG: frame.jpeg,
                    onRequestBuilt: { requestJSON, targetJPEG in
                        // The complete Flash request is now built and is about to be
                        // dispatched. Start Live's dynamic progress speech here so
                        // Flash is already entering its HTTP request path.
                        Task { @MainActor [weak self] in
                            guard let self, self.activeSessionID == sessionID, self.isRunning else { return }
                            self.gemini.requestProgressSpeech(progressMessage)
                            self.stepManager?.log("Live progress: \(progressMessage)")
                        }
                        recorderTarget.recordVerification(
                            step: step.step,
                            mode: "Live_Flash_LOW",
                            callID: call.id,
                            currentJPEG: frame.jpeg,
                            targetJPEG: targetJPEG,
                            requestJSON: requestJSON,
                            metadata: [
                                "transport": "HTTP POST generateContent",
                                "model": GeminiConfig.flashModel,
                                "thinking_level": "low",
                                "endpoint": "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiConfig.flashModel):generateContent",
                                "function_name": call.name,
                                "progress_message": progressMessage,
                                "step_title": step.title,
                                "current_image_captured_at": currentCapturedAtISO,
                                "current_image_width": frame.width,
                                "current_image_height": frame.height,
                                "camera_image_format": "JPEG",
                                "camera_jpeg_quality_requested": 0.9
                            ]
                        ) { count, error in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeSessionID == sessionID else { return }
                                self.recordedFrameCount = count
                                self.captureStatus = error.map { "Function Call 请求保存失败：\($0)" }
                                    ?? "已保存 \(count) 次视觉请求（CURRENT + TARGET + request.json）"
                            }
                        }
                    }
                )
                guard self.activeSessionID == sessionID, self.isRunning, !Task.isCancelled else { return }
                self.finishFlashTool(call: call, inspection: inspection, frame: frame)
            } catch {
                guard self.activeSessionID == sessionID, self.isRunning, !Task.isCancelled else { return }
                let latency = Int(Date().timeIntervalSince(overallStart) * 1000)
                let inspection = self.uncertainInspection(
                    step: step.step,
                    reason: "Flash 验收请求失败：\(error.localizedDescription)",
                    latency: latency
                )
                self.finishFlashTool(call: call, inspection: inspection, frame: frame)
            }
        }
        pendingTasks[call.id] = task
        // The progress phrase is echoed only after the Flash request body has
        // been built and the HTTP request is about to be dispatched (see above).
        syncStepState()
    }

    private func finishFlashTool(call: LiveFunctionCall,
                                 inspection: LEGOVisualInspection,
                                 frame: CameraFrameSnapshot?) {
        pendingTasks[call.id] = nil
        guard let manager = stepManager else { return }
        let result = manager.processFlashInspection(call: call, inspection: inspection)
        flashLatencyMilliseconds = inspection.latencyMilliseconds
        flashStatus = "Step \(inspection.verdict.uppercased()) · Gemini Flash LOW · \(String(format: "%.2f", Double(inspection.latencyMilliseconds) / 1000.0)) s"
        flashResultText = "判断：\(inspection.verdict)\n证据：\(inspection.evidence)\n修正：\(inspection.correction)\n检查项：\(inspection.checks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))"
        if let frame {
            flashResultText += "\nCURRENT：\(frame.width)×\(frame.height)，\(Self.isoString(frame.capturedAt))"

            // Persist the actual Flash HTTP response and both raw + normalized
            // model outputs alongside the request/images for this Function Call.
            var normalizedResult: [String: Any] = [
                "step": Self.intValue(call.args["step"]) ?? currentStepNumber,
                "verdict": inspection.verdict,
                "evidence": inspection.evidence,
                "correction": inspection.correction,
                "checks": inspection.checks,
                "model": inspection.model,
                "latency_ms": inspection.latencyMilliseconds,
                "state_machine_response": result.response
            ]
            if let value = inspection.promptTokenCount { normalizedResult["prompt_tokens"] = value }
            if let value = inspection.candidateTokenCount { normalizedResult["candidate_tokens"] = value }
            if let value = inspection.thoughtsTokenCount { normalizedResult["thoughts_tokens"] = value }
            if let value = inspection.httpStatusCode { normalizedResult["http_status"] = value }
            if let value = inspection.errorMessage { normalizedResult["error"] = value }

            var responseMetadata: [String: Any] = [
                "flash_model": inspection.model,
                "flash_latency_ms": inspection.latencyMilliseconds,
                "flash_verdict": inspection.verdict,
                "flash_evidence": inspection.evidence,
                "flash_correction": inspection.correction,
                "flash_checks": inspection.checks,
                "flash_response_received": inspection.rawResponseBody != nil,
                "flash_candidate_text_available": !inspection.rawJSON.isEmpty
            ]
            if let value = inspection.httpStatusCode { responseMetadata["flash_http_status"] = value }
            if let value = inspection.promptTokenCount { responseMetadata["flash_prompt_tokens"] = value }
            if let value = inspection.candidateTokenCount { responseMetadata["flash_candidate_tokens"] = value }
            if let value = inspection.thoughtsTokenCount { responseMetadata["flash_thoughts_tokens"] = value }
            if let value = inspection.errorMessage { responseMetadata["flash_error"] = value }

            let sessionID = activeSessionID
            recorder.recordFlashResponse(
                callID: call.id,
                responseBody: inspection.rawResponseBody,
                candidateText: inspection.rawJSON,
                normalizedResult: normalizedResult,
                metadata: responseMetadata
            ) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.activeSessionID == sessionID else { return }
                    if let error {
                        self.captureStatus = "Flash 已返回，但响应日志保存失败：\(error)"
                    } else {
                        self.captureStatus = "已保存 \(self.recordedFrameCount) 次请求及 Flash 原始响应 / 验收结果"
                    }
                }
            }
        }

        // The original Live tool call stays pending until the Flash result is
        // validated by the local LEGO state machine, then receives this response.
        gemini.sendToolResponse(
            id: call.id,
            name: call.name,
            response: result.response,
            scheduling: "WHEN_IDLE"
        )
        syncStepState()
    }

    private func sendToolError(_ call: LiveFunctionCall, message: String) {
        gemini.sendToolResponse(
            id: call.id,
            name: call.name,
            response: [
                "status": "error",
                "accepted": false,
                "message": message,
                "current_step": currentStepNumber
            ],
            scheduling: "WHEN_IDLE"
        )
    }

    // MARK: - Fresh local camera frame

    private func waitForFreshFrame(after date: Date, timeoutSeconds: Double = 5.0) async -> CameraFrameSnapshot? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                frameWaiter = FrameWaiter(id: id, after: date, continuation: continuation)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard let self, self.frameWaiter?.id == id else { return }
                    self.completeFrameWaiter(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.frameWaiter?.id == id else { return }
                self.completeFrameWaiter(nil)
            }
        }
    }

    private func completeFrameWaiter(_ result: CameraFrameSnapshot?) {
        guard let waiter = frameWaiter else { return }
        frameWaiter = nil
        waiter.continuation.resume(returning: result)
    }

    private func uncertainInspection(step: Int, reason: String, latency: Int) -> LEGOVisualInspection {
        LEGOVisualInspection(
            verdict: "uncertain",
            evidence: reason,
            correction: "请把当前积木完整放入画面，避免遮挡或模糊，然后重新说‘搭好了’。",
            checks: [
                "image_quality": "unknown",
                "part_identity": "unknown",
                "part_count": "unknown",
                "placement": "unknown",
                "orientation": "unknown"
            ],
            model: GeminiConfig.flashModel,
            rawJSON: "",
            rawResponseBody: nil,
            httpStatusCode: nil,
            errorMessage: reason,
            latencyMilliseconds: latency,
            promptTokenCount: nil,
            candidateTokenCount: nil,
            thoughtsTokenCount: nil
        )
    }

    private func syncStepState() {
        guard let manager = stepManager else { return }
        currentStepNumber = manager.currentStep
        totalSteps = manager.tutorial.totalSteps
        currentStepTitle = manager.currentTitle
        stepPhaseText = manager.phase.rawValue
        lastStepVerdict = manager.lastVerdict
        stepEventLog = manager.eventLog
        if let step = manager.currentStepData,
           let data = try? LEGOTutorialRepository.imageData(relativePath: step.afterImage) {
            targetPreviewImage = UIImage(data: data)
        } else {
            targetPreviewImage = nil
        }
    }

    private func failStartup(_ message: String) {
        stop()
        errorMessage = message
    }

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
