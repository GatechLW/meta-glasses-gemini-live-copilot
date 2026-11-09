import AVFoundation
import Foundation

enum GlassesAudioRouteError: LocalizedError {
    case bluetoothHFPInputUnavailable(available: String)
    case bluetoothHFPRouteNotActive(inputs: String, outputs: String)
    case routeLost(inputs: String, outputs: String)

    var errorDescription: String? {
        switch self {
        case .bluetoothHFPInputUnavailable(let available):
            return "未发现 Meta 眼镜 Bluetooth HFP 麦克风。当前可用输入：\(available)。请确认 Ray-Ban Meta 已连接，并在 iOS 蓝牙设置中允许通话音频。"
        case .bluetoothHFPRouteNotActive(let inputs, let outputs):
            return "无法确认眼镜双向 HFP 音频路由。当前麦克风：\(inputs)；当前扬声器：\(outputs)。为遵守严格眼镜音频模式，App 不会回退到 iPhone。"
        case .routeLost(let inputs, let outputs):
            return "Meta 眼镜 HFP 音频路由已丢失。当前麦克风：\(inputs)；当前扬声器：\(outputs)。会话已停止，请重新连接眼镜后重试。"
        }
    }
}

final class AudioManager {
    var onAudioCaptured: ((Data) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onRouteChanged: ((String) -> Void)?
    var onRouteInvalidated: ((String) -> Void)?

    private var routeObserver: NSObjectProtocol?
    private let playbackLock = NSLock()
    private var pendingPlaybackBuffers = 0
    private var serverTurnEnded = false
    private var drainNotified = false
    private var playbackGeneration = 0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isCapturing = false
    private var isPlayerNodeAttached = false
    private var glassesHFPRouteConfirmed = false
    private var routeLossReported = false

    private let outputFormat: AVAudioFormat

    // Accumulate resampled PCM into ~100ms chunks before sending.
    private let sendQueue = DispatchQueue(label: "audio.accumulator")
    private var accumulatedData = Data()
    private let minSendBytes = 3200 // 100ms at 16kHz mono Int16.

    var isUsingGlassesHFP: Bool {
        Self.routeHasMetaGlassesHFPInBothDirections(AVAudioSession.sharedInstance().currentRoute)
    }

    var currentRouteSummary: String {
        Self.routeSummary(AVAudioSession.sharedInstance().currentRoute)
    }

    init() {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: GeminiConfig.outputAudioSampleRate,
            channels: GeminiConfig.audioChannels,
            interleaved: true
        )!

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    /// Mirrors the known-working VisionClaw glasses audio session:
    /// playAndRecord + videoChat + Bluetooth HFP. The route is not considered
    /// ready until both input AND output are verified as Bluetooth HFP.
    func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setPreferredSampleRate(GeminiConfig.inputAudioSampleRate)
        try session.setPreferredIOBufferDuration(0.064)
        try session.setActive(true)

        glassesHFPRouteConfirmed = false
        routeLossReported = false
        publishCurrentAudioRoute()

        NSLog(
            "[Audio] Session configured for Meta glasses: category=playAndRecord mode=videoChat options=defaultToSpeaker+allowBluetooth sampleRate=%.0f",
            session.sampleRate
        )
    }

