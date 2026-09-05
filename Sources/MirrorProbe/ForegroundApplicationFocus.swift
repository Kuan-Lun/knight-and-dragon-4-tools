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
        return NSRunningApplication(processIdentifier: processID)
    }
}

enum ForegroundApplicationFocus {
    static var currentApplication: NSRunningApplication? {
        read().application
    }

    /// Reads focus through Accessibility. AppKit may supply a fallback candidate only when the
    /// system-wide attribute has no value; the candidate still needs a live AXFrontmost true.
    static func read() -> ForegroundApplicationFocusSnapshot {
        let systemWide = AXUIElementCreateSystemWide()
        let timeoutError = AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard timeoutError == .success else {
            return failure(timeoutError, reason: "messagingTimeoutUnavailable")
        }

        var value: CFTypeRef?
        let attributeError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &value
        )
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
        let focusedApplication = unsafeBitCast(value, to: AXUIElement.self)
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
            outcome: "focusedApplicationConfirmed"
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
                let boolean = unsafeBitCast(value, to: CFBoolean.self)
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
