#!/usr/bin/env bash
# Snapshot modified file pairs from a sibling repo's worktree into
# tools/corpus/ (gitignored, local-only) and capture the IntelliJ oracle's
# output for each pair. The source repo is only ever read.
#
# Usage: tools/capture_corpus.sh [path-to-repo]   (default: ../vitality)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="${1:-../vitality}"
CORPUS="tools/corpus"
ORACLE_DIR="tools/intellij-oracle"

if [ ! -d "$REPO/.git" ]; then
  echo "error: $REPO is not a git repository" >&2
  exit 1
fi
if [ ! -d "$ORACLE_DIR/lib" ]; then
  echo "error: run $ORACLE_DIR/fetch-deps.sh first" >&2
  exit 1
fi

mkdir -p "$CORPUS"
: > "$CORPUS/manifest.txt"

count=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  name=$(echo "$path" | tr '/' '_')
  left="$CORPUS/$name.left"
  right="$CORPUS/$name.right"
  git -C "$REPO" show "HEAD:$path" > "$left" 2>/dev/null || continue
  cp "$REPO/$path" "$right" 2>/dev/null || continue
  (cd "$ORACLE_DIR" && java -cp "lib/*" Oracle.java "../../$left" "../../$right") > "$CORPUS/$name.golden.json"
  echo "$name" >> "$CORPUS/manifest.txt"
  count=$((count + 1))
  echo "captured $name"
done < <(git -C "$REPO" diff --name-only --diff-filter=M HEAD)

echo "done: $count pairs in $CORPUS/"
