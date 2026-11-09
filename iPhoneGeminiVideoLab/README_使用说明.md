# Meta Glasses LEGO + General A/V Copilot V2.0

本工程把已验证的 iPhone V8 双模式 Live + Function Calling + Flash 工作流迁移到 Ray-Ban Meta Gen 2 眼镜，并采用 VisionClaw 历史工程中已使用的 Bluetooth HFP 路由顺序。

## 1. 两个前端模式

### 模式 A：通用音视频助手

- Gemini Live 是全双工语音 Agent。
- 普通问题由 Live 直接语音回答。
- 需要视觉信息时，Live 调用 `inspect_current_scene(question, progress_message)`。
- App 从 Meta 眼镜持续运行的 HEVC 视频流中获取最新解码帧，生成 CURRENT JPEG。
- Gemini Flash `gemini-3.8-flash` / LOW 负责视觉理解。
- Flash 文字结果作为 Function Response 返回 Live，由 Live 生成最终语音回答。

### 模式 B：LEGO 音视频助手

- 使用 iPhone V8 中的 8 步 LEGO 教程、Step 状态机、验收规则和 TARGET AFTER 图片。
- Gemini Live 负责语音教学、理解用户输入和触发 `request_step_verification(step, progress_message)`。
- App 获取最新 Meta 眼镜视频帧作为 CURRENT。
- App 根据当前 Step 加载 TARGET AFTER 和中文验收标准。
- Gemini Flash LOW 进行视觉验收。
- 本地状态机验证结果；只有明确正确才进入下一步。
- Flash 结果通过原始 Function Response 返回 Live，由 Live 继续语音指导。

两个模式共享同一套 Meta DAT 视频采集、HEVC 解码、音频、Gemini Live、Flash、记录和导出组件。

## 2. 视频采集：只保留 Video Stream

本版本已彻底移除独立拍照分支，不再调用 `camera.photo` 或 `capturePhoto(resolution:quality:)`。

| 项目 | 配置 |
|---|---|
| Meta DAT SDK | Exact 1.0.1 |
| 摄像头 | Ray-Ban Meta Gen 2 |
| Codec | HEVC `hvc1` |
| Resolution | High · 720 × 1280 |
| DAT 请求 FPS | 15 |
| 本地解码预览 | 约 5 FPS（受设备和传输影响） |
| Gemini 图片缓存 | 1 FPS |
| JPEG Quality | 0.9 |
| Live 图像输入 | 不持续发送 |
| Flash 图像输入 | 仅视觉 Function Call 获取最新 CURRENT JPEG |

流程：

```text
Meta Glasses HEVC stream
        ↓
Meta DAT SDK 1.0.1
        ↓
iPhone VideoToolbox decode
        ↓
local preview + 1 FPS JPEG cache
        ↓
Live visual Function Call
        ↓
fresh CURRENT JPEG
        ↓
Gemini Flash LOW
        ↓
Function Response
        ↓
Gemini Live voice response
```

视频流在 Flash 视觉分析期间保持运行，不会为了拍照暂停或重启。

## 3. 严格使用眼镜音频 + 全双工

本版本只允许 Meta 眼镜 Bluetooth HFP 音频，不允许自动回退到 iPhone 麦克风或扬声器。

### 路由顺序（沿用 VisionClaw 历史实现）

1. 配置 `AVAudioSession`：`.playAndRecord` + `.videoChat` + `[.defaultToSpeaker, .allowBluetooth]`。
2. 启动 Meta DAT `DeviceSession` 并等待 `.started`。
3. 在 DAT 视频流启动前，从 `availableInputs` 找到名称包含 `Meta` / `Ray-Ban` / `RB Meta` 的 `.bluetoothHFP` 设备。
4. 调用 `setPreferredInput(hfp)`。
5. 等待 iOS 完成路由切换（保留 VisionClaw 的 1.5 秒等待，再轮询确认）。
6. 同时确认 `currentRoute.inputs` 和 `currentRoute.outputs` 都是名称匹配 Meta / Ray-Ban 的 `.bluetoothHFP`，不接受其他蓝牙耳机。
7. 只有双向 HFP 确认成功，才启动 DAT 视频流、Gemini Live 和音频采集。

如果没有 HFP 输入，或输出仍然是 iPhone speaker，启动直接失败并显示当前路由，不会回退。

### 全双工上行

