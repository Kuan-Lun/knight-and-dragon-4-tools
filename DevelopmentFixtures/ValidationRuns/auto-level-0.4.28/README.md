# Auto-level 0.4.28: bounded application-resolution recovery

The September 14 10:52:10–10:57:55 run completed 13 cycles and posted 68 actions.
Before action 69 could close the battle prompt, AppKit returned no application
for the locked mirror PID 91507. The process remained alive with its September 6
start time. `incident.json` retains the relevant report events. The original
AppKit failure's underlying cause remains unproven.

The missing-handle result now reaches the existing action retry loop before
activation, capture or input. A signal-zero process check must confirm that the
original PID still exists; an exited or unconfirmed process remains terminal.
Resolution failures share the same three total attempts and one-second backoff
as focus and retryable result-observation failures. No inner retry loop or
whole-program restart was added.

Each retry preserves the pending request, controller, counts and original action
and session deadlines. Recovery requires the same nonterminated application
PID/bundle, then fresh window, geometry, page, target and input-boundary checks.
Application-resolution attempts, exhaustion, refusal and recovery are recorded
in the report. Stderr also distinguishes an AX-confirmed foreground PID whose
AppKit application lookup failed from an AX read failure.

Whole-program retry would discard pending click acknowledgements, repeat-selection
protection, single-use confirmations, counts and elapsed-time limits. Recovery
therefore remains within the existing session/action boundaries. Posted input
does not enter this retry branch.

Validation passed 576 Swift Testing tests, two XCTest cases, 12 isolated launcher
cases, release build/signature verification and the launcher dry run. New policy
tests cover repeated exhaustion, refusal after input or unconfirmed liveness,
independent subsequent actions, and all six orderings of application-resolution,
focus and result-observation failures sharing one budget. A separate static
review checked runtime integration and retreat-proof continuity.

The packaged replay of the terminal image remains `wideModalOneButton` and
reports read-only operation with zero input events. Release and packaged binaries
have the same build UUID; their byte hashes differ because packaging replaces the
code signature. `validation.json` records the packaged version/build (0.4.28/51),
hash, test results and permission diagnostics.

No live game input was posted, and the original macOS lookup fault was not forced
in a live process. The pre-build Launch Services doctor had both permissions;
after signing 0.4.28, it reports Screen Recording and Accessibility/post-event
permission missing. Renew those grants for `.build/Mirror Probe.app` before
another automation run.
