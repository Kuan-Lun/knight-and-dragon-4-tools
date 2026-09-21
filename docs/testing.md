# Testing

## One command

From any working directory:

```sh
zsh /path/to/project/Scripts/test.sh
```

From the repository root, optionally collect Swift coverage:

```sh
zsh Scripts/test.sh --coverage
```

Requirements are macOS 15+, an Xcode toolchain supporting Swift 6.2 or newer,
Python 3 and zsh. The script respects `DEVELOPER_DIR`; otherwise it selects
`/Applications/Xcode.app/Contents/Developer` when available. Compiler/package
caches and validation logs stay under `.build/`.

The command runs, in order:

1. Swift Core and Runtime test targets.
2. Isolated auto-level launcher tests.
3. Isolated character-reroll launcher tests.
4. Isolated restart supervisor tests with a fake launcher (no App or game input).
5. Release executable compilation.
6. Offline process tests against that release executable.

Any failed stage makes the command fail. The script does not replace or re-sign
`.build/Mirror Probe.app`. Packaging remains a separate command:

```sh
zsh Scripts/build-app.sh
```

Packaging also respects an explicit `DEVELOPER_DIR`, so validation and packaging can use
the same installed toolchain.

Logs are in `.build/validation/`. Swift coverage data is in the debug build's
`codecov` directory; use `xcrun swift test --show-codecov-path` with the same
toolchain to locate the generated JSON after a coverage run. Coverage is scoped
to Swift tests; launcher/CLI subprocess coverage is not merged into that file.

## Test layers

| Layer | Exercises | Does not establish |
| --- | --- | --- |
| Core unit tests | Policy boundaries, target geometry, retries, frame validation, detector evidence | Real macOS input delivery |
| Saved-frame replays | Actual retained PNG classification and explicit multi-frame scenarios | Unrecorded portions of live runs |
| Filesystem/process integration | Kernel run-lock contention/release, symlink/hardlink/permission rejection | End-to-end application launch locking |
| Runtime tests | Production command parsing, offline analysis, report persistence/termination, and the automation loop itself driven through scripted platform operations (`AutoLevelLoopOperations`) | Real window capture, focus reads and input delivery |
| CLI integration | Actual executable dispatch, exit codes, stdout JSON, output files and invalid inputs | Screen Recording/Accessibility permissions |
| Launcher integration | Real shell scripts with fake `open`/`codesign`, argument and report contracts | Launch Services or real signing identity |

## Individual checks

Use the unified script first to build the executable and initialize local caches.
For a targeted Swift test, retain its environment and package-cache arguments when
working inside a restricted environment:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
  xcrun swift test --disable-sandbox \
    --cache-path "$PWD/.build/swiftpm-cache" \
    --config-path "$PWD/.build/swiftpm-config" \
    --security-path "$PWD/.build/swiftpm-security" \
    --filter MirrorProbeRuntimeTests

zsh Tests/LauncherTests/auto-level-wait-tests.zsh
zsh Tests/LauncherTests/reroll-character-tests.zsh
python3 Tests/IntegrationTests/cli-tests.py .build/release/mirror-probe
```

`--disable-sandbox` disables SwiftPM's nested build sandbox so an already
restricted development environment can compile; it does not grant the app input
or screen-capture permissions.

## Zoom-level captures

iPhone Mirroring keeps a fixed-point border around the phone content (38 above, 8
below, 7.5 each side at 1x), so only the 406x890 zoom level is proportional to the
calibrated regions. `MirrorContentLayout` detects that border and places the content
on a reference-proportioned canvas before recognition; `analyze-file` and `capture`
reports describe it under `contentLayout`, and a run logs `mirrorContentLayout:` to
stderr whenever it changes.

Templates are sampled at the zoom-level window sizes listed in
`MirrorContentLayout.calibratedWindowSizes`; a window dragged to another size is stepped to
the nearest level through the app's 顯示方式 menu (Accessibility ⌘- / ⌘+ presses) by
`snapMirrorWindowToCalibratedSize` before an auto-level session locks its geometry, because
glyph rasterization at intermediate sizes scores below the 0.94 floor. Setting the window
size directly rounds the height differently (250x552 instead of 250x553) and also fails.

To collect calibration or regression captures at every zoom level on this Mac:

```sh
ANALYZE_BIN=.build/debug/mirror-probe zsh Scripts/zoom-sweep-capture.zsh captures/zoom-sweep loot
```

The script only clicks 顯示方式 > 放大／縮小 through System Events (Accessibility) and
captures through the packaged App; it never posts input to the phone and restores the
initial zoom level. Zoom-level template sources are listed with the `zoom` placement in
`Scripts/generate-result-visual-templates.py` and `Scripts/generate-battle-visual-templates.py`,
which sample them through the same canvas (`Scripts/mirror_content_layout.py`). Sources
captured earlier remain sampled raw so their bytes never change.

## CI

`.github/workflows/test.yml` runs the same coverage-enabled offline command for
pushes, pull requests and manual dispatch. It uses GitHub's
[macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
and the official [checkout action](https://github.com/actions/checkout).
This workflow has been added locally; its hosted result is available only after
the repository receives the commit and GitHub runs it.

## Remaining integration work

The production capture → authorize → post → acknowledge loop still needs injected
capture, clock, input and persistence dependencies. Tests that manually compose
Core helpers do not replace tests of that actual workflow. See the ordered
[architecture plan](architecture.md#next-optimization-passes).

A live smoke test additionally needs the connected iPhone/game, correct page,
macOS permissions and supervised input. The offline suite deliberately does not
start a game session; its success must not be reported as live end-to-end proof.

## First-pass validation baseline (2026-09-15)

The local Xcode Swift 6.3.3 toolchain passed:

- 648 Swift Testing tests in 60 suites and 2 XCTest cases;
- 55 auto-level launcher cases and 84 reroll launcher cases;
- release compilation and 18 offline CLI integration tests against that binary.

The final Swift coverage run measured **97.0%** of executable Core lines
(7,811/8,049) and **9.0%** of Runtime lines (573/6,391). These are line-coverage
figures, not proof of every branch or end-to-end behavior. The runtime figure
now includes production code that was previously outside the test targets;
its unexercised platform operations and orchestration define the next test work.
The executable entry and shell/Python cases are outside these Swift figures.
