import Foundation
import UIKit
import MWDATCore
import MWDATCamera

private enum MetaDATManagerError: LocalizedError {
    case timeout(String)
    case sessionStopped
    case streamStopped
    case noCamera
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .timeout(let stage): return "等待 Meta 眼镜\(stage)超时。请确认眼镜已佩戴、蓝牙已连接，并保持手机与眼镜靠近。"
        case .sessionStopped: return "Meta DAT DeviceSession 意外停止。"
        case .streamStopped: return "Meta 视频流在启动过程中停止。"
        case .noCamera: return "Meta DAT 无法创建 Camera capability。"
        case .permissionDenied: return "Meta AI 未授予眼镜相机权限。请在 Meta AI App 中检查授权。"
        }
    }
}

/// Thread-safe one-shot bridge from DAT's callback publishers to Swift concurrency.
private final class DATContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    @discardableResult
    func succeed(_ value: Value) -> Bool { resolve(.success(value)) }

    @discardableResult
    func fail(_ error: Error) -> Bool { resolve(.failure(error)) }
}

@MainActor
final class MetaGlassesDATManager {
    var onFrame: ((UIImage, Date) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnosticLog: ((String) -> Void)?
    /// Must confirm the glasses HFP microphone AND speaker before the DAT stream starts.
    var beforeStreamStart: (() async throws -> Void)?

    private var decodedFrameCount = 0
    private var lastVideoFrameLogAt = Date.distantPast

    private let wearables = Wearables.shared
    private let deviceSelector: AutoDeviceSelector
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var stream: MWDATCamera.Stream?

    private let decoder = GlassesHEVCFrameProcessor()
    private let sessionTokens = ListenerTokenBag()
    private let streamTokens = ListenerTokenBag()
    private let operationTokens = ListenerTokenBag()


    init() {
        deviceSelector = AutoDeviceSelector(wearables: wearables)
        decoder.onImage = { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.decodedFrameCount += 1
                let now = Date()
                if self.decodedFrameCount == 1 ||
                    now.timeIntervalSince(self.lastVideoFrameLogAt) >= 15 {
                    self.lastVideoFrameLogAt = now
                    let width = image.cgImage?.width ?? 0
                    let height = image.cgImage?.height ?? 0
                    self.diagnostic("VIDEO_FRAME decoded_count=\(self.decodedFrameCount) size=\(width)x\(height)")
                }
                self.onFrame?(image, now)
            }
        }
    }

    private func diagnostic(_ message: String) {
        let line = "[DAT] " + message
        NSLog("%@", line)
        onDiagnosticLog?(line)
    }

