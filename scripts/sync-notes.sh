#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew & standard binaries are on PATH (required for launchd)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO_DIR="/Users/mohamedfarghal/.gemini/antigravity/scratch/farghal.ai"
WORKTREE_DIR="/Users/mohamedfarghal/.gemini/antigravity/scratch/farghal.ai-staging"
PREVIEW_URL="https://medo.github.io/blog-preview/"

# Locate Obsidian blog folder
if [[ -n "${NOTES_BLOG_DIR:-}" && -d "${NOTES_BLOG_DIR}" ]]; then
  BLOG_SRC="${NOTES_BLOG_DIR}"
elif [[ -d "$HOME/Notes/Notes/blog" ]]; then
  BLOG_SRC="$HOME/Notes/Notes/blog"
elif [[ -d "$HOME/Notes/blog" ]]; then
  BLOG_SRC="$HOME/Notes/blog"
else
  echo "[sync] Error: Could not find Obsidian blog folder (checked ~/Notes/Notes/blog and ~/Notes/blog)." >&2
  exit 1
fi

log() {
  echo "[sync $(date '+%Y-%m-%d %H:%M:%S')] $*"
}

git_gh() {
  git -c credential.helper='!gh auth git-credential' "$@"
}

# Fetch latest remote refs
cd "$REPO_DIR"
git_gh fetch origin --quiet

# Ensure staging worktree exists and tracks staging branch
if [[ ! -d "$WORKTREE_DIR" ]]; then
  log "Creating staging worktree at $WORKTREE_DIR..."
  if git show-ref --verify --quiet refs/heads/staging; then
    git worktree add "$WORKTREE_DIR" staging
  elif git show-ref --verify --quiet refs/remotes/origin/staging; then
    git worktree add -b staging "$WORKTREE_DIR" origin/staging
  else
    git worktree add -b staging "$WORKTREE_DIR" origin/main
  fi
  (cd "$WORKTREE_DIR" && git submodule update --init --recursive --quiet)
fi

cd "$WORKTREE_DIR"

# Make sure we are on staging and up to date with main
git checkout staging --quiet
if git show-ref --verify --quiet refs/remotes/origin/staging; then
  git merge --ff-only origin/staging --quiet || true
fi
git merge origin/main --no-edit --quiet
git submodule update --init --recursive --quiet

# Sync Obsidian blog folder into content/posts/ (preserving _index.md)
mkdir -p "$WORKTREE_DIR/content/posts"
rsync -a --delete \
  --exclude='_index.md' \
  --exclude='.DS_Store' \
  --exclude='.obsidian/' \
  --exclude='*.tmp' \
  "$BLOG_SRC/" "$WORKTREE_DIR/content/posts/"

# Convert Obsidian image embeds ![[image.png]] or ![[image.png|alt]] to standard Markdown
python3 - "$WORKTREE_DIR/content/posts" <<'PY'
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

# Check if staging has any new content changes
HAS_CHANGES=0
if [[ -n "$(git status --porcelain)" ]]; then
  HAS_CHANGES=1
fi

# Also check if staging differs from preview/main
PREVIEW_SYNC_NEEDED=0
git_gh fetch preview --quiet 2>/dev/null || true
if ! git show-ref --verify --quiet refs/remotes/preview/main; then
  PREVIEW_SYNC_NEEDED=1
elif [[ "$(git rev-parse HEAD)" != "$(git rev-parse preview/main)" ]]; then
  PREVIEW_SYNC_NEEDED=1
fi

if [[ "$HAS_CHANGES" -eq 0 && "$PREVIEW_SYNC_NEEDED" -eq 0 ]]; then
  log "No updates in $BLOG_SRC."
  exit 0
fi

# Validate Hugo preview build before committing/pushing
log "Validating Hugo preview build..."
hugo --environment preview --buildDrafts --gc --quiet

if [[ "$HAS_CHANGES" -eq 1 ]]; then
  git add -A
  git commit -m "Sync notes from Obsidian ($(date '+%Y-%m-%d %H:%M'))" --quiet
  log "Committed updates to staging."
fi

# Push staging branch to origin and mirror to blog-preview repo
log "Pushing staging to origin and preview..."
git_gh push origin staging --quiet
git_gh push preview staging:main --force --quiet

# Ensure an open PR exists from staging -> main if staging is ahead of main
AHEAD_COUNT=$(git rev-list --count origin/main..HEAD)
if [[ "$AHEAD_COUNT" -gt 0 ]]; then
  EXISTING_PR=$(gh pr list -R medo/medo.github.io --head staging --base main --state open --json url -q '.[0].url' || true)
  if [[ -z "$EXISTING_PR" ]]; then
    PR_URL=$(gh pr create -R medo/medo.github.io \
      --head staging \
      --base main \
      --title "Publish updates to medo's notes" \
      --body "Automated sync from Obsidian (\`$BLOG_SRC\`).

### Preview
- **Staging URL**: $PREVIEW_URL *(includes \`draft: true\` posts; \`noindex\` enabled)*

### How to Publish
Merge this pull request to deploy non-draft posts to **https://medo.github.io/**.")
    log "Opened Pull Request: $PR_URL"
  else
    log "Updated existing Pull Request: $EXISTING_PR"
  fi
fi

log "Preview updated: $PREVIEW_URL"
