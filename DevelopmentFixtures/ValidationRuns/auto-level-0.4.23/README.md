# Auto-level 0.4.23: visual result regions

The user-started `auto-level-20260911-052556.F6y52z` run stopped after two cycles
and eight posted actions. Its first cycle used 0.4.22's focused OCR successfully.
The last EXP advance also worked: captures 28 and 29 show EXP followed by loot.
The seven subsequent observations were unknown because of the title's 0.5 OCR
confidence, so the pending advance timed out. Replaying its final PNG with
0.4.22 recognized it successfully. The old report does not retain enough
focused-read rejection detail to establish which live refinement check failed.

At the user's request, 0.4.23 replaces result-page OCR with fixed visual regions:
success/failure title, EXP/loot header, and repeat label, combined with the existing
selected/empty red-stamp detector. Every semantic region and one unambiguous stamp
state must be present. The score is the minimum of pixel correlation and absolute
luminance agreement, with a fixed 0.94 threshold; this is not an OCR confidence or
an estimated probability. Both native 1x/2x samples and a bounded one-logical-pixel
registration tolerance are supported. Dynamic body rows and the status bar are
excluded. Modal geometry takes priority over result matching.

Recognized/partial result layouts do not run OCR. If other-screen OCR finds a
result state after the visual regions failed, that result action is suppressed.
Other screens, including battle progress, retain their existing recognition.
Visual evidence carries actual template scores and regions with no fabricated
OCR observation. Controller boundaries require complete, consistent visual
anchors and preserve existing target, foreground, deadline, retry, and page
acknowledgement rules.

Sources, native image labels, and template hashes are preserved under
`DevelopmentFixtures/ClassifierReplaySources/result-visual-20260911/`.
The template calibration and regression corpus overlap; the test results are
regression coverage, not a universal accuracy claim. See `validation.json` for
the final unit, packaged replay, permission, and live read-only results. This
validation does not start or click through a live automation session.

The first packaged live read-only check found another concrete defect: all three
visual regions matched, but the unselected loot page was rejected by the old
stamp ROI. The user confirmed the repeat option was unselected. Decoding that
same PNG through the production CoreGraphics path counted 103 red-like pixels
out of 8,968 (about 1.15%), from the first dynamic item row inside the old
0.270 lower edge. The new lower edge is 0.260, above the item row; color rules,
selected threshold 0.04, and clearly-empty threshold 0.001 are unchanged.
The original PNG and failed live report are retained. New regression tests
reproduce the failure before the change and cover dynamic red item rows at
1x/2x, while existing partial/faded-stamp tests remain in force.