    /// Preserve NSError domain/code/userInfo so Meta SDK failures can be distinguished
    /// from our own timeout / state-machine errors in a copied diagnostic log.
    private func diagnosticError(_ event: String, _ error: Error) {
        let nsError = error as NSError
        let userInfo = nsError.userInfo.keys.sorted().map { key in
            "\(key)=\(String(describing: nsError.userInfo[key] ?? "nil"))"
        }.joined(separator: " | ")
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            " underlying={domain=\($0.domain), code=\($0.code), description=\($0.localizedDescription)}"
        } ?? ""
        diagnostic("\(event) type=\(String(reflecting: type(of: error))) domain=\(nsError.domain) code=\(nsError.code) localized=\(nsError.localizedDescription) userInfo={\(userInfo)}\(underlying)")
    }

    func registerWithMetaAI() async throws {
        diagnostic("REGISTRATION begin")
        onStatus?("正在启动 Meta AI 注册 / 授权流程…")
        try await wearables.startRegistration()
        diagnostic("REGISTRATION returned_to_app_or_handoff_started")
        onStatus?("Meta AI 注册流程已返回。若刚才切换到 Meta AI，请完成授权后返回本 App。")
    }

    func handleMetaURL(_ url: URL) async throws {
        diagnostic("APP_URL callback_received host=\(url.host ?? "nil") query=\(url.query ?? "nil")")
        _ = try await wearables.handleUrl(url)
        diagnostic("APP_URL handled_by_DAT")
        onStatus?("已处理 Meta Wearables 回调。")
    }

    func startStreaming() async throws {
        diagnostic("SESSION startStreaming called existingSession=\(deviceSession != nil) existingStream=\(stream != nil)")

        if let existingSession = deviceSession {
            if let existingStream = stream {
                try await startStreamAndWait(existingStream)
            } else {
                try await attachAndStartCamera(
                    in: existingSession,
                    reason: "reuse_existing_device_session"
                )
            }
            return
        }

        onStatus?("正在查找已连接的 Meta 眼镜…")
        diagnostic("SESSION createSession begin")
        let session = try wearables.createSession(deviceSelector: deviceSelector)
        diagnostic("SESSION createSession success")
        deviceSession = session

        session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.diagnostic("SESSION state=\(state)")
                self?.onStatus?("Meta DeviceSession：\(state)")
            }
        }.store(in: sessionTokens)

        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                self?.diagnosticError("SESSION errorPublisher", error)
                self?.onError?(error.localizedDescription)
            }
        }.store(in: sessionTokens)

        diagnostic("SESSION start() requested")
        try session.start()
        try await waitForSessionStarted(session)
        diagnostic("SESSION started confirmed")

        onStatus?("检查 Meta 眼镜相机权限…")
        let permissionStatus = try await wearables.checkPermissionStatus(.camera)
        diagnostic("CAMERA_PERMISSION status=\(permissionStatus)")
        if permissionStatus != .granted {
            let requestedPermission = try await wearables.requestPermission(.camera)
            diagnostic("CAMERA_PERMISSION request_result=\(requestedPermission)")
            guard requestedPermission == .granted else {
                throw MetaDATManagerError.permissionDenied
            }
        }

        try await attachAndStartCamera(in: session, reason: "initial_start")
    }

    private func makeStreamConfiguration() -> StreamConfiguration {
        // High = 720 × 1280; 15 FPS is the selected capture rate.
        // hvc1 keeps the glasses' compressed HEVC stream; the app decodes it locally.
        StreamConfiguration(
            videoCodec: VideoCodec.hvc1,
            resolution: StreamingResolution.high,
            frameRate: 15
        )
    }

    /// Adds the camera capability and starts its HEVC video stream.
    private func attachAndStartCamera(
        in session: DeviceSession,
        reason: String
    ) async throws {
        diagnostic("CAMERA_ADD begin reason=\(reason) codec=hvc1 resolution=high frameRate=15")
        streamTokens.clear()

        guard let newCamera = try session.addCamera(config: makeStreamConfiguration()) else {
            diagnostic("CAMERA_ADD failed reason=\(reason) result=nil")
            throw MetaDATManagerError.noCamera
        }

        camera = newCamera
        let newStream = newCamera.stream
        stream = newStream
        diagnostic("CAMERA_ADD success reason=\(reason) new_camera_and_stream_created")

        newCamera.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.diagnostic("CAMERA statePublisher state=\(state) reason=\(reason)")
            }
        }.store(in: streamTokens)

        newStream.videoFramePublisher.listen { [weak self] frame in
            self?.decoder.append(sampleBuffer: frame.sampleBuffer, renderEveryFrame: false)
        }.store(in: streamTokens)

        newStream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.diagnostic("STREAM statePublisher state=\(state) reason=\(reason)")
                self?.onStatus?("Meta 视频流：\(state)")
            }
        }.store(in: streamTokens)

        newStream.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                self?.diagnosticError("STREAM errorPublisher reason=\(reason)", error)
                self?.onError?(error.localizedDescription)
            }
        }.store(in: streamTokens)

        try await startStreamAndWait(newStream)
        diagnostic("CAMERA_ADD stream_active reason=\(reason)")
        onStatus?("Meta 眼镜视频流已启动 · HEVC High 720×1280 · 请求 15 FPS")
    }

    func stop() {
        diagnostic("SESSION stop() requested")
        onStatus?("正在停止 Meta 眼镜会话…")
        operationTokens.clear()
        streamTokens.clear()
        sessionTokens.clear()
        camera?.stop()
        deviceSession?.stop()
        decoder.reset()
        stream = nil
        camera = nil
        deviceSession = nil
        diagnostic("SESSION stop() completed")
        onStatus?("Meta 眼镜已断开")
    }

    // MARK: - DAT lifecycle waits

    private func waitForSessionStarted(_ session: DeviceSession) async throws {
        diagnostic("WAIT session .started begin")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = DATContinuationGate(continuation)
            session.statePublisher.listen { state in
                Task { @MainActor [weak self] in self?.diagnostic("WAIT session state=\(state)") }
                if state == .started { gate.succeed(()) }
                if state == .stopped { gate.fail(MetaDATManagerError.sessionStopped) }
            }.store(in: operationTokens)
            session.errorPublisher.listen { error in
                Task { @MainActor [weak self] in self?.diagnostic("WAIT session ERROR=\(error.localizedDescription)") }
                gate.fail(error)
            }.store(in: operationTokens)
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                if gate.fail(MetaDATManagerError.timeout("DeviceSession 启动")) {
                    Task { @MainActor [weak self] in self?.diagnostic("WAIT session TIMEOUT after=40s") }
                }
            }
        }
        operationTokens.clear()
        diagnostic("WAIT session .started completed")
    }

    private func startStreamAndWait(_ stream: MWDATCamera.Stream) async throws {
        diagnostic("WAIT stream .streaming begin")

        // VisionClaw's proven sequence: DeviceSession.started -> select Bluetooth HFP
        // -> allow iOS to switch the route -> start the DAT camera stream.
        // The caller enforces strict mode: failure aborts startup; no iPhone fallback.
        if let beforeStreamStart {
            diagnostic("AUDIO_ROUTE strict_glasses_HFP_preflight begin")
            try await beforeStreamStart()
            diagnostic("AUDIO_ROUTE strict_glasses_HFP_preflight confirmed")
        } else {
            throw MetaDATManagerError.timeout("眼镜 HFP 音频路由预检回调")
        }

        operationTokens.clear()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = DATContinuationGate(continuation)
            stream.statePublisher.listen { state in
                Task { @MainActor [weak self] in self?.diagnostic("WAIT stream start state=\(state)") }
                if state == .streaming { gate.succeed(()) }
            }.store(in: operationTokens)
            stream.errorPublisher.listen { error in
                Task { @MainActor [weak self] in self?.diagnosticError("WAIT stream start errorPublisher", error) }
                gate.fail(error)
            }.store(in: operationTokens)
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                if gate.fail(MetaDATManagerError.timeout("视频流启动")) {
                    Task { @MainActor [weak self] in self?.diagnostic("WAIT stream start TIMEOUT after=40s") }
                }
            }
            self.diagnostic("WAIT stream start() requested")
            stream.start()
        }
        operationTokens.clear()
        diagnostic("WAIT stream .streaming completed")
    }

}
