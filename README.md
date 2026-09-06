# Knight & Dragon IV — iPhone Mirroring auto-level runner

This repository contains a fail-closed macOS automation runner for a stage that the user has
already opened manually in Knight & Dragon IV through iPhone Mirroring. It can also retain the
original one-shot capture, analysis, and click diagnostics.

It requires macOS Sequoia 15 or later, an iPhone that supports iPhone Mirroring, and the Mac and
iPhone configured for iPhone Mirroring.

The implemented loop can:

- handle the game's calibrated central modal skin without reading its labels: one detected row
  presses its only button, while two rows press the upper button;
- rely on the game's configured default `全部自動` mode and deliberately never press its
  toggle; each new battle must show independently verified combat progress within 30 seconds;
- collect loot and handle adventurer, battle, defeat, skill, and returned-party notifications
  through that same button-count rule;
- select `重複進行此任務`, then use the fixed upper advance control on both success and failure results without depending on OCR of `>>`; a positively observed selection is latched for the active result episode so a later OCR miss can never toggle it back off;
- recover a naturally stalled defeat after a dense five-second visual-stability confirmation; and
- stop on inventory-full, conflicting/unknown non-modal UI, changed window identity or geometry,
  an explicit stop file, or configured cycle/time/action limits.

The original feasibility checks established that:

1. Can public macOS APIs capture the `iPhone Mirroring` window as non-blank pixels?
2. Can one explicitly confirmed synthetic click reach that window?
3. Can a captured frame be classified into a known game state with only named, state-specific actions?

It uses only public APIs:

- ScreenCaptureKit for one-window screenshots.
- Apple Vision for Traditional Chinese and English OCR.
- Core Graphics for a single mouse-down/up pair.
- AppKit activation with an Accessibility `AXFrontmost` fallback for borrowing and restoring focus.
- A conservative image-health check that rejects transparent, uniform, and nearly black frames.

## Build and test

