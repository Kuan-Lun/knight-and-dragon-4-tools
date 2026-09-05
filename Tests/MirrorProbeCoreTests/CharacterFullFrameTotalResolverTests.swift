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
