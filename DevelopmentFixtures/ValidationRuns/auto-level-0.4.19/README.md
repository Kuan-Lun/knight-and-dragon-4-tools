# Auto-level 0.4.19: ignored repeat-selection input

Source: `logs/auto-level-20260909-220516.3scIWq/run-report.json`. The run stopped
at 22:06:23 Asia/Taipei on September 9 after three result cycles and eleven posted
actions. `source-run-tail.json` retains the last result transition and failure.

Request 11 selected the repeat row at normalized (0.16749, 0.24607), correctly
inside its OCR rectangle. Its first after-capture had mean absolute pixel
difference 0.0. Later captures still showed an unselected failure result until
the twelve-second acknowledgement timeout. The final PNG and offline Vision
report are fixtures named `mission-repeat-ignored-final` in the core test target.
The PNG SHA-256 is checked before replaying its actual OCR and stamp pixels.

The evidence establishes an unacknowledged input, not its delivery-layer cause.
The same symptom occurred in earlier September 5 logs, including a subsequent
successful controlled click at the same coordinates. This fix supplies bounded
recovery without assuming which component ignored the event.

Repeat selection can now post at most three attempts. A retry requires affirmative
unselected pixel evidence in both the originating and timeout observations, the
same independently recognized result family and content page, and exactly the
same target. The captured unselected region has four brown-rule pixels among
8,968 samples, so absence allows at most 0.1% red noise; selection needs at least
4%, with the intervening range ineligible for input. OCR-only absence cannot
authorize a retry. The fresh preflight repeats that proof and exact target check;
a selected preflight cancels the pending retry through the existing forward
transition path. Existing selected-state latching, cooldowns, freshness,
STOP/window/focus checks and global budgets continue to apply.

Validation details are recorded in `validation.json`. Recovery is verified by
saved-image replay and controller simulations; live game input and an eight-hour
soak are not part of this validation.
