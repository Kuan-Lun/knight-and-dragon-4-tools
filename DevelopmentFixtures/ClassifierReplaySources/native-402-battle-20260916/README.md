# Native 402×882 battle after a modal acknowledgement

Source run: `logs/auto-level-20260916-142900.5t7RC5`, 2026-09-16.

All eight retained diagnostic PNGs are copied byte-for-byte to
`Tests/MirrorProbeCoreTests/Fixtures/native-402-battle-capture-0013.png` through
`native-402-battle-capture-0020.png`. Capture 0020 is the original `final.png`.
The adjacent `native-402-battle-sequence.json` records original paths, elapsed
times, capture identities, dimensions, SHA-256 hashes, and the source-report hash.

Capture 0013 calibrates only the skip-control glyph template. Captures 0014–0020
are held-out replay images and do not contribute template pixels. All images
were classified as unknown in the report; skip similarity remained about 0.9358
below the unchanged 0.94 threshold, although the game had entered battle.

The regression reconstructs the final modal origin from its reported target
and state because no original modal PNG survived error-only retention. Its
mouse-post time is explicitly simulated at the origin observation time; the
report actionPosted timestamp records the later result capture. No screenshot
is invented, and no live input is performed. The replay uses the retained
battle capture times and proves acknowledgement clears on the first battle
frame, later frames pass the old deadline, and no additional action is issued.
Automatic mode and in-progress status in controller replay are explicit test
runtime inputs, not facts inferred from an individual screenshot.

## Validation

`baseline-replay.json` records the pre-fix production executable classifying all
eight frames as unknown. The rebuilt 0.4.33 (56) App classifies all eight as battle;
skip similarity is 0.98361–0.98367. `validation.json` retains those classifications
and the packaged executable hash. The new sample preserves the 0.94 floor and
fixed regions; all-auto and retreat must still independently match.

Passed 642 Core and 43 Runtime Swift Testing tests, 2 XCTest cases, 55 auto-level
launcher cases, 84 reroll launcher cases, 15 restart-supervisor tests, and 18
packaged CLI integration tests. The unified offline script's release build was
blocked by the sandbox at `dsymutil`; the same release build and App packaging
then succeeded through `Scripts/build-app.sh` with approved local tool access.
Signature verification and the original launcher's 480-minute dry run passed.
The packaged read-only permission check reported both screen capture and post-event
permissions missing after re-signing. The user must reauthorize Mirror Probe in
macOS privacy settings before restarting automation; no TCC settings were changed.

No game input was posted, and an eight-hour live session has not been verified.
