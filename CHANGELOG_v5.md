# v5 — Single Live + Flash mode and Flash response logging

- Removed the Live-only multimodal visual verification mode from the UI, tool schema, Live system instruction, service connection configuration, and iPhone routing.
- The app now has one fixed architecture: Gemini Live voice + `request_step_verification` Function Call + Gemini Flash LOW + iPhone step state machine.
- Added raw Flash HTTP response persistence (`flash_response.json`).
- Added extracted candidate text (`flash_candidate.txt`) and normalized state-machine output (`flash_result.json`).
- Failed Flash requests now also create `flash_error.json` when a request record exists.
- Updated per-event `metadata.json` and `manifest.json` with Flash response status, latency, token usage, verdict, checks, and file names.
- Preserved v4 CRC32 self-test and ZIP writer fix.
- Preserved Live-generated dynamic progress messages, on-demand image logging, CURRENT/TARGET images, and the 8-step tutorial.
