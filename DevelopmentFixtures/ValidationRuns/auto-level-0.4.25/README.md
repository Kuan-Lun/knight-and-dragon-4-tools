# Auto-level 0.4.25: NotificationCenter input-boundary incident

The source run, `logs/auto-level-20260911-062312.BBbuKG`, started on
2026-09-11 at 06:23:12 and stopped at 08:00:07 Asia/Taipei. It completed
294 cycles and posted 1,494 actions over approximately 96 minutes 55 seconds.
Request 1,495, `pressWideModalTopButton`, was rejected before either mouse event
was posted on all three attempts, ending with `clickPointObscured`.

`input-boundaries.json` retains the exact three final rejection samples from
stderr lines 17085, 17098, and 17111, together with a summary and the earliest
matching rejection and recovery. The terminal error appears at stderr line 17113.
The original 6 MB report and screenshots remain in the source run directory;
they are not duplicated here.

At 08:00:03, 08:00:04, and 08:00:07, the WindowServer list put NotificationCenter
window 14 at layer 21 ahead of the locked Mirroring window 65194. The Mirroring
process, PID 91507, was nevertheless frontmost, and successful Accessibility
hit-testing at the target point returned that same PID. The same NotificationCenter
signature had caused a rejection at 06:25:15, after which request 33 succeeded
on its second attempt at 06:25:18 (report event 107).

This suggests a passive system management background was counted as an input
obstruction. The recorded NotificationCenter and Dock bounds were both
`x=0, y=0, width=1512, height=982`, resembling a full-display surface. The incident
did not record live display geometry metadata, however, so equality with an
actual display cannot be established retrospectively. The inference must not
be treated as proof that a visible NotificationCenter panel was harmless.

The source `final.png` correctly shows the obtain-all-items Yes/No confirmation,
and the planned target falls inside Yes. Capture uses
`SCContentFilter(desktopIndependentWindow:)`, so this image excludes other desktop
windows and cannot establish whether the NotificationCenter surface was visible
or interactive. The terminal failure is an input-boundary veto; this image shows
no corresponding game-recognition error.

The implemented fix is narrowly limited to the observed NotificationCenter layer 21
management-surface signature, with bounds matching a currently observed full
display and successful AX hit-testing at the click belonging to the expected
process. Visible or intercepting surfaces, partial-size windows, unknown AX hits,
and unrelated owners must continue to block input. Existing window identity,
geometry, focus, timing, and bounded retry checks remain applicable.

Validation passed 564 Swift Testing cases plus 2 XCTest cases (566 total), including
10 new backdrop regressions, and 12 isolated launcher regressions. The 0.4.25/build-48
release compiled and passed code-signature verification and the original
500-cycle/480-minute launcher dry run. A packaged offline replay of the terminal
PNG still identifies `wideModalTwoButtons` and its upper-button target with zero
posted input events. Details and executable hash are in `validation.json`.

The rebuilt app's Launch Services `doctor` reports Screen Recording granted and
Accessibility/post-event permission missing. Renew that permission for
`.build/Mirror Probe.app` before running again. No live game clicks were posted.
The intermittent full-display NotificationCenter surface was not reproduced live;
regression scenarios explicitly supply the matching active-display geometry that
the old incident did not log. The fix retains the three-attempt bound and all
final input checks; it does not promise to recover real or unrecognized obstructions.
