import Foundation

/// Durations use the session's monotonic clock, never wall-clock timestamps.
/// The first sample runs from session start to the first observed result; later
/// samples run between results, including the intervening result-page actions.
struct AutomationTimingReport: Codable {
    private(set) var elapsedSeconds: Double = 0
    private(set) var completedCycleCount: Int = 0
    private(set) var completedCycleTotalSeconds: Double = 0
    private(set) var averageCycleSeconds: Double?
    private(set) var medianCycleSeconds: Double?
    private(set) var fastestCycleSeconds: Double?
    private(set) var slowestCycleSeconds: Double?
    private(set) var lastCycleSeconds: Double?
    private(set) var secondsSinceLastCycle: Double?
    private(set) var cyclesPerHour: Double?
    // Retain measured samples for an exact median and round-trip persistence.
    // Older timing summaries lack these samples; their median remains unavailable.
    private var cycleDurationsSeconds: [Double]? = []

    mutating func updateElapsed(_ elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        // Recognition can log a newer decision before an older capture is reused.
        elapsedSeconds = max(elapsedSeconds, elapsed)
        secondsSinceLastCycle = completedCycleCount > 0
            ? max(0, elapsedSeconds - completedCycleTotalSeconds) : nil
        cyclesPerHour = elapsedSeconds > 0
            ? Double(completedCycleCount) / elapsedSeconds * 3600 : nil
    }

    mutating func recordCompletedCycle(count: Int, elapsed: TimeInterval) {
        // Reused result frames and subsequent actions must not count a sample twice.
        guard count == completedCycleCount + 1,
              elapsed.isFinite, elapsed >= completedCycleTotalSeconds
        else { return }
        let duration = elapsed - completedCycleTotalSeconds
        completedCycleCount = count
        completedCycleTotalSeconds = elapsed
        averageCycleSeconds = elapsed / Double(count)
        cycleDurationsSeconds?.append(duration)
        if let durations = cycleDurationsSeconds, durations.count == count {
            let sorted = durations.sorted()
            let middle = sorted.count / 2
            medianCycleSeconds = sorted.count.isMultiple(of: 2)
                ? sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
                : sorted[middle]
        } else {
            // A partial sample history cannot establish the whole-run median.
            medianCycleSeconds = nil
            cycleDurationsSeconds = nil
        }
        fastestCycleSeconds = min(fastestCycleSeconds ?? duration, duration)
        slowestCycleSeconds = max(slowestCycleSeconds ?? duration, duration)
        lastCycleSeconds = duration
        updateElapsed(elapsed)
    }

    private enum CodingKeys: String, CodingKey {
        case elapsedSeconds, completedCycleCount, completedCycleTotalSeconds
        case averageCycleSeconds, medianCycleSeconds, fastestCycleSeconds, slowestCycleSeconds
        case lastCycleSeconds, secondsSinceLastCycle, cyclesPerHour
        case cycleDurationsSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try container.encode(completedCycleCount, forKey: .completedCycleCount)
        try container.encode(completedCycleTotalSeconds, forKey: .completedCycleTotalSeconds)
        // Explicit null means there is no measured sample, not a zero-second cycle.
        try container.encode(averageCycleSeconds, forKey: .averageCycleSeconds)
        try container.encode(medianCycleSeconds, forKey: .medianCycleSeconds)
        try container.encode(fastestCycleSeconds, forKey: .fastestCycleSeconds)
        try container.encode(slowestCycleSeconds, forKey: .slowestCycleSeconds)
        try container.encode(lastCycleSeconds, forKey: .lastCycleSeconds)
        try container.encode(secondsSinceLastCycle, forKey: .secondsSinceLastCycle)
        try container.encode(cyclesPerHour, forKey: .cyclesPerHour)
        try container.encode(cycleDurationsSeconds, forKey: .cycleDurationsSeconds)
    }
}
