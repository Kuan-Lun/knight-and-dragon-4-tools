import Darwin
import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Run lock filesystem integration")
struct AutoLevelWindowRunLockFilesystemTests {
    private let identity = AutoLevelWindowIdentity(processID: 5_678, windowID: 9_012)
    private var userID: UInt32 { UInt32(getuid()) }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-probe-lock-filesystem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func lockFile(in directory: URL) -> URL {
        directory.appendingPathComponent(AutoLevelWindowRunLock.lockFileName(
            userID: userID, processID: identity.processID, windowID: identity.windowID
        ))
    }

    private func acquire(in directory: URL) throws -> AutoLevelWindowRunLock {
        try AutoLevelWindowRunLock.acquire(
            for: identity, userID: userID, lockDirectory: directory
        )
    }

    @Test("A separate process cannot acquire the window lock until it is released")
    func crossProcessExclusionAndRelease() throws {
        try withDirectory { directory in
            let lock = try acquire(in: directory)
            defer { lock.release() }
            // Python lockf uses the same kernel record-lock namespace. It exercises a
            // different process/file description, independently of the Swift wrapper.
            func childExit() throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", "-c", """
                import errno, fcntl, os, sys
                fd = os.open(sys.argv[1], os.O_RDWR)
                try:
                    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as error:
                    sys.exit(73 if error.errno in (errno.EAGAIN, errno.EACCES) else 74)
                finally:
                    os.close(fd)
                """, lockFile(in: directory).path]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationReason == .exit)
                return process.terminationStatus
            }
            #expect(try childExit() == 73)
            lock.release()
            lock.release() // Repeated cleanup must not close an unrelated descriptor.
            #expect(try childExit() == 0)
            #expect(FileManager.default.fileExists(atPath: lockFile(in: directory).path))
        }
    }

    @Test("Distinct window identities can run concurrently")
    func independentWindows() throws {
        try withDirectory { directory in
            let first = try acquire(in: directory)
            defer { first.release() }
            let second = try AutoLevelWindowRunLock.acquire(
                for: AutoLevelWindowIdentity(processID: identity.processID, windowID: 9_013),
                userID: userID, lockDirectory: directory
            )
            second.release()
        }
    }

    @Test("Unsafe existing directory permissions are rejected", arguments: [0o755, 0o770])
    func directoryPermissions(mode: Int) throws {
        try withDirectory { directory in
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
            #expect(throws: AutoLevelWindowRunLockError.self) { try acquire(in: directory) }
        }
    }

    @Test("Unsafe existing file permissions are rejected", arguments: [0o644, 0o660])
    func filePermissions(mode: Int) throws {
        try withDirectory { directory in
            let lock = try acquire(in: directory)
            lock.release()
            try FileManager.default.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: lockFile(in: directory).path
            )
            #expect(throws: AutoLevelWindowRunLockError.self) { try acquire(in: directory) }
        }
    }

    @Test("A directory symlink is refused without modifying its destination")
    func directorySymlink() throws {
        try withDirectory { directory in
            let destination = directory.appendingPathComponent("real")
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let link = directory.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            #expect(throws: AutoLevelWindowRunLockError.self) { try acquire(in: link) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test("A lock-file symlink is refused without modifying its destination")
    func fileSymlink() throws {
        try withDirectory { directory in
            let destination = directory.appendingPathComponent("unrelated")
            let original = Data("preserve this content".utf8)
            try original.write(to: destination)
            try FileManager.default.createSymbolicLink(
                at: lockFile(in: directory), withDestinationURL: destination
            )
            #expect(throws: AutoLevelWindowRunLockError.self) { try acquire(in: directory) }
            #expect(try Data(contentsOf: destination) == original)
        }
    }

    @Test("A lock file with a second hard link is refused")
    func hardLinkedFile() throws {
        try withDirectory { directory in
            let lock = try acquire(in: directory)
            lock.release()
            try FileManager.default.linkItem(
                at: lockFile(in: directory), to: directory.appendingPathComponent("alias")
            )
            #expect(throws: AutoLevelWindowRunLockError.self) { try acquire(in: directory) }
        }
    }

    @Test("A non-regular lock path is refused")
    func directoryAtFilePath() throws {
        try withDirectory { directory in
            try FileManager.default.createDirectory(
                at: lockFile(in: directory), withIntermediateDirectories: false
            )
            #expect(throws: AutoLevelWindowRunLockError.self) { try acquire(in: directory) }
        }
    }
}
