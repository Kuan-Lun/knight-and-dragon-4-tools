# iPhone Mirroring zoom-level sweep, 2026-09-20

Source failure: `logs/auto-level-20260920-133419.Sr2aV5` stopped with
`uncertainStateExceededGrace(unknown)` after 13 seconds at a 211×468 window
(顯示方式 > 縮小 to the smallest level), while `logs/auto-level-20260920-115149.t4mCqs`
had completed 13 cycles at 400×878 earlier the same day. Battle footer similarity in
the failing run was 0.48 (skip) and 0.42 (all-auto) against the 0.94 floor.

## Cause

iPhone Mirroring keeps a fixed-point border around the phone content: 38 points above,
8 below and 7.5 on each side (7 pixel columns at 1x, 15 at 2x). Zooming scales only the
content, so at every level except 406×890 the calibrated normalized regions no longer
cover the controls. Zoom levels on this display (1x): 211×468, 250×553, 289×637,
328×722, 367×806, 406×890, 439×960. `MirrorContentLayout` now detects the border and
places the content on a reference-proportioned canvas before recognition; inputs map
canvas targets back to the captured window.

## Captures

All captures are read-only `mirror-probe capture` outputs through the packaged App
(0.4.36), taken with `Scripts/zoom-sweep-capture.zsh` or the equivalent per-level
procedure, copied byte-for-byte into `Tests/MirrorProbeCoreTests/Fixtures/`.
`captures.json` records each fixture's source capture name, timestamp, window
geometry, dimensions and SHA-256.

- `zoom-loot-result-*.png` (7): one selected-repeat loot result page at every level.
- `zoom-battle-modal-*.png` (3): one single-button dialog during a dungeon floor at the
  smallest, a middle and the largest level. The footer beneath is dimmed by the dialog
  overlay (mean luminance 107 versus 189), so these never contribute template pixels.
- `zoom-battle-*.png` (6): battle pages at every level except 406×890, one per cycle: the
  runner (`--max-cycles 2`) was stopped by STOP file at its first battle observation, the
  window zoomed through the View menu, one capture taken, and the window returned to
  406×890 before the next cycle. Battles last 8–28 seconds, so a full sweep per battle
  was not possible.

- `zoom-experience-result-*.png` (7): the experience result page at every level. The first
  live run of the rebuilt App at 211×468 stopped on this page with `experienceHeader` at
  0.844 (successTitle 0.994, repeatOption 0.980); the page persisted, so a full sweep was
  taken before any further input.

Pages behind the post-battle dialog were probed six times by pressing the dialog button
with `mirror-probe click` after stopping the runner; every cycle succeeded and landed on
the loot result page already covered above. No failure result page was captured at a zoom
level other than 406×890, so `failureTitle` keeps only its reference-size template.

## Templates

`Scripts/generate-result-visual-templates.py` adds `successTitle`, `lootHeader` and
`repeatOption` samples from the 211, 250, 289 and 328 loot captures and `experienceHeader`
samples from the same four experience captures;
`Scripts/generate-battle-visual-templates.py` adds all four footer controls from the
211–367 battle captures. Zoom sources are placed on the reference canvas
(`Scripts/mirror_content_layout.py`) before sampling; earlier sources stay raw so their
sample bytes are unchanged. The 0.94 floor and all regions are unchanged.

Before the new samples, canvas similarity was: loot page successTitle 0.906/0.930/0.951
and lootHeader 0.883/0.905/0.937 at 211/250/289; battle skip 0.736/0.858/0.878/0.914/
0.9x at 211/250/289/328/367. 439×960 matched the reference templates alone for both pages
and is held out from calibration.

## Validation

Live: `logs/auto-level-20260920-145016.EZnRXy`, the packaged 0.4.37 (60) App at a
211×468 window, completed 3 cycles with 11 actions in 57 seconds
(`maximumCyclesReached`), recognizing loot result, two-button and one-button dialogs
and battle pages on the 204×445 canvas. The first advance click was not acknowledged
and the existing retry posted it again 11 seconds later; the remaining ten actions were
acknowledged on the next capture. Earlier the same day the 0.4.36 App at the same size
stopped after 13 seconds without recognizing any page.

Offline:
See `docs/testing.md` (zoom-level captures) and the regression suites
`ZoomLevelResultRegressionTests`, `ZoomLevelBattleRegressionTests`,
`ZoomLevelModalRegressionTests`, `MirrorContentLayoutTests` and
`MirrorContentLayoutRuntimeTests`.
