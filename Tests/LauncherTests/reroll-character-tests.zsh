#!/bin/zsh

set -euo pipefail

readonly project_dir=${0:A:h:h:h}
readonly test_dir=$(mktemp -d "${TMPDIR:-/tmp}/reroll-character-tests.XXXXXX")
readonly isolated_project="$test_dir/project with spaces 'quote'"
readonly app_path="$isolated_project/.build/Mirror Probe.app"
trap 'rm -rf -- "$test_dir"' EXIT

# Never start the application: open and codesign resolve only to these stubs.
# A project path containing spaces and quotes also exercises argument boundaries.
mkdir -p "$test_dir/bin" "$app_path/Contents/MacOS"
cp "$project_dir/reroll-character.zsh" "$isolated_project/reroll-character.zsh"
print -r -- '#!/bin/zsh
exit 99' > "$app_path/Contents/MacOS/mirror-probe"
chmod +x "$app_path/Contents/MacOS/mirror-probe"
print -r -- '{"CFBundleIdentifier":"com.kuanlun.knightdragon.mirrorprobe"}' \
    > "$app_path/Contents/Info.plist"
cat > "$test_dir/bin/codesign" <<'STUB'
#!/bin/zsh
exit "${MIRROR_PROBE_TEST_CODESIGN_EXIT:-0}"
STUB
cat > "$test_dir/bin/open" <<'STUB'
#!/bin/zsh
set -euo pipefail
printf '%s\0' "$@" > "$MIRROR_PROBE_TEST_ARGUMENTS"
report_path=""
stdout_path=""
stderr_path=""
stop_path=""
while (( $# > 0 )); do
    case "$1" in
        --report) report_path=$2; shift 2 ;;
        -o) stdout_path=$2; shift 2 ;;
        --stderr) stderr_path=$2; shift 2 ;;
        --stop-file) stop_path=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$report_path" && -n "$stdout_path" && -n "$stderr_path" ]] || exit 98
if [[ "${MIRROR_PROBE_TEST_WAIT_FOR_STOP:-0}" == 1 ]]; then
    for attempt in {1..100}; do
        [[ -f "$stop_path" ]] && break
        sleep 0.05
    done
    [[ -f "$stop_path" ]] || exit 97
fi
if [[ -s "$MIRROR_PROBE_TEST_REPORT" ]]; then
    cp "$MIRROR_PROBE_TEST_REPORT" "$report_path"
fi
print -rn -- "$MIRROR_PROBE_TEST_STDOUT" > "$stdout_path"
print -rn -- "$MIRROR_PROBE_TEST_STDERR" > "$stderr_path"
exit "$MIRROR_PROBE_TEST_OPEN_EXIT"
STUB
chmod +x "$test_dir/bin/open" "$test_dir/bin/codesign"

case_count=0
output=""
run_case() {
    local name=$1 expected_exit=$2 report=$3 open_exit=$4
    shift 4
    local actual_exit=0
    print -rn -- "$report" > "$test_dir/report.json"
    rm -f "$test_dir/arguments"
    output=$(PATH="$test_dir/bin:$PATH" \
        MIRROR_PROBE_TEST_REPORT="$test_dir/report.json" \
        MIRROR_PROBE_TEST_ARGUMENTS="$test_dir/arguments" \
        MIRROR_PROBE_TEST_STDOUT='stub runtime summary' \
        MIRROR_PROBE_TEST_STDERR='stub runtime diagnostic' \
        MIRROR_PROBE_TEST_OPEN_EXIT="$open_exit" \
        /bin/zsh "$isolated_project/reroll-character.zsh" "$@" 2>&1) || actual_exit=$?
    if (( actual_exit != expected_exit )); then
        print -u2 -r -- "FAIL $name: expected exit $expected_exit, got $actual_exit"
        print -u2 -r -- "$output"
        exit 1
    fi
    (( case_count += 1 ))
}

run_argument_case() {
    local name=$1 expected_exit=$2
    shift 2
    run_case "$name" "$expected_exit" '' 98 "$@"
    [[ ! -e "$test_dir/arguments" ]] || {
        print -u2 -r -- "FAIL $name: argument validation or dry run invoked open"
        exit 1
    }
}

assert_contains() {
    [[ "$output" == *"$1"* ]] || {
        print -u2 -r -- "FAIL expected output containing: $1"
        print -u2 -r -- "$output"
        exit 1
    }
}

assert_omits() {
    [[ "$output" != *"$1"* ]] || {
        print -u2 -r -- "FAIL unexpected output containing: $1"
        print -u2 -r -- "$output"
        exit 1
    }
}

