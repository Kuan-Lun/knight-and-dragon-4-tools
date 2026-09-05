public enum ForegroundFocusRestorationCancellation: String, Equatable, Sendable {
    case userInputObserved
    case applicationChanged
    case monitoringUnavailable
    case focusChangedDuringSetup
}

/// A single-use decision to return focus after temporarily activating another application.
///
/// Every restoration attempt consumes the saved destination, including skipped attempts. The
/// cancellation latch remains live until monitoring ends, so activity after consuming the
/// destination can still prevent a pending activation request or its Accessibility fallback.
public struct ForegroundFocusRestoration: Equatable, Sendable {
    private let targetProcessID: Int32
    private let previousProcessID: Int32?
    private var wasConsumed = false
    private var targetWasFocused: Bool
    public private(set) var cancellationReason: ForegroundFocusRestorationCancellation?

    public init(targetProcessID: Int32, previousProcessID: Int32?) {
        self.targetProcessID = targetProcessID
        self.previousProcessID = previousProcessID
        targetWasFocused = previousProcessID == targetProcessID
    }

    /// Input from this program is not a takeover. Any other observed input conservatively
    /// cancels this borrow, even if it leaves the same application focused.
    public mutating func recordInput(isAutomationInput: Bool) {
        if !isAutomationInput {
            cancelRestoration(reason: .userInputObserved)
        }
    }

    /// The first transition from the saved application to the target is the expected borrow.
    /// Once the target has activated, leaving it cancels restoration even if it returns later.
    public mutating func recordApplicationActivation(processID: Int32?) {
        guard let processID, processID > 0 else {
            cancelRestoration(reason: .applicationChanged)
            return
        }
        if processID == targetProcessID {
            targetWasFocused = true
        } else if targetWasFocused || processID != previousProcessID {
            cancelRestoration(reason: .applicationChanged)
        }
    }

    public mutating func cancelRestoration(reason: ForegroundFocusRestorationCancellation) {
        guard cancellationReason == nil else { return }
        cancellationReason = reason
    }

    /// Returns the original application only while the borrowed target still owns focus.
    /// The caller must check the current application and the original application's lifetime
    /// immediately before invoking this method, then perform any permitted restoration promptly.
    public mutating func takeRestorationTarget(
        currentProcessID: Int32?,
        previousApplicationTerminated: Bool
    ) -> Int32? {
        guard !wasConsumed else { return nil }
        wasConsumed = true

        guard cancellationReason == nil,
              targetProcessID > 0,
              let previousProcessID,
              previousProcessID > 0,
              previousProcessID != targetProcessID,
              currentProcessID == targetProcessID,
              !previousApplicationTerminated
        else {
            return nil
        }
        return previousProcessID
    }
}
