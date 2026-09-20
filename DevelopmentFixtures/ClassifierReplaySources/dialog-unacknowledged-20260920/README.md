# Unacknowledged dialog press, 2026-09-20

Source run: `logs/auto-level-20260920-150737.CW2ZaR`, a 211×468 window (recognition canvas
204×445), 13 cycles and 62 actions in 5 minutes before stopping with
`actionDidNotAdvance(pressWideModalTopButton)`.

At 294.6 s the runner pressed the "探索完成 / 關閉" dialog button. The post-action capture
reported `meanAbsoluteDifference=0.0`: the game never received the tap. The stderr log shows
`focusRestorationSkipped … reason=userInputObserved` around every late action, so the user's
mouse was moving; a movement between the posted mouse-down and mouse-up (60 ms apart) turns
the tap into a drag. The controller only retried timed-out result-page actions, so after the
8 second `postActionTimeout` it stopped.

`final.png` is copied byte-for-byte to
`Tests/MirrorProbeCoreTests/Fixtures/dialog-unacknowledged-20260920-final.png`
(SHA-256 `4ed86e8e246b64791b7bd3a087a0f83fa2afc7df494bc3ccd644b34ae2ccf8b3`; report SHA-256
`81dd209ff4792e41ddb64271a022115ef1bd6056c94e58a9ff8d95cdf0734f64`). It is the canvas the
classifier saw, not the raw window capture.

## Change

`AutoLevelController.retryTimedOutWideModalPress` re-posts a dialog button up to two more
times when the same dialog layout and exact button target remain the only candidate after
the timeout. Dialog buttons only dismiss or advance a dialog, so a press the game never
received is safe to repeat; the one-shot retreat confirmation keeps no retry. Retries never
issue from a stale observation. `DialogUnacknowledgedRegressionTests` replays the retained
canvas with the incident's timing and expects a second press instead of a stop.
