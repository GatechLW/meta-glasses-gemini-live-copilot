# MetaGlassesGeneralAV 2.2 — Camera lifecycle fix

## Root cause indicated by the 2026-11-08 diagnostic log

The standalone high-quality photo completed successfully:
- Photo reached `.started`.
- Transfer progress reached 95.91%.
- `photoDataPublisher` delivered a decodable 3024 × 4032 image.
- Photo reached `.stopped`.

The failure occurred only when the app called `start()` on the same old Stream after standalone Photo. The old stream transitioned `waitingForDevice → starting → stopping` and emitted `MWDATCamera.StreamError` code 4 (`Critical error, the stream should end`).

## Changes

- After Photo reaches `.stopped`, clear Photo listeners and call `camera.stop()` to stop/detach the old Camera capability.
- Keep the parent `DeviceSession` alive.
- Call `session.addCamera(config:)` to create a fresh Camera capability and a new Stream.
- Re-register video-frame, stream-state, and stream-error listeners on the new Stream.
- Start the new Stream and wait for `.streaming`.
- Apply the same fresh-Camera recovery path if Photo capture itself fails.
- Never retry `start()` on the old Stream after standalone Photo.
- Fix false timeout diagnostics: timeout events are now logged only if the continuation is still pending and the timeout actually wins. This removes misleading timeout lines that appeared 20–40 seconds after successful operations.
- Keep Meta DAT SDK pinned to exact version 1.0.1.
- Keep HEVC High 720 × 1280 / requested 15 FPS, Gemini image sampling, Live audio/video, Function Calling, Flash LOW, and existing export logic.

## Official lifecycle reference

Meta's current iOS camera-capture guidance says to stop the active Stream before standalone Photo, wait for Photo `.started`, capture, wait for delivery, stop Photo, clear Photo listeners, then stop Camera. The camera-streaming guidance states that `camera.stop()` detaches the Camera from the session so a later `session.addCamera()` can register a new Camera. This build follows that lifecycle for restoring the preview.

## Validation

- All Swift files passed `swiftc -frontend -parse`.
- `Info.plist` and `project.pbxproj` passed `plutil -lint`.
- ZIP integrity passed.
- Xcode build, SPM resolution, and physical Ray-Ban Meta Gen 2 testing still need to be performed on the user's Mac/iPhone. This environment cannot confirm runtime behavior on the glasses.
