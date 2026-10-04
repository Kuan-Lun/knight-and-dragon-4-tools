# Posted retreat followed by mission success, 2026-10-04

Source run: `logs/auto-level-restart-i7oqh4ar/attempt-001`, session
`20261004-221919-96101b11`, a 211×468 window (recognition canvas 204×445).
The run stopped after 57 counted cycles and 271 posted actions with
`unexpectedTransition(requestRetreat, battle, missionCompleteRepeatSelected)`.

Event 772 confirmed a frozen battle after verified progress: 5.447 seconds and 12
dense samples. Captures 1049–1052 have the same full-frame fingerprint; the last
preflight at 1493.945 seconds still shows the battle HUD. Event 774 records retreat
request 270 being posted. Capture 1053 at 1495.350 seconds is the success EXP page
with the repeat option already selected. The success title scored 0.9939, the EXP
header 0.9742, and the repeat option 0.9800. The captures establish the observed
transition, not whether the retreat tap caused the game to advance.

The controller allowed a posted retreat to reach either failure result directly,
but rejected both success result states. It now accepts all four mission result
states for a posted retreat originating in a battle or battle-recognition recovery.
The original posting, fingerprint, deadline, window, freshness, and run-limit
guards remain in place. A result clears the pending retreat without granting
retreat-confirmation authorization and follows normal one-time cycle accounting.

`capture-1052.png` and `final.png` are copied byte-for-byte to the Core test
fixtures `retreat-direct-success-before.png` and `retreat-direct-success-final.png`.
`retreat-direct-success-sequence.json` records their capture times, fingerprints,
dimensions, and PNG hashes. `RetreatDirectResultRegressionTests` classifies those
actual canvases and replays the transition, checking that success is counted once,
stale observations cannot post another action, and the next fresh request advances
the selected success page without toggling repeat. Stall metadata and the exact
posting time are supplied by the replay as documented in the manifest; the pair
of images alone does not establish temporal stall evidence or live input delivery.
