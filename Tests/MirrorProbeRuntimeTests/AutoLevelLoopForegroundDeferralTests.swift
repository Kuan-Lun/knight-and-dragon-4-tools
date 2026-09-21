import CoreGraphics
import Foundation
import MirrorProbeCore
import Testing
@testable import MirrorProbeRuntime

/// Drives the production automation loop offline. Every macOS operation is scripted: nothing
/// here captures a window, reads focus, or posts input, while the loop's policy, controller,
/// detectors, deferral and reporting are the same code the app runs.
@Suite("Automation loop foreground deferral")
struct AutoLevelLoopForegroundDeferralTests {
    private let identity = AutoLevelWindowIdentity(processID: 20, windowID: 10)
    private let frame = CGRect(x: 6, y: 30, width: 211, height: 468)

    @Test("An unreadable focus defers the click, and the loop posts it once focus can be read")
    func focusUnavailableDefersThenPosts() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let harness = try LoopHarness(directory: directory, identity: identity, frame: frame)
        harness.focusAvailable = false
        harness.onBorrowFocus = { attempt in
            if attempt == 4 { harness.focusAvailable = true }
        }
        harness.onCapture = { phase in
            if phase == "afterPost" { harness.requestStop() }
        }

        try await harness.run()

        let events = harness.report.events
        let kinds = events.map(\.kind)
        let deferredIndex = try #require(kinds.firstIndex(of: "actionDeferred"))
        let recoveredIndex = try #require(kinds.firstIndex(of: "foregroundRecovered"))
        let postedIndex = try #require(kinds.firstIndex(of: "actionPosted"))
        #expect(deferredIndex < recoveredIndex)
        #expect(recoveredIndex < postedIndex)
        #expect(kinds.last == "sessionEnded")
        #expect(kinds.filter { $0 == "actionDeferred" }.count == 1)
        #expect(kinds.contains("activationRetryExhausted"))
        #expect(!kinds.contains("sessionError"))
        #expect(harness.report.status == "stopped")
        #expect(harness.report.finalReason == "stopFileDetected")
        #expect(harness.report.actionsPosted == 1)

        let deferred = events[deferredIndex]
        #expect(deferred.action == .pressWideModalTopButton)
        #expect(deferred.decision == "continueObservation")
        #expect(deferred.detail?.contains("reason=focusUnavailable") == true)
        #expect(deferred.detail?.contains("requestID=1") == true)
        #expect(deferred.detail?.contains("deferredActions=1") == true)
        #expect(deferred.detail?.contains("backoffSeconds=5.0") == true)
        #expect(deferred.detail?.contains("noInputPosted=true") == true)
        #expect(deferred.detail?.contains(
            "the current focused application remained unavailable after 3 attempts"
        ) == true)
        let recovered = events[recoveredIndex]
        #expect(recovered.detail?.contains("deferredActions=1") == true)
        #expect(recovered.detail?.contains("requestID=2") == true)
        // The discarded request was never posted; the click belongs to a newer request.
        #expect(events[postedIndex].decision?.contains("requestID: 2") == true)
        #expect(events[postedIndex].detail?.contains("activationAttempts=1") == true)

        #expect(harness.borrowAttempts == 4)
        #expect(harness.preflights == 1)
        #expect(harness.postedClicks == 1)
        #expect(harness.restoredBorrows == 1)
        #expect(harness.sleeps.prefix(2) == [1, 1])
        #expect(harness.sleeps.filter { $0 == 0.5 }.count == 10)
        #expect(harness.captures == ["observation", "afterPost"])
    }

    @Test("Focus that stays unreadable for two minutes ends the run with the original error")
    func focusUnavailableForTwoMinutesEndsRun() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let harness = try LoopHarness(directory: directory, identity: identity, frame: frame)
        harness.focusAvailable = false
        let startedAt = harness.time

        do {
            try await harness.run()
            Issue.record("Expected the run to end with the focus error")
        } catch ProbeError.unsafeWindow(let detail) {
            #expect(detail.hasPrefix(
                "the current focused application remained unavailable after 3 attempts"
            ))
            #expect(detail.contains("foregroundDeferral: reason=focusUnavailable"))
            #expect(detail.contains("limitSeconds=120.0"))
            #expect(detail.contains("noInputPosted=true"))
        }

        let kinds = harness.report.events.map(\.kind)
        let deferrals = kinds.filter { $0 == "actionDeferred" }.count
        #expect(deferrals >= 4)
        #expect(!kinds.contains("foregroundRecovered"))
        #expect(!kinds.contains("actionPosted"))
        #expect(!kinds.contains("sessionEnded"))
        #expect(harness.time - startedAt >= 120)
        #expect(harness.preflights == 0)
        #expect(harness.postedClicks == 0)
        #expect(harness.report.actionsPosted == 0)
        #expect(harness.borrowAttempts == (deferrals + 1) * 3)
        // Backoff grew 5, 10, 20, 30 and then stayed at 30 seconds between attempts.
        let backoffs = harness.report.events.filter { $0.kind == "actionDeferred" }.map { event in
            event.detail?.contains("backoffSeconds=5.0") == true ? 5
                : event.detail?.contains("backoffSeconds=10.0") == true ? 10
                : event.detail?.contains("backoffSeconds=20.0") == true ? 20
                : event.detail?.contains("backoffSeconds=30.0") == true ? 30 : -1
        }
        #expect(backoffs.prefix(4) == [5, 10, 20, 30])
        #expect(backoffs.allSatisfy { $0 > 0 })
    }

    @Test("Contended focus after activation defers the click and restores the borrowed focus")
    func focusContendedDefersThenPosts() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let harness = try LoopHarness(directory: directory, identity: identity, frame: frame)
        harness.contendedPreflights = 3
        harness.onCapture = { phase in
            if phase == "afterPost" { harness.requestStop() }
        }

        try await harness.run()

        let events = harness.report.events
        let kinds = events.map(\.kind)
        let deferredIndex = try #require(kinds.firstIndex(of: "actionDeferred"))
        let recoveredIndex = try #require(kinds.firstIndex(of: "foregroundRecovered"))
        let postedIndex = try #require(kinds.firstIndex(of: "actionPosted"))
        #expect(deferredIndex < recoveredIndex)
        #expect(recoveredIndex < postedIndex)
        #expect(kinds.filter { $0 == "activationRetry" }.count == 2)
        #expect(kinds.contains("activationRetryExhausted"))
        #expect(harness.report.status == "stopped")
        #expect(harness.report.actionsPosted == 1)

        let deferred = events[deferredIndex]
        #expect(deferred.detail?.contains("reason=focusContended") == true)
        #expect(deferred.detail?.contains(
            "iPhone Mirroring could not be made active and frontmost after 3 attempts"
        ) == true)
        #expect(deferred.detail?.contains("frontmostPID=39056") == true)
        #expect(harness.borrowAttempts == 4)
        #expect(harness.preflights == 4)
        // Each contended attempt gave focus back before waiting; the posting borrow did too.
        #expect(harness.restoredBorrows == 4)
        #expect(harness.postedClicks == 1)
    }

    @Test("A STOP request during the deferral backoff ends the run without another capture")
    func stopDuringBackoffEndsRun() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let harness = try LoopHarness(directory: directory, identity: identity, frame: frame)
        harness.focusAvailable = false
        harness.onSleep = { seconds in
            if seconds == 0.5 { harness.requestStop() }
        }

        try await harness.run()

        let kinds = harness.report.events.map(\.kind)
        let deferredIndex = try #require(kinds.firstIndex(of: "actionDeferred"))
        #expect(kinds[deferredIndex...] == ["actionDeferred", "sessionEnded"])
        #expect(harness.report.status == "stopped")
        #expect(harness.report.finalReason == "stopFileDetected")
        #expect(harness.report.actionsPosted == 0)
        #expect(harness.sleeps == [1, 1, 0.5])
        #expect(harness.captures.isEmpty)
        #expect(harness.preflights == 0)
        #expect(harness.postedClicks == 0)
    }
}

