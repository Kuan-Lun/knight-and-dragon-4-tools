import AppKit
import Foundation
import MirrorProbeCore

/// Keeps the previous application alive as an identity token, without relaunching it if it exits.
/// One instance belongs to one activation attempt, including its preflight and error paths.
struct ForegroundFocusBorrow {
    let previousProcessID: Int32
    private let targetProcessID: Int32
    private let previousApplication: NSRunningApplication
    private let monitor: ForegroundFocusBorrowMonitor
    private var restorationWasConsumed = false

    init?(targetProcessID: Int32) {
        guard targetProcessID > 0,
              let previous = ForegroundApplicationFocus.currentApplication,
              previous.processIdentifier > 0
        else { return nil }
        let previousProcessID = previous.processIdentifier
        self.previousProcessID = previousProcessID
        self.targetProcessID = targetProcessID
        previousApplication = previous
        monitor = ForegroundFocusBorrowMonitor(
            targetProcessID: targetProcessID,
            previousProcessID: previousProcessID
        )
        // The observer is installed after the first identity read. If focus changed during
        // that setup, this borrow cannot assume that its saved destination is still wanted.
        if ForegroundApplicationFocus.currentApplication?.processIdentifier != previousProcessID {
            monitor.cancelRestoration(reason: .focusChangedDuringSetup)
        }
    }

    /// Call once the caller finishes its post-click capture, and also from defer on other paths.
    /// Consuming a skipped restoration prevents later cleanup from overriding the user's choice.
    @discardableResult
    mutating func restore() -> ForegroundActivationRequest? {
        guard !restorationWasConsumed else { return nil }
        restorationWasConsumed = true
        defer { monitor.stop() }
        let result = monitor.takeRestorationTarget(
            currentProcessID: ForegroundApplicationFocus.currentApplication?.processIdentifier,
            previousApplicationTerminated: previousApplication.isTerminated
        )
        if let reason = result.cancellationReason {
            FileHandle.standardError.write(Data(
                "focusRestorationSkipped: targetPID=\(targetProcessID), "
                    .appending("previousPID=\(previousProcessID), reason=\(reason.rawValue)\n").utf8
            ))
        }
        guard let processID = result.processID,
              previousApplication.processIdentifier == processID
        else {
            return nil
        }

        // Default activation restores the application's main/key windows. Do not raise all of
        // its windows, launch a replacement process, or retry over a subsequent user action.
        // AppKit activation is advisory and asynchronous; it is not an atomic focus transfer.
        let request = ForegroundApplicationActivation.request(
            previousApplication,
            expectedCurrentProcessID: targetProcessID,
            shouldProceed: { monitor.cancellationReason == nil }
        )
        if !request.accepted {
            let cancellationReason = monitor.cancellationReason
            let kind = cancellationReason == nil
                ? "focusRestorationRequestUnaccepted" : "focusRestorationSkipped"
            FileHandle.standardError.write(Data(
                "\(kind): targetPID=\(targetProcessID), previousPID=\(processID), "
                    .appending("reason=\(cancellationReason?.rawValue ?? request.outcome)\n").utf8
            ))
        }
        return request
    }
}
