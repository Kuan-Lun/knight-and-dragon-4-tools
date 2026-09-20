#!/bin/zsh
# Capture the mirror window at every iPhone Mirroring zoom level and analyze each capture
# offline. Read-only for the game: it only clicks 顯示方式 > 放大／縮小 in the mirroring app's
# menu bar (System Events, needs Accessibility) and never posts input to the phone.
#
#   zsh Scripts/zoom-sweep-capture.zsh OUTPUT_DIR [LABEL]
#
# Requires the packaged App (Scripts/build-app.sh) for screen-capture permission. Analysis uses
# the App binary unless ANALYZE_BIN points elsewhere (for example .build/debug/mirror-probe to
# evaluate uncommitted recognition changes). The window returns to its initial zoom level.
set -euo pipefail

readonly project_dir=${0:A:h:h}
readonly app="$project_dir/.build/Mirror Probe.app"
readonly analyze_bin=${ANALYZE_BIN:-"$app/Contents/MacOS/mirror-probe"}
readonly output_dir=${1:?usage: zoom-sweep-capture.zsh OUTPUT_DIR [LABEL]}
readonly label=${2:-sweep}
readonly menu='menu 1 of menu bar item "顯示方式" of menu bar 1 of process "iPhone Mirroring"'

[[ -x "$app/Contents/MacOS/mirror-probe" ]] || { print -u2 -r -- "missing App: $app"; exit 2; }
[[ -x "$analyze_bin" ]] || { print -u2 -r -- "missing analyzer: $analyze_bin"; exit 2; }
mkdir -p "$output_dir"

menu_click() { osascript -e "tell application \"System Events\" to click menu item \"$1\" of $menu" >/dev/null; }
menu_enabled() { osascript -e "tell application \"System Events\" to get enabled of menu item \"$1\" of $menu"; }
window_size() {
    osascript -e 'tell application "System Events" to tell process "iPhone Mirroring" to get size of window 1' \
        | tr -d ' ' | tr ',' 'x'
}

# Remember the initial level as the number of 縮小 steps taken to reach the smallest size.
initial_steps=0
while [[ $(menu_enabled 縮小) == true ]]; do menu_click 縮小; sleep 1.2; initial_steps=$((initial_steps + 1)); done

level=1
while true; do
    sleep 0.8
    size=$(window_size)
    png="$output_dir/$label-L$level-$size.png"
    capture_report="$output_dir/$label-L$level-$size.capture.json"
    analysis="$output_dir/$label-L$level-$size.analysis.json"
    open -W "$app" --args capture --output "$png" --report "$capture_report"
    "$analyze_bin" analyze-file --input "$png" --report "$analysis" >/dev/null 2>&1 || true
    python3 - "$level" "$size" "$analysis" <<'PY'
import json, sys
level, size, path = sys.argv[1:]
report = json.load(open(path))
classification = report["classification"]
layout = report.get("contentLayout") or {}
canvas = f"{layout.get('canvasWidth')}x{layout.get('canvasHeight')}" if layout else "n/a"
actions = [a["name"] for a in classification.get("allowedActions", [])]
print(f"L{level} {size} canvas={canvas} state={classification['state']} actions={actions}")
for evidence in classification["evidence"]:
    if "Rejected" in evidence["detail"] or evidence["kind"] == "lowConfidenceMarker":
        print("    ", evidence["detail"][:220])
PY
    [[ $(menu_enabled 放大) == true ]] || break
    menu_click 放大; sleep 1.5; level=$((level + 1))
done

while [[ $(menu_enabled 縮小) == true ]]; do menu_click 縮小; sleep 1.2; done
for ((i = 0; i < initial_steps; i++)); do menu_click 放大; sleep 1.2; done
print -r -- "restored zoom level $((initial_steps + 1)); captures in $output_dir"
