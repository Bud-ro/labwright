#!/usr/bin/env bash
# Format every Dart file in the repo (workspace packages, the standalone apps, the examples,
# the tools and the root tests); the gitignored corpus trees are left alone.
# VS Code formats on save; run this so CLI/agent edits match and diffs stay
# noise-free. Keep the tree formatted before committing.
#
#   ./format.sh          format in place
#   ./format.sh --check   verify only, exit 1 if anything is unformatted (CI)
set -euo pipefail
cd "$(dirname "$0")"
dirs=()
for d in packages apps example tool test; do
  [[ -d "$d" ]] && dirs+=("$d")
done
if [[ "${1:-}" == "--check" ]]; then
  exec dart format --output=none --set-exit-if-changed "${dirs[@]}"
fi
exec dart format "${dirs[@]}"