run_argument_case defaults 0 --dry-run
assert_contains 'open -g -W -n '
assert_contains '--args reroll-character --confirm CHARACTER_REROLL '
assert_contains '--minimum-total 90 --max-rerolls 500 --max-minutes 10 '
assert_omits '--window-id'
assert_omits '--report'
assert_omits '--stop-file'

run_argument_case limits_and_leading_zeros 0 --dry-run --minimum-total=00100 \
    --max-rerolls 05000 --max-minutes=00060 --window-id 0004294967295
assert_contains '--minimum-total 100 --max-rerolls 5000 --max-minutes 60 --window-id 4294967295 '
run_argument_case lower_bounds 0 --dry-run --minimum-total 90 --max-rerolls=1 \
    --max-minutes 1 --window-id=1
assert_contains '--minimum-total 90 --max-rerolls 1 --max-minutes 1 --window-id 1 '
run_argument_case many_leading_zeros 0 --dry-run \
    --minimum-total 00000000000000000000000000000000000000090
assert_contains '--minimum-total 90 '
[[ ! -e "$isolated_project/logs" ]] || {
    print -u2 -r -- 'FAIL dry run created logs'
    exit 1
}

for flag in --minimum-total --max-rerolls --max-minutes --window-id; do
    for value in '' -1 +1 1.5 1e2 NaN inf ' 90' '90 '; do
        run_argument_case "invalid_${flag}_${value}" 2 --dry-run "$flag=$value"
        assert_contains "$flag 必須是"
    done
    run_argument_case "missing_$flag" 2 --dry-run "$flag"
    assert_contains "$flag 需要一個數值"
    run_argument_case "missing_before_option_$flag" 2 "$flag" --dry-run
    assert_contains "$flag 需要一個數值"
done
for pair in '--minimum-total=89' '--minimum-total=101' '--max-rerolls=0' \
    '--max-rerolls=5001' '--max-minutes=0' '--max-minutes=61' '--window-id=0' \
    '--window-id=4294967296'; do
    run_argument_case "out_of_range_$pair" 2 --dry-run "$pair"
    assert_contains '必須介於'
done

# Values exceeding zsh's integer precision must never become accepted limits.
for pair in '--minimum-total=18446744073709551706' \
    '--max-rerolls=18446744073709551617' '--max-minutes=18446744073709551617' \
    '--window-id=18446744073709551617'; do
    run_argument_case "overflow_$pair" 2 --dry-run "$pair"
    assert_contains '必須介於'
done

run_argument_case unknown_option 2 --dry-run --unknown
assert_contains '不支援的參數：--unknown'
run_argument_case duplicate_dry_run 2 --dry-run --dry-run
assert_contains '--dry-run 不可重複'
for flag in --minimum-total --max-rerolls --max-minutes --window-id; do
    run_argument_case "duplicate_$flag" 2 --dry-run "$flag" 90 "$flag=90"
    assert_contains "$flag 不可重複"
done

for help_flag in --help -h; do
    run_argument_case help 0 "$help_flag"
    assert_contains '用法：'
    assert_contains '--minimum-total N'
    assert_omits 'DRY RUN'
done

run_case completed 0 '{"status":"completed","finalTotal":93,"rerollsPosted":7}' 0 \
    --minimum-total 92 --max-rerolls 10 --max-minutes 2 --window-id 123
assert_contains '完成：total=93（共重擲 7 次）'
assert_contains 'stub runtime summary'
assert_contains 'stub runtime diagnostic'
python3 - "$test_dir/arguments" "$app_path" "$isolated_project/logs" <<'PY'
import pathlib
import sys

arguments = pathlib.Path(sys.argv[1]).read_bytes().decode().split('\0')[:-1]
app = str(pathlib.Path(sys.argv[2]).resolve())
logs = pathlib.Path(sys.argv[3]).resolve()
assert arguments[:4] == ['-g', '-W', '-n', '-o'], arguments
assert arguments[5] == '--stderr', arguments
assert arguments[7:19] == [
    app, '--args', 'reroll-character', '--confirm', 'CHARACTER_REROLL',
    '--minimum-total', '92', '--max-rerolls', '10', '--max-minutes', '2', '--window-id',
], arguments
assert arguments[19] == '123', arguments
assert arguments[20] == '--report' and arguments[22] == '--stop-file', arguments
assert len(arguments) == 24, arguments
report = pathlib.Path(arguments[21]).resolve()
stop = pathlib.Path(arguments[23]).resolve()
assert report.parent.parent == logs and report.name == 'run-report.json', arguments
assert stop.parent == report.parent and stop.name == 'STOP', arguments
assert pathlib.Path(arguments[4]).resolve() == report.parent / 'stdout.log', arguments
assert pathlib.Path(arguments[6]).resolve() == report.parent / 'stderr.log', arguments
assert not stop.exists(), arguments
PY

