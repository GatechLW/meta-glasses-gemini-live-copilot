import Foundation
import CryptoKit

/// Saves only the image/request bundle created for an actual visual Function Call.
/// Ordinary 1-FPS camera samples stay in memory and are never written to disk.
final class GeminiInputFrameRecorder {
    private let writerQueue = DispatchQueue(label: "iphone-lego-function-call-recorder", qos: .utility)
    private var sessionFolder: URL?
    private var eventCount = 0
    private var eventRecords: [[String: Any]] = []
    private var archiveFileName = "LEGOFunctionCallRequests.zip"
    private let isoFormatter = ISO8601DateFormatter()

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts the exact inline image bytes from the JSON body that will be sent
    /// to Gemini. This lets the export verify that the saved JPEG is byte-identical
    /// to the image embedded in the HTTP request.
    private func extractInlineImage(from requestJSON: Data) -> (data: Data, mimeType: String)? {
        guard
            let root = try? JSONSerialization.jsonObject(with: requestJSON) as? [String: Any],
            let contents = root["contents"] as? [[String: Any]],
            let parts = contents.first?["parts"] as? [[String: Any]]
        else { return nil }

        for part in parts {
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let encoded = inlineData["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { continue }
            return (data, inlineData["mimeType"] as? String ?? "unknown")
        }
        return nil
    }

    func startNewCapture(sessionFolderName: String = "LEGOFunctionCalls",
                         archiveFileName: String = "LEGOFunctionCallRequests.zip",
                         completion: (() -> Void)? = nil) {
        writerQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(sessionFolderName, isDirectory: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
            let folder = root.appendingPathComponent("Session_" + formatter.string(from: Date()), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                self.sessionFolder = folder
            } catch {
                self.sessionFolder = nil
                NSLog("[LEGOFunctionCallRecorder] Could not create session folder: %@", String(describing: error))
            }
            self.eventCount = 0
            self.eventRecords = []
            self.archiveFileName = archiveFileName
            completion?()
        }
    }

    /// Persists one exact model request plus the two JPEGs referenced by it.
    /// `requestJSON` is the serialized request body/payload sent by the iPhone;
    /// it intentionally contains no API key or authorization header.
    func recordVerification(step: Int,
                            mode: String,
                            callID: String,
                            currentJPEG: Data,
                            targetJPEG: Data,
                            requestJSON: Data,
                            metadata: [String: Any] = [:],
                            completion: @escaping (Int, String?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let root = self.sessionFolder else {
                completion(self.eventCount, "Function Call record directory unavailable")
                return
            }
            guard !currentJPEG.isEmpty, !targetJPEG.isEmpty, !requestJSON.isEmpty else {
                completion(self.eventCount, "Request or image data is empty")
                return
            }

            let nextIndex = self.eventCount + 1
            let safeMode = mode.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            let eventName = String(format: "Check_%04d_Step_%02d_%@", nextIndex, step, safeMode)
            let eventFolder = root.appendingPathComponent(eventName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: eventFolder, withIntermediateDirectories: true)
                try currentJPEG.write(to: eventFolder.appendingPathComponent("current.jpg"), options: .atomic)
                try targetJPEG.write(to: eventFolder.appendingPathComponent("target.jpg"), options: .atomic)
                try requestJSON.write(to: eventFolder.appendingPathComponent("request.json"), options: .atomic)

                var record = metadata
                record["event_index"] = nextIndex
                record["step"] = step
                record["mode"] = mode
                record["tool_call_id"] = callID
                record["saved_at"] = self.isoFormatter.string(from: Date())
                record["current_image_file"] = "current.jpg"
                record["target_image_file"] = "target.jpg"
                record["request_file"] = "request.json"
                record["current_image_bytes"] = currentJPEG.count
                record["target_image_bytes"] = targetJPEG.count
                record["request_json_bytes"] = requestJSON.count
                record["api_key_saved"] = false
                let metadataData = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                try metadataData.write(to: eventFolder.appendingPathComponent("metadata.json"), options: .atomic)

                self.eventCount = nextIndex
                self.eventRecords.append(["folder": eventName, "step": step, "mode": mode, "tool_call_id": callID])
                completion(self.eventCount, nil)
                NSLog("[LEGOFunctionCallRecorder] Saved %@", eventName)
            } catch {
                try? FileManager.default.removeItem(at: eventFolder)
                completion(self.eventCount, error.localizedDescription)
            }
        }
    }


