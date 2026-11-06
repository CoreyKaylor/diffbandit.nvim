#!/bin/sh
# Fetch pinned test dependencies into deps/ (gitignored).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MINI_TEST_TAG="${MINI_TEST_TAG:-v0.17.0}"
DEST="$ROOT/deps/mini.test"
if [ ! -f "$DEST/.tag" ] || [ "$(cat "$DEST/.tag")" != "$MINI_TEST_TAG" ]; then
  rm -rf "$DEST"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$MINI_TEST_TAG" https://github.com/nvim-mini/mini.test "$DEST"
  echo "$MINI_TEST_TAG" > "$DEST/.tag"
fi

# vim-fugitive has no recent tag; pin a commit. Fetch by SHA, which GitHub allows.
FUGITIVE_SHA="${FUGITIVE_SHA:-3b753cf8c6a4dcde6edee8827d464ba9b8c4a6f0}"
DEST="$ROOT/deps/vim-fugitive"
if [ ! -f "$DEST/.tag" ] || [ "$(cat "$DEST/.tag")" != "$FUGITIVE_SHA" ]; then
  rm -rf "$DEST"
  git init --quiet "$DEST"
  git -C "$DEST" fetch --quiet --depth 1 https://github.com/tpope/vim-fugitive "$FUGITIVE_SHA"
  git -C "$DEST" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  echo "$FUGITIVE_SHA" > "$DEST/.tag"
fi
