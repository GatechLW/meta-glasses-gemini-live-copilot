/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

/// Decode every HEVC sample (including inter frames) but render a UIImage only
/// a few times per second. This must not run on the main/UI actor.
/// The UIImage is passed unchanged to the existing Gemini 1 FPS throttle and
/// PNG/JPEG recorder. No resize or secondary JPEG encoding occurs here.
final class GlassesHEVCFrameProcessor {
  private let queue = DispatchQueue(label: "visionclaw.glasses.hevc.decoder", qos: .userInitiated)
  private let context = CIContext(options: [.useSoftwareRenderer: false])
  private let decoder = GlassesVTDecoder()
  private var lastUIImageAt: TimeInterval = 0
  private var renderEveryFrame = false
  private var deliveredFrameCount = 0
  private var decodeErrorCount = 0
  private var currentWindowStart = Date()
  private var windowFrameCount = 0
  private var lastActualSize: String = "unknown"

  /// Invoked from the decoding queue, NOT from the main actor.
  var onImage: ((UIImage) -> Void)?

  init() {
    decoder.onDecodedFrame = { [weak self] buffer in
      self?.handlePixelBuffer(buffer)
    }
  }

  func append(sampleBuffer: CMSampleBuffer, renderEveryFrame: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      self.renderEveryFrame = renderEveryFrame
      self.deliveredFrameCount += 1
      self.windowFrameCount += 1

      if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
        self.handlePixelBuffer(pixelBuffer)
      } else {
        // HEVC is inter-frame coded: always decode every compressed sample,
        // even when UIImage materialization is throttled to <= 5 FPS.
        do {
          try self.decoder.decode(sampleBuffer)
        } catch {
          self.decodeErrorCount += 1
          if self.decodeErrorCount <= 3 || self.decodeErrorCount % 50 == 0 {
            NSLog("[Stream HEVC] decode error #%d: %@", self.decodeErrorCount, String(describing: error))
          }
        }
      }
      let elapsed = Date().timeIntervalSince(self.currentWindowStart)
      if elapsed >= 5 {
        NSLog("[Stream HEVC] delivered %.2f FPS, last decoded size %@, total decode errors %d",
              Double(self.windowFrameCount) / elapsed, self.lastActualSize, self.decodeErrorCount)
        self.windowFrameCount = 0
        self.currentWindowStart = Date()
      }
    }
  }

  private func handlePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    lastActualSize = "\(w)x\(h)"
    if deliveredFrameCount <= 3 {
      NSLog("[Stream HEVC] decoded frame #%d: %dx%d", deliveredFrameCount, w, h)
    }
    let now = Date().timeIntervalSince1970
    // Original Gemini throttles further to ~1 FPS. 5 FPS keeps the UI preview
    // smooth enough without rendering every incoming HEVC frame on the CPU/GPU.
    guard renderEveryFrame || now - lastUIImageAt >= 0.20 else { return }
    lastUIImageAt = now

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      NSLog("[Stream HEVC] Could not convert decoded CVPixelBuffer to CGImage")
      return
    }
    onImage?(UIImage(cgImage: cgImage))
  }

  func reset() {
    queue.async { [weak self] in
      guard let self else { return }
      self.decoder.invalidate()
      self.lastUIImageAt = 0
      self.renderEveryFrame = false
      self.deliveredFrameCount = 0
      self.decodeErrorCount = 0
      self.windowFrameCount = 0
      self.currentWindowStart = Date()
      self.lastActualSize = "unknown"
    }
  }
}

private enum GlassesVTDecoderError: Error {
  case noFormatDescription
  case creationFailed(OSStatus)
  case decodeFailed(OSStatus)
}

/// Minimal VideoToolbox decoder for 0.9.0 `VideoFrame.sampleBuffer` HEVC.
/// The decoder callback may be synchronous or asynchronous; all state is kept
/// on the enclosing serial queue. Wait for async frames after each input so
/// that a session can be invalidated safely on stop/restart.
private final class GlassesVTDecoder {
  var onDecodedFrame: ((CVPixelBuffer) -> Void)?
  private var session: VTDecompressionSession?
  private var format: CMFormatDescription?

  deinit { invalidate() }

  func decode(_ sampleBuffer: CMSampleBuffer) throws {
    guard let newFormat = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      throw GlassesVTDecoderError.noFormatDescription
    }
    if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: newFormat) }) == true {
      try makeSession(format: newFormat)
    }
    var result = decodeOnce(sampleBuffer)
    // iOS can invalidate the hardware decoder on an app lifecycle change.
    if result == kVTInvalidSessionErr || result == kVTVideoDecoderMalfunctionErr {
      try makeSession(format: newFormat)
      result = decodeOnce(sampleBuffer)
    }
    guard result == noErr else { throw GlassesVTDecoderError.decodeFailed(result) }
  }

  private func decodeOnce(_ sampleBuffer: CMSampleBuffer) -> OSStatus {
    guard let session else { return kVTInvalidSessionErr }
    var info = VTDecodeInfoFlags(rawValue: 0)
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer,
      flags: [._1xRealTimePlayback], frameRefcon: nil, infoFlagsOut: &info)
    if status == noErr { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    return status
  }

  func invalidate() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    format = nil
  }

  private func makeSession(format newFormat: CMFormatDescription) throws {
    invalidate()
    var callback = VTDecompressionOutputCallbackRecord()
    callback.decompressionOutputCallback = { refcon, _, status, _, imageBuffer, _, _ in
      guard status == noErr, let refcon, let imageBuffer else { return }
      let decoder = Unmanaged<GlassesVTDecoder>.fromOpaque(refcon).takeUnretainedValue()
      decoder.onDecodedFrame?(imageBuffer)
    }
    callback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
    ]
    var resultSession: VTDecompressionSession?
    let code = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: newFormat,
      decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &callback, decompressionSessionOut: &resultSession)
    guard code == noErr, let resultSession else {
      throw GlassesVTDecoderError.creationFailed(code)
    }
    session = resultSession
    format = newFormat
    NSLog("[Stream HEVC] VideoToolbox decoder ready")
  }
}
