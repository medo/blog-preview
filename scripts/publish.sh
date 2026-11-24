#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO_DIR="/Users/mohamedfarghal/.gemini/antigravity/scratch/farghal.ai"

# 1. Run sync first so the latest Obsidian edits are included
"$REPO_DIR/scripts/sync-notes.sh"

# 2. Check if there is an open staging -> main PR and merge it, or fast-forward locally
PR_NUMBER=$(gh pr list -R medo/medo.github.io --head staging --base main --state open --json number -q '.[0].number' || true)

if [[ -n "$PR_NUMBER" ]]; then
  echo "[publish] Merging PR #$PR_NUMBER (staging -> main)..."
  gh pr merge "$PR_NUMBER" -R medo/medo.github.io --merge
  git -C "$REPO_DIR" -c credential.helper='!gh auth git-credential' pull origin main --ff-only --quiet
  echo "[publish] Published! GitHub Actions is deploying to https://medo.github.io/"
else
  echo "[publish] Nothing new to publish — main is already up to date with staging."
fi
