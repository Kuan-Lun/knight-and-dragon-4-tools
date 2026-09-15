# Auto-level 0.4.29: posted retreat directly reaches failure results

The September 14 19:12:57–19:16:46 run stopped after 9 counted cycles and 45
posted actions. At event 127, runtime monitoring confirmed 5.2279 seconds of
stable battle pixels across 13 dense samples after observed battle progress.
Action 45 then pressed the measured Retreat target. The retained preflight
(capture 182) is a battle; the next retained image (183) is the unselected
`任務失敗` experience page. The controller rejected this as
`unexpectedTransition(requestRetreat, battle, missionFailed)` before counting
the next failure. `incident.json` retains the original events and capture metadata.

The images establish the observed transition, not whether the game skipped an
intermediate prompt or independently finished the battle between captures. The
packaged 0.4.28 saved-image replay already classifies the result correctly; this
fix changes controller acknowledgement, not image recognition or retreat timing.

A pending, posted Retreat originating in battle now accepts either failure-result
state within its existing acknowledgement deadline. Normal pending-action cleanup
disables retreat-confirmation authorization, and the existing result-episode logic
counts the failure once and resumes repeat selection or selected-result advance.
Unposted requests do not gain this acknowledgement. Original fingerprint, time,
window, limits, uncertainty and target checks remain effective. No global restart,
extra click, retry budget or confirmation-intent widening was added.

`RetreatDirectFailureRegressionTests` verifies both native PNG hashes, runs the
actual visual classifier, and replays posted retreat through one failure count,
fresh-observation gating and the original repeat target. Runtime stall metadata
comes from the source report; the test does not infer it from one image. Its
posting timestamp is explicitly synthetic between the retained capture times
because the report does not retain the exact mouse-event timestamp.

Controller tests cover both failure states, next-cycle continuation, the selected
latch, expired/same-frame/unposted acknowledgements, unrelated states, changed
window identity, run limits and absence of later confirmation authorization.
All 585 Swift Testing tests, two XCTest cases and 12 isolated launcher tests pass.
A separate static review found no actionable issues in the transition or replay.

No live game input is used for validation. Build, signature, packaged image replay,
launcher dry run and Launch Services permission results are recorded beside this
file in `validation.json` and the associated logs.

The packaged 0.4.29 (build 52) release passes signature verification and the
user's `--max-minutes 480 --wait` launcher dry run, retaining the 500-cycle cap.
Its saved-image replay still recognizes `missionFailed` with zero input events.
Both permissions were granted before the rebuild; after signing, Launch Services
doctor reports Screen Recording and Accessibility/post-event permission missing.
Renew those grants for `.build/Mirror Probe.app` before rerunning automation.
