#!/bin/zsh

set -euo pipefail

readonly project_dir=${0:A:h}
readonly app_path="$project_dir/.build/Mirror Probe.app"
readonly executable_path="$app_path/Contents/MacOS/mirror-probe"
readonly expected_bundle_id="com.kuanlun.knightdragon.mirrorprobe"
readonly original_argument_count=$#

max_cycles=20
max_minutes=120
window_id=""
requested_output_dir=""
capture_level=error
legacy_talisman_flag_was_set=0
max_cycles_was_set=0
max_minutes_was_set=0
window_id_was_set=0
output_dir_was_set=0
capture_level_was_set=0
wait_for_completion=0
dry_run=0

usage() {
    print -r -- '騎士與龍 IV 自動練等啟動器'
    print -r -- ''
    print -r -- '用法：'
    print -r -- '  ./auto-level.zsh [options]'
    print -r -- ''
    print -r -- '選用參數：'
    print -r -- '  --max-cycles N       完成 N 場後停止（範圍：1–500）。'
    print -r -- '  --max-minutes N      執行 N 分鐘後停止（範圍：1–480）。'
    print -r -- '  --window-id ID       同時開啟多個鏡像視窗時指定其中一個。'
    print -r -- '  --output-dir PATH    指定尚不存在的新路徑；預設建立於 logs/。'
    print -r -- '  --capture-level LEVEL'
    print -r -- '      error（預設）正常停止不留圖；錯誤／安全停止最多保留最後 8 張；'
    print -r -- '      最後一張會命名為 final.png，所以總數仍不超過 8 張。'
    print -r -- '      info 另保留開場、結束，以及每次完成後測之操作的前後畫面。'
    print -r -- '  --wait               讓目前終端等待到程序停止；預設會在背景執行。'
    print -r -- '  --dry-run            只顯示啟動指令，不建立檔案也不開啟程式。'
    print -r -- '  --confirm-no-talisman, --no-talisman'
    print -r -- '      舊指令相容參數；可省略，程式不檢查護符使用狀態。'
    print -r -- '  -h, --help           顯示這份說明後退出；必須單獨使用。'
    print -r -- ''
    print -r -- '程式固定使用 foreground 輸入：只有需要按下已授權按鈕時，才會短暫將'
    print -r -- 'iPhone 鏡像切到前景並使用共用滑鼠，點擊後等待約一秒並擷取後測畫面，再切回原程式。'
    print -r -- '若期間偵測到你手動操作或切換程式，會取消該次切回；下次操作重新辨識目前焦點。'
    print -r -- '鏡像可被其他一般視窗完全遮住，無須保留螢幕區塊；請勿最小化或切換 Space。'
    print -r -- '切換及點擊前辨識仍會暫時佔用焦點，同時打字或移動滑鼠仍可能受影響。'
    print -r -- '若其他程式瞬間搶走前景或遮住點擊位置，會重新擷取並完整驗證，最多嘗試三次。'
    print -r -- '失敗後再次嘗試前至少等待一秒；若先到執行或操作期限，則停止而不再嘗試。'
    print -r -- '仍有遮擋時不會點擊；持續遮擋會停止，並在 log 記錄遮擋視窗的所屬程式。'
    print -r -- '原鏡像視窗暫時查不到時會停止輸入，最多查詢四次；恢復後重新辨識畫面。'
    print -r -- ''
    print -r -- '兩個限制都不指定時，預設為 20 場與 120 分鐘，先到者停止。只指定其中'
    print -r -- '一個時，另一個會提高到安全上限（500 場或 480 分鐘）。兩個都指定時，'
    print -r -- '仍是先到者停止，不會等待兩個條件同時成立。'
    print -r -- ''
    print -r -- '預設執行報告、stdout、stderr 與錯誤截圖都放在專案的 logs/。確認沒有'
    print -r -- '自動練等程序正在執行後，可以自行清空整個 logs/，不影響程式功能。'
}

