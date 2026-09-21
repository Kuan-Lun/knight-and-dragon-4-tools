import AppKit
import ApplicationServices
import Foundation
import MirrorProbeCore

struct ForegroundApplicationFocusSnapshot: Codable {
    let processID: Int32?
    /// The original system-wide AXFocusedApplication result, including noValue after fallback.
    let accessibilityError: Int32
    let source: String
    let fallbackCandidateProcessID: Int32?
    let fallbackAccessibilityError: Int32?
    let outcome: String

    var application: NSRunningApplication? {
        guard let processID, processID > 0 else { return nil }
        let application = NSRunningApplication(processIdentifier: processID)
        if application == nil {
            // AX can confirm a PID while AppKit temporarily cannot resolve its application.
            // Keep this distinct from a failed AX read or an observed foreground switch.
            FileHandle.standardError.write(Data(
                "focusApplicationResolution: confirmedPID=\(processID), source=\(source), "
                    .appending("accessibilityError=\(accessibilityError), outcome=applicationUnavailable\n")
                    .utf8
            ))
        }
        return application
    }
}

enum ForegroundApplicationFocus {
    /// Applied on every read. The system-wide element's timeout is the process-wide default,
    /// and other system-wide callers in this process set their own value before each call.
    static let messagingTimeoutSeconds: Float = 0.25
    /// One retry after kAXErrorCannotComplete, which reports a frontmost application that is
    /// busy or not yet answering Accessibility, for example while another application launches
    /// and takes focus. A longer second wait separates a slow answer from a missing one.
    static let retryMessagingTimeoutSeconds: Float = 1

    static var currentApplication: NSRunningApplication? {
        read().application
    }

    /// Reads focus through Accessibility. AppKit may supply a fallback candidate only when the
    /// system-wide attribute has no value; the candidate still needs a live AXFrontmost true.
    static func read() -> ForegroundApplicationFocusSnapshot {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        var attributeError = AXError.cannotComplete
        var retried = false
        for timeout in [messagingTimeoutSeconds, retryMessagingTimeoutSeconds] {
            let timeoutError = AXUIElementSetMessagingTimeout(systemWide, timeout)
            guard timeoutError == .success else {
                return failure(timeoutError, reason: "messagingTimeoutUnavailable")
            }
            value = nil
            attributeError = AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &value
            )
            guard attributeError == .cannotComplete, !retried else { break }
            retried = true
            FileHandle.standardError.write(Data(
                "focusReadRetry: accessibilityError=\(attributeError.rawValue), "
                    .appending("timeoutSeconds=\(retryMessagingTimeoutSeconds), ")
                    .appending("outcome=retryingAfterCannotComplete\n")
                    .utf8
            ))
        }
        if retried {
            // The longer wait belongs to that retry only; keep the process-wide default short.
            AXUIElementSetMessagingTimeout(systemWide, messagingTimeoutSeconds)
        }
        guard attributeError == .success else {
            let unavailable = failure(attributeError, reason: "focusedApplicationUnavailable")
            guard attributeError == .noValue else { return unavailable }
            return readFrontmostFallback(primaryError: attributeError)
        }
        guard let value else {
            return failure(.noValue, reason: "focusedApplicationMissing")
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return failure(.failure, reason: "focusedApplicationTypeInvalid")
        }

        // The Core Foundation type check above establishes that this value is an AXUIElement.
        let focusedApplication = unsafeDowncast(value, to: AXUIElement.self)
        var processID: pid_t = 0
        let processError = AXUIElementGetPid(focusedApplication, &processID)
        guard processError == .success else {
            return failure(processError, reason: "focusedApplicationPIDUnavailable")
        }
        guard processID > 0 else {
            return failure(.failure, reason: "focusedApplicationPIDInvalid")
        }

