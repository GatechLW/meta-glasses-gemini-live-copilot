# v4 — ZIP CRC32 export fix

- Fixed the custom ZIP32 writer's CRC-32 implementation.
- The previous implementation shifted the CRC accumulator only once per input byte; standard ZIP CRC-32 requires eight bit-steps per byte.
- Added the canonical `CRC32("123456789") == 0xCBF43926` self-test. ZIP export now refuses to proceed if this test fails.
- Preserved v3 behavior: Live-generated `progress_message`, asynchronous visual Function Call, Flash LOW mode, both LEGO verification modes, on-demand Function Call-only image/request logging, and all eight LEGO tutorial steps.

