import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("AutoLevelInputSafety")
struct AutoLevelInputSafetyTests {
    @Test("An exact current snapshot remains authorized before both deadlines")
    func acceptsExactCurrentSnapshot() {
        #expect(rejection(now: 111.999, actionDeadline: 112, sessionDeadline: 200) == nil)
    }

    @Test("Geometry must match exactly at the input boundary")
    func rejectsAnyGeometryChange() {
        let changed = AutoLevelWindowGeometry(x: 40.000_001, y: 80, width: 300, height: 650)

        #expect(rejection(windowGeometry: changed) == .windowGeometryChanged)
    }

    @Test("The locked window must still be frontmost and topmost at the click point")
    func rejectsChangedWindowOrdering() {
        #expect(rejection(frontmostProcessID: 98) == .applicationNotFrontmost)
        #expect(
            rejection(topmostWindowIdentity: AutoLevelWindowIdentity(processID: 99, windowID: 8))
                == .clickPointObscured
        )
    }

    @Test("Another window from the focused application still obscures the locked window")
    func rejectsSameProcessWindowAboveTarget() {
        #expect(
            rejection(
                frontmostProcessID: identity.processID,
                topmostWindowIdentity: AutoLevelWindowIdentity(
                    processID: identity.processID, windowID: identity.windowID + 1
                )
            ) == .clickPointObscured
        )
    }

    @Test("An unfocused application's covering window is not ignored")
    func rejectsUnfocusedApplicationWindowAboveTarget() {
        #expect(
            rejection(
                frontmostProcessID: identity.processID,
                topmostWindowIdentity: AutoLevelWindowIdentity(processID: 98, windowID: 8)
            ) == .clickPointObscured
        )
    }

    @Test("Unavailable live focus never authorizes a click on an otherwise matching window")
    func rejectsUnavailableFocusedProcess() {
        let snapshot = AutoLevelInputSnapshot(
            windowIdentity: identity,
            windowGeometry: geometry,
            frontmostProcessID: nil,
            topmostWindowIdentity: identity,
            targetProcessTopmostWindowIdentity: identity
        )
        #expect(AutoLevelInputSafety.rejection(
            expectedWindowIdentity: identity,
            expectedWindowGeometry: geometry,
            snapshot: snapshot,
            now: 100,
            actionDeadline: 112,
            sessionDeadline: 200,
            stopRequested: false
        ) == .applicationNotFrontmost)
    }

    @Test("Process routing permits another app in front but binds the destination window")
    func processRoutingUsesTargetProcessWindow() {
        let other = AutoLevelWindowIdentity(processID: 98, windowID: 8)

        #expect(
            rejection(
                inputMode: .process,
                frontmostProcessID: other.processID,
                topmostWindowIdentity: other,
                targetProcessTopmostWindowIdentity: identity
            ) == nil
        )
        #expect(
            rejection(
                inputMode: .process,
                frontmostProcessID: other.processID,
                topmostWindowIdentity: other,
                targetProcessTopmostWindowIdentity: AutoLevelWindowIdentity(
                    processID: identity.processID,
                    windowID: 9
                )
            ) == .clickPointObscured
        )
    }

    @Test("A STOP request wins at the final input boundary")
    func rejectsStopRequest() {
        #expect(
            rejection(
                now: 500,
                actionDeadline: 100,
                sessionDeadline: 100,
                stopRequested: true
            ) == .stopRequested
        )
    }

    @Test("Action and session deadlines are strict and fail closed")
    func rejectsExpiredDeadlines() {
        #expect(
            rejection(now: 112, actionDeadline: 112, sessionDeadline: 200)
                == .actionAuthorizationExpired
        )
        #expect(
            rejection(now: 200, actionDeadline: 201, sessionDeadline: 200)
                == .sessionRuntimeExpired
        )
        #expect(
            rejection(now: 200, actionDeadline: 112, sessionDeadline: 200)
                == .sessionRuntimeExpired
        )
        #expect(
            rejection(now: .nan, actionDeadline: 201, sessionDeadline: 300)
                == .invalidTiming
        )
    }

    @Test("An unlimited session authorizes fresh input at any runtime but keeps the action deadline",
          arguments: [AutoLevelInputMode.foreground, .process])
    func noSessionDeadlineRetainsActionAuthorization(inputMode: AutoLevelInputMode) {
        let muchLater: TimeInterval = 1_000_000
        #expect(rejection(
            inputMode: inputMode, now: muchLater,
            actionDeadline: muchLater + 1, sessionDeadline: nil
        ) == nil)
        #expect(rejection(
            inputMode: inputMode, now: muchLater + 1,
            actionDeadline: muchLater + 1, sessionDeadline: nil
        ) == .actionAuthorizationExpired)
        #expect(rejection(
            inputMode: inputMode, now: muchLater + 2,
            actionDeadline: muchLater + 1, sessionDeadline: nil
        ) == .actionAuthorizationExpired)
    }

    @Test("Omitting the session deadline preserves the live input-boundary checks")
    func defaultSessionDeadlineStillRequiresMatchingWindow() {
        let snapshot = AutoLevelInputSnapshot(
            windowIdentity: identity,
            windowGeometry: geometry,
            frontmostProcessID: nil,
            topmostWindowIdentity: identity
        )
        #expect(AutoLevelInputSafety.rejection(
            expectedWindowIdentity: identity,
            expectedWindowGeometry: geometry,
            snapshot: snapshot,
            now: 100,
            actionDeadline: 112,
            stopRequested: false
        ) == .applicationNotFrontmost)
        #expect(rejection(
            windowIdentity: AutoLevelWindowIdentity(processID: 99, windowID: 8),
            sessionDeadline: nil
        ) == .windowIdentityChanged)
        #expect(rejection(
            windowGeometry: AutoLevelWindowGeometry(x: 41, y: 80, width: 300, height: 650),
            sessionDeadline: nil
        ) == .windowGeometryChanged)
        #expect(rejection(
            topmostWindowIdentity: AutoLevelWindowIdentity(processID: 98, windowID: 8),
            sessionDeadline: nil
        ) == .clickPointObscured)
    }

    @Test("Unlimited sessions reject invalid timing and honor STOP before expired authorization")
    func noSessionDeadlineRetainsTimingAndStopGuards() {
        for invalid in [TimeInterval.nan, .infinity, -.infinity, -1] {
            #expect(rejection(now: invalid, sessionDeadline: nil) == .invalidTiming)
            #expect(rejection(actionDeadline: invalid, sessionDeadline: nil) == .invalidTiming)
            #expect(rejection(sessionDeadline: invalid) == .invalidTiming)
        }
        #expect(rejection(
            now: 500, actionDeadline: 100, sessionDeadline: nil, stopRequested: true
        ) == .stopRequested)
    }

    private let identity = AutoLevelWindowIdentity(processID: 99, windowID: 7)
    private let geometry = AutoLevelWindowGeometry(x: 40, y: 80, width: 300, height: 650)

    private func rejection(
        inputMode: AutoLevelInputMode = .foreground,
        windowIdentity: AutoLevelWindowIdentity? = nil,
        windowGeometry: AutoLevelWindowGeometry? = nil,
        frontmostProcessID: Int32? = nil,
        topmostWindowIdentity: AutoLevelWindowIdentity? = nil,
        targetProcessTopmostWindowIdentity: AutoLevelWindowIdentity? = nil,
        now: TimeInterval = 100,
        actionDeadline: TimeInterval = 112,
        sessionDeadline: TimeInterval? = 200,
        stopRequested: Bool = false
    ) -> AutoLevelInputRejection? {
        AutoLevelInputSafety.rejection(
            expectedWindowIdentity: identity,
            expectedWindowGeometry: geometry,
            inputMode: inputMode,
            snapshot: AutoLevelInputSnapshot(
                windowIdentity: windowIdentity ?? identity,
                windowGeometry: windowGeometry ?? geometry,
                frontmostProcessID: frontmostProcessID ?? identity.processID,
                topmostWindowIdentity: topmostWindowIdentity ?? identity,
                targetProcessTopmostWindowIdentity: targetProcessTopmostWindowIdentity
                    ?? identity
            ),
            now: now,
            actionDeadline: actionDeadline,
            sessionDeadline: sessionDeadline,
            stopRequested: stopRequested
        )
    }
}