run_case completed_disagreeing_high_totals 0 '{"status":"completed","rerollsPosted":3}' 0
assert_contains '兩路 OCR 均已達 total >= 90（讀值不同；共重擲 3 次）'
for report_status in stopped limitReached error; do
    run_case "$report_status" 1 "{\"status\":\"$report_status\",\"finalTotal\":88,\"rerollsPosted\":4}" 0
    assert_contains "未達標：status=$report_status，最後 total=88，已重擲 4 次"
done
run_case incomplete_report 1 '{"status":"running","rerollsPosted":4}' 0
assert_contains '執行報告尚未封口：status=running'
run_case malformed_report 1 '{invalid json' 0
assert_contains '執行報告尚未封口：status=missing'
run_case missing_report 2 '' 0
assert_contains '程式結束但沒有產生執行報告'
run_case open_failure 7 '' 7
assert_contains 'stub runtime diagnostic'
run_case open_failure_with_completed_report 7 '{"status":"completed","finalTotal":95,"rerollsPosted":1}' 7
assert_contains 'open 指令失敗（狀態碼 7）'
assert_omits '完成：'

# An interrupted wait is not the child's exit code. The launcher must write
# STOP, reap the fake child, then honor its successful terminal report.
python3 - "$test_dir" "$isolated_project" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, project = map(Path, sys.argv[1:])
arguments_path = root / 'signal-arguments'
report_path = root / 'signal-report.json'
report_path.write_text(json.dumps({'status': 'completed', 'finalTotal': 95, 'rerollsPosted': 1}))
environment = dict(os.environ, **{
    'PATH': str(root / 'bin') + ':' + os.environ['PATH'],
    'MIRROR_PROBE_TEST_REPORT': str(report_path),
    'MIRROR_PROBE_TEST_ARGUMENTS': str(arguments_path),
    'MIRROR_PROBE_TEST_STDOUT': '', 'MIRROR_PROBE_TEST_STDERR': '',
    'MIRROR_PROBE_TEST_OPEN_EXIT': '0', 'MIRROR_PROBE_TEST_WAIT_FOR_STOP': '1',
})
process = subprocess.Popen(
    ['/bin/zsh', str(project / 'reroll-character.zsh')],
    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
try:
    deadline = time.monotonic() + 5
    while not arguments_path.exists():
        if process.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError('Launcher failed to reach fake open before signal test timeout')
        time.sleep(0.01)
    process.send_signal(signal.SIGTERM)
    stdout, stderr = process.communicate(timeout=8)
    assert process.returncode == 0, (process.returncode, stdout, stderr)
    assert '已收到中斷訊號；已建立 STOP' in stderr, stderr
    assert '完成：total=95' in stdout, stdout
    arguments = arguments_path.read_bytes().decode().split('\0')[:-1]
    assert Path(arguments[arguments.index('--stop-file') + 1]).is_file(), arguments
finally:
    if process.poll() is None:
        process.kill()
        process.communicate()
PY
(( case_count += 1 ))

# App validation also stays offline and must run before creating a log directory.
export MIRROR_PROBE_TEST_CODESIGN_EXIT=1
run_argument_case invalid_signature 2 --dry-run
assert_contains '簽章驗證失敗'
unset MIRROR_PROBE_TEST_CODESIGN_EXIT
print -r -- '{"CFBundleIdentifier":"wrong.bundle"}' > "$app_path/Contents/Info.plist"
run_argument_case invalid_bundle_identifier 2 --dry-run
assert_contains 'bundle identifier 不正確：wrong.bundle'
print -r -- 'invalid plist' > "$app_path/Contents/Info.plist"
run_argument_case unreadable_bundle_identifier 2 --dry-run
assert_contains '無法讀取 Mirror Probe.app 的 bundle identifier'
rm "$app_path/Contents/MacOS/mirror-probe"
run_argument_case missing_app 2 --dry-run
assert_contains '找不到已建置的 .build/Mirror Probe.app'
run_argument_case help_without_app 0 --help
assert_contains '用法：'

print -r -- "PASS: $case_count reroll launcher argument/report cases (no app launched)"