    /// Persists a general scene-inspection Function Call. Unlike LEGO checks,
    /// this event has no TARGET image or step number; only CURRENT + exact Flash request.
    func recordGeneralVision(callID: String,
                             currentJPEG: Data,
                             requestJSON: Data,
                             metadata: [String: Any] = [:],
                             completion: @escaping (Int, String?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let root = self.sessionFolder else {
                completion(self.eventCount, "Function Call record directory unavailable")
                return
            }
            guard !currentJPEG.isEmpty, !requestJSON.isEmpty else {
                completion(self.eventCount, "Request or CURRENT image data is empty")
                return
            }

            let nextIndex = self.eventCount + 1
            let eventName = String(format: "Check_%04d_General_Flash_LOW", nextIndex)
            let eventFolder = root.appendingPathComponent(eventName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: eventFolder, withIntermediateDirectories: true)

                // This is the exact JPEG Data passed to GeminiFlashVisionService.analyze().
                let flashInputFile = "gemini_flash_input.jpg"
                try currentJPEG.write(
                    to: eventFolder.appendingPathComponent(flashInputFile),
                    options: .atomic
                )

                // request.json is the actual HTTP JSON body; the API key is only in
                // the HTTP header and is never written to this archive.
                try requestJSON.write(
                    to: eventFolder.appendingPathComponent("request.json"),
                    options: .atomic
                )

                let requestImage = self.extractInlineImage(from: requestJSON)
                let requestImageMatches = requestImage.map { $0.data == currentJPEG } ?? false
                let requestImageSHA = requestImage.map { self.sha256Hex($0.data) }
                let flashInputSHA = self.sha256Hex(currentJPEG)

                var record = metadata
                record["event_index"] = nextIndex
                record["mode"] = "General_AV_Flash_LOW"
                record["tool_call_id"] = callID
                record["saved_at"] = self.isoFormatter.string(from: Date())

                // Keep the old generic keys for compatibility with previous analysis scripts.
                record["current_image_file"] = flashInputFile
                record["current_image_bytes"] = currentJPEG.count
                record["current_image_sha256"] = flashInputSHA

                // Explicitly named image pair.
                record["gemini_flash_input_file"] = flashInputFile
                record["gemini_flash_input_bytes"] = currentJPEG.count
                record["gemini_flash_input_sha256"] = flashInputSHA
                record["gemini_flash_input_mime_type"] = requestImage?.mimeType ?? "image/jpeg"
                record["gemini_flash_input_width"] = metadata["current_image_width"] ?? NSNull()
                record["gemini_flash_input_height"] = metadata["current_image_height"] ?? NSNull()

                record["request_file"] = "request.json"
                record["request_json_bytes"] = requestJSON.count
                record["request_inline_image_matches_saved_file"] = requestImageMatches
                record["request_inline_image_sha256"] = requestImageSHA ?? (NSNull() as Any)
                record["target_image_file"] = NSNull()
                record["step"] = NSNull()
                record["api_key_saved"] = false

                let metadataData = try JSONSerialization.data(
                    withJSONObject: record,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try metadataData.write(
                    to: eventFolder.appendingPathComponent("metadata.json"),
                    options: .atomic
                )

                self.eventCount = nextIndex
                self.eventRecords.append([
                    "folder": eventName,
                    "mode": "General_AV_Flash_LOW",
                    "tool_call_id": callID,
                    "gemini_flash_input_file": flashInputFile,
                    "request_inline_image_matches_saved_file": requestImageMatches
                ])
                completion(self.eventCount, nil)
                NSLog(
                    "[GeneralAVFunctionCallRecorder] Saved %@ flash_input=%@ request_image_match=%@",
                    eventName,
                    flashInputFile,
                    requestImageMatches ? "true" : "false"
                )
            } catch {
                try? FileManager.default.removeItem(at: eventFolder)
                completion(self.eventCount, error.localizedDescription)
            }
        }
    }

