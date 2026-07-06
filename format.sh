#!/usr/bin/env bash
# Format every Dart file in the repo (workspace packages + the standalone apps).
# VS Code formats on save; run this so CLI/agent edits match and diffs stay
# noise-free. Keep the tree formatted before committing.
#
#   ./format.sh          format in place
#   ./format.sh --check   verify only, exit 1 if anything is unformatted (CI)
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" == "--check" ]]; then
  exec dart format --output=none --set-exit-if-changed .
fi
exec dart format .