        return ForegroundApplicationFocusSnapshot(
            processID: processID,
            accessibilityError: AXError.success.rawValue,
            source: "AXFocusedApplication",
            fallbackCandidateProcessID: nil,
            fallbackAccessibilityError: nil,
            outcome: retried ? "focusedApplicationConfirmedAfterRetry" : "focusedApplicationConfirmed"
        )
    }

    private static func readFrontmostFallback(
        primaryError: AXError
    ) -> ForegroundApplicationFocusSnapshot {
        let candidateBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let candidateBefore, candidateBefore > 0 else {
            return reportFallback(
                primaryError: primaryError, candidateBefore: candidateBefore,
                candidateAfter: nil, frontmostError: nil, frontmostValue: .unavailable,
                processID: nil, outcome: "candidateUnavailable"
            )
        }

        let application = AXUIElementCreateApplication(candidateBefore)
        let timeoutError = AXUIElementSetMessagingTimeout(application, 0.25)
        guard timeoutError == .success else {
            return reportFallback(
                primaryError: primaryError, candidateBefore: candidateBefore,
                candidateAfter: nil, frontmostError: timeoutError,
                frontmostValue: .unavailable, processID: nil,
                outcome: "frontmostMessagingTimeoutUnavailable"
            )
        }

        var value: CFTypeRef?
        let frontmostError = AXUIElementCopyAttributeValue(
            application, kAXFrontmostAttribute as CFString, &value
        )
        let candidateAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostValue: ForegroundFocusFallbackValue
        if let value {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                // Do not coerce NSNumber, strings, or other CF values into a truth value.
                let boolean = unsafeDowncast(value, to: CFBoolean.self)
                frontmostValue = .boolean(CFBooleanGetValue(boolean))
            } else {
                frontmostValue = .invalidType
            }
        } else {
            frontmostValue = .unavailable
        }
        let processID = ForegroundFocusFallbackValidation.confirmedProcessID(
            primaryReturnedNoValue: primaryError == .noValue,
            candidateBefore: candidateBefore,
            candidateAfter: candidateAfter,
            frontmostReadSucceeded: frontmostError == .success,
            frontmostValue: frontmostValue
        )
        let outcome: String
        if frontmostError != .success {
            outcome = "frontmostAttributeUnavailable"
        } else if candidateAfter != candidateBefore {
            outcome = "candidateChangedDuringFrontmostRead"
        } else {
            switch frontmostValue {
            case .unavailable: outcome = "frontmostAttributeMissing"
            case .invalidType: outcome = "frontmostAttributeTypeInvalid"
            case .boolean(false): outcome = "candidateIsNotFrontmost"
            case .boolean(true): outcome = "frontmostCandidateConfirmed"
            }
        }
        return reportFallback(
            primaryError: primaryError, candidateBefore: candidateBefore,
            candidateAfter: candidateAfter, frontmostError: frontmostError,
            frontmostValue: frontmostValue, processID: processID, outcome: outcome
        )
    }

    private static func reportFallback(
        primaryError: AXError,
        candidateBefore: Int32?,
        candidateAfter: Int32?,
        frontmostError: AXError?,
        frontmostValue: ForegroundFocusFallbackValue,
        processID: Int32?,
        outcome: String
    ) -> ForegroundApplicationFocusSnapshot {
        let before = candidateBefore.map(String.init) ?? "none"
        let after = candidateAfter.map(String.init) ?? "none"
        let error = frontmostError.map { String($0.rawValue) } ?? "none"
        FileHandle.standardError.write(Data(
            "focusReadFallback: source=AXFrontmost, primaryAccessibilityError=\(primaryError.rawValue), "
                .appending("candidateBeforePID=\(before), candidateAfterPID=\(after), ")
                .appending("accessibilityError=\(error), value=\(frontmostValue), outcome=\(outcome)\n")
                .utf8
        ))
        return ForegroundApplicationFocusSnapshot(
            processID: processID,
            accessibilityError: primaryError.rawValue,
            source: processID == nil ? "unavailable" : "AXFrontmost",
            fallbackCandidateProcessID: candidateBefore,
            fallbackAccessibilityError: frontmostError?.rawValue,
            outcome: outcome
        )
    }

    private static func failure(
        _ error: AXError,
        reason: String
    ) -> ForegroundApplicationFocusSnapshot {
        FileHandle.standardError.write(Data(
            "focusRead: accessibilityError=\(error.rawValue), axTrusted=\(AXIsProcessTrusted()), "
                .appending("outcome=\(reason)\n").utf8
        ))
        return ForegroundApplicationFocusSnapshot(
            processID: nil,
            accessibilityError: error.rawValue,
            source: "unavailable",
            fallbackCandidateProcessID: nil,
            fallbackAccessibilityError: nil,
            outcome: reason
        )
    }
}