/// Scripts the loop's platform operations and records what the loop asked for.
private final class LoopHarness {
    let identity: AutoLevelWindowIdentity
    let frame: CGRect
    let stopURL: URL
    let reportURL: URL
    let directoryURL: URL
    let captureRecorder = AutomationCaptureRecorder()
    let windowRecovery: AutomationWindowRecoveryContext
    var report: AutomationRunReport

    var time: TimeInterval = 1_000
    var focusAvailable = true
    var contendedPreflights = 0
    var borrowAttempts = 0
    var restoredBorrows = 0
    var preflights = 0
    var postedClicks = 0
    var captures: [String] = []
    var sleeps: [TimeInterval] = []
    var onBorrowFocus: ((Int) -> Void)?
    var onCapture: ((String) -> Void)?
    var onSleep: ((TimeInterval) -> Void)?

    private let image: CGImage
    private let rgba: RGBAFrame
    private let metrics: FrameMetrics

    init(directory: RuntimeTestDirectory, identity: AutoLevelWindowIdentity, frame: CGRect) throws {
        self.identity = identity
        self.frame = frame
        directoryURL = directory.url
        stopURL = directory.url.appendingPathComponent("STOP")
        reportURL = directory.url.appendingPathComponent("run-report.json")
        windowRecovery = AutomationWindowRecoveryContext(
            stopURL: stopURL, sessionDeadline: nil, initialFrame: frame
        )
        image = try runtimeTestImage()
        rgba = try MirrorProbeRuntime.rgbaFrame(from: image)
        metrics = try FrameAnalyzer.analyzeRGBA(
            rgba.bytes, width: rgba.width, height: rgba.height, bytesPerRow: rgba.bytesPerRow
        )
        report = AutomationRunReport(
            schemaVersion: automationSchemaVersion, recognitionMode: "visualRegions",
            sessionID: "loop-test", status: "running", startedAt: "2026-09-21T00:00:00Z",
            endedAt: nil,
            window: WindowReport(
                windowID: identity.windowID, processID: identity.processID,
                applicationName: "Fixture", bundleIdentifier: "test.fixture", title: "Fixture",
                x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                onScreen: true, active: true
            ),
            talismanPolicy: "unrestricted", inputMode: .foreground, captureLevel: .error,
            limits: .init(maximumCycles: nil, maximumMinutes: nil, maximumActions: nil,
                          pollIntervalSeconds: 1.5),
            outputDirectory: directory.url.path, stopFile: stopURL.path,
            completedCycles: 0, actionsPosted: 0, finalReason: nil,
            diagnosticScreenshots: [], diagnosticPersistenceErrors: [], events: [],
            timing: AutomationTimingReport()
        )
    }

