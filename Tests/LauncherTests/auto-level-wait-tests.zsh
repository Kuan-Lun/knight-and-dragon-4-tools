#!/bin/zsh

set -euo pipefail

readonly project_dir=${0:A:h:h:h}
readonly test_dir=$(mktemp -d "${TMPDIR:-/tmp}/auto-level-wait-tests.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

# Run an isolated copy of the launcher with fake open/codesign commands.
# These tests never launch Mirror Probe or send input to the game.
mkdir -p "$test_dir/bin" "$test_dir/project/.build/Mirror Probe.app/Contents/MacOS"
cp "$project_dir/auto-level.zsh" "$test_dir/project/auto-level.zsh"
print -r -- '#!/bin/zsh' > "$test_dir/project/.build/Mirror Probe.app/Contents/MacOS/mirror-probe"
chmod +x "$test_dir/project/.build/Mirror Probe.app/Contents/MacOS/mirror-probe"
print -r -- '{"CFBundleIdentifier":"com.kuanlun.knightdragon.mirrorprobe"}' \
    > "$test_dir/project/.build/Mirror Probe.app/Contents/Info.plist"
print -r -- '#!/bin/zsh
exit 0' > "$test_dir/bin/codesign"
cat > "$test_dir/bin/open" <<'STUB'
#!/bin/zsh
set -euo pipefail
output_dir=""
stderr_path=""
while (( $# > 0 )); do
    case "$1" in
        --output-dir) output_dir=$2; shift 2 ;;
        --stderr) stderr_path=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -s "$MIRROR_PROBE_TEST_REPORT" ]]; then
    cp "$MIRROR_PROBE_TEST_REPORT" "$output_dir/run-report.json"
fi
print -rn -- "$MIRROR_PROBE_TEST_STDERR" > "$stderr_path"
exit "$MIRROR_PROBE_TEST_OPEN_EXIT"
STUB
chmod +x "$test_dir/bin/open" "$test_dir/bin/codesign"

