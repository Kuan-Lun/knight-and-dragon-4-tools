import Testing
@testable import MirrorProbeCore

@Suite("Foreground focus fallback validation")
struct ForegroundFocusFallbackValidationTests {
    @Test("A stable AppKit candidate requires a successful live AXFrontmost true")
    func confirmsOnlyCorroboratedCandidate() {
        #expect(resolve() == 20)
        #expect(resolve(frontmostReadSucceeded: false) == nil)
        #expect(resolve(frontmostValue: .boolean(false)) == nil)
    }

    @Test("Missing and incorrectly typed AX values cannot authorize focus borrowing")
    func rejectsUnknownOrInvalidAttributeValue() {
        #expect(resolve(frontmostValue: .unavailable) == nil)
        #expect(resolve(frontmostValue: .invalidType) == nil)
    }

    @Test("Primary errors other than noValue cannot be replaced with a candidate")
    func rejectsFallbackForOtherPrimaryResults() {
        #expect(resolve(primaryReturnedNoValue: false) == nil)
    }

    @Test("Unknown candidates before or after the live AX read fail closed")
    func rejectsUnknownCandidates() {
        #expect(resolve(candidateBefore: nil) == nil)
        #expect(resolve(candidateAfter: nil) == nil)
        #expect(resolve(candidateBefore: nil, candidateAfter: nil) == nil)
    }

    @Test("Invalid identifiers never become focus or restoration destinations")
    func rejectsInvalidProcessIdentifiers() {
        for processID in [Int32(0), Int32(-1)] {
            #expect(resolve(candidateBefore: processID, candidateAfter: processID) == nil)
            #expect(resolve(candidateBefore: processID) == nil)
            #expect(resolve(candidateAfter: processID) == nil)
        }
    }

    @Test("A user-selected third application invalidates an otherwise true AX read")
    func rejectsCandidateChanges() {
        #expect(resolve(candidateBefore: 20, candidateAfter: 30) == nil)
        #expect(resolve(candidateBefore: 30, candidateAfter: 20) == nil)
    }

    private func resolve(
        primaryReturnedNoValue: Bool = true,
        candidateBefore: Int32? = 20,
        candidateAfter: Int32? = 20,
        frontmostReadSucceeded: Bool = true,
        frontmostValue: ForegroundFocusFallbackValue = .boolean(true)
    ) -> Int32? {
        ForegroundFocusFallbackValidation.confirmedProcessID(
            primaryReturnedNoValue: primaryReturnedNoValue,
            candidateBefore: candidateBefore,
            candidateAfter: candidateAfter,
            frontmostReadSucceeded: frontmostReadSucceeded,
            frontmostValue: frontmostValue
        )
    }
}
