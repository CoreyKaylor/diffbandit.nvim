// Ground-truth oracle for diffbandit's IntelliJ-alignment work.
//
// Runs the exact engine behind IntelliJ IDEA's diff viewer
// (com.intellij.diff.comparison, Apache 2.0, from the standalone
// com.jetbrains.intellij.platform:util-diff artifact) on two files and emits
// the result as JSON. Two layers are reported:
//
//   lines:  ByLineRt.compare change ranges (0-based, half-open) — the
//           line-block boundaries.
//   blocks: per changed range, ByWordRt.compareAndSplit sub-blocks mapped to
//           absolute line ranges (mirroring the IDE's
//           ComparisonManagerImpl.createInnerWordFragments, including its
//           insert/delete fast path), plus inner word fragments as char
//           offsets into each side's joined block text.
//
// Usage: ./fetch-deps.sh && java -cp "lib/*" Oracle.java <left> <right>
public final class Oracle {
  private static final String UTIL_DIFF_VERSION = "261.26222.72";

  public static void main(String[] args) throws Exception {
    if (args.length != 2) {
      System.err.println("usage: java -cp \"lib/*\" Oracle.java <left-file> <right-file>");
      System.exit(2);
    }
    java.util.List<String> lines1 = java.nio.file.Files.readAllLines(java.nio.file.Path.of(args[0]));
    java.util.List<String> lines2 = java.nio.file.Files.readAllLines(java.nio.file.Path.of(args[1]));

    com.intellij.diff.comparison.ComparisonPolicy policy =
        com.intellij.diff.comparison.ComparisonPolicy.DEFAULT;
    com.intellij.diff.comparison.CancellationChecker checker =
        com.intellij.diff.comparison.CancellationChecker.EMPTY;

    com.intellij.diff.comparison.iterables.FairDiffIterable lineDiff =
        com.intellij.diff.comparison.ByLineRt.compare(
            new java.util.ArrayList<CharSequence>(lines1),
            new java.util.ArrayList<CharSequence>(lines2),
            policy, checker);

    StringBuilder out = new StringBuilder();
    out.append("{\n");
    out.append("  \"utilDiffVersion\": \"").append(UTIL_DIFF_VERSION).append("\",\n");
    out.append("  \"policy\": \"").append(policy.name()).append("\",\n");

    out.append("  \"lines\": [\n");
    java.util.List<com.intellij.diff.util.Range> changes = new java.util.ArrayList<>();
    for (java.util.Iterator<com.intellij.diff.util.Range> it = lineDiff.changes(); it.hasNext(); ) {
      changes.add(it.next());
    }
    for (int i = 0; i < changes.size(); i++) {
      com.intellij.diff.util.Range c = changes.get(i);
      out.append("    ").append(rangeJson(c.start1, c.end1, c.start2, c.end2));
      out.append(i < changes.size() - 1 ? ",\n" : "\n");
    }
    out.append("  ],\n");

    out.append("  \"blocks\": [\n");
    for (int i = 0; i < changes.size(); i++) {
      com.intellij.diff.util.Range c = changes.get(i);
      out.append(blockJson(c, lines1, lines2, policy, checker));
      out.append(i < changes.size() - 1 ? ",\n" : "\n");
    }
    out.append("  ]\n");
    out.append("}\n");
    System.out.print(out);
  }

  // Mirrors ComparisonManagerImpl.createInnerFragments/createInnerWordFragments:
  // pure insertions/deletions are not word-split; other blocks are split into
  // sub-blocks at matched newlines with currentEndLine = currentStartLine +
  // block.newlines (last block clamps to the fragment end).
  private static String blockJson(com.intellij.diff.util.Range c,
                                  java.util.List<String> lines1,
                                  java.util.List<String> lines2,
                                  com.intellij.diff.comparison.ComparisonPolicy policy,
                                  com.intellij.diff.comparison.CancellationChecker checker) {
    StringBuilder b = new StringBuilder();
    b.append("    { \"range\": ").append(rangeJson(c.start1, c.end1, c.start2, c.end2));
    b.append(", \"subBlocks\": [");

    if (c.start1 == c.end1 || c.start2 == c.end2) {
      // Insertion/deletion fast path: single sub-block, no inner fragments.
      b.append(rangeJson(c.start1, c.end1, c.start2, c.end2));
      b.append("] }");
      return b.toString();
    }

    String text1 = String.join("\n", lines1.subList(c.start1, c.end1));
    String text2 = String.join("\n", lines2.subList(c.start2, c.end2));

    java.util.List<com.intellij.diff.comparison.ByWordRt.LineBlock> lineBlocks;
    try {
      lineBlocks = com.intellij.diff.comparison.ByWordRt.compareAndSplit(text1, text2, policy, checker);
    } catch (Exception e) {
      // DiffTooBigException etc.: report the block unsplit, like the IDE's
      // coarse-fragment fallback.
      b.append(rangeJson(c.start1, c.end1, c.start2, c.end2));
      b.append("] }");
      return b.toString();
    }

    int startLine1 = c.start1;
    int startLine2 = c.start2;
    for (int i = 0; i < lineBlocks.size(); i++) {
      com.intellij.diff.comparison.ByWordRt.LineBlock block = lineBlocks.get(i);
      int endLine1 = i != lineBlocks.size() - 1 ? startLine1 + block.newlines1 : c.end1;
      int endLine2 = i != lineBlocks.size() - 1 ? startLine2 + block.newlines2 : c.end2;

      if (i > 0) b.append(", ");
      b.append("{ \"lines\": ").append(rangeJson(startLine1, endLine1, startLine2, endLine2));
      b.append(", \"offsets\": ").append(rangeJson(
          block.offsets.start1, block.offsets.end1, block.offsets.start2, block.offsets.end2));
      b.append(", \"inner\": [");
      for (int j = 0; j < block.fragments.size(); j++) {
        com.intellij.diff.fragments.DiffFragment f = block.fragments.get(j);
        if (j > 0) b.append(", ");
        b.append(rangeJson(f.getStartOffset1(), f.getEndOffset1(),
            f.getStartOffset2(), f.getEndOffset2()));
      }
      b.append("] }");

      startLine1 = endLine1;
      startLine2 = endLine2;
    }
    b.append("] }");
    return b.toString();
  }

  private static String rangeJson(int s1, int e1, int s2, int e2) {
    return "{ \"start1\": " + s1 + ", \"end1\": " + e1
        + ", \"start2\": " + s2 + ", \"end2\": " + e2 + " }";
  }
}
