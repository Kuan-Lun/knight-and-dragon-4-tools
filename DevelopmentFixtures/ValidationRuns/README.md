# Validation run records

These reports are durable development evidence, not user logs.

- `ten-minute-soak-0.3.11/run-report.json` records the completed ten-minute live soak run.
- `retention-stop-0.3.12/run-report.json` records a user `STOP` run that retained zero PNG files at
  the default `error` capture level.

Only the compact reports are retained. Their historical absolute runtime paths may refer to files
that were deliberately removed from the disposable repository-root `captures/` directory.
