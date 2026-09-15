# Auto-level 0.4.27: retreat proof tolerates pause occlusion

The source run, `logs/auto-level-20260914-030707.5S7Z3g`, completed 456 cycles
and posted 1,991 actions between 03:07:07 and 05:40:21 on September 14, 2026,
Asia/Taipei. Nine consecutive unknown observations over 13.14 seconds ended
the session with `uncertainStateExceededGrace(unknown)`.

The retained native 406×890 screenshots show a combat effect covering Pause.
Skip, All-auto, and Retreat still match at approximately 0.977. The packaged
0.4.26 replay in `before-fix-final-image.json` reproduces the missing-pause
failure without input. `incident.json` retains the final 15 original events
and the diagnostic capture metadata.

Per the user's request to check Retreat instead of Pause, 0.4.27 requires the
two battle footer anchors plus the measured Retreat control before temporal
monitoring. Pause remains diagnostic only. This shared proof is used by normal
classification, activity/stall evidence, dense confirmation, and final retreat
preflight. Templates, the 0.94 similarity threshold, click targets, progress
requirements, five-second freeze confirmation, and timeouts are unchanged.

`BattlePauseOcclusionRegressionTests.swift` replays all eight retained capture
positions, preserving recorded times and verifying PNG hashes. Five distinct
native PNGs are retained once each in the fixture manifest. Tests cover obscured
Pause, missing/dimmed required footer or Retreat controls, and rejection of
progress and retreat authorization based solely on a static image. Controller
replays supply explicit in-progress runtime facts; those are not inferred from
the captures. Existing visual activity and footer tests now reflect the requested
Retreat requirement.

All 573 Swift Testing tests and two XCTest cases pass, along with 12 isolated
launcher cases. The release app builds and passes signature verification. All
eight packaged saved-image replays classify as battle with the exact gated
Retreat target. Launcher dry-run validation preserves the requested 480-minute
limit (and existing 500-cycle cap). Results are in `validation.json` and the
adjacent logs. No live auto-level session or game input was started.

The rebuilt 0.4.27 app's Launch Services `doctor` reports both Screen Recording
and Accessibility/post-event permission missing. Renew those permissions for
`.build/Mirror Probe.app` before running again.

Pause/Resume is no longer interpreted. Manually pausing a battle after verified
progress may enter the existing freeze recovery while Retreat remains visible;
use the run's STOP file to stop automation. A static startup image still cannot
establish progress. This offline validation does not establish uninterrupted
eight-hour operation.
