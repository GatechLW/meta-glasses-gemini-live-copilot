import Foundation
import Combine

enum LEGOPhase: String {
    case preparing = "加载教程"
    case readyToStart = "等待用户说：开始"
    case instructing = "讲解当前步骤"
    case waitingForBuild = "等待用户搭建"
    case verifying = "正在验收当前步骤"
    case completed = "8 步全部完成"
}

struct LEGOResultPayload {
    let response: [String: Any]
    let judgement: String
}

@MainActor
final class LEGOStepManager: ObservableObject {
    @Published private(set) var currentStep = 1
    @Published private(set) var phase: LEGOPhase = .preparing
    @Published private(set) var lastVerdict = "尚未验收"
    @Published private(set) var eventLog: [String] = []

    let tutorial: LEGOTutorial
    private var activeVerificationStep: Int?
    private var cachedResponses: [String: [String: Any]] = [:]
    private var startTranscriptBuffer = ""

    init(tutorial: LEGOTutorial) {
        self.tutorial = tutorial
    }

    var currentStepData: LEGOStep? {
        guard currentStep >= 1, currentStep <= tutorial.steps.count else { return nil }
        return tutorial.steps[currentStep - 1]
    }

    var currentTitle: String { currentStepData?.title ?? "已完成" }

    func log(_ message: String) {
        eventLog.append("\(Date().formatted(date: .omitted, time: .standard)) · \(message)")
        if eventLog.count > 36 { eventLog.removeFirst(eventLog.count - 36) }
    }

    func contextSent() {
        phase = .readyToStart
        log("8-step text context ready; reference JPEGs remain local until requested")
    }

    func heardUser(_ text: String) {
        guard !text.isEmpty else { return }
        if phase == .readyToStart {
            startTranscriptBuffer = String((startTranscriptBuffer + text).suffix(60))
            if startTranscriptBuffer.contains("开始") || startTranscriptBuffer.contains("继续") {
                phase = .instructing
                startTranscriptBuffer = ""
                log("User asked to start / continue")
            }
        } else if phase == .waitingForBuild,
                  ["搭好", "搭好了", "完成", "做完", "检查", "看看", "对不对", "正确吗"].contains(where: { text.contains($0) }) {
            phase = .verifying
            log("User requested Step \(currentStep) verification")
        } else if ["再说一遍", "重复一下", "再讲一次"].contains(where: { text.contains($0) }) {
            phase = .instructing
            log("User asked to repeat Step \(currentStep)")
        }
    }

    /// Only an exact current-step request may start a verification cycle.
    func beginVerification(step requestedStep: Int, callID: String) -> [String: Any]? {
        if let cached = cachedResponses[callID] { return cached }
        guard requestedStep == currentStep, currentStepData != nil else {
            log("Rejected verification: requested Step \(requestedStep), local Step \(currentStep)")
            return ["accepted": false, "error": "step_mismatch", "current_step": currentStep]
        }
        guard activeVerificationStep == nil else {
            log("Rejected duplicate verification while Step \(currentStep) is already pending")
            return ["accepted": false, "error": "verification_busy", "current_step": currentStep]
        }
        activeVerificationStep = currentStep
        phase = .verifying
        log("Verification cycle started for Step \(currentStep), callID=\(callID)")
        return nil
    }

    func cancelVerification(reason: String) {
        if let step = activeVerificationStep { log("Step \(step) verification cancelled: \(reason)") }
        activeVerificationStep = nil
        if currentStepData != nil { phase = .waitingForBuild }
        lastVerdict = "Step \(currentStep) · uncertain · \(reason)"
    }

    func processFlashInspection(call: LiveFunctionCall, inspection: LEGOVisualInspection) -> LEGOResultPayload {
        if let cached = cachedResponses[call.id] {
            return LEGOResultPayload(response: cached, judgement: cached["result"] as? String ?? "uncertain")
        }
        guard call.name == "request_step_verification",
              activeVerificationStep == currentStep else {
            let rejected: [String: Any] = ["accepted": false, "error": "no_active_verification", "current_step": currentStep]
            cachedResponses[call.id] = rejected
            return LEGOResultPayload(response: rejected, judgement: "uncertain")
        }
        return finishVerification(
            step: currentStep,
            judgement: inspection.verdict,
            checks: inspection.checks,
            evidence: inspection.evidence,
            correction: inspection.correction,
            verifier: inspection.model,
            callID: call.id
        )
    }

    func modelAudioDrained() {
        if phase == .instructing {
            phase = .waitingForBuild
            log("Instruction audio finished; waiting for user to build")
        }
    }

    private func finishVerification(step: Int,
                                    judgement rawJudgement: String,
                                    checks: [String: String],
                                    evidence: String,
                                    correction: String,
                                    verifier: String,
                                    callID: String) -> LEGOResultPayload {
        let judgement = ["correct", "incorrect", "uncertain"].contains(rawJudgement) ? rawJudgement : "uncertain"
        let completedStep = step
        let nextStep: Int?
        if judgement == "correct" {
            currentStep += 1
            nextStep = currentStep <= tutorial.steps.count ? currentStep : nil
            phase = currentStep > tutorial.steps.count ? .completed : .instructing
        } else {
            nextStep = nil
            phase = .waitingForBuild
        }
        activeVerificationStep = nil

        let fallbackCorrection = judgement == "correct" ? "" :
            (correction.isEmpty ? "请根据当前步骤的目标参考图重新调整，保持完整入镜后再说‘搭好了’。" : correction)
        lastVerdict = "Step \(completedStep) · \(judgement) · \(evidence)"
        let response: [String: Any] = [
            "accepted": true,
            "result": judgement,
            "completed_step": completedStep,
            "current_step": currentStep,
            "next_step": nextStep as Any? ?? NSNull(),
            "completed": currentStep > tutorial.steps.count,
            "reason": evidence,
            "correction": fallbackCorrection,
            "checks": checks,
            "verifier": verifier
        ]
        cachedResponses[callID] = response
        log("Step \(completedStep) verdict=\(judgement), verifier=\(verifier), next=\(currentStep)")
        if !checks.isEmpty {
            log("Checks: \(checks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        }
        return LEGOResultPayload(response: response, judgement: judgement)
    }


}
