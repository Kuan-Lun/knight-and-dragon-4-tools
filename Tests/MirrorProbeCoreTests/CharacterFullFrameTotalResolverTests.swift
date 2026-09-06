import Testing
@testable import MirrorProbeCore

@Suite("Full-frame character total resolver")
struct CharacterFullFrameTotalResolverTests {
    @Test("A calibrated exact total resolves independently of unrelated page anchors")
    func exactTotalResolves() {
        let observations = [
            observation("unrelated", rect(0.1, 0.1, 0.2, 0.02), confidence: .nan),
            observation(" ＴＯＴＡＬ ： 97 ", totalRect, confidence: 0.30),
        ]

        #expect(CharacterFullFrameTotalResolver.resolve(observations: observations)
            == .exact(CharacterFullFrameTotalRead(value: 97, digitCount: 2)))
    }

    @Test("The failed live total 81 row resolves despite Vision's small fragment overlap")
    func capturedSplitEightyOne() {
        let observations = [
            observation("total：", rect(
                0.807820612691448, 0.3212500003137998,
                0.10357059986133288, 0.013679774423663527
            )),
            observation("81", rect(
                0.9064039400656815, 0.32134831468164793,
                0.049261083743842304, 0.013483146067415741
            )),
        ]

        #expect(CharacterFullFrameTotalResolver.resolve(observations: observations)
            == .exact(CharacterFullFrameTotalRead(value: 81, digitCount: 2)))
        #expect(CharacterFullFrameTotalResolver.resolve(observations: Array(observations.reversed()))
            == .exact(CharacterFullFrameTotalRead(value: 81, digitCount: 2)))
    }

    @Test("Adjacent split rows preserve low and keeper values", arguments: [81, 90, 100, 125])
    func splitRowsPreserveBoundary(value: Int) {
        #expect(CharacterFullFrameTotalResolver.resolve(observations: splitRow(value))
            == .exact(CharacterFullFrameTotalRead(
                value: value, digitCount: String(value).count
            )))
    }

    @Test("A three-part row can separate the colon from its label")
    func threePartSplit() {
        #expect(CharacterFullFrameTotalResolver.resolve(observations: [
            observation("total", rect(0.794, 0.320, 0.080, 0.014)),
            observation(":", rect(0.876, 0.320, 0.014, 0.014)),
            observation("100", rect(0.897, 0.320, 0.059, 0.014)),
        ]) == .exact(CharacterFullFrameTotalRead(value: 100, digitCount: 3)))
    }

    @Test("Every split fragment retains the full-frame confidence floor")
    func splitConfidenceFloor() {
        #expect(CharacterFullFrameTotalResolver.resolve(
            observations: splitRow(81, confidence: 0.30)
        ) == .exact(CharacterFullFrameTotalRead(value: 81, digitCount: 2)))
        for index in 0...1 {
            var observations = splitRow(81)
            let original = observations[index]
            observations[index] = observation(
                original.text, original.rect, confidence: 0.2999
            )
            #expect(CharacterFullFrameTotalResolver.resolve(observations: observations)
                == .contaminated(credibleReads: []))
        }
    }

    @Test("Extra merged or split row text stays contaminated and retains credible subrows")
    func extraFragmentsCannotAuthorize() {
        let expectedRead = CharacterFullFrameTotalRead(value: 81, digitCount: 2)
        for extraText in ["97", "9O", "x"] {
            let extra = observation(extraText, rect(0.958, 0.320, 0.020, 0.014))
            #expect(CharacterFullFrameTotalResolver.resolve(
                observations: splitRow(81) + [extra]
            ) == .contaminated(credibleReads: [expectedRead]), Comment(rawValue: extraText))
            #expect(CharacterFullFrameTotalResolver.resolve(observations: [
                observation("total: 81", rect(0.808, 0.320, 0.148, 0.014)), extra,
            ]) == .contaminated(credibleReads: [expectedRead]), Comment(rawValue: extraText))
        }

        #expect(CharacterFullFrameTotalResolver.resolve(observations: splitRow(81) + [
            observation("total: 97", totalRect),
        ]) == .contaminated(credibleReads: [
            CharacterFullFrameTotalRead(value: 97, digitCount: 2),
            expectedRead,
        ]))
    }

    @Test("Split fragments need calibrated geometry and exact numeric grammar")
    func unsafeSplitRows() {
        let label = observation("total:", rect(0.808, 0.320, 0.103, 0.014))
        for number in [
            observation("81", rect(0.948, 0.320, 0.025, 0.014)),
            observation("81", rect(0.900, 0.320, 0.056, 0.014)),
            observation("81", rect(0.912, 0.335, 0.044, 0.014)),
            observation("81", rect(0.912, 0.320, 0.015, 0.014)),
            observation("9O", rect(0.912, 0.320, 0.044, 0.014)),
            observation("081", rect(0.912, 0.320, 0.044, 0.014)),
            observation("126", rect(0.912, 0.320, 0.044, 0.014)),
            observation("81", rect(0.912, 0.320, 0.044, 0.014), confidence: .nan),
        ] {
            #expect(CharacterFullFrameTotalResolver.resolve(observations: [label, number])
                == .contaminated(credibleReads: []))
        }
    }

    @Test("Ambiguous, weak, or misplaced total rows do not become boundary evidence")
    func unsafeCandidateFailsClosed() {
        #expect(CharacterFullFrameTotalResolver.resolve(observations: [
            observation("total: 97", totalRect, confidence: 0.2999),
        ]) == .contaminated(credibleReads: []))
        for observations in [
            [observation("total: 97", rect(0.50, 0.32, 0.15, 0.014))],
            [observation("total: 97", rect(0.81, 0.37, 0.15, 0.014))],
        ] {
            #expect(CharacterFullFrameTotalResolver.resolve(observations: observations)
                == .unavailable)
        }
    }

    @Test("Duplicate rows are contaminated but retain credible keeper reads")
    func duplicatesRetainOnlyVetoEvidence() {
        #expect(CharacterFullFrameTotalResolver.resolve(observations: [
            observation("total: 87", totalRect),
            observation("TOTAL: 97", totalRect),
        ]) == .contaminated(credibleReads: [
            CharacterFullFrameTotalRead(value: 87, digitCount: 2),
            CharacterFullFrameTotalRead(value: 97, digitCount: 2),
        ]))

        #expect(CharacterFullFrameTotalResolver.resolve(observations: [
            observation("total: 97", totalRect),
            observation("TOTAL: 9O", totalRect),
        ]) == .contaminated(credibleReads: [
            CharacterFullFrameTotalRead(value: 97, digitCount: 2),
        ]))
    }

    @Test("Only exact, bounded, non-padded ASCII totals resolve")
    func grammarAndRange() {
        for text in [
            "total", "total:", "total: 9O", "total: 097", "total: -1", "total: 126",
            "Base total: 97", "total: 97 points",
        ] {
            #expect(CharacterFullFrameTotalResolver.resolve(observations: [
                observation(text, totalRect),
            ]) == (text == "Base total: 97"
                ? .unavailable
                : .contaminated(credibleReads: [])), Comment(rawValue: text))
        }
    }

    private let totalRect = NormalizedRect(
        x: 0.8079,
        y: 0.3213,
        width: 0.1527,
        height: 0.0135
    )

    private func splitRow(_ value: Int, confidence: Double = 1) -> [OCRTextObservation] {
        let labelX = value >= 100 ? 0.794 : 0.808
        let digitsX = labelX + 0.103
        return [
            observation("total:", rect(labelX, 0.320, 0.103, 0.014), confidence: confidence),
            observation(
                String(value), rect(digitsX, 0.320, 0.956 - digitsX, 0.014),
                confidence: confidence
            ),
        ]
    }

    private func observation(
        _ text: String,
        _ rect: NormalizedRect,
        confidence: Double = 1
    ) -> OCRTextObservation {
        OCRTextObservation(text: text, rect: rect, confidence: confidence)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double)
        -> NormalizedRect
    {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}