The machine's active developer directory currently points at Command Line Tools, so commands explicitly select the installed Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
zsh scripts/build-app.sh
```

The packaged app is written to `.build/Mirror Probe.app` with a fixed bundle identifier so it is recognizable in the privacy panes. Its current ad-hoc signature is not a stable TCC identity: rebuilding may invalidate the grants. A maintained app should use a stable Development or Developer ID certificate.

When the project is on the Desktop, macOS may also request Desktop folder access for the runner
to read its log directory. This is separate from Screen Recording and Accessibility. A pending
Desktop permission dialog can block directory access and take foreground focus; complete that
request before starting an automation run.

## Custom-character reroll usage

Open iPhone Mirroring and leave Knight & Dragon IV on the custom-character page, then run:

```sh
./reroll-character.zsh
```

The default target is `total >= 90` (thresholds 90 through 100 are supported). The runner reads two
matching frames before every action. It
requires full-frame and focused `total` OCR to be independently well-formed and to agree on digit
count, then independently counts the rendered digit glyphs; both OCR lengths and the actual
one/two/three-character length must match. For a two-digit threshold, both OCR reads at or above
the threshold stop the run even if their individual digit readings differ. Another reroll is
allowed only when both reads are below the threshold and exactly equal. A cross-boundary or
low-side disagreement is a terminal veto: later low OCR samples cannot erase it. At threshold 100,
digit-count agreement alone establishes which side of the boundary the result occupies. The
runner presses only the top-right `隨機` control and stops without pressing `決定`. After each click
it waits at least 1.5 seconds, verifies that the generated-result pixels changed, and requires two
pixel-stable snapshots before continuing. The name is the only generated text field used as an
identity signal. Profession, race, faith, all five stats, and remaining points are ignored.
Missing, ambiguous, low-confidence, misplaced, or inconsistent evidence stops the run safely.
Immediately before an input event, it performs an additional pixel-only capture and requires the
page identity, Random control, generated result, and lower controls to remain identical. The event
authorization expires 0.5 seconds after
that capture began; macOS does not expose an atomic compare-and-click API. Foreground input still
shares the Mac's keyboard focus and pointer during preflight and the click.

Vision sometimes reports an otherwise exact full-frame `total` row at confidence 0.30. That one
reading is only provisional: the independently cropped OCR must still have confidence 0.50 or
higher, and the rendered digit count must also agree. When a two-digit value is below the selected
threshold, the two OCR values must agree exactly. The `隨機` control and all other measured page
anchors retain their stricter confidence floors.

Version 0.4.14 also accepts full-frame Vision output that splits `total:` and the number into
adjacent observations on the same calibrated row. The 2026-09-06 run stopped at roll 165 because
`total: 81` was split this way and the old parser treated the label alone as malformed. Full-frame
boundary evidence and the page detector now use the same row resolver. Assembly requires exact
grammar, confidence, alignment, and bounded spacing; extra, duplicate, malformed, or conflicting
row evidence still stops the run. Focused OCR, rendered digit counting, and the sticky threshold
veto remain required. The original PNG and both OCR reads are retained as regression evidence.
All 425 source tests passed, the packaged release built and passed signature verification, and
the Launch Services `doctor` check confirmed both permissions still granted for 0.4.14
(`logs/character-reroll-fix-0.4.14-{tests.log,build.log,doctor.json}`). Validation used saved-image
OCR replays and read-only diagnostics; no live reroll was posted for this fix.

Useful bounded options are:

```sh
./reroll-character.zsh --minimum-total 90
./reroll-character.zsh --minimum-total 100
./reroll-character.zsh --max-rerolls 1000 --max-minutes 20
./reroll-character.zsh --window-id WINDOW_ID
```

Each launch creates stdout/stderr logs under `logs/character-reroll-*`; after permission, window,
and initial-page checks pass, it also creates a run report. A terminal run writes at most one
`final-candidate.png` beside that report: a completed run labels it `finalStable`, while a stop,
limit, or error records whether it is the last verified stable frame, a pre-click fallback after a
posted action, or the latest unverified post-click observation. The report stores both OCR values,
rendered digit count, and boundary status; it does not invent an exact `finalTotal` when two
high-side OCR values differ. Character-reroll report schema 3 also records whether keeper or
conflicting boundary evidence appeared earlier during stabilization, even if the latest saved
frame is a later low or unavailable OCR sample. No character-reroll images are written to the root `captures/`
directory. The launcher prints the exact
`touch .../STOP` command, and Ctrl-C creates that same stop file before exiting. Foreground input
activates iPhone Mirroring only when it is not already frontmost. Immediately after the click,
the runner requests a return to the previously active application before waiting for the generated
result. A cancelled or failed preflight also releases borrowed focus. If a different application
is already frontmost at cleanup, it is left alone. This reduces focus occupation but cannot prevent
simultaneous typing or pointer movement from being interrupted. Do not move or resize the mirror
window during a run.

## Auto-level usage

1. In the game, enable the persistent/default `全部自動` setting before the run. The runner
   treats the visible control as a toggle and never presses it, because pressing it when the
   default is already active would disable automatic combat.
2. Open iPhone Mirroring and manually enter the stage you want to repeat. Leave the game on its
   battle-introduction prompt or active battle screen.
3. Keep exactly one iPhone Mirroring window open, then start a bounded run with the launcher:

```sh
./auto-level.zsh
```

The launcher locates the project independently of the current shell directory, verifies the final
app and its signature, creates a unique empty run directory under `logs/`, starts the app, and prints the
report, error log, and exact `STOP` command. Run `./auto-level.zsh --help` by itself for built-in
help; `--help` displays usage and never starts a run.

Talisman use does not restrict launching, automation, or retreat. The launcher supplies the app's
general `--confirm AUTO_LEVEL` token. The old `--confirm-no-talisman` / `--no-talisman` flags and
the raw app token `AUTO_LEVEL_NO_TALISMAN` remain compatibility aliases; none asserts or checks
talisman status. Choosing whether to use talismans is left to the user.

The launcher's common optional limits are:

```sh
./auto-level.zsh --max-cycles 50
./auto-level.zsh --max-minutes 180
./auto-level.zsh --max-cycles 50 --max-minutes 180
./auto-level.zsh --capture-level info
```

- `--max-cycles N` limits the number of completed missions, including the stage already in
  progress when the launcher starts. Accepted values are 1–500.
- `--max-minutes N` is a wall-clock runtime limit. Accepted values are 1–480.
- With neither option, the defaults are 20 cycles and 120 minutes; whichever is reached first
  stops the run. With only one option, the omitted limit is raised to its safety ceiling (500
  cycles or 480 minutes), so its ordinary default cannot unexpectedly stop the requested limit.
  With both options, whichever is reached first stops the run; both do not need to be reached.
- `--window-id ID` selects one window when multiple iPhone Mirroring windows are open.
- `--output-dir PATH` atomically creates that new, previously nonexistent directory instead of
  generating the default `logs/auto-level-*` path. An existing path is rejected so concurrent
  runs cannot share or overwrite reports.
- `--capture-level error|info` controls retained screenshots. `error` is the default: expected
  limits and a `STOP` file retain no PNG, while a runtime error or safety stop retains at most the
  final eight captures. `info` additionally retains the initial frame and before/after frames for
  every posted action whose after frame was successfully captured, which is useful for a complete
  audit but uses more disk space. Both levels retain the run report and ordinary stdout/stderr
  logs.
- `--wait` keeps the invoking shell attached until the run stops, then prints `status`, completed
  cycles, posted actions, and the final reason. A report with `status=error` also prints stderr and
  makes the launcher exit nonzero. The default launch is asynchronous.
- `--dry-run` prints the exact launch command without creating files or launching the app.

Both launchers use `open -g` so starting the runner does not itself take focus away from the
application the user is working in.

The launcher deliberately fixes the app's internal `--input-mode foreground`. This mode temporarily
activates iPhone Mirroring and uses the shared pointer for each authorized click. The unverified
background/process input mode is not exposed by the normal launcher.

If startup fails, its reason is written to the printed error log even when no `run-report.json`
could be initialized.

At the cycle limit, the program stops on the result page before starting another mission. If more
than one eligible mirror window exists, first run `doctor` and add `--window-id WINDOW_ID`.

`--input-mode foreground` is the working input path for iPhone Mirroring. Each activation attempt
remembers the previously active application and activates the mirror only if it is not frontmost.
After a normal HID click, it restores the cursor position, retains focus through the one-second
settle and first post-action capture, then requests activation of the previous application. This
uses its main/key windows rather than raising all of its windows. Subsequent result observation
continues in the background. Cancellation, stop, and preflight errors also release borrowed
focus. Restoration is attempted at most once per activation attempt, only while the mirror is still
frontmost and the original application is still alive. If the user has already selected another
application, cleanup leaves it alone; it never relaunches an exited application.

Version 0.4.11 also observes explicit user input and application activation during each borrow.
Clicking the mirror yourself, dragging, scrolling, typing, or leaving the borrowed app cancels
that attempt's restoration, even if the mirror is frontmost again at cleanup. The runner tags its
own clicks so they do not cancel restoration. Pointer movement alone does not count as takeover.
Observers retain no key text or coordinates and are removed at cleanup. Each subsequent attempt
starts with the user's then-current app; cancellation never permanently disables restoration.
If input observation is unavailable, that attempt skips restoration. These passive observers and
macOS activation are asynchronous, so a user action concurrent with an already-issued activation
request is still not an atomic handoff.

Once a run has locked a window, a temporary absence from the eligible capture list pauses input
and allows at most four queries with 1, 1, and 1.5 second backoffs, within a fixed five-second
recovery budget. Recovery accepts only the original PID, window ID, and geometry. It does not
reopen the app, select a replacement window, or treat hidden/minimized windows as click targets.
STOP and the original session/action deadlines remain effective; post-click capture uses the
original acknowledgement deadline and cannot resend the click. Every gap discards prior pixel
continuity and any pending stall proof, including gaps shorter than the normal sample interval.
The `windowAvailability` stderr entries record the phase, attempts, mirror candidates before
filtering, and the matching WindowServer entry. This distinguishes a failed query from proof that
the user closed the window. Persistent absence still stops the run. A wait may end early at
an existing deadline, but that stops recovery without issuing another query.

macOS activation is asynchronous and advisory, so this is a best-effort return to the previous
application, not a guarantee of exact window/control focus or desktop stacking order. A rejected
AppKit activation request now falls back to setting `AXFrontmost` on that exact running process,
using the existing Accessibility permission. This also applies when restoring the previous app.
The fallback does not relaunch either app or use the pointer to switch windows. It is skipped if
focus changed before the fallback request. API acceptance alone never authorizes a click: the
existing preflight and input boundary checks still require the mirror's actual foreground PID.
Version 0.4.6 reads that PID directly through Accessibility's `AXFocusedApplication`, including
when remembering and restoring the user's app. An unavailable AX result remains unknown and
cannot authorize input. A separately created `NSRunningApplication.isActive` can disagree during
rapid switches and is now diagnostic only. The log distinguishes `notRequestedAlreadyFrontmost`
from an actual activation request returning `false`; it no longer substitutes `isActive` for an
API return value. The locked window, geometry, click-point obstruction, and deadline checks remain
mandatory at the final input boundary.
Live commands run the full AppKit event loop so AppKit can update its cached foreground and
application-state properties. Initializing `NSApplication.shared` alone left those observations
stale during the packaged focus test; an async settling delay did not refresh them. Offline
`analyze-file` and help commands continue without initializing AppKit.
AppKit rejection and the fallback outcome are recorded in stderr. Focus occupation includes the activation settling delay
(350 ms on the first attempt, longer on retries) and the complete capture/recognition preflight,
in addition to the 60 ms mouse-down/up interval. Because these events use the shared macOS pointer
and focus, typing or moving the pointer at the same instant can still be interrupted. If another application momentarily
takes focus before input, the runner makes at most three total activation attempts. Every attempt
uses a fresh capture and repeats the complete window, state, and target validation; no failed
attempt posts input. Each failed attempt waits one second before the next attempt's activation
settling delay and fresh capture. Three consecutive focus failures still stop the run safely.

Version 0.4.13 also spends that same three-attempt budget when a known window from another
process covers the action point while the mirror remains focused. No event is posted on the
rejected attempt. Retries wait for stacking to settle even if the mirror is already frontmost,
then take a fresh capture and repeat state, target, geometry, timing, and topmost-window checks.
The original action and session deadlines are not extended. Persistent obstruction still stops;
unknown topmost windows, a competing mirror-process window, and process-mode obstruction remain
terminal. `inputBoundaryRejected` stderr entries and the report's retry/error details now retain
the rejected point's window IDs, PIDs, bundle identifiers, layers, frames, and the same AX hit
result used by the guard. These diagnostics do not include other windows' titles or content.

`--input-mode process` is retained as a safe diagnostic mode. It routes the down/up pair only to
the locked iPhone Mirroring PID, never moves the global cursor, and never falls back to a global
click. A prior live test recorded in this README did not advance the recognized control and ended
at the unchanged-frame timeout. That observation does not identify which layer ignored the event
or prove that every form of background input is impossible. Do not use
this mode for unattended leveling unless a later macOS/iPhone Mirroring version is first verified
to accept the background event.

Only one `run` may control a particular iPhone Mirroring window at a time. After selecting the
exact window, the runner takes a nonblocking cross-process lock keyed by the current user, the
iPhone Mirroring process, and the window ID, and holds it until the run exits. A repeated launch
for that same window is refused before it can capture a frame or post an action.

To stop cleanly before a limit, create the session's stop file. If you use the same Terminal in
which `run_dir` was defined, run:

```sh
touch "$run_dir/STOP"
```

Shell variables are not inherited by a new Terminal window. From another Terminal, use the
absolute output path printed or chosen when the run was started, for example:

```sh
touch "/absolute/path/to/logs/auto-level-YYYYMMDD-HHMMSS/STOP"
```

The mirror does not need a reserved visible area: ordinary windows in the same Space may fully
cover it between actions. ScreenCaptureKit captures the specified window's content independently
of that occlusion; the runner brings it forward only when input is needed. Keep it open and
unminimized in the same Space. App hiding, other Spaces, and full-screen transitions are not
supported by the current on-screen-window discovery and input checks.

Do not move, resize, minimize, or send the mirror window to another Space during a run. Every
proposed click is confirmed against a fresh second capture. The exact window/process identity,
geometry, topmost destination-process window at the point, state-specific action name, and
OCR-, pixel-geometry-, or fixed-layout-derived target are all checked before one mouse-down/up
pair is posted. Foreground mode also checks the globally frontmost/topmost window.
`run-report.json` is retained under the output directory after initialization. Screenshot
retention follows `--capture-level`: the default `error` level writes no PNG when the maximum
cycle/runtime limit or a `STOP` file ends the run, but writes at most the final eight captures
after a safety stop or runtime error (the newest one is `final.png`, so the total is eight rather
than eight plus one). `info` also writes `initial.png`, every posted action's before/after images
after its after frame is captured, and `final.png`. A framework, full-disk, or capture error can
prevent a corresponding diagnostic image from being produced; that failure is recorded in the
report or launcher error log without replacing the original stop reason.

## Output directories and cleanup

Generated runtime data is deliberately separated from permanent development fixtures:

- `logs/` contains auto-level and character-reroll run reports, stdout/stderr logs, stop files,
  and any retained screenshots. When no automation run is active, you may clear the entire
  directory without affecting the program. Do not remove an active run's directory because its
  `STOP` file, report, and diagnostics are written there while the process is running.
- `captures/` is reserved for disposable output from the manual `doctor`, `capture`, `analyze`,
  `analyze-file`, and supervised `click` workflows shown below. You may clear it whenever you no
  longer need those diagnostics; the auto-level runner does not depend on its contents.
- `DevelopmentFixtures/` and `Tests/MirrorProbeCoreTests/Fixtures/` contain permanent development
  and regression-test inputs. Do not delete or clean these directories as runtime logs.

## Safe test sequence

Open iPhone Mirroring, connect the phone, display a harmless and visually distinctive game screen, and keep the mirror window visible rather than minimized.

Run the permission doctor through Launch Services:

```sh
open -W -n ".build/Mirror Probe.app" --args doctor --request-permissions \
  --output "$PWD/captures/doctor.json"
