#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN environment variable is required}"

REPO_OWNER="${REPO_OWNER:-medo}"
MAIN_REPO="${MAIN_REPO:-medo.github.io}"
PREVIEW_REPO="${PREVIEW_REPO:-blog-preview}"
PREVIEW_URL="${PREVIEW_URL:-https://${REPO_OWNER}.github.io/${PREVIEW_REPO}/}"
BLOG_SRC="${BLOG_SRC:-/blog-src}"
WORK_DIR="${WORK_DIR:-/workspace/blog}"
SYNC_INTERVAL="${SYNC_INTERVAL:-3600}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Mohammed Farghal}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-mohamed@farghal.com}"

export GH_TOKEN="$GITHUB_TOKEN"

log() {
  echo "[nas-sync $(date '+%Y-%m-%d %H:%M:%S')] $*"
}

setup_git() {
  git config --global user.name "$GIT_AUTHOR_NAME"
  git config --global user.email "$GIT_AUTHOR_EMAIL"
  git config --global credential.helper '!gh auth git-credential'
  git config --global --add safe.directory "$WORK_DIR"
}

init_repo() {
  if [[ ! -d "$WORK_DIR/.git" ]]; then
    log "Cloning ${REPO_OWNER}/${MAIN_REPO}..."
    mkdir -p "$(dirname "$WORK_DIR")"
    git clone "https://github.com/${REPO_OWNER}/${MAIN_REPO}.git" "$WORK_DIR"
    cd "$WORK_DIR"
    git remote add preview "https://github.com/${REPO_OWNER}/${PREVIEW_REPO}.git"
  fi
}

sync_once() {
  if [[ ! -d "$BLOG_SRC" ]]; then
    log "Warning: $BLOG_SRC does not exist yet; skipping."
    return 0
  fi

  cd "$WORK_DIR"
  git fetch origin --quiet --prune
  git fetch preview --quiet --prune 2>/dev/null || true

  # Ensure staging branch exists and is synced with origin/staging and origin/main
  if git show-ref --verify --quiet refs/heads/staging; then
    git checkout staging --quiet
  elif git show-ref --verify --quiet refs/remotes/origin/staging; then
    git checkout -b staging origin/staging --quiet
  else
    git checkout -b staging origin/main --quiet
  fi

  if git show-ref --verify --quiet refs/remotes/origin/staging; then
    git merge --ff-only origin/staging --quiet || true
  fi
  git merge origin/main --no-edit --quiet

  # Sync read-only NAS blog folder into content/posts/ (preserving _index.md)
  mkdir -p "$WORK_DIR/content/posts"
  rsync -a --delete \
    --exclude='_index.md' \
    --exclude='.DS_Store' \
    --exclude='.obsidian/' \
    --exclude='*.tmp' \
    "$BLOG_SRC/" "$WORK_DIR/content/posts/"

  # Convert Obsidian ![[image.png]] or ![[image.png|alt]] embeds to standard Markdown
  python3 - "$WORK_DIR/content/posts" <<'PY'
import pathlib, re, sys

posts_dir = pathlib.Path(sys.argv[1])
pattern = re.compile(r'!\[\[([^|\]]+?)(?:\|([^\]]+))?\]\]')

for md in posts_dir.rglob("*.md"):
    if md.name == "_index.md":
        continue
    text = md.read_text(encoding="utf-8")
    updated = pattern.sub(lambda m: f"![{m.group(2) or ''}]({m.group(1)})", text)
    if updated != text:
        md.write_text(updated, encoding="utf-8")
PY

  HAS_CHANGES=0
  if [[ -n "$(git status --porcelain)" ]]; then
    HAS_CHANGES=1
  fi

  PREVIEW_SYNC_NEEDED=0
  if ! git show-ref --verify --quiet refs/remotes/preview/main; then
    PREVIEW_SYNC_NEEDED=1
  elif [[ "$(git rev-parse HEAD)" != "$(git rev-parse preview/main)" ]]; then
    PREVIEW_SYNC_NEEDED=1
  fi

  if [[ "$HAS_CHANGES" -eq 0 && "$PREVIEW_SYNC_NEEDED" -eq 0 ]]; then
    log "No updates detected."
    return 0
  fi

  if [[ "$HAS_CHANGES" -eq 1 ]]; then
    git add -A
    git commit -m "Sync notes from NAS ($(date '+%Y-%m-%d %H:%M'))" --quiet
    log "Committed updates to staging."
  fi

  log "Pushing staging to origin and preview..."
  git push origin staging --quiet
  git push preview staging:main --force --quiet

  # Open or update the single staging -> main PR
  AHEAD_COUNT=$(git rev-list --count origin/main..HEAD)
  if [[ "$AHEAD_COUNT" -gt 0 ]]; then
    EXISTING_PR=$(gh pr list -R "${REPO_OWNER}/${MAIN_REPO}" --head staging --base main --state open --json url -q '.[0].url' || true)
    if [[ -z "$EXISTING_PR" ]]; then
      PR_URL=$(gh pr create -R "${REPO_OWNER}/${MAIN_REPO}" \
        --head staging \
        --base main \
        --title "Publish updates to medo's notes" \
        --body "Automated sync from UGREEN NAS.

### Preview
- **Staging URL**: $PREVIEW_URL *(includes \`draft: true\` posts; \`noindex\` enabled)*

### How to Publish
Merge (or **Squash and merge**) this pull request to deploy non-draft posts to **https://${REPO_OWNER}.github.io/**.")
      log "Opened Pull Request: $PR_URL"
    else
      log "Updated existing Pull Request: $EXISTING_PR"
    fi
  fi

  log "Preview updated: $PREVIEW_URL"
}

setup_git
init_repo

log "Starting hourly NAS sync loop (interval: ${SYNC_INTERVAL}s)..."
while true; do
  sync_once || log "Sync cycle encountered an error; will retry next cycle."
  sleep "$SYNC_INTERVAL"
done