case_count=0
output=""
run_case() {
    local name=$1 expected_exit=$2 report=$3 open_exit=${4:-0} stderr_text=${5:-}
    local actual_exit=0
    print -rn -- "$report" > "$test_dir/report.json"
    output=$(PATH="$test_dir/bin:$PATH" \
        MIRROR_PROBE_TEST_REPORT="$test_dir/report.json" \
        MIRROR_PROBE_TEST_STDERR="$stderr_text" \
        MIRROR_PROBE_TEST_OPEN_EXIT="$open_exit" \
        /bin/zsh "$test_dir/project/auto-level.zsh" --wait \
        --output-dir "$test_dir/$name" 2>&1) || actual_exit=$?
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
    local actual_exit=0
    output=$(PATH="$test_dir/bin:$PATH" \
        /bin/zsh "$test_dir/project/auto-level.zsh" "$@" 2>&1) || actual_exit=$?
    if (( actual_exit != expected_exit )); then
        print -u2 -r -- "FAIL $name: expected exit $expected_exit, got $actual_exit"
        print -u2 -r -- "$output"
        exit 1
    fi
    (( case_count += 1 ))
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

run_case unfinished 1 '{"status":"running","completedCycles":16,"actionsPosted":86}' 0 'last runtime diagnostic'
assert_contains '程序未留下結束報告'
assert_contains 'completedCycles=16，actionsPosted=86'
assert_contains 'last runtime diagnostic'
assert_omits '缺少有效的 finalReason'

run_case unfinished_empty_stderr 1 '{"status":"running","completedCycles":0,"actionsPosted":0}'
assert_contains '程序未留下結束報告'
assert_omits 'stderr 最後 20 行'

run_case completed 0 '{"status":"completed","completedCycles":20,"actionsPosted":100,"finalReason":"maximumCyclesReached"}'
assert_contains 'status: completed'
assert_contains 'finalReason: maximumCyclesReached'
assert_contains '尚無時間統計（舊版報告或未提供）'
assert_omits 'averageCycleSeconds'

run_case decimal_timing 0 '{"status":"stopped","completedCycles":2,"actionsPosted":10,"finalReason":"applicationQuitRequested","startedAt":"2026-09-17T10:00:00Z","endedAt":"2026-09-17T11:01:01Z","timing":{"elapsedSeconds":3661.25,"completedCycleCount":2,"completedCycleTotalSeconds":3640.5,"averageCycleSeconds":1820.25,"medianCycleSeconds":1820.25,"fastestCycleSeconds":60.25,"slowestCycleSeconds":3580.25,"lastCycleSeconds":3580.25,"secondsSinceLastCycle":20.75,"cyclesPerHour":1.96654}}'
assert_contains 'status: stopped'
assert_contains 'startedAt (開始時間): 2026-09-17T10:00:00Z'
assert_contains 'endedAt (結束時間): 2026-09-17T11:01:01Z'
assert_contains 'elapsedSeconds (總執行時間): 1 小時 1 分 1.25 秒'
assert_contains 'completedCycleTotalSeconds (已完成場次合計耗時): 1 小時 0 分 40.50 秒'
assert_contains 'averageCycleSeconds (平均每場耗時): 30 分 20.25 秒'
assert_contains 'medianCycleSeconds (每場耗時中位數): 30 分 20.25 秒'
assert_contains 'fastestCycleSeconds (最快一場耗時): 1 分 0.25 秒'
assert_contains 'slowestCycleSeconds (最慢一場耗時): 59 分 40.25 秒'
assert_contains 'lastCycleSeconds (最後一場耗時): 59 分 40.25 秒'
assert_contains 'secondsSinceLastCycle (最後一場完成後經過時間): 20.75 秒'
assert_contains 'cyclesPerHour (每小時完成場次): 1.97 場／小時'
assert_contains '首場由本次程序開始時計算，可能是不完整的一場'
assert_contains '平均與中位數只計已完成場次，不含最後尚未完成的時間'
assert_omits '尚無資料'

run_case integer_timing 0 '{"status":"completed","completedCycles":2,"actionsPosted":10,"finalReason":"maximumCyclesReached","timing":{"elapsedSeconds":120,"completedCycleCount":2,"completedCycleTotalSeconds":120,"averageCycleSeconds":60,"medianCycleSeconds":60,"fastestCycleSeconds":60,"slowestCycleSeconds":60,"lastCycleSeconds":60,"secondsSinceLastCycle":0,"cyclesPerHour":60}}'
assert_contains 'elapsedSeconds (總執行時間): 2 分 0.00 秒'
assert_contains 'averageCycleSeconds (平均每場耗時): 1 分 0.00 秒'
assert_contains 'medianCycleSeconds (每場耗時中位數): 1 分 0.00 秒'
assert_contains 'secondsSinceLastCycle (最後一場完成後經過時間): 0.00 秒'
assert_contains 'cyclesPerHour (每小時完成場次): 60.00 場／小時'
assert_omits '尚無資料'

run_case legacy_timing_without_median 0 '{"status":"completed","completedCycles":2,"actionsPosted":10,"finalReason":"maximumCyclesReached","timing":{"elapsedSeconds":120,"completedCycleCount":2,"completedCycleTotalSeconds":120,"averageCycleSeconds":60,"fastestCycleSeconds":60,"slowestCycleSeconds":60,"lastCycleSeconds":60,"secondsSinceLastCycle":0,"cyclesPerHour":60}}'
assert_contains 'averageCycleSeconds (平均每場耗時): 1 分 0.00 秒'
assert_contains 'medianCycleSeconds (每場耗時中位數): 尚無資料'
assert_contains 'fastestCycleSeconds (最快一場耗時): 1 分 0.00 秒'
assert_omits '尚無時間統計（舊版報告或未提供）'

run_case zero_cycles_timing 0 '{"status":"stopped","completedCycles":0,"actionsPosted":0,"finalReason":"stopFileDetected","timing":{"elapsedSeconds":12.5,"completedCycleCount":0,"completedCycleTotalSeconds":0,"averageCycleSeconds":null,"medianCycleSeconds":null,"fastestCycleSeconds":null,"slowestCycleSeconds":null,"lastCycleSeconds":null,"secondsSinceLastCycle":null,"cyclesPerHour":0}}'
assert_contains 'elapsedSeconds (總執行時間): 12.50 秒'
assert_contains 'completedCycleTotalSeconds (已完成場次合計耗時): 0.00 秒'
assert_contains 'averageCycleSeconds (平均每場耗時): 尚無資料'
assert_contains 'medianCycleSeconds (每場耗時中位數): 尚無資料'
assert_contains 'fastestCycleSeconds (最快一場耗時): 尚無資料'
assert_contains 'slowestCycleSeconds (最慢一場耗時): 尚無資料'
assert_contains 'lastCycleSeconds (最後一場耗時): 尚無資料'
assert_contains 'secondsSinceLastCycle (最後一場完成後經過時間): 尚無資料'
assert_contains 'cyclesPerHour (每小時完成場次): 0.00 場／小時'

run_case zero_elapsed_timing 0 '{"status":"stopped","completedCycles":0,"actionsPosted":0,"finalReason":"stopFileDetected","timing":{"elapsedSeconds":0,"completedCycleCount":0,"completedCycleTotalSeconds":0}}'
assert_contains 'elapsedSeconds (總執行時間): 0.00 秒'
assert_contains 'averageCycleSeconds (平均每場耗時): 尚無資料'
assert_contains 'medianCycleSeconds (每場耗時中位數): 尚無資料'
assert_contains 'cyclesPerHour (每小時完成場次): 尚無資料'

run_case rounded_duration_timing 0 '{"status":"completed","completedCycles":1,"actionsPosted":1,"finalReason":"maximumCyclesReached","timing":{"elapsedSeconds":60,"completedCycleCount":1,"completedCycleTotalSeconds":59.999,"averageCycleSeconds":59.999,"medianCycleSeconds":59.999,"fastestCycleSeconds":59.999,"slowestCycleSeconds":59.999,"lastCycleSeconds":59.999,"secondsSinceLastCycle":0.001,"cyclesPerHour":60}}'
assert_contains 'averageCycleSeconds (平均每場耗時): 1 分 0.00 秒'
assert_contains 'medianCycleSeconds (每場耗時中位數): 1 分 0.00 秒'
assert_contains 'secondsSinceLastCycle (最後一場完成後經過時間): 0.00 秒'

run_case invalid_optional_timing 0 '{"status":"stopped","completedCycles":1,"actionsPosted":1,"finalReason":"applicationQuitRequested","timing":{"elapsedSeconds":false,"averageCycleSeconds":"60","medianCycleSeconds":"60","fastestCycleSeconds":-1,"cyclesPerHour":"$(exit 1)"}}'
assert_contains 'elapsedSeconds (總執行時間): 尚無資料'
assert_contains 'averageCycleSeconds (平均每場耗時): 尚無資料'
assert_contains 'medianCycleSeconds (每場耗時中位數): 尚無資料'
assert_contains 'fastestCycleSeconds (最快一場耗時): 尚無資料'
assert_contains 'cyclesPerHour (每小時完成場次): 尚無資料'

run_case stopped 0 '{"status":"stopped","completedCycles":13,"actionsPosted":61,"finalReason":"uncertainStateExceededGrace(kind: unknown)"}'
assert_contains 'status: stopped'
assert_contains 'finalReason: uncertainStateExceededGrace(kind: unknown)'

run_case runtime_error 1 '{"status":"error","completedCycles":2,"actionsPosted":10,"finalReason":"capture failed","timing":{"elapsedSeconds":20.5,"completedCycleCount":2,"completedCycleTotalSeconds":16,"averageCycleSeconds":8,"medianCycleSeconds":8,"fastestCycleSeconds":7.5,"slowestCycleSeconds":8.5,"lastCycleSeconds":8.5,"secondsSinceLastCycle":4.5,"cyclesPerHour":351.219512}}' 0 'underlying capture failure'
assert_contains 'Mirror Probe 回報 status=error'
assert_contains 'underlying capture failure'
assert_contains '執行失敗：capture failed'
assert_contains 'elapsedSeconds (總執行時間): 20.50 秒'
assert_contains 'averageCycleSeconds (平均每場耗時): 8.00 秒'
assert_contains 'medianCycleSeconds (每場耗時中位數): 8.00 秒'
[[ $(plutil -extract openWaitCompleted raw -expect bool \
    "$test_dir/runtime_error/.launcher-wait.json") == true ]] || {
    print -u2 -r -- 'FAIL app error after a successful wait must leave a completion receipt'
    exit 1
}

run_case terminal_missing_reason 1 '{"status":"stopped","completedCycles":2,"actionsPosted":10}'
assert_contains '缺少有效的 finalReason'

run_case terminal_empty_reason 1 '{"status":"stopped","completedCycles":2,"actionsPosted":10,"finalReason":""}'
assert_contains 'finalReason 不可為空'

run_case invalid_status 1 '{"status":"invalid","completedCycles":2,"actionsPosted":10}'
assert_contains 'status 不是 completed、stopped 或 error：invalid'
assert_omits '缺少有效的 finalReason'

run_case invalid_counter 1 '{"status":"running","completedCycles":-1,"actionsPosted":10}'
assert_contains 'completedCycles 不是非負整數'

run_case missing_report 1 '' 0 'failed before report creation'
assert_contains '未能建立執行報告'
assert_contains 'failed before report creation'

run_case open_failure 1 '' 7 'launch or wait failed'
assert_contains 'open 指令失敗（狀態碼 7）'
assert_contains 'launch or wait failed'

run_case open_failure_with_terminal_report 1 '{"status":"completed","completedCycles":20,"actionsPosted":100,"finalReason":"maximumCyclesReached"}' 7
assert_contains 'open 指令失敗（狀態碼 7）'
assert_omits '執行結果：'
[[ ! -e "$test_dir/open_failure_with_terminal_report/.launcher-wait.json" ]] || {
    print -u2 -r -- 'FAIL a failed open wait must never leave a completion receipt'
    exit 1
}

run_argument_case unlimited_default 0 --dry-run
assert_contains '--input-mode foreground '
assert_contains '--capture-level error '
assert_contains '--output-dir '
assert_omits '--max-cycles'
assert_omits '--max-minutes'

run_argument_case cycles_only_above_old_limit 0 --dry-run --max-cycles 501
assert_contains '--max-cycles 501 '
assert_omits '--max-minutes'

run_argument_case minutes_only_above_old_limit 0 --dry-run --max-minutes 481
assert_contains '--max-minutes 481 '
assert_omits '--max-cycles'

run_argument_case both_limits 0 --dry-run --max-cycles 2000 --max-minutes 1440
assert_contains '--max-cycles 2000 '
assert_contains '--max-minutes 1440 '

run_argument_case aliases_and_leading_zeros 0 --dry-run --cycles=000501 --minutes 000481
assert_contains '--max-cycles 501 '
assert_contains '--max-minutes 481 '

run_argument_case int_max_limits 0 --dry-run \
    --max-cycles=9223372036854775807 --max-minutes 0009223372036854775807
assert_contains '--max-cycles 9223372036854775807 '
assert_contains '--max-minutes 9223372036854775807 '

run_argument_case many_leading_zeros 0 --dry-run --cycles 00000000000000000000000000000000000000001
assert_contains '--max-cycles 1 '
assert_omits '--max-minutes'

for limit_flag in --max-cycles --max-minutes; do
    for invalid_value in '' 0 000 -1 +1 1.5 1e3 NaN inf ' 1' '1 '; do
        run_argument_case "invalid_${limit_flag}_${invalid_value}" 2 --dry-run "$limit_flag=$invalid_value"
        assert_contains "$limit_flag 必須是正整數"
    done
    for overflow_value in 9223372036854775808 18446744073709551617 \
        0009223372036854775808 99999999999999999999999999999999999999; do
        run_argument_case "overflow_${limit_flag}_${overflow_value}" 2 --dry-run "$limit_flag=$overflow_value"
        assert_contains "$limit_flag 不可超過 9223372036854775807"
    done
    run_argument_case "missing_$limit_flag" 2 --dry-run "$limit_flag"
    assert_contains "$limit_flag 需要一個數值"
done

run_argument_case duplicate_cycles_alias 2 --dry-run --max-cycles 1 --cycles=2
assert_contains '--max-cycles 不可重複'
run_argument_case duplicate_minutes_alias 2 --dry-run --minutes 1 --max-minutes=2
assert_contains '--max-minutes 不可重複'

run_argument_case wait_capture_and_legacy_alias 0 --dry-run --wait --capture-level info \
    --no-talisman --window-id 00123 --output-dir "$test_dir/dry-run-output"
assert_contains '-W '
assert_contains '--capture-level info '
assert_contains '--window-id 123 '
assert_contains "--output-dir $test_dir/dry-run-output"
assert_omits '--max-cycles'
assert_omits '--max-minutes'
[[ ! -e "$test_dir/dry-run-output" && ! -e "$test_dir/project/logs" ]] || {
    print -u2 -r -- 'FAIL dry run created an output directory'
    exit 1
}

run_argument_case help 0 --help
assert_contains '預設不限制場次、執行時間或操作次數'
assert_contains '只指定其中一個限制時，另一個仍不限制'
assert_omits '1–500'
assert_omits '1–480'

print -r -- "PASS: $case_count launcher wait/report and argument regression cases (no app launched)"
