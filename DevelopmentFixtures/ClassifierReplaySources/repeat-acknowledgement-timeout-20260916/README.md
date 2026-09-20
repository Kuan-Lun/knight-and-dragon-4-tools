# Posted-repeat acknowledgement timeout

Source run: `logs/auto-level-20260916-032136.jY21AC`. It ran from 2026-09-16
03:21:48 to 09:13:20 Asia/Taipei, completing 719 cycles and posting 3,469 actions.
At the last failed EXP result, the repeat selection produced no visible selected
stamp. Subsequent captures remained confidently classified as `missionFailed`.

The run passed the posted action's 12-second acknowledgement deadline into the
ordinary observation capture as an input authorization deadline. Once expired,
window selection threw before the controller could consume another frame and
perform its existing bounded repeat retry. The exception included `reason=missing`
and `actualFrame=unavailable`, which could be unqueried default values rather than
observations about the actual window. The logs do not establish why the game's
first repeat selection did not respond.

## Fix

`AutomationCaptureDeadline` distinguishes pre-input authorization from post-input
acknowledgement. Pre-input authorization still expires before or after a window
query. An acknowledgement deadline allows an ordinary query of the original,
eligible, unchanged window to produce a fresh frame after the timeout, letting
the controller either authorize its existing bounded retry or stop normally.

Actual missing or changed windows still enter the original fixed recovery budget
and retain the original action deadline. This does not renew an expired budget,
authorize input after a window change, or relax final click validation. The
ordinary observation and first post-click observation both use acknowledgement
semantics; preflight uses input authorization semantics.

Error detail now records whether a query completed and reports `notQueried`
before any query. Completed query results update the diagnostic reason before
the post-query deadline check.

## Regression scope

The original PNG is retained byte-for-byte in the Runtime test bundle as
`visual-repeat-timeout-404x874.png`, with provenance in its adjacent JSON file.
The runtime regression composes production image loading/classification, window
selection with a simulated query/clock, and the real controller's request/post/
timeout decisions. It verifies fresh retry requests, unchanged failed-cycle
count, and the existing three-post maximum. The simulated continuation of saved
pixels is an offline replay, not additional captured history or live input.

Negative tests keep expired input authorization, actual window recovery expiry,
identity changes, and invalid timing non-actionable. Existing STOP/session and
geometry-recovery tests remain part of the full suite. No live game actions are
part of this validation.

## Final validation

`zsh Scripts/test.sh` passed 681 Swift Testing tests (638 Core and 43 Runtime),
2 XCTest cases, 55 auto-level launcher cases, 84 reroll launcher cases, 15 restart
supervisor tests, release compilation, and 18 offline CLI tests. The packaged
App also passed all 18 CLI tests, signature verification, the original command's
dry run, and read-only classification of the retained incident PNG.

The final Launch Services permission check reported screen capture and post-event
access missing after packaging; macOS reauthorization is required before a live
run. `validation.json` records the executable hash, exact test totals, read-only
replay, and permission result. No game input was posted during this work.