```

After granting **Screen Recording** and **Accessibility** in System Settings, quit and rerun the probe without `--request-permissions`. Inspect `captures/doctor.json` and use its `windowID`. Keep launching the packaged app through Launch Services so macOS attributes TCC permissions to `Mirror Probe`, rather than to the terminal or parent process. Capture is read-only:

```sh
open -W -n ".build/Mirror Probe.app" --args capture \
  --window-id WINDOW_ID \
  --output "$PWD/captures/mirror-probe.png" \
  --report "$PWD/captures/capture-report.json"
```

The JSON report includes the `windowID` and frame-health metrics. Inspect the PNG before using it as a state-recognition fixture.

To verify focus switching separately from game input, leave another app (for example Terminal)
frontmost and run the packaged diagnostic with the same background launch option as the runner:

```sh
open -g -W -n ".build/Mirror Probe.app" --args focus-check \
  --window-id WINDOW_ID \
  --output "$PWD/captures/focus-check.json"
```

This temporarily activates the mirror and then requests restoration of the original app. It sends
no mouse or keyboard events, and takes the same window lock as the runner. The report records both
API outcomes and observed foreground PIDs; successful verification requires an actual switch from
a different application and a return to that application. Starting with the mirror already
frontmost is not a valid restoration test. A concurrent user focus change can cause verification
to fail; cleanup does not intentionally override a newly selected app. Run this again after
granting permissions if the ad-hoc rebuild invalidated them. Version 0.4.5 adds this diagnostic,
the Accessibility fallback, and the AppKit event loop for the background-launch
activation failure and stale foreground state observed during 0.4.3–0.4.4 validation.

Local 0.4.5 validation on 2026-09-05 verified a background-launched focus check switching from
Codex to iPhone Mirroring and back, with zero input events. A subsequent launcher run limited to
one minute and two completed-cycle counts posted six clicks, advanced from an existing result
page through the next battle to its result page, and stopped normally at the cycle limit after
50.5 seconds. The two-cycle count includes the result already reached when the run began.

The subsequent 0.4.6 test began with Terminal frontmost and ran to the five-minute limit,
finishing after 303.1 seconds with 12 posted clicks and two success cycles. Its one initial focus
retry recovered; there were no exhausted retries, AX focus-read failures, or session errors.
The final reason was `maximumRuntimeReached(limit: 300.0)`. This verifies the longer focus-switching
path, but not all battle-stall recovery: the third cycle was still in battle when time expired,
and the observed enemy HP did not change over the final roughly 144 seconds.

Follow-up capture-only sampling found the battle image itself frozen for over nine consecutive
seconds, including the damage overlay. The old loop ran OCR on every stability sample, so its
roughly three-second capture/recognition/poll cycle frequently exceeded the three-second sample
gap limit; a five-second candidate could also contain fewer than the required five samples.
Version 0.4.7 separates capture from OCR and uses a short, bounded burst of pixel comparisons
after a stable battle pair. It records actual capture time before OCR, compares both consecutive
frames and a fixed starting frame, and revalidates fresh OCR before requesting retreat and again
at input preflight. If combat resumes during preflight, the unposted retreat is cancelled and
observation continues.

The 0.4.7 build passed 367 tests, including dense sampling, accumulated visual drift, stale or
changed preflight evidence, and cancellation of unposted retreat requests. Offline Vision
analysis also recognized the recorded frozen frame as battle with all four strict layout anchors.
Two subsequent live runs stopped after 112.965 and 40.284 seconds when Accessibility returned
`AXError.noValue` while acquiring the original focused application. They posted 9 and 2 clicks
respectively, and neither reached dense stability or retreat. The first completed two success
cycles. Thus live stalled-battle recovery is still unverified.

Version 0.4.8 treats an unavailable original focus read as an unposted focus failure in the same
three-attempt budget used for activation contention. Current builds wait one second after each
failure, recheck STOP and both deadlines, then obtain a new original-application identity and
perform the full action preflight.
It never guesses the original PID or extends authorization; persistent unavailable focus still
stops after the bounded retries. The 367 tests passed again after this change. Renewed macOS grants
and a fresh live run are required for the rebuilt app.

After renewed grants, the first 0.4.8 live run was stopped through its STOP file at 220.318 seconds
because a read-only inspection showed `[護符 戰神 風神]`, conflicting with the no-talisman launch
precondition. It posted five clicks and counted the result already present at startup; no new
complete battle cycle or retreat was observed. A dense candidate at 214.435 seconds was correctly
cancelled on moving pixels (adjacent MAD 0.006629, fixed-anchor MAD 0.006927, threshold 0.002).
There were no focus errors or retries in this run, so transient focus-read recovery and confirmed
stalled-battle retreat still require live validation. Continuing the retreat test requires
resolving the talisman precondition first.

The user's subsequent instruction removes that talisman restriction in 0.4.9: equipment choice
no longer affects launch or retreat, and reports use schema 4 with `talismanPolicy: unrestricted`.
The same update handles a system-wide AX `noValue` by checking a candidate application's live
`AXFrontmost` attribute. AppKit proposes the PID only; the AX read must succeed with an actual
CFBoolean true and the candidate must remain the same before/after that read. All other failed,
unknown, or conflicting focus reads still reject input. The source and both query outcomes are
logged separately. A stronger fallback is necessary because a later 0.4.8 run exhausted all three
original-focus reads after 1.265 seconds without posting any input.

The strict battle fingerprint now also accepts OCR's measured `利品` truncation in the same unique
loot-header position at confidence 0.50 or higher; all other control anchors remain required.
This addresses the extra header row observed with talismans without making equipment status a
policy input. The full 0.4.9 source suite passed 378 tests. A read-only capture returned the current
floor-69 menu correctly; that page is classified unknown because the runner does not automate
stage selection, not because capture failed. The user clarified that the mirror was still in
front during that capture, so it does not establish occluded capture support. A subsequent
explicitly occluded test was initially blocked by the rebuilt app's missing Screen Recording grant.
After renewed authorization, both partial occlusion and the user's ordinary Firefox window filling
the desktop captured the mirror correctly. `lsappinfo` reported Firefox PID 1341 before and after
each capture, with zero input events. The fully covered capture at 20:36:07 local time recognized
the current mission-complete page. This does not test macOS full-screen Spaces or minimization.

The first 0.4.9 live run demonstrated successful AXFrontmost fallback but stopped after 17.423
seconds because the posted repeat-selection click did not select the row. A controlled one-click
comparison at the same coordinates, initially activating the mirror with `open -b` and retaining
mirror focus through the after capture, produced the visible SELECTED stamp. This changed both
initial activation and focus duration, so it does not isolate the cause. Version 0.4.10 retains
borrowed focus until the existing
first post-action capture completes instead of treating event posting as delivery. It preserves
the posted timestamp, counts the input immediately, honors STOP/session deadlines, and feeds that
after frame to the controller once. A missing change still follows the existing wait/stop path;
the toggle is not blindly clicked again. The full suite still passes 378 tests.

The first 0.4.10 run still stopped on an unacknowledged result-page advance. A subsequent doctor
check found the same mirror process and window, with the required permissions granted; the
mirror had not closed. After an initial `open -b com.apple.ScreenContinuity`, the retry at
20:52:19 completed 301.613 seconds and stopped normally at the configured 300-second limit.
`logs/auto-level-20260905-205219.1l7YEa/run-report.json` records 29 posted actions and six result
cycles, of which one was already present at startup and five were new battle-to-success cycles.
The run borrowed and restored focus to Firefox and other foreground applications. All 25 primary
AX `noValue` reads recovered through the validated AXFrontmost fallback, with no exhausted focus
retries or diagnostic persistence errors. Some clicks still needed the existing bounded retry
before the page advanced, so this does not establish that every click is received. No natural
stall occurred, leaving live retreat and post-retreat recovery unverified in this run.

A later 0.4.10 run (`logs/auto-level-20260905-213112.wCV6yG`) lasted 2,978.330 seconds,
recording 54 result cycles and 273 posted actions before one eligible-window query omitted
51767. The last successful battle capture preceded the error by 3.063 seconds. A subsequent
read-only check found the same PID 9823 and window 51767, with no process restart. This motivated
0.4.11's bounded window recovery and per-borrow user takeover tracking. Its source suite passes
397 tests, including fixed recovery deadlines, acknowledgement deadlines that do not slide,
and cancellation that applies to one borrow even when the user leaves and returns to the mirror.
After renewed macOS permissions, `logs/focus-check-0.4.11-firefox.json` verified Firefox PID 1341
to mirror PID 9823 and back with zero input events. The 0.4.11 run at 22:51:51
(`logs/auto-level-20260905-225151.kDI6JD/run-report.json`) reached the five-minute limit normally
with 36 posted actions and seven recorded result cycles: one existing startup result, then three
successes and three failures. Two failures followed confirmed stalls: 5.338 seconds/nine samples
and 5.479 seconds/ten samples. Both retreat confirmations succeeded and both flows entered a new
battle afterward. No focus error, restoration-skip, monitoring-unavailable, or diagnostic
persistence error was recorded. This also found no evidence of the runner mistaking its tagged
clicks for user input. There was no live window-availability interruption or observed mid-borrow
user takeover during this run; those new branches remain covered by source review and the
automated tests rather than a reproduced live interruption.

Version 0.4.12 addresses `logs/auto-level-20260905-230008.3OTiLw`: its only advance left the
selected EXP page unchanged, but the former retry policy allowed only loot-page recovery. Both
known success pages now use the same three-attempt limit with fixed per-attempt acknowledgement
windows. Retry requires the original page identity, exact unique measured target, SELECTED state,
and clean evidence. EXP-to-loot transitions are handled separately and are never inferred from
pixel differences alone. The actual failed classification is retained as a regression fixture.
The reason the game ignored the original event remains unproven. A read-only `windowFocusBeforePost`
diagnostic now records AX focused-window versus hit-window agreement for success-page advances;
unknown AX data remains diagnostic and cannot override the existing input checks.
The 0.4.12 source suite passes 408 tests, including the recorded EXP failure, both pages' retry
limits, and cancellation when the page advances before a retry is posted. After renewed macOS
permissions were verified, `logs/auto-level-20260905-233335.Io9WAe/run-report.json` stopped after
14.361 seconds: its one `selectMissionRepeat` input left the EXP page unselected. This establishes
that ignored input also affects the repeat row, before the new advance retry path is reached.
The user reproduced the problem with overlapping Firefox and Terminal windows above the mirror.
The final input guard already compares the actual topmost CG window ID, including windows owned
by an unfocused application or another window owned by the focused application. That check does
not establish that the mirror's content window has key focus, however. The root cause of the
ignored input was not established.

The following run at 23:39:51 stopped after 3.831 seconds with no posted input because all three
preflight focus checks still found Firefox. The user confirmed manually clicking Firefox during
that test; it is a user focus change, not evidence that window activation itself failed. The
LaunchServices comparisons that evening were also inconclusive: one included user input during
the borrow, and the other found a battle already underway rather than the expected result page.

With the user preserving the overlapping arrangement for a short comparison,
`logs/auto-level-20260905-234640.PlxUAx/run-report.json` posted six actions and stopped on the
requested STOP after 28.990 seconds. It closed the existing battle-end prompt, selected repeat,
advanced EXP to loot and then left loot on the first posted attempt for each page, handled the
following prompts, and entered a new battle. The recorded cycle was the result present at
startup; this short test did not complete another battle. Both success-advance diagnostics
reported matching AX focused and hit windows with the expected PID and frame. Those reads precede
the fresh preflight capture and are not atomic evidence of focus at mouse-down. A later modal
action encountered one Terminal focus change with a user-input notification; its next activation
attempt succeeded without an extra posted click. No ignored advance or timeout retry occurred.
The user elected not to pursue the rare overlap failure further. No speculative AXRaise or
key-window mutation was added; the additional regression tests confirm that covering windows are
rejected regardless of whether they share the focused process or belong to an unfocused app.

The subsequent five-minute 0.4.12 run at 23:49:35
(`logs/auto-level-20260905-234935.CkAjqU/run-report.json`) reached the configured limit normally
after 300.491 seconds, with 28 posted actions and five recorded success cycles: one existing
startup result and four newly completed battles. It also exercised the previously unverified EXP
retry naturally: action 18's after-frame at 178.773 seconds remained on EXP, action 19's after-frame
at 194.663 seconds showed loot, and action 20 then left loot. The runner returned to battle at
208.237 seconds. Two unposted focus retries recovered, and five user-input notifications cancelled
individual focus restorations; no diagnostic persistence error was recorded. This validates the
bounded EXP retry in practice without establishing why the original click was ignored. The full
source suite, including the two added window-overlap regressions, passes 410 tests. No app rebuild
or additional macOS permission grant was needed for these test/documentation changes.

The run at 02:27:14 on 2026-09-06
(`logs/auto-level-20260906-022714.jnEEll/run-report.json`) completed 11 cycles and posted 56
actions before request 57 was refused at 02:39:27. Window identity, geometry, timing, and the
foreground PID passed; the topmost-window check at the modal action point failed. The old logs
do not identify the covering window, and the per-window final image cannot show external
occlusion. The preceding `accessibilityRequestAccepted` entries are successful fallback requests.
Version 0.4.13 adds the bounded external-obstruction retry and rejected-boundary diagnostics
described above. All 416 source tests pass (`logs/obstruction-retry-tests.log`), and the packaged
release builds and passes signature verification. Its first Launch Services doctor check reported
both permissions missing after the ad-hoc rebuild (`logs/doctor-0.4.13.json`). After the user
renewed permission grants, `logs/doctor-0.4.13-authorized.json` confirmed both permissions granted
and the same mirror process 9823/window 51767. The subsequent read-only preflight
(`logs/preflight-0.4.13.json`) captured that window and classified `wideModalOneButton`, with zero
input events. `logs/focus-check-0.4.13.json` then verified activation of the mirror and restoration
of the previous application, also with zero input events. A bounded one-minute/one-cycle run
(`logs/obstruction-fix-0.4.13-live/run-report.json`) posted one modal-close action, reached the
existing mission's result page, and stopped normally at the cycle limit after 2.247 seconds.
It did not complete a newly started battle or encounter a point obstruction. The new obstruction
retry branch is covered by automated tests; live obstruction recovery remains unverified.

## Read-only state analysis

Analyze an existing PNG without requesting macOS privacy permissions or initializing the iPhone Mirroring connection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build
.build/debug/mirror-probe analyze-file \
  --input "$PWD/captures/click-test-1/before.png" \
  --report "$PWD/captures/analysis-before.json"
```