- 麦克风音频持续从 Meta HFP 输入采集并转换为 16 kHz mono Int16 PCM。
- 按约 100 ms 分块上传 Gemini Live。
- 不再使用 `!isModelSpeaking` 门控。
- Live 已配置服务端 VAD 和 `START_OF_ACTIVITY_INTERRUPTS`。
- 用户说话时，Live 可打断当前语音回复；App 收到 `serverContent.interrupted` 后立即清空本地播放队列。
- Gemini 输出 24 kHz mono PCM，经 AVAudioEngine 播放到 Meta HFP 输出。

眼镜麦克风和扬声器位于同一副眼镜，依赖眼镜 HFP/设备端的语音处理能力。此版本不把 iPhone V8 针对手机内置扬声器设计的 VoiceProcessingIO 配置直接套到眼镜 HFP 链路。

### 运行时严格校验

- 启动前：必须同时验证 HFP input + HFP output。
- 运行中：监听 `AVAudioSession.routeChangeNotification`。
- 如果任一方向离开 Bluetooth HFP，自动停止会话并提示错误。
- UI 和诊断日志显示当前实际 Mic / Speaker 设备。

## 4. Function Call 记录与导出

普通 1 FPS 帧只保留在内存。只有 Live 触发视觉 Function Call 时才保存输入素材。

### General A/V event

```text
Check_0001_General_Flash_LOW/
  gemini_flash_input.jpg
  request.json
  metadata.json
  flash_response.json
  flash_candidate.txt
  flash_result.json
```

### LEGO event

```text
Check_0001_Step_01_Live_Flash_LOW/
  current.jpg
  target.jpg
  request.json
  metadata.json
  flash_response.json
  flash_candidate.txt
  flash_result.json
```

ZIP 中不包含 API Key。General 和 LEGO 模式使用不同的会话目录与导出文件名。

## 5. 安装和测试

1. 解压 ZIP。
2. 在 Mac 上打开 `iPhoneGeminiVideoLab/MetaGlassesGeneralAV.xcodeproj`。
3. 在 Target → Signing & Capabilities 选择自己的 Apple Development Team，并按需修改 Bundle Identifier。
4. 确认 Swift Package `meta-wearables-dat-ios` 使用 Exact Version 1.0.1。
5. 使用真实 iPhone 安装运行。
6. 输入 Gemini API Key。
7. 先完成 Meta AI 注册 / 授权，确认眼镜 Developer Mode 和 Camera permission 已开启。
8. 选择 General A/V 或 LEGO 模式。
9. 点击 Start。

### 建议测试顺序

**测试 1：音频路由**

启动后检查界面 `Audio route`。麦克风和扬声器必须都显示 Meta Ray-Ban / Bluetooth HFP，并显示 `STRICT HFP OK`。如果不是，App 应拒绝启动，不应使用 iPhone 音频。

**测试 2：全双工打断**

1. 让 Gemini 连续说话。
2. 用户在 Gemini 说话期间直接提出新问题。
3. 观察 Gemini 是否停止旧回答并回应新问题。
4. 保持安静，检查 Gemini 是否会因为自己的语音回声而反复打断自己。

**测试 3：General A/V**

询问眼镜前方物体、文字或场景。确认 Live 触发 `inspect_current_scene`，Flash 收到最新视频帧，结果返回 Live 语音回答。

**测试 4：LEGO**

选择 LEGO 模式，说“开始”，按步骤搭建；完成后说“搭好了，帮我检查”。确认当前 Step、TARGET AFTER、CURRENT 视频帧和验收标准一起进入 Flash 请求，状态机根据 Flash 结果决定是否进入下一步。

## 6. 诊断信息

App 会记录：

- DAT DeviceSession / Stream 状态和错误
- HFP 输入、输出路由及 route change
- 音频采集启动、PCM 分块和 Live interrupted
- Live Function Call、Flash request / response、延迟和验收结果

如果 HFP 路由不能建立，请导出完整 `.log`。如果出现语音自我打断，也请提供日志、iPhone 型号、iOS 版本以及眼镜连接状态。

## 7. 验证边界

本工程完成了源代码迁移、资源检查、Swift 语法解析和静态完整性检查。当前环境没有完整 Xcode / iOS SDK，也无法连接你的 Meta 眼镜，因此不能声称已完成真实 iPhone 编译、HFP 真机路由测试或 Gemini 端到端测试。请在 Mac Xcode 中完成 Build & Run，并按上述顺序验证。
