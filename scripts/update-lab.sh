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

# If any pins changed, offer to commit
if ! git diff --quiet; then
    echo
    echo "Submodule pins have changed. Commit updated pins? [y/N]"
    read -r answer
    if [[ "${answer,,}" == "y" ]]; then
        git add .
        git commit -m "submodules: advance all to latest remote"
        echo "Committed. Run 'git push' to publish."
    else
        echo "Changes left unstaged."
    fi
else
    echo
    echo "All submodules already at latest — nothing to commit."
fi
