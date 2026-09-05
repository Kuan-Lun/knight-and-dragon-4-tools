import Darwin
import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Per-window automation run lock")
struct AutoLevelWindowRunLockTests {
    @Test("Lock names are stable and include user, mirror process, and window identities")
    func stableLockName() {
        #expect(
            AutoLevelWindowRunLock.lockFileName(
                userID: 501,
                processID: 12_345,
                windowID: 67_890
            ) == "mirror-probe-run-u501-p12345-w67890.lock"
        )
    }

    @Test("A second nonblocking acquisition for the same window is refused")
    func refusesConcurrentOwner() throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirror-probe-lock-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let lockDirectory = testRoot.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let userID = UInt32(Darwin.getuid())
        let identity = AutoLevelWindowIdentity(processID: 5_678, windowID: 9_012)
        let first = try AutoLevelWindowRunLock.acquire(
            for: identity,
            userID: userID,
            lockDirectory: lockDirectory
        )

        do {
            let unexpected = try AutoLevelWindowRunLock.acquire(
                for: identity,
                userID: userID,
                lockDirectory: lockDirectory
            )
            unexpected.release()
            Issue.record("A second lock unexpectedly acquired the same window")
        } catch let error as AutoLevelWindowRunLockError {
            #expect(
                error == .alreadyLocked(
                    userID: userID,
                    processID: identity.processID,
                    windowID: identity.windowID
                )
            )
        } catch {
            Issue.record("Unexpected lock error: \(error)")
        }

        first.release()
        let reacquired = try AutoLevelWindowRunLock.acquire(
            for: identity,
            userID: userID,
            lockDirectory: lockDirectory
        )
        reacquired.release()
    }
}
