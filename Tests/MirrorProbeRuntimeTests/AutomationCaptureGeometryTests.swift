import Foundation
import Testing
@testable import MirrorProbeRuntime

@Suite("Capture continuity across display changes")
struct AutomationCaptureGeometryTests {
    @Test("A display scale change invalidates evidence even when point geometry is unchanged")
    func changedBackingPixels() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = AutomationWindowRecoveryContext(
            stopURL: directory.url.appendingPathComponent("STOP"), sessionDeadline: nil
        )
        recovery.recordCaptureLayout(width: 404, height: 874, bytesPerRow: 1616)
        #expect(recovery.generation == 0)
        recovery.recordCaptureLayout(width: 808, height: 1748, bytesPerRow: 3232)
        #expect(recovery.generation == 1)
        recovery.recordCaptureLayout(width: 808, height: 1748, bytesPerRow: 3232)
        #expect(recovery.generation == 1)

        // Geometry recovery already interrupted continuity; its first new capture establishes
        // the new backing layout without manufacturing a second unrelated interruption.
        recovery.interruptContinuity()
        recovery.recordCaptureLayout(width: 404, height: 886, bytesPerRow: 1616)
        #expect(recovery.generation == 2)
    }

    @Test("Different post-action layouts are not compared using preflight buffer dimensions")
    func changedLayoutsSkipDifference() throws {
        let before = rgba(width: 4, height: 8)
        let shorter = rgba(width: 4, height: 6)
        let scaled = rgba(width: 8, height: 16)
        for after in [shorter, scaled] {
            #expect(try MirrorProbeRuntime.automationActionFrameDifference(
                before: before, after: after, continuityUnchanged: true
            ) == nil)
        }
        #expect(try MirrorProbeRuntime.automationActionFrameDifference(
            before: before, after: before, continuityUnchanged: false
        ) == nil)
        #expect(try MirrorProbeRuntime.automationActionFrameDifference(
            before: before, after: before, continuityUnchanged: true
        ) == 0)
    }

    private func rgba(width: Int, height: Int) -> RGBAFrame {
        RGBAFrame(bytes: Array(repeating: 255, count: width * height * 4),
                  width: width, height: height, bytesPerRow: width * 4)
    }
}