After rebuilding and granting Screen Recording to that build, a live analysis can capture and classify exactly one mirror frame. It does not require Accessibility and sends no input events:

```sh
open -W -n ".build/Mirror Probe.app" --args analyze \
  --window-id WINDOW_ID \
  --output "$PWD/captures/analysis.png" \
  --report "$PWD/captures/analysis-report.json"
```

The fixed `zh-Hant-v1` profile uses Vision revision 3 with accurate `zh-Hant` and `en-US` recognition. Analysis schema version 2 records the SHA-256 of the exact encoded PNG bytes as `image.pngSHA256`, so a report can be checked against its source image rather than accidentally reused with a newer PNG at the same path. Every report also records OCR confidence and normalized top-left rectangles, plus `readOnly: true`, `inputEventsPosted: 0`, and `actionAuthorization: none`; `allowedActions` and `policyGatedActions` are planning evidence, never permission by themselves to click.

`analyze-file` opens its input exactly once with `O_RDONLY | O_CLOEXEC | O_NOFOLLOW` plus `O_NONBLOCK`; the last flag lets it reject a FIFO without waiting for a writer. A final-component symbolic link is also rejected. It uses `fstat` on that same descriptor to require a regular file whose advertised size is at most 50 MiB, then performs a bounded read of at most 50 MiB plus one byte. The resulting in-memory bytes are both hashed and supplied to ImageIO. ImageIO-reported width, height, and the 25-megapixel limit are validated before decoding.