fail() {
    print -u2 -r -- "錯誤：$1"
    print -u2 -r -- '請執行 ./auto-level.zsh --help 查看用法。'
    exit 2
}

runtime_fail() {
    print -u2 -r -- "執行失敗：$1"
    exit 1
}

report_field() {
    local report_path=$1
    local key=$2
    local expected_type=$3

    plutil -extract "$key" raw -expect "$expected_type" "$report_path" 2>/dev/null
}

print_wait_stderr() {
    local stderr_path=$1

    print -u2 -r -- 'Mirror Probe 回報 status=error，stderr 內容：'
    if [[ -s "$stderr_path" ]]; then
        while IFS= read -r error_line; do
            print -u2 -r -- "  $error_line"
        done < "$stderr_path"
    else
        print -u2 -r -- '  （stderr 為空）'
    fi
}

is_unsigned_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

while (( $# > 0 )); do
    case "$1" in
        --confirm-no-talisman|--no-talisman)
            (( legacy_talisman_flag_was_set == 0 )) || fail '舊版護符參數不可重複'
            legacy_talisman_flag_was_set=1
            shift
            ;;
        --max-cycles|--cycles)
            (( max_cycles_was_set == 0 )) || fail '--max-cycles 不可重複'
            (( $# >= 2 )) || fail "$1 需要一個數值"
            [[ "$2" != --* ]] || fail "$1 需要一個數值"
            max_cycles=$2
            max_cycles_was_set=1
            shift 2
            ;;
        --max-cycles=*|--cycles=*)
            (( max_cycles_was_set == 0 )) || fail '--max-cycles 不可重複'
            max_cycles=${1#*=}
            max_cycles_was_set=1
            shift
            ;;
        --max-minutes|--minutes)
            (( max_minutes_was_set == 0 )) || fail '--max-minutes 不可重複'
            (( $# >= 2 )) || fail "$1 需要一個數值"
            [[ "$2" != --* ]] || fail "$1 需要一個數值"
            max_minutes=$2
            max_minutes_was_set=1
            shift 2
            ;;
        --max-minutes=*|--minutes=*)
            (( max_minutes_was_set == 0 )) || fail '--max-minutes 不可重複'
            max_minutes=${1#*=}
            max_minutes_was_set=1
            shift
            ;;
        --window-id)
            (( window_id_was_set == 0 )) || fail '--window-id 不可重複'
            (( $# >= 2 )) || fail '--window-id 需要一個數值'
            [[ "$2" != --* ]] || fail '--window-id 需要一個數值'
            window_id=$2
            window_id_was_set=1
            shift 2
            ;;
        --window-id=*)
            (( window_id_was_set == 0 )) || fail '--window-id 不可重複'
            window_id=${1#*=}
            window_id_was_set=1
            shift
            ;;
        --output-dir)
            (( output_dir_was_set == 0 )) || fail '--output-dir 不可重複'
            (( $# >= 2 )) || fail '--output-dir 需要一個路徑'
            [[ "$2" != --* ]] || fail '--output-dir 需要一個路徑'
            requested_output_dir=$2
            output_dir_was_set=1
            shift 2
            ;;
        --output-dir=*)
            (( output_dir_was_set == 0 )) || fail '--output-dir 不可重複'
            requested_output_dir=${1#*=}
            output_dir_was_set=1
            shift
            ;;
        --capture-level)
            (( capture_level_was_set == 0 )) || fail '--capture-level 不可重複'
            (( $# >= 2 )) || fail '--capture-level 需要一個值'
            [[ "$2" != --* ]] || fail '--capture-level 需要一個值'
            capture_level=$2
            capture_level_was_set=1
            shift 2
            ;;
        --capture-level=*)
            (( capture_level_was_set == 0 )) || fail '--capture-level 不可重複'
            capture_level=${1#*=}
            [[ -n "$capture_level" ]] || fail '--capture-level 需要一個值'
            capture_level_was_set=1
            shift
            ;;
        --wait)
            (( wait_for_completion == 0 )) || fail '--wait 不可重複'
            wait_for_completion=1
            shift
            ;;
        --dry-run)
            (( dry_run == 0 )) || fail '--dry-run 不可重複'
            dry_run=1
            shift
            ;;
        -h|--help)
            (( original_argument_count == 1 )) || fail \
                '--help 只會顯示說明，不能和啟動參數一起使用；要執行請移除 --help'
            usage
            exit 0
            ;;
        *)
            fail "不支援的參數：$1"
            ;;
    esac
done

if (( window_id_was_set == 1 )) && [[ -z "$window_id" ]]; then
    fail '--window-id 需要一個數值'
fi
if (( output_dir_was_set == 1 )) && [[ -z "$requested_output_dir" ]]; then
    fail '--output-dir 需要一個路徑'
fi
if (( capture_level_was_set == 1 )) && [[ -z "$capture_level" ]]; then
    fail '--capture-level 需要一個值'
fi
case "$capture_level" in
    error|info) ;;
    *) fail '--capture-level 必須是 error 或 info' ;;
