# Character reroll development evidence

These files are durable calibration and OCR-replay evidence for the custom-character reroller.
They are intentionally separate from the repository-root `captures/` runtime-output directory.

- `total-69.png` and `total-69-ocr.json` are the source frame/report for the checked-in
  `character-reroll-live.json` OCR fixture.
- `total-76.png` and `total-76-ocr.json` preserve the frame where full-frame Vision omitted one
  red stat value. They demonstrate why stats are not part of the reroll decision.
- `total-73-glyph.png` is the 406 x 890 source frame used to calibrate the rendered two-digit
  component mask in `CharacterTotalDigitDetectorTests`.
- `total-97-full-reads-91.png` and its OCR report preserve the live frame where full-frame Vision
  read the rendered `97` as `91` at confidence 0.30 while focused Vision read `97` at confidence
  1.00. The raw detector independently counted two glyphs. Both OCR reads are safely on the
  `>= 90` side even though their individual digits differ; the same fixture also proves that the
  value remains on the two-digit side of a 100 boundary.
- `total-81-split-full-frame.png` is the unchanged terminal image from reroll 165 of
  `character-reroll-20260906-193447.6CuPgN`. Its adjacent OCR report reproduces the full-frame
  split into `total：` and `81`, both at confidence 1.00. Their boxes overlap by 0.0049873 of
  the frame width, within the former focused-row tolerance of 0.005. The test fixture
  `character-reroll-split-total-live.json` preserves those full-frame observations and a separate
  focused Vision revision 3 replay (`en-US`, accurate, language correction off, ROI
  x=0.72/y=0.64/width=0.27/height=0.08 in Vision coordinates). Focused OCR also reads `81` at
  confidence 1.00; the rendered pixel detector independently counts two digits. The PNG SHA-256
  is `443d8c1a3d7eb2a0a4667fe7e2a784ff43091c0c0c2f4b633dc52dbf920d569f`.
- `total-84-split-full-frame.png` is the unchanged terminal image from reroll 49 of
  `character-reroll-20260906-195446.DZMJIb`. Its adjacent OCR report reproduces the full-frame
  split into `total：` and `84`, both at confidence 1.00. Their boxes overlap by 0.00500316088
  of the frame width (2.03128 pixels at 406 pixels), just beyond the former 0.005 cutoff.
  This tiny variation from the total 81 frame exposes why the split-row overlap allowance
  needs a calibrated pixel margin. Both OCR resolvers now share a 2.5-pixel overlap allowance
  at the 406-pixel reference width. The `character-reroll-split-total-84-live.json` fixture
  preserves the complete observations plus a focused Vision replay using the same settings
  documented above; focused OCR reads the merged `total: 84` at confidence 1.00. The rendered
  pixel detector independently counts two digits. The PNG SHA-256 is
  `75d8b7cea2c6d6f8077c44d2731504f7b2bc9eed2b3759c9c55abea7bd94deda`.

Four read-only captures of the `total: 73` page were taken several seconds apart during the
2026-09-05 calibration. Their PNG SHA-256 values were identical:
`476e4c5f24a9a424300caa601e33c6537865383bc599b768416aa9af95bb8b9a`.
Only one copy is retained because the other three contained no additional evidence.

The raw OCR reports retain their historical `source.capturedImagePath` values. The adjacent renamed
PNG is tied to each report by the unchanged `image.pngSHA256` value.

## Pixel-guard rejection, September 10, 2026

`total-67-pixel-guard.png` is the unmodified terminal image from
`logs/character-reroll-20260910-230308.YX8fMX/final-candidate.png` (SHA-256
`cff32411928ef2f829c1502b24c6bfe24b4afd99825cf41d3577d99d6bdbf957`). The run
posted 33 rerolls before the final pixel guard cancelled the next click. The page shows Jennie,
total 67. `total-67-pixel-guard-ocr.json` is a read-only Apple Vision replay of that image.
`total-67-pixel-guard-focused-ocr.json` records an independent focused Vision revision 3 replay
using the runtime ROI and source-image coordinate conversion. Its `total:` and `67` fragments
both have confidence 1.00; the full-frame resolver, focused resolver, and rendered two-glyph
check agree on below-threshold evidence.
The old input region started at normalized y=0.08; the replay's clock box extends to about
y=0.081, confirming the intended status-bar exclusion was incomplete. No before image was
retained, so this fixture cannot establish the actual temporal difference that ended the run.
