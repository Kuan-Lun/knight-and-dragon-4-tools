import Testing
@testable import MirrorProbeCore

@Suite("Input boundary malformed and missing window evidence")
struct AutoLevelInputBoundaryValidationTests {
    @Test("Matching invalid identities never authorize either input route",
          arguments: [AutoLevelInputMode.foreground, .process])
    func rejectsInvalidIdentity(mode: AutoLevelInputMode) {
        for invalid in [
            AutoLevelWindowIdentity(processID: 0, windowID: 7),
            AutoLevelWindowIdentity(processID: -1, windowID: 7),
            AutoLevelWindowIdentity(processID: 99, windowID: 0),
        ] {
            #expect(rejection(
                expectedIdentity: invalid, expectedGeometry: geometry, mode: mode,
                snapshot: matchingSnapshot(identity: invalid, geometry: geometry)
            ) == .windowIdentityChanged)
        }
    }

    @Test("Matching malformed geometry never authorizes either input route",
          arguments: [AutoLevelInputMode.foreground, .process])
    func rejectsInvalidGeometry(mode: AutoLevelInputMode) {
        let invalid: [AutoLevelWindowGeometry] = [
            .init(x: .infinity, y: 80, width: 300, height: 650),
            .init(x: 40, y: -.infinity, width: 300, height: 650),
            .init(x: .nan, y: 80, width: 300, height: 650),
            .init(x: 40, y: 80, width: .infinity, height: 650),
            .init(x: 40, y: 80, width: 300, height: .nan),
            .init(x: 40, y: 80, width: 0, height: 650),
            .init(x: 40, y: 80, width: 300, height: -1),
            .init(x: .greatestFiniteMagnitude, y: 80,
                  width: .greatestFiniteMagnitude, height: 650),
            .init(x: 40, y: .greatestFiniteMagnitude,
                  width: 300, height: .greatestFiniteMagnitude),
        ]
        for frame in invalid {
            #expect(!frame.isValid)
            #expect(rejection(
                expectedIdentity: identity, expectedGeometry: frame, mode: mode,
                snapshot: matchingSnapshot(identity: identity, geometry: frame)
            ) == .windowGeometryChanged)
        }
    }

    @Test("Negative desktop coordinates remain valid on displays left of or above the primary display",
          arguments: [AutoLevelInputMode.foreground, .process])
    func acceptsNegativeDisplayOrigin(mode: AutoLevelInputMode) {
        let frame = AutoLevelWindowGeometry(x: -1920, y: -1080, width: 300, height: 650)
        #expect(frame.isValid)
        #expect(rejection(
            expectedIdentity: identity, expectedGeometry: frame, mode: mode,
            snapshot: matchingSnapshot(identity: identity, geometry: frame)
        ) == nil)
    }

    @Test("Missing window identity or geometry fails closed even when focus and ordering match",
          arguments: [AutoLevelInputMode.foreground, .process])
    func rejectsUnavailableWindow(mode: AutoLevelInputMode) {
        for snapshot in [
            AutoLevelInputSnapshot(
                windowIdentity: nil, windowGeometry: geometry,
                frontmostProcessID: identity.processID, topmostWindowIdentity: identity,
                targetProcessTopmostWindowIdentity: identity
            ),
            AutoLevelInputSnapshot(
                windowIdentity: identity, windowGeometry: nil,
                frontmostProcessID: identity.processID, topmostWindowIdentity: identity,
                targetProcessTopmostWindowIdentity: identity
            ),
        ] {
            #expect(rejection(
                expectedIdentity: identity, expectedGeometry: geometry, mode: mode, snapshot: snapshot
            ) == .windowUnavailable)
        }
    }

    @Test("Unavailable window ordering cannot be mistaken for an unobscured point",
          arguments: [AutoLevelInputMode.foreground, .process])
    func rejectsUnavailableWindowOrdering(mode: AutoLevelInputMode) {
        let snapshot = AutoLevelInputSnapshot(
            windowIdentity: identity, windowGeometry: geometry,
            frontmostProcessID: identity.processID,
            topmostWindowIdentity: mode == .foreground ? nil : identity,
            targetProcessTopmostWindowIdentity: mode == .process ? nil : identity
        )
        #expect(rejection(
            expectedIdentity: identity, expectedGeometry: geometry, mode: mode, snapshot: snapshot
        ) == .clickPointObscured)
    }

    private let identity = AutoLevelWindowIdentity(processID: 99, windowID: 7)
    private let geometry = AutoLevelWindowGeometry(x: 40, y: 80, width: 300, height: 650)

    private func matchingSnapshot(
        identity: AutoLevelWindowIdentity, geometry: AutoLevelWindowGeometry
    ) -> AutoLevelInputSnapshot {
        .init(windowIdentity: identity, windowGeometry: geometry,
              frontmostProcessID: identity.processID, topmostWindowIdentity: identity,
              targetProcessTopmostWindowIdentity: identity)
    }

    private func rejection(
        expectedIdentity: AutoLevelWindowIdentity,
        expectedGeometry: AutoLevelWindowGeometry,
        mode: AutoLevelInputMode,
        snapshot: AutoLevelInputSnapshot
    ) -> AutoLevelInputRejection? {
        AutoLevelInputSafety.rejection(
            expectedWindowIdentity: expectedIdentity, expectedWindowGeometry: expectedGeometry,
            inputMode: mode, snapshot: snapshot, now: 100, actionDeadline: 112,
            stopRequested: false
        )
    }
}
