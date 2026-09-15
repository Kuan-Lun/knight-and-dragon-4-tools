#!/bin/zsh

set -euo pipefail
setopt NO_BG_NICE

readonly project_dir=${0:A:h}
readonly app_path="$project_dir/.build/Mirror Probe.app"
readonly executable_path="$app_path/Contents/MacOS/mirror-probe"
readonly expected_bundle_id="com.kuanlun.knightdragon.mirrorprobe"

minimum_total=90
max_rerolls=500
max_minutes=10
window_id=""
dry_run=0

usage() {
    print -r -- '騎士與龍 IV 自訂創角自動重擲'
    print -r -- ''
    print -r -- '用法：'
    print -r -- '  ./reroll-character.zsh [options]'
    print -r -- ''
    print -r -- '請先在 iPhone 鏡像中停留於自訂創角頁。程式只會在完整辨識頁面、'
    print -r -- '兩路 total OCR 與實際數字字形長度一致、畫面穩定，且 total 小於門檻時'
    print -r -- '按右上角「隨機」。預設門檻為 90；低側兩路 OCR 數值不同時會安全停止。'
    print -r -- '執行期間請維持鏡像在前景，不要切換程式；點擊後會留在鏡像，不切回原程式。'
    print -r -- '鏡像已在前景時會略過切換與切換後等待；請勿移動或縮放鏡像視窗。'
    print -r -- ''
    print -r -- '選用參數：'
    print -r -- '  --minimum-total N   目標門檻（預設 90，範圍 90–100）。'
    print -r -- '  --max-rerolls N     最多重擲 N 次（預設 500，範圍 1–5000）。'
    print -r -- '  --max-minutes N     最多執行 N 分鐘（預設 10，範圍 1–60）。'
    print -r -- '  --window-id ID      同時開啟多個鏡像視窗時指定其中一個。'
    print -r -- '  --dry-run           只顯示啟動指令，不建立紀錄也不啟動。'
    print -r -- '  -h, --help          顯示說明。'
}

fail() {
    print -u2 -r -- "錯誤：$1"
    print -u2 -r -- '請執行 ./reroll-character.zsh --help 查看用法。'
    exit 2
}

is_unsigned_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

