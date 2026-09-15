# Result title occlusion, 2026-09-09

Preserved without modification from the user-started run
`logs/auto-level-20260909-181123.B5Jt4k`, session
`20260909-181123-6857a1ba`. The run stopped on 2026-09-09 at 18:16:22 Asia/Taipei,
after 15 completed cycles and 66 posted actions. Request 67, the upper EXP-result
continuation, had not been posted when its confirmation frame became unknown.

| Saved pair | Original image | Capture | PNG SHA-256 |
| --- | --- | --- | --- |
| `before.png`, `before-analysis.json` | `diagnostics/capture-0229.png` | 229, elapsed 297.6443087917287 s | `c59bb0ded4c3c511b876a4e06843fbbe262dd48897e0dc22faaa1db502712e3a` |
| `confirmation.png`, `confirmation-analysis.json` | `final.png` | 230, elapsed 298.203643291723 s | `d155e21745f916a45b1f5e6e07c81a4c425336e82c897ac1fe068bc736b5e156` |

The analysis JSON files are the unchanged offline `analyze-file` outputs from
`/tmp/knight-dragon-0.4.18-replay/before.json` and `confirmation.json`. Both used
Apple Vision accurate recognition, revision 3, `zh-Hant`/`en-US`, without language
correction. No new live captures or input events were made to construct these fixtures.

The before image has an unobscured `任務完成！` title, an EXP header, and the red
repeat-selection stamp. Its archived measured stamp ratio is 0.10749330954504906.
The confirmation image contains a dark floating pill over the title: OCR sees only
`任` at confidence 0.30, while the EXP header and repeat row remain visible.
The confirmation must remain `unknown` with no actions; the stamp and page content
alone do not establish the complete result identity.

`ResultTitleOcclusionRegressionTests.swift` bundles exact copies of both PNGs and
analysis JSON files. It verifies the PNG hashes, runs the stamp detector on the
actual pixels, and replays the original OCR through the unchanged classifier and
result-action resolver. Controller tests use the archived classifications and the
shared foreground/result-confirmation retry budget. Preflight recovery never
feeds the unknown or restored frames back into the controller. Fresh restoration
must match the known EXP page and original target before reusing the same unposted
request exactly once; the original 12-second posting deadline remains unchanged. Restoration is a
simulated return of the unobscured pixels, not a claimed additional live capture.
