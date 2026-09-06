import Testing
@testable import MirrorProbeCore

@Suite("Character total boundary evidence resolver")
struct CharacterTotalBoundaryEvidenceResolverTests {
    @Test("Small OCR box variation preserves threshold and contamination vetoes")
    func overlappingFragmentsKeepBoundaryProtection() {
        let label = OCRTextObservation(
            text: "total:",
            rect: NormalizedRect(x: 0.808, y: 0.320, width: 0.103, height: 0.014),
            confidence: 1
        )
        let digitsX = 0.911 - 2.4 / 406
        for total in [84, 90, 100, 125] {
            let digits = OCRTextObservation(
                text: "\(total)",
                rect: NormalizedRect(x: digitsX, y: 0.320, width: 0.956 - digitsX, height: 0.014),
                confidence: 1
            )
            for minimum in [90, 100] {
                let rows = [label, digits]
                let focused = CharacterFocusedTotalResolver.resolveEvidence(observations: rows)
                let detection = CharacterTotalDigitDetection.digitCount(String(total).count)
                #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
                    fullFrame: CharacterFullFrameTotalResolver.resolve(observations: rows),
                    focused: focused,
                    renderedDigitDetection: detection,
                    minimumTotal: minimum
                ) == (total >= minimum ? .thresholdReached : .belowThreshold))

                for extraText in ["9O", "97", "total: 97"] {
                    let extra = OCRTextObservation(
                        text: extraText,
                        rect: NormalizedRect(x: 0.958, y: 0.320, width: 0.020, height: 0.014),
                        confidence: 1
                    )
                    let contaminatedRows = rows + [extra]
                    #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
                        fullFrame: CharacterFullFrameTotalResolver.resolve(
                            observations: contaminatedRows
                        ),
                        focused: focused,
                        renderedDigitDetection: detection,
                        minimumTotal: minimum
                    ) == .boundaryConflict)
                    #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
                        fullFrame: CharacterFullFrameTotalResolver.resolve(observations: rows),
                        focused: CharacterFocusedTotalResolver.resolveEvidence(
                            observations: contaminatedRows
                        ),
                        renderedDigitDetection: detection,
                        minimumTotal: minimum
                    ) == .boundaryConflict)
                }
            }
        }
    }

    @Test("Three complete sources distinguish safe low and safe keeper values")
    func completeEvidence() {
        #expect(evidence(full: .exact(read(73)), focused: read(73), raw: 2)
            == .belowThreshold)
        #expect(evidence(full: .exact(read(91)), focused: read(97), raw: 2)
            == .thresholdReached)
    }

    @Test("Any incomplete credible high source is an immediate conflict")
    func incompleteHighFailsClosed() {
        #expect(evidence(full: .exact(read(97)), focused: nil, raw: 2)
            == .boundaryConflict)
        #expect(evidence(full: .unavailable, focused: read(97), raw: 2)
            == .boundaryConflict)
        #expect(evidence(full: .exact(read(97)), focused: read(97), raw: nil)
            == .boundaryConflict)
        #expect(evidence(full: .unavailable, focused: nil, raw: 3)
            == .boundaryConflict)
    }

    @Test("Incomplete low evidence never authorizes a click")
    func incompleteLowIsUnavailable() {
        #expect(evidence(full: .exact(read(73)), focused: nil, raw: 2)
            == .unavailable)
        #expect(evidence(full: .unavailable, focused: nil, raw: 2)
            == .unavailable)
    }

    @Test("Contaminated full-frame evidence can veto but never authorize")
    func contaminatedEvidence() {
        #expect(evidence(
            full: .contaminated(credibleReads: [read(87), read(97)]),
            focused: read(87),
            raw: 2
        ) == .boundaryConflict)
        #expect(evidence(
            full: .contaminated(credibleReads: [read(73)]),
            focused: read(73),
            raw: 2
        ) == .boundaryConflict)
        #expect(evidence(
            full: .contaminated(credibleReads: [read(73)]),
            focused: read(73),
            raw: 2,
            minimum: 100
        ) == .boundaryConflict)
        #expect(evidence(
            full: .contaminated(credibleReads: []),
            focused: nil,
            raw: 2
        ) == .boundaryConflict)
    }

    @Test("Two-digit-threshold contamination permanently vetoes a later clean low sample")
    func contaminatedLowIsStickyAtNinety() {
        var latch = CharacterTotalBoundaryLatch()
        let contaminated = evidence(
            full: .contaminated(credibleReads: [read(87)]),
            focused: read(87),
            raw: 2
        )
        let laterCleanLow = evidence(
            full: .exact(read(87)),
            focused: read(87),
            raw: 2
        )

        #expect(latch.observe(contaminated) == .terminalVeto)
        #expect(latch.observe(laterCleanLow) == .terminalVeto)
    }

    @Test("A possible leading hundreds glyph is terminal even before OCR agrees")
    func ambiguousHundredsSlotIsSticky() {
        var latch = CharacterTotalBoundaryLatch()
        let ambiguous = CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .exact(read(99)),
            focused: .exact(CharacterFocusedTotalRead(value: 99, digitCount: 2)),
            renderedDigitDetection: .boundaryAmbiguous,
            minimumTotal: 100
        )
        let laterLow = evidence(
            full: .exact(read(99)),
            focused: read(99),
            raw: 2,
            minimum: 100
        )

        #expect(latch.observe(ambiguous) == .terminalVeto)
        #expect(latch.observe(laterLow) == .terminalVeto)
    }

    @Test("Focused contamination containing a keeper read is terminal")
    func focusedContaminationRetainsKeeperEvidence() {
        #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .exact(read(87)),
            focused: .contaminated(credibleReads: [
                CharacterFocusedTotalRead(value: 97, digitCount: 2),
            ]),
            renderedDigitDetection: .digitCount(2),
            minimumTotal: 90
        ) == .boundaryConflict)
    }

    @Test("The 100 boundary retains its digit-length compatibility rules")
    func hundredCompatibility() {
        #expect(evidence(
            full: .exact(read(91)), focused: read(97), raw: 2, minimum: 100
        ) == .belowThreshold)
        #expect(evidence(
            full: .exact(read(100)), focused: read(125), raw: 3, minimum: 100
        ) == .thresholdReached)
        #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .exact(read(91)),
            focused: .contaminated(credibleReads: [
                CharacterFocusedTotalRead(value: 97, digitCount: 2),
            ]),
            renderedDigitDetection: .digitCount(2),
            minimumTotal: 100
        ) == .boundaryConflict)
        #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .contaminated(credibleReads: [read(100)]),
            focused: .exact(CharacterFocusedTotalRead(value: 100, digitCount: 3)),
            renderedDigitDetection: .digitCount(3),
            minimumTotal: 100
        ) == .boundaryConflict)
    }

    @Test("Any raw detector failure is terminal and cannot be erased by a later low sample")
    func rawFailureIsSticky() {
        var latch = CharacterTotalBoundaryLatch()
        let unsafeRaw = CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .exact(read(99)),
            focused: .exact(CharacterFocusedTotalRead(value: 99, digitCount: 2)),
            renderedDigitDetection: .unsafe,
            minimumTotal: 100
        )
        let laterLow = evidence(
            full: .exact(read(99)), focused: read(99), raw: 2, minimum: 100
        )

        #expect(latch.observe(unsafeRaw) == .terminalVeto)
        #expect(latch.observe(laterLow) == .terminalVeto)
    }

    @Test("Inconsistent public read metadata is terminal")
    func invalidReadMetadata() {
        #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .exact(CharacterFullFrameTotalRead(value: 87, digitCount: 3)),
            focused: .exact(CharacterFocusedTotalRead(value: 87, digitCount: 2)),
            renderedDigitDetection: .digitCount(2),
            minimumTotal: 90
        ) == .boundaryConflict)
        #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: .exact(read(87)),
            focused: .exact(CharacterFocusedTotalRead(value: 87, digitCount: 3)),
            renderedDigitDetection: .digitCount(2),
            minimumTotal: 90
        ) == .boundaryConflict)
    }

    @Test("Cross-boundary and unequal low reads conflict at 90")
    func disagreementsFailClosed() {
        #expect(evidence(full: .exact(read(89)), focused: read(90), raw: 2)
            == .boundaryConflict)
        #expect(evidence(full: .exact(read(81)), focused: read(87), raw: 2)
            == .boundaryConflict)
    }

    private func evidence(
        full: CharacterFullFrameTotalResolution,
        focused: CharacterFullFrameTotalRead?,
        raw: Int?,
        minimum: Int = 90
    ) -> CharacterTotalBoundaryEvidence {
        CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: full,
            focused: focused.map {
                .exact(CharacterFocusedTotalRead(value: $0.value, digitCount: $0.digitCount))
            } ?? .unavailable,
            renderedDigitDetection: raw.map(CharacterTotalDigitDetection.digitCount) ?? .unsafe,
            minimumTotal: minimum
        )
    }

    private func read(_ value: Int) -> CharacterFullFrameTotalRead {
        CharacterFullFrameTotalRead(value: value, digitCount: String(value).count)
    }
}
