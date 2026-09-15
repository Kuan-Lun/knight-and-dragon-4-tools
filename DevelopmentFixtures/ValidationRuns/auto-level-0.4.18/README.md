# Auto-level 0.4.18: transient result-title occlusion

Source: `logs/auto-level-20260909-181123.B5Jt4k/run-report.json`, stopped at
18:16:22 Asia/Taipei on 2026-09-09 after 15 cycles and 66 posted inputs.
`source-run-tail.json` preserves the final events and capture references.

Capture 229 showed the selected EXP result page. Capture 230, taken 0.559 seconds
later for request 67's preflight, still showed that page but had a black floating
pill covering the completion title. Offline OCR read only `任` at confidence 0.30
instead of `任務完成！`; the classifier correctly produced `unknown` and no action.
Request 67 was never posted. The origin of the floating overlay is not established.
The `accessibilityRequestAccepted` diagnostic was an accepted focus request, not
the classification failure. The issuing observation was only 0.140 seconds old,
with 0.122 seconds of recognition processing, so this incident is distinct from
the stale-observation expiry addressed by 0.4.17.

The exact PNGs and offline analysis reports are retained under
`DevelopmentFixtures/ClassifierReplaySources/result-title-occlusion-20260909/`.
The classifier remains unchanged in this version. A success-advance preflight
that becomes unknown without actions or adverse evidence can now repeat complete
preflight with the same request, original EXP/loot identity, target, and deadline.
It shares the existing three-attempt budget with focus contention; an unknown
frame never authorizes input, renews the deadline, or consumes a posted retry.

Validation results are recorded in `validation.json`. Fixture tests verify actual
red-stamp pixels and original OCR, unknown-frame rejection, shared retry bounds,
single posting of the original request after simulated restoration, and deadline
expiry. No live automatic game input or long-duration recovery run was performed.
