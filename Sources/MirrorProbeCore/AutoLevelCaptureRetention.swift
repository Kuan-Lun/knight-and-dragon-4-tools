public enum AutoLevelCaptureLevel: String, Codable, Equatable, Sendable {
    case error
    case info
}

public enum AutoLevelCaptureTerminationKind: String, Codable, Equatable, Sendable {
    case expectedLimit
    case userStop
    case safetyStop
    case runtimeError
}

/// The screenshot roles which should survive an automation run. The executable owns image
/// encoding and filesystem writes; this Core value only describes retention policy.
public struct AutoLevelCaptureRetentionPlan: Equatable, Sendable {
    public let retainsInitial: Bool
    public let retainsActionPairs: Bool
    public let retainsRecent: Bool
    public let retainsFinal: Bool

    public init(
        retainsInitial: Bool,
        retainsActionPairs: Bool,
        retainsRecent: Bool,
        retainsFinal: Bool
    ) {
        self.retainsInitial = retainsInitial
        self.retainsActionPairs = retainsActionPairs
        self.retainsRecent = retainsRecent
        self.retainsFinal = retainsFinal
    }

    public var retainsAnyScreenshot: Bool {
        retainsInitial || retainsActionPairs || retainsRecent || retainsFinal
    }
}

/// Separates screenshot-retention decisions from ScreenCaptureKit and filesystem side effects.
/// `info` retains the routine audit trail. Either diagnostic termination retains recent context,
/// while every such termination and every `info` run retains a final frame when one is available.
public struct AutoLevelCaptureRetentionPolicy: Equatable, Sendable {
    public let level: AutoLevelCaptureLevel

    public init(level: AutoLevelCaptureLevel) {
        self.level = level
    }

    public func plan(
        for termination: AutoLevelCaptureTerminationKind
    ) -> AutoLevelCaptureRetentionPlan {
        let retainsRoutineAudit = level == .info
        let retainsDiagnosticContext: Bool
        switch termination {
        case .safetyStop, .runtimeError:
            retainsDiagnosticContext = true
        case .expectedLimit, .userStop:
            retainsDiagnosticContext = false
        }

        return AutoLevelCaptureRetentionPlan(
            retainsInitial: retainsRoutineAudit,
            retainsActionPairs: retainsRoutineAudit,
            retainsRecent: retainsDiagnosticContext,
            retainsFinal: retainsRoutineAudit || retainsDiagnosticContext
        )
    }
}

/// A bounded, value-semantic buffer whose snapshot is always ordered oldest to newest.
/// Elements are intentionally not deduplicated: two captures with identical fingerprints still
/// represent distinct points in the run's timeline.
public struct RecentCaptureBuffer<Element> {
    public let capacity: Int

    private var storage: [Element]
    private var nextInsertionIndex: Int

    public init(capacity: Int = 8) {
        precondition(capacity > 0, "RecentCaptureBuffer capacity must be positive")
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
        nextInsertionIndex = 0
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public var elementsOldestFirst: [Element] {
        guard storage.count == capacity, nextInsertionIndex != 0 else {
            return storage
        }
        return Array(storage[nextInsertionIndex...]) + Array(storage[..<nextInsertionIndex])
    }

    /// Adds one temporal sample and returns the evicted oldest element, if the buffer was full.
    @discardableResult
    public mutating func append(_ element: Element) -> Element? {
        guard storage.count == capacity else {
            storage.append(element)
            return nil
        }

        let evicted = storage[nextInsertionIndex]
        storage[nextInsertionIndex] = element
        nextInsertionIndex = (nextInsertionIndex + 1) % capacity
        return evicted
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        nextInsertionIndex = 0
    }
}

extension RecentCaptureBuffer: Equatable where Element: Equatable {
    public static func == (
        lhs: RecentCaptureBuffer<Element>,
        rhs: RecentCaptureBuffer<Element>
    ) -> Bool {
        lhs.capacity == rhs.capacity
            && lhs.elementsOldestFirst == rhs.elementsOldestFirst
    }
}
extension RecentCaptureBuffer: Sendable where Element: Sendable {}
