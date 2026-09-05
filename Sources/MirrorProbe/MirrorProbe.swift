import AppKit
import ApplicationServices
import CoreGraphics
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MirrorProbeCore
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

private let mirrorBundleIdentifier = "com.apple.ScreenContinuity"
private let singleClickConfirmation = "SINGLE_CLICK"
private let autoLevelConfirmation = "AUTO_LEVEL"
private let legacyAutoLevelConfirmation = "AUTO_LEVEL_NO_TALISMAN"
private let characterRerollConfirmation = "CHARACTER_REROLL"
private let analysisProfileName = "zh-Hant-v1"
private let analysisSchemaVersion = 2
private let automationSchemaVersion = 4
private let characterRerollSchemaVersion = 3
private let maximumPNGByteCount = 50 * 1_024 * 1_024

private enum ProbeError: LocalizedError {
    case invalidArguments(String)
    case screenCapturePermissionRequired
    case postEventPermissionRequired
    case noMirrorWindow
    case ambiguousMirrorWindows([UInt32])
    case requestedWindowNotFound(UInt32)
    case unsafeWindow(String)
    case captureFailed(String)
    case imageLoadFailed(String)
    case textRecognitionFailed(String)
    case pngEncodingFailed
    case frameConversionFailed

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case .screenCapturePermissionRequired:
            return "Screen Recording permission is required. Grant it in System Settings, then run the command again."
        case .postEventPermissionRequired:
            return "Accessibility/Post Event permission is required. Grant it in System Settings, then run the command again."
        case .noMirrorWindow:
            return "No on-screen iPhone Mirroring window was found. Keep iPhone Mirroring open and unminimized in the current Space; other windows may cover it."
        case let .ambiguousMirrorWindows(ids):
            return "More than one eligible iPhone Mirroring window was found (IDs: \(ids)). Pass --window-id explicitly."
        case let .requestedWindowNotFound(id):
            return "The requested iPhone Mirroring window ID \(id) is no longer available."
        case let .unsafeWindow(reason):
            return "Safety check refused the action: \(reason)"
        case let .captureFailed(message):
            return "ScreenCaptureKit failed: \(message)"
        case let .imageLoadFailed(message):
            return "Could not load the input image: \(message)"
        case let .textRecognitionFailed(message):
            return "Vision text recognition failed: \(message)"
        case .pngEncodingFailed:
            return "Could not encode the captured image as PNG."
        case .frameConversionFailed:
            return "Could not convert the captured image to RGBA pixels."
        }
    }
}

private struct WindowReport: Codable {
    let windowID: UInt32
    let processID: Int32
    let applicationName: String
    let bundleIdentifier: String
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let onScreen: Bool
    let active: Bool
}

private struct CaptureReport: Codable {
    let timestamp: String
    let window: WindowReport
    let outputPath: String
    let imageWidth: Int
    let imageHeight: Int
    let metrics: FrameMetrics
}

private struct DoctorReport: Codable {
    let timestamp: String
    let screenCapturePermission: String
    let postEventPermission: String
    let windows: [WindowReport]
    let nextStep: String?
}

private struct FocusCheckReport: Codable {
    let timestamp: String
    let windowID: UInt32
    let previousProcessID: Int32?
    let targetProcessID: Int32
    let activation: ForegroundActivationRequest
    let frontmostProcessIDAfterActivation: Int32?
    let restoration: ForegroundActivationRequest?
    let frontmostProcessIDAfterRestoration: Int32?
    let targetFocusVerified: Bool
    let restorationVerified: Bool
    let inputEventsPosted: Int
}

private struct ClickReport: Codable {
    let timestamp: String
    let window: WindowReport
    let normalizedX: Double
    let normalizedY: Double
    let screenX: Double
    let screenY: Double
    let beforePath: String
    let afterPath: String
    let beforeMetrics: FrameMetrics
    let afterMetrics: FrameMetrics
    let meanAbsoluteDifference: Double?
}

private struct CharacterRerollLimitsReport: Codable {
    let minimumTotal: Int
    let maximumRerolls: Int
    let maximumMinutes: Double
}

private struct CharacterRerollReport: Codable {
    let schemaVersion: Int
    let status: String
    let startedAt: String
    let endedAt: String?
    let window: WindowReport
    let limits: CharacterRerollLimitsReport
    let initialTotal: Int?
    let finalTotal: Int?
    let rerollsPosted: Int
    let finalReason: String
    let keeperOrConflictWasObserved: Bool
    let candidateImage: CharacterRerollCandidateImageReport?
}

private struct CharacterRerollCandidateImageReport: Codable {
    let role: String
    let path: String
    let pngSHA256: String
    let observedTotal: Int?
    let observedTotalSource: String?
    let credibleFullFrameTotals: [Int]
    let credibleFocusedTotals: [Int]
    let fullFrameWasContaminated: Bool
    let focusedWasContaminated: Bool
    let focusedTotal: Int?
    let renderedDigitCount: Int?
    let boundaryEvidence: String
    let thresholdReached: Bool
}

private struct CharacterRerollObservation {
    let capturedAt: TimeInterval
    let window: SCWindow
    let decision: CharacterRerollDecision
    let boundaryEvidence: CharacterTotalBoundaryEvidence
    let credibleFullFrameTotals: [Int]
    let credibleFocusedTotals: [Int]
    let fullFrameWasContaminated: Bool
    let focusedWasContaminated: Bool
    let fullFrameTotal: Int?
    let focusedTotal: Int?
    let renderedDigitCount: Int?
    let image: CGImage
    let rgba: RGBAFrame
}

private enum CharacterRerollCandidateRole: String {
    case finalStable
    case lastVerifiedStable
    case preClickFallback
    case latestPreClickUnverified
    case latestPostClickUnverified
}

private struct CharacterRerollTerminalError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private enum CharacterRerollObservationEnd {
    case stopRequested
    case maximumRuntimeReached
    case failed(String)
}

private enum CharacterRerollAcknowledgementOutcome {
    case acknowledged(CharacterRerollObservation)
    case ended(
        latestPostClick: CharacterRerollObservation?,
        keeperOrConflictWasObserved: Bool,
        reason: CharacterRerollObservationEnd
    )
}

private enum CharacterRerollStabilityOutcome {
    case stable(CharacterRerollObservation)
    case ended(
        latest: CharacterRerollObservation?,
        keeperOrConflictWasObserved: Bool,
        reason: CharacterRerollObservationEnd
    )
}

private enum CharacterRerollClickResult {
    case posted
    case focusContended
    case stopRequested
    case maximumRuntimeReached
}

private enum CharacterRerollInterruption: Error {
    case stopRequested
    case maximumRuntimeReached
}

private struct AnalysisSourceReport: Codable {
    let kind: String
    let path: String?
    let window: WindowReport?
    let capturedImagePath: String?
}

private struct AnalysisImageReport: Codable {
    let width: Int
    let height: Int
    let orientation: String
    let pngSHA256: String
}

private struct AnalysisOCRReport: Codable {
    let engine: String
    let requestRevision: Int
    let recognitionLevel: String
    let languages: [String]
    let usesLanguageCorrection: Bool
    let coordinateSpace: String
    let observations: [OCRTextObservation]
}

private struct AnalysisSafetyReport: Codable {
    let readOnly: Bool
    let inputEventsPosted: Int
    let actionAuthorization: String
}

private struct AnalysisReport: Codable {
    let schemaVersion: Int
    let profile: String
    let command: String
    let status: String
    let timestamp: String
    let source: AnalysisSourceReport
    let image: AnalysisImageReport
    let frameMetrics: FrameMetrics
    let ocr: AnalysisOCRReport
    let classification: GameStateClassification
    let safety: AnalysisSafetyReport
}

private struct RGBAFrame {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private struct WindowServerWindow {
    let identity: AutoLevelWindowIdentity
    let frame: CGRect
    let alpha: Double
    let layer: Int
    let name: String?
    let ownerBundleIdentifier: String?
}

private struct LoadedPNG {
    let image: CGImage
    let sha256: String
}

private struct AutomationLimitsReport: Codable {
    let maximumCycles: Int
    let maximumMinutes: Double
    let maximumActions: Int
    let pollIntervalSeconds: Double
}

private struct AutomationRunEvent: Codable {
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

private enum AutomationDiagnosticScreenshotRole: String, Codable {
    case recent
    case final
}

private struct AutomationDiagnosticScreenshotReport: Codable {
    let captureSequence: UInt64
    let capturedAtElapsedSeconds: Double
    let state: GameState
    let frameFingerprint: String
    let path: String
    let role: AutomationDiagnosticScreenshotRole
}

private struct AutomationDiagnosticPersistenceResult {
    let finalPath: String?
    let screenshots: [AutomationDiagnosticScreenshotReport]
    let errors: [String]
}

private struct AutomationRunReport: Codable {
    let schemaVersion: Int
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

/// Capture time precedes OCR so recognition latency never becomes sampled stability.
private struct AutomationCapturedFrame {
    let capturedAt: TimeInterval
    let windowContinuityGeneration: UInt64
    let window: SCWindow
    let image: CGImage
    let rgba: RGBAFrame
    let metrics: FrameMetrics
}

private struct AutomationObservation {
    let capturedAt: TimeInterval
    let windowContinuityGeneration: UInt64
    let window: SCWindow
    let image: CGImage
    let rgba: RGBAFrame
    let metrics: FrameMetrics
    let observations: [OCRTextObservation]
    let classification: GameStateClassification
    let fingerprint: String
}

/// A missing window invalidates all pixel continuity, even when it returns within one poll.
private final class AutomationWindowRecoveryContext {
    let stopURL: URL
    let sessionDeadline: TimeInterval
    private(set) var generation: UInt64 = 0

    init(stopURL: URL, sessionDeadline: TimeInterval) {
        self.stopURL = stopURL
        self.sessionDeadline = sessionDeadline
    }

    func interruptContinuity() { generation &+= 1 }

    func checkSessionBoundary() throws {
        if FileManager.default.fileExists(atPath: stopURL.path) {
            throw AutomationCaptureInterruption.stopRequested
        }
        if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
            throw AutomationCaptureInterruption.sessionExpired
        }
    }
}

private enum AutomationCaptureInterruption: LocalizedError {
    case stopRequested
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .stopRequested: "Capture stopped because the STOP file was detected."
        case .sessionExpired: "Capture stopped because the session time limit was reached."
        }
    }
}

private struct BufferedAutomationCapture {
    let sequence: UInt64
    let capturedAt: TimeInterval
    let state: GameState
    let fingerprint: String
    let image: CGImage
}

/// Keeps only the most recent successfully analyzed captures in memory. Nothing in this buffer
/// reaches disk during a normal error-level run.
private final class AutomationCaptureRecorder {
    private var nextSequence: UInt64 = 1
    private var buffer = RecentCaptureBuffer<BufferedAutomationCapture>(capacity: 8)

    func record(_ observation: AutomationObservation) {
        buffer.append(BufferedAutomationCapture(
            sequence: nextSequence,
            capturedAt: observation.capturedAt,
            state: observation.classification.state,
            fingerprint: observation.fingerprint,
            image: observation.image
        ))
        nextSequence &+= 1
    }

    var capturesOldestFirst: [BufferedAutomationCapture] {
        buffer.elementsOldestFirst
    }
}

private struct AutomationForegroundActivationSnapshot {
    let attempt: Int
    let maximumAttempts: Int
    let activateReturned: Bool?
    let targetApplicationIsActive: Bool
    /// ScreenCaptureKit streaming state; recorded for capture diagnostics, never used as focus.
    let scWindowIsActive: Bool
    let expectedProcessID: Int32
    let frontmostProcessID: Int32?
    let frontmostApplicationName: String?
    let frontmostBundleIdentifier: String?

    var isReady: Bool {
        AutoLevelForegroundActivationRetryState.activationIsReady(
            activateReturned: activateReturned ?? false,
            targetApplicationIsActive: targetApplicationIsActive,
            frontmostProcessMatches: frontmostProcessID == expectedProcessID
        )
    }

    func detail(phase: String, result: String) -> String {
        let actualPID = frontmostProcessID.map(String.init) ?? "none"
        let actualName = frontmostApplicationName.map { String(reflecting: $0) } ?? "none"
        let actualBundle = frontmostBundleIdentifier.map { String(reflecting: $0) } ?? "none"
        let activationRequest = activateReturned.map(String.init) ?? "notRequestedAlreadyFrontmost"
        return "phase=\(phase), attempt=\(attempt)/\(maximumAttempts), "
            + "activationRequestAccepted=\(activationRequest), focusSource=Accessibility, "
            + "appKitTargetIsActive=\(targetApplicationIsActive), "
            + "scWindowIsActive=\(scWindowIsActive), expectedPID=\(expectedProcessID), "
            + "frontmostPID=\(actualPID), frontmostApplicationName=\(actualName), "
            + "frontmostBundleIdentifier=\(actualBundle), result=\(result), "
            + "noInputPosted=true"
    }
}

private enum AutomationActionPreflightResult {
    case confirmed(
        observation: AutomationObservation,
        target: AutoLevelActionTarget,
        activation: AutomationForegroundActivationSnapshot?
    )
    case stateChanged(
        observation: AutomationObservation,
        activation: AutomationForegroundActivationSnapshot?
    )
    case activationContended(
        observation: AutomationObservation,
        activation: AutomationForegroundActivationSnapshot
    )
}

private enum AutomationClickResult {
    case posted(at: TimeInterval)
    case stopRequested
    case maximumRuntimeReached
    case foregroundActivationContended(detail: String)
}

private struct AutomationTemporalFrame {
    let rgba: RGBAFrame
    let context: BattleWindowContext
    let inputGeneration: UInt64
}

private enum AutomationVisualConfirmationResult {
    case confirmed(BattleVisualStabilityConfirmation, AutomationObservation, BattleStallAssessment)
    case rejected(AutomationObservation, detail: String)
    case interrupted
}

private struct VerifiedAutomaticBattleProgress {
    let battleSessionID: String
    let inputGeneration: UInt64

    func matches(battleSessionID: String?, inputGeneration: UInt64) -> Bool {
        guard let battleSessionID else { return false }
        return self.battleSessionID == battleSessionID
            && self.inputGeneration == inputGeneration
    }
}

private struct AutomationBattleTracker {
    private(set) var currentID: String?
    private(set) var sequence = 0
    private var previousStableState: GameState?

    mutating func observe(state: GameState, sessionID: String) -> String? {
        if state == .battleEncounterPrompt, previousStableState != .battleEncounterPrompt {
            sequence += 1
            currentID = "\(sessionID)-battle-\(sequence)"
        } else if currentID == nil, isBattleFamily(state) {
            sequence += 1
            currentID = "\(sessionID)-battle-\(sequence)"
        }

        if isMissionResult(state) {
            currentID = nil
        }
        if state != .unknown {
            previousStableState = state
        }
        return currentID
    }

    private func isBattleFamily(_ state: GameState) -> Bool {
        switch state {
        case .battle, .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt,
             .retreatConfirmation, .defeat:
            return true
        default:
            return false
        }
    }

    private func isMissionResult(_ state: GameState) -> Bool {
        switch state {
        case .missionComplete, .missionCompleteRepeatSelected,
             .missionFailed, .missionFailedRepeatSelected:
            return true
        default:
            return false
        }
    }
}

