import Testing
@testable import MirrorProbeCore

@Suite("Foreground focus restoration")
struct ForegroundFocusRestorationTests {
    @Test("A live original application receives focus at most once")
    func restoresOriginalApplicationOnce() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == 10)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("The user's third application is preserved, even if the mirror later regains focus")
    func preservesThirdApplicationAndConsumesSkippedRestoration() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 30, previousApplicationTerminated: false
        ) == nil)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Already returning to the original application consumes restoration")
    func preservesOriginalApplicationAlreadySelectedByUser() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 10, previousApplicationTerminated: false
        ) == nil)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Starting with the mirror already focused requires no restoration")
    func skipsWhenPreviousApplicationWasTarget() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 20)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("A terminated original application cannot become a later restoration target")
    func skipsTerminatedOriginalApplication() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: true
        ) == nil)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Unknown current focus consumes restoration without activating anything")
    func skipsUnknownCurrentApplication() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: nil, previousApplicationTerminated: false
        ) == nil)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("An unknown original application has no restoration target")
    func skipsUnknownOriginalApplication() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: nil)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Invalid process identifiers never authorize restoration")
    func skipsInvalidProcessIdentifiers() {
        var invalidTarget = ForegroundFocusRestoration(targetProcessID: 0, previousProcessID: 10)
        var invalidPrevious = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: -1)

        #expect(invalidTarget.takeRestorationTarget(
            currentProcessID: 0, previousApplicationTerminated: false
        ) == nil)
        #expect(invalidPrevious.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Automation clicks and the expected activation preserve restoration")
    func ignoresAutomationInputAndExpectedActivation() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
        restoration.recordApplicationActivation(processID: 10)
        restoration.recordApplicationActivation(processID: 20)
        restoration.recordInput(isAutomationInput: true)
        restoration.recordApplicationActivation(processID: 20)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == 10)
    }

    @Test("User input takes over the mirror even when its focused PID never changes")
    func preservesUserTakingOverTheBorrowedMirror() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
        restoration.recordApplicationActivation(processID: 20)
        restoration.recordInput(isAutomationInput: false)
        restoration.recordInput(isAutomationInput: true)

        #expect(restoration.cancellationReason == .userInputObserved)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Leaving the mirror and returning before cleanup still cancels restoration")
    func remembersFocusChangesWithinOneBorrow() {
        for destination: Int32 in [10, 30] {
            var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
            restoration.recordApplicationActivation(processID: 20)
            restoration.recordApplicationActivation(processID: destination)
            restoration.recordApplicationActivation(processID: 20)

            #expect(restoration.cancellationReason == .applicationChanged)
            #expect(restoration.takeRestorationTarget(
                currentProcessID: 20, previousApplicationTerminated: false
            ) == nil)
        }
    }

    @Test("An unexpected application before the target activates also cancels restoration")
    func preservesAThirdApplicationSelectedDuringActivation() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
        restoration.recordApplicationActivation(processID: 30)
        restoration.recordApplicationActivation(processID: 20)

        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Unavailable monitoring or a changed setup snapshot must not restore focus")
    func failsClosedWhenTakeoverCannotBeMonitored() {
        for reason: ForegroundFocusRestorationCancellation in [
            .monitoringUnavailable, .focusChangedDuringSetup,
        ] {
            var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
            restoration.cancelRestoration(reason: reason)
            restoration.recordApplicationActivation(processID: 20)

            #expect(restoration.cancellationReason == reason)
            #expect(restoration.takeRestorationTarget(
                currentProcessID: 20, previousApplicationTerminated: false
            ) == nil)
            #expect(restoration.takeRestorationTarget(
                currentProcessID: 20, previousApplicationTerminated: false
            ) == nil)
        }
    }

    @Test("A later borrow independently restores the user's newly selected application")
    func takeoverDoesNotDisableFutureBorrows() {
        var earlier = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
        earlier.recordApplicationActivation(processID: 20)
        earlier.recordInput(isAutomationInput: false)
        earlier.recordApplicationActivation(processID: 30)
        #expect(earlier.takeRestorationTarget(
            currentProcessID: 30, previousApplicationTerminated: false
        ) == nil)

        var later = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 30)
        later.recordApplicationActivation(processID: 20)
        later.recordInput(isAutomationInput: true)
        #expect(later.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == 30)
    }

    @Test("User activity after target selection still cancels a pending activation request")
    func cancellationRemainsLiveAfterRestorationTargetIsConsumed() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
        restoration.recordApplicationActivation(processID: 20)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == 10)
        #expect(restoration.cancellationReason == nil)

        restoration.recordInput(isAutomationInput: true)
        #expect(restoration.cancellationReason == nil)
        restoration.recordInput(isAutomationInput: false)
        #expect(restoration.cancellationReason == .userInputObserved)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }

    @Test("Focus changes after target selection still cancel the Accessibility fallback")
    func focusCancellationRemainsLiveAfterRestorationTargetIsConsumed() {
        var restoration = ForegroundFocusRestoration(targetProcessID: 20, previousProcessID: 10)
        restoration.recordApplicationActivation(processID: 20)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == 10)

        restoration.recordApplicationActivation(processID: 30)
        restoration.recordApplicationActivation(processID: 20)
        #expect(restoration.cancellationReason == .applicationChanged)
        #expect(restoration.takeRestorationTarget(
            currentProcessID: 20, previousApplicationTerminated: false
        ) == nil)
    }
}
