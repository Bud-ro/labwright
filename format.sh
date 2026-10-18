#!/usr/bin/env bash
# Format every Dart file in the repo (workspace packages, the standalone apps,
# the tools and the example), leaving the fetched corpora under corpus/ alone.
# VS Code formats on save; run this so CLI/agent edits match and diffs stay
# noise-free. Keep the tree formatted before committing.
#
#   ./format.sh          format in place
#   ./format.sh --check   verify only, exit 1 if anything is unformatted (CI)
set -euo pipefail
cd "$(dirname "$0")"
dirs=(apps example packages tool)
if [[ "${1:-}" == "--check" ]]; then
  exec dart format --output=none --set-exit-if-changed "${dirs[@]}"
fi
exec dart format "${dirs[@]}"
