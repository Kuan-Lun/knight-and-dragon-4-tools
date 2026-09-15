# Auto-level 0.4.20: brown separator mistaken for a partial repeat stamp

Source: `logs/auto-level-20260910-003956.qxapyQ/run-report.json`. The run stopped
at 00:56:00 Asia/Taipei on September 10 after 963.594 seconds, 46 result cycles,
and 213 posted actions. Repeat-selection request 214 was rejected during its
first confirmation and never posted. `accessibilityRequestAccepted` reports
successful acceptance of a focus request; it was not the classification error.

Capture 739 correctly showed an unselected failure result. The confirmation,
capture 740 (`final.png`), showed the same result 0.581 seconds later. Both OCR
analyses recognized the failure title and repeat row at confidence 1. The old
stamp detector counted seven brown separator pixels in the first image and nine
in the second, among 8,968 samples. Nine samples yield 0.001003568, just above
0.4.19's absence cutoff of 0.001; it returned `unknown` with a low-confidence
stamp marker. The old preflight recovery covered only success advances and
accepted only empty or entirely low-confidence evidence, so this repeat request
had no chance to obtain a fresh valid confirmation.

The detector now requires red dominance relative to both green and blue:
`red - green >= 2 * (green - blue)`, in addition to its existing color, opacity
and ratio bounds. This excludes the brown background rule without increasing
the 0.1% absence or 4% presence thresholds. Both new incident frames now have
zero matching pixels. `stamp-color-corpus.tsv` records path, old count, refined
count, sample count, and minimum inner-stamp chroma ratio for 70 saved frames.
The 63 frames above the old selection threshold remain above it (minimum new
ratio 0.106824), while all seven unselected frames yield zero matching pixels.

Unknown preflight recovery now covers repeat selection and failure advances as
well as success advances, accepting only benign result evidence without actions
or adverse markers. It retries the same unposted request with the original
deadline and the shared three-attempt focus budget. No unknown frame authorizes
input, consumes a posted repeat attempt, or resets the cycle count. Restored
states and targets must pass normal validation and preserve any original page
identity. A delayed selected state cancels the repeat request without posting.
Diagnostics now include the classification evidence that rejected confirmation.

The captured pair and original offline OCR are retained in the test fixtures.
Validation totals, packaged offline replay and permission checks are recorded
in `validation.json`. No live automatic game input or long-duration soak was run.