@main
private struct MirrorProbe {
    @MainActor
    static func main() {
        // NSWorkspace/NSRunningApplication cache changing properties until the main event
        // loop processes AppKit updates. Initializing NSApplication alone left foreground
        // observations stale in the packaged command, even after successful AX activation.
        let appKitCommands: Set<String> = [
            "doctor", "focus-check", "capture", "analyze", "click", "reroll-character", "run",
        ]
        let needsAppKit = appKitCommands.contains(CommandLine.arguments.dropFirst().first ?? "")
        let keepAlivePort = Port()
        RunLoop.main.add(keepAlivePort, forMode: .common)
        Task {
            do {
                try await run()
                Foundation.exit(0)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                FileHandle.standardError.write(Data("error: \(message)\n".utf8))
                Foundation.exit(1)
            }
        }
        if needsAppKit {
            NSApplication.shared.run()
        } else {
            // Help and offline analysis must not establish a WindowServer connection.
            RunLoop.main.run()
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }
        let options = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "doctor":
            await establishAppKitConnection()
            try await doctor(options)
        case "capture":
            await establishAppKitConnection()
            try await captureCommand(options)
        case "focus-check":
            await establishAppKitConnection()
            try await focusCheckCommand(options)
        case "analyze":
            await establishAppKitConnection()
            try await analyzeCommand(options)
        case "analyze-file":
            try analyzeFileCommand(options)
        case "click":
            await establishAppKitConnection()
            try await clickCommand(options)
        case "reroll-character":
            await establishAppKitConnection()
            try await characterRerollCommand(options)
        case "run":
            await establishAppKitConnection()
            try await autoLevelCommand(options)
        default:
            throw ProbeError.invalidArguments("Unknown command '\(command)'. Run mirror-probe help.")
        }
    }

    private static func doctor(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--output"],
            flagOptions: ["--request-permissions"]
        )
        let requestPermissions = arguments.contains("--request-permissions")
        var screenGranted = CGPreflightScreenCaptureAccess()
        var postEventGranted = CGPreflightPostEventAccess()

        if requestPermissions {
            if !screenGranted {
                _ = CGRequestScreenCaptureAccess()
            }
            if !postEventGranted {
                _ = CGRequestPostEventAccess()
            }
            if !screenGranted || !postEventGranted {
                print("Permission requests were sent. Complete the macOS prompts; this probe will wait 30 seconds.")
                try await Task.sleep(for: .seconds(30))
                screenGranted = CGPreflightScreenCaptureAccess()
                postEventGranted = CGPreflightPostEventAccess()
            }
        }

        let windows = screenGranted ? try await mirrorWindows().map(windowReport) : []
        let nextStep: String?
        if !screenGranted || !postEventGranted {
            nextStep = requestPermissions
                ? "Grant missing permissions in System Settings, quit this probe, and run doctor again."
                : "Run doctor --request-permissions."
        } else if windows.isEmpty {
            nextStep = "Open iPhone Mirroring, connect the iPhone, and keep the window visible."
        } else {
            nextStep = nil
        }

        let report = DoctorReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            screenCapturePermission: screenGranted ? "granted" : "missing",
            postEventPermission: postEventGranted ? "granted" : "missing",
            windows: windows,
            nextStep: nextStep
        )
        try printJSON(report)

        if let output = option("--output", in: arguments) {
            let outputURL = try outputURL(for: output)
            try writeJSON(report, to: outputURL)
        }
    }

    /// Exercises activation and restoration through the packaged app's real TCC identity.
    /// It never posts mouse/keyboard events or advances the game.
    private static func focusCheckCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments, valueOptions: ["--window-id", "--output"]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()
        let window = try await selectMirrorWindow(requestedID: optionalWindowID(arguments))
        guard let processID = window.owningApplication?.processID,
              let target = NSRunningApplication(processIdentifier: processID)
        else {
            throw ProbeError.unsafeWindow("could not resolve iPhone Mirroring for focus check")
        }
        let lock = try AutoLevelWindowRunLock.acquire(
            for: AutoLevelWindowIdentity(processID: processID, windowID: window.windowID)
        )
        defer { lock.release() }
        guard var focusBorrow = ForegroundFocusBorrow(targetProcessID: processID) else {
            throw ProbeError.unsafeWindow("the current focused application is unavailable")
        }
        let previousProcessID = focusBorrow.previousProcessID
        defer { focusBorrow.restore() }
        let activation = ForegroundApplicationActivation.request(
            target, options: [.activateAllWindows], expectedCurrentProcessID: previousProcessID
        )
        try await Task.sleep(for: .milliseconds(350))
        let afterActivation = ForegroundApplicationFocus.currentApplication?.processIdentifier
        let restoration = focusBorrow.restore()
        try await Task.sleep(for: .milliseconds(350))
        let afterRestoration = ForegroundApplicationFocus.currentApplication?.processIdentifier
        let report = FocusCheckReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            windowID: window.windowID,
            previousProcessID: previousProcessID,
            targetProcessID: processID,
            activation: activation,
            frontmostProcessIDAfterActivation: afterActivation,
            restoration: restoration,
            frontmostProcessIDAfterRestoration: afterRestoration,
            targetFocusVerified: afterActivation == processID,
            restorationVerified: previousProcessID != processID
                && restoration?.accepted == true
                && afterRestoration == previousProcessID,
            inputEventsPosted: 0
        )
        try printJSON(report)
        if let output = option("--output", in: arguments) {
            try writeJSON(report, to: outputURL(for: output))
        }
        guard previousProcessID != processID else {
            throw ProbeError.unsafeWindow(
                "focus check requires another application to be frontmost before it starts"
            )
        }
        guard activation.accepted, report.targetFocusVerified, report.restorationVerified else {
            throw ProbeError.unsafeWindow("focus check could not verify activation and restoration")
        }
    }

    private static func captureCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--window-id", "--output", "--report"]
        )
        try ensureScreenCapturePermission()
        let requestedID = try optionalWindowID(arguments)
        let output = option("--output", in: arguments) ?? "captures/mirror-probe.png"
        let window = try await selectMirrorWindow(requestedID: requestedID)
        let image = try await capture(window: window)
        let metrics = try metrics(for: image)
        let imageOutputURL = try outputURL(for: output)
        try writePNG(image, to: imageOutputURL)

        let report = CaptureReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: windowReport(window),
            outputPath: imageOutputURL.path,
            imageWidth: image.width,
            imageHeight: image.height,
            metrics: metrics
        )
        try printJSON(report)

        if let reportPath = option("--report", in: arguments) {
            try writeJSON(report, to: outputURL(for: reportPath))
        }

        if metrics.isBlank {
            throw ProbeError.unsafeWindow("captured frame is blank, transparent, or nearly black")
        }
    }

    private static func analyzeFileCommand(_ arguments: [String]) throws {
        try validateOptions(
            arguments,
            valueOptions: ["--input", "--report", "--profile"]
        )
        try validateAnalysisProfile(arguments)
        guard let inputPath = option("--input", in: arguments) else {
            throw ProbeError.invalidArguments("analyze-file requires --input IMAGE.png")
        }

        let inputURL = inputFileURL(for: inputPath)
        let reportURL = try option("--report", in: arguments).map { try outputURL(for: $0) }
        try requireDistinct(inputURL, reportURL, labels: "--input and --report")

        let loadedPNG = try loadPNG(at: inputURL)
        let report = try analyze(
            image: loadedPNG.image,
            pngSHA256: loadedPNG.sha256,
            command: "analyze-file",
            source: AnalysisSourceReport(
                kind: "file",
                path: inputURL.path,
                window: nil,
                capturedImagePath: nil
            )
        )
        try printJSON(report)
        if let reportURL {
            try writeJSON(report, to: reportURL)
        }
    }

    private static func analyzeCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--window-id", "--output", "--report", "--profile"]
        )
        try validateAnalysisProfile(arguments)
        try ensureScreenCapturePermission()

        let requestedID = try optionalWindowID(arguments)
        let captureURL = try outputURL(
            for: option("--output", in: arguments) ?? "captures/analysis.png"
        )
        let reportURL = try outputURL(
            for: option("--report", in: arguments) ?? "captures/analysis-report.json"
        )
        try requireDistinct(captureURL, reportURL, labels: "--output and --report")

        let window = try await selectMirrorWindow(requestedID: requestedID)
        let image = try await capture(window: window)
        let pngSHA256 = try writePNG(image, to: captureURL)

        let report = try analyze(
            image: image,
            pngSHA256: pngSHA256,
            command: "analyze",
            source: AnalysisSourceReport(
                kind: "mirrorCapture",
                path: nil,
                window: windowReport(window),
                capturedImagePath: captureURL.path
            )
        )
        try printJSON(report)
        try writeJSON(report, to: reportURL)
    }

    private static func analyze(
        image: CGImage,
        pngSHA256: String,
        command: String,
        source: AnalysisSourceReport
    ) throws -> AnalysisReport {
        let frameMetrics = try metrics(for: image)
        let recognized: (
            observations: [OCRTextObservation],
            classification: GameStateClassification
        )
        if frameMetrics.isBlank {
            recognized = (
                observations: [],
                classification: GameStateClassifier.classify(observations: [])
            )
        } else {
            recognized = try recognizeGameState(in: image)
        }
        let observations = recognized.observations
        let classification = recognized.classification
        let status: String
        if frameMetrics.isBlank {
            status = "rejected"
        } else if classification.state == .unknown {
            status = "unknown"
        } else {
            status = "classified"
        }

        return AnalysisReport(
            schemaVersion: analysisSchemaVersion,
            profile: analysisProfileName,
            command: command,
            status: status,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            source: source,
            image: AnalysisImageReport(
                width: image.width,
                height: image.height,
                orientation: "up",
                pngSHA256: pngSHA256
            ),
            frameMetrics: frameMetrics,
            ocr: AnalysisOCRReport(
                engine: "appleVision",
                requestRevision: Int(VNRecognizeTextRequestRevision3),
                recognitionLevel: "accurate",
                languages: ["zh-Hant", "en-US"],
                usesLanguageCorrection: false,
                coordinateSpace: "normalizedTopLeft",
                observations: observations
            ),
            classification: classification,
            safety: AnalysisSafetyReport(
                readOnly: true,
                inputEventsPosted: 0,
                actionAuthorization: "none"
            )
        )
    }

    /// OCR classifies ordinary states, while calibrated modal geometry independently selects the
    /// unique/upper row. Repeat-selected results use their fixed upper continuation coordinate.
    private static func recognizeGameState(
        in image: CGImage,
        rgba suppliedRGBA: RGBAFrame? = nil
    ) throws -> (
        observations: [OCRTextObservation],
        classification: GameStateClassification
    ) {
        let rgba = try suppliedRGBA ?? rgbaFrame(from: image)
        let modalDetection = try WideModalButtonDetector.detectRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        let repeatSelectedStampDetection = try RepeatSelectedStampDetector.detectRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        let geometryModalPresent = isGeometryModalPresent(modalDetection.layout)
        let observations: [OCRTextObservation]
        if geometryModalPresent {
            // Modal handling is intentionally independent of text recognition. Preserve OCR when
            // Vision succeeds so reports remain useful, but an OCR failure must neither hide a
            // supported one/two-row modal nor let an unsupported button count reach the background.
            observations = (try? recognizeText(in: image)) ?? []
        } else {
            observations = try recognizeText(in: image)
        }
        let classification = GameStateClassifier.classify(
            observations: observations,
            repeatSelectedStampDetection: repeatSelectedStampDetection
        )

        // The calibrated modal skin is the primary signal: one row selects its only button and
        // two rows select the upper button. The same geometry is captured again before input.
        if geometryModalPresent || isWideModalActionState(classification.state)
        {
            return (
                observations,
                WideModalActionResolver.resolve(
                    classification: classification,
                    detection: modalDetection
                )
            )
        }

        if classification.state == .missionCompleteRepeatSelected
            || classification.state == .missionFailedRepeatSelected
        {
            return (
                observations,
                MissionResultTopActionResolver.resolve(classification: classification)
            )
        }

        // A low-confidence `是` or `否` can make the initial OCR classification unknown even
        // though the modal scaffold is exact. Remove only unique, valid decision observations in
        // their measured rows, reclassify the still-intact scaffold, and let the two detected
        // rectangles choose the top row. All other text, including safety conflicts, is retained.
        if let scaffoldObservations = lootConfirmationScaffoldObservations(from: observations) {
            let scaffold = GameStateClassifier.classify(
                observations: scaffoldObservations,
                repeatSelectedStampDetection: repeatSelectedStampDetection
            )
            if isWideModalActionState(scaffold.state) {
                return (
                    observations,
                    WideModalActionResolver.resolve(
                        classification: scaffold,
                        detection: modalDetection
                    )
                )
            }
        }

        // A whole-frame action has already passed every classifier guard, so supplemental OCR
        // must not replace or reinterpret it.
        if !classification.allowedActions.isEmpty {
            return (observations, classification)
        }

        return (observations, classification)
    }

    private static func isWideModalActionState(_ state: GameState) -> Bool {
        switch state {
        case .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt,
             .lootCollectionConfirmation, .adventurerRecruitment, .retreatConfirmation:
            true
        default:
            false
        }
    }

    private static func isGeometryModalPresent(_ layout: WideModalLayout) -> Bool {
        switch layout {
        case .oneButton, .twoButtons, .returnedPartyManualStop, .unsupportedButtonCount:
            return true
        case .none:
            return false
        }
    }

    private static func lootConfirmationScaffoldObservations(
        from observations: [OCRTextObservation]
    ) -> [OCRTextObservation]? {
        let yesCandidates = observations.filter {
            canonicalDecisionText($0.text) == "是"
        }
        let noCandidates = observations.filter {
            canonicalDecisionText($0.text) == "否"
        }
        guard yesCandidates.count <= 1,
              noCandidates.count <= 1,
              yesCandidates.allSatisfy({ isValidWholeFrameLootDecision($0, expected: "是") }),
              noCandidates.allSatisfy({ isValidWholeFrameLootDecision($0, expected: "否") })
        else {
            return nil
        }

        return observations.filter {
            !isExactLootConfirmationDecision($0)
        }
    }

    private static func isExactLootConfirmationDecision(
        _ observation: OCRTextObservation
    ) -> Bool {
        let text = canonicalDecisionText(observation.text)
        return text == "是" || text == "否"
    }

    private static func isValidWholeFrameLootDecision(
        _ observation: OCRTextObservation,
        expected: String
    ) -> Bool {
        guard canonicalDecisionText(observation.text) == expected,
              observation.rect.isValid,
              observation.confidence.isFinite,
              (0...1).contains(observation.confidence)
        else {
            return false
        }

        let center = observation.rect.center
        guard (0.45...0.55).contains(center.x) else {
            return false
        }
        switch expected {
        case "是":
            return (0.51...0.55).contains(center.y)
        case "否":
            return (0.55...0.60).contains(center.y)
        default:
            return false
        }
    }

    private static func canonicalDecisionText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func recognizeText(
        in image: CGImage,
        regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        minimumTextHeight: Float = 0.01,
        languages: [String] = ["zh-Hant", "en-US"]
    ) throws -> [OCRTextObservation] {
        let revision = VNRecognizeTextRequestRevision3
        do {
            let request = VNRecognizeTextRequest()
            request.revision = revision
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = false
            request.minimumTextHeight = minimumTextHeight
            request.regionOfInterest = regionOfInterest
            let supported: [String]
            do {
                supported = try request.supportedRecognitionLanguages()
            } catch {
                throw ProbeError.textRecognitionFailed(
                    "supported-language query failed: \(diagnosticDescription(error))"
                )
            }
            guard languages.allSatisfy(supported.contains) else {
                throw ProbeError.textRecognitionFailed(
                    "the \(analysisProfileName) languages are not supported by this Vision revision"
                )
            }

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw ProbeError.textRecognitionFailed(
                    "request execution failed: \(diagnosticDescription(error))"
                )
            }

            var observations = (request.results ?? []).compactMap { result -> OCRTextObservation? in
                guard let candidate = result.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }
                // Vision reports OCR boxes relative to `regionOfInterest`, not the source image.
                // Convert them back to the full-frame normalized coordinate space used by the
                // classifier and click safety checks.
                let regionBox = result.boundingBox
                let box = CGRect(
                    x: regionOfInterest.minX + regionBox.minX * regionOfInterest.width,
                    y: regionOfInterest.minY + regionBox.minY * regionOfInterest.height,
                    width: regionBox.width * regionOfInterest.width,
                    height: regionBox.height * regionOfInterest.height
                )
                return OCRTextObservation(
                    text: text,
                    rect: NormalizedRect(
                        x: normalizedVisionValue(box.minX),
                        y: normalizedVisionValue(1 - box.maxY),
                        width: normalizedVisionValue(box.width),
                        height: normalizedVisionValue(box.height)
                    ),
                    confidence: Double(candidate.confidence)
                )
            }
            observations.sort { lhs, rhs in
                if lhs.rect.y != rhs.rect.y {
                    return lhs.rect.y < rhs.rect.y
                }
                if lhs.rect.x != rhs.rect.x {
                    return lhs.rect.x < rhs.rect.x
                }
                return lhs.text < rhs.text
            }
            return observations
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError.textRecognitionFailed(error.localizedDescription)
        }
    }

    private static func normalizedVisionValue(_ value: CGFloat) -> Double {
        let converted = Double(value)
        if converted < 0, converted >= -0.000_001 {
            return 0
        }
        if converted > 1, converted <= 1.000_001 {
            return 1
        }
        return converted
    }

    private static func diagnosticDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
    }

    private static func loadPNG(at url: URL) throws -> LoadedPNG {
        do {
            let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    return -1
                }
                return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw ProbeError.imageLoadFailed(
                    "could not open a readable regular PNG without following a symbolic link"
                )
            }
            defer { _ = Darwin.close(descriptor) }

            var fileStatus = stat()
            guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
                throw ProbeError.imageLoadFailed("could not inspect the opened PNG")
            }
            guard fileStatus.st_mode & S_IFMT == S_IFREG else {
                throw ProbeError.imageLoadFailed("the opened input is not a regular file")
            }
            let encodedSize = fileStatus.st_size
            guard encodedSize > 0, encodedSize <= maximumPNGByteCount else {
                throw ProbeError.imageLoadFailed("PNG must be between 1 byte and 50 MiB")
            }

            let encodedData = try readBounded(
                descriptor: descriptor,
                maximumByteCount: maximumPNGByteCount
            )
            guard encodedData.count <= maximumPNGByteCount else {
                throw ProbeError.imageLoadFailed("PNG must not exceed 50 MiB")
            }
            guard Int64(encodedData.count) == encodedSize else {
                throw ProbeError.imageLoadFailed("the PNG changed while it was being read")
            }
            let encodedSHA256 = sha256Hex(of: encodedData)
            guard let source = CGImageSourceCreateWithData(encodedData as CFData, nil) else {
                throw ProbeError.imageLoadFailed("the file is not a supported image source")
            }
            guard CGImageSourceGetCount(source) == 1 else {
                throw ProbeError.imageLoadFailed("exactly one image is required")
            }
            guard (CGImageSourceGetType(source) as String?) == UTType.png.identifier else {
                throw ProbeError.imageLoadFailed("only PNG input is accepted")
            }

            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
                  let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else {
                throw ProbeError.imageLoadFailed("PNG dimensions are missing")
            }
            let pixelWidth = widthNumber.int64Value
            let pixelHeight = heightNumber.int64Value
            guard pixelWidth > 0,
                  pixelHeight > 0,
                  pixelWidth <= 10_000,
                  pixelHeight <= 10_000,
                  pixelWidth * pixelHeight <= 25_000_000
            else {
                throw ProbeError.imageLoadFailed(
                    "PNG dimensions must be at most 10,000 pixels per side and 25 megapixels"
                )
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            guard orientation == 1 else {
                throw ProbeError.imageLoadFailed("PNG orientation metadata must be up (1)")
            }
            guard let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) else {
                throw ProbeError.imageLoadFailed("PNG decoding failed")
            }
            guard Int64(image.width) == pixelWidth, Int64(image.height) == pixelHeight else {
                throw ProbeError.imageLoadFailed("decoded PNG dimensions do not match its properties")
            }
            return LoadedPNG(image: image, sha256: encodedSHA256)
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError.imageLoadFailed(error.localizedDescription)
        }
    }

    private static func readBounded(
        descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        let bufferCapacity = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, bufferCapacity))

        while data.count <= maximumByteCount {
            let remainingCapacity = maximumByteCount + 1 - data.count
            let requestedCount = min(bufferCapacity, remainingCapacity)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ProbeError.imageLoadFailed("could not read the opened PNG")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func inputFileURL(for path: String) -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
        }
        return url.standardizedFileURL
    }

    private static func validateAnalysisProfile(_ arguments: [String]) throws {
        guard let profile = option("--profile", in: arguments) else {
            return
        }
        guard profile == analysisProfileName else {
            throw ProbeError.invalidArguments(
                "--profile must be \(analysisProfileName); confidence thresholds cannot be lowered"
            )
        }
    }

    private static func requireDistinct(
        _ lhs: URL,
        _ rhs: URL?,
        labels: String
    ) throws {
        guard let rhs else {
            return
        }
        let lhsPath = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let rhsPath = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        guard lhsPath != rhsPath else {
            throw ProbeError.invalidArguments("\(labels) must refer to different files")
        }
    }

    private static func clickCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--window-id", "--x", "--y", "--confirm", "--output-dir", "--report"]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()

        guard option("--confirm", in: arguments) == singleClickConfirmation else {
            throw ProbeError.invalidArguments(
                "click requires --confirm \(singleClickConfirmation); exactly one mouse-down/up pair will be sent"
            )
        }
        guard let requestedID = try optionalWindowID(arguments) else {
            throw ProbeError.invalidArguments("click requires --window-id from a successful capture report")
        }
        let normalizedX = try requiredNormalizedCoordinate("--x", in: arguments)
        let normalizedY = try requiredNormalizedCoordinate("--y", in: arguments)
        let outputDirectory = option("--output-dir", in: arguments) ?? "captures/click-test"

        var window = try await selectMirrorWindow(requestedID: requestedID)
        let initialFrame = window.frame
        let beforeImage = try await capture(window: window)
        let beforeMetrics = try metrics(for: beforeImage)
        guard !beforeMetrics.isBlank else {
            throw ProbeError.unsafeWindow("pre-click frame is blank, transparent, or nearly black")
        }

        let directoryURL = try outputURL(for: outputDirectory, isDirectory: true)
        let beforeURL = directoryURL.appendingPathComponent("before.png")
        let afterURL = directoryURL.appendingPathComponent("after.png")
        try writePNG(beforeImage, to: beforeURL)

        guard let app = window.owningApplication,
              let runningApplication = NSRunningApplication(processIdentifier: app.processID)
        else {
            throw ProbeError.unsafeWindow("could not resolve the owning iPhone Mirroring application")
        }

        guard var focusBorrow = ForegroundFocusBorrow(targetProcessID: app.processID) else {
            throw ProbeError.unsafeWindow("the current focused application is unavailable")
        }
        defer { focusBorrow.restore() }
        if ForegroundApplicationFocus.currentApplication?.processIdentifier != app.processID {
            _ = ForegroundApplicationActivation.request(
                runningApplication, options: [.activateAllWindows],
                expectedCurrentProcessID: focusBorrow.previousProcessID
            )
            try await Task.sleep(for: .milliseconds(350))
        }

        window = try await selectMirrorWindow(requestedID: requestedID)
        guard approximatelyEqual(window.frame, initialFrame, tolerance: 0.5) else {
            throw ProbeError.unsafeWindow("the window moved or resized after the pre-click capture")
        }
        guard window.isActive else {
            throw ProbeError.unsafeWindow("the requested iPhone Mirroring window is not active")
        }
        guard ForegroundApplicationFocus.currentApplication?.processIdentifier == app.processID else {
            throw ProbeError.unsafeWindow("iPhone Mirroring could not be made the frontmost application")
        }

        let clickPoint = CGPoint(
            x: window.frame.minX + window.frame.width * normalizedX,
            y: window.frame.minY + window.frame.height * normalizedY
        )
        guard let topmost = topmostInputWindow(
            at: clickPoint,
            expectedWindowFrame: window.frame,
            expectedProcessID: app.processID
        ) else {
            throw ProbeError.unsafeWindow("could not identify the topmost window at the requested click point")
        }
        guard topmost.identity.windowID == requestedID,
              topmost.identity.processID == app.processID
        else {
            throw ProbeError.unsafeWindow(
                "window ID \(topmost.identity.windowID) is above the requested click point"
            )
        }

        let previousMouseLocation = CGEvent(source: nil)?.location
        _ = try postSingleClick(at: clickPoint)
        if let previousMouseLocation {
            CGWarpMouseCursorPosition(previousMouseLocation)
        }
        focusBorrow.restore()

        try await Task.sleep(for: .seconds(1))
        let afterWindow = try await selectMirrorWindow(requestedID: requestedID)
        let afterImage = try await capture(window: afterWindow)
        let afterMetrics = try metrics(for: afterImage)
        try writePNG(afterImage, to: afterURL)

        let difference: Double?
        if beforeImage.width == afterImage.width, beforeImage.height == afterImage.height {
            let beforeFrame = try rgbaFrame(from: beforeImage)
            let afterFrame = try rgbaFrame(from: afterImage)
            difference = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                beforeFrame.bytes,
                afterFrame.bytes,
                width: beforeFrame.width,
                height: beforeFrame.height,
                bytesPerRow: beforeFrame.bytesPerRow
            )
        } else {
            difference = nil
        }

        let report = ClickReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: windowReport(afterWindow),
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            screenX: clickPoint.x,
            screenY: clickPoint.y,
            beforePath: beforeURL.path,
            afterPath: afterURL.path,
            beforeMetrics: beforeMetrics,
            afterMetrics: afterMetrics,
            meanAbsoluteDifference: difference
        )
        try printJSON(report)

        if let reportPath = option("--report", in: arguments) {
            try writeJSON(report, to: outputURL(for: reportPath))
        }
    }

    private static func characterRerollCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: [
                "--window-id", "--confirm", "--minimum-total", "--max-rerolls",
                "--max-minutes", "--stop-file", "--report",
            ]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()

        guard option("--confirm", in: arguments) == characterRerollConfirmation else {
            throw ProbeError.invalidArguments(
                "reroll-character requires --confirm \(characterRerollConfirmation); only the "
                    + "verified top-right Random control may be pressed"
            )
        }
        let requestedID = try optionalWindowID(arguments)
        let minimumTotal = try boundedIntegerOption(
            "--minimum-total",
            in: arguments,
            defaultValue: 90,
            range: CharacterRerollDetector.supportedMinimumTotalRange
        )
        let maximumRerolls = try boundedIntegerOption(
            "--max-rerolls",
            in: arguments,
            defaultValue: 500,
            range: 1...5_000
        )
        let maximumMinutes = try boundedDoubleOption(
            "--max-minutes",
            in: arguments,
            defaultValue: 10,
            range: 0.1...60
        )
        let reportURL = try option("--report", in: arguments).map {
            try outputURL(for: $0)
        }
        let stopURL = option("--stop-file", in: arguments).map(inputFileURL)
        let limits = CharacterRerollLimitsReport(
            minimumTotal: minimumTotal,
            maximumRerolls: maximumRerolls,
            maximumMinutes: maximumMinutes
        )

        let startedDate = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sessionDeadline = startedAt + maximumMinutes * 60
        guard sessionDeadline.isFinite else {
            throw ProbeError.invalidArguments("--max-minutes produced an invalid deadline")
        }

        let initialWindow = try await selectMirrorWindow(requestedID: requestedID)
        guard let application = initialWindow.owningApplication,
              application.processID > 0,
              let runningApplication = NSRunningApplication(
                  processIdentifier: application.processID
              )
        else {
            throw ProbeError.unsafeWindow("could not resolve the iPhone Mirroring process")
        }
        let identity = AutoLevelWindowIdentity(
            processID: application.processID,
            windowID: initialWindow.windowID
        )
        let initialFrame = initialWindow.frame
        let windowRunLock = try AutoLevelWindowRunLock.acquire(for: identity)
        defer { windowRunLock.release() }

        let initialStability = await stableCharacterRerollObservation(
            requestedID: identity.windowID,
            expectedIdentity: identity,
            expectedFrame: initialFrame,
            minimumTotal: minimumTotal,
            sessionDeadline: sessionDeadline,
            stabilityTimeout: 5,
            stopURL: stopURL
        )
        let initialObservation: CharacterRerollObservation
        switch initialStability {
        case let .stable(observation):
            initialObservation = observation
        case let .ended(latest, keeperOrConflictWasObserved, endReason):
            let status: String
            let reportReason: String
            let terminalMessage: String?
            switch endReason {
            case .stopRequested:
                status = "stopped"
                reportReason = "stopFileDetected"
                terminalMessage = nil
            case .maximumRuntimeReached:
                status = "limitReached"
                reportReason = "maximumRuntimeReached"
                terminalMessage = "the character reroll runtime limit was reached during initial "
                    + "stability checks"
            case let .failed(message):
                status = "error"
                reportReason = message
                terminalMessage = message
            }
            try emitCharacterRerollReport(
                status: status,
                reason: reportReason,
                startedDate: startedDate,
                window: latest?.window ?? initialWindow,
                limits: limits,
                initialTotal: latest.flatMap(characterRerollUnambiguousTotal),
                finalTotal: latest.flatMap(characterRerollUnambiguousTotal),
                rerollsPosted: 0,
                reportURL: reportURL,
                candidateObservation: latest,
                candidateRole: latest == nil ? nil : .latestPreClickUnverified,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved
            )
            if let terminalMessage {
                throw CharacterRerollTerminalError(message: terminalMessage)
            }
            return
        }
        guard let initialTotal = characterRerollTotal(initialObservation.decision) else {
            throw ProbeError.unsafeWindow("the initial character total was unavailable")
        }

        var current = initialObservation
        var rerollsPosted = 0
        var terminalReportWasEmitted = false
        var candidateRole = CharacterRerollCandidateRole.lastVerifiedStable
        var keeperOrConflictWasObserved = false

        try emitCharacterRerollReport(
            status: "running",
            reason: "sessionStarted",
            startedDate: startedDate,
            window: current.window,
            limits: limits,
            initialTotal: initialTotal,
            finalTotal: initialTotal,
            rerollsPosted: rerollsPosted,
            reportURL: reportURL,
            printToStandardOutput: false
        )

        do {
            characterLoop: while true {
            if characterRerollStopRequested(stopURL) {
                try emitCharacterRerollReport(
                    status: "stopped",
                    reason: "stopFileDetected",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current
                )
                terminalReportWasEmitted = true
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard now < sessionDeadline else {
                try emitCharacterRerollReport(
                    status: "limitReached",
                    reason: "maximumRuntimeReached",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current
                )
                terminalReportWasEmitted = true
                throw ProbeError.unsafeWindow(
                    "the character reroll runtime limit was reached before total "
                        + "\(minimumTotal)"
                )
            }

            switch current.decision {
            case .thresholdReached:
                try emitCharacterRerollReport(
                    status: "completed",
                    reason: "minimumTotalReached",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current
                )
                terminalReportWasEmitted = true
                return

            case let .unsafe(reason):
                throw ProbeError.unsafeWindow(
                    "the custom-character snapshot became unsafe (\(reason.rawValue))"
                )

            case .rerollRequired:
                break
            }

            guard rerollsPosted < maximumRerolls else {
                try emitCharacterRerollReport(
                    status: "limitReached",
                    reason: "maximumRerollsReached",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current
                )
                terminalReportWasEmitted = true
                throw ProbeError.unsafeWindow(
                    "the maximum of \(maximumRerolls) rerolls was reached before total "
                        + "\(minimumTotal)"
                )
            }

            let authorizedObservation = current
            var activationRetry = AutoLevelForegroundActivationRetryState()

            activationLoop: while true {
                guard var focusBorrow = ForegroundFocusBorrow(targetProcessID: identity.processID) else {
                    throw ProbeError.unsafeWindow("the current focused application is unavailable")
                }
                defer { focusBorrow.restore() }
                let alreadyFrontmost = ForegroundApplicationFocus.currentApplication?
                    .processIdentifier == identity.processID
                let activateReturned: Bool? = alreadyFrontmost
                    ? nil
                    : ForegroundApplicationActivation.request(
                        runningApplication, options: [.activateAllWindows],
                        expectedCurrentProcessID: focusBorrow.previousProcessID
                    ).accepted
                if !alreadyFrontmost {
                    try await Task.sleep(
                        for: .milliseconds(activationRetry.settleDelayMilliseconds)
                    )
                }

                if characterRerollStopRequested(stopURL) {
                    continue characterLoop
                }

                let preflightStability = await stableCharacterRerollObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: initialFrame,
                    minimumTotal: minimumTotal,
                    sessionDeadline: sessionDeadline,
                    stabilityTimeout: 3,
                    stopURL: stopURL
                )
                let preflight: CharacterRerollObservation
                switch preflightStability {
                case let .stable(observation):
                    preflight = observation
                case let .ended(latest, boundaryWasObserved, endReason):
                    keeperOrConflictWasObserved = boundaryWasObserved
                    if let latest {
                        current = latest
                        candidateRole = .latestPreClickUnverified
                    }
                    switch endReason {
                    case .stopRequested:
                        throw CharacterRerollInterruption.stopRequested
                    case .maximumRuntimeReached:
                        throw CharacterRerollInterruption.maximumRuntimeReached
                    case let .failed(message):
                        throw CharacterRerollTerminalError(message: message)
                    }
                }
                // Keeper or ambiguous boundary evidence must leave the entire activation retry
                // loop immediately. Otherwise a transient focus failure could discard this frame
                // and let a later low OCR sample revive the old authorization.
                guard preflight.boundaryEvidence == .belowThreshold,
                      case .rerollRequired = preflight.decision
                else {
                    current = preflight
                    continue characterLoop
                }
                current = preflight
                candidateRole = .lastVerifiedStable
                let focusReady = AutoLevelForegroundActivationRetryState.activationIsReady(
                    activateReturned: activateReturned ?? false,
                    targetApplicationIsActive: runningApplication.isActive,
                    frontmostProcessMatches: ForegroundApplicationFocus.currentApplication?
                        .processIdentifier == identity.processID
                )
                guard focusReady else {
                    focusBorrow.restore()
                    switch activationRetry.recordUnpostedFocusFailure() {
                    case let .retry(_, delayMilliseconds):
                        try await Task.sleep(for: .milliseconds(delayMilliseconds))
                        continue activationLoop
                    case let .exhausted(attempts):
                        throw ProbeError.unsafeWindow(
                            "iPhone Mirroring could not be kept frontmost after \(attempts) attempts"
                        )
                    }
                }

                guard characterRerollRoll(preflight.decision)
                    == characterRerollRoll(authorizedObservation.decision),
                    try characterRerollFramesAreQuiescent(
                        authorizedObservation.rgba,
                        preflight.rgba
                    )
                else {
                    // The user or game changed the generated result after authorization. The
                    // fresh stable snapshot becomes the next observation; no stale click is sent.
                    current = preflight
                    continue characterLoop
                }
                guard case let .rerollRequired(_, authorizedTarget) =
                    authorizedObservation.decision,
                    case let .rerollRequired(_, confirmedTarget) = preflight.decision,
                    characterRerollTargetsMatch(authorizedTarget, confirmedTarget)
                else {
                    current = preflight
                    continue characterLoop
                }

                // Take one last content snapshot after activation and immediately before the
                // synchronous input boundary. It must still be the exact same low roll and target;
                // any keeper, ambiguity, or unrelated page change cancels the stale authorization.
                let finalObservation = try await captureCharacterRerollObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: initialFrame,
                    minimumTotal: minimumTotal
                )
                guard characterRerollStableDecisionsMatch(
                    preflight.decision,
                    finalObservation.decision
                ),
                    finalObservation.boundaryEvidence == .belowThreshold,
                    try characterRerollFramesAreQuiescent(
                        preflight.rgba,
                        finalObservation.rgba
                    ),
                    case let .rerollRequired(_, finalTarget) = finalObservation.decision,
                    characterRerollTargetsMatch(confirmedTarget, finalTarget)
                else {
                    current = finalObservation
                    candidateRole = .latestPreClickUnverified
                    throw CharacterRerollTerminalError(
                        message: "the final pre-click content changed or became ambiguous; no "
                            + "input was posted"
                    )
                }
                current = finalObservation
                candidateRole = .lastVerifiedStable

                // ScreenCaptureKit has no supported synchronous one-shot capture on macOS 15.
                // Use a final pixel-only guard and bind the event deadline to the start of that
                // capture, limiting the remaining non-atomic compositor-to-event window to 0.5 s.
                let pixelGuardStartedAt = ProcessInfo.processInfo.systemUptime
                let pixelGuardImage = try await capture(window: finalObservation.window)
                let pixelGuardFrame = try rgbaFrame(from: pixelGuardImage)
                guard try characterRerollInputSurfaceFramesAreQuiescent(
                    finalObservation.rgba,
                    pixelGuardFrame
                ) else {
                    current = CharacterRerollObservation(
                        capturedAt: pixelGuardStartedAt,
                        window: finalObservation.window,
                        decision: .unsafe(reason: .invalidObservation),
                        boundaryEvidence: .unavailable,
                        credibleFullFrameTotals: [],
                        credibleFocusedTotals: [],
                        fullFrameWasContaminated: false,
                        focusedWasContaminated: false,
                        fullFrameTotal: nil,
                        focusedTotal: nil,
                        renderedDigitCount: nil,
                        image: pixelGuardImage,
                        rgba: pixelGuardFrame
                    )
                    candidateRole = .latestPreClickUnverified
                    throw CharacterRerollTerminalError(
                        message: "the final pixel guard saw the page or Random control change; "
                            + "no input was posted"
                    )
                }

                let clickResult = try postCharacterRerollClick(
                    target: finalTarget,
                    observation: finalObservation,
                    identity: identity,
                    expectedFrame: initialFrame,
                    actionDeadline: pixelGuardStartedAt + 0.5,
                    sessionDeadline: sessionDeadline,
                    stopURL: stopURL
                )
                // Observe the result in the background; do not hold focus through the
                // acknowledgement/stabilization wait or report persistence.
                focusBorrow.restore()
                switch clickResult {
                case .posted:
                    let postedAt = ProcessInfo.processInfo.systemUptime
                    rerollsPosted += 1
                    candidateRole = .preClickFallback
                    try emitCharacterRerollReport(
                        status: "running",
                        reason: "awaitingRerollAcknowledgement",
                        startedDate: startedDate,
                        window: finalObservation.window,
                        limits: limits,
                        initialTotal: initialTotal,
                        finalTotal: characterRerollTotal(finalObservation.decision),
                        rerollsPosted: rerollsPosted,
                        reportURL: reportURL,
                        printToStandardOutput: false
                    )
                    let acknowledgement = await awaitCharacterRerollAcknowledgement(
                        previousObservation: finalObservation,
                        postedAt: postedAt,
                        requestedID: identity.windowID,
                        expectedIdentity: identity,
                        expectedFrame: initialFrame,
                        minimumTotal: minimumTotal,
                        sessionDeadline: sessionDeadline,
                        acknowledgementTimeout: 10,
                        stopURL: stopURL
                    )
                    switch acknowledgement {
                    case let .acknowledged(observation):
                        current = observation
                        candidateRole = .lastVerifiedStable
                        continue characterLoop
                    case let .ended(latestPostClick, boundaryWasObserved, reason):
                        keeperOrConflictWasObserved = boundaryWasObserved
                        if let latestPostClick {
                            current = latestPostClick
                            candidateRole = .latestPostClickUnverified
                        } else {
                            current = finalObservation
                            candidateRole = .preClickFallback
                        }
                        switch reason {
                        case .stopRequested:
                            throw CharacterRerollInterruption.stopRequested
                        case .maximumRuntimeReached:
                            throw CharacterRerollInterruption.maximumRuntimeReached
                        case let .failed(message):
                            throw CharacterRerollTerminalError(message: message)
                        }
                    }

                case .focusContended:
                    switch activationRetry.recordUnpostedFocusFailure() {
                    case let .retry(_, delayMilliseconds):
                        try await Task.sleep(for: .milliseconds(delayMilliseconds))
                        continue activationLoop
                    case let .exhausted(attempts):
                        throw ProbeError.unsafeWindow(
                            "iPhone Mirroring lost focus before input on all \(attempts) attempts"
                        )
                    }

                case .stopRequested:
                    current = finalObservation
                    continue characterLoop

                case .maximumRuntimeReached:
                    current = finalObservation
                    continue characterLoop
                }
            }
            }
        } catch CharacterRerollInterruption.stopRequested {
            try emitCharacterRerollReport(
                status: "stopped",
                reason: "stopFileDetected",
                startedDate: startedDate,
                window: current.window,
                limits: limits,
                initialTotal: initialTotal,
                finalTotal: characterRerollUnambiguousTotal(current),
                rerollsPosted: rerollsPosted,
                reportURL: reportURL,
                candidateObservation: current,
                candidateRole: candidateRole,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved
            )
            return
        } catch CharacterRerollInterruption.maximumRuntimeReached {
            try emitCharacterRerollReport(
                status: "limitReached",
                reason: "maximumRuntimeReached",
                startedDate: startedDate,
                window: current.window,
                limits: limits,
                initialTotal: initialTotal,
                finalTotal: characterRerollUnambiguousTotal(current),
                rerollsPosted: rerollsPosted,
                reportURL: reportURL,
                candidateObservation: current,
                candidateRole: candidateRole,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved
            )
            throw ProbeError.unsafeWindow(
                "the character reroll runtime limit was reached before total \(minimumTotal)"
            )
        } catch {
            if !terminalReportWasEmitted {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                try? emitCharacterRerollReport(
                    status: "error",
                    reason: reason,
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current,
                    candidateRole: candidateRole,
                    keeperOrConflictWasObserved: keeperOrConflictWasObserved
                )
            }
            throw error
        }
    }

    private static func captureCharacterRerollObservation(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        minimumTotal: Int
    ) async throws -> CharacterRerollObservation {
        let window = try await selectMirrorWindow(requestedID: requestedID)
        guard let application = window.owningApplication,
              application.processID == expectedIdentity.processID,
              window.windowID == expectedIdentity.windowID
        else {
            throw ProbeError.unsafeWindow("the iPhone Mirroring process or window identity changed")
        }
        guard approximatelyEqual(window.frame, expectedFrame, tolerance: 0.5) else {
            throw ProbeError.unsafeWindow(
                "the iPhone Mirroring window moved or resized during character reroll"
            )
        }

        // The authorization age starts before ScreenCaptureKit reads the pixels. Measuring it
        // after Vision completes would make an old frame appear artificially fresh under load.
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        let image = try await capture(window: window)
        let rgba = try rgbaFrame(from: image)
        let frameMetrics = try FrameAnalyzer.analyzeRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        guard !frameMetrics.isBlank else {
            throw ProbeError.unsafeWindow(
                "the character-reroll capture was blank, transparent, or nearly black"
            )
        }
        let observations = try recognizeText(in: image)
        let fullFrameResolution = CharacterFullFrameTotalResolver.resolve(
            observations: observations
        )
        let credibleFullFrameTotals: [Int]
        let fullFrameTotal: Int?
        let fullFrameWasContaminated: Bool
        switch fullFrameResolution {
        case let .exact(read):
            credibleFullFrameTotals = [read.value]
            fullFrameTotal = read.value
            fullFrameWasContaminated = false
        case let .contaminated(reads):
            credibleFullFrameTotals = reads.map(\.value)
            fullFrameTotal = nil
            fullFrameWasContaminated = true
        case .unavailable:
            credibleFullFrameTotals = []
            fullFrameTotal = nil
            fullFrameWasContaminated = false
        }
        // These independent reads run for every nonblank frame, even if an unrelated page anchor
        // fails. A credible high result therefore reaches the sticky boundary latch on its own.
        let focusedResolution = (try? focusedCharacterRerollTotalResolution(in: image))
            ?? .unavailable
        let credibleFocusedTotals: [Int]
        let focusedRead: CharacterFocusedTotalRead?
        let focusedWasContaminated: Bool
        switch focusedResolution {
        case let .exact(read):
            credibleFocusedTotals = [read.value]
            focusedRead = read
            focusedWasContaminated = false
        case let .contaminated(reads):
            credibleFocusedTotals = reads.map(\.value)
            focusedRead = nil
            focusedWasContaminated = true
        case .unavailable:
            credibleFocusedTotals = []
            focusedRead = nil
            focusedWasContaminated = false
        }
        let renderedDigitDetection = CharacterTotalDigitDetector.detectRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        let renderedDigitCount: Int?
        switch renderedDigitDetection {
        case let .digitCount(count):
            renderedDigitCount = count
        case .boundaryAmbiguous, .unsafe:
            renderedDigitCount = nil
        }
        let boundaryEvidence = CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: fullFrameResolution,
            focused: focusedResolution,
            renderedDigitDetection: renderedDigitDetection,
            minimumTotal: minimumTotal
        )
        var decision = CharacterRerollDetector.detect(
            observations: observations,
            minimumTotal: minimumTotal
        )
        switch decision {
        case .rerollRequired where boundaryEvidence != .belowThreshold:
            decision = .unsafe(
                reason: boundaryEvidence == .boundaryConflict
                    ? .totalBoundaryConflict
                    : renderedDigitCount == nil && focusedRead != nil
                        ? .totalGlyphDetectionFailed
                        : .totalCorroborationMismatch
            )
        case .thresholdReached where boundaryEvidence != .thresholdReached:
            decision = .unsafe(
                reason: boundaryEvidence == .boundaryConflict
                    ? .totalBoundaryConflict
                    : .totalCorroborationMismatch
            )
        default:
            break
        }
        return CharacterRerollObservation(
            capturedAt: captureStartedAt,
            window: window,
            decision: decision,
            boundaryEvidence: boundaryEvidence,
            credibleFullFrameTotals: credibleFullFrameTotals,
            credibleFocusedTotals: credibleFocusedTotals,
            fullFrameWasContaminated: fullFrameWasContaminated,
            focusedWasContaminated: focusedWasContaminated,
            fullFrameTotal: fullFrameTotal,
            focusedTotal: focusedRead?.value,
            renderedDigitCount: renderedDigitCount,
            image: image,
            rgba: rgba
        )
    }

    /// A focused Vision request presents only the total area. It must agree with full-frame OCR
    /// on digit count; rendered pixels independently guard the two-to-three digit boundary.
    private static func focusedCharacterRerollTotalResolution(
        in image: CGImage
    ) throws -> CharacterFocusedTotalResolution {
        let totalRegion = CGRect(x: 0.72, y: 0.64, width: 0.27, height: 0.08)
        let observations = try recognizeText(
            in: image,
            regionOfInterest: totalRegion,
            minimumTextHeight: 0.01,
            languages: ["en-US"]
        )
        return CharacterFocusedTotalResolver.resolveEvidence(observations: observations)
    }

    private static func stableCharacterRerollObservation(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        minimumTotal: Int,
        sessionDeadline: TimeInterval,
        stabilityTimeout: TimeInterval,
        stopURL: URL?
    ) async -> CharacterRerollStabilityOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = min(sessionDeadline, startedAt + stabilityTimeout)
        var prior: CharacterRerollObservation?
        var latest: CharacterRerollObservation?
        var lastUnsafeReason: CharacterRerollUnsafeReason?
        var boundaryLatch = CharacterTotalBoundaryLatch()
        var keeperOrConflictWasObserved = false

        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if characterRerollStopRequested(stopURL) {
                    throw CharacterRerollInterruption.stopRequested
                }
                if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                    throw CharacterRerollInterruption.maximumRuntimeReached
                }
                let observation = try await captureCharacterRerollObservation(
                    requestedID: requestedID,
                    expectedIdentity: expectedIdentity,
                    expectedFrame: expectedFrame,
                    minimumTotal: minimumTotal
                )
                // Keep the latest screen before a boundary latch or stability comparison can stop
                // the routine, so callers can persist the actual terminal evidence.
                latest = observation
                if observation.boundaryEvidence == .thresholdReached
                    || observation.boundaryEvidence == .boundaryConflict
                {
                    keeperOrConflictWasObserved = true
                }
                if boundaryLatch.observe(observation.boundaryEvidence) == .terminalVeto {
                    throw ProbeError.unsafeWindow(
                        "conflicting total evidence reached or obscured the configured boundary; "
                            + "the snapshot is terminal and will not be retried"
                    )
                }
                switch observation.decision {
                case let .unsafe(reason):
                    lastUnsafeReason = reason
                    prior = nil
                case .rerollRequired:
                    if let prior,
                       characterRerollStableDecisionsMatch(
                           prior.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(prior.rgba, observation.rgba)
                    {
                        return .stable(observation)
                    }
                    prior = observation
                case .thresholdReached:
                    if let prior,
                       characterRerollStableDecisionsMatch(
                           prior.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(prior.rgba, observation.rgba)
                    {
                        return .stable(observation)
                    }
                    prior = observation
                }
                try await Task.sleep(for: .milliseconds(250))
            }

            if characterRerollStopRequested(stopURL) {
                throw CharacterRerollInterruption.stopRequested
            }
            if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                throw CharacterRerollInterruption.maximumRuntimeReached
            }
            let suffix = lastUnsafeReason.map { " (last detector result: \($0.rawValue))" } ?? ""
            throw ProbeError.unsafeWindow(
                "the custom-character page did not produce two matching safe snapshots\(suffix)"
            )
        } catch CharacterRerollInterruption.stopRequested {
            return .ended(
                latest: latest,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .stopRequested
            )
        } catch CharacterRerollInterruption.maximumRuntimeReached {
            return .ended(
                latest: latest,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .maximumRuntimeReached
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .ended(
                latest: latest,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .failed(message)
            )
        }
    }

    private static func awaitCharacterRerollAcknowledgement(
        previousObservation: CharacterRerollObservation,
        postedAt: TimeInterval,
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        minimumTotal: Int,
        sessionDeadline: TimeInterval,
        acknowledgementTimeout: TimeInterval,
        stopURL: URL?
    ) async -> CharacterRerollAcknowledgementOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = min(sessionDeadline, startedAt + acknowledgementTimeout)
        // The local UI updates immediately in measured runs. Waiting well beyond that transition,
        // then requiring two pixel-quiescent result frames, prevents a staged name/total update
        // from authorizing the next click.
        let settleNotBefore = postedAt + 1.5
        var changedCandidate: CharacterRerollObservation?
        var latestPostClick: CharacterRerollObservation?
        var lastUnsafeReason: CharacterRerollUnsafeReason?
        var boundaryLatch = CharacterTotalBoundaryLatch()
        var keeperOrConflictWasObserved = false

        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if characterRerollStopRequested(stopURL) {
                    throw CharacterRerollInterruption.stopRequested
                }
                if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                    throw CharacterRerollInterruption.maximumRuntimeReached
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now < settleNotBefore {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let observation = try await captureCharacterRerollObservation(
                    requestedID: requestedID,
                    expectedIdentity: expectedIdentity,
                    expectedFrame: expectedFrame,
                    minimumTotal: minimumTotal
                )
                // Preserve the latest screen obtained after the posted action before any later
                // validation can terminate. Terminal reporting can then never masquerade the
                // pre-click character as the phone's latest observed state.
                latestPostClick = observation
                if observation.boundaryEvidence == .thresholdReached
                    || observation.boundaryEvidence == .boundaryConflict
                {
                    keeperOrConflictWasObserved = true
                }
                if boundaryLatch.observe(observation.boundaryEvidence) == .terminalVeto {
                    throw ProbeError.unsafeWindow(
                        "conflicting post-click total evidence reached or obscured the configured "
                            + "boundary; no further click is permitted"
                    )
                }
                switch observation.decision {
                case let .unsafe(reason):
                    lastUnsafeReason = reason
                    changedCandidate = nil
                case .rerollRequired:
                    let changeFromPreClick = try characterRerollResultDifference(
                        previousObservation.rgba,
                        observation.rgba
                    )
                    guard changeFromPreClick >= characterRerollMinimumChangedDifference else {
                        changedCandidate = nil
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if let changedCandidate,
                       characterRerollStableDecisionsMatch(
                           changedCandidate.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(
                           changedCandidate.rgba,
                           observation.rgba
                       )
                    {
                        return .acknowledged(observation)
                    }
                    changedCandidate = observation
                case .thresholdReached:
                    let changeFromPreClick = try characterRerollResultDifference(
                        previousObservation.rgba,
                        observation.rgba
                    )
                    guard changeFromPreClick >= characterRerollMinimumChangedDifference else {
                        changedCandidate = nil
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if let changedCandidate,
                       characterRerollStableDecisionsMatch(
                           changedCandidate.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(
                           changedCandidate.rgba,
                           observation.rgba
                       )
                    {
                        return .acknowledged(observation)
                    }
                    changedCandidate = observation
                }
                try await Task.sleep(for: .milliseconds(250))
            }

            if characterRerollStopRequested(stopURL) {
                throw CharacterRerollInterruption.stopRequested
            }
            if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                throw CharacterRerollInterruption.maximumRuntimeReached
            }
            let suffix = lastUnsafeReason.map { " (last detector result: \($0.rawValue))" } ?? ""
            throw ProbeError.unsafeWindow(
                "the Random click was not acknowledged by two settled, pixel-stable changed "
                    + "snapshots" + suffix
            )
        } catch CharacterRerollInterruption.stopRequested {
            return .ended(
                latestPostClick: latestPostClick,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .stopRequested
            )
        } catch CharacterRerollInterruption.maximumRuntimeReached {
            return .ended(
                latestPostClick: latestPostClick,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .maximumRuntimeReached
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .ended(
                latestPostClick: latestPostClick,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .failed(message)
            )
        }
    }

    private static func postCharacterRerollClick(
        target: CharacterRerollTarget,
        observation: CharacterRerollObservation,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        actionDeadline: TimeInterval,
        sessionDeadline: TimeInterval,
        stopURL: URL?
    ) throws -> CharacterRerollClickResult {
        let permittedButtonRect = CharacterRerollDetector.measuredRandomButtonRect
        let permittedButtonPoint = CharacterRerollDetector.measuredRandomButtonPoint
        guard observation.boundaryEvidence == .belowThreshold,
              case .rerollRequired = observation.decision,
              canonicalCharacterRerollText(target.sourceText) == "隨機",
              target.rect.isValid,
              characterRerollRect(target.rect, isContainedIn: permittedButtonRect),
              abs(target.point.x - permittedButtonPoint.x) <= 0.001,
              abs(target.point.y - permittedButtonPoint.y) <= 0.001,
              !isInsideCharacterDecisionOrResetRegion(target.point),
              observation.window.windowID == identity.windowID,
              observation.window.owningApplication?.processID == identity.processID,
              approximatelyEqual(observation.window.frame, expectedFrame, tolerance: 0.5)
        else {
            throw ProbeError.unsafeWindow(
                "the confirmed Random target was outside its only permitted control region"
            )
        }

        let clickPoint = CGPoint(
            x: expectedFrame.minX + expectedFrame.width * target.point.x,
            y: expectedFrame.minY + expectedFrame.height * target.point.y
        )
        let expectedGeometry = automationWindowGeometry(expectedFrame)
        let previousMouseLocation = CGEvent(source: nil)?.location
        var boundaryResult: CharacterRerollClickResult?
        let posted = try postSingleClick(at: clickPoint) {
            let frontmostProcessID = ForegroundApplicationFocus.currentApplication?.processIdentifier
            let windows = windowServerWindows() ?? []
            let currentWindow = windows.first { $0.identity.windowID == identity.windowID }
            let topmostWindow = topmostInputWindow(
                at: clickPoint,
                expectedWindowFrame: expectedFrame,
                expectedProcessID: identity.processID,
                windows: windows
            )
            let snapshot = AutoLevelInputSnapshot(
                windowIdentity: currentWindow?.identity,
                windowGeometry: currentWindow.map { automationWindowGeometry($0.frame) },
                frontmostProcessID: frontmostProcessID,
                topmostWindowIdentity: topmostWindow?.identity
            )
            let rejection = AutoLevelInputSafety.rejection(
                expectedWindowIdentity: identity,
                expectedWindowGeometry: expectedGeometry,
                inputMode: .foreground,
                snapshot: snapshot,
                now: ProcessInfo.processInfo.systemUptime,
                actionDeadline: actionDeadline,
                sessionDeadline: sessionDeadline,
                stopRequested: characterRerollStopRequested(stopURL)
            )
            guard let rejection else {
                return true
            }
            switch rejection {
            case .stopRequested:
                boundaryResult = .stopRequested
                return false
            case .sessionRuntimeExpired:
                boundaryResult = .maximumRuntimeReached
                return false
            case .applicationNotFrontmost:
                boundaryResult = .focusContended
                return false
            case .invalidTiming:
                throw ProbeError.unsafeWindow("the character reroll timing was invalid")
            case .actionAuthorizationExpired:
                throw ProbeError.unsafeWindow(
                    "the character reroll authorization expired before input"
                )
            case .windowUnavailable:
                throw ProbeError.unsafeWindow(
                    "the requested iPhone Mirroring window disappeared before input"
                )
            case .windowIdentityChanged:
                throw ProbeError.unsafeWindow(
                    "the iPhone Mirroring window identity changed before input"
                )
            case .windowGeometryChanged:
                throw ProbeError.unsafeWindow(
                    "the iPhone Mirroring window moved or resized before input"
                )
            case .clickPointObscured:
                throw ProbeError.unsafeWindow(
                    "another window covered the Random button before input"
                )
            }
        }

        guard posted else {
            guard let boundaryResult else {
                throw ProbeError.unsafeWindow(
                    "the final character reroll boundary rejected input"
                )
            }
            return boundaryResult
        }
        if let previousMouseLocation {
            CGWarpMouseCursorPosition(previousMouseLocation)
        }
        return .posted
    }

    private static func characterRerollTargetsMatch(
        _ lhs: CharacterRerollTarget,
        _ rhs: CharacterRerollTarget
    ) -> Bool {
        canonicalCharacterRerollText(lhs.sourceText) == "隨機"
            && canonicalCharacterRerollText(rhs.sourceText) == "隨機"
            && abs(lhs.point.x - rhs.point.x) <= 0.01
            && abs(lhs.point.y - rhs.point.y) <= 0.01
            && abs(lhs.rect.width - rhs.rect.width) <= 0.02
            && abs(lhs.rect.height - rhs.rect.height) <= 0.02
    }

    private static func characterRerollStableDecisionsMatch(
        _ lhs: CharacterRerollDecision,
        _ rhs: CharacterRerollDecision
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.rerollRequired(leftRoll, _), .rerollRequired(rightRoll, _)):
            return leftRoll == rightRoll
        case let (.thresholdReached(leftRoll), .thresholdReached(rightRoll)):
            // Two independently safe observations of the same quiescent pixels may disagree on
            // individual digit shapes while still agreeing that the configured boundary is met.
            return leftRoll.name == rightRoll.name
        default:
            return false
        }
    }

    private static func characterRerollUnambiguousTotal(
        _ observation: CharacterRerollObservation
    ) -> Int? {
        guard !observation.fullFrameWasContaminated,
            !observation.focusedWasContaminated,
            observation.fullFrameTotal != nil
            || observation.credibleFullFrameTotals.isEmpty,
            observation.focusedTotal != nil
                || observation.credibleFocusedTotals.isEmpty
        else {
            return nil
        }
        switch (observation.fullFrameTotal, observation.focusedTotal) {
        case let (fullFrame?, focused?) where fullFrame == focused:
            return fullFrame
        case (_?, _?):
            return nil
        case let (fullFrame?, nil):
            return fullFrame
        case let (nil, focused?):
            return focused
        case (nil, nil):
            return nil
        }
    }

    private static func characterRerollObservedTotalSource(
        _ observation: CharacterRerollObservation
    ) -> String? {
        guard !observation.fullFrameWasContaminated,
            !observation.focusedWasContaminated,
            observation.fullFrameTotal != nil
            || observation.credibleFullFrameTotals.isEmpty,
            observation.focusedTotal != nil
                || observation.credibleFocusedTotals.isEmpty
        else {
            return nil
        }
        switch (observation.fullFrameTotal, observation.focusedTotal) {
        case let (fullFrame?, focused?) where fullFrame == focused:
            return "agreement"
        case (_?, _?):
            return nil
        case (_?, nil):
            return "fullFrame"
        case (nil, _?):
            return "focused"
        case (nil, nil):
            return nil
        }
    }

    private static func characterRerollBoundaryEvidenceName(
        _ evidence: CharacterTotalBoundaryEvidence
    ) -> String {
        switch evidence {
        case .belowThreshold:
            return "belowThreshold"
        case .thresholdReached:
            return "thresholdReached"
        case .boundaryConflict:
            return "boundaryConflict"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Includes every generated field but excludes the iPhone clock and all tappable controls.
    private static let characterRerollResultRegion = MirrorProbeCore.NormalizedRect(
        x: 0.01,
        y: 0.13,
        width: 0.98,
        height: 0.50
    )
    /// Covers the page identity, Random control, generated result, and lower action controls while
    /// excluding the changing iPhone status bar. The final pixel-only guard uses this wider region
    /// so an in-app overlay cannot replace Random without invalidating authorization.
    private static let characterRerollInputSurfaceRegion = MirrorProbeCore.NormalizedRect(
        x: 0.01,
        y: 0.08,
        width: 0.98,
        height: 0.65
    )
    /// Four static live captures were byte-identical in this region. Keep a small allowance for
    /// capture conversion noise while still requiring the generated result to be visually still.
    private static let characterRerollMaximumQuiescentDifference = 0.000_1
    /// Distinct measured rolls differ by roughly 0.006 mean RGB. This conservative floor proves
    /// the click changed the generated result even if name and total happen to repeat.
    private static let characterRerollMinimumChangedDifference = 0.001

    private static func characterRerollFramesAreQuiescent(
        _ lhs: RGBAFrame,
        _ rhs: RGBAFrame
    ) throws -> Bool {
        try characterRerollResultDifference(lhs, rhs)
            <= characterRerollMaximumQuiescentDifference
    }

    private static func characterRerollInputSurfaceFramesAreQuiescent(
        _ lhs: RGBAFrame,
        _ rhs: RGBAFrame
    ) throws -> Bool {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.bytesPerRow == rhs.bytesPerRow
        else {
            throw ProbeError.unsafeWindow(
                "the character-reroll capture dimensions changed during the final pixel guard"
            )
        }
        return try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            lhs.bytes,
            rhs.bytes,
            width: lhs.width,
            height: lhs.height,
            bytesPerRow: lhs.bytesPerRow,
            region: characterRerollInputSurfaceRegion
        ) <= characterRerollMaximumQuiescentDifference
    }

    private static func characterRerollResultDifference(
        _ lhs: RGBAFrame,
        _ rhs: RGBAFrame
    ) throws -> Double {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.bytesPerRow == rhs.bytesPerRow
        else {
            throw ProbeError.unsafeWindow(
                "the character-reroll capture dimensions changed during comparison"
            )
        }
        return try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            lhs.bytes,
            rhs.bytes,
            width: lhs.width,
            height: lhs.height,
            bytesPerRow: lhs.bytesPerRow,
            region: characterRerollResultRegion
        )
    }

    private static func characterRerollRect(
        _ inner: MirrorProbeCore.NormalizedRect,
        isContainedIn outer: MirrorProbeCore.NormalizedRect
    ) -> Bool {
        inner.isValid
            && outer.isValid
            && inner.x >= outer.x
            && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }

    private static func characterRerollTotal(_ decision: CharacterRerollDecision) -> Int? {
        characterRerollRoll(decision)?.total
    }

    private static func characterRerollRoll(
        _ decision: CharacterRerollDecision
    ) -> CharacterRoll? {
        switch decision {
        case let .rerollRequired(roll, _), let .thresholdReached(roll):
            return roll
        case .unsafe:
            return nil
        }
    }

    private static func canonicalCharacterRerollText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping.uppercased()
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "：", with: ":")
    }

    private static func characterRerollStopRequested(_ stopURL: URL?) -> Bool {
        guard let stopURL else { return false }
        return FileManager.default.fileExists(atPath: stopURL.path)
    }

    private static func isInsideCharacterDecisionOrResetRegion(
        _ point: MirrorProbeCore.NormalizedPoint
    ) -> Bool {
        (0.32...0.68).contains(point.x)
            && (0.62...0.73).contains(point.y)
    }

    private static func emitCharacterRerollReport(
        status: String,
        reason: String,
        startedDate: Date,
        window: SCWindow,
        limits: CharacterRerollLimitsReport,
        initialTotal: Int?,
        finalTotal: Int?,
        rerollsPosted: Int,
        reportURL: URL?,
        candidateObservation: CharacterRerollObservation? = nil,
        candidateRole: CharacterRerollCandidateRole? = nil,
        keeperOrConflictWasObserved: Bool = false,
        printToStandardOutput: Bool = true
    ) throws {
        let terminalBoundaryWasObserved = keeperOrConflictWasObserved
            || candidateObservation?.boundaryEvidence == .thresholdReached
            || candidateObservation?.boundaryEvidence == .boundaryConflict
        let candidateImage: CharacterRerollCandidateImageReport?
        if status != "running",
           let reportURL,
           let candidateObservation
        {
            let imageURL = reportURL.deletingLastPathComponent()
                .appendingPathComponent("final-candidate.png")
            if let pngSHA256 = try? writePNG(candidateObservation.image, to: imageURL) {
                candidateImage = CharacterRerollCandidateImageReport(
                    role: (
                        candidateRole
                            ?? (status == "completed" ? .finalStable : .lastVerifiedStable)
                    ).rawValue,
                    path: imageURL.path,
                    pngSHA256: pngSHA256,
                    observedTotal: characterRerollUnambiguousTotal(candidateObservation),
                    observedTotalSource: characterRerollObservedTotalSource(
                        candidateObservation
                    ),
                    credibleFullFrameTotals: candidateObservation.credibleFullFrameTotals,
                    credibleFocusedTotals: candidateObservation.credibleFocusedTotals,
                    fullFrameWasContaminated: candidateObservation.fullFrameWasContaminated,
                    focusedWasContaminated: candidateObservation.focusedWasContaminated,
                    focusedTotal: candidateObservation.focusedTotal,
                    renderedDigitCount: candidateObservation.renderedDigitCount,
                    boundaryEvidence: characterRerollBoundaryEvidenceName(
                        candidateObservation.boundaryEvidence
                    ),
                    thresholdReached: candidateObservation.boundaryEvidence == .thresholdReached
                )
            } else {
                candidateImage = nil
            }
        } else {
            candidateImage = nil
        }
        let report = CharacterRerollReport(
            schemaVersion: characterRerollSchemaVersion,
            status: status,
            startedAt: ISO8601DateFormatter().string(from: startedDate),
            endedAt: status == "running"
                ? nil
                : ISO8601DateFormatter().string(from: Date()),
            window: windowReport(window),
            limits: limits,
            initialTotal: initialTotal,
            finalTotal: finalTotal,
            rerollsPosted: rerollsPosted,
            finalReason: reason,
            keeperOrConflictWasObserved: terminalBoundaryWasObserved,
            candidateImage: candidateImage
        )
        if let reportURL {
            try writeJSON(report, to: reportURL)
        }
        if printToStandardOutput {
            try printJSON(report)
        }
    }

    private static func autoLevelCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: [
                "--window-id", "--confirm", "--input-mode", "--max-cycles", "--max-minutes",
                "--capture-level", "--output-dir",
            ]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()

        guard let confirmation = option("--confirm", in: arguments),
              [autoLevelConfirmation, legacyAutoLevelConfirmation].contains(confirmation)
        else {
            throw ProbeError.invalidArguments(
                "run requires --confirm \(autoLevelConfirmation), authorizing bounded automation "
                    + "including recovery from a confirmed stalled battle. Talisman use is unrestricted."
            )
        }
        let requestedID = try optionalWindowID(arguments)
        let inputModeText = option("--input-mode", in: arguments) ?? AutoLevelInputMode.foreground.rawValue
        guard let inputMode = AutoLevelInputMode(rawValue: inputModeText) else {
            throw ProbeError.invalidArguments("--input-mode must be foreground or process")
        }
        let captureLevelText = option("--capture-level", in: arguments)
            ?? AutoLevelCaptureLevel.error.rawValue
        guard let captureLevel = AutoLevelCaptureLevel(rawValue: captureLevelText) else {
            throw ProbeError.invalidArguments("--capture-level must be error or info")
        }
        let maximumCycles = try boundedIntegerOption(
            "--max-cycles",
            in: arguments,
            defaultValue: 20,
            range: 1...500
        )
        let maximumMinutes = try boundedDoubleOption(
            "--max-minutes",
            in: arguments,
            defaultValue: 120,
            range: 1...480
        )
        let maximumActions = min(10_000, max(50, maximumCycles * 16 + 20))
        let pollInterval = 1.5
        let sessionID = automationSessionID()
        guard let outputDirectoryPath = option("--output-dir", in: arguments),
              outputDirectoryPath.hasPrefix("/")
        else {
            throw ProbeError.invalidArguments(
                "run requires --output-dir with an absolute path for durable logs and the STOP file"
            )
        }
        let directoryURL = try outputURL(for: outputDirectoryPath, isDirectory: true)
        let reportURL = directoryURL.appendingPathComponent("run-report.json")
        let stopURL = directoryURL.appendingPathComponent("STOP")
        let existingOutputEntries = try FileManager.default.contentsOfDirectory(
            atPath: directoryURL.path
        )
        guard existingOutputEntries.isEmpty else {
            throw ProbeError.invalidArguments(
                "--output-dir must be empty so no prior report or capture can be overwritten"
            )
        }

        let startedDate = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let captureRecorder = AutomationCaptureRecorder()
        let initialWindow = try await selectMirrorWindow(requestedID: requestedID)
        guard let initialApplication = initialWindow.owningApplication,
              initialApplication.processID > 0
        else {
            throw ProbeError.unsafeWindow("could not resolve the iPhone Mirroring process")
        }
        let identity = AutoLevelWindowIdentity(
            processID: initialApplication.processID,
            windowID: initialWindow.windowID
        )
        let windowRunLock = try AutoLevelWindowRunLock.acquire(for: identity)
        defer { windowRunLock.release() }
        let initialFrame = initialWindow.frame
        let windowRecovery = AutomationWindowRecoveryContext(
            stopURL: stopURL, sessionDeadline: startedAt + maximumMinutes * 60
        )
        let limits = AutomationLimitsReport(
            maximumCycles: maximumCycles,
            maximumMinutes: maximumMinutes,
            maximumActions: maximumActions,
            pollIntervalSeconds: pollInterval
        )
        var report = AutomationRunReport(
            schemaVersion: automationSchemaVersion,
            sessionID: sessionID,
            status: "running",
            startedAt: ISO8601DateFormatter().string(from: startedDate),
            endedAt: nil,
            window: windowReport(initialWindow),
            talismanPolicy: "unrestricted",
            inputMode: inputMode,
            captureLevel: captureLevel,
            limits: limits,
            outputDirectory: directoryURL.path,
            stopFile: stopURL.path,
            completedCycles: 0,
            actionsPosted: 0,
            finalReason: nil,
            diagnosticScreenshots: [],
            diagnosticPersistenceErrors: [],
            events: []
        )
        do {
            let initialObservation = try await captureAutomationObservation(
                requestedID: initialWindow.windowID,
                expectedIdentity: identity,
                expectedFrame: initialFrame,
                captureRecorder: captureRecorder,
                recovery: windowRecovery,
                phase: "initial"
            )
            let routineCapturePlan = AutoLevelCaptureRetentionPolicy(level: captureLevel)
                .plan(for: .expectedLimit)
            let initialPath: String?
            if routineCapturePlan.retainsInitial {
                let initialURL = directoryURL.appendingPathComponent("initial.png")
                try writePNG(initialObservation.image, to: initialURL)
                initialPath = initialURL.path
            } else {
                initialPath = nil
            }

            try appendAutomationEvent(
                kind: "sessionStarted",
                state: initialObservation.classification.state,
                decision: nil,
                action: nil,
                target: nil,
                frameFingerprint: initialObservation.fingerprint,
                detail: "User entered the stage manually; automation acquired and locked the mirror window; inputMode=\(inputMode.rawValue), captureLevel=\(captureLevel.rawValue).",
                screenshotPath: initialPath,
                elapsed: initialObservation.capturedAt - startedAt,
                report: &report,
                reportURL: reportURL
            )

            try await performAutoLevelLoop(
                initialObservation: initialObservation,
                identity: identity,
                initialFrame: initialFrame,
                sessionID: sessionID,
                inputMode: inputMode,
                captureLevel: captureLevel,
                captureRecorder: captureRecorder,
                windowRecovery: windowRecovery,
                startedAt: startedAt,
                maximumCycles: maximumCycles,
                maximumMinutes: maximumMinutes,
                maximumActions: maximumActions,
                pollInterval: pollInterval,
                directoryURL: directoryURL,
                reportURL: reportURL,
                stopURL: stopURL,
                report: &report
            )
        } catch let interruption as AutomationCaptureInterruption {
            let stoppedByUser = interruption == .stopRequested
            try finishAutomationRun(
                status: "stopped",
                reason: stoppedByUser ? "stopFileDetected" : String(describing:
                    AutoLevelStopReason.maximumRuntimeReached(limit: maximumMinutes * 60)),
                terminationKind: stoppedByUser ? .userStop : .expectedLimit,
                observation: nil,
                captureLevel: captureLevel,
                captureRecorder: captureRecorder,
                startedAt: startedAt,
                directoryURL: directoryURL,
                reportURL: reportURL,
                report: &report
            )
        } catch {
            let originalReason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            let diagnosticResult = persistAutomationTerminationScreenshots(
                captureLevel: captureLevel,
                terminationKind: .runtimeError,
                observation: nil,
                captureRecorder: captureRecorder,
                startedAt: startedAt,
                directoryURL: directoryURL
            )
            report.diagnosticScreenshots.append(contentsOf: diagnosticResult.screenshots)
            report.diagnosticPersistenceErrors.append(contentsOf: diagnosticResult.errors)
            let latestCapture = captureRecorder.capturesOldestFirst.last
            report.status = "error"
            report.endedAt = ISO8601DateFormatter().string(from: Date())
            report.finalReason = originalReason
            try? appendAutomationEvent(
                kind: "sessionError",
                state: latestCapture?.state,
                decision: nil,
                action: nil,
                target: nil,
                frameFingerprint: latestCapture?.fingerprint,
                detail: diagnosticResult.errors.isEmpty
                    ? originalReason
                    : "\(originalReason); diagnosticPersistenceErrors="
                        + diagnosticResult.errors.joined(separator: " | "),
                screenshotPath: diagnosticResult.finalPath,
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                report: &report,
                reportURL: reportURL
            )
            try? writeJSON(report, to: reportURL)
            throw error
        }

        try writeJSON(report, to: reportURL)
        try printJSON(report)
    }

    private static func performAutoLevelLoop(
        initialObservation: AutomationObservation,
        identity: AutoLevelWindowIdentity,
        initialFrame: CGRect,
        sessionID: String,
        inputMode: AutoLevelInputMode,
        captureLevel: AutoLevelCaptureLevel,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext,
        startedAt: TimeInterval,
        maximumCycles: Int,
        maximumMinutes: Double,
        maximumActions: Int,
        pollInterval: TimeInterval,
        directoryURL: URL,
        reportURL: URL,
        stopURL: URL,
        report: inout AutomationRunReport
    ) async throws {
        let policy = AutoLevelPolicy(
            actionCooldown: 0.8,
            postActionTimeout: 12,
            uncertainStateGraceDuration: 15,
            uncertainStateGraceSnapshots: 8,
            maxCycles: maximumCycles,
            maxRuntime: maximumMinutes * 60,
            maxActions: maximumActions
        )
        let retainsActionPairs = AutoLevelCaptureRetentionPolicy(level: captureLevel)
            .plan(for: .expectedLimit)
            .retainsActionPairs
        let session = AutoLevelSessionMetadata(
            sessionID: sessionID,
            startedAt: startedAt,
            windowIdentity: identity
        )
        var controller = AutoLevelController(session: session, policy: policy)
        var battleTracker = AutomationBattleTracker()
        var autoEnabledBattleIDs = Set<String>()
        var stallDetector = BattleStallDetector(configuration: BattleStallConfiguration(
            suspectedAfter: 3,
            confirmedAfter: 5,
            maximumSampleGap: 3,
            maximumStableROIDifference: 0.002,
            minimumStableSampleCount: 5
        ))
        var stallAssessment = stallDetector.reset()
        var resumableStallProgressByBattleID: [String: BattleStallProgressResumeState] = [:]
        var allAutoProgressValidator = AllAutoProgressValidator()
        var battleActivityProgressDetector = BattleActivityProgressDetector()
        var verifiedAutomaticBattleProgress: VerifiedAutomaticBattleProgress?
        var inputGeneration: UInt64 = 0
        var previousTemporalFrame: AutomationTemporalFrame?
        var currentObservation: AutomationObservation? = initialObservation
        var lastObservation: AutomationObservation? = initialObservation
        var lastLoggedSignature: String?
        var lastHeartbeatAt = startedAt
        var handledWindowContinuityGeneration: UInt64 = 0
        var needsProgressAfterWindowRecovery = false

        automationLoop: while true {
            if FileManager.default.fileExists(atPath: stopURL.path) {
                try finishAutomationRun(
                    status: "stopped",
                    reason: "stopFileDetected",
                    terminationKind: .userStop,
                    observation: currentObservation ?? lastObservation,
                    captureLevel: captureLevel,
                    captureRecorder: captureRecorder,
                    startedAt: startedAt,
                    directoryURL: directoryURL,
                    reportURL: reportURL,
                    report: &report
                )
                return
            }

            var observation: AutomationObservation
            if let supplied = currentObservation {
                observation = supplied
                currentObservation = nil
            } else {
                try await Task.sleep(for: .seconds(pollInterval))
                observation = try await captureAutomationObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: initialFrame,
                    captureRecorder: captureRecorder,
                    recovery: windowRecovery,
                    phase: "observation",
                    actionDeadline: controller.pendingActionAcknowledgementDeadline
                )
            }
            let windowContinuityChanged = observation.windowContinuityGeneration
                != handledWindowContinuityGeneration
            if windowContinuityChanged {
                handledWindowContinuityGeneration = observation.windowContinuityGeneration
                needsProgressAfterWindowRecovery = true
                inputGeneration &+= 1
                previousTemporalFrame = nil
                verifiedAutomaticBattleProgress = nil
                resumableStallProgressByBattleID.removeAll()
                stallAssessment = stallDetector.reset()
                battleActivityProgressDetector.reset()
                try appendAutomationEvent(
                    kind: "windowAvailabilityRecovered",
                    state: observation.classification.state,
                    decision: "rebuildVisualEvidence",
                    action: nil, target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: "sameProcessAndWindowVerified=true, continuityGeneration=\(handledWindowContinuityGeneration), stalePixelEvidenceDiscarded=true",
                    screenshotPath: nil,
                    elapsed: observation.capturedAt - startedAt,
                    report: &report, reportURL: reportURL
                )
            }
            lastObservation = observation

            let battleID = battleTracker.observe(
                state: observation.classification.state,
                sessionID: sessionID
            )
            let newlyAssumedAutomaticBattleID: String?
            if observation.classification.state == .battle,
               let battleID,
               autoEnabledBattleIDs.insert(battleID).inserted
            {
                // Knight & Dragon IV carries the user's configured 全部自動 setting into
                // each battle. Treat that default as already on; clicking the visible control
                // would toggle it off. This is an observation-time assumption, not an input, so
                // inputGeneration intentionally remains unchanged. The validators below still
                // require independently observed battle progress within their bounded timeout.
                newlyAssumedAutomaticBattleID = battleID
                verifiedAutomaticBattleProgress = nil
            } else {
                newlyAssumedAutomaticBattleID = nil
            }
            let allAutoStatus: AutoLevelAllAutoStatus
            if let battleID, autoEnabledBattleIDs.contains(battleID) {
                allAutoStatus = .active
            } else {
                allAutoStatus = .unknown
            }
            let battleContext = automationBattleContext(
                for: observation,
                identity: identity
            )
            let regionDifference = try automationBattleRegionDifference(
                previous: previousTemporalFrame,
                current: observation,
                context: battleContext,
                inputGeneration: inputGeneration
            )
            let stallFrameEvidence = BattleStallFrameEvidence.extract(
                from: observation.observations
            )
            let sample = BattleStallSample(
                monotonicTime: observation.capturedAt,
                context: battleContext,
                battleScreenConfirmed: observation.classification.state == .battle,
                modalPresent: isAutomationModal(observation.classification.state),
                paused: automationIsPaused(observation.observations),
                inputGeneration: inputGeneration,
                frameEvidence: stallFrameEvidence,
                battleROIDifferenceFromPrevious: regionDifference
            )
            let activityProgressAssessment: BattleActivityProgressAssessment
            if let newlyAssumedAutomaticBattleID {
                needsProgressAfterWindowRecovery = false
                resumableStallProgressByBattleID.removeValue(
                    forKey: newlyAssumedAutomaticBattleID
                )
                stallAssessment = stallDetector.automaticBattleEnabled(
                    at: observation.capturedAt,
                    context: battleContext,
                    inputGeneration: inputGeneration
                )
                _ = allAutoProgressValidator.automaticBattleExpected(
                    at: observation.capturedAt,
                    battleSessionID: newlyAssumedAutomaticBattleID
                )
                activityProgressAssessment = battleActivityProgressDetector
                    .automaticBattleExpected(
                        at: observation.capturedAt,
                        battleSessionID: newlyAssumedAutomaticBattleID,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
            } else if needsProgressAfterWindowRecovery, let battleID,
                      observation.classification.state == .battle {
                // The first recovered frame may be a loading/unknown page. Keep this reset
                // pending until a real battle frame can establish new temporal baselines.
                needsProgressAfterWindowRecovery = false
                stallAssessment = stallDetector.automaticBattleEnabled(
                    at: observation.capturedAt, context: battleContext,
                    inputGeneration: inputGeneration
                )
                if !allAutoProgressValidator.isAwaitingProgress {
                    _ = allAutoProgressValidator.automaticBattleExpected(
                        at: observation.capturedAt, battleSessionID: battleID
                    )
                }
                activityProgressAssessment = battleActivityProgressDetector.automaticBattleExpected(
                    at: observation.capturedAt, battleSessionID: battleID,
                    context: battleContext, inputGeneration: inputGeneration
                )
            } else {
                stallAssessment = stallDetector.observe(sample)
                if let battleID {
                    activityProgressAssessment = battleActivityProgressDetector.observe(
                        BattleActivityProgressSample(
                            monotonicTime: observation.capturedAt,
                            battleSessionID: battleID,
                            context: battleContext,
                            inputGeneration: inputGeneration,
                            evidence: BattleActivityFrameEvidence.extract(
                                from: observation.observations
                            ),
                            battleROIDifferenceFromPrevious: regionDifference
                        )
                    )
                } else {
                    battleActivityProgressDetector.reset()
                    activityProgressAssessment = .inactive
                }
            }
            let stallResetReason = stallAssessment.resetReason
            let mayResumeEstablishedProgress = stallResetReason == .incompleteBattleEvidence
                || stallResetReason == .sampleGap
            if stallAssessment.phase == .inactive,
               !mayResumeEstablishedProgress,
               stallResetReason != nil,
               let battleID
            {
                resumableStallProgressByBattleID.removeValue(forKey: battleID)
            }
            if stallAssessment.isArmed,
               let battleID,
               let resumeState = stallDetector.progressResumeState
            {
                // This map is populated only from detector-issued, already-armed evidence. The
                // battle ID is the runtime's independent boundary between otherwise identical
                // window contexts.
                resumableStallProgressByBattleID[battleID] = resumeState
            }
            if stallAssessment.phase == .inactive,
               let battleID,
               autoEnabledBattleIDs.contains(battleID),
               observation.classification.state == .battle
            {
                if mayResumeEstablishedProgress,
                   let resumeState = resumableStallProgressByBattleID[battleID]
                {
                    stallAssessment = stallDetector.resumeMonitoring(
                        from: resumeState,
                        at: observation.capturedAt,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
                    if stallAssessment.phase == .inactive {
                        resumableStallProgressByBattleID.removeValue(forKey: battleID)
                    }
                }
                if stallAssessment.phase == .inactive {
                    // Automatic mode remains latched for this battle, but no prior progress is
                    // inferred across other reset causes or an identity mismatch.
                    stallAssessment = stallDetector.automaticBattleEnabled(
                        at: observation.capturedAt,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
                }
            }
            previousTemporalFrame = AutomationTemporalFrame(
                rgba: observation.rgba,
                context: battleContext,
                inputGeneration: inputGeneration
            )
            let allAutoValidation = allAutoProgressValidator.observe(
                at: observation.capturedAt,
                battleSessionID: battleID,
                state: observation.classification.state,
                genuineProgressObserved: stallAssessment.isArmed
                    || activityProgressAssessment.didObserveProgress
            )
            if case .validated(.genuineBattleProgress) = allAutoValidation,
               let battleID
            {
                verifiedAutomaticBattleProgress = VerifiedAutomaticBattleProgress(
                    battleSessionID: battleID,
                    inputGeneration: inputGeneration
                )
            }
            if verifiedAutomaticBattleProgress?.matches(
                battleSessionID: battleID,
                inputGeneration: inputGeneration
            ) == true,
               observation.classification.state == .battle,
               !stallAssessment.isArmed
            {
                // Normal automatic combat was independently proven by a changed HP/log
                // signature plus moving pixels. From here, use dense five-second visual
                // stability instead of requiring every HP value to remain OCR-readable.
                stallAssessment = stallDetector.markVerifiedNormalBattleProgress(
                    at: observation.capturedAt,
                    context: battleContext,
                    inputGeneration: inputGeneration
                )
            }
            if case let .timedOut(unresponsiveBattleID) = allAutoValidation {
                try finishAutomationRun(
                    status: "stopped",
                    reason: "allAutoDidNotProduceProgress(battleSessionID: \(unresponsiveBattleID), timeout: 30.0)",
                    terminationKind: .safetyStop,
                    observation: observation,
                    captureLevel: captureLevel,
                    captureRecorder: captureRecorder,
                    startedAt: startedAt,
                    directoryURL: directoryURL,
                    reportURL: reportURL,
                    report: &report
                )
                return
            }
            var retreatVisualConfirmation: BattleVisualStabilityConfirmation?
            let retreatVisualAnchor = observation.rgba
            if stallAssessment.isArmed,
               verifiedAutomaticBattleProgress?.matches(
                   battleSessionID: battleID,
                   inputGeneration: inputGeneration
               ) == true,
               allAutoStatus == .active,
               let regionDifference,
               regionDifference <= stallDetector.configuration.maximumStableROIDifference,
               let confirmation = stallDetector.beginVisualConfirmation(from: sample)
            {
                let result = try await confirmAutomationVisualStability(
                    confirmation,
                    anchor: observation,
                    identity: identity,
                    expectedFrame: initialFrame,
                    inputGeneration: inputGeneration,
                    sessionDeadline: startedAt + policy.maxRuntime,
                    stopURL: stopURL,
                    captureRecorder: captureRecorder,
                    windowRecovery: windowRecovery
                )
                switch result {
                case let .confirmed(confirmation, final, assessment):
                    retreatVisualConfirmation = confirmation
                    observation = final
                    lastObservation = final
                    stallAssessment = assessment
                    previousTemporalFrame = AutomationTemporalFrame(
                        rgba: final.rgba,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
                    try appendAutomationEvent(
                        kind: "battleVisualStabilityConfirmed",
                        state: final.classification.state,
                        decision: "freshBattleOCRConfirmed",
                        action: nil,
                        target: nil,
                        frameFingerprint: final.fingerprint,
                        detail: automationStallDetail(assessment) + ", fixedAnchorCompared=true",
                        screenshotPath: nil,
                        elapsed: final.capturedAt - startedAt,
                        report: &report,
                        reportURL: reportURL
                    )
                case let .rejected(final, detail):
                    currentObservation = final
                    lastObservation = final
                    try appendAutomationEvent(
                        kind: "battleVisualStabilityCancelled",
                        state: final.classification.state,
                        decision: "continueObservation",
                        action: nil,
                        target: nil,
                        frameFingerprint: final.fingerprint,
                        detail: detail + ", noInputPosted=true",
                        screenshotPath: nil,
                        elapsed: final.capturedAt - startedAt,
                        report: &report,
                        reportURL: reportURL
                    )
                    continue automationLoop
                case .interrupted:
                    let stoppedByUser = FileManager.default.fileExists(atPath: stopURL.path)
                    try finishAutomationRun(
                        status: "stopped",
                        reason: stoppedByUser ? "stopFileDetected" : String(describing:
                            AutoLevelStopReason.maximumRuntimeReached(limit: policy.maxRuntime)),
                        terminationKind: stoppedByUser ? .userStop : .expectedLimit,
                        observation: lastObservation,
                        captureLevel: captureLevel,
                        captureRecorder: captureRecorder,
                        startedAt: startedAt,
                        directoryURL: directoryURL,
                        reportURL: reportURL,
                        report: &report
                    )
                    return
                }
            }
            let battleStatus: AutoLevelBattleStatus
            if stallAssessment.isConfirmedEvidence,
               retreatVisualConfirmation != nil,
               stallAssessment.isArmed,
               verifiedAutomaticBattleProgress?.matches(
                   battleSessionID: battleID,
                   inputGeneration: inputGeneration
               ) == true,
               allAutoStatus == .active
            {
                // BattleStallDetector confirmation already requires pixel-corroborated progress
                // in its current context/input generation. The explicit verified identity also
                // prevents an assumed-default status from authorizing retreat by itself.
                battleStatus = .stalledAfterDefeat
            } else if observation.classification.state == .battle {
                battleStatus = .inProgress
            } else {
                battleStatus = .unknown
            }
            let runtime = AutoLevelRuntimeMetadata(
                observedAt: observation.capturedAt,
                windowIdentity: identity,
                frameFingerprint: observation.fingerprint,
                battleSessionID: battleID,
                allAutoStatus: allAutoStatus,
                battleStatus: battleStatus
            )
            let snapshot = AutoLevelSnapshot(
                classification: observation.classification,
                runtime: runtime
            )
            let decision = controller.consume(snapshot)
            report.completedCycles = controller.completedCycles

            let signature = "\(observation.classification.state.rawValue)|"
                + "\(String(describing: decision))|\(stallAssessment.phase.rawValue)"
            let shouldLog = signature != lastLoggedSignature
                || observation.capturedAt - lastHeartbeatAt >= 30
            if shouldLog {
                try appendAutomationEvent(
                    kind: "observation",
                    state: observation.classification.state,
                    decision: String(describing: decision),
                    action: nil,
                    target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: automationStallDetail(stallAssessment),
                    screenshotPath: nil,
                    elapsed: observation.capturedAt - startedAt,
                    report: &report,
                    reportURL: reportURL
                )
                lastLoggedSignature = signature
                lastHeartbeatAt = observation.capturedAt
            }

            switch decision {
            case .wait:
                continue

            case let .completedCycle(completion):
                report.completedCycles = completion.count
                try appendAutomationEvent(
                    kind: "cycleCompleted",
                    state: observation.classification.state,
                    decision: String(describing: decision),
                    action: nil,
                    target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: "cycle=\(completion.count), outcome=\(completion.outcome.rawValue)",
                    screenshotPath: nil,
                    elapsed: observation.capturedAt - startedAt,
                    report: &report,
                    reportURL: reportURL
                )
                // The controller intentionally reports the new cycle before choosing the result
                // page action. Reuse this exact, already trusted observation immediately instead
                // of taking another OCR sample which may lose the low-contrast SELECTED stamp.
                // Action preflight still performs a fresh capture and full target validation.
                currentObservation = observation
                continue

            case let .requestAction(request):
                let actionDeadline = observation.capturedAt + policy.postActionTimeout
                let sessionDeadline = startedAt + policy.maxRuntime
                let actionStem = String(format: "action-%04llu-%@", request.requestID, request.intent.rawValue)
                let beforeURL: URL?
                let afterURL: URL?
                if retainsActionPairs {
                    let framesURL = directoryURL.appendingPathComponent(
                        "frames",
                        isDirectory: true
                    )
                    beforeURL = framesURL.appendingPathComponent("\(actionStem)-before.png")
                    afterURL = framesURL.appendingPathComponent("\(actionStem)-after.png")
                } else {
                    beforeURL = nil
                    afterURL = nil
                }
                var activationRetry = AutoLevelForegroundActivationRetryState()
                var activationFailureDetails: [String] = []
                var postedPreflight: AutomationObservation?
                var postedAfter: AutomationObservation?
                var postedActionTime: TimeInterval?

                activationAttemptLoop: while true {
                    if FileManager.default.fileExists(atPath: stopURL.path) {
                        try finishAutomationRun(
                            status: "stopped",
                            reason: "stopFileDetected",
                            terminationKind: .userStop,
                            observation: lastObservation,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return
                    }
                    let retryBoundaryNow = ProcessInfo.processInfo.systemUptime
                    guard retryBoundaryNow.isFinite,
                          retryBoundaryNow >= 0,
                          actionDeadline.isFinite,
                          sessionDeadline.isFinite
                    else {
                        throw ProbeError.unsafeWindow(
                            "the foreground activation retry timing was invalid"
                        )
                    }
                    if retryBoundaryNow >= sessionDeadline {
                        let reason = AutoLevelStopReason.maximumRuntimeReached(
                            limit: policy.maxRuntime
                        )
                        try finishAutomationRun(
                            status: "stopped",
                            reason: String(describing: reason),
                            terminationKind: .expectedLimit,
                            observation: lastObservation,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return
                    }
                    guard retryBoundaryNow < actionDeadline else {
                        throw ProbeError.unsafeWindow(
                            "the action authorization expired while retrying foreground activation"
                        )
                    }

                    var focusBorrow = inputMode == .foreground
                        ? ForegroundFocusBorrow(targetProcessID: identity.processID)
                        : nil
                    guard inputMode != .foreground || focusBorrow != nil else {
                        // macOS can briefly return AXError.noValue while the user switches
                        // applications. No activation or input has happened in this attempt.
                        // Spend the same bounded budget, then read the original app anew; never
                        // substitute a cached PID or renew the action/session deadlines.
                        let failureDetail = "phase=focusBorrow, "
                            + "attempt=\(activationRetry.currentAttempt)/"
                            + "\(AutoLevelForegroundActivationRetryState.maximumAttempts), "
                            + "focusSource=Accessibility, "
                            + "result=focusedApplicationUnavailable, noInputPosted=true"
                        activationFailureDetails.append(failureDetail)
                        let retryDecision = activationRetry.recordUnpostedFocusFailure()
                        let detail: String
                        let kind: String
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            kind = "activationRetry"
                            detail = failureDetail + ", nextDelayMilliseconds=\(delayMilliseconds)"
                        case .exhausted:
                            kind = "activationRetryExhausted"
                            detail = failureDetail
                        }
                        try appendAutomationEvent(
                            kind: kind,
                            state: observation.classification.state,
                            decision: String(describing: decision),
                            action: request.intent,
                            target: request.target,
                            frameFingerprint: observation.fingerprint,
                            detail: detail,
                            screenshotPath: nil,
                            elapsed: retryBoundaryNow - startedAt,
                            report: &report,
                            reportURL: reportURL
                        )
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop
                        case let .exhausted(attempts):
                            throw ProbeError.unsafeWindow(
                                "the current focused application remained unavailable after "
                                    + "\(attempts) attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        }
                    }
                    defer { focusBorrow?.restore() }
                    let preflightResult = try await activateAndPreflightAutomationAction(
                        request,
                        identity: identity,
                        expectedFrame: initialFrame,
                        inputMode: inputMode,
                        expectedFocusSourceProcessID: focusBorrow?.previousProcessID,
                        activationAttempt: activationRetry.currentAttempt,
                        activationSettleDelayMilliseconds: activationRetry
                            .settleDelayMilliseconds,
                        battleSessionID: battleID,
                        allAutoStatus: allAutoStatus,
                        battleStatus: battleStatus,
                        captureRecorder: captureRecorder,
                        windowRecovery: windowRecovery,
                        actionDeadline: actionDeadline
                    )
                    let preflight: AutomationObservation
                    let confirmedTarget: AutoLevelActionTarget
                    let activation: AutomationForegroundActivationSnapshot?
                    switch preflightResult {
                    case let .confirmed(observation, target, activationSnapshot):
                        preflight = observation
                        confirmedTarget = target
                        activation = activationSnapshot

                    case let .stateChanged(observation, activationSnapshot):
                        focusBorrow?.restore()
                        if activationRetry.currentAttempt > 1,
                           let activationSnapshot
                        {
                            try appendAutomationEvent(
                                kind: "activationRecovered",
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: activationSnapshot.detail(
                                    phase: "preflight",
                                    result: "readyWithStateChange"
                                ),
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                        }
                        let cancellationReason: String
                        if request.intent == .requestRetreat,
                           controller.cancelUnpostedRetreat(request)
                        {
                            cancellationReason = "retreatStateChanged"
                        } else if controller.cancelUnpostedActionAfterForwardResultTransition(
                            request,
                            observedState: observation.classification.state
                        ) {
                            cancellationReason = "forwardResultTransition"
                        } else if controller.cancelUnpostedActionForObservedModal(
                            request,
                            observedState: observation.classification.state
                        ) {
                            cancellationReason = "newGeometryModal"
                        } else {
                            throw ProbeError.unsafeWindow(
                                "the game state changed from \(request.observedState.rawValue) to "
                                    + "\(observation.classification.state.rawValue) during action confirmation"
                            )
                        }
                        currentObservation = observation
                        lastObservation = observation
                        try appendAutomationEvent(
                            kind: "actionAlreadySatisfied",
                            state: observation.classification.state,
                            decision: String(describing: decision),
                            action: request.intent,
                            target: request.target,
                            frameFingerprint: observation.fingerprint,
                            detail: "noInputPosted=true, requestID=\(request.requestID), "
                                + "transition=\(request.observedState.rawValue)->"
                                + "\(observation.classification.state.rawValue); stale authorization "
                                + "cancelledReason=\(cancellationReason); confirmation capture will "
                                + "be processed as the next observation",
                            screenshotPath: nil,
                            elapsed: observation.capturedAt - startedAt,
                            report: &report,
                            reportURL: reportURL
                        )
                        continue automationLoop

                    case let .activationContended(observation, activationSnapshot):
                        focusBorrow?.restore()
                        lastObservation = observation
                        if request.intent == .requestRetreat {
                            // This is a new captured frame even though focus was contested.
                            // Discard the proof rather than skip potentially moving/modal pixels
                            // and later reuse it after an apparently stable retry frame.
                            guard controller.cancelUnpostedRetreat(request) else {
                                throw ProbeError.unsafeWindow("the contested retreat request could not be cancelled")
                            }
                            currentObservation = observation
                            try appendAutomationEvent(
                                kind: "battleVisualStabilityCancelled",
                                state: observation.classification.state,
                                decision: "continueObservation",
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: "retreatFocusContended, noInputPosted=true",
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            continue automationLoop
                        }
                        let failureDetail = activationSnapshot.detail(
                            phase: "preflight",
                            result: "focusContended"
                        )
                        activationFailureDetails.append(failureDetail)
                        let retryDecision = activationRetry.recordUnpostedFocusFailure()
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try appendAutomationEvent(
                                kind: "activationRetry",
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: "\(failureDetail), nextDelayMilliseconds=\(delayMilliseconds)",
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop

                        case let .exhausted(attempts):
                            try appendAutomationEvent(
                                kind: "activationRetryExhausted",
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: failureDetail,
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            throw ProbeError.unsafeWindow(
                                "iPhone Mirroring could not be made active and frontmost after "
                                    + "\(attempts) attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        }
                    }

                    if request.intent == .requestRetreat {
                        if preflight.windowContinuityGeneration != observation.windowContinuityGeneration {
                            retreatVisualConfirmation = nil
                        }
                        let preflightContext = automationBattleContext(
                            for: preflight,
                            identity: identity
                        )
                        let preflightDifference = try automationBattleRegionDifference(
                            previous: previousTemporalFrame,
                            current: preflight,
                            context: preflightContext,
                            inputGeneration: inputGeneration
                        )
                        let preflightSample = BattleStallSample(
                            monotonicTime: preflight.capturedAt,
                            context: preflightContext,
                            battleScreenConfirmed: preflight.classification.state == .battle,
                            modalPresent: isAutomationModal(preflight.classification.state),
                            paused: automationIsPaused(preflight.observations),
                            inputGeneration: inputGeneration,
                            frameEvidence: BattleStallFrameEvidence.extract(
                                from: preflight.observations
                            ),
                            battleROIDifferenceFromPrevious: preflightDifference
                        )
                        let preflightAssessment = retreatVisualConfirmation?.validate(
                            preflightSample,
                            differenceFromAnchor: try automationBattlePixelDifference(
                                retreatVisualAnchor, preflight.rgba
                            )
                        )
                        guard let preflightAssessment else {
                            focusBorrow?.restore()
                            guard controller.cancelUnpostedRetreat(request) else {
                                throw ProbeError.unsafeWindow("the stale retreat request could not be cancelled")
                            }
                            currentObservation = preflight
                            lastObservation = preflight
                            try appendAutomationEvent(
                                kind: "battleVisualStabilityCancelled",
                                state: preflight.classification.state,
                                decision: "continueObservation",
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: preflight.fingerprint,
                                detail: "retreatPreflightContinuityLost, noInputPosted=true",
                                screenshotPath: nil,
                                elapsed: preflight.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            continue automationLoop
                        }
                        stallAssessment = preflightAssessment
                        previousTemporalFrame = AutomationTemporalFrame(
                            rgba: preflight.rgba,
                            context: preflightContext,
                            inputGeneration: inputGeneration
                        )
                    }

                    let clickResult = try postAutomationClick(
                        request,
                        confirmedTarget: confirmedTarget,
                        using: preflight,
                        activation: activation,
                        identity: identity,
                        expectedFrame: initialFrame,
                        inputMode: inputMode,
                        actionDeadline: actionDeadline,
                        sessionDeadline: sessionDeadline,
                        stopURL: stopURL
                    )
                    switch clickResult {
                    case let .posted(postedAt):
                        guard controller.markActionPosted(request, at: postedAt) else {
                            throw ProbeError.unsafeWindow(
                                "the controller refused the posted action acknowledgement window"
                            )
                        }
                        report.actionsPosted += 1
                        postedPreflight = preflight
                        postedActionTime = postedAt
                        // CGEvent.post queues the mouse-up; it is not a delivery acknowledgement.
                        // Keep the successful borrow alive through the existing first after-frame,
                        // including the loop's defer. Do not repost a toggle if it has not changed.
                        let remainingRuntime = max(0, sessionDeadline - ProcessInfo.processInfo.systemUptime)
                        try await Task.sleep(for: .seconds(min(1, remainingRuntime)))
                        let stoppedByUser = FileManager.default.fileExists(atPath: stopURL.path)
                        if stoppedByUser || ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                            focusBorrow?.restore()
                            try finishAutomationRun(
                                status: "stopped",
                                reason: stoppedByUser ? "stopFileDetected" : String(describing:
                                    AutoLevelStopReason.maximumRuntimeReached(limit: policy.maxRuntime)),
                                terminationKind: stoppedByUser ? .userStop : .expectedLimit,
                                observation: preflight,
                                captureLevel: captureLevel,
                                captureRecorder: captureRecorder,
                                startedAt: startedAt,
                                directoryURL: directoryURL,
                                reportURL: reportURL,
                                report: &report
                            )
                            return
                        }
                        postedAfter = try await captureAutomationObservation(
                            requestedID: identity.windowID,
                            expectedIdentity: identity,
                            expectedFrame: initialFrame,
                            captureRecorder: captureRecorder,
                            recovery: windowRecovery,
                            phase: "afterPost",
                            actionDeadline: postedAt + policy.postActionTimeout
                        )
                        focusBorrow?.restore()
                        break activationAttemptLoop

                    case .stopRequested:
                        focusBorrow?.restore()
                        try finishAutomationRun(
                            status: "stopped",
                            reason: "stopFileDetected",
                            terminationKind: .userStop,
                            observation: preflight,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return

                    case .maximumRuntimeReached:
                        focusBorrow?.restore()
                        let reason = AutoLevelStopReason.maximumRuntimeReached(
                            limit: policy.maxRuntime
                        )
                        try finishAutomationRun(
                            status: "stopped",
                            reason: String(describing: reason),
                            terminationKind: .expectedLimit,
                            observation: preflight,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return

                    case let .foregroundActivationContended(detail):
                        focusBorrow?.restore()
                        lastObservation = preflight
                        activationFailureDetails.append(detail)
                        let retryDecision = activationRetry.recordUnpostedFocusFailure()
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try appendAutomationEvent(
                                kind: "activationRetry",
                                state: preflight.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: preflight.fingerprint,
                                detail: "\(detail), nextDelayMilliseconds=\(delayMilliseconds)",
                                screenshotPath: nil,
                                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop

                        case let .exhausted(attempts):
                            try appendAutomationEvent(
                                kind: "activationRetryExhausted",
                                state: preflight.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: preflight.fingerprint,
                                detail: detail,
                                screenshotPath: nil,
                                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            throw ProbeError.unsafeWindow(
                                "iPhone Mirroring lost foreground before input on all "
                                    + "\(attempts) attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        }
                    }
                }

                guard let preflight = postedPreflight,
                      let after = postedAfter,
                      let postedAt = postedActionTime
                else {
                    throw ProbeError.unsafeWindow(
                        "foreground activation ended without posting or a classified stop"
                    )
                }
                inputGeneration &+= 1
                verifiedAutomaticBattleProgress = nil
                previousTemporalFrame = nil
                battleActivityProgressDetector.reset()
                if let battleID {
                    resumableStallProgressByBattleID.removeValue(forKey: battleID)
                }
                if request.intent == .enableAllAuto, let battleID {
                    autoEnabledBattleIDs.insert(battleID)
                    let autoPostedAt = postedAt
                    stallAssessment = stallDetector.automaticBattleEnabled(
                        at: autoPostedAt,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                    _ = allAutoProgressValidator.automaticBattlePosted(
                        at: autoPostedAt,
                        battleSessionID: battleID
                    )
                    _ = battleActivityProgressDetector.automaticBattlePosted(
                        at: autoPostedAt,
                        battleSessionID: battleID,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                } else if (request.intent == .closeBattlePrompt
                            || request.intent == .pressWideModalTopButton),
                          let battleID,
                          autoEnabledBattleIDs.contains(battleID)
                {
                    // Closing a modal within an already-automatic battle changes the input
                    // generation and invalidates both temporal baselines. Start a fresh bounded
                    // progress expectation for the same battle; the prompt itself never counts
                    // as proof that automatic combat is running.
                    let resumedAt = postedAt
                    stallAssessment = stallDetector.automaticBattleEnabled(
                        at: resumedAt,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                    _ = allAutoProgressValidator.automaticBattleExpected(
                        at: resumedAt,
                        battleSessionID: battleID
                    )
                    _ = battleActivityProgressDetector.automaticBattleExpected(
                        at: resumedAt,
                        battleSessionID: battleID,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                } else {
                    stallAssessment = stallDetector.reset()
                }

                if let beforeURL, let afterURL {
                    try writePNG(preflight.image, to: beforeURL)
                    try writePNG(after.image, to: afterURL)
                }
                let frameDifference = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                    preflight.rgba.bytes,
                    after.rgba.bytes,
                    width: preflight.rgba.width,
                    height: preflight.rgba.height,
                    bytesPerRow: preflight.rgba.bytesPerRow
                )
                let captureDetail = afterURL.map { "after=\($0.path)" }
                    ?? "actionScreenshotsPersisted=false"
                try appendAutomationEvent(
                    kind: "actionPosted",
                    state: preflight.classification.state,
                    decision: String(describing: decision),
                    action: request.intent,
                    target: request.target,
                    frameFingerprint: preflight.fingerprint,
                    detail: "inputMode=\(inputMode.rawValue), captureLevel=\(captureLevel.rawValue), "
                        + "activationAttempts=\(activationRetry.currentAttempt), \(captureDetail), "
                        + "focusRestorationAfterPostCapture=\(inputMode == .foreground), "
                        + "meanAbsoluteDifference=\(frameDifference)",
                    screenshotPath: beforeURL?.path,
                    elapsed: after.capturedAt - startedAt,
                    report: &report,
                    reportURL: reportURL
                )
                // Reuse the already captured post-action frame as the controller's next input.
                // This shortens acknowledgement latency and gives the temporal detector its
                // earliest possible post-auto baseline without posting another event.
                currentObservation = after
                continue

            case let .stop(reason):
                let limitReached: Bool
                switch reason {
                case .maximumCyclesReached:
                    limitReached = true
                default:
                    limitReached = false
                }
                try finishAutomationRun(
                    status: limitReached ? "completed" : "stopped",
                    reason: String(describing: reason),
                    terminationKind: captureTerminationKind(for: reason),
                    observation: observation,
                    captureLevel: captureLevel,
                    captureRecorder: captureRecorder,
                    startedAt: startedAt,
                    directoryURL: directoryURL,
                    reportURL: reportURL,
                    report: &report
                )
                return
            }
        }
    }

    private static func captureAutomationObservation(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        captureRecorder: AutomationCaptureRecorder,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        actionDeadline: TimeInterval? = nil
    ) async throws -> AutomationObservation {
        let frame = try await captureAutomationFrame(
            requestedID: requestedID,
            expectedIdentity: expectedIdentity,
            expectedFrame: expectedFrame,
            recovery: recovery,
            phase: phase,
            actionDeadline: actionDeadline
        )
        let observation = try recognizeAutomationFrame(frame, captureRecorder: captureRecorder)
        try recovery.checkSessionBoundary()
        return observation
    }

    private static func captureAutomationFrame(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        actionDeadline: TimeInterval? = nil
    ) async throws -> AutomationCapturedFrame {
        let window = try await selectAutomationWindow(
            requestedID: requestedID, expectedIdentity: expectedIdentity,
            expectedFrame: expectedFrame, recovery: recovery,
            phase: phase, actionDeadline: actionDeadline
        )
        guard let application = window.owningApplication,
              application.processID == expectedIdentity.processID,
              window.windowID == expectedIdentity.windowID
        else {
            throw ProbeError.unsafeWindow("the iPhone Mirroring process or window identity changed")
        }
        guard approximatelyEqual(window.frame, expectedFrame, tolerance: 0.5) else {
            throw ProbeError.unsafeWindow("the iPhone Mirroring window moved or resized during automation")
        }
        let image = try await capture(window: window)
        try recovery.checkSessionBoundary()
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let rgba = try rgbaFrame(from: image)
        let frameMetrics = try FrameAnalyzer.analyzeRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        guard !frameMetrics.isBlank else {
            throw ProbeError.unsafeWindow("the automation capture was blank, transparent, or nearly black")
        }
        return AutomationCapturedFrame(
            capturedAt: capturedAt,
            windowContinuityGeneration: recovery.generation,
            window: window,
            image: image,
            rgba: rgba,
            metrics: frameMetrics
        )
    }

    private static func recognizeAutomationFrame(
        _ frame: AutomationCapturedFrame,
        captureRecorder: AutomationCaptureRecorder
    ) throws -> AutomationObservation {
        let recognized = try recognizeGameState(in: frame.image, rgba: frame.rgba)
        let observations = recognized.observations
        let classification = recognized.classification
        let fingerprint = sha256Hex(of: Data(frame.rgba.bytes))
        let observation = AutomationObservation(
            capturedAt: frame.capturedAt,
            windowContinuityGeneration: frame.windowContinuityGeneration,
            window: frame.window,
            image: frame.image,
            rgba: frame.rgba,
            metrics: frame.metrics,
            observations: observations,
            classification: classification,
            fingerprint: fingerprint
        )
        captureRecorder.record(observation)
        return observation
    }

    private static func activateAndPreflightAutomationAction(
        _ request: AutoLevelActionRequest,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        inputMode: AutoLevelInputMode,
        expectedFocusSourceProcessID: Int32?,
        activationAttempt: Int,
        activationSettleDelayMilliseconds: Int,
        battleSessionID: String?,
        allAutoStatus: AutoLevelAllAutoStatus,
        battleStatus: AutoLevelBattleStatus,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext,
        actionDeadline: TimeInterval
    ) async throws -> AutomationActionPreflightResult {
        guard request.intent != .enableAllAuto else {
            throw ProbeError.unsafeWindow(
                "the auto-level runner never presses the 全部自動 toggle"
            )
        }
        guard let runningApplication = NSRunningApplication(
            processIdentifier: identity.processID
        ) else {
            throw ProbeError.unsafeWindow("could not resolve the iPhone Mirroring application")
        }
        let activateReturned: Bool?
        if inputMode == .foreground {
            guard let expectedFocusSourceProcessID else {
                throw ProbeError.unsafeWindow("the original focused application is unavailable")
            }
            let alreadyFrontmost = ForegroundApplicationFocus.currentApplication?
                .processIdentifier == identity.processID
            activateReturned = alreadyFrontmost
                ? nil
                : ForegroundApplicationActivation.request(
                    runningApplication, options: [.activateAllWindows],
                    expectedCurrentProcessID: expectedFocusSourceProcessID
                ).accepted
            if !alreadyFrontmost {
                try await Task.sleep(for: .milliseconds(activationSettleDelayMilliseconds))
            }
        } else {
            activateReturned = nil
        }
        let preflight = try await captureAutomationObservation(
            requestedID: identity.windowID,
            expectedIdentity: identity,
            expectedFrame: expectedFrame,
            captureRecorder: captureRecorder,
            recovery: windowRecovery,
            phase: "preflight",
            actionDeadline: actionDeadline
        )
        let activation: AutomationForegroundActivationSnapshot?
        if inputMode == .foreground {
            let frontmostApplication = ForegroundApplicationFocus.currentApplication
            let snapshot = AutomationForegroundActivationSnapshot(
                attempt: activationAttempt,
                maximumAttempts: AutoLevelForegroundActivationRetryState.maximumAttempts,
                activateReturned: activateReturned,
                targetApplicationIsActive: runningApplication.isActive,
                scWindowIsActive: preflight.window.isActive,
                expectedProcessID: identity.processID,
                frontmostProcessID: frontmostApplication?.processIdentifier,
                frontmostApplicationName: frontmostApplication?.localizedName,
                frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier
            )
            guard snapshot.isReady else {
                return .activationContended(
                    observation: preflight,
                    activation: snapshot
                )
            }
            activation = snapshot
        } else {
            activation = nil
        }
        guard preflight.classification.state == request.observedState else {
            return .stateChanged(observation: preflight, activation: activation)
        }
        let runtime = AutoLevelRuntimeMetadata(
            observedAt: preflight.capturedAt,
            windowIdentity: identity,
            frameFingerprint: preflight.fingerprint,
            battleSessionID: battleSessionID,
            allAutoStatus: allAutoStatus,
            battleStatus: battleStatus
        )
        let candidates = AutoLevelSnapshot(
            classification: preflight.classification,
            runtime: runtime
        ).actionCandidates.filter { $0.intent == request.intent }
        guard candidates.count == 1,
              let confirmed = candidates.first,
              automationTargetsMatch(request.target, confirmed.target)
        else {
            throw ProbeError.unsafeWindow(
                "the named action target was missing, ambiguous, or moved during confirmation"
            )
        }
        return .confirmed(
            observation: preflight,
            target: confirmed.target,
            activation: activation
        )
    }

    private static func postAutomationClick(
        _ request: AutoLevelActionRequest,
        confirmedTarget: AutoLevelActionTarget,
        using observation: AutomationObservation,
        activation: AutomationForegroundActivationSnapshot?,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        inputMode: AutoLevelInputMode,
        actionDeadline: TimeInterval,
        sessionDeadline: TimeInterval,
        stopURL: URL
    ) throws -> AutomationClickResult {
        guard request.intent != .enableAllAuto else {
            throw ProbeError.unsafeWindow(
                "the auto-level input boundary refused the 全部自動 toggle"
            )
        }
        guard observation.window.windowID == identity.windowID,
              observation.window.owningApplication?.processID == identity.processID,
              approximatelyEqual(observation.window.frame, expectedFrame, tolerance: 0.5)
        else {
            throw ProbeError.unsafeWindow("the preflight window identity or geometry changed")
        }
        let point = confirmedTarget.point
        let rect = confirmedTarget.rect
        guard rect.isValid,
              point.x >= rect.x, point.x <= rect.x + rect.width,
              point.y >= rect.y, point.y <= rect.y + rect.height,
              point.x >= 0.02, point.x <= 0.98, point.y >= 0.02, point.y <= 0.98,
              !isInsideAllAutoForbiddenRegion(point)
        else {
            throw ProbeError.unsafeWindow("the confirmed action target was outside the safe content area")
        }
        let clickPoint = CGPoint(
            x: expectedFrame.minX + expectedFrame.width * point.x,
            y: expectedFrame.minY + expectedFrame.height * point.y
        )
        let expectedGeometry = automationWindowGeometry(expectedFrame)
        let previousMouseLocation = inputMode == .foreground ? CGEvent(source: nil)?.location : nil
        var boundaryResult: AutomationClickResult?
        var authorizedPostTime: TimeInterval?
        let posted = try postSingleClick(
            at: clickPoint,
            processID: inputMode == .process ? identity.processID : nil
        ) {
            let windows = windowServerWindows() ?? []
            let currentWindow = windows.first { $0.identity.windowID == identity.windowID }
            let topmostWindow = topmostInputWindow(
                at: clickPoint,
                expectedWindowFrame: expectedFrame,
                expectedProcessID: identity.processID,
                windows: windows
            )
            let targetProcessTopmostWindow = windows.first {
                $0.identity.processID == identity.processID
                    && $0.alpha > 0.01
                    && $0.frame.contains(clickPoint)
            }
            let frontmostApplication = inputMode == .foreground
                ? ForegroundApplicationFocus.currentApplication : nil
            let frontmostProcessID = frontmostApplication?.processIdentifier
            let snapshot = AutoLevelInputSnapshot(
                windowIdentity: currentWindow?.identity,
                windowGeometry: currentWindow.map { automationWindowGeometry($0.frame) },
                frontmostProcessID: frontmostProcessID,
                topmostWindowIdentity: topmostWindow?.identity,
                targetProcessTopmostWindowIdentity: targetProcessTopmostWindow?.identity
            )
            let now = ProcessInfo.processInfo.systemUptime
            let stopRequested = FileManager.default.fileExists(atPath: stopURL.path)
            guard let rejection = AutoLevelInputSafety.rejection(
                expectedWindowIdentity: identity,
                expectedWindowGeometry: expectedGeometry,
                inputMode: inputMode,
                snapshot: snapshot,
                now: now,
                actionDeadline: actionDeadline,
                sessionDeadline: sessionDeadline,
                stopRequested: stopRequested
            ) else {
                authorizedPostTime = now
                return true
            }
            switch rejection {
            case .stopRequested:
                boundaryResult = .stopRequested
                return false
            case .invalidTiming:
                throw ProbeError.unsafeWindow("the final input timing check was invalid")
            case .actionAuthorizationExpired:
                throw ProbeError.unsafeWindow(
                    "the action authorization expired during confirmation"
                )
            case .sessionRuntimeExpired:
                boundaryResult = .maximumRuntimeReached
                return false
            case .windowUnavailable:
                throw ProbeError.unsafeWindow(
                    "the requested window disappeared immediately before input"
                )
            case .windowIdentityChanged:
                throw ProbeError.unsafeWindow(
                    "the window identity changed immediately before input"
                )
            case .windowGeometryChanged:
                throw ProbeError.unsafeWindow(
                    "the window geometry changed immediately before input"
                )
            case .applicationNotFrontmost:
                guard AutoLevelForegroundActivationRetryState.permitsRetry(
                    after: rejection,
                    inputWasPosted: false
                ) else {
                    throw ProbeError.unsafeWindow(
                        "the final input boundary rejected a non-retryable focus loss"
                    )
                }
                let boundarySnapshot = AutomationForegroundActivationSnapshot(
                    attempt: activation?.attempt ?? 1,
                    maximumAttempts: activation?.maximumAttempts
                        ?? AutoLevelForegroundActivationRetryState.maximumAttempts,
                    activateReturned: activation?.activateReturned,
                    targetApplicationIsActive: NSRunningApplication(
                        processIdentifier: identity.processID
                    )?.isActive ?? false,
                    scWindowIsActive: observation.window.isActive,
                    expectedProcessID: identity.processID,
                    frontmostProcessID: frontmostApplication?.processIdentifier,
                    frontmostApplicationName: frontmostApplication?.localizedName,
                    frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier
                )
                boundaryResult = .foregroundActivationContended(
                    detail: boundarySnapshot.detail(
                        phase: "finalInputBoundary",
                        result: "focusContended"
                    )
                )
                return false
            case .clickPointObscured:
                let message = inputMode == .process
                    ? "another iPhone Mirroring window was above the locked mirror at the action point"
                    : "another window was above the confirmed action point immediately before input"
                throw ProbeError.unsafeWindow(message)
            }
        }
        guard posted else {
            guard let boundaryResult else {
                throw ProbeError.unsafeWindow(
                    "the final input boundary refused input without a classified reason"
                )
            }
            return boundaryResult
        }
        if let previousMouseLocation {
            CGWarpMouseCursorPosition(previousMouseLocation)
        }
        guard let authorizedPostTime else {
            throw ProbeError.unsafeWindow(
                "the input was posted without a recorded authorization timestamp"
            )
        }
        return .posted(at: authorizedPostTime)
    }

    /// `全部自動` is a persistent toggle, not an idempotent command. Keep a final
    /// coordinate-level deny-list at the input boundary so even a mislabeled detector target
    /// cannot switch automatic combat off.
    private static func isInsideAllAutoForbiddenRegion(
        _ point: MirrorProbeCore.NormalizedPoint
    ) -> Bool {
        (0.15...0.45).contains(point.x)
            && (0.83...0.93).contains(point.y)
    }

    private static func automationTargetsMatch(
        _ lhs: AutoLevelActionTarget,
        _ rhs: AutoLevelActionTarget
    ) -> Bool {
        lhs.name == rhs.name
            && abs(lhs.point.x - rhs.point.x) <= 0.02
            && abs(lhs.point.y - rhs.point.y) <= 0.02
            && abs(lhs.rect.width - rhs.rect.width) <= 0.05
            && abs(lhs.rect.height - rhs.rect.height) <= 0.05
    }

    private static func automationBattleContext(
        for observation: AutomationObservation,
        identity: AutoLevelWindowIdentity
    ) -> BattleWindowContext {
        automationBattleContext(window: observation.window, rgba: observation.rgba, identity: identity)
    }

    private static func automationBattleContext(
        window: SCWindow,
        rgba: RGBAFrame,
        identity: AutoLevelWindowIdentity
    ) -> BattleWindowContext {
        let frame = window.frame
        let scaleFactor = frame.width > 0
            ? Double(rgba.width) / Double(frame.width)
            : 1
        return BattleWindowContext(
            processID: identity.processID,
            windowID: identity.windowID,
            originX: Double(frame.origin.x),
            originY: Double(frame.origin.y),
            width: rgba.width,
            height: rgba.height,
            scaleFactor: scaleFactor
        )
    }

    private static func automationBattleRegionDifference(
        previous: AutomationTemporalFrame?,
        current: AutomationObservation,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) throws -> Double? {
        guard let previous,
              previous.context == context,
              previous.inputGeneration == inputGeneration,
              previous.rgba.width == current.rgba.width,
              previous.rgba.height == current.rgba.height,
              previous.rgba.bytesPerRow == current.rgba.bytesPerRow
        else {
            return nil
        }
        return try automationBattlePixelDifference(previous.rgba, current.rgba)
    }

    private static func automationBattlePixelDifference(
        _ previous: RGBAFrame,
        _ current: RGBAFrame
    ) throws -> Double? {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow
        else { return nil }
        return try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            previous.bytes,
            current.bytes,
            width: current.width,
            height: current.height,
            bytesPerRow: current.bytesPerRow,
            region: BattleStallDetector.battleROI
        )
    }

    /// A bounded capture-only burst. OCR runs at the two boundaries; fast frames provide only
    /// visual continuity, never a fabricated battle classification. No focus or input is used.
    private static func confirmAutomationVisualStability(
        _ initialConfirmation: BattleVisualStabilityConfirmation,
        anchor: AutomationObservation,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        inputGeneration: UInt64,
        sessionDeadline: TimeInterval,
        stopURL: URL,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext
    ) async throws -> AutomationVisualConfirmationResult {
        var confirmation = initialConfirmation
        var previous = anchor.rgba
        let burstDeadline = ProcessInfo.processInfo.systemUptime + 7
        func interrupted() -> Bool {
            FileManager.default.fileExists(atPath: stopURL.path)
                || ProcessInfo.processInfo.systemUptime >= sessionDeadline
        }
        while !confirmation.isComplete {
            if interrupted() { return .interrupted }
            try await Task.sleep(for: .milliseconds(400))
            if interrupted() { return .interrupted }
            let frame = try await captureAutomationFrame(
                requestedID: identity.windowID,
                expectedIdentity: identity,
                expectedFrame: expectedFrame,
                recovery: windowRecovery,
                phase: "densePixels"
            )
            if interrupted() { return .interrupted }
            if frame.windowContinuityGeneration != anchor.windowContinuityGeneration {
                let fresh = try recognizeAutomationFrame(frame, captureRecorder: captureRecorder)
                return .rejected(fresh, detail: "windowAvailabilityInterruptedPixelContinuity")
            }
            let context = automationBattleContext(window: frame.window, rgba: frame.rgba, identity: identity)
            let previousDifference = try automationBattlePixelDifference(previous, frame.rgba)
            let anchorDifference = try automationBattlePixelDifference(anchor.rgba, frame.rgba)
            let accepted = confirmation.observe(
                monotonicTime: frame.capturedAt,
                context: context,
                inputGeneration: inputGeneration,
                differenceFromPrevious: previousDifference,
                differenceFromAnchor: anchorDifference
            )
            guard accepted, frame.capturedAt <= burstDeadline else {
                let observation = try recognizeAutomationFrame(frame, captureRecorder: captureRecorder)
                return .rejected(observation, detail: "pixelChangeOrSampleDiscontinuity, "
                    + "previousMAD=\(previousDifference.map(String.init(describing:)) ?? "unavailable"), "
                    + "anchorMAD=\(anchorDifference.map(String.init(describing:)) ?? "unavailable")")
            }
            previous = frame.rgba
        }
        if interrupted() { return .interrupted }
        let final = try await captureAutomationObservation(
            requestedID: identity.windowID,
            expectedIdentity: identity,
            expectedFrame: expectedFrame,
            captureRecorder: captureRecorder,
            recovery: windowRecovery,
            phase: "denseFinalOCR"
        )
        if interrupted() { return .interrupted }
        guard final.windowContinuityGeneration == anchor.windowContinuityGeneration else {
            return .rejected(final, detail: "windowAvailabilityInterruptedFinalContinuity")
        }
        let finalSample = BattleStallSample(
            monotonicTime: final.capturedAt,
            context: automationBattleContext(for: final, identity: identity),
            battleScreenConfirmed: final.classification.state == .battle,
            modalPresent: isAutomationModal(final.classification.state),
            paused: automationIsPaused(final.observations),
            inputGeneration: inputGeneration,
            frameEvidence: BattleStallFrameEvidence.extract(from: final.observations),
            battleROIDifferenceFromPrevious: try automationBattlePixelDifference(previous, final.rgba)
        )
        guard let assessment = confirmation.validate(
            finalSample,
            differenceFromAnchor: try automationBattlePixelDifference(anchor.rgba, final.rgba)
        ) else {
            return .rejected(final, detail: "finalBattleClassificationOrContinuityLost")
        }
        return .confirmed(confirmation, final, assessment)
    }

    private static func isAutomationModal(_ state: GameState) -> Bool {
        switch state {
        case .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt,
             .retreatConfirmation, .lootCollectionConfirmation,
             .adventurerRecruitment, .missionComplete,
             .missionCompleteRepeatSelected, .missionFailed,
             .missionFailedRepeatSelected, .wideModalOneButton,
             .wideModalTwoButtons, .inventoryFull:
            return true
        case .battle, .defeat, .unknown:
            return false
        }
    }

    private static func automationIsPaused(_ observations: [OCRTextObservation]) -> Bool {
        observations.contains { observation in
            let text = observation.text
                .precomposedStringWithCompatibilityMapping
                .uppercased()
                .filter { !$0.isWhitespace }
            return text == "繼續" || text == "恢復" || text == "RESUME"
        }
    }

    private static func automationStallDetail(
        _ assessment: BattleStallAssessment
    ) -> String {
        let enemy = assessment.enemyHP.map {
            "\($0.current)/\($0.maximum)"
        } ?? "none"
        let reset = assessment.resetReason?.rawValue ?? "none"
        return "stallPhase=\(assessment.phase.rawValue), armed=\(assessment.isArmed), "
            + "stableSeconds=\(assessment.stableDuration), samples=\(assessment.stableSampleCount), "
            + "zeroParty=\(assessment.zeroPartyMembers), enemyHP=\(enemy), reset=\(reset)"
    }

    private static func appendAutomationEvent(
        kind: String,
        state: GameState?,
        decision: String?,
        action: AutoLevelActionIntent?,
        target: AutoLevelActionTarget?,
        frameFingerprint: String?,
        detail: String?,
        screenshotPath: String?,
        elapsed: TimeInterval,
        report: inout AutomationRunReport,
        reportURL: URL
    ) throws {
        report.events.append(AutomationRunEvent(
            sequence: report.events.count + 1,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            elapsedSeconds: max(0, elapsed),
            kind: kind,
            state: state,
            decision: decision,
            action: action,
            target: target,
            frameFingerprint: frameFingerprint,
            detail: detail,
            screenshotPath: screenshotPath
        ))
        try writeJSON(report, to: reportURL)
    }

    private static func finishAutomationRun(
        status: String,
        reason: String,
        terminationKind: AutoLevelCaptureTerminationKind,
        observation: AutomationObservation?,
        captureLevel: AutoLevelCaptureLevel,
        captureRecorder: AutomationCaptureRecorder,
        startedAt: TimeInterval,
        directoryURL: URL,
        reportURL: URL,
        report: inout AutomationRunReport
    ) throws {
        let diagnosticResult = persistAutomationTerminationScreenshots(
            captureLevel: captureLevel,
            terminationKind: terminationKind,
            observation: observation,
            captureRecorder: captureRecorder,
            startedAt: startedAt,
            directoryURL: directoryURL
        )
        report.diagnosticScreenshots.append(contentsOf: diagnosticResult.screenshots)
        report.diagnosticPersistenceErrors.append(contentsOf: diagnosticResult.errors)
        report.status = status
        report.endedAt = ISO8601DateFormatter().string(from: Date())
        report.finalReason = reason
        try appendAutomationEvent(
            kind: "sessionEnded",
            state: observation?.classification.state,
            decision: nil,
            action: nil,
            target: nil,
            frameFingerprint: observation?.fingerprint,
            detail: diagnosticResult.errors.isEmpty
                ? reason
                : "\(reason); diagnosticPersistenceErrors="
                    + diagnosticResult.errors.joined(separator: " | "),
            screenshotPath: diagnosticResult.finalPath,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
            report: &report,
            reportURL: reportURL
        )
    }

    private static func captureTerminationKind(
        for reason: AutoLevelStopReason
    ) -> AutoLevelCaptureTerminationKind {
        switch reason {
        case .maximumCyclesReached, .maximumRuntimeReached:
            return .expectedLimit
        default:
            return .safetyStop
        }
    }

    /// Writes screenshots only after the termination category is known. Every write is
    /// best-effort so a full disk or encoding failure cannot replace the original stop reason.
    private static func persistAutomationTerminationScreenshots(
        captureLevel: AutoLevelCaptureLevel,
        terminationKind: AutoLevelCaptureTerminationKind,
        observation: AutomationObservation?,
        captureRecorder: AutomationCaptureRecorder,
        startedAt: TimeInterval,
        directoryURL: URL
    ) -> AutomationDiagnosticPersistenceResult {
        let plan = AutoLevelCaptureRetentionPolicy(level: captureLevel)
            .plan(for: terminationKind)
        guard plan.retainsRecent || plan.retainsFinal else {
            return AutomationDiagnosticPersistenceResult(
                finalPath: nil,
                screenshots: [],
                errors: []
            )
        }

        var captures = captureRecorder.capturesOldestFirst
        if captures.isEmpty, let observation {
            // Successful automation captures are normally recorded immediately. This fallback
            // keeps a final frame if a future caller supplies an independently built observation.
            captures = [BufferedAutomationCapture(
                sequence: 0,
                capturedAt: observation.capturedAt,
                state: observation.classification.state,
                fingerprint: observation.fingerprint,
                image: observation.image
            )]
        }

        var screenshots: [AutomationDiagnosticScreenshotReport] = []
        var errors: [String] = []
        var finalPath: String?

        func persist(
            _ capture: BufferedAutomationCapture,
            to url: URL,
            role: AutomationDiagnosticScreenshotRole
        ) {
            do {
                try writePNG(capture.image, to: url)
                screenshots.append(AutomationDiagnosticScreenshotReport(
                    captureSequence: capture.sequence,
                    capturedAtElapsedSeconds: max(0, capture.capturedAt - startedAt),
                    state: capture.state,
                    frameFingerprint: capture.fingerprint,
                    path: url.path,
                    role: role
                ))
                if role == .final {
                    finalPath = url.path
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                errors.append("\(url.path): \(message)")
            }
        }

        if plan.retainsRecent, !captures.isEmpty {
            // The newest retained sample becomes final.png instead of being duplicated. Thus an
            // error-level run writes at most eight PNG files in total.
            for capture in captures.dropLast() {
                let filename = String(format: "capture-%04llu.png", capture.sequence)
                let url = directoryURL
                    .appendingPathComponent("diagnostics", isDirectory: true)
                    .appendingPathComponent(filename)
                persist(capture, to: url, role: .recent)
            }
            if plan.retainsFinal, let newest = captures.last {
                persist(
                    newest,
                    to: directoryURL.appendingPathComponent("final.png"),
                    role: .final
                )
            }
        } else if plan.retainsFinal, let newest = captures.last {
            persist(
                newest,
                to: directoryURL.appendingPathComponent("final.png"),
                role: .final
            )
        }

        return AutomationDiagnosticPersistenceResult(
            finalPath: finalPath,
            screenshots: screenshots,
            errors: errors
        )
    }

    private static func ensureScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ProbeError.screenCapturePermissionRequired
        }
    }

    private static func ensurePostEventPermission() throws {
        guard CGPreflightPostEventAccess() else {
            throw ProbeError.postEventPermissionRequired
        }
    }

    private static func mirrorWindowCandidates() async throws -> [SCWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            // Keep rejected mirror candidates for diagnostics; never persist another app's windows.
            return content.windows.filter {
                $0.owningApplication?.bundleIdentifier == mirrorBundleIdentifier
            }.sorted { $0.windowID < $1.windowID }
        } catch {
            throw ProbeError.captureFailed(error.localizedDescription)
        }
    }

    private static func isEligibleMirrorWindow(_ window: SCWindow) -> Bool {
        window.windowLayer == 0 && window.isOnScreen
            && window.frame.width >= 120 && window.frame.height >= 200
    }

    private static func mirrorWindows() async throws -> [SCWindow] {
        try await mirrorWindowCandidates().filter(isEligibleMirrorWindow)
    }

    /// Only a missing eligible window enters recovery. A replacement window, moved geometry,
    /// capture error, or lost permission never renews the session's locked identity.
    private static func selectAutomationWindow(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        actionDeadline: TimeInterval?
    ) async throws -> SCWindow {
        var retry: AutoLevelWindowAvailabilityRetry?
        while true {
            try recovery.checkSessionBoundary()
            if var budget = retry {
                if let reason = budget.validateBoundary(
                    at: ProcessInfo.processInfo.systemUptime,
                    stopRequested: FileManager.default.fileExists(atPath: recovery.stopURL.path)
                ) {
                    try throwWindowRecoveryStop(reason, windowID: requestedID, phase: phase)
                }
                retry = budget
            }
            let candidates = try await mirrorWindowCandidates()
            try recovery.checkSessionBoundary()
            if var budget = retry {
                if let reason = budget.validateBoundary(at: ProcessInfo.processInfo.systemUptime) {
                    try throwWindowRecoveryStop(reason, windowID: requestedID, phase: phase)
                }
                retry = budget
            }
            if let window = candidates.first(where: {
                $0.windowID == requestedID && isEligibleMirrorWindow($0)
            }) {
                guard window.owningApplication?.processID == expectedIdentity.processID,
                      window.windowID == expectedIdentity.windowID else {
                    throw ProbeError.unsafeWindow("the iPhone Mirroring process or window identity changed")
                }
                guard approximatelyEqual(window.frame, expectedFrame, tolerance: 0.5) else {
                    throw ProbeError.unsafeWindow("the iPhone Mirroring window moved or resized during automation")
                }
                if let budget = retry {
                    logWindowAvailability(
                        "recovered", phase: phase, identity: expectedIdentity,
                        candidates: candidates, retry: budget, detail: "sameIdentityAndGeometry=true"
                    )
                }
                return window
            }
            if retry == nil {
                recovery.interruptContinuity()
                retry = AutoLevelWindowAvailabilityRetry(
                    startedAt: ProcessInfo.processInfo.systemUptime,
                    sessionDeadline: recovery.sessionDeadline,
                    actionDeadline: actionDeadline
                )
            }
            guard var budget = retry else { throw ProbeError.requestedWindowNotFound(requestedID) }
            logWindowAvailability(
                "missing", phase: phase, identity: expectedIdentity,
                candidates: candidates, retry: budget, detail: "inputSuspendedDuringRecovery=true"
            )
            let decision = budget.recordMissing(
                at: ProcessInfo.processInfo.systemUptime,
                stopRequested: FileManager.default.fileExists(atPath: recovery.stopURL.path)
            )
            retry = budget
            switch decision {
            case let .retry(_, delaySeconds):
                // Short slices keep STOP responsive without making another capture query.
                let wakeAt = ProcessInfo.processInfo.systemUptime + delaySeconds
                while ProcessInfo.processInfo.systemUptime < wakeAt {
                    try recovery.checkSessionBoundary()
                    try await Task.sleep(for: .seconds(min(
                        0.1, max(0, wakeAt - ProcessInfo.processInfo.systemUptime)
                    )))
                }
            case let .stop(reason):
                logWindowAvailability(
                    "exhausted", phase: phase, identity: expectedIdentity,
                    candidates: candidates, retry: budget, detail: String(describing: reason)
                )
                try throwWindowRecoveryStop(reason, windowID: requestedID, phase: phase)
            }
        }
    }

    private static func throwWindowRecoveryStop(
        _ reason: AutoLevelWindowAvailabilityRetryStopReason,
        windowID: UInt32,
        phase: String
    ) throws -> Never {
        switch reason {
        case .stopRequested: throw AutomationCaptureInterruption.stopRequested
        case .sessionExpired: throw AutomationCaptureInterruption.sessionExpired
        default:
            throw ProbeError.unsafeWindow(
                "iPhone Mirroring window ID \(windowID) remained unavailable within the bounded "
                    + "capture recovery; phase=\(phase), reason=\(reason). "
                    + "This does not establish that the window was closed; see windowAvailability diagnostics."
            )
        }
    }

    private static func logWindowAvailability(
        _ outcome: String,
        phase: String,
        identity: AutoLevelWindowIdentity,
        candidates: [SCWindow],
        retry: AutoLevelWindowAvailabilityRetry,
        detail: String
    ) {
        let app = NSRunningApplication(processIdentifier: identity.processID)
        let cgWindows = CGWindowListCopyWindowInfo(.optionIncludingWindow, identity.windowID)
            as? [[String: Any]] ?? []
        let exactCGWindow = cgWindows.first {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowID
        }
        let diagnostics: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome, "phase": phase, "attempt": retry.attempt,
            "elapsedMissingSeconds": ProcessInfo.processInfo.systemUptime - retry.startedAt,
            "expectedPID": identity.processID, "expectedWindowID": identity.windowID,
            "targetProcessRunning": app.map { !$0.isTerminated } ?? false,
            "targetApplicationHidden": app.map { $0.isHidden as Any } ?? NSNull(),
            "frontmostPID": ForegroundApplicationFocus.read().processID.map { $0 as Any } ?? NSNull(),
            "windowServerHasExpectedID": exactCGWindow != nil,
            "windowServerOnScreen": exactCGWindow?[kCGWindowIsOnscreen as String] ?? NSNull(),
            "inputWasPostedForThisCapture": phase == "afterPost",
            "detail": detail,
            "candidatesBeforeEligibilityFilter": candidates.map { window -> [String: Any] in [
                "id": window.windowID,
                "pid": window.owningApplication?.processID ?? 0,
                "onScreen": window.isOnScreen, "layer": window.windowLayer,
                "x": window.frame.minX, "y": window.frame.minY,
                "width": window.frame.width, "height": window.frame.height
            ] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data("windowAvailability: \(text)\n".utf8))
        }
    }

    private static func selectMirrorWindow(requestedID: UInt32?) async throws -> SCWindow {
        let windows = try await mirrorWindows()
        if let requestedID {
            guard let window = windows.first(where: { $0.windowID == requestedID }) else {
                throw ProbeError.requestedWindowNotFound(requestedID)
            }
            return window
        }
        guard !windows.isEmpty else {
            throw ProbeError.noMirrorWindow
        }
        guard windows.count == 1 else {
            throw ProbeError.ambiguousMirrorWindows(windows.map(\.windowID))
        }
        return windows[0]
    }

    private static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ProbeError.captureFailed(error.localizedDescription)
        }
    }

    private static func rgbaFrame(from image: CGImage) throws -> RGBAFrame {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = Array(repeating: UInt8(0), count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            throw ProbeError.frameConversionFailed
        }
        return RGBAFrame(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func metrics(for image: CGImage) throws -> FrameMetrics {
        let frame = try rgbaFrame(from: image)
        return try FrameAnalyzer.analyzeRGBA(
            frame.bytes,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow
        )
    }

    @discardableResult
    private static func writePNG(_ image: CGImage, to outputURL: URL) throws -> String {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ProbeError.pngEncodingFailed
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        return sha256Hex(of: data)
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func outputURL(for path: String, isDirectory: Bool = false) throws -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path, isDirectory: isDirectory)
        }
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url.standardizedFileURL
    }

    private static func postSingleClick(
        at point: CGPoint,
        processID: Int32? = nil,
        validateBeforePost: () throws -> Bool = { true }
    ) throws -> Bool {
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw ProbeError.unsafeWindow("could not create the mouse events")
        }
        AutomationInputMarker.mark(mouseDown)
        AutomationInputMarker.mark(mouseUp)

        guard try validateBeforePost() else {
            return false
        }
        if let processID {
            mouseDown.postToPid(processID)
        } else {
            mouseDown.post(tap: .cghidEventTap)
        }
        usleep(60_000)
        if let processID {
            mouseUp.postToPid(processID)
        } else {
            mouseUp.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func topmostInputWindow(
        at point: CGPoint,
        expectedWindowFrame: CGRect,
        expectedProcessID: Int32,
        windows: [WindowServerWindow]? = nil
    ) -> WindowServerWindow? {
        let candidates = windows ?? windowServerWindows() ?? []
        let hitProcessID = accessibilityHitProcessID(at: point)
        return candidates.first {
            $0.alpha > 0.01
                && $0.frame.contains(point)
                && !isNonOccludingDockBackdrop(
                    $0,
                    covering: expectedWindowFrame,
                    hitProcessID: hitProcessID,
                    expectedProcessID: expectedProcessID
                )
        }
    }

    /// Dock owns a transparent, full-display management surface above ordinary windows. It is
    /// present in the front-to-back WindowServer list but does not receive the click. Ignore only
    /// the observed Dock/layer signature and only when Accessibility hit-testing independently
    /// proves that input at this point belongs to the expected process. The visible Dock and
    /// interactive Dock-owned surfaces therefore remain occluders.
    private static func isNonOccludingDockBackdrop(
        _ window: WindowServerWindow,
        covering expectedWindowFrame: CGRect,
        hitProcessID: Int32?,
        expectedProcessID: Int32
    ) -> Bool {
        window.ownerBundleIdentifier == "com.apple.dock"
            && window.layer == 20
            && window.name == "Dock"
            && window.frame.contains(expectedWindowFrame)
            && hitProcessID == expectedProcessID
    }

    private static func accessibilityHitProcessID(at point: CGPoint) -> Int32? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
            let hitElement
        else {
            return nil
        }
        var processID: pid_t = 0
        guard AXUIElementGetPid(hitElement, &processID) == .success else {
            return nil
        }
        return processID
    }

    private static func windowServerWindows() -> [WindowServerWindow]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return list.compactMap { entry in
            guard let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDictionary["X"] as? NSNumber)?.doubleValue,
                  let y = (boundsDictionary["Y"] as? NSNumber)?.doubleValue,
                  let width = (boundsDictionary["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDictionary["Height"] as? NSNumber)?.doubleValue,
                  let windowNumber = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32
            else {
                return nil
            }
            return WindowServerWindow(
                identity: AutoLevelWindowIdentity(
                    processID: ownerPID,
                    windowID: windowNumber
                ),
                frame: CGRect(x: x, y: y, width: width, height: height),
                alpha: alpha,
                layer: layer,
                name: entry[kCGWindowName as String] as? String,
                ownerBundleIdentifier: NSRunningApplication(
                    processIdentifier: ownerPID
                )?.bundleIdentifier
            )
        }
    }

    private static func automationWindowGeometry(_ frame: CGRect) -> AutoLevelWindowGeometry {
        AutoLevelWindowGeometry(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    @MainActor
    private static func establishAppKitConnection() {
        // ScreenCaptureKit needs an AppKit/WindowServer connection. Commands that only
        // analyze an existing image deliberately avoid registering as a GUI application.
        _ = NSApplication.shared
    }

    private static func windowReport(_ window: SCWindow) -> WindowReport {
        let app = window.owningApplication
        return WindowReport(
            windowID: window.windowID,
            processID: app?.processID ?? 0,
            applicationName: app?.applicationName ?? "",
            bundleIdentifier: app?.bundleIdentifier ?? "",
            title: window.title ?? "",
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height,
            onScreen: window.isOnScreen,
            active: window.isActive
        )
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func validateOptions(
        _ arguments: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String> = []
    ) throws {
        var seen = Set<String>()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw ProbeError.invalidArguments("Unexpected positional argument '\(argument)'")
            }
            guard !seen.contains(argument) else {
                throw ProbeError.invalidArguments("Option '\(argument)' may only be supplied once")
            }
            seen.insert(argument)

            if flagOptions.contains(argument) {
                index += 1
                continue
            }
            guard valueOptions.contains(argument) else {
                throw ProbeError.invalidArguments("Unknown option '\(argument)'")
            }
            guard index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--")
            else {
                throw ProbeError.invalidArguments("Option '\(argument)' requires a value")
            }
            index += 2
        }
    }

    private static func optionalWindowID(_ arguments: [String]) throws -> UInt32? {
        guard let value = option("--window-id", in: arguments) else {
            return nil
        }
        guard let parsed = UInt32(value) else {
            throw ProbeError.invalidArguments("--window-id must be an unsigned integer")
        }
        return parsed
    }

    private static func boundedIntegerOption(
        _ name: String,
        in arguments: [String],
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = option(name, in: arguments) else {
            return defaultValue
        }
        guard let parsed = Int(value), range.contains(parsed) else {
            throw ProbeError.invalidArguments(
                "\(name) must be an integer from \(range.lowerBound) through \(range.upperBound)"
            )
        }
        return parsed
    }

    private static func boundedDoubleOption(
        _ name: String,
        in arguments: [String],
        defaultValue: Double,
        range: ClosedRange<Double>
    ) throws -> Double {
        guard let value = option(name, in: arguments) else {
            return defaultValue
        }
        guard let parsed = Double(value), parsed.isFinite, range.contains(parsed) else {
            throw ProbeError.invalidArguments(
                "\(name) must be a number from \(range.lowerBound) through \(range.upperBound)"
            )
        }
        return parsed
    }

    private static func automationSessionID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(formatter.string(from: Date()))-\(suffix)"
    }

    private static func requiredNormalizedCoordinate(
        _ name: String,
        in arguments: [String]
    ) throws -> Double {
        guard let value = option(name, in: arguments),
              let parsed = Double(value),
              parsed.isFinite,
              parsed >= 0.02,
              parsed <= 0.98
        else {
            throw ProbeError.invalidArguments("\(name) must be a number from 0.02 through 0.98")
        }
        return parsed
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }

    private static func printUsage() {
        print(
            """
            mirror-probe — bounded iPhone Mirroring game automation and diagnostics

            Usage:
              mirror-probe doctor [--request-permissions] [--output report.json]
              mirror-probe focus-check [--window-id ID] [--output report.json]
              mirror-probe capture [--window-id ID] [--output captures/mirror-probe.png]
                [--report captures/capture-report.json]
              mirror-probe analyze [--window-id ID] [--output captures/analysis.png]
                [--report captures/analysis-report.json] [--profile \(analysisProfileName)]
              mirror-probe analyze-file --input IMAGE.png [--report REPORT.json]
                [--profile \(analysisProfileName)]
              mirror-probe click --window-id ID --x 0..1 --y 0..1 \\
                --confirm \(singleClickConfirmation) [--output-dir captures/click-test]
                [--report captures/click-report.json]
              mirror-probe reroll-character [--window-id ID]
                --confirm \(characterRerollConfirmation) [--minimum-total 90]
                [--max-rerolls 500] [--max-minutes 10]
                [--stop-file /absolute/path/to/STOP] [--report REPORT.json]
              mirror-probe run [--window-id ID] --confirm \(autoLevelConfirmation)
                [--input-mode foreground|process]
                [--max-cycles 20] [--max-minutes 120]
                [--capture-level error|info]
                --output-dir /absolute/path/to/auto-level-RUN_ID

            Safety:
              focus-check temporarily switches to the mirror and back without posting any
              mouse or keyboard events; its report verifies both observed foreground states.
              capture, analyze, and analyze-file are read-only; analysis reports always set
              actionAuthorization to none. click is a supervised diagnostic that sends exactly
              one left mouse-down/up pair and refuses blank captures, changed window geometry,
              an inactive/non-frontmost mirror, or any visible window above the exact requested
              window at the click point. reroll-character requires two stable custom-character
              snapshots, requires full-frame and focused total OCR to agree with the rendered
              one/two/three-digit glyph count, applies a terminal veto to threshold conflicts,
              and only presses the measured top-right Random control while both OCR reads safely
              establish that total is below the selected 90...100 threshold. After a click it
              waits at least 1.5 seconds and
              requires the generated-result pixels to be changed and stable in two snapshots
              before another click. run assumes the user has already entered a stage and
              enabled the game's persistent/default 全部自動 setting. It never presses that
              toggle, and each new battle must show verified progress within 30 seconds. Other
              input uses only state-specific named targets. Process input routes only to the locked
              iPhone Mirroring PID and never falls back to a global click. Foreground input requests
              a return to the previous application after the first post-click capture or a cancelled preflight, unless
              another application is already frontmost. Keep the mirror open and unminimized in
              the current Space; other windows may cover it between actions. It stops on
              inventory-full, conflicting or persistently unknown states, window/geometry
              changes, limits, or a STOP file in its output directory. Talisman use does not
              restrict automation or retreat. Screenshot level error (the default) keeps
              up to the final eight captures only after an error or safety stop; normal limits and
              STOP retain no PNG. Level info also retains initial, action-pair, and final images.
            """
        )
    }
}
