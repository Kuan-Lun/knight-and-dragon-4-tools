# Intact result titles with weak full-frame OCR, 2026-09-11

These PNGs are unchanged saved captures from two user-started runs. They show an
intact `任務完成！` title, the result-page header, and a red SELECTED stamp. Unlike
the 2026-09-09 title-occlusion fixture, no floating black pill covers the title.

| Fixture | Original run / file | Capture elapsed | PNG SHA-256 |
| --- | --- | --- | --- |
| `startup` | `auto-level-20260911-051405.MSkXSb/final.png` | 15.765833416720852 s | `1a12308ad0e2c1f3b59e73b4e7e152434c322c6d6abe8835dcbfba0d2861abe5` |
| `experience` | `auto-level-20260911-051602.awbevq/diagnostics/capture-0019.png` | 22.957955749938264 s | `1af0059233c5b2885d1b672591030af86a08e94fa32a763db8924c5e3e614cd4` |
| `loot-after` | `auto-level-20260911-051602.awbevq/diagnostics/capture-0020.png` | 24.25756858312525 s | `368211cc89f68e7a65f5a05bf723ef0d596417388c86c1373a3c530fbdcd2f4f` |
| `loot-final` | `auto-level-20260911-051602.awbevq/final.png` | 36.06088054156862 s | `e3adcdce20cdec79823310b4353af811e132a79e4b0a265b6bcf66edd5075f4c` |

All original paths are beneath this repository's `logs/` directory. The first
run posted no actions and ended with `uncertainStateExceededGrace(.unknown)`.
The second run completed one cycle and posted five actions. Its fifth action was
the selected EXP page's upper-left continuation arrow. The before/after captures
show that this click succeeded: the header changes from `獲得經驗值` to
`獲得拾得物`, and the body changes from party EXP rows to loot items. The visible
SELECTED stamp persists. The failure is the missing semantic acknowledgement of
this page transition, not a missing click or an unselected repeat option.

Each `*-analysis.json` is the original packaged 0.4.21 app's read-only
`analyze-file` output. The EXP title has confidence 1 and its page classifies as
`missionCompleteRepeatSelected`. The other three titles have confidence 0.5,
below the unchanged ordinary confidence floor. Their classifications are
`unknown`, with one `lowConfidenceMarker` and no actions. The second run's pending
EXP advance therefore could not acknowledge the loot page and eventually ended
with `actionDidNotAdvance(.advanceMissionSuccess)` at the existing 12-second
posted-action timeout.

The `*-focused.json` files preserve actual Apple Vision accurate, revision 3
recognition from those same saved PNGs, with `zh-Hant` / `en-US`, language
correction disabled, and the measured title region `(0.25, 0.07, 0.50, 0.08)`.
Observation rectangles use normalized full-frame coordinates with a top-left
origin. Each focused pass independently recognizes the same full title at
confidence 1. No synthetic confidence values, live captures, or game input events
were used to create these reports.

`LowResultTitleSequenceRegressionTests.swift` bundles identical PNGs and JSON
files under the `low-result-title-` prefix. It verifies PNG hashes and dimensions,
runs the stamp detector on the actual saved pixels, and replays both original OCR
and focused refinement. The original sequences still reproduce the two stop
reasons. Refined startup permits one loot continuation without toggling the
selected repeat option. Refined EXP-to-loot recognition acknowledges the posted
EXP request and issues a fresh loot request, retaining a single completed cycle.
These controller tests use normalized test clocks with the same 12-second action
timeout and 15-second / 8-observation uncertainty limits; they are offline replay
checks, not a new live automation run.