    /// Called by MetaGlassesDATManager after DeviceSession.started and BEFORE
    /// stream.start(), matching the working VisionClaw route-selection order.
    /// Strict policy: do not continue unless both mic and speaker are on HFP.
    func requireGlassesHFPRoute() async throws {
        let session = AVAudioSession.sharedInstance()

        guard let hfpInput = session.availableInputs?.first(where: Self.isMetaGlassesHFPPort) else {
            glassesHFPRouteConfirmed = false
            let available = (session.availableInputs ?? [])
                .map { "\($0.portName)(\($0.portType.rawValue))" }
                .joined(separator: ", ")
            throw GlassesAudioRouteError.bluetoothHFPInputUnavailable(
                available: available.isEmpty ? "none" : available
            )
        }

        if session.preferredInput?.uid != hfpInput.uid {
            try session.setPreferredInput(hfpInput)
            NSLog("[Audio] Requested Meta glasses HFP input: %@", hfpInput.portName)
        } else {
            NSLog("[Audio] Meta glasses HFP is already the preferred input: %@", hfpInput.portName)
        }

        // VisionClaw's proven route handoff waits 1.5 seconds after selecting
        // HFP and before starting the DAT video stream. Keep that ordering.
        if !Self.routeHasMetaGlassesHFPInBothDirections(session.currentRoute) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            let route = session.currentRoute
            if Self.routeHasMetaGlassesHFPInBothDirections(route) {
                glassesHFPRouteConfirmed = true
                routeLossReported = false
                publishCurrentAudioRoute()
                NSLog("[Audio] STRICT_GLASSes_HFP_CONFIRMED %@", Self.routeSummary(route))
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        glassesHFPRouteConfirmed = false
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        NSLog("[Audio] STRICT_GLASSes_HFP_FAILED input=%@ output=%@", inputs, outputs)
        throw GlassesAudioRouteError.bluetoothHFPRouteNotActive(
            inputs: inputs.isEmpty ? "none" : inputs,
            outputs: outputs.isEmpty ? "none" : outputs
        )
    }

    func startCapture() throws {
        guard !isCapturing else { return }

        let session = AVAudioSession.sharedInstance()
        guard glassesHFPRouteConfirmed,
              Self.routeHasMetaGlassesHFPInBothDirections(session.currentRoute) else {
            let route = session.currentRoute
            let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            throw GlassesAudioRouteError.bluetoothHFPRouteNotActive(
                inputs: inputs.isEmpty ? "none" : inputs,
                outputs: outputs.isEmpty ? "none" : outputs
            )
        }

        if !isPlayerNodeAttached {
            audioEngine.attach(playerNode)
            isPlayerNodeAttached = true
        }

        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: GeminiConfig.outputAudioSampleRate,
            channels: GeminiConfig.audioChannels,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        let inputNode = audioEngine.inputNode
        let inputNativeFormat = inputNode.outputFormat(forBus: 0)

        NSLog(
            "[Audio] Glasses HFP native input format: %@ sampleRate=%.0f channels=%d",
            inputNativeFormat.commonFormat == .pcmFormatFloat32 ? "Float32" :
                inputNativeFormat.commonFormat == .pcmFormatInt16 ? "Int16" : "Other",
            inputNativeFormat.sampleRate,
            inputNativeFormat.channelCount
        )

        let needsResample = inputNativeFormat.sampleRate != GeminiConfig.inputAudioSampleRate
            || inputNativeFormat.channelCount != GeminiConfig.audioChannels
        NSLog("[Audio] HFP input needs resample: %@", needsResample ? "YES" : "NO")

        sendQueue.async { self.accumulatedData = Data() }

        var converter: AVAudioConverter?
        if needsResample {
            let resampleFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: GeminiConfig.inputAudioSampleRate,
                channels: GeminiConfig.audioChannels,
                interleaved: false
            )!
            converter = AVAudioConverter(from: inputNativeFormat, to: resampleFormat)
        }

        var tapCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            tapCount += 1
            let pcmData: Data
            let rms: Float

            if let converter {
                let resampleFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: GeminiConfig.inputAudioSampleRate,
                    channels: GeminiConfig.audioChannels,
                    interleaved: false
                )!
                guard let resampled = self.convertBuffer(
                    buffer,
                    using: converter,
                    targetFormat: resampleFormat
                ) else {
                    if tapCount <= 3 {
                        NSLog("[Audio] HFP resample failed for tap #%d", tapCount)
                    }
                    return
                }
                pcmData = self.float32BufferToInt16Data(resampled)
                rms = self.computeRMS(resampled)
            } else {
                pcmData = self.float32BufferToInt16Data(buffer)
                rms = self.computeRMS(buffer)
            }

            self.sendQueue.async {
                self.accumulatedData.append(pcmData)
                if self.accumulatedData.count >= self.minSendBytes {
                    let chunk = self.accumulatedData
                    self.accumulatedData = Data()
                    if tapCount <= 3 {
                        NSLog("[Audio] Sending glasses-HFP PCM chunk: %d bytes (~%dms), rms=%.4f",
                              chunk.count, chunk.count / 32, rms)
                    }
                    self.onAudioCaptured?(chunk)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            playerNode.stop()
            if isPlayerNodeAttached {
                audioEngine.detach(playerNode)
                isPlayerNodeAttached = false
            }
            throw error
        }

        // Recheck after the audio engine starts; do not silently accept an
        // iPhone route if iOS changed the output while activating the engine.
        guard Self.routeHasMetaGlassesHFPInBothDirections(session.currentRoute) else {
            inputNode.removeTap(onBus: 0)
            playerNode.stop()
            audioEngine.stop()
            if isPlayerNodeAttached {
                audioEngine.detach(playerNode)
                isPlayerNodeAttached = false
            }
            let route = session.currentRoute
            let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            throw GlassesAudioRouteError.bluetoothHFPRouteNotActive(
                inputs: inputs.isEmpty ? "none" : inputs,
                outputs: outputs.isEmpty ? "none" : outputs
            )
        }

        playerNode.play()
        isCapturing = true
        publishCurrentAudioRoute()
        NSLog("[Audio] Capture started with STRICT Meta HFP input + output. %@", Self.routeSummary(session.currentRoute))
    }

