#!/bin/sh
# Fetch pinned test dependencies into deps/ (gitignored).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MINI_TEST_TAG="${MINI_TEST_TAG:-v0.17.0}"
DEST="$ROOT/deps/mini.test"
if [ -f "$DEST/.tag" ] && [ "$(cat "$DEST/.tag")" = "$MINI_TEST_TAG" ]; then
  exit 0
fi
rm -rf "$DEST"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$MINI_TEST_TAG" https://github.com/nvim-mini/mini.test "$DEST"
echo "$MINI_TEST_TAG" > "$DEST/.tag"
