import AppKit
import ApplicationServices
import Foundation

struct ForegroundActivationRequest: Codable {
    let processID: Int32
    let appKitAccepted: Bool
    let accessibilityError: Int32?
    let outcome: String

    var accepted: Bool {
        appKitAccepted || accessibilityError == AXError.success.rawValue
    }
}

enum ForegroundApplicationActivation {
    /// AppKit may decline activation by a background automation app. Accessibility provides a
    /// public, permission-gated request for the running application's AXFrontmost attribute.
    /// Neither API's return value is evidence that it became frontmost: callers must observe it.
    static func request(
        _ application: NSRunningApplication,
        options: NSApplication.ActivationOptions = [],
        expectedCurrentProcessID: Int32,
        shouldProceed: () -> Bool = { true }
    ) -> ForegroundActivationRequest {
        let processID = application.processIdentifier
        guard expectedCurrentProcessID > 0 else {
            return reportUnacceptedAppKitRequest(ForegroundActivationRequest(
                processID: processID, appKitAccepted: false, accessibilityError: nil,
                outcome: "expectedFocusProcessInvalid"
            ))
        }
        guard let currentProcessID = ForegroundApplicationFocus.read().processID,
              currentProcessID > 0
        else {
            return reportUnacceptedAppKitRequest(ForegroundActivationRequest(
                processID: processID, appKitAccepted: false, accessibilityError: nil,
                outcome: "focusedApplicationUnavailableBeforeAppKitRequest"
            ))
        }
        guard currentProcessID == expectedCurrentProcessID else {
            return reportUnacceptedAppKitRequest(ForegroundActivationRequest(
                processID: processID, appKitAccepted: false, accessibilityError: nil,
                outcome: "focusChangedBeforeAppKitRequest"
            ))
        }
        // Restoration's user-activity latch remains live while the source-focus read runs.
        // Check it next to the request, not only when the restoration target was selected.
        guard shouldProceed() else {
            return reportUnacceptedAppKitRequest(ForegroundActivationRequest(
                processID: processID, appKitAccepted: false, accessibilityError: nil,
                outcome: "callerCancelledBeforeAppKitRequest"
            ))
        }
        let appKitAccepted = application.activate(options: options)
        if appKitAccepted {
            return ForegroundActivationRequest(
                processID: processID,
                appKitAccepted: true,
                accessibilityError: nil,
                outcome: "appKitRequestAccepted"
            )
        }

        let result: ForegroundActivationRequest
        if application.isTerminated || processID <= 0 {
            result = ForegroundActivationRequest(
                processID: processID, appKitAccepted: false, accessibilityError: nil,
                outcome: "applicationUnavailable"
            )
        } else if !AXIsProcessTrusted() {
            result = ForegroundActivationRequest(
                processID: processID, appKitAccepted: false, accessibilityError: nil,
                outcome: "accessibilityPermissionMissing"
            )
        } else {
            let element = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(element, 0.25)
            // Keep the same authorized source across both APIs. A restoration caller must
            // not replace the borrowed mirror with a newly selected application as its source.
            if let fallbackProcessID = ForegroundApplicationFocus.read().processID,
               fallbackProcessID > 0,
               fallbackProcessID == expectedCurrentProcessID
            {
                guard shouldProceed() else {
                    return reportUnacceptedAppKitRequest(ForegroundActivationRequest(
                        processID: processID, appKitAccepted: false, accessibilityError: nil,
                        outcome: "callerCancelledBeforeAccessibilityRequest"
                    ))
                }
                let error = AXUIElementSetAttributeValue(
                    element, kAXFrontmostAttribute as CFString, kCFBooleanTrue
                )
                result = ForegroundActivationRequest(
                    processID: processID, appKitAccepted: false,
                    accessibilityError: error.rawValue,
                    outcome: error == .success
                        ? "accessibilityRequestAccepted" : "accessibilityRequestFailed"
                )
            } else {
                result = ForegroundActivationRequest(
                    processID: processID, appKitAccepted: false, accessibilityError: nil,
                    outcome: "focusChangedBeforeAccessibilityRequest"
                )
            }
        }
        return reportUnacceptedAppKitRequest(result)
    }

    private static func reportUnacceptedAppKitRequest(
        _ result: ForegroundActivationRequest
    ) -> ForegroundActivationRequest {
        let errorText = result.accessibilityError.map(String.init) ?? "none"
        FileHandle.standardError.write(Data(
            "focusActivation: targetPID=\(result.processID), appKitAccepted=false, "
                .appending("accessibilityError=\(errorText), outcome=\(result.outcome)\n").utf8
        ))
        return result
    }
}