    func requestStop() {
        FileManager.default.createFile(atPath: stopURL.path, contents: Data())
    }

    func run() async throws {
        let initial = modalObservation()
        try await MirrorProbeRuntime.performAutoLevelLoop(
            initialObservation: initial,
            identity: identity,
            sessionID: "loop-test",
            inputMode: .foreground,
            captureLevel: .error,
            captureRecorder: captureRecorder,
            windowRecovery: windowRecovery,
            startedAt: time,
            maximumCycles: nil,
            maximumMinutes: nil,
            maximumActions: nil,
            pollInterval: 1.5,
            directoryURL: directoryURL,
            reportURL: reportURL,
            stopURL: stopURL,
            operations: operations(),
            report: &report
        )
    }

    /// A one-button dialog whose only allowed action is its top button, as the classifier
    /// reports it for a skill or reward prompt. Captured "now" so freshness checks pass.
    func modalObservation() -> AutomationObservation {
        let rect = NormalizedRect(x: 0.108, y: 0.537, width: 0.783, height: 0.040)
        let classification = GameStateClassification(
            state: .wideModalOneButton,
            evidence: [],
            allowedActions: [AllowedGameAction(
                name: .pressWideModalTopButton,
                target: NamedGameTarget(
                    name: .wideModalTopButton, sourceText: "<measured-wide-modal-primary-button>",
                    rect: rect, point: rect.center
                )
            )]
        )
        let observation = AutomationObservation(
            capturedAt: time,
            recognitionDurationSeconds: 0.01,
            windowContinuityGeneration: windowRecovery.generation,
            window: AutomationWindowSnapshot(
                windowID: identity.windowID, processID: identity.processID, frame: frame,
                isActive: true
            ),
            image: image,
            rgba: rgba,
            layout: .identity(width: rgba.width, height: rgba.height),
            metrics: metrics,
            stallEvidence: BattleStallFrameEvidence.extractVisual(from: classification),
            activityEvidence: BattleActivityFrameEvidence(
                hasStrictBattleBackground: false, hpReadings: [], combatLogSignature: ""
            ),
            classification: classification,
            fingerprint: "modal-\(time)"
        )
        captureRecorder.record(observation)
        return observation
    }

    private func operations() -> AutoLevelLoopOperations {
        AutoLevelLoopOperations(
            now: { self.time },
            sleep: { seconds in
                self.sleeps.append(seconds)
                self.time += seconds
                self.onSleep?(seconds)
            },
            captureObservation: { phase, _ in
                self.captures.append(phase)
                self.onCapture?(phase)
                return self.modalObservation()
            },
            confirmVisualStability: { _, _, _ in
                Issue.record("The dialog scenario never confirms battle visual stability")
                throw ProbeError.unsafeWindow("unexpected visual stability confirmation")
            },
            borrowFocus: { _ in
                self.borrowAttempts += 1
                self.onBorrowFocus?(self.borrowAttempts)
                guard self.focusAvailable else { return nil }
                return RecordedFocusBorrow(previousProcessID: 4_360, harness: self)
            },
            activateAndPreflight: { preflight in
                self.preflights += 1
                let observation = self.modalObservation()
                let contended = self.contendedPreflights > 0
                if contended { self.contendedPreflights -= 1 }
                let activation = AutomationForegroundActivationSnapshot(
                    attempt: preflight.activationAttempt,
                    maximumAttempts: AutoLevelForegroundActivationRetryState.maximumAttempts,
                    activateReturned: false,
                    targetApplicationIsActive: !contended,
                    scWindowIsActive: true,
                    expectedProcessID: self.identity.processID,
                    frontmostProcessID: contended ? 39_056 : self.identity.processID,
                    frontmostApplicationName: contended ? "Firefox" : "iPhone Mirroring",
                    frontmostBundleIdentifier: nil
                )
                if contended {
                    return .activationContended(observation: observation, activation: activation)
                }
                return .confirmed(
                    observation: observation, target: preflight.request.target,
                    activation: activation
                )
            },
            postClick: { _ in
                self.postedClicks += 1
                return .posted(at: self.time, cursorDisturbed: false)
            }
        )
    }
}

private struct RecordedFocusBorrow: AutomationFocusBorrow {
    let previousProcessID: Int32
    let harness: LoopHarness
    private var restored = false

    init(previousProcessID: Int32, harness: LoopHarness) {
        self.previousProcessID = previousProcessID
        self.harness = harness
    }

    mutating func restore() -> ForegroundActivationRequest? {
        guard !restored else { return nil }
        restored = true
        harness.restoredBorrows += 1
        return nil
    }
}
