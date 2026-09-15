#!/bin/zsh

# All offline checks. This does not package/re-sign the app or post game input.
set -euo pipefail

readonly project_dir=${0:A:h:h}
cd "$project_dir"

coverage_args=()
case "${1:-}" in
    '') ;;
    --coverage) coverage_args=(--enable-code-coverage); shift ;;
    --help|-h)
        print -r -- 'Usage: zsh Scripts/test.sh [--coverage]'
        print -r -- 'Runs Swift unit/runtime tests, isolated launchers, offline CLI integration, and release compilation.'
        exit 0 ;;
    *) print -u2 -r -- "Unknown option: $1"; exit 2 ;;
esac
(( $# == 0 )) || { print -u2 -r -- 'Unexpected extra arguments'; exit 2; }

# Respect an explicit toolchain, otherwise prefer the installed full Xcode.
if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$SWIFTPM_MODULECACHE_OVERRIDE"
readonly validation_dir="$project_dir/.build/validation"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$validation_dir" \
    "$project_dir/.build/swiftpm-cache" "$project_dir/.build/swiftpm-config" \
    "$project_dir/.build/swiftpm-security"
swift_args=(
    --disable-sandbox
    --cache-path "$project_dir/.build/swiftpm-cache"
    --config-path "$project_dir/.build/swiftpm-config"
    --security-path "$project_dir/.build/swiftpm-security"
)

xcrun swift --version
xcrun swift test "${swift_args[@]}" "${coverage_args[@]}" 2>&1 | tee "$validation_dir/swift-tests.log"
zsh Tests/LauncherTests/auto-level-wait-tests.zsh 2>&1 | tee "$validation_dir/auto-level-launcher.log"
zsh Tests/LauncherTests/reroll-character-tests.zsh 2>&1 | tee "$validation_dir/reroll-launcher.log"
xcrun swift build "${swift_args[@]}" -c release 2>&1 | tee "$validation_dir/release-build.log"
readonly binary_dir=$(xcrun swift build "${swift_args[@]}" -c release --show-bin-path)
python3 Tests/IntegrationTests/cli-tests.py "$binary_dir/mirror-probe" 2>&1 | tee "$validation_dir/cli-integration.log"

print -r -- "PASS: all offline checks; logs: $validation_dir"
