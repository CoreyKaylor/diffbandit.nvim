# IntelliJ diff oracle

Dev-time ground-truth tool for aligning diffbandit's hunk output with the
diff engine IntelliJ IDEA's viewer uses. It runs the real, open-source
engine — `ByLineRt`/`ByWordRt` from `com.jetbrains.intellij.platform:util-diff`
(Apache 2.0, the exact code behind the IDE's side-by-side viewer in both
Community and Ultimate) — on two files and prints JSON.

The plugin runtime never uses this; it exists so `tools/compare_harness.lua`
can measure diffbandit's output against IntelliJ's, and so golden expectations
in `tests/run.lua` can be captured once and checked in.

## Usage

```sh
./fetch-deps.sh                          # one-time: downloads pinned jars into lib/ (gitignored)
java -cp "lib/*" Oracle.java left.kt right.kt > out.json
```

Requires JDK 17+ (uses the Java source-file launcher; no build step).

## Output

- `lines`: line-level change ranges from `ByLineRt.compare` with
  `ComparisonPolicy.DEFAULT` (the IDE default). 0-based, half-open.
- `blocks`: for each changed range, the word-driven sub-block split from
  `ByWordRt.compareAndSplit`, mapped to absolute line ranges the same way the
  IDE's `ComparisonManagerImpl.createInnerWordFragments` does, plus `inner`
  word fragments as char offsets into each side's newline-joined block text.
  Pure insertions/deletions are a single sub-block with no inner fragments
  (the IDE's fast path).

Note: lines are read with `Files.readAllLines` (splits on `\n`, no trailing
empty line for a final newline) to match how diffbandit's `vim.fn.readfile`
sees files. Revisit if EOF-edge divergences ever show up in the harness.

## Version pin

`util-diff 261.26222.72` from the JetBrains IntelliJ Repository
(plus `kotlin-stdlib 2.1.20`, `annotations 24.0.0` from Maven Central),
sha256-pinned in `fetch-deps.sh`. Bumping the pin: update versions + hashes
there, rerun the harness, and regenerate any golden expectations that moved.