while (( $# > 0 )); do
    case "$1" in
        --minimum-total)
            (( $# >= 2 )) || fail '--minimum-total 需要一個數值'
            minimum_total=$2
            shift 2
            ;;
        --minimum-total=*)
            minimum_total=${1#*=}
            shift
            ;;
        --max-rerolls)
            (( $# >= 2 )) || fail '--max-rerolls 需要一個數值'
            max_rerolls=$2
            shift 2
            ;;
        --max-rerolls=*)
            max_rerolls=${1#*=}
            shift
            ;;
        --max-minutes)
            (( $# >= 2 )) || fail '--max-minutes 需要一個數值'
            max_minutes=$2
            shift 2
            ;;
        --max-minutes=*)
            max_minutes=${1#*=}
            shift
            ;;
        --window-id)
            (( $# >= 2 )) || fail '--window-id 需要一個數值'
            window_id=$2
            shift 2
            ;;
        --window-id=*)
            window_id=${1#*=}
            shift
            ;;
        --dry-run)
            (( dry_run == 0 )) || fail '--dry-run 不可重複'
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "不支援的參數：$1"
            ;;
    esac
done

is_unsigned_integer "$minimum_total" || fail '--minimum-total 必須是整數'
minimum_total_number=$(( 10#$minimum_total ))
(( minimum_total_number >= 90 && minimum_total_number <= 100 )) || fail \
    '--minimum-total 必須介於 90 到 100'

is_unsigned_integer "$max_rerolls" || fail '--max-rerolls 必須是整數'
max_rerolls_number=$(( 10#$max_rerolls ))
(( max_rerolls_number >= 1 && max_rerolls_number <= 5000 )) || fail \
    '--max-rerolls 必須介於 1 到 5000'

is_unsigned_integer "$max_minutes" || fail '--max-minutes 必須是整數'
max_minutes_number=$(( 10#$max_minutes ))
(( max_minutes_number >= 1 && max_minutes_number <= 60 )) || fail \
    '--max-minutes 必須介於 1 到 60'

if [[ -n "$window_id" ]]; then
    is_unsigned_integer "$window_id" || fail '--window-id 必須是正整數'
    window_id_number=$(( 10#$window_id ))
    (( window_id_number >= 1 && window_id_number <= 4294967295 )) || fail \
        '--window-id 必須介於 1 到 4294967295'
fi

[[ -d "$app_path" && -x "$executable_path" ]] || fail \
    '找不到已建置的 .build/Mirror Probe.app；請先執行 zsh scripts/build-app.sh'
actual_bundle_id=$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist" 2>/dev/null) \
    || fail '無法讀取 Mirror Probe.app 的 bundle identifier'
[[ "$actual_bundle_id" == "$expected_bundle_id" ]] || fail \
    "Mirror Probe.app 的 bundle identifier 不正確：$actual_bundle_id"
codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || fail \
    'Mirror Probe.app 的簽章驗證失敗；請重新執行 zsh scripts/build-app.sh'

runner_arguments=(
    reroll-character
    --confirm CHARACTER_REROLL
    --minimum-total "$minimum_total_number"
    --max-rerolls "$max_rerolls_number"
    --max-minutes "$max_minutes_number"
)
if [[ -n "$window_id" ]]; then
    runner_arguments+=(--window-id "$window_id_number")
fi

if (( dry_run == 1 )); then
    printf 'DRY RUN：'
    printf '%q ' open -g -W -n "$app_path" --args "${runner_arguments[@]}"
    printf '\n'
    exit 0
fi

mkdir -p "$project_dir/logs"
run_stamp=$(date +%Y%m%d-%H%M%S)
run_dir=$(mktemp -d "$project_dir/logs/character-reroll-$run_stamp.XXXXXX")
report_path="$run_dir/run-report.json"
stdout_path="$run_dir/stdout.log"
stderr_path="$run_dir/stderr.log"
stop_path="$run_dir/STOP"
runner_arguments+=(--report "$report_path" --stop-file "$stop_path")

signal_stop_requested=0
request_stop() {
    signal_stop_requested=1
    touch "$stop_path"
    print -u2 -r -- "已收到中斷訊號；已建立 STOP，正等待目前的安全檢查結束。"
}
trap request_stop INT TERM HUP

print -r -- "紀錄：$run_dir"
print -r -- "停止：touch ${(q)stop_path}"

open_status=0
open_wait_complete=0
(
    # Keep the LaunchServices waiter alive when Ctrl-C targets the whole process group. The
    # parent handles the signal by writing STOP, then reaps this proxy after the app exits.
    trap '' INT TERM HUP
    exec open -g -W -n -o "$stdout_path" --stderr "$stderr_path" \
        "$app_path" --args "${runner_arguments[@]}"
) &
open_pid=$!
if wait "$open_pid"; then
    open_wait_complete=1
else
    open_status=$?
    if ! kill -0 "$open_pid" 2>/dev/null; then
        open_wait_complete=1
    fi
fi

if (( signal_stop_requested == 1 && open_wait_complete == 0 )); then
    for _ in {1..60}; do
        if ! kill -0 "$open_pid" 2>/dev/null; then
            wait "$open_pid" || open_status=$?
            open_wait_complete=1
            break
        fi
        sleep 0.25
    done
    if (( open_wait_complete == 0 )); then
        print -u2 -r -- \
            'STOP 已建立，但程式在 15 秒內尚未完成安全收尾；請查看本次紀錄。'
        kill -KILL "$open_pid" 2>/dev/null || true
        wait "$open_pid" 2>/dev/null || true
        open_wait_complete=1
    fi
fi
trap - INT TERM HUP

if [[ -s "$stdout_path" ]]; then
    print -r -- '結果：'
    sed 's/^/  /' "$stdout_path"
fi
if [[ -s "$stderr_path" ]]; then
    print -u2 -r -- '錯誤：'
    sed 's/^/  /' "$stderr_path" >&2
fi

if [[ -f "$report_path" ]]; then
    run_status=$(plutil -extract status raw -expect string "$report_path" 2>/dev/null || true)
    final_total=$(plutil -extract finalTotal raw -expect integer "$report_path" 2>/dev/null || true)
    rerolls=$(plutil -extract rerollsPosted raw -expect integer "$report_path" 2>/dev/null || true)
    candidate_path=$(plutil -extract candidateImage.path raw -expect string \
        "$report_path" 2>/dev/null || true)
    candidate_role=$(plutil -extract candidateImage.role raw -expect string \
        "$report_path" 2>/dev/null || true)
    if [[ -n "$candidate_path" && -f "$candidate_path" ]]; then
        case "$candidate_role" in
            finalStable) candidate_label='達標穩定畫面' ;;
            lastVerifiedStable) candidate_label='最後確認穩定畫面' ;;
            preClickFallback) candidate_label='已送出點擊前的備援畫面' ;;
            latestPreClickUnverified) candidate_label='點擊前最新未驗證畫面' ;;
            latestPostClickUnverified) candidate_label='點擊後最新未驗證畫面' ;;
            *) candidate_label='終止畫面' ;;
        esac
        print -r -- "$candidate_label：$candidate_path"
    else
        print -u2 -r -- '警告：本次沒有可保存的終止畫面。'
    fi
    if [[ "$run_status" == completed ]]; then
        if [[ -n "$final_total" ]]; then
            print -r -- "完成：total=$final_total（共重擲 $rerolls 次）"
        else
            print -r -- \
                "完成：兩路 OCR 均已達 total >= $minimum_total_number（讀值不同；共重擲 $rerolls 次）"
        fi
        exit 0
    fi
    case "$run_status" in
        stopped|limitReached|error) ;;
        *)
            print -u2 -r -- "執行報告尚未封口：status=${run_status:-missing}"
            exit 1
            ;;
    esac
    [[ -n "$final_total" ]] || final_total=unknown
    print -u2 -r -- "未達標：status=$run_status，最後 total=$final_total，已重擲 $rerolls 次"
    exit 1
fi

(( open_status == 0 )) || exit "$open_status"
fail '程式結束但沒有產生執行報告'
