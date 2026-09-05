import Testing
@testable import MirrorProbeCore

@Suite("Focused character total resolver")
struct CharacterFocusedTotalResolverTests {
    @Test("Merged and adjacent split Vision rows resolve identically")
    func mergedAndSplitRows() {
        let expected = CharacterFocusedTotalRead(value: 60, digitCount: 2)
        let merged = [observation("total: 60", rect(0.808, 0.320, 0.153, 0.014))]
        let split = [
            observation("total:", rect(0.8084, 0.320, 0.1031, 0.0134)),
            observation("60", rect(0.9115, 0.320, 0.0442, 0.0134)),
        ]

        #expect(CharacterFocusedTotalResolver.resolve(observations: merged) == expected)
        #expect(CharacterFocusedTotalResolver.resolve(observations: split) == expected)
    }

    @Test("A three-digit split row preserves the digit boundary")
    func threeDigitSplitRow() {
        let split = [
            observation("total:", rect(0.794, 0.320, 0.103, 0.0134)),
            observation("100", rect(0.897, 0.320, 0.059, 0.0134)),
        ]

        #expect(CharacterFocusedTotalResolver.resolve(observations: split)
            == CharacterFocusedTotalRead(value: 100, digitCount: 3))
    }

    @Test("Focused observations outside the measured total row are ignored")
    func unrelatedRowsAreIgnored() {
        let observations = [
            observation("I 2521# CUT +10%", rect(0.72, 0.282, 0.255, 0.016)),
            observation("total:", rect(0.8084, 0.320, 0.1031, 0.0134)),
            observation("60", rect(0.9115, 0.320, 0.0442, 0.0134)),
        ]

        #expect(CharacterFocusedTotalResolver.resolve(observations: observations)
            == CharacterFocusedTotalRead(value: 60, digitCount: 2))
    }

    @Test("Low confidence, gaps, vertical splits, and extra row text fail closed")
    func unsafeGeometryAndConfidence() {
        let variants = [
            [observation("total: 60", rect(0.808, 0.320, 0.153, 0.014), confidence: 0.49)],
            [
                observation("total:", rect(0.808, 0.320, 0.080, 0.013)),
                observation("60", rect(0.930, 0.320, 0.026, 0.013)),
            ],
            [
                observation("total:", rect(0.808, 0.310, 0.103, 0.013)),
                observation("60", rect(0.911, 0.333, 0.044, 0.013)),
            ],
            [
                observation("total:", rect(0.808, 0.320, 0.103, 0.013)),
                observation("60", rect(0.911, 0.320, 0.030, 0.013)),
                observation("x", rect(0.942, 0.320, 0.014, 0.013)),
            ],
        ]

        for observations in variants {
            #expect(CharacterFocusedTotalResolver.resolve(observations: observations) == nil)
        }
    }

    @Test("Only exact, in-range, non-padded ASCII totals are accepted")
    func grammarAndRange() {
        for text in ["total:", "total: 6O", "total: 060", "total: -1", "total: 126"] {
            #expect(CharacterFocusedTotalResolver.resolve(observations: [
                observation(text, rect(0.808, 0.320, 0.153, 0.014)),
            ]) == nil, Comment(rawValue: text))
        }
    }

    @Test("Contaminated crops retain credible merged or split keeper reads as veto evidence")
    func contaminatedKeeperEvidence() {
        let mergedWithExtra = [
            observation("total: 97", rect(0.808, 0.320, 0.148, 0.014)),
            observation("x", rect(0.956, 0.320, 0.010, 0.014)),
        ]
        let splitWithExtra = [
            observation("total:", rect(0.794, 0.320, 0.103, 0.0134)),
            observation("97", rect(0.897, 0.320, 0.059, 0.0134)),
            observation("x", rect(0.956, 0.320, 0.010, 0.0134)),
        ]
        let expected = CharacterFocusedTotalResolution.contaminated(credibleReads: [
            CharacterFocusedTotalRead(value: 97, digitCount: 2),
        ])

        #expect(CharacterFocusedTotalResolver.resolveEvidence(
            observations: mergedWithExtra
        ) == expected)
        #expect(CharacterFocusedTotalResolver.resolveEvidence(
            observations: splitWithExtra
        ) == expected)
        #expect(CharacterFocusedTotalResolver.resolve(observations: mergedWithExtra) == nil)
    }

    @Test("A malformed or weak focused row is contaminated rather than absent")
    func malformedRowIsContaminated() {
        for row in [
            [observation("total: 9O", rect(0.808, 0.320, 0.153, 0.014))],
            [observation(
                "total: 97",
                rect(0.808, 0.320, 0.153, 0.014),
                confidence: 0.49
            )],
        ] {
            #expect(CharacterFocusedTotalResolver.resolveEvidence(observations: row)
                == .contaminated(credibleReads: []))
        }
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
