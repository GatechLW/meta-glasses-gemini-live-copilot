# Meta Glasses LEGO + General A/V Copilot V2.0

This project migrates the iPhone V8 dual-mode Gemini Live + Function Calling + Flash workflow to Ray-Ban Meta Gen 2 glasses. It uses the Bluetooth HFP route-selection order from the supplied historical VisionClaw DAT 0.9.0 diagnostics project.

## Modes

- **General A/V Assistant**: Gemini Live handles full-duplex voice. Ordinary questions are answered directly. Visual questions trigger `inspect_current_scene`, which obtains the latest decoded Meta glasses video frame and sends a CURRENT JPEG to Gemini Flash LOW. The text result returns to Live as the Function Response, and Live speaks the answer.
- **LEGO Assistant**: Reuses the iPhone V8 eight-step tutorial, local state machine, acceptance criteria, and TARGET AFTER references. Live teaches and triggers `request_step_verification`; the app obtains the latest glasses video frame and sends CURRENT + TARGET + criteria to Gemini Flash LOW. The local state machine validates the result before advancing.

## Video-only capture

Standalone photo capture has been removed. The app does not call `camera.photo` or `capturePhoto(resolution:quality:)`.

- DAT SDK: Exact 1.0.1
- Codec: HEVC `hvc1`
- Resolution: High, 720 × 1280
- Requested DAT FPS: 15
- Local visual cache: 1 FPS
- JPEG quality: 0.9
- Live receives no continuous image stream.
- A fresh frame is sent to Flash only when Live calls a visual Function Call.

## Strict glasses audio and full duplex

The app requires both audio directions to use Meta glasses Bluetooth HFP. It never falls back to the iPhone microphone or speaker.

The route sequence mirrors the supplied VisionClaw implementation:

1. Configure `.playAndRecord` + `.videoChat` + Bluetooth HFP.
2. Wait for DAT `DeviceSession.started`.
3. Find the `.bluetoothHFP` input and call `setPreferredInput`.
4. Wait 1.5 seconds for iOS route switching.
5. Verify both `currentRoute.inputs` and `currentRoute.outputs` are `.bluetoothHFP`.
6. Only then start the DAT camera stream and Gemini audio pipeline.

The microphone stays active while Gemini speaks. The client does not gate audio on `isModelSpeaking`. Gemini Live server VAD and `START_OF_ACTIVITY_INTERRUPTS` handle barge-in; the app stops queued playback when it receives `serverContent.interrupted`.

If HFP is unavailable or either route direction changes away from HFP, startup/session fails instead of silently using iPhone audio. The glasses HFP path is expected to use the glasses' own voice processing; the iPhone V8 VoiceProcessingIO configuration is not copied onto this Bluetooth glasses route.

## Build

1. Open `iPhoneGeminiVideoLab/MetaGlassesGeneralAV.xcodeproj` in Xcode.
2. Select your Apple Development Team and update the Bundle Identifier if needed.
3. Confirm `meta-wearables-dat-ios` is pinned to Exact Version 1.0.1.
4. Install on a physical iPhone.
5. Save your Gemini API key in the app.
6. Complete Meta AI registration / authorization, enable Developer Mode, and grant Camera permission.
7. Choose General A/V or LEGO mode and tap Start.

## Test

- Confirm the UI shows both Mic and Speaker on Meta Bluetooth HFP and `STRICT HFP OK`.
- Ask a question while Gemini is speaking to test barge-in.
- Ask a visual question to test Live → `inspect_current_scene` → latest video frame → Flash LOW → Function Response → Live speech.
- In LEGO mode, say “开始”, assemble each step, and say “搭好了” to test `request_step_verification`.

## Validation boundary

The source migration, resource checks, Swift parser checks, and static package checks are performed. This environment does not have the full Xcode/iOS SDK or access to your glasses, so a real iPhone build, HFP runtime test, and Gemini end-to-end test must still be completed on your Mac and device.