The local fixtures currently calibrate these result-page transitions:

- `missionComplete` → suggest `selectMissionRepeat`, targeting the observed `重複進行此任務` text box.
- `missionCompleteRepeatSelected` → suggest `advanceMissionComplete` only when the calibrated area beside the repeat row contains the rendered red selection stamp and exactly one trusted page header (`獲得經驗值` or `獲得拾得物`) establishes the result layout. Runtime selection detection uses pixels, not Vision's reading of the word `SELECTED`; OCR variants remain diagnostic only. The runtime then uses the calibrated fixed upper continuation coordinate; OCR of `>>`, `22`, or the lower decorative glyph does not choose the target. Both success pages reuse that point. Before timeout, an explicit EXP-to-loot transition acknowledges the first click and permits the next page's action. If the original page remains visible after timeout, versions 0.4.12 and later allow at most three total posted attempts on that same independently recognized page and exact target; animation or fingerprint change alone cannot authorize a retry.
- `missionFailed` → suggest selecting `重複進行此任務`.
- `missionFailedRepeatSelected` → use the same calibrated upper continuation coordinate after the failure title, repeat row, and rendered red-stamp region are established. The lower glyph is never actionable.

For the game's central modal skin, the runtime does not require button-label or message OCR. It
detects the rendered wide rectangles directly: exactly one row selects that row, and exactly two
non-overlapping rows select the upper row. This covers battle, defeat, skill, loot, adventurer, and
returned-party notifications even when Vision misses or misreads their text. The calibrated
geometry excludes ordinary battle/result controls, and the entire window, modal layout, target,
frontmost status, and topmost point are captured and checked again immediately before input. The
regression corpus matches all 168 expected button counts, with no false positives across 70
battle/result samples and all 85 explicitly labelled modal layouts resolved correctly.

