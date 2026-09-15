# Auto-level 0.4.26: changing border above battle footer glyphs

The source run, `logs/auto-level-20260913-000136.Q2CoDs`, ran from 00:01:36 to
00:24:11 on September 13, 2026, Asia/Taipei (1,354.2 seconds), completing 60 cycles
and posting 296 actions. Nine consecutive unknown observations ended the session
with `uncertainStateExceededGrace(unknown)`. The original report's terminal events
are retained in `incident.json`; `before-fix-final-image.json` reproduces the failure
using the original packaged executable without posting input.

The final native 812×1780 image visibly contains a battle and normal Pause/Retreat
controls. Skip and All-auto matched only 0.89873 and 0.92211 against the 0.94 minimum,
while Pause and Retreat matched 0.99824 and 0.99809. The glyphs had not shifted:
quarter-logical-pixel registration probes found no improvement. The changing pixels
were concentrated in the first three native rows at the old footer regions' upper
edge, above the glyph bodies.

Both footer regions now begin at normalized y=0.870 instead of 0.867. Their lower
edges remain 0.893 (Skip) and 0.891 (All-auto). This excludes the changing edge even
at the matcher's one-logical-pixel upward registration offset. Templates were
regenerated from the same original 1× and 2× sources. No incident image was used as
a template. Thresholds, registration tolerance, modal priority, normal-pause proof,
retreat target, progress requirements, and uncertainty deadlines are unchanged.

`BattleFooterVariantRegressionTests.swift` replays all eight retained capture
positions with their recorded times and verifies native PNG hashes. Six unique PNGs
are stored once each, with repeated frames referenced by the sequence manifest.
The tests verify battle recognition, waiting with explicit in-progress runtime
metadata, masked/dimmed footer rejection, missing-pause rejection, independent
retreat evidence, discarded-edge invariance, and temporal stall authorization.
The explicit runtime facts in the controller replay are not inferred from stills.

The existing 566 Swift tests, five new Swift tests (including parameterized
negative cases), and 12 isolated launcher cases pass. Packaged saved-image replay,
release build, signature, dry-run, and permission results are in `validation.json`.
All eight packaged replays classify as battle; the final Skip/All-auto scores are
0.99840/0.99797. The rebuilt app's Launch Services `doctor` reports both Screen
Recording and Accessibility/post-event permission missing. Renew those permissions
for `.build/Mirror Probe.app` before starting another live session.
No live auto-level run or game input is part of this validation. The incident was
replayed offline; uninterrupted eight-hour operation has not been established.
