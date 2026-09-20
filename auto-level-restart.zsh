#!/bin/zsh
set -euo pipefail
readonly project_dir=${0:A:h}
exec python3 "$project_dir/Scripts/auto-level-supervisor.py" "$@"
