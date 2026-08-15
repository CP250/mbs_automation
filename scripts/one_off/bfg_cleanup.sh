#!/usr/bin/env bash
# bfg_cleanup.sh - Strip binary file history from the vault's git repo
#
# Usage:
#   bash /Users/cpreston/Vaults/storage_mbs/admin/mbs_system/bfg_cleanup.sh
#
# Prerequisites: Java must be installed (check: java -version)
# BFG jar is downloaded automatically to /tmp/bfg.jar
#
# What it does:
#   1. Commits any uncommitted changes (so the current clean state is protected)
#   2. Downloads BFG Repo Cleaner if not already present
#   3. Runs BFG to strip all binary blob types from git history
#   4. Expires reflog and runs aggressive gc to actually reclaim disk space

set -euo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
BFG_JAR="/tmp/bfg.jar"
BFG_VERSION="1.14.0"
BFG_URL="https://repo1.maven.org/maven2/com/madgag/bfg/${BFG_VERSION}/bfg-${BFG_VERSION}.jar"

cd "$VAULT"

echo "── Step 1: Committing current state ────────────────────────────────"
git add -A
if git diff --cached --quiet; then
  echo "  Nothing to commit - working tree already clean."
else
  git commit -m "chore: pre-BFG snapshot - binaries migrated to storage_mbs_assets"
  echo "  Committed current state."
fi
echo ""

echo "── Step 2: Downloading BFG ─────────────────────────────────────────"
if [ -f "$BFG_JAR" ]; then
  echo "  BFG jar already present at $BFG_JAR"
else
  echo "  Downloading BFG ${BFG_VERSION}..."
  curl -L "$BFG_URL" -o "$BFG_JAR"
  echo "  Downloaded."
fi
echo ""

echo "── Step 3: Running BFG to strip binary history ─────────────────────"
# BFG protects the HEAD commit by default, so the current clean state is safe.
# The glob strips every commit in history that contains these file types.
java -jar "$BFG_JAR" \
  --delete-files "*.{pdf,png,jpg,jpeg,gif,svg,webp,mp3,mp4,wav,mov,avi,zip,docx,xlsx,pptx,sketch,fig,epub,html,ics}" \
  "$VAULT"
echo ""

echo "── Step 4: Expiring reflog and running gc ───────────────────────────"
git reflog expire --expire=now --all
git gc --prune=now --aggressive
echo ""

echo "── Done ─────────────────────────────────────────────────────────────"
du -sh "$VAULT/.git"
echo "  .git size after cleanup shown above."
echo ""
echo "You can now delete this script:"
echo "  rm $VAULT/admin/mbs_system/bfg_cleanup.sh"
echo "And the BFG jar:"
echo "  rm $BFG_JAR"
