import AppKit
import ApplicationServices
import Foundation
import MirrorProbeCore

/// One passive observer belongs to one borrow. AppKit tokens are accessed on the main thread;
/// the small decision state is protected by a lock because automation runs off the main thread.
/// No key values, characters, pointer coordinates, or event objects are retained.
final class ForegroundFocusBorrowMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var restoration: ForegroundFocusRestoration
    private let startedAt: TimeInterval
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: (any NSObjectProtocol)?

    init(targetProcessID: Int32, previousProcessID: Int32) {
        startedAt = ProcessInfo.processInfo.systemUptime
        restoration = ForegroundFocusRestoration(
            targetProcessID: targetProcessID,
            previousProcessID: previousProcessID
        )
        Self.onMainThread { self.install() }
    }

    deinit { stop() }

    func cancelRestoration(reason: ForegroundFocusRestorationCancellation) {
        lock.withLock { restoration.cancelRestoration(reason: reason) }
    }

    var cancellationReason: ForegroundFocusRestorationCancellation? {
        lock.withLock { restoration.cancellationReason }
    }

    func takeRestorationTarget(
        currentProcessID: Int32?,
        previousApplicationTerminated: Bool
    ) -> (processID: Int32?, cancellationReason: ForegroundFocusRestorationCancellation?) {
        Self.onMainThread {
            self.lock.withLock {
                let processID = self.restoration.takeRestorationTarget(
                    currentProcessID: currentProcessID,
                    previousApplicationTerminated: previousApplicationTerminated
                )
                return (processID, self.restoration.cancellationReason)
            }
        }
    }

    func stop() {
        Self.onMainThread {
            if let globalMonitor = self.globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let localMonitor = self.localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let observer = self.activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                self.activationObserver = nil
            }
        }
    }

    @MainActor
    private func install() {
        guard AXIsProcessTrusted() else {
            cancelRestoration(reason: .monitoringUnavailable)
            return
        }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.recordActivation(processID: app?.processIdentifier)
        }
        if globalMonitor == nil || localMonitor == nil {
            cancelRestoration(reason: .monitoringUnavailable)
        }
    }

    private func record(_ event: NSEvent) {
        // Global monitoring is asynchronous. Do not let a delayed event from an earlier borrow
        // cancel a new one that started after that event occurred.
        guard !event.timestamp.isFinite || event.timestamp >= startedAt else { return }
        let isAutomationInput = AutomationInputMarker.matches(event.cgEvent)
        lock.withLock { restoration.recordInput(isAutomationInput: isAutomationInput) }
    }

    private func recordActivation(processID: Int32?) {
        lock.withLock { restoration.recordApplicationActivation(processID: processID) }
    }

    private static func onMainThread<Result: Sendable>(
        _ action: @MainActor @Sendable () -> Result
    ) -> Result {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { action() }
        } else {
            return DispatchQueue.main.sync { MainActor.assumeIsolated { action() } }
        }
    }
}