esac

if (( max_cycles_was_set == 1 && max_minutes_was_set == 0 )); then
    max_minutes=480
elif (( max_cycles_was_set == 0 && max_minutes_was_set == 1 )); then
    max_cycles=500
fi

is_unsigned_integer "$max_cycles" || fail '--max-cycles 必須是整數'
max_cycles_number=$(( 10#$max_cycles ))
(( max_cycles_number >= 1 && max_cycles_number <= 500 )) || fail \
    '--max-cycles 必須介於 1 到 500'

is_unsigned_integer "$max_minutes" || fail '--max-minutes 必須是整數'
max_minutes_number=$(( 10#$max_minutes ))
(( max_minutes_number >= 1 && max_minutes_number <= 480 )) || fail \
    '--max-minutes 必須介於 1 到 480'

if [[ -n "$window_id" ]]; then
    is_unsigned_integer "$window_id" || fail '--window-id 必須是正整數'
    window_id_number=$(( 10#$window_id ))
    (( window_id_number >= 1 && window_id_number <= 4294967295 )) || fail \
        '--window-id 必須介於 1 到 4294967295'
fi

[[ -d "$app_path" && -x "$executable_path" ]] || fail \
    '找不到已建置的 .build/Mirror Probe.app；請先執行 zsh Scripts/build-app.sh'

actual_bundle_id=$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist" 2>/dev/null) \
    || fail '無法讀取 Mirror Probe.app 的 bundle identifier'
[[ "$actual_bundle_id" == "$expected_bundle_id" ]] || fail \
    "Mirror Probe.app 的 bundle identifier 不正確：$actual_bundle_id"
codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || fail \
    'Mirror Probe.app 的簽章驗證失敗；請重新執行 zsh Scripts/build-app.sh'

run_stamp=$(date +%Y%m%d-%H%M%S)
if [[ -n "$requested_output_dir" ]]; then
    if [[ "$requested_output_dir" == /* ]]; then
        run_dir="$requested_output_dir"
    else
        run_dir="$PWD/$requested_output_dir"
    fi
    while [[ "$run_dir" != / && "$run_dir" == */ ]]; do
        run_dir=${run_dir%/}
    done
else
    run_dir="$project_dir/logs/auto-level-$run_stamp.XXXXXX"
fi

runner_arguments=(
    run
    --confirm AUTO_LEVEL
    --input-mode foreground
    --max-cycles "$max_cycles_number"
    --max-minutes "$max_minutes_number"
    --capture-level "$capture_level"
)
if [[ -n "$window_id" ]]; then
    runner_arguments+=(--window-id "$window_id_number")
fi

if (( dry_run == 1 )); then
    if [[ -z "$requested_output_dir" ]]; then
        run_dir=${run_dir//.XXXXXX/.DRYRUN}
    fi
    stdout_log="$run_dir.stdout.log"
    stderr_log="$run_dir.stderr.log"
    runner_arguments+=(--output-dir "$run_dir")
    open_arguments=(-g -n -o "$stdout_log" --stderr "$stderr_log")
    (( wait_for_completion == 1 )) && open_arguments+=(-W)
    printf 'DRY RUN：'
    printf '%q ' open "${open_arguments[@]}" "$app_path" --args "${runner_arguments[@]}"
    printf '\n'
    exit 0
fi

if [[ -z "$requested_output_dir" ]]; then
    mkdir -p "$project_dir/logs"
    run_dir=$(mktemp -d "$run_dir")
else
    [[ ! -e "$run_dir" ]] || fail "--output-dir 必須是尚不存在的新路徑：$run_dir"
    mkdir -p "${run_dir:h}"
    mkdir "$run_dir" 2>/dev/null || fail \
        "無法獨占建立 --output-dir（可能有另一個程序同時使用）：$run_dir"
fi

stdout_log="$run_dir.stdout.log"
stderr_log="$run_dir.stderr.log"
[[ ! -e "$stdout_log" && ! -e "$stderr_log" ]] || fail \
    '預定的 stdout/stderr 紀錄檔已存在，請改用另一個 --output-dir'

runner_arguments+=(--output-dir "$run_dir")
open_arguments=(-g -n -o "$stdout_log" --stderr "$stderr_log")
(( wait_for_completion == 1 )) && open_arguments+=(-W)

print -r -- "紀錄：$run_dir"
print -r -- "報告：$run_dir/run-report.json"
print -r -- "標準輸出：$stdout_log"
print -r -- "錯誤：$stderr_log"
printf '停止指令：'
printf '%q ' touch "$run_dir/STOP"
printf '\n'

open_status=0
open "${open_arguments[@]}" "$app_path" --args "${runner_arguments[@]}" || open_status=$?

if (( wait_for_completion == 1 )) && [[ ! -f "$run_dir/run-report.json" ]]; then
    if [[ -s "$stderr_log" ]]; then
        print -u2 -r -- 'Mirror Probe 未能建立執行報告，錯誤內容：'
        while IFS= read -r error_line; do
            print -u2 -r -- "  $error_line"
        done < "$stderr_log"
    fi
    runtime_fail "未建立 $run_dir/run-report.json"
fi

if (( wait_for_completion == 1 )); then
    report_path="$run_dir/run-report.json"
    report_status=$(report_field "$report_path" status string) \
        || runtime_fail "執行報告缺少有效的 status：$report_path"
    report_completed_cycles=$(report_field "$report_path" completedCycles integer) \
        || runtime_fail "執行報告缺少有效的 completedCycles：$report_path"
    report_actions_posted=$(report_field "$report_path" actionsPosted integer) \
        || runtime_fail "執行報告缺少有效的 actionsPosted：$report_path"
    report_final_reason=$(report_field "$report_path" finalReason string) \
        || runtime_fail "執行報告缺少有效的 finalReason：$report_path"

    is_unsigned_integer "$report_completed_cycles" \
        || runtime_fail "執行報告的 completedCycles 不是非負整數：$report_completed_cycles"
    is_unsigned_integer "$report_actions_posted" \
        || runtime_fail "執行報告的 actionsPosted 不是非負整數：$report_actions_posted"
    [[ -n "$report_final_reason" ]] \
        || runtime_fail '執行報告的 finalReason 不可為空'

    print -r -- '執行結果：'
    print -r -- "  status: $report_status"
    print -r -- "  completedCycles: $report_completed_cycles"
    print -r -- "  actionsPosted: $report_actions_posted"
    print -r -- "  finalReason: $report_final_reason"

    case "$report_status" in
        completed|stopped)
            exit 0
            ;;
        error)
            print_wait_stderr "$stderr_log"
            runtime_fail "$report_final_reason"
            ;;
        *)
            runtime_fail "執行報告的 status 不是 completed、stopped 或 error：$report_status"
            ;;
    esac
fi

(( open_status == 0 )) || runtime_fail "open 指令失敗（狀態碼 $open_status）"
