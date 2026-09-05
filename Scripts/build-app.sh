#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
developer_dir=/Applications/Xcode.app/Contents/Developer
app_dir="$project_dir/.build/Mirror Probe.app"
binary_path="$project_dir/.build/release/mirror-probe"
module_cache="$project_dir/.build/ModuleCache"

cd "$project_dir"
mkdir -p \
  "$module_cache" \
  "$project_dir/.build/swiftpm-cache" \
  "$project_dir/.build/swiftpm-config" \
  "$project_dir/.build/swiftpm-security"
env \
  DEVELOPER_DIR="$developer_dir" \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  CLANG_MODULE_CACHE_PATH="$module_cache" \
  xcrun swift build \
    --disable-sandbox \
    --cache-path "$project_dir/.build/swiftpm-cache" \
    --config-path "$project_dir/.build/swiftpm-config" \
    --security-path "$project_dir/.build/swiftpm-security" \
    -c release

mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_path" "$app_dir/Contents/MacOS/mirror-probe"
cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier com.kuanlun.knightdragon.mirrorprobe "$app_dir"

echo "$app_dir"
