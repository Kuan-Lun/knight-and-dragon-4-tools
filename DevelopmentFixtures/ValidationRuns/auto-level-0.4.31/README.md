# Auto-level 0.4.31: recover a battle already frozen at startup

## Incident and retained evidence

Source: `logs/auto-level-20260915-132057.KbWxRU`, started 2026-09-15
13:20:57 Asia/Taipei. The user confirmed the battle was already stopped before
launching auto-level and requested retreat followed by repeating the stage.
The source report ended after 30.809308 seconds with zero posted inputs, zero
completed cycles and `allAutoDidNotProduceProgress(..., timeout: 30.0)`.

The first report event classified the screen as battle with all four visual
controls above their 0.94 similarity floors. The regular stall detector was
still awaiting independently verified normal battle activity. A startup frame
that has never progressed cannot satisfy that prerequisite, so the old runtime
stopped at the automatic-progress deadline before it could retreat.

The error-capture ring retained eight original 406 × 890 PNGs, captures 13–20:

| Captures | Original capture times, elapsed seconds | Preserved resource |
| --- | --- | --- |
| 13–17 | 19.475316416705027 through 25.922745124902576 | `startup-frozen-battle-before.png` |
| 18–20 | 27.47702341666445 through 30.725790791679174 | `startup-frozen-battle-after.png` |

Only two encoded PNGs are distinct, so the test corpus stores one copy of each.
`Tests/MirrorProbeCoreTests/Fixtures/startup-frozen-battle-sequence.json` preserves
every original capture time, sequence number, source path, frame fingerprint,
role and PNG SHA-256, plus the original session/window and stop metadata. PNG
hashes are separate from the runtime's frame fingerprints:

- Before: `440accf322dabc66a233efd70a6267f4dae4faf95f8402a62dc4071bf13c6830`
- After: `e75f446ea8392825237970ea6d23dba440cc32441208230348edb6e934ada217`

The pair contains small pixel changes throughout the image. Direct RGB decoding
measured a full-frame mean absolute difference of about 0.00130 and a battle-ROI
difference of about 0.00138, below the existing 0.002 stability threshold. The
regression computes the actual differences again with `FrameAnalyzer` using the
same Core Graphics decoding as the other visual tests. It checks both adjacent
frames and the first-frame anchor; it does not claim the battle pixels are
identical. Visual HP/log regions do not exhibit acknowledgement-quality activity.
All retained frames must classify as battle and retain a trusted retreat target.

## Recovery behavior

The runtime may create a one-shot startup candidate only from the session's
first trusted battle observation. Thirty seconds without verified activity can
then start a separate dense confirmation. The confirmation starts with zero
stable elapsed time and requires at least five seconds and five samples, bounded
capture gaps, adjacent-frame and fixed-anchor stability, and a newer classified
retreat preflight. State, input, window or genuine-progress changes revoke the
startup candidate. The normal battle detector still requires normal progress.

A confirmed startup freeze uses the existing retreat and result-acknowledgement
flow. A direct failure result completes one failed cycle, selects repeat, and
advances back into battle. The startup exception cannot be reused for a later
battle in the same run.

## Regression scope and limits

`StartupFrozenBattleRegressionTests.swift` covers three cases:

1. Replay all eight originals at their report capture times, verify classification,
   retreat trust, measured stability and absence of normal progress. These frames
   never arm the regular stall detector.
2. Replay those originals through `StartupBattleRecovery`, proving the retained
   11.25 seconds cannot authorize recovery. Then explicitly simulate a future
   continuation of the final frozen pixels until 30 seconds have elapsed **since
   the first retained image**, followed by a separate dense confirmation and
   preflight. The real controller requests retreat, accepts a modeled direct
   failure result, selects repeat, advances and acknowledges the next battle.
3. Deliberately change only the incident frame's clock or skill tray in labeled
   synthetic variants. Those regions cannot supply gameplay stability changes
   or HP/log progress.

The simulated continuation does not fill in missing captures from the original
run. Failure and repeat-selected screens in the modeled continuation are existing
original PNGs from other runs (`retreat-direct-failure-final` and
`visual-result-failure-selected`). Their reuse does not claim the incident reached
either screen: it posted no input. These tests exercise offline recovery and
controller behavior; they do not demonstrate a successful live retreat/repeat or
prove continuous stability during the first 19.475 seconds of the original run.

## Final validation

Release 0.4.31, build 54 passes 612 Swift Testing tests in 54 suites and two
XCTest cases, including eight startup-policy tests and all three incident
regressions. The release build and signature verification pass. Both distinct
incident PNGs classify as battle in the final packaged executable's read-only
replay. The original `--max-minutes 480 --wait` launcher dry run is preserved.
Exact results and the packaged executable SHA-256 are in `validation.json`.

The pre-build app had both permissions. After the ad-hoc rebuild, the final
Launch Services `doctor` reports Screen Recording and Accessibility/post-event
permissions missing. Reauthorize `.build/Mirror Probe.app` in macOS before a
live run. No live automation was started and no game input was posted during
this validation.