    /// Attaches the actual Flash API response to the already-recorded Function Call.
    /// The raw HTTP response body is preserved byte-for-byte; the candidate text and
    /// the state-machine-normalized result are saved separately for convenient analysis.
    func recordFlashResponse(callID: String,
                             responseBody: Data?,
                             candidateText: String,
                             normalizedResult: [String: Any],
                             metadata: [String: Any] = [:],
                             completion: @escaping (String?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let eventIndex = self.eventRecords.firstIndex(where: {
                ($0["tool_call_id"] as? String) == callID
            }),
            let eventName = self.eventRecords[eventIndex]["folder"] as? String,
            let root = self.sessionFolder else {
                completion("No saved request record matches Flash Function Call ID: \(callID)")
                return
            }

            let eventFolder = root.appendingPathComponent(eventName, isDirectory: true)
            do {
                var savedFiles: [String] = []
                if let responseBody, !responseBody.isEmpty {
                    try responseBody.write(to: eventFolder.appendingPathComponent("flash_response.json"), options: .atomic)
                    savedFiles.append("flash_response.json")
                } else if let errorText = metadata["flash_error"] as? String, !errorText.isEmpty {
                    let errorPayload: [String: Any] = [
                        "error": errorText,
                        "call_id": callID,
                        "recorded_at": self.isoFormatter.string(from: Date())
                    ]
                    let errorData = try JSONSerialization.data(withJSONObject: errorPayload, options: [.prettyPrinted, .sortedKeys])
                    try errorData.write(to: eventFolder.appendingPathComponent("flash_error.json"), options: .atomic)
                    savedFiles.append("flash_error.json")
                }
                if !candidateText.isEmpty {
                    try Data(candidateText.utf8).write(to: eventFolder.appendingPathComponent("flash_candidate.txt"), options: .atomic)
                    savedFiles.append("flash_candidate.txt")
                }
                let normalizedData = try JSONSerialization.data(
                    withJSONObject: normalizedResult,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try normalizedData.write(to: eventFolder.appendingPathComponent("flash_result.json"), options: .atomic)
                savedFiles.append("flash_result.json")

                let metadataURL = eventFolder.appendingPathComponent("metadata.json")
                var record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))) as? [String: Any] ?? [:]
                metadata.forEach { record[$0.key] = $0.value }
                record["flash_response_file"] = responseBody?.isEmpty == false ? "flash_response.json" : NSNull()
                record["flash_error_file"] = (savedFiles.contains("flash_error.json") ? "flash_error.json" : NSNull())
                record["flash_candidate_file"] = candidateText.isEmpty ? NSNull() : "flash_candidate.txt"
                record["flash_result_file"] = "flash_result.json"
                record["flash_response_bytes"] = responseBody?.count ?? 0
                record["flash_candidate_text_bytes"] = candidateText.utf8.count
                record["flash_result_json_bytes"] = normalizedData.count
                record["flash_files"] = savedFiles
                record["flash_response_saved"] = responseBody?.isEmpty == false
                let metadataData = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                try metadataData.write(to: metadataURL, options: .atomic)

                self.eventRecords[eventIndex]["flash_result_file"] = "flash_result.json"
                self.eventRecords[eventIndex]["flash_response_saved"] = (responseBody?.isEmpty == false)
                completion(nil)
                NSLog("[LEGOFunctionCallRecorder] Saved Flash response for %@", eventName)
            } catch {
                completion("Could not save Flash response: \(error.localizedDescription)")
            }
        }
    }

    func export(completion: @escaping (Result<URL, Error>) -> Void) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let folder = self.sessionFolder, self.eventCount > 0 else {
                completion(.failure(NSError(domain: "LEGOFunctionCallRecorder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No visual Function Call requests have been recorded"])))
                return
            }
            do {
                let manifest: [String: Any] = [
                    "description": "Only visual Function Call events are saved. Each event contains the exact CURRENT JPEG extracted from the Meta glasses HEVC video stream, the matching TARGET JPEG for LEGO checks when applicable, the exact Flash request.json (without API key), SHA-256 checksums and request-image byte-identity verification, plus raw Flash response/candidate/result files. Ordinary 1-FPS video frames are memory-only. Standalone photo capture is not part of this app.",
                    "saved_event_count": self.eventCount,
                    "events": self.eventRecords
                ]
                let manifestURL = folder.appendingPathComponent("manifest.json")
                let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                try manifestData.write(to: manifestURL, options: .atomic)

                var inputs: [(url: URL, name: String)] = []
                if let enumerator = FileManager.default.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                        guard values.isRegularFile == true else { continue }
                        let relative = String(fileURL.path.dropFirst(folder.path.count + 1))
                        inputs.append((fileURL, relative))
                    }
                }
                inputs.sort { $0.name < $1.name }
                let output = folder.appendingPathComponent(self.archiveFileName)
                try GeminiInputStreamingZipWriter.create(output: output, inputs: inputs)
                completion(.success(output))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// Streaming, no-recompression ZIP32 writer.
