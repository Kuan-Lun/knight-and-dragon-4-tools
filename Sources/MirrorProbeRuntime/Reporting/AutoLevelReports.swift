import Foundation
import MirrorProbeCore

struct AutomationLimitsReport: Codable {
    let maximumCycles: Int?
    let maximumMinutes: Double?
    let maximumActions: Int?
    let pollIntervalSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case maximumCycles, maximumMinutes, maximumActions, pollIntervalSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Explicit null distinguishes an unlimited run from a missing report field.
        try container.encode(maximumCycles, forKey: .maximumCycles)
        try container.encode(maximumMinutes, forKey: .maximumMinutes)
        try container.encode(maximumActions, forKey: .maximumActions)
        try container.encode(pollIntervalSeconds, forKey: .pollIntervalSeconds)
    }
}

struct AutomationRunEvent: Codable {
    let sequence: Int
    let timestamp: String
    let elapsedSeconds: Double
    let kind: String
    let state: GameState?
    let decision: String?
    let action: AutoLevelActionIntent?
    let target: AutoLevelActionTarget?
    let frameFingerprint: String?
    let detail: String?
    let screenshotPath: String?
}

enum AutomationDiagnosticScreenshotRole: String, Codable {
    case recent
    case final
}

struct AutomationDiagnosticScreenshotReport: Codable {
    let captureSequence: UInt64
    let capturedAtElapsedSeconds: Double
    let state: GameState
    let frameFingerprint: String
    let path: String
    let role: AutomationDiagnosticScreenshotRole
}

struct AutomationDiagnosticPersistenceResult {
    let finalPath: String?
    let screenshots: [AutomationDiagnosticScreenshotReport]
    let errors: [String]
}

struct AutomationRunReport: Codable {
    let schemaVersion: Int
    let recognitionMode: String?
    let sessionID: String
    var status: String
    let startedAt: String
    var endedAt: String?
    let window: WindowReport
    let talismanPolicy: String
    let inputMode: AutoLevelInputMode
    let captureLevel: AutoLevelCaptureLevel
    let limits: AutomationLimitsReport
    let outputDirectory: String
    let stopFile: String
    var completedCycles: Int
    var actionsPosted: Int
    var finalReason: String?
    var diagnosticScreenshots: [AutomationDiagnosticScreenshotReport]
    var diagnosticPersistenceErrors: [String]
    var events: [AutomationRunEvent]
}
