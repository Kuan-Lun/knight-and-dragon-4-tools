import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("System backdrop input-point filtering")
struct AutoLevelSystemBackdropTests {
    private let mirror = AutoLevelWindowIdentity(processID: 91_507, windowID: 65_194)
    private let mirrorFrame = AutoLevelWindowGeometry(x: 0, y: 33, width: 406, height: 890)
    private let displayFrame = AutoLevelWindowGeometry(x: 0, y: 0, width: 1_512, height: 982)

    @Test("The recorded NotificationCenter and Dock stack resolves to the locked mirror")
    func recordedStackResolvesToMirror() {
        // auto-level-20260911-062312.BBbuKG, request 1495: both system surfaces cover the
        // display while the final boundary's successful Accessibility hit identifies the mirror.
        let topmost = firstOccluder(in: [notificationCenter, dock, mirrorWindow])
        #expect(topmost == mirror)
        #expect(safetyRejection(topmost: topmost) == nil)
    }

    @Test("Unavailable, failed, or foreign AX hits never dismiss a system surface")
    func accessibilityMustConfirmExpectedProcess() {
        for window in [notificationCenter, dock] {
            for hitPID: Int32? in [nil, 0, -1, 719, 637, 91_508] {
                #expect(!isBackdrop(window, hitProcessID: hitPID))
            }
            for error: Int32 in [-25_202, -25_204, 1] {
                #expect(!isBackdrop(window, hitError: error))
            }
            for invalidPID: Int32 in [0, -1] {
                #expect(!isBackdrop(
                    window, hitProcessID: invalidPID, expectedProcessID: invalidPID
                ))
            }
        }
        #expect(firstOccluder(
            in: [notificationCenter, dock, mirrorWindow], hitProcessID: 719
        ) == notificationCenter.identity)
    }

    @Test("Only the exact system owners and observed layers qualify")
    func ownerAndLayerMustMatch() {
        for owner: String? in [nil, "", "com.apple.finder", "com.apple.NotificationCenterUI"] {
            var candidate = notificationCenter
            candidate.owner = owner
            #expect(!isBackdrop(candidate))
        }
        for layer in [0, 20, 22, 100] {
            var candidate = notificationCenter
            candidate.layer = layer
            #expect(!isBackdrop(candidate))
        }
        var wrongDockLayer = dock
        wrongDockLayer.layer = 21
        #expect(!isBackdrop(wrongDockLayer))
    }

    @Test("The Dock exception retains its name guard without requiring display discovery")
    func dockSignatureRemainsNarrow() {
        #expect(isBackdrop(dock, displayFrames: []))
        for name: String? in [nil, "", "dock", "Mission Control"] {
            var candidate = dock
            candidate.name = name
            #expect(!isBackdrop(candidate))
        }
    }

    @Test("NotificationCenter requires exact current display bounds")
    func notificationRequiresDisplayBounds() {
        #expect(!isBackdrop(notificationCenter, displayFrames: []))
        #expect(!isBackdrop(notificationCenter, displayFrames: [mirrorFrame]))
        for frame in [
            AutoLevelWindowGeometry(x: 0, y: 0, width: 1_512, height: 981.999),
            AutoLevelWindowGeometry(x: 0, y: 0, width: 1_513, height: 982),
            AutoLevelWindowGeometry(x: -0.001, y: 0, width: 1_512, height: 982),
            AutoLevelWindowGeometry(x: 0, y: -0.001, width: 1_512, height: 982),
        ] {
            var candidate = notificationCenter
            candidate.frame = frame
            #expect(!isBackdrop(candidate))
        }
    }

    @Test("A panel covering the entire mirror is still an occluder")
    func partialDisplayPanelIsNotABackdrop() {
        var panel = notificationCenter
        panel.frame = .init(x: 0, y: 0, width: 450, height: 982)
        #expect(!isBackdrop(panel))
        let topmost = firstOccluder(in: [panel, dock, mirrorWindow])
        #expect(topmost == panel.identity)
        #expect(safetyRejection(topmost: topmost) == .clickPointObscured)
    }

    @Test("A full-display surface must contain the whole locked window")
    func mirrorMustRemainInsideSurface() {
        for frame in [
            AutoLevelWindowGeometry(x: -1, y: 33, width: 406, height: 890),
            AutoLevelWindowGeometry(x: 0, y: -1, width: 406, height: 890),
            AutoLevelWindowGeometry(x: 1_200, y: 33, width: 406, height: 890),
            AutoLevelWindowGeometry(x: 0, y: 100, width: 406, height: 890),
        ] {
            #expect(!isBackdrop(notificationCenter, expectedWindowFrame: frame))
            #expect(!isBackdrop(dock, expectedWindowFrame: frame))
        }
    }

    @Test("Offset displays use their own full bounds without an origin-zero assumption")
    func offsetDisplayBounds() {
        for display in [
            AutoLevelWindowGeometry(x: -1_920, y: -200, width: 1_920, height: 1_080),
            AutoLevelWindowGeometry(x: 1_512, y: 300, width: 1_920, height: 1_080),
        ] {
            var candidate = notificationCenter
            candidate.frame = display
            let target = AutoLevelWindowGeometry(
                x: display.x + 50, y: display.y + 50, width: 406, height: 890
            )
            #expect(isBackdrop(
                candidate, expectedWindowFrame: target, displayFrames: [displayFrame, display]
            ))
            #expect(!isBackdrop(
                candidate, expectedWindowFrame: target, displayFrames: [displayFrame]
            ))
        }
    }

    @Test("Malformed or overflowing geometry cannot qualify as a system backdrop")
    func invalidGeometryFailsClosed() {
        let invalidFrames: [AutoLevelWindowGeometry] = [
            .init(x: .nan, y: 0, width: 1_512, height: 982),
            .init(x: 0, y: .infinity, width: 1_512, height: 982),
            .init(x: 0, y: 0, width: .infinity, height: 982),
            .init(x: 0, y: 0, width: 1_512, height: .nan),
            .init(x: 0, y: 0, width: 0, height: 982),
            .init(x: 0, y: 0, width: 1_512, height: -982),
            .init(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 982),
            .init(x: 0, y: .greatestFiniteMagnitude, width: 1_512, height: .greatestFiniteMagnitude),
        ]
        for frame in invalidFrames {
            for window in [notificationCenter, dock] {
                var candidate = window
                candidate.frame = frame
                #expect(!isBackdrop(candidate, displayFrames: [frame]))
                #expect(!isBackdrop(window, expectedWindowFrame: frame))
            }
            #expect(!isBackdrop(notificationCenter, displayFrames: [frame]))
        }
    }

    @Test("External and same-process windows remain occluders beneath the system backdrops")
    func actualWindowsStillBlockInput() {
        for occluder in [
            Window(identity: .init(processID: 46_525, windowID: 86_529),
                   owner: "com.openai.codex", layer: 0, name: nil, frame: displayFrame),
            Window(identity: .init(processID: mirror.processID, windowID: mirror.windowID + 1),
                   owner: "com.apple.ScreenContinuity", layer: 0, name: nil, frame: mirrorFrame),
        ] {
            let topmost = firstOccluder(in: [notificationCenter, dock, occluder, mirrorWindow])
            #expect(topmost == occluder.identity)
            #expect(safetyRejection(topmost: topmost) == .clickPointObscured)
        }
    }

    private struct Window {
        let identity: AutoLevelWindowIdentity
        var owner: String?
        var layer: Int
        var name: String?
        var frame: AutoLevelWindowGeometry
    }

    private var notificationCenter: Window {
        .init(identity: .init(processID: 719, windowID: 14),
              owner: "com.apple.notificationcenterui", layer: 21, name: nil, frame: displayFrame)
    }

    private var dock: Window {
        .init(identity: .init(processID: 637, windowID: 8),
              owner: "com.apple.dock", layer: 20, name: "Dock", frame: displayFrame)
    }

    private var mirrorWindow: Window {
        .init(identity: mirror, owner: "com.apple.ScreenContinuity",
              layer: 0, name: nil, frame: mirrorFrame)
    }

    private func isBackdrop(
        _ window: Window,
        expectedWindowFrame: AutoLevelWindowGeometry? = nil,
        displayFrames: [AutoLevelWindowGeometry]? = nil,
        hitProcessID: Int32? = 91_507,
        hitError: Int32 = 0,
        expectedProcessID: Int32 = 91_507
    ) -> Bool {
        AutoLevelSystemBackdrop.isNonOccluding(
            ownerBundleIdentifier: window.owner, layer: window.layer, name: window.name,
            frame: window.frame, expectedWindowFrame: expectedWindowFrame ?? mirrorFrame,
            displayFrames: displayFrames ?? [displayFrame], hitProcessID: hitProcessID,
            hitError: hitError, expectedProcessID: expectedProcessID
        )
    }

    private func firstOccluder(
        in windowsAtPointFrontToBack: [Window], hitProcessID: Int32? = 91_507
    ) -> AutoLevelWindowIdentity? {
        windowsAtPointFrontToBack.first { !isBackdrop($0, hitProcessID: hitProcessID) }?.identity
    }

    private func safetyRejection(topmost: AutoLevelWindowIdentity?) -> AutoLevelInputRejection? {
        AutoLevelInputSafety.rejection(
            expectedWindowIdentity: mirror, expectedWindowGeometry: mirrorFrame,
            snapshot: .init(
                windowIdentity: mirror, windowGeometry: mirrorFrame,
                frontmostProcessID: mirror.processID, topmostWindowIdentity: topmost,
                targetProcessTopmostWindowIdentity: mirror
            ),
            now: 100, actionDeadline: 112, sessionDeadline: 200, stopRequested: false
        )
    }
}
