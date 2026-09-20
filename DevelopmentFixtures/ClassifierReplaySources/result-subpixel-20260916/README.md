# Native 404×874 recognition at subpixel registration offsets

Source: `logs/auto-level-20260916-030418.5d1gmr/final.png`, from the run
started at 2026-09-16 03:04:18 Asia/Taipei. The original 404×874 PNG is retained
byte-for-byte as `Tests/MirrorProbeCoreTests/Fixtures/visual-result-failure-404x874.png`.
Its SHA-256 is `dca2172b97116663eb99c37dbe59c27fba26c3c9e75d47cea7f81457c6135c3c`.

The visible page is an unselected-repeat mission failure EXP result. The run
posted zero actions, counted zero cycles, and stopped after 13.014 seconds with
`uncertainStateExceededGrace(kind: MirrorProbeCore.AutoLevelUncertainKind.unknown)`.
All nine observations had the same RGBA fingerprint
`a4a06eb6e3f59ea986094bc366bd0e2f2e09d7dd159c3b8f541d6ac0b9f8628a`.
PNG hashes and decoded-frame fingerprints are different identifiers.

The integer-only registration grid missed intact glyphs between reference pixel
centers. Read-only production replay of the original PNG measured:

| Marker | Integer offsets | Including half-pixel offsets |
| --- | ---: | ---: |
| Failure title | 0.94528 | 0.95958 |
| EXP header | 0.91100 | 0.96091 |
| Repeat option | 0.89458 | 0.96154 |

The shared matcher now samples quarter-pixel positions inside its existing
one-reference-pixel radius. The 0.94 similarity floor, template bytes, required
anchors, brightness/alpha checks, and action coordinates are unchanged. Both
result and battle callers use this matcher, so their existing negative corpora
remain part of validation.

The new fixture tests exercise visual classification, screenshot-derived repeat
target bounds, and the controller's failed-cycle/repeat request. In-memory dimming
and anchor occlusion must still reject input. The PNG is a regression holdout
from the existing template calibration sources; no new template was trained on
it. This verifies saved-frame behavior, not a live eight-hour game session.

## Related live battle capture

After the user reenabled permissions, a read-only live analysis at 03:14 found
the same 404×874 geometry's battle footer but could not confirm retreat. This is
a separate live capture, not an additional frame from the original failed run.
`visual-battle-404x874.png` retains its original pixels and has SHA-256
`eb49a7ab620b134b3867eec9ad45810bd21e34a6de39d816e1c5431848045097`.
The half-pixel grid was insufficient here; quarter-pixel registration confirms
retreat at 0.95091 using existing templates. Pause remains below the threshold
and is optional diagnostic evidence. The two footer controls and retreat permit
temporal battle monitoring; they do not authorize an immediate retreat.

The subsequent 03:15 read-only capture shows a one-button battle-event dialog.
It is retained as `visual-battle-modal-404x874.png` with SHA-256
`40de45701dac83228984b0cef2fa607611f7a45747aa2b08fd5d3eed968252ff`.
Tests require the dialog to retain priority over its dimmed battle background.
Both PNGs are under `Tests/MirrorProbeCoreTests/Fixtures/`. The shared matcher's
search radius and action targets remain unchanged by the finer sampling grid.

## Validation

The final `zsh Scripts/test.sh` passed 675 Swift Testing tests (638 Core and 37
Runtime), 2 XCTest cases, 55 auto-level launcher cases, 84 reroll launcher cases,
15 restart-supervisor tests, release compilation, and 18 offline CLI tests.
The packaged App also passed all 18 CLI tests, signature verification, the
original launcher's dry run, and all three retained-image replays. Its final
Launch Services permission check at 03:20:08 reported both screen capture and
post-event access granted.

`validation.json` retains the final offline checks, packaged executable identity,
read-only replays, and permission check. No game input was posted during this
investigation and no long-running game session was started.
