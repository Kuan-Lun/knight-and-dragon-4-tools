import Testing
@testable import MirrorProbeCore

@Suite("Character total boundary corroborator")
struct CharacterTotalCorroboratorTests {
    @Test("Two OCR reads on the high side stop even when their digit values differ")
    func highSideStops() {
        for (full, focused) in [(91, 97), (97, 91), (90, 99)] {
            #expect(decision(full: full, focused: focused, rendered: 2, minimum: 90)
                == .thresholdReached)
        }
        #expect(decision(full: 100, focused: 125, rendered: 3, minimum: 90)
            == .thresholdReached)
    }

    @Test("A two-digit low-side reroll requires exact OCR value agreement")
    func lowSideRequiresExactAgreement() {
        for value in [10, 73, 89] {
            #expect(decision(full: value, focused: value, rendered: 2, minimum: 90)
                == .rerollRequired)
        }
        #expect(decision(full: 81, focused: 87, rendered: 2, minimum: 90)
            == .unsafeBoundaryConflict)
    }

    @Test("Every cross-boundary OCR disagreement is a terminal conflict")
    func crossBoundaryFailsClosed() {
        for (full, focused) in [(89, 90), (90, 89), (87, 97), (97, 87)] {
            #expect(decision(full: full, focused: focused, rendered: 2, minimum: 90)
                == .unsafeBoundaryConflict)
        }
    }

    @Test("One-digit low reads must agree below 100, while three digits stop")
    func unambiguousDigitLengths() {
        #expect(decision(full: 9, focused: 9, rendered: 1, minimum: 90)
            == .rerollRequired)
        #expect(decision(full: 9, focused: 7, rendered: 1, minimum: 90)
            == .unsafeBoundaryConflict)
        #expect(decision(full: 100, focused: 125, rendered: 3, minimum: 100)
            == .thresholdReached)
    }

    @Test("The 100 mode still permits different two-digit OCR values")
    func threeDigitBoundaryMode() {
        #expect(decision(full: 91, focused: 97, rendered: 2, minimum: 100)
            == .rerollRequired)
        #expect(decision(full: 99, focused: 90, rendered: 2, minimum: 100)
            == .rerollRequired)
        #expect(decision(full: 9, focused: 7, rendered: 1, minimum: 100)
            == .rerollRequired)
    }

    @Test("Any OCR or rendered digit-count disagreement fails closed")
    func digitCountDisagreementFailsClosed() {
        #expect(decision(
            full: 99, focused: 100, focusedDigits: 3, rendered: 3, minimum: 100
        ) == .unsafeBoundaryConflict)
        #expect(decision(
            full: 100, focused: 99, focusedDigits: 2, rendered: 3, minimum: 100
        ) == .unsafeBoundaryConflict)
        #expect(decision(
            full: 100, focused: 100, focusedDigits: 3, rendered: 2, minimum: 100
        ) == .unsafeBoundaryConflict)
        #expect(decision(
            full: 73, focused: 73, focusedDigits: 2, rendered: 1, minimum: 90
        ) == .unsafeDigitCountMismatch)
    }

    @Test("Invalid thresholds, ranges, and focused metadata fail closed")
    func invalidEvidenceFailsClosed() {
        #expect(decision(full: 73, focused: 73, rendered: 2, minimum: 89)
            == .invalidMinimumTotal)
        #expect(decision(full: 73, focused: 73, rendered: 2, minimum: 101)
            == .invalidMinimumTotal)
        #expect(decision(full: -1, focused: 73, rendered: 2, minimum: 90)
            == .unsafeDigitCountMismatch)
        #expect(decision(full: 73, focused: 73, focusedDigits: 3, rendered: 2, minimum: 90)
            == .unsafeDigitCountMismatch)
        #expect(decision(full: 73, focused: 73, rendered: 0, minimum: 90)
            == .unsafeDigitCountMismatch)
        #expect(decision(full: 73, focused: 73, rendered: 4, minimum: 90)
            == .unsafeDigitCountMismatch)
    }

    private func decision(
        full: Int,
        focused: Int,
        focusedDigits: Int? = nil,
        rendered: Int,
        minimum: Int
    ) -> CharacterTotalBoundaryDecision {
        CharacterTotalCorroborator.decide(
            fullFrameTotal: full,
            focusedRead: CharacterFocusedTotalRead(
                value: focused,
                digitCount: focusedDigits ?? String(focused).count
            ),
            renderedDigitCount: rendered,
            minimumTotal: minimum
        )
    }
}
