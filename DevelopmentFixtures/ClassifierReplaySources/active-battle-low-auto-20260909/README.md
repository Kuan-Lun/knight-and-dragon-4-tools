# Battle stopped after auto-button OCR confidence dropped

Source run: `logs/auto-level-20260909-001142.R5kF6M`, 2026-09-09 Asia/Taipei.
After 13 completed cycles and 61 inputs, captures 180–186 were classified as `unknown`.
At elapsed 335.915 seconds the controller stopped with `uncertainStateExceededGrace(unknown)`.

`final.png` is the retained original frame. `final-analysis-before.json` is its offline Vision
revision 3 replay before the fix, including the encoded PNG SHA-256. The test fixture
`Tests/MirrorProbeCoreTests/Fixtures/active-battle-low-auto-sequence.json` records OCR from all
eight retained frames (179–186), their image hashes, and their original classifications.

The decorative title reads `第3場戰門` rather than `第3場戰鬥`, and no round label is present.
The stable anchors are `戰利品` 1.0, `暫停` 1.0, `撤退` 0.5, and `跳過` 1.0.
`全部自動` drops from 1.0 on capture 179 to 0.5 on all seven following frames, below the 0.6
floor required by the existing fallback. This prevents corroboration of the battle layout;
the low-confidence battle controls then produce `unknown`. Extending the grace period would
only delay the stop because the OCR result remains the same on the stationary frame.

The fix accepts auto confidence >= 0.5 for classification only when all five anchors are unique,
trusted at their individual floors, and in the measured layout. Retreat must still meet its
normal 0.5 target floor; this cannot combine with the separate low-retreat exception.
The auto click floor remains 0.6, and retreat remains subject to temporal recovery authorization.
The test replays the sequence beyond the uncertainty grace period with zero actions issued,
and rejects missing, duplicated, misplaced, low-confidence, or conflicting anchors.
