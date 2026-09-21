import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    /// Discards an unposted action whose foreground focus is unavailable or contended, records
    /// the deferral, and waits out its backoff. Returns the terminal reason instead when the
    /// bounded patience ran out; the caller throws it so the run ends as it did before.
    static func deferForegroundAction(
        reason: AutoLevelForegroundDeferralReason,
        request: AutoLevelActionRequest,
        observation: AutomationObservation,
        failure: String,
        controller: inout AutoLevelController,
        deferral: inout AutoLevelForegroundDeferralState,
        startedAt: TimeInterval,
        stopURL: URL,
        sessionDeadline: TimeInterval?,
        now: () -> TimeInterval,
        sleep: (TimeInterval) async throws -> Void,
        report: inout AutomationRunReport,
        reportURL: URL
    ) async throws -> String? {
        let time = now()
        let limit = AutoLevelForegroundDeferralState.maximumUnavailableSeconds
        switch deferral.recordDeferral(at: time) {
        case .invalidClock:
            throw ProbeError.unsafeWindow("the foreground deferral timing was invalid; " + failure)

        case let .exhausted(deferredActions, unavailableSeconds):
            return failure + " | foregroundDeferral: reason=\(reason.rawValue), "
                + "deferredActions=\(deferredActions), unavailableSeconds=\(unavailableSeconds), "
                + "limitSeconds=\(limit), noInputPosted=true"

        case let .deferred(deferredActions, unavailableSeconds, backoffSeconds):
            guard controller.cancelUnpostedActionForForegroundDeferral(request) else {
                throw ProbeError.unsafeWindow(
                    "the focus-deferred action could not be cancelled; " + failure
                )
            }
            try appendAutomationEvent(
                kind: "actionDeferred",
                state: observation.classification.state,
                decision: "continueObservation",
                action: request.intent,
                target: request.target,
                frameFingerprint: observation.fingerprint,
                detail: "reason=\(reason.rawValue), requestID=\(request.requestID), "
                    + "deferredActions=\(deferredActions), unavailableSeconds=\(unavailableSeconds), "
                    + "backoffSeconds=\(backoffSeconds), limitSeconds=\(limit), noInputPosted=true; "
                    + failure,
                screenshotPath: nil,
                elapsed: time - startedAt,
                report: &report,
                reportURL: reportURL
            )
            try await waitForForegroundDeferralBackoff(
                seconds: backoffSeconds, stopURL: stopURL, sessionDeadline: sessionDeadline,
                now: now, sleep: sleep
            )
            return nil
        }
    }

    /// Ends a deferral episode once a fresh preflight saw iPhone Mirroring own focus again.
    static func recordForegroundRecovery(
        _ deferral: inout AutoLevelForegroundDeferralState,
        request: AutoLevelActionRequest,
        observation: AutomationObservation,
        startedAt: TimeInterval,
        report: inout AutomationRunReport,
        reportURL: URL
    ) throws {
        guard let recovery = deferral.recordForegroundAvailable(at: observation.capturedAt) else {
            return
        }
        try appendAutomationEvent(
            kind: "foregroundRecovered",
            state: observation.classification.state,
            decision: "freshPreflightConfirmed",
            action: request.intent,
            target: request.target,
            frameFingerprint: observation.fingerprint,
            detail: "deferredActions=\(recovery.deferredActions), "
                + "unavailableSeconds=\(recovery.unavailableSeconds), requestID=\(request.requestID), "
                + "sameProcessAndWindowVerified=true, noInputPosted=true",
            screenshotPath: nil,
            elapsed: observation.capturedAt - startedAt,
            report: &report,
            reportURL: reportURL
        )
    }

    /// Waits out a deferral backoff in short slices so a STOP request or the session deadline
    /// ends the wait early. The observation loop then performs the actual stop or expiry
    /// handling on its next capture.
    static func waitForForegroundDeferralBackoff(
        seconds: TimeInterval,
        stopURL: URL,
        sessionDeadline: TimeInterval?,
        now: () -> TimeInterval,
        sleep: (TimeInterval) async throws -> Void
    ) async throws {
        guard seconds.isFinite, seconds > 0 else { return }
        let wakeAt = now() + seconds
        while true {
            let time = now()
            guard time < wakeAt,
                  !applicationStopRequest.isRequested(stopFileURL: stopURL),
                  sessionDeadline.map({ time < $0 }) ?? true
            else { return }
            try await sleep(min(0.5, wakeAt - time))
        }
    }
}
