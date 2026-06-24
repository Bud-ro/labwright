#!/usr/bin/env bash
# Fetch the pinned diverse VI corpus cataloged in corpus/sources.json.
# The .vi files are NOT committed (clean-room + licensing); this pulls each repo
# at its pinned commit so the corpus is reproducible. Requires `gh` (authenticated)
# and python3. Usage: corpus/fetch.sh [destRoot]   (default /tmp/claude-1000/vi_corpus)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$(python3 -c "import json;print(json.load(open('$here/sources.json'))['fetchRoot'])")}"
mkdir -p "$dest"
python3 - "$here/sources.json" "$dest" <<'PY'
import json, os, subprocess, sys
manifest, dest = sys.argv[1], sys.argv[2]
srcs = json.load(open(manifest))["sources"]
for s in srcs:
    repo, commit = s["repo"], s["commit"]
    name = repo.replace("/", "_")
    out = os.path.join(dest, name)
    if os.path.isdir(out) and os.listdir(out):
        print(f"skip  {repo} (already present)"); continue
    os.makedirs(out, exist_ok=True)
    tar = out + ".tar.gz"
    print(f"fetch {repo} @ {commit[:12]}")
    with open(tar, "wb") as fh:
        subprocess.run(["gh", "api", f"repos/{repo}/tarball/{commit}"], stdout=fh, check=True)
    subprocess.run(["tar", "xzf", tar, "-C", out], check=True)
    os.remove(tar)
print("done:", dest)
PY
