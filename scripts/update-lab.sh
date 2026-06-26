#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== OT Lab Update ==="
echo

# Pull latest parent repo
echo "[1/3] Pulling latest repo..."
git pull --ff-only

# Recover ghost submodules: git marks them initialized (writes a .git file)
# even when the clone was interrupted, leaving an empty directory. deinit+init
# forces a fresh clone for any submodule whose directory has only a .git file.
echo
echo "[2/3] Checking for incomplete submodule clones..."
git submodule foreach --quiet 'echo "$name $displaypath"' 2>/dev/null | \
while read -r name path; do
    # Count non-.git entries in the submodule directory
    content=$(find "$REPO_ROOT/$path" -mindepth 1 -not -name '.git' 2>/dev/null | wc -l)
    if [[ "$content" -eq 0 ]]; then
        echo "[!] $name has empty working tree — reinitialising..."
        git submodule deinit -f "$path"
        git submodule update --init "$path"
    fi
done

echo
echo "[3/3] Fetching latest commits for all submodules..."
git submodule update --init --remote --merge

echo
echo "Submodule status:"
git submodule status

# Only prompt to commit if pins actually moved (ignore dirty working trees).
SUMMARY=$(git submodule summary 2>/dev/null || true)
if [[ -n "$SUMMARY" ]]; then
    echo
    echo "Submodule pins have changed:"
    echo "$SUMMARY"
    echo
    echo "Commit updated pins? [y/N]"
    read -r answer
    if [[ "${answer,,}" == "y" ]]; then
        git add $(git submodule status | awk '{print $2}')
        git commit -m "submodules: advance all to latest remote"
        echo "Committed. Run 'git push' to publish."
    else
        echo "Changes left unstaged."
    fi
else
    echo
    echo "All submodules already at latest — nothing to commit."
fi
