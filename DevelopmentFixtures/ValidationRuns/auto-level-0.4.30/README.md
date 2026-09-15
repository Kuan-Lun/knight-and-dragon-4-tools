# Auto-level 0.4.30: no default session limits

The user requested removal of the 500-cycle cap and then clarified that runtime
must also have no default limit. Auto-level now defaults to no cycle, runtime or
action-count cap. The launcher forwards `--max-cycles` and `--max-minutes` only
when explicitly supplied; supplying one never manufactures the other. Positive
explicit values remain supported without the old 500/480 ceilings. The launcher
normalizes decimal strings and rejects integer overflow before arithmetic.

The controller uses optional limits rather than large numeric sentinels. The
native runner carries an optional session deadline through normal observations,
stale-result accounting, dense battle confirmation, action retries, final input
validation and post-click capture. Reports use schema 5 and encode absent
maximumCycles/maximumMinutes/maximumActions as JSON null. The old cycle-derived
action cap is removed. Character-reroll limits are unchanged.

STOP, Ctrl-C in wait mode, per-action deadlines, visual recognition, window
identity checks, fixed retry budgets and error stops remain effective. Dense
confirmation preserves the observed interruption reason instead of re-reading
the STOP file later and confusing manual stop with runtime expiry.

Use `caffeinate -di ./auto-level.zsh --wait` for continuous operation. The old
`--max-minutes 480` flag still explicitly requests an eight-hour stop.

The regression uses one controller without resets through 510 counted cycles,
10,710 posted and acknowledged actions, and 44,880 seconds (12 hours 28 minutes)
of simulated elapsed time. It can issue the next action. Other regressions retain
explicit count/runtime stops, finite per-action posting/acknowledgement deadlines,
STOP and fixed window recovery budgets even without a session deadline. Optional,
legacy numeric and explicit-null policies remain Codable-compatible.

Validation results, final release/signature checks and launcher dry runs are in
`validation.json` and adjacent logs. Tests are offline; no live game input or
continuous automation was started for validation.

Final validation passes 601 Swift Testing tests, two XCTest cases and 55 isolated
launcher cases. The 0.4.30 build 53 release passes signature verification. Packaged
help and real-launcher dry runs confirm no default flags, independent explicit
time-only/cycles-only options, and cycle values above 500. Release and package
share a build UUID. After this ad-hoc rebuild, Launch Services doctor reports
Screen Recording and Accessibility/post-event permission missing; renew those
grants for `.build/Mirror Probe.app` before running automation.
