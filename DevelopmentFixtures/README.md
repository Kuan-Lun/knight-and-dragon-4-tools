# Development fixtures

This directory contains durable development evidence. It is not runtime output and must not be
deleted when cleaning logs or captures.

- `ButtonGeometryCorpus/` contains the 168-image regression corpus used by
  `Scripts/button-geometry-probe.swift`. The nested `captures/` component preserves each image's
  historical source path; it is not a disposable runtime directory.
- `ClassifierReplaySources/` contains source-report/source-image pairs retained for classifier
  provenance, OCR replay, and newly observed regression cases. The active-battle control-grid
  pair preserves the 2026-09-05 case where Vision lost both the title and `戰利品` prefix while
  the four battle controls remained stable.
- `CharacterReroll/` contains the compact source frames and OCR reports used to calibrate and
  replay the custom-character `total >= 100` detector.
- `PendingRegressions/` contains newly observed failures that have not yet been promoted into the
  passing automated suite.
- `ValidationRuns/` contains compact reports from milestone runtime/retention checks. Large frame
  sequences and ordinary stdout/stderr logs are intentionally not kept here.

Disposable program output belongs in the repository-root `logs/` and `captures/` directories.
