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
- A conservative image-health check that rejects transparent, uniform, and nearly black frames.

## Build and test

The machine's active developer directory currently points at Command Line Tools, so commands explicitly select the installed Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
zsh scripts/build-app.sh
```

The packaged app is written to `.build/Mirror Probe.app` with a fixed bundle identifier so it is recognizable in the privacy panes. Its current ad-hoc signature is not a stable TCC identity: rebuilding may invalidate the grants. A maintained app should use a stable Development or Developer ID certificate.

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
that capture began; macOS does not expose an atomic compare-and-click API, so avoid interacting
with the Mac while a run is active.

Vision sometimes reports an otherwise exact full-frame `total` row at confidence 0.30. That one
reading is only provisional: the independently cropped OCR must still have confidence 0.50 or
higher, and the rendered digit count must also agree. When a two-digit value is below the selected
threshold, the two OCR values must agree exactly. The `隨機` control and all other measured page
anchors retain their stricter confidence floors.

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
briefly activates iPhone Mirroring for each verified click, so do not move or resize the mirror
window, and avoid using the mouse or keyboard while a run is active.

## Auto-level usage

1. Ensure this particular run uses **no talisman**. The recovery confirmation may otherwise
   destroy a used talisman.
2. In the game, enable the persistent/default `全部自動` setting before the run. The runner
   treats the visible control as a toggle and never presses it, because pressing it when the
   default is already active would disable automatic combat.
3. Open iPhone Mirroring and manually enter the stage you want to repeat. Leave the game on its
   battle-introduction prompt or active battle screen.
4. Keep exactly one iPhone Mirroring window open, then start a bounded run with the launcher:

```sh
./auto-level.zsh --confirm-no-talisman
```

The launcher locates the project independently of the current shell directory, verifies the final
app and its signature, creates a unique empty run directory under `logs/`, starts the app, and prints the
report, error log, and exact `STOP` command. Run `./auto-level.zsh --help` by itself for built-in
help; `--help` displays usage and never starts a run.

`--confirm-no-talisman` is required for every run. It maps to the app's internal
`--confirm AUTO_LEVEL_NO_TALISMAN` assertion: the runner may confirm retreat after a verified
natural stalled defeat only because the user has stated that this run uses no talisman.

The launcher's common optional limits are:

```sh
./auto-level.zsh --confirm-no-talisman --max-cycles 50
./auto-level.zsh --confirm-no-talisman --max-minutes 180
./auto-level.zsh --confirm-no-talisman --max-cycles 50 --max-minutes 180
./auto-level.zsh --confirm-no-talisman --capture-level info
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

The launcher deliberately fixes the app's internal `--input-mode foreground`. This mode briefly
activates iPhone Mirroring and uses the shared pointer for each authorized click. The known-rejected
background/process input mode is not exposed by the normal launcher.

If startup fails, its reason is written to the printed error log even when no `run-report.json`
could be initialized.

At the cycle limit, the program stops on the result page before starting another mission. If more
than one eligible mirror window exists, first run `doctor` and add `--window-id WINDOW_ID`.

`--input-mode foreground` is the reliable mode for iPhone Mirroring. It activates the mirror for
each authorized action, posts a normal HID click, and restores the cursor position afterward.
Because those events use the shared macOS pointer and focus, using the mouse or keyboard in
another application at the same instant can be interrupted. If another application momentarily
takes focus before input, the runner makes at most three total activation attempts. Every attempt
uses a fresh capture and repeats the complete window, state, and target validation; no failed
attempt posts input. Three consecutive focus failures still stop the run safely.

`--input-mode process` is retained as a safe diagnostic mode. It routes the down/up pair only to
the locked iPhone Mirroring PID, never moves the global cursor, and never falls back to a global
click. Live testing on the current ScreenContinuity build showed that the event was rejected: the
recognized control did not advance and the unchanged-frame timeout stopped the run. Do not use
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
- `missionCompleteRepeatSelected` → suggest `advanceMissionComplete` only when the calibrated area beside the repeat row contains the rendered red selection stamp and exactly one trusted page header (`獲得經驗值` or `獲得拾得物`) establishes the result layout. Runtime selection detection uses pixels, not Vision's reading of the word `SELECTED`; OCR variants remain diagnostic only. The runtime then uses the calibrated fixed upper continuation coordinate; OCR of `>>`, `22`, or the lower decorative glyph does not choose the target. Because both success pages reuse that point, a second click is allowed only after the recognized page identity changes from EXP to loot; animation or fingerprint change alone cannot replay it.
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
exception is limited to `missionComplete` → `missionCompleteRepeatSelected` and the equivalent
failure pair; every other preflight state change remains a safety error, and the runner never turns
the stale request directly into a continuation click.

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
three seconds apart. HP values are diagnostic only and are not required for this frozen-screen
decision. A moving frame, unknown/non-battle state, prompt, pause, window change, input, or sampling
gap immediately clears the candidate. The changing phone status bar is outside the ROI, and the
same conditions are checked again immediately before `撤退`. A single screenshot never authorizes
`撤退` or its confirmation.

The safe operating policy is therefore:

- Auto-level runs have a no-talisman precondition. Under the user-authorized button-count rule, a
  reliably measured two-row modal may choose its upper row; the required launch confirmation is
  what makes that safe when the modal is the talisman-loss retreat confirmation.
- A reliably measured one-row central modal always presses its sole row; a reliably measured
  two-row central modal always presses the upper row. Text recognition is not required. Ordinary
  page controls and unsupported button counts are outside this rule.
- The same rule closes returned-party and skill notifications and chooses the upper recruitment
  row. If the resulting page has no recognized modal or auto-level state, the run stops for manual
  handling.
- Natural stalled-defeat recovery is enabled only by the multi-frame detector and the explicit
  `AUTO_LEVEL_NO_TALISMAN` assertion. The detector still controls whether the runner may press the
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
