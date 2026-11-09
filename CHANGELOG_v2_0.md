## Build 6 hotfix (2026-11-09)

- Fixed Swift control-flow error in `AudioManager.handleRouteChange()` by adding the required `return` at the end of the outer `guard ... else` block after reporting HFP route loss.
- No audio routing behavior changed: if the Meta HFP route is lost, the callback is reported and the handler exits.

# V2.0 Change Log — Meta Glasses Dual-Mode Full Duplex

## Based on three source projects

- iPhone V8: dual-mode General A/V + LEGO, full-duplex Live/Flash orchestration, LEGO state machine and verifier.
- Meta DAT 1.0.1 V1.3: glasses HEVC stream, VideoToolbox decoder, local 1-FPS image cache, Live/Flash pipeline, diagnostics and export.
- VisionClaw DAT 0.9.0 diagnostics: known-working Bluetooth HFP selection order and glasses-mode continuous microphone uplink.

## Removed

- `GlassesCaptureSource` selector.
- Standalone `camera.photo` capture lifecycle.
- `capturePhoto(resolution: .full, quality: .high)`.
- Photo stop/restart logic, transfer-progress listeners and original-photo preview/export UI.
- All UI copy and model instructions that describe a photo capture branch.

## Added / changed

- Front-end segmented selector for General A/V and LEGO modes.
- Startup now uses `selectedMode`, loads LEGO tutorial/state machine only in LEGO mode, and calls `gemini.connect(mode:tutorial:)` with the selected mode.
- General visual tool uses the latest fresh decoded Meta HEVC video frame only.
- LEGO verification uses the latest fresh decoded Meta HEVC video frame + matching TARGET AFTER + written criteria.
- Strict glasses audio route:
  - `AVAudioSession.playAndRecord`
  - `AVAudioSession.Mode.videoChat`
  - Bluetooth HFP enabled
  - After DAT DeviceSession.started, select `.bluetoothHFP` with `setPreferredInput`.
  - Wait 1.5 seconds, then verify both microphone input and speaker output are Bluetooth HFP before starting the DAT video stream.
  - If HFP is unavailable or either direction leaves HFP, fail/stop instead of falling back to iPhone audio.
- Full-duplex glasses microphone uplink:
  - Removed the `!gemini.isModelSpeaking` gate.
  - Continuous glasses HFP microphone PCM upload while Live speaks.
  - Existing server VAD + `START_OF_ACTIVITY_INTERRUPTS` and local `onInterrupted -> stopPlayback()` are retained.
- Diagnostic log now records strict HFP preflight, current Mic/Speaker route, route loss and full-duplex startup.
- Function Call recorder no longer supports or emits standalone original-photo files.

## Preserved

- Meta DAT SDK Exact 1.0.1.
- HEVC High 720×1280 / requested 15 FPS.
- VideoToolbox decoding and local preview.
- 1 FPS JPEG cache / JPEG quality 0.9.
- Gemini 3.8 Live and Gemini 3.8 Flash LOW.
- Function Call request/response logging and ZIP export.
- Eight-step LEGO resources, state machine, TARGET AFTER references and Flash verifier.
- Existing Meta registration, permissions and URL callback flow.

## Audio design note

The supplied VisionClaw project configures `.playAndRecord` + `.videoChat` + Bluetooth and selects the HFP input after DAT DeviceSession startup, before `stream.start()`. Its glasses mode sends microphone PCM while the model speaks; only its iPhone mode applies the model-speaking gate. V2.0 ports that glasses-mode behavior and strengthens it by requiring both HFP input and HFP output.

The iPhone V8 `setVoiceProcessingEnabled(true)` path is not blindly copied to the glasses HFP route. The glasses' own HFP/voice-processing path is used, with strict route verification. Real acoustic echo performance still requires testing on the actual Ray-Ban glasses and iPhone.

## Validation

Static source checks and Swift parser checks are included in `verify_package.py`. This handoff environment cannot perform a real Xcode/iOS build or connect to Meta glasses, so HFP routing, true hardware full-duplex behavior, and Gemini API integration remain to be validated on device.
