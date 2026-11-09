# v6 Change Log

## Added: General Audio/Video Assistant mode

- Added a front-end mode selector with two modes:
  1. LEGO assembly mode — existing v5 behavior retained.
  2. General audio/video assistant — Live voice agent plus on-demand Flash visual perception.
- General mode does not load LEGO tutorial JSON, reference images, step state machine, or LEGO-only prompts.
- Added Live tool `inspect_current_scene(question, progress_message)`.
- General visual Function Calls capture a fresh CURRENT JPEG, send it with the user's visual question to Gemini Flash, and return Flash's concise text as the original Function Response to Live.
- Flash uses LOW thinking level in both modes.
- Live-generated dynamic progress speech, NON_BLOCKING tool calls, WHEN_IDLE final tool responses, and current half-duplex microphone uplink policy are retained.
- Added separate general-mode logging folder and ZIP name. General events save `current.jpg`, `request.json`, raw Flash response, candidate text, normalized result, and metadata; no target image is created.
- Updated app display name and camera/microphone permission descriptions.
- Updated project version to 1.5 (build 5).

## Preserved

- LEGO 8-step tutorial and local step state machine.
- 720p / 1080p camera selection, 1 FPS in-memory JPEG sampling, JPEG quality 0.9.
- Function-call-only image/request logging and Flash response logging.
- CRC32-correct ZIP export.
