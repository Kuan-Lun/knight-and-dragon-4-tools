import Darwin
import Foundation

public enum AutoLevelWindowRunLockError: Error, Equatable, LocalizedError, Sendable {
    case alreadyLocked(userID: UInt32, processID: Int32, windowID: UInt32)
    case unsafeLockObject(String)
    case systemFailure(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .alreadyLocked(userID, processID, windowID):
            return "Another mirror-probe run already controls iPhone Mirroring window ID "
                + "\(windowID) (process \(processID), user \(userID)). Repeated launch for "
                + "that window is refused."
        case let .unsafeLockObject(reason):
            return "The per-window run lock failed its safety checks: \(reason)"
        case let .systemFailure(operation, code):
            return "Could not acquire the per-window run lock: \(operation) failed with errno "
                + "\(code) (\(String(cString: strerror(code))))."
        }
    }
}

/// A cross-process exclusive advisory lock for one exact iPhone Mirroring window.
///
/// Lock files are deliberately retained after release. Reusing one stable inode prevents two
/// cooperating launches from acquiring different locks during an unlink-and-recreate race.
public final class AutoLevelWindowRunLock: @unchecked Sendable {
    private static let lockDirectoryName = "mirror-probe-window-run-locks-v1"
    private static let ownerOnlyDirectoryMode = mode_t(0o700)
    private static let ownerOnlyFileMode = mode_t(0o600)

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Acquires the exact window's lock without waiting.
    public static func acquire(
        for identity: AutoLevelWindowIdentity
    ) throws -> AutoLevelWindowRunLock {
        let userID = UInt32(Darwin.getuid())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            lockDirectoryName,
            isDirectory: true
        )
        return try acquire(for: identity, userID: userID, lockDirectory: directory)
    }

    /// Releases this instance's advisory lock. The lock file itself remains for safe reuse.
    public func release() {
        stateLock.lock()
        let descriptorToClose = descriptor
        descriptor = -1
        stateLock.unlock()

        guard descriptorToClose >= 0 else {
            return
        }
        _ = Self.setAdvisoryLock(descriptor: descriptorToClose, type: Int16(F_UNLCK))
        _ = Darwin.close(descriptorToClose)
    }

    static func lockFileName(
        userID: UInt32,
        processID: Int32,
        windowID: UInt32
    ) -> String {
        "mirror-probe-run-u\(userID)-p\(processID)-w\(windowID).lock"
    }

    static func acquire(
        for identity: AutoLevelWindowIdentity,
        userID: UInt32,
        lockDirectory: URL
    ) throws -> AutoLevelWindowRunLock {
        guard identity.processID > 0, identity.windowID > 0 else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the selected window identity is invalid"
            )
        }
        guard lockDirectory.isFileURL else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock directory is not a local filesystem path"
            )
        }

        let directoryDescriptor = try openVerifiedLockDirectory(
            at: lockDirectory,
            expectedUserID: userID
        )
        defer { _ = Darwin.close(directoryDescriptor) }

        let fileName = lockFileName(
            userID: userID,
            processID: identity.processID,
            windowID: identity.windowID
        )
        let fileDescriptor = try openVerifiedLockFile(
            named: fileName,
            in: directoryDescriptor,
            expectedUserID: userID
        )
        var closeOnFailure = true
        defer {
            if closeOnFailure {
                _ = Darwin.close(fileDescriptor)
            }
        }

        while setAdvisoryLock(descriptor: fileDescriptor, type: Int16(F_WRLCK)) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if code == EACCES || code == EAGAIN {
                throw AutoLevelWindowRunLockError.alreadyLocked(
                    userID: userID,
                    processID: identity.processID,
                    windowID: identity.windowID
                )
            }
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "fcntl(F_OFD_SETLK)",
                code: code
            )
        }

        closeOnFailure = false
        return AutoLevelWindowRunLock(descriptor: fileDescriptor)
    }

    private static func setAdvisoryLock(descriptor: Int32, type: Int16) -> Int32 {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, F_OFD_SETLK, &lock)
    }

    private static func openVerifiedLockDirectory(
        at directory: URL,
        expectedUserID: UInt32
    ) throws -> Int32 {
        var hasFileSystemRepresentation = false
        let makeResult = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            hasFileSystemRepresentation = true
            return Darwin.mkdir(path, ownerOnlyDirectoryMode)
        }
        if !hasFileSystemRepresentation {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock directory path could not be represented"
            )
        }
        if makeResult != 0, errno != EEXIST {
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "mkdir lock directory",
                code: errno
            )
        }

        hasFileSystemRepresentation = false
        let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            hasFileSystemRepresentation = true
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard hasFileSystemRepresentation else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock directory path could not be represented"
            )
        }
        guard descriptor >= 0 else {
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "open lock directory without following links",
                code: errno
            )
        }
        var closeOnFailure = true
        defer {
            if closeOnFailure {
                _ = Darwin.close(descriptor)
            }
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "inspect lock directory",
                code: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock directory path is not a directory"
            )
        }
        guard status.st_uid == uid_t(expectedUserID) else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock directory is not owned by the current user"
            )
        }
        guard status.st_mode & mode_t(0o777) == ownerOnlyDirectoryMode else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock directory permissions must be 0700"
            )
        }

        closeOnFailure = false
        return descriptor
    }

    private static func openVerifiedLockFile(
        named fileName: String,
        in directoryDescriptor: Int32,
        expectedUserID: UInt32
    ) throws -> Int32 {
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var descriptor = fileName.withCString { path in
            Darwin.openat(
                directoryDescriptor,
                path,
                createFlags,
                ownerOnlyFileMode
            )
        }
        let created = descriptor >= 0
        if descriptor < 0, errno == EEXIST {
            descriptor = fileName.withCString { path in
                Darwin.openat(
                    directoryDescriptor,
                    path,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else {
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "open lock file without following links",
                code: errno
            )
        }
        var closeOnFailure = true
        defer {
            if closeOnFailure {
                _ = Darwin.close(descriptor)
            }
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "inspect lock file",
                code: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock path is not a regular file"
            )
        }
        guard status.st_uid == uid_t(expectedUserID) else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock file is not owned by the current user"
            )
        }
        guard status.st_nlink == 1 else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock file must have exactly one filesystem link"
            )
        }

        if created, Darwin.fchmod(descriptor, ownerOnlyFileMode) != 0 {
            throw AutoLevelWindowRunLockError.systemFailure(
                operation: "set lock file permissions",
                code: errno
            )
        }
        if created {
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw AutoLevelWindowRunLockError.systemFailure(
                    operation: "reinspect lock file",
                    code: errno
                )
            }
        }
        guard status.st_mode & mode_t(0o777) == ownerOnlyFileMode else {
            throw AutoLevelWindowRunLockError.unsafeLockObject(
                "the lock file permissions must be 0600"
            )
        }

        closeOnFailure = false
        return descriptor
    }
}