private enum GeminiInputStreamingZipWriter {
    private struct Entry {
        let name: Data
        let size: UInt32
        let crc: UInt32
        let offset: UInt32
    }

    static func create(output: URL, inputs: [(url: URL, name: String)]) throws {
        guard crc32SelfTest() else {
            throw makeError("CRC32 self-test failed; refusing to create an invalid ZIP")
        }
        let fm = FileManager.default
        guard inputs.count <= Int(UInt16.max) else { throw makeError("Too many files for ZIP32") }
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        guard fm.createFile(atPath: output.path, contents: nil) else { throw makeError("Could not create ZIP") }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var entries: [Entry] = []

        func append(_ bytes: Data) throws {
            try handle.write(contentsOf: bytes)
            offset += UInt64(bytes.count)
            guard offset < UInt64(UInt32.max) else { throw makeError("ZIP exceeds 4GB limit") }
        }

        for input in inputs {
            let attributes = try fm.attributesOfItem(atPath: input.url.path)
            guard let fileSize = attributes[.size] as? NSNumber else { throw makeError("Missing file size") }
            let count = fileSize.uint64Value
            guard count < UInt64(UInt32.max), offset < UInt64(UInt32.max) else { throw makeError("ZIP32 size limit") }
            let bytesName = Data(input.name.utf8)
            guard bytesName.count < Int(UInt16.max) else { throw makeError("ZIP filename too long") }
            let crc = try fileCRC32(input.url)
            let entry = Entry(name: bytesName, size: UInt32(count), crc: crc, offset: UInt32(offset))
            var local = Data()
            local.appendZIPLE(UInt32(0x04034b50))
            local.appendZIPLE(UInt16(20))
            local.appendZIPLE(UInt16(0))
            local.appendZIPLE(UInt16(0))
            local.appendZIPLE(UInt16(0))
            local.appendZIPLE(UInt16(0))
            local.appendZIPLE(crc)
            local.appendZIPLE(entry.size)
            local.appendZIPLE(entry.size)
            local.appendZIPLE(UInt16(bytesName.count))
            local.appendZIPLE(UInt16(0))
            try append(local)
            try append(bytesName)
            let reader = try FileHandle(forReadingFrom: input.url)
            do {
                while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try append(chunk)
                }
                try reader.close()
            } catch {
                try? reader.close()
                throw error
            }
            entries.append(entry)
        }

        let directoryStart = offset
        for entry in entries {
            var central = Data()
            central.appendZIPLE(UInt32(0x02014b50))
            central.appendZIPLE(UInt16(20))
            central.appendZIPLE(UInt16(20))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(entry.crc)
            central.appendZIPLE(entry.size)
            central.appendZIPLE(entry.size)
            central.appendZIPLE(UInt16(entry.name.count))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt16(0))
            central.appendZIPLE(UInt32(0))
            central.appendZIPLE(entry.offset)
            try append(central)
            try append(entry.name)
        }
        guard offset - directoryStart < UInt64(UInt32.max) else { throw makeError("ZIP directory too large") }
        var footer = Data()
        footer.appendZIPLE(UInt32(0x06054b50))
        footer.appendZIPLE(UInt16(0))
        footer.appendZIPLE(UInt16(0))
        footer.appendZIPLE(UInt16(entries.count))
        footer.appendZIPLE(UInt16(entries.count))
        footer.appendZIPLE(UInt32(offset - directoryStart))
        footer.appendZIPLE(UInt32(directoryStart))
        footer.appendZIPLE(UInt16(0))
        try append(footer)
    }

    private static func fileCRC32(_ url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            updateCRC32(&crc, with: chunk)
        }
        return ~crc
    }

    /// Standard ZIP/PKZIP CRC-32 (reflected polynomial 0xEDB88320).
    /// Every input byte must run through all 8 bits; omitting the inner loop
    /// produces a syntactically valid ZIP whose entries all fail CRC checks.
    private static func updateCRC32(_ crc: inout UInt32, with bytes: Data) {
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
    }

    /// Canonical CRC-32 test vector: CRC32("123456789") == 0xCBF43926.
    private static func crc32SelfTest() -> Bool {
        var crc: UInt32 = 0xFFFF_FFFF
        updateCRC32(&crc, with: Data("123456789".utf8))
        return ~crc == 0xCBF4_3926
    }

    private static func makeError(_ message: String) -> Error {
        NSError(domain: "GeminiInputStreamingZipWriter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension Data {
    mutating func appendZIPLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
