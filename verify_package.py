#!/usr/bin/env python3
"""Offline integrity checks for Meta Glasses LEGO + General A/V Copilot V2.0."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import re

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "iPhoneGeminiVideoLab"
APP = PROJECT / "iPhoneGeminiVideoLab"
RESOURCE = PROJECT / "LEGOResources"
errors = []


def require(path: Path, label: str):
    if not path.exists():
        errors.append(f"Missing {label}: {path.relative_to(ROOT)}")
    elif path.is_file() and path.stat().st_size == 0:
        errors.append(f"Empty {label}: {path.relative_to(ROOT)}")


required = [
    PROJECT / "MetaGlassesGeneralAV.xcodeproj/project.pbxproj",
    APP / "ContentView.swift",
    APP / "SessionViewModel.swift",
    APP / "Gemini/GeminiLiveService.swift",
    APP / "Gemini/GeminiConfig.swift",
    APP / "Gemini/GeminiFlashVisionService.swift",
    APP / "Gemini/AudioManager.swift",
    APP / "Camera/MetaGlassesDATManager.swift",
    APP / "Camera/GlassesHEVCFrameProcessor.swift",
    APP / "LEGO/LEGOTutorialRepository.swift",
    APP / "LEGO/LEGOStepManager.swift",
    APP / "LEGO/LEGOVisualVerifier.swift",
    APP / "Recording/GeminiInputFrameRecorder.swift",
    RESOURCE / "tutorial.json",
    RESOURCE / "SYSTEM_PROMPT.md",
    RESOURCE / "TUTORIAL_CONTEXT.md",
    PROJECT / "README_使用说明.md",
    PROJECT / "README.md",
]
for path in required:
    require(path, path.relative_to(ROOT).as_posix())

try:
    tutorial = json.loads((RESOURCE / "tutorial.json").read_text(encoding="utf-8"))
    assert tutorial.get("total_steps") == 8
    assert len(tutorial.get("steps", [])) == 8
    assert [step.get("step") for step in tutorial["steps"]] == list(range(1, 9))
    for step in tutorial["steps"]:
        for key in ("before_image", "after_image"):
            require(RESOURCE / step[key], f"Step {step['step']} {key}")
    require(RESOURCE / tutorial["inventory_image"], "inventory image")
except Exception as exc:
    errors.append(f"tutorial.json validation failed: {exc}")

config = (APP / "Gemini/GeminiConfig.swift").read_text(encoding="utf-8")
service = (APP / "Gemini/GeminiLiveService.swift").read_text(encoding="utf-8")
vm = (APP / "SessionViewModel.swift").read_text(encoding="utf-8")
view = (APP / "ContentView.swift").read_text(encoding="utf-8")
repo = (APP / "LEGO/LEGOTutorialRepository.swift").read_text(encoding="utf-8")
verifier = (APP / "LEGO/LEGOVisualVerifier.swift").read_text(encoding="utf-8")
flash = (APP / "Gemini/GeminiFlashVisionService.swift").read_text(encoding="utf-8")
recorder = (APP / "Recording/GeminiInputFrameRecorder.swift").read_text(encoding="utf-8")
audio = (APP / "Gemini/AudioManager.swift").read_text(encoding="utf-8")
dat = (APP / "Camera/MetaGlassesDATManager.swift").read_text(encoding="utf-8")

# Two modes and both mode-specific visual pipelines.
for required_text, label in [
    ("case lego = ", "LEGO mode enum"),
    ("case generalAV = ", "General A/V mode enum"),
    ('"name": "request_step_verification"', "LEGO visual tool"),
    ('"name": "inspect_current_scene"', "General A/V visual tool"),
    ("func connect(mode: AssistantMode", "mode-aware Live connection"),
    ("startGeneralVisualInspection", "General Flash visual pipeline"),
    ("startFlashStepVerification", "LEGO Flash verification pipeline"),
    ("activeMode = selectedMode", "selected mode used by session startup"),
    ("ForEach(AssistantMode.allCases)", "front-end mode selector"),
    ("private var stepPanel", "LEGO Step UI"),
    ("stepManager = LEGOStepManager(tutorial: loaded)", "LEGO state machine initialization"),
    ("gemini.connect(mode: activeMode, tutorial: loadedTutorial)", "mode-aware Gemini connect"),
]:
    source = config + service + vm + view
    if required_text not in source:
        errors.append(f"Missing dual-mode element: {label}")

if "GeminiConfig.toolSet(mode: activeMode)" not in service:
    errors.append("Live setup must register tools for the selected mode")
if "GeminiConfig.systemInstruction(mode: mode, tutorial: tutorial)" not in service:
    errors.append("Live system instruction must depend on selected mode")
if "stepManager = nil" not in vm or "LEGOTutorialRepository.load()" not in vm:
    errors.append("General mode must not load/initialize LEGO tutorial/state")
if "thinkingLevel: .low" not in vm or '"thinkingLevel": thinkingLevel.apiValue' not in flash:
    errors.append("Flash visual analysis must use LOW")
if "requestProgressSpeech(progressMessage)" not in vm or "APP PROGRESS SPEECH REQUEST" not in service:
    errors.append("Live-generated progress speech echo must remain")

# Strict glasses HFP: both directions, no phone fallback.
for required_text, label in [
    ("portType == .bluetoothHFP", "Bluetooth HFP port"),
    ('name.contains("meta")', "Meta glasses device-name validation"),
    ("session.setPreferredInput(hfpInput)", "preferred HFP input selection"),
    ("route.inputs.contains", "HFP input route validation"),
    ("route.outputs.contains", "HFP output route validation"),
    ("func requireGlassesHFPRoute() async throws", "strict route preflight"),
    ("onRouteInvalidated", "route-loss callback"),
    ("beforeStreamStart", "pre-stream HFP callback"),
]:
    if required_text not in audio + dat:
        errors.append(f"Missing strict glasses audio element: {label}")
if "try await beforeStreamStart()" not in dat or dat.find("try await beforeStreamStart()") > dat.find("stream.start()"):
    errors.append("HFP route preflight must run before DAT stream.start()")
if "guard self.isRunning" not in vm or "!self.gemini.isModelSpeaking" in vm:
    errors.append("Full-duplex uplink must not be gated while Gemini speaks")
if '"activityHandling": "START_OF_ACTIVITY_INTERRUPTS"' not in service:
    errors.append("Gemini Live must retain START_OF_ACTIVITY_INTERRUPTS")
if '"turnCoverage": "TURN_INCLUDES_ALL_INPUT"' not in service:
    errors.append("Gemini Live must retain TURN_INCLUDES_ALL_INPUT")
if "onInterrupted" not in vm or "audio.stopPlayback()" not in vm:
    errors.append("Interrupted event must stop queued local audio")

# Standalone photo capture must be completely removed from app source and UI.
for path in APP.rglob("*.swift"):
    source = path.read_text(encoding="utf-8")
    for forbidden in ("captureHighQualityPhoto", "capturePhoto(resolution:", "photoDataPublisher",
                      "selectedCaptureSource", "GlassesCaptureSource", "highQualityPhoto"):
        if forbidden in source:
            errors.append(f"Standalone-photo branch remains in {path.relative_to(ROOT)}: {forbidden}")

# Logging and export remain.
for name in ("recordVerification", "recordGeneralVision", "recordFlashResponse",
             "flash_response.json", "flash_candidate.txt", "flash_result.json", "flash_error.json"):
    if name not in recorder:
        errors.append(f"Recorder missing logging element: {name}")
if "responseBody: response?.rawResponseBody" not in vm:
    errors.append("General mode must save the raw Flash HTTP response")
if "responseBody: inspection.rawResponseBody" not in vm:
    errors.append("LEGO mode must save the raw Flash HTTP response")
if "current.jpg" not in recorder or "request.json" not in recorder:
    errors.append("Recorder must save CURRENT image and exact request")
if "for _ in 0..<8" not in recorder or "0xCBF4_3926" not in recorder or "crc32SelfTest()" not in recorder:
    errors.append("ZIP writer must use standard CRC32 and its canonical self-test")

# Xcode source/resource references.
pbx_path = PROJECT / "MetaGlassesGeneralAV.xcodeproj/project.pbxproj"
pbx = pbx_path.read_text(encoding="utf-8")
for needle in [
    "MetaGlassesDATManager.swift in Sources",
    "AudioManager.swift in Sources",
    "LEGOTutorialRepository.swift in Sources",
    "LEGOStepManager.swift in Sources",
    "LEGOVisualVerifier.swift in Sources",
    "GeminiFlashVisionService.swift in Sources",
    "GeminiInputFrameRecorder.swift in Sources",
    "LEGOResources in Resources",
]:
    if needle not in pbx:
        errors.append(f"Xcode project missing build reference: {needle}")

# Parse Swift syntax when compiler is available.
swiftc = shutil.which("swiftc")
if swiftc:
    for source in APP.rglob("*.swift"):
        result = subprocess.run(
            [swiftc, "-frontend", "-parse", str(source)],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            errors.append(f"Swift parse failed: {source.relative_to(ROOT)}\n{result.stderr}")
else:
    print("WARN: swiftc not found; skipped Swift syntax parsing.")

# Lint plist and project when plutil is available.
plutil = shutil.which("plutil")
if plutil:
    for path in [APP / "Info.plist", pbx_path]:
        result = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            errors.append(f"plutil failed: {path.relative_to(ROOT)}\n{result.stderr or result.stdout}")

if errors:
    print("PACKAGE CHECK FAILED")
    for error in errors:
        print("-", error)
    sys.exit(1)

print("PACKAGE CHECK PASSED")
print("- Front-end exposes General A/V and LEGO modes")
print("- LEGO mode initializes the 8-step state machine and Flash LOW verifier")
print("- General mode routes visual questions to the latest Meta HEVC frame + Flash LOW")
print("- Standalone camera.photo branch removed; video-stream capture only")
print("- Strict Bluetooth HFP microphone AND speaker route required; no iPhone fallback")
print("- Full-duplex microphone uplink remains active while Gemini speaks")
print("- Live server VAD / START_OF_ACTIVITY_INTERRUPTS and local playback interruption retained")
print("- Function Call images, exact requests, raw Flash responses and normalized results remain exportable")
print("- Swift syntax, Info.plist, and Xcode project checks passed when tools are available")