Immediately before every click, the runner captures and classifies the window again. If a pending
`selectMissionRepeat` is already satisfied by the exact corresponding selected result state, the
stale selection is cancelled without posting input and the fresh state is polled normally. This
result-selection exception covers `missionComplete` → `missionCompleteRepeatSelected` and the
equivalent failure pair. A success advance also records its expected EXP/loot page for preflight.
If an unposted EXP request now sees a verified loot page, it is cancelled and that fresh frame is
processed before a new action is authorized. Other existing modal/retreat cancellation rules still
apply; an unsupported state or content-page change stops instead of reusing stale coordinates.

The battle detector requires multiple independent, layout-constrained anchors, such as `第…場戰鬥`, `戰利品…`, and controls such as `暫停`, `撤退`, or `全部自動`. The unique `全部自動` target may still be located as classification evidence and for supervised diagnostics, but the auto-level runner never executes it: the control is a toggle and the run requires the game's default automatic mode to be on. `撤退` is merely located as a policy-gated target until the temporal detector confirms a stalled defeat. OCR remains diagnostic for modal contents, but complete calibrated modal geometry takes priority over OCR conflicts or missing text. Without such geometry, empty OCR, low-confidence uncorroborated markers, conflicting states, invalid geometry, inventory-full, and unknown screens produce no ordinary executable action.

