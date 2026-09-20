# Unacknowledged stalled-battle retreat, 2026-09-20

Source run: `logs/auto-level-20260920-165503.92enHa`, a 211×468 window (recognition canvas
204×445), 26 cycles and 123 actions in 10.5 minutes before stopping with
`actionDidNotAdvance(requestRetreat)`.

The boss battle starting at 608.8 s stopped changing; the stall monitor confirmed 5.5
seconds without progress across 13 samples at 622.6 s and the runner posted the retreat at
623.9 s. The post-action capture reported `meanAbsoluteDifference=2.3e-05`, and the eight
retained captures from 623.9 s to 635.4 s have zero changed pixels between them: the game
never received the tap. The stderr log shows `focusRestorationSkipped … reason=userInputObserved`
and a foreground application other than the mirror at that moment, matching the earlier
dialog incident (`dialog-unacknowledged-20260920`): a mouse movement during the 60 ms
between the posted mouse-down and mouse-up turns the tap into a drag.

`final.png` is copied byte-for-byte to
`Tests/MirrorProbeCoreTests/Fixtures/retreat-unacknowledged-20260920-final.png`. It is the
canvas the classifier saw; all four footer controls matched at 0.98.

## Change

`AutoLevelController.retryTimedOutRetreatStep` re-posts a stalled-battle retreat, and the
retreat confirmation press, up to two more times when the same state, the same exact target
and (for the retreat) fresh stalled-defeat metadata remain after the timeout. Both repeat a
decision already made rather than making a new one; retries never issue from a stale
observation. `RetreatUnacknowledgedRegressionTests` replays the retained canvas with the
incident's timing and expects a second retreat request instead of a stop.
