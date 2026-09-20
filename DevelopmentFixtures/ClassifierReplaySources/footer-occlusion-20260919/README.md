# Battle footer recognition failure, 2026-09-19

Source run: `logs/auto-level-20260919-130059.tJLHuZ`, using `visualRegions`.
The run completed 227 cycles before stopping at 2026-09-19 14:31:39 Asia/Taipei
with `uncertainStateExceededGrace(unknown)`.

All eight retained 400×878 PNGs are copied byte-for-byte to
`Tests/MirrorProbeCoreTests/Fixtures/footer-occlusion-20260919-capture-4656.png`
through `footer-occlusion-20260919-capture-4663.png`. Capture 4663 is the original
`final.png`. Duplicate captures remain separate files so their source sequence
is explicit: captures 4659–4660 share one hash, and 4661–4663 share another.
The sequence contains five distinct PNG hashes.

The adjacent `footer-occlusion-20260919-sequence.json` records source paths,
report and PNG SHA-256 hashes, original elapsed times and timestamps, capture
and event sequences, frame fingerprints, original states, decisions, diagnostics,
and marker scores. Scores from rejected classifications retain the report's
five-decimal precision. The manifest also records the last confirmed battle
and first unknown observation; no PNG survived for those two observations.

## Failure evidence

Event 3118 at elapsed 5410.185096 seconds was a confirmed battle. Its skip,
all-auto, and retreat similarities were approximately 0.946369, 0.948817, and
0.944214, respectively. The temporal monitor was armed.

Event 3119 at elapsed 5426.474954 seconds became unknown because the detector
required both footer identity controls to meet the 0.94 floor. Skip fell to
0.48795 and all-auto to 0.50542. Retreat remained above its unchanged floor at
0.94428; pause was slightly below the floor at 0.93968. The detector discarded
the accepted retreat match when returning `incompleteFooterMarkers`, leaving
no retreat candidate. The temporal monitor reset to inactive/unarmed with
`reset=paused`. These footer and retreat scores stayed unchanged across all
eight retained captures.

After nine consecutive unknown observations, event 3127 stopped at elapsed
5439.884718 seconds, 13.409764 seconds after the first unknown observation.
No retreat was requested during this unknown interval. The same run had already
posted 11 retreat requests earlier, most recently at elapsed 5389.239346 seconds;
the incident is therefore specific to the classification/recovery transition.

The images show ongoing combat and large damage/healing numbers above the footer.
The skip and all-auto text remains visible in the retained images. The exact
visual cause of the low footer correlations—overlay, surrounding pixels, or
layout/registration differences—is not established by these images alone.
The regression should preserve that distinction instead of treating an overlay
on the glyphs as a proven cause or lowering the general recognition threshold.

## Negative control and replay boundaries

`footer-occlusion-20260919-iphone-disconnected.png` is the original final PNG from
`logs/auto-level-20260919-124521.NTXN1x`. It shows “iPhone 使用中” and explains that
mirroring ended because the iPhone was in use. That earlier run completed 34
cycles and also stopped with an unknown-state timeout, but all four battle
control similarities were -1. Its provenance and original scores are recorded
under `negativeControls` in the manifest. It must not permit retreat recovery.

A recovery replay must supply the preceding confirmed-battle context and use
the recorded elapsed times; neither an isolated image nor the fixture name
authorizes an action. The original last-confirmed and first-unknown images are
unavailable, so tests using those contexts must identify them as report-derived
or explicitly simulated inputs. No post-retreat confirmation image exists for
this incident. The fixtures do not prove that a real click was accepted or that
a subsequent battle resumed. No live input was posted while collecting them.

## Recovery and regression coverage

The detector now retains the independently measured retreat glyph while leaving
the page unknown and exposing no ordinary or policy-gated action. A separate
`BattleRecognitionRecovery` policy requires a recent recognized battle in the
same window/battle/input generation followed by 30 seconds of consecutive footer
failures with a visible retreat glyph. Gaps longer than five seconds, lost glyphs,
modals, results, or continuity changes revoke the chain. A fresh capture must
still verify retreat immediately before posting. This path deliberately allows
combat animation; it does not assert that the battle is frozen.

`FooterOcclusionRegressionTests` verifies all eight original captures and the
disconnect negative, obscured/dim retreat controls, and existing modal/result
pages. Its controller replay explicitly supplies a synthetic preceding battle
sample and synthetic continuation of the final pixels up to the 30-second
boundary, then verifies the retreat-confirmation transition. It does not claim
those extra samples or the confirmation happened in the original live run.
`BattleRecognitionRecoveryTests` covers interruption, freshness, timing, action
limits, and posted versus unposted failure-result acknowledgement.