### Live-observed failure flow and policy boundary

A natural battle failure was observed to stop on an apparently stable battle frame. In that sample, five party HP rows were at zero and one party member remained visible as a survivor; the game did not advance until `撤退` was pressed manually. Retreat then displayed the generic warning that used talismans would be lost. Only after the user confirmed that the current run had used no talisman and explicitly authorized `是` did the test continue. The game then showed the defeat prompt, followed by the `任務失敗` result. Recovery is to select `重複進行此任務` and then press the **top** `>>`.

That stalled-defeat condition is temporal, not a safe single-frame state. At the start of every
new battle, the runner assumes the configured default `全部自動` mode is already on, posts no
input, and arms a bounded validator. The battle must then produce genuine, pixel-corroborated
HP/log progress within 30 seconds or the run stops. An encounter, event, or defeat prompt is not
accepted as progress; after closing a prompt within the same battle, the runner starts fresh
30-second activity and stall baselines bound to the new input generation. Only after that normal
activity has been independently verified can the stalled-defeat detector begin its visual check.
It then requires the unique battle-layout anchors and at least five dense, consecutive samples
whose gameplay ROI remains nearly unchanged for at least five seconds; samples may be no more than
three seconds apart. A stable pair starts a capture-only burst with a 400 ms pause between captures
and a seven-second time bound; actual capture overhead adds to that interval. Both the previous
image and the fixed starting image must remain close, so gradual accumulated changes also cancel
confirmation. Only the boundaries run OCR; intermediate images establish visual continuity and
are never represented as newly recognized battle states. The burst honors STOP and the session
deadline without borrowing focus. HP values are diagnostic only and are not required for this frozen-screen
decision. A moving frame, unknown/non-battle state, prompt, pause, window change, input, or sampling
gap immediately clears the candidate. The changing phone status bar is outside the ROI, and the
same conditions are checked again immediately before `撤退`. A single screenshot never authorizes
`撤退` or its confirmation.

