#!/usr/bin/env bash
# Fetch the pinned IntelliJ util-diff jars used by Oracle.java into lib/.
# Dev-time tool only: the plugin runtime never touches the JVM.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p lib

IJ_VERSION="261.26222.72"
IJ_REPO="https://www.jetbrains.com/intellij-repository/releases/com/jetbrains/intellij/platform"
CENTRAL="https://repo1.maven.org/maven2"

if ! command -v java >/dev/null 2>&1; then
  echo "error: java not found on PATH (JDK 17+ required)" >&2
  exit 1
fi
JAVA_MAJOR=$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)
if [ "${JAVA_MAJOR:-0}" -lt 17 ]; then
  echo "error: JDK 17+ required (found ${JAVA_MAJOR:-unknown})" >&2
  exit 1
fi

# name|url|sha256
DEPS=(
  "util-diff-$IJ_VERSION.jar|$IJ_REPO/util-diff/$IJ_VERSION/util-diff-$IJ_VERSION.jar|305f1c21f6daf21946c9829a02cf229e2da08d2abe4f77e7063e8fc8403cf48c"
  "util-multiplatform-$IJ_VERSION.jar|$IJ_REPO/util-multiplatform/$IJ_VERSION/util-multiplatform-$IJ_VERSION.jar|e34344d19761408a6493d8affa563dfee3aa920eb09855fdd9027093084911aa"
  "util-base-multiplatform-$IJ_VERSION.jar|$IJ_REPO/util-base-multiplatform/$IJ_VERSION/util-base-multiplatform-$IJ_VERSION.jar|aab3710853c470a8f7bc92316c04fab5d51a938b9c794435aaab42a7c5b54cf0"
  "kotlin-stdlib-2.1.20.jar|$CENTRAL/org/jetbrains/kotlin/kotlin-stdlib/2.1.20/kotlin-stdlib-2.1.20.jar|1bcc74e8ce84e2c25eaafde10f1248349cce3062b6e36978cbeec610db1e930a"
  "annotations-24.0.0.jar|$CENTRAL/org/jetbrains/annotations/24.0.0/annotations-24.0.0.jar|ff112f54ce874b8ae899cfd68f0315d96c9f406a338b8eca80c76d10e2e5a2f7"
)

for dep in "${DEPS[@]}"; do
  name="${dep%%|*}"
  rest="${dep#*|}"
  url="${rest%%|*}"
  sha="${rest#*|}"
  if [ -f "lib/$name" ] && echo "$sha  lib/$name" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "ok       $name"
    continue
  fi
  echo "fetching $name"
  curl -fsSL "$url" -o "lib/$name"
  echo "$sha  lib/$name" | shasum -a 256 -c - >/dev/null || {
    echo "error: sha256 mismatch for $name" >&2
    rm -f "lib/$name"
    exit 1
  }
done

echo "done: $(ls lib | wc -l | tr -d ' ') jars in $(pwd)/lib"
