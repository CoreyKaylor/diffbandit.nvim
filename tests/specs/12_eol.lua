-- Test Suite 12: stored-text codec and final-newline hunks (issue #36)

local function assert_same(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error((msg or "assertion failed")
      .. string.format("\nExpected: %s\nActual:   %s", vim.inspect(expected), vim.inspect(actual)))
  end
end

-- Suite 12a: decode/encode round-trip stored text byte for byte
do
  local text_mod = require("diffbandit.util.text")
  local cases = {
    { "", {}, true, nil },
    { "a\nb\n", { "a", "b" }, true, "lf" },
    { "a\nb", { "a", "b" }, false, "lf" },
    { "a", { "a" }, false, nil },
    { "a\r\nb\r\n", { "a", "b" }, true, "crlf" },
    { "class A\r\n{\r\n}", { "class A", "{", "}" }, false, "crlf" },
    -- Mixed endings keep their CRs, as Vim shows them.
    { "a\r\nb\nc\n", { "a\r", "b", "c" }, true, "mixed" },
    { "\n", { "" }, true, "lf" },
    { "\239\187\191a\r\nb", { "a", "b" }, false, "crlf" },
  }
  for _, case in ipairs(cases) do
    local value, lines, eol, line_ending = case[1], case[2], case[3], case[4]
    local decoded, format = text_mod.decode(value)
    assert_same(decoded, lines, "decode lines of " .. vim.inspect(value))
    assert_eq(format.eol, eol, "decode eol of " .. vim.inspect(value))
    assert_eq(format.line_ending, line_ending, "decode line ending of " .. vim.inspect(value))
    assert_eq(text_mod.encode(decoded, format), value, "encode round-trip of " .. vim.inspect(value))
    assert_eq(format.bom, value:sub(1, 3) == "\239\187\191", "decode BOM of " .. vim.inspect(value))
  end

  assert_eq(text_mod.reaches_end(3, 1, 3), true, "a range ending on the last line reaches the end")
  assert_eq(text_mod.reaches_end(2, 1, 3), false, "a range above the last line does not")
  assert_eq(text_mod.reaches_end(3, 0, 3), true, "an insertion after the last line reaches the end")
  assert_eq(text_mod.reaches_end(2, 0, 3), false, "an insertion inside the file does not")
end

-- Suite 12b: a final-newline difference is a hunk
do
  -- Only the final newline differs: the last line pair becomes a change.
  local hunks = diff.compute_hunks("a\nb", "a\nb\n", config.diff)
  assert_eq(#hunks, 1, "a final-newline change alone should produce one hunk")
  assert_eq(hunks[1].type, "change", "the final-newline hunk should be a change")
  assert_same(hunks[1].left, { start = 2, count = 1 }, "the hunk should cover the last left line")
  assert_same(hunks[1].right, { start = 2, count = 1 }, "the hunk should cover the last right line")
  assert_eq(hunks[1].eol_change, true, "the hunk should be marked as a final-newline change")

  -- Issue #36 repro: CRLF file gaining its final CRLF, with or without
  -- whitespace-insensitive matching.
  local left, right = "class A\r\n{\r\n}", "class A\r\n{\r\n}\r\n"
  for _, ignore in ipairs({ false, true }) do
    local opts = vim.tbl_extend("force", config.diff or {}, { ignore_whitespace = ignore })
    hunks = diff.compute_hunks(left, right, opts)
    assert_eq(#hunks, 1, "CRLF final-newline change should show (ignore_whitespace=" .. tostring(ignore) .. ")")
    assert_same(hunks[1].left, { start = 3, count = 1 }, "CRLF final-newline hunk should sit on the last line")
  end

  -- A hunk that already reaches the end carries the difference.
  hunks = diff.compute_hunks("a\nb", "a\nc\n", config.diff)
  assert_eq(#hunks, 1, "a changed last line should not get a second hunk")
  assert_eq(hunks[1].eol_change, true, "the changed last line should carry the final-newline change")

  -- A change elsewhere plus the final newline: two hunks.
  hunks = diff.compute_hunks("x\nb\nc", "y\nb\nc\n", config.diff)
  assert_eq(#hunks, 2, "an earlier change and a final-newline change should be separate hunks")
  assert_eq(hunks[1].eol_change, nil, "the earlier hunk is not a final-newline change")
  assert_eq(hunks[2].eol_change, true, "the last hunk is the final-newline change")

  -- Same final newline on both sides: nothing extra.
  assert_eq(#diff.compute_hunks("a\nb", "a\nb", config.diff), 0, "two files without a final newline are equal")
  -- A line-ending change alone is not a line hunk (the header names it).
  assert_eq(#diff.compute_hunks("a\r\nb\r\n", "a\nb\n", config.diff), 0, "CRLF vs LF lines compare equal")
end

-- Suite 12c: headers name a line-ending change
do
  local function header(left, right)
    return status_mod.build({ config = config, left = left, right = right })
  end
  local lines = header({ label = "a.cs", line_ending = "crlf" }, { label = "a.cs", line_ending = "lf" })
  assert_eq(lines.left:find("[CRLF]", 1, true) ~= nil, true, "left header should name CRLF: " .. lines.left)
  assert_eq(lines.right:find("[LF]", 1, true) ~= nil, true, "right header should name LF: " .. lines.right)
  lines = header({ label = "a.cs", bom = true }, { label = "a.cs" })
  assert_eq(lines.left:find("[BOM]", 1, true) ~= nil, true, "left header should name the BOM: " .. lines.left)
  assert_eq(lines.right:find("[no BOM]", 1, true) ~= nil, true, "right header should name its absence: " .. lines.right)
  lines = header({ label = "a.cs", line_ending = "crlf" }, { label = "a.cs", line_ending = "crlf" })
  assert_eq(lines.left:find("[", 1, true), nil, "matching line endings should not be named")
end
