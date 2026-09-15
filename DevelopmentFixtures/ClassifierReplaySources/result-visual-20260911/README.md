# Result-page visual recognition corpus

This corpus records the actual pixels used to validate the transition from OCR-gated result-page recognition to fixed-region visual matching. Expected labels were checked against the displayed PNGs, independently of their legacy OCR classifications. All images retain their native pixels; no rescaling, cropping, sharpening or synthetic text was applied to these fixtures.

`manifest.json` lists 21 captures with their repository source paths, expected result state, expected content page and action intent, native dimensions, and SHA-256. Existing PNGs in the test bundle are reused. The native 406×890 and 812×1780 images have the same normalized layout, while party names, experience values, loot lists, status-bar contents and some text rasterization differ.

The five PNGs stored in this directory are copies of the newest relevant source captures:

| File | Original capture | Verified content |
| --- | --- | --- |
| `experience.png` | `logs/auto-level-20260911-052556.F6y52z/diagnostics/capture-0028.png` | Success EXP page with repeat selected, immediately before the result advance |
| `loot-after.png` | `logs/auto-level-20260911-052556.F6y52z/diagnostics/capture-0029.png` | Success loot page after that advance; the action did change pages |
| `loot-final.png` | `logs/auto-level-20260911-052556.F6y52z/final.png` | Same selected loot page when the run stopped |
| `live-loot.png` | `logs/result-visual-live-source.png` | Independently captured selected loot page, with another loot list |
| `live-unselected-loot.png` | `logs/result-visual-0.4.23-live.png` | User-parked unselected loot page; old stamp region included first item-row text |

The regression tests decode the original PNGs directly to RGBA and call `VisualResultDetector.classifyRGBA` without supplying any OCR observations. They verify state, page identity, action intent, trustworthy visual evidence, and repeat-selection proof for unselected pages. The actual EXP→loot pair also exercises controller acknowledgement, cycle counting and rejection of the stale EXP request.

Six negative images cover a title obscured by a floating status pill, a skill-acquired modal over an EXP result, collection and recruitment modals over loot results, an active battle, and a returned-party modal on the map. Modal underlays preserve the result title, page header and SELECTED stamp while darkening them. The detector must reject these as actionable result pages; normalized similarity that ignores brightness entirely would be insufficient.

The template calibration and regression corpus overlap, so these examples demonstrate regression coverage rather than an independent accuracy estimate. The bounded corpus includes the newly verified unselected loot result but does not include a native 2× failure result. No live input events or long-running automation are part of these tests.