    func playAudio(data: Data) {
        guard isCapturing, !data.isEmpty else { return }

        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: GeminiConfig.outputAudioSampleRate,
            channels: GeminiConfig.audioChannels,
            interleaved: false
        )!

        let frameCount = UInt32(data.count) / (GeminiConfig.audioBitsPerSample / 8 * GeminiConfig.audioChannels)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frameCount) {
                floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        playbackLock.lock()
        pendingPlaybackBuffers += 1
        serverTurnEnded = false
        drainNotified = false
        let generation = playbackGeneration
        playbackLock.unlock()

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.playbackLock.lock()
            if self.playbackGeneration == generation {
                self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
            }
            let shouldNotify = self.playbackGeneration == generation
                && self.pendingPlaybackBuffers == 0
                && self.serverTurnEnded
                && !self.drainNotified
            if shouldNotify { self.drainNotified = true }
            self.playbackLock.unlock()
            if shouldNotify {
                DispatchQueue.main.async { [weak self] in self?.onPlaybackDrained?() }
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Called after server turnComplete; actual drain also waits for all queued audio.
    func markServerTurnComplete() {
        playbackLock.lock()
        serverTurnEnded = true
        let shouldNotify = pendingPlaybackBuffers == 0 && !drainNotified
        if shouldNotify { drainNotified = true }
        playbackLock.unlock()
        if shouldNotify {
            DispatchQueue.main.async { [weak self] in self?.onPlaybackDrained?() }
        }
    }

    func stopPlayback() {
        playbackLock.lock()
        playbackGeneration += 1
        pendingPlaybackBuffers = 0
        serverTurnEnded = false
        drainNotified = false
        playbackLock.unlock()
        playerNode.stop()
        if isCapturing { playerNode.play() }
    }

    func stopCapture() {
        guard isCapturing else {
            glassesHFPRouteConfirmed = false
            return
        }
        isCapturing = false
        audioEngine.inputNode.removeTap(onBus: 0)
        playbackLock.lock()
        playbackGeneration += 1
        pendingPlaybackBuffers = 0
        serverTurnEnded = false
        drainNotified = false
        playbackLock.unlock()
        playerNode.stop()
        audioEngine.stop()
        if isPlayerNodeAttached {
            audioEngine.detach(playerNode)
            isPlayerNodeAttached = false
        }
        glassesHFPRouteConfirmed = false

        sendQueue.async {
            if !self.accumulatedData.isEmpty {
                let chunk = self.accumulatedData
                self.accumulatedData = Data()
                self.onAudioCaptured?(chunk)
            }
        }
    }

    // MARK: - Strict route validation

    private func handleRouteChange() {
        publishCurrentAudioRoute()
        guard isCapturing else { return }

        let route = AVAudioSession.sharedInstance().currentRoute
        guard Self.routeHasMetaGlassesHFPInBothDirections(route) else {
            glassesHFPRouteConfirmed = false
            guard !routeLossReported else { return }
            routeLossReported = true

            let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let error = GlassesAudioRouteError.routeLost(
                inputs: inputs.isEmpty ? "none" : inputs,
                outputs: outputs.isEmpty ? "none" : outputs
            )
            NSLog("[Audio] STRICT HFP route lost: %@", error.localizedDescription)
            onRouteInvalidated?(error.localizedDescription)
            return
        }
    }

    private func publishCurrentAudioRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let label = Self.routeSummary(route)
            + (Self.routeHasMetaGlassesHFPInBothDirections(route) ? " · STRICT HFP OK" : " · STRICT HFP NOT READY")
        onRouteChanged?(label)
        NSLog("[Audio] Current route: %@", label)
    }

    private static func isMetaGlassesHFPPort(_ port: AVAudioSessionPortDescription) -> Bool {
        guard port.portType == .bluetoothHFP else { return false }
        let name = port.portName.lowercased()
        return name.contains("meta")
            || name.contains("ray-ban")
            || name.contains("rayban")
            || name.contains("rb meta")
    }

    private static func routeHasMetaGlassesHFPInBothDirections(_ route: AVAudioSessionRouteDescription) -> Bool {
        let hasMetaHFPInput = route.inputs.contains(where: isMetaGlassesHFPPort)
        let hasMetaHFPOutput = route.outputs.contains(where: isMetaGlassesHFPPort)
        return hasMetaHFPInput && hasMetaHFPOutput
    }

    private static func routeSummary(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        return "Mic: \(inputs.isEmpty ? "—" : inputs) · Speaker: \(outputs.isEmpty ? "—" : outputs)"
    }

    // MARK: - PCM conversion

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return 0 }
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let sample = floatData[0][i]
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(frameCount))
    }

    private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
        var int16Array = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1.0, min(1.0, floatData[0][i]))
            int16Array[i] = Int16(sample * Float(Int16.max))
        }
        return int16Array.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil { return nil }
        return outputBuffer
    }
}
