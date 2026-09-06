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
  the frame width, within the existing focused-row tolerance of 0.005. The test fixture
  `character-reroll-split-total-live.json` preserves those full-frame observations and a separate
  focused Vision revision 3 replay (`en-US`, accurate, language correction off, ROI
  x=0.72/y=0.64/width=0.27/height=0.08 in Vision coordinates). Focused OCR also reads `81` at
  confidence 1.00; the rendered pixel detector independently counts two digits. The PNG SHA-256
  is `443d8c1a3d7eb2a0a4667fe7e2a784ff43091c0c0c2f4b633dc52dbf920d569f`.

Four read-only captures of the `total: 73` page were taken several seconds apart during the
2026-09-05 calibration. Their PNG SHA-256 values were identical:
`476e4c5f24a9a424300caa601e33c6537865383bc599b768416aa9af95bb8b9a`.
Only one copy is retained because the other three contained no additional evidence.

The raw OCR reports retain their historical `source.capturedImagePath` values. The adjacent renamed
PNG is tied to each report by the unchanged `image.pngSHA256` value.