The safe operating policy is therefore:

- Talisman status does not change automation decisions. The user's run authorization includes
  confirming retreat regardless of whether a talisman was used.
- A reliably measured one-row central modal always presses its sole row; a reliably measured
  two-row central modal always presses the upper row. Text recognition is not required. Ordinary
  page controls and unsupported button counts are outside this rule.
- The same rule closes returned-party and skill notifications and chooses the upper recruitment
  row. If the resulting page has no recognized modal or auto-level state, the run stops for manual
  handling.
- Natural stalled-defeat recovery is enabled only by the multi-frame detector. It controls whether the runner may press the
  battle-screen `撤退` button; the resulting two-row confirmation then follows the general upper-row
  rule.

Apple documents the OCR API and Traditional Chinese language code in [Recognizing text in images](https://developer.apple.com/documentation/vision/recognizing-text-in-images).

## Supervised one-click diagnostic

This remains available only to reproduce the original one-shot feasibility test:

```sh
open -W -n ".build/Mirror Probe.app" --args click \
  --window-id WINDOW_ID \
  --x 0.5 \
  --y 0.5 \
  --confirm SINGLE_CLICK \
  --output-dir "$PWD/captures/click-test" \
  --report "$PWD/captures/click-report.json"
```

Launch Services does not reliably relay the app's standard output to the shell, so `--report` persists the JSON result. The click command captures `before.png` and `after.png`, refuses blank frames or changed window geometry, requires the exact mirror window to be active and topmost at the point, and sends exactly one mouse-down/up pair. Do not select a point that can purchase, delete, sell, overwrite, or otherwise make an irreversible choice.

The `click` subcommand remains a supervised feasibility probe. The separate `run` command is the
bounded automation path: it recognizes explicit states, uses only state-specific target regions,
performs a fresh preflight classification before every input, and stops when those guarantees no
longer hold.

Because this local PoC is ad-hoc signed, rebuilding changes its code-signing identity. After a rebuild, remove the old `Mirror Probe` entries from both privacy panes, add the newly built `.build/Mirror Probe.app`, and grant the permissions again. A maintained version should use a stable signing certificate instead.

## Go/no-go decision

- **Go:** the captured PNG visibly contains the game UI and a manually selected harmless click produces the expected visible state change.
- **No-go:** the mirror window cannot be uniquely found, all captures are black/transparent, or the confirmed click is ignored. This probe does not use private Apple frameworks or attempt to bypass protected content.
