import Testing
@testable import MirrorProbeCore

@Suite("Character total boundary latch")
struct CharacterTotalBoundaryLatchTests {
    @Test("A boundary conflict is immediately terminal")
    func conflictIsTerminal() {
        var latch = CharacterTotalBoundaryLatch()
        #expect(latch.observe(.boundaryConflict) == .terminalVeto)
        #expect(latch.observe(.belowThreshold) == .terminalVeto)
        #expect(latch.observe(.thresholdReached) == .terminalVeto)
    }

    @Test("High evidence can never be replaced by low or unavailable OCR")
    func reachedBoundaryIsSticky() {
        for later in [
            CharacterTotalBoundaryEvidence.belowThreshold,
            .unavailable,
            .boundaryConflict,
        ] {
            var latch = CharacterTotalBoundaryLatch()
            #expect(latch.observe(.thresholdReached) == .continueStabilizing)
            #expect(latch.observe(later) == .terminalVeto)
            #expect(latch.observe(.thresholdReached) == .terminalVeto)
        }
    }

    @Test("Ordinary unavailable and low samples may stabilize before any high evidence")
    func lowSamplesRemainRetryable() {
        var latch = CharacterTotalBoundaryLatch()
        #expect(latch.observe(.unavailable) == .continueStabilizing)
        #expect(latch.observe(.belowThreshold) == .continueStabilizing)
        #expect(latch.observe(.thresholdReached) == .continueStabilizing)
        #expect(latch.observe(.thresholdReached) == .continueStabilizing)
    }
}
