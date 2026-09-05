# Battle event: monster defeated

Observed in Mirror Probe 0.3.12 (build 15) during session
`20260904-050231-e1ce7b0f` after seven completed cycles.

- `before-prompt.png`: the boss has reached zero HP.
- `prompt.png`: one-button battle event reading `魔怪被擊敗了…` with the unique `關閉` control.
- `analysis.json`: offline OCR/classification replay. OCR found the narrative and close control,
  but the classifier returned `unknown` because the phrase did not match the narrower event-text
  variants and the fallback battle-background fingerprint was incomplete.
- `context/`: all seven recent frames retained immediately before the final prompt.
- `run-report.json`: the original schema-version 3 automation report.

Expected eventual behavior is `battleEventPrompt` with exactly one `closeBattlePrompt` action.
Until a narrowly tested classifier change is made, this remains a pending (not passing) fixture.
