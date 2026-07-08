-- Suite 18: IntelliJ-alignment goldens. Expected hunks captured once from
-- the real IntelliJ engine (tools/intellij-oracle, util-diff 261.26222.72,
-- ComparisonPolicy.DEFAULT) — each case pins one ported heuristic. If these
-- move, the port diverged from the IDE; re-verify against the oracle before
-- updating (see tools/intellij-oracle/README.md).
do
  local function assert_hunks(label, left, right, expected)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, label .. ": diff error")
    assert_eq(#hunks, #expected, label .. ": hunk count")
    for i, e in ipairs(expected) do
      local h = hunks[i]
      assert_eq(h.type, e[1], label .. ": hunk " .. i .. " type")
      assert_eq(h.left.start, e[2], label .. ": hunk " .. i .. " left start")
      assert_eq(h.left.count, e[3], label .. ": hunk " .. i .. " left count")
      assert_eq(h.right.start, e[4], label .. ": hunk " .. i .. " right start")
      assert_eq(h.right.count, e[5], label .. ": hunk " .. i .. " right count")
    end
    return hunks
  end

  -- correctChangesSecondStep: the whitespace-agnostic first pass matches
  -- shifted brace lines; the second step realigns them so the exactly-equal
  -- pairs match and only the first line remains deleted (example from the
  -- ByLineRt.kt source comment).
  assert_hunks("iw-realign",
    { ".{", "..{", "...{" },
    { "..{", "...{" },
    { { "delete", 1, 1, 0, 0 } })

  -- LineChunkOptimizer: the inserted function is ambiguous (could slide);
  -- the boundary must sit at the blank line so the insertion is one clean
  -- block, anchored after line 4.
  assert_hunks("blank-line slide",
    { "fun a() {", "    body", "}", "", "fun c() {", "    body", "}" },
    { "fun a() {", "    body", "}", "", "fun b() {", "    body", "}", "", "fun c() {", "    body", "}" },
    { { "add", 4, 0, 5, 4 } })

  -- compareSmart: brace/blank lines are excluded from primary matching, so
  -- the repeated {,},blank scaffolding cannot drag the alignment — the
  -- insertion lands as one block at the top.
  assert_hunks("unimportant-line anchoring",
    { "alpha one", "{", "}", "", "beta two", "{", "}" },
    { "gamma three", "{", "}", "", "alpha one", "{", "}", "", "beta two", "{", "}" },
    { { "add", 0, 0, 1, 4 } })

  -- Reindexer.discardUnique + MyersLCS tie-breaking: swapped blocks resolve
  -- as delete-at-top + add-at-bottom, exactly like the IDE.
  assert_hunks("block reorder",
    { "aa bb", "cc dd", "ee ff", "gg hh" },
    { "ee ff", "gg hh", "aa bb", "cc dd" },
    { { "delete", 1, 2, 0, 0 }, { "add", 4, 0, 3, 2 } })

  -- ByWordRt.compareAndSplit: the rewrite plus inserted line stay one
  -- sub-block (word matching does not split them), and the inner emphasis
  -- spans come from the block-scoped word fragments.
  local hunks = assert_hunks("word sub-blocks",
    { "val x = compute(a, b)", "return x" },
    { "val x = compute(a, b, c)", "log(x)", "return x" },
    { { "change", 1, 1, 1, 2 } })
  assert_eq(hunks[1].sub_hunks, nil, "word sub-blocks: single sub-block stays unsplit")
  assert_eq(hunks[1].inner_spans ~= nil, true, "word sub-blocks: inner spans present")
end

