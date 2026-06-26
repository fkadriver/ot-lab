#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== OT Lab Update ==="
echo

# Pull latest parent repo
echo "[1/3] Pulling latest repo..."
git pull --ff-only

# Show current submodule state before update
echo
echo "[2/3] Initialising and fetching latest submodule commits..."
git submodule update --init --remote --merge

# Show what changed
echo
echo "[3/3] Submodule status after update:"
git submodule status

# If any pins changed, offer to commit.
# Use submodule summary rather than git diff --quiet so dirty working trees
# inside submodules don't trigger a false positive.
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
