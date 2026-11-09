import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SessionViewModel()
    @State private var apiKeyDraft = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modePanel
                    cameraPanel
                    if viewModel.selectedMode == .lego {
                        stepPanel
                    } else {
                        generalAssistantPanel
                    }
                    architecturePanel
                    connectionPanel
                    diagnosticPanel
                    flashDiagnosticsPanel
                    exportPanel
                    transcriptPanel
                }
                .padding(16)
            }
            .navigationTitle(viewModel.selectedMode == .lego ? "Meta Glasses LEGO Copilot" : "Meta Glasses A/V Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scenePhase) { _, phase in
                // Meta registration / camera-permission flows temporarily switch to
                // the Meta AI app while startup is in progress. Do not cancel startup
                // during that handoff; stop only an already-running assistant.
                if phase != .active && viewModel.isRunning { viewModel.stop() }
            }
            .onOpenURL { url in
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else {
                    return
                }
                viewModel.handleMetaURL(url)
            }
        }
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作模式").font(.headline)
            Picker("工作模式", selection: $viewModel.selectedMode) {
                ForEach(AssistantMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning || viewModel.isStarting)

            Text(viewModel.selectedMode == .lego
                 ? "LEGO 搭建助手：Live 负责全双工语音交互和工具决策；本地状态机提供当前 Step、验收规则及 TARGET AFTER；Flash LOW 检查最新眼镜视频帧。"
                 : "通用音视频助手：Live 负责全双工语音交互；普通问题直接回答，需要视觉信息时调用工具获取最新眼镜视频帧，再由 Flash LOW 理解。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Meta 眼镜实时画面").font(.headline)
                Spacer()
                Text("HEVC · High · 15 FPS")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)
                if let image = viewModel.latestGlassesFrame {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 34))
                        Text("连接 Meta Ray-Ban Gen 2 后显示眼镜画面")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(20)
                }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack {
                Text("实际解码：\(viewModel.actualFrameDimensions)")
                Spacer()
                Text("Gemini 取样：1 FPS")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(viewModel.latestFrameAgeText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(viewModel.glassesStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var generalAssistantPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("通用音视频助手", systemImage: "waveform.and.mic")
                .font(.headline)

            Text("直接通过眼镜与 Gemini Live 语音交流。普通知识问题由 Live 直接回答；当问题需要看眼镜画面时，Live 调用 inspect_current_scene。")
                .font(.subheadline)

            Text("视觉 Function Call 发生时，App 从持续运行的 HEVC 视频流中获取最新解码帧，生成 JPEG 交给 Gemini Flash LOW。Flash 的文字结果作为 Function Response 返回 Live，再由 Live 生成语音回答。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.flashResultText.isEmpty {
                Divider()
                Text("最近一次视觉理解结果")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.flashResultText)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var stepPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("LEGO 当前步骤").font(.headline)
                Spacer()
                Text(viewModel.isCompleted ? "全部完成" : "STEP \(viewModel.currentStepNumber) / \(viewModel.totalSteps)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(viewModel.isCompleted ? .green : .blue)
            }

            ProgressView(
                value: Double(min(viewModel.currentStepNumber - 1, viewModel.totalSteps)),
                total: Double(viewModel.totalSteps)
            )
            .tint(.blue)

            Text(viewModel.currentStepTitle)
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.blue)
                Text(viewModel.stepPhaseText)
                    .font(.subheadline)
            }

            Text(viewModel.lastStepVerdict)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let target = viewModel.targetPreviewImage {
                Divider()
                Text("当前步骤目标完成图（TARGET AFTER）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(uiImage: target)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !viewModel.stepEventLog.isEmpty {
                Divider()
                Text("状态机事件").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(viewModel.stepEventLog.suffix(5).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var architecturePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("当前工作流", systemImage: "arrow.triangle.branch")
                .font(.headline)

            if viewModel.selectedMode == .lego {
                Text("Gemini Live Voice Agent → request_step_verification → 最新眼镜视频帧 + Step Context → Gemini Flash LOW → Function Response → Live Audio")
                    .font(.subheadline.weight(.semibold))
                Text("Live 负责语音理解、教学和 Function Call；iPhone 本地状态机维护 8 个 Step，准备验收文字和 TARGET AFTER；Flash LOW 对照最新 CURRENT 视频帧进行质量检查。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Gemini Live Voice Agent → inspect_current_scene → 最新眼镜视频帧 → Gemini Flash LOW → Function Response → Live Audio")
                    .font(.subheadline.weight(.semibold))
                Text("普通问题由 Live 直接回答；视觉问题触发 Function Call，App 从 Meta 视频流取得最新 CURRENT JPEG，Flash LOW 返回文字结果，再交给 Live 语音回答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("视频：Meta DAT 1.0.1 · HEVC High 720×1280 · 请求 15 FPS · 本地解码预览约 5 FPS · 视觉缓存 1 FPS · JPEG 0.9。Live 不接收持续视频帧。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("音频严格使用 Meta 眼镜 Bluetooth HFP：眼镜麦克风采集 + 眼镜扬声器播放。启动前同时验证 HFP 输入和输出；路由丢失时停止会话，不回退 iPhone。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接与 Gemini 会话").font(.headline)

            HStack(spacing: 8) {
                Image(systemName: viewModel.hasAPIKey ? "checkmark.shield.fill" : "key.fill")
                    .foregroundStyle(viewModel.hasAPIKey ? .green : .orange)
                Text(viewModel.hasAPIKey ? "Gemini API Key 已保存在 iOS Keychain" : "需要 Gemini API Key")
                    .font(.footnote)
            }

            HStack(spacing: 8) {
                SecureField("粘贴 Gemini API Key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    if viewModel.saveAPIKey(apiKeyDraft) { apiKeyDraft = "" }
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          viewModel.isRunning || viewModel.isStarting)
            }

            Button {
                viewModel.registerMetaGlasses()
            } label: {
                Label("Meta AI 注册 / 授权", systemImage: "eyeglasses")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRunning || viewModel.isStarting)

            Text("首次使用此 App 时，先完成 Meta AI 授权。需要在 Meta AI App 中开启眼镜 Developer Mode，并允许相机访问。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("DAT SDK：1.0.1（Exact）")
                Text("Video：hvc1 · High 720×1280 · 15 FPS")
                Text("Live：models/gemini-3.8-live")
                Text("Flash：gemini-3.8-flash · LOW")
                Text("Audio route：\(viewModel.audioRouteStatus)")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)


            Text(viewModel.connectionStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Button {
                if viewModel.isRunning || viewModel.isStarting {
                    viewModel.stop()
                } else {
                    Task { await viewModel.start() }
                }
            } label: {
                Label(
                    viewModel.isRunning
                        ? "停止\(viewModel.selectedMode == .lego ? " LEGO 助手" : "通用助手")"
                        : (viewModel.isStarting
                            ? "正在启动…"
                            : (viewModel.selectedMode == .lego ? "Start LEGO Assistant" : "Start General A/V Assistant")),
                    systemImage: viewModel.isRunning ? "stop.circle.fill" : "play.circle.fill"
                )
                .frame(maxWidth: .infinity)
                .padding(7)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRunning ? .red : .blue)
            .disabled(!viewModel.hasAPIKey && !viewModel.isRunning && !viewModel.isStarting)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var diagnosticPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("DAT / 眼镜音频路由诊断日志", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.diagnosticLogCount) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("重点记录 DAT DeviceSession / HEVC Stream 状态、Bluetooth HFP 输入与输出路由、麦克风 PCM 采集、Gemini interrupted 事件及错误详情。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(viewModel.diagnosticLogPreview.isEmpty ? "启动助手后，这里会显示最近的诊断事件。" : viewModel.diagnosticLogPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(maxHeight: 220)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 10) {
                Button {
                    viewModel.copyDiagnosticLogs()
                } label: {
                    Label("复制全部日志", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)

                if let logURL = viewModel.diagnosticLogURL {
                    ShareLink(item: logURL) {
                        Label("导出 .log", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("建议：启动前确认 Meta 眼镜已连接并支持通话音频。若严格 HFP 检查失败，复制全部日志或导出 .log 文件发给我。")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var flashDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gemini Flash 视觉诊断").font(.headline)
                Spacer()
                Text("\(viewModel.flashRequestCount) 次调用")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(viewModel.flashStatus, systemImage: "eye")
                    .font(.subheadline)
                Spacer()
                if viewModel.flashLatencyMilliseconds != nil {
                    Text(viewModel.flashLatencyLabel)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            HStack {
                fact(label: "Thinking", value: viewModel.flashThinkingLevelLabel)
                fact(label: "Flash latency", value: viewModel.flashLatencyLabel)
            }

            Text(viewModel.latestFrameAgeText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.flashResultText.isEmpty {
                Divider()
                Text("最近一次 Flash 视觉理解结果")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.flashResultText)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Text("每次视觉 Function Call 都会保存从 Meta HEVC 视频流抽取的 CURRENT JPEG、实际 request.json、Flash 原始响应和标准化结果。普通 1 FPS 帧只保留在内存，不会持续写盘。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func fact(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("视频帧视觉请求保存与导出").font(.headline)
            Text("已保存 \(viewModel.recordedFrameCount) 次视觉 Function Call")
                .font(.subheadline.monospacedDigit())
            Text(viewModel.captureStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(viewModel.selectedMode == .lego
                 ? "每次 LEGO 验收保存 CURRENT JPEG、TARGET AFTER JPEG、Flash 实际 request.json、原始响应和状态机验收结果。"
                 : "每次通用视觉请求保存 CURRENT JPEG、Flash 实际 request.json、原始响应和 Live Function Response。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                viewModel.exportCaptureZIP()
            } label: {
                Label(viewModel.isExporting ? "正在生成 ZIP…" : "导出视觉请求与 Flash 结果 ZIP", systemImage: "archivebox")
            }
            .disabled(!viewModel.isCaptureFinalized || viewModel.isExporting ||
                      viewModel.recordedFrameCount == 0 || viewModel.isRunning)

            if let zip = viewModel.zipURL {
                ShareLink(item: zip) {
                    Label("分享 ZIP 到 Files / AirDrop", systemImage: "square.and.arrow.up")
                }
            }

            Text("请先停止助手，再导出。普通视频帧不落盘；只有 Function Call 使用的 CURRENT / TARGET 图片、实际 request.json（不含 API Key）及模型返回结果会保存。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("语音转写记录").font(.headline)
            Text("用户").font(.caption).foregroundStyle(.secondary)
            Text(viewModel.userTranscript.isEmpty ? "—" : viewModel.userTranscript)
                .textSelection(.enabled)
            Divider()
            Text("Gemini Live").font(.caption).foregroundStyle(.secondary)
            Text(viewModel.aiTranscript.isEmpty ? "—" : viewModel.aiTranscript)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
