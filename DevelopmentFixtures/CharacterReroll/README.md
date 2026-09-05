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

Four read-only captures of the `total: 73` page were taken several seconds apart during the
2026-09-05 calibration. Their PNG SHA-256 values were identical:
`476e4c5f24a9a424300caa601e33c6537865383bc599b768416aa9af95bb8b9a`.
Only one copy is retained because the other three contained no additional evidence.

The raw OCR reports retain their historical `source.capturedImagePath` values. The adjacent renamed
PNG is tied to each report by the unchanged `image.pngSHA256` value.
