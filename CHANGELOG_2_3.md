# MetaGlassesGeneralAV 2.3 — Original Photo + Gemini Input Export

## Purpose

For every visual Function Call that uses Meta's standalone Full / High photo path, preserve both:
1. `meta_original_photo.<ext>` — the exact byte buffer delivered by Meta DAT `photoDataPublisher`; no UIImage re-encoding.
2. `gemini_flash_input.jpg` — the exact JPEG Data passed to `GeminiFlashVisionService.analyze()` and embedded in the actual HTTP request.

## Added

- Save the original Meta DAT photo bytes under an explicit `meta_original_photo.<ext>` filename.
- Save the exact Gemini Flash input as `gemini_flash_input.jpg`.
- Save the exact HTTP request JSON as `request.json`; it contains the inline Base64 image payload but no API key (the API key is sent in the HTTP header).
- Extract the inline image back from `request.json` during recording and compare it byte-for-byte with `gemini_flash_input.jpg`.
- Record SHA-256 hashes for the original photo, Gemini input JPEG, and request inline image.
- Record image file names, byte sizes, MIME type, dimensions, and a boolean `request_inline_image_matches_saved_file`.
- Continue saving Flash raw response, candidate text, normalized result, and metadata in the same Function Call folder.
- Add an in-app side-by-side preview of the latest Meta original photo and Gemini Flash input.
- Clarify the export panel and ZIP action in Chinese.
- Keep ordinary video frames memory-only; no continuous frame dumping.
- Preserve the v2.2 Camera lifecycle fix and Meta DAT SDK Exact 1.0.1.

## Export layout

For a photo-backed Function Call:

```text
Check_0001_General_Flash_LOW/
  meta_original_photo.jpg
  gemini_flash_input.jpg
  request.json
  metadata.json
  flash_response.json
  flash_candidate.txt
  flash_result.json
```

For a video-frame Function Call, no `meta_original_photo` file is created; `gemini_flash_input.jpg` is still saved.

## How to use

1. Select **原生高质量照片** as the capture source.
2. Start the assistant and ask a visual question.
3. The latest original and Gemini input images appear side by side in **视觉图片保存与导出**.
4. Stop the assistant.
5. Tap **导出图片与 Flash 请求 ZIP**, then share the ZIP to Files or AirDrop.

## Validation

- All Swift files passed `swiftc -frontend -parse`.
- `Info.plist` and `project.pbxproj` passed `plutil -lint`.
- Source-level check verifies the image in `request.json` is decoded and compared byte-for-byte to the saved Gemini input image.
- ZIP integrity checked.
- Xcode build and physical Ray-Ban Meta Gen 2 runtime test still require the user's Mac/iPhone.
