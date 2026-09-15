# Auto-level 0.4.24: all recognition from image regions

The user requested replacement of every auto-level OCR decision with graphical region
comparison, explicitly excluding character reroll. This extends 0.4.23's result-page
work to battle classification, normal-progress verification, retreat preflight, and the
final frame of dense visual-stability confirmation. Modal geometry already supported
the existing one-row/two-row upper-button policy.

The live unselected loot capture exposed an additional old stamp-ROI defect. Its lower
edge included the first dynamic loot row. The adjusted lower edge is 0.260 instead of
0.270; all red-ink and selected/empty thresholds remain unchanged. The failing capture,
report, and before-fix regression output are retained in the adjacent 0.4.23 validation
folder and the result visual corpus. It now belongs to the 21-image result corpus.

Battle-page identity matches only the fixed Skip and All-auto footer glyphs, as the user
requested. Skill brightness and the loot counter are excluded. Normal pause and the retreat
target are separate running/action checks. A still never establishes HP values or whether
auto mode is enabled. Normal progress requires changes in fixed HP/log
image regions corroborated by gameplay-area change. This excludes clock changes and
enemy animation alone. The gameplay/stall ROI stops above the bottom control/skill tray, so
its changing brightness cannot keep resetting a frozen battle’s timer. Existing window/session/input/gap guards, the 30-second progress
limit, and dense five-second stall/retreat confirmation remain. Visual evidence carries
actual regions/scores; HP values and OCR observations are not fabricated.

The user confirmed that the game is deliberately parked on an unselected loot page.
Live validation is read-only. No game clicks or long-running auto-level session are
part of this validation. Final results are recorded in validation.json.

An intermediate battle-header template depended on loot-label alignment; it was removed
following the user’s preference for the stable Skip/All-auto footer. The retained
battle-header-before-fix.json records that intermediate investigation, not the final method.

Final validation passed: 554 Swift Testing tests plus 2 XCTest cases, 12 launcher
regressions, 12 packaged saved-image replays, release build, signature verification,
and launcher dry run. The final ad-hoc rebuild initially lost Screen Recording; the
user renewed it, and doctor confirmed both permissions granted. A fresh 812×1780
read-only capture correctly recognizes the unselected loot page, with zero OCR
observations and zero posted inputs. No long-running live automation was started.
