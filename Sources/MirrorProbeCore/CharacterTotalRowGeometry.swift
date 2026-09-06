/// Shared spacing limits for full-frame and focused OCR fragments of the calibrated total row.
enum CharacterTotalRowGeometry {
    static func allowsAdjacentGap(_ gap: Double) -> Bool {
        gap.isFinite && gap >= -maximumOverlap && gap <= 0.03
    }

    // Live 81 and 84 rows have about two pixels of label/number box overlap at the 406-pixel
    // reference width. Allow half a reference pixel of variation in Vision's fitted boxes.
    // The old normalized limit 0.005 was only 2.03 pixels and rejected 84 at 2.031283 pixels.
    // Normalizing this allowance preserves it when the mirror is proportionally scaled.
    private static let maximumOverlap = (2.0 + 0.5) / 406.0
}
