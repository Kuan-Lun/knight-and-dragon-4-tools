import Foundation

/// Shares AppKit's Quit request with the command's existing safe stop checkpoints.
/// A Quit request is latched for the process lifetime, even when no STOP file is configured.
public final class AutomationStopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var quitRequested = false

    public init() {}

    /// Returns true only for the first Quit request, so repeated Quit events are harmless.
    @discardableResult
    public func requestApplicationQuit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasRequested = quitRequested
        quitRequested = true
        return !wasRequested
    }

    public var applicationQuitRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return quitRequested
    }

    public func isRequested(stopFileURL: URL?) -> Bool {
        if applicationQuitRequested { return true }
        guard let stopFileURL else { return false }
        return FileManager.default.fileExists(atPath: stopFileURL.path)
    }

    /// Used only after a stop checkpoint has returned true.
    public var reportReason: String {
        applicationQuitRequested ? "applicationQuitRequested" : "stopFileDetected"
    }
}
