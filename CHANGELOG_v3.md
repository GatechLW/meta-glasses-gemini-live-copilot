# v3 — Live-generated progress message handoff

- Added required `progress_message` argument to visual Function Calls. Gemini Live generates this sentence dynamically in the same tool call as the step number.
- In Live + Flash mode, iPhone starts the fresh-frame/Flash LOW pipeline first. Immediately after the Flash request body is built and is about to be dispatched, iPhone sends a separate `clientContent` turn asking Live to speak the exact generated `progress_message`.
- The original `request_step_verification` Function Call remains pending during progress speech and Flash inference. The only `toolResponse` for that call is sent after the actual Flash result has been validated by the iPhone step state machine.
- In Live multimodal mode, `get_step_verification_context` also carries a generated `progress_message`; iPhone echoes it to Live while preparing CURRENT + TARGET.
- `report_step_verdict` remains a blocking, fast local state-machine operation.
- Request logging now includes the exact generated progress message in `metadata.json`.
- Bumped Xcode marketing version to 1.3 and build number to 3.

The handoff follows Google's documented asynchronous Live API pattern: after receiving a non-blocking tool call, the client starts the background work and sends a text turn prompting the model to speak a waiting sentence; the actual Function Response is returned when the work is complete.
