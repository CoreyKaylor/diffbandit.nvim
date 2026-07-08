-- Lua port of IntelliJ's line-comparison pipeline (ByLineRt.doCompare, the
-- ComparisonPolicy.DEFAULT path), so diffbandit's change blocks match what
-- IntelliJ IDEA's diff viewer shows:
--
--   compareSmart          - primary matching ignores whitespace AND skips
--                           "unimportant" lines (<= 3 non-space chars: braces,
--                           blanks) so they cannot drag the alignment; gaps
--                           between matched important lines are re-diffed
--                           (SmartLineChangeCorrector)
--   LineChunkOptimizer    - merges touching change blocks and slides ambiguous
--                           boundaries so changes start/end at empty or
--                           unimportant lines
--   correctChangesSecondStep - the primary matching was whitespace-agnostic;
--                           re-align whitespace-equal-but-not-identical line
--                           pairs to maximize exact matches (brute force
--                           capped at n <= 10, like the original)
--
-- Ported from intellij-community platform/util/diff (Apache 2.0):
-- ByLineRt.kt, ChangeCorrector.kt, ChunkOptimizer.kt, TrimUtil.kt,
-- DiffIterableUtil.kt. The Myers LCS core is delegated to vim.diff (xdiff)
-- over synthesized one-line-per-element texts.
--
-- All ranges in this module are 0-based half-open {start1, end1, start2, end2}
-- like the original; compute_hunks converts to diffbandit's 1-based
-- {start, count} hunk contract at the end.

local M = {}

local UNIMPORTANT_LINE_CHAR_COUNT = 3

local function make_lines(raw)
  local lines = {}
  for i, content in ipairs(raw) do
    local iw = content:gsub("%s+", "")
    lines[i] = { content = content, iw = iw, nonspace = #iw }
  end
  return lines
end

-- Fair diff of two string arrays. Delegates to the Lua port of IntelliJ's
-- own LCS engine (myers_lcs.lua) so tie-breaks and the unique-element
-- pre-discard match the original exactly; xdiff's Myers picks different
-- (equally valid) alignments, which shifts block boundaries.
local myers = require("diffbandit.myers_lcs")

local function sequence_diff(items1, items2)
  return myers.diff(items1, items2)
end

local function unchanged_from_changes(changes, n1, n2)
  local unchanged = {}
  local last1, last2 = 0, 0
  for _, c in ipairs(changes) do
    if c.start1 > last1 or c.start2 > last2 then
      unchanged[#unchanged + 1] = { start1 = last1, end1 = c.start1, start2 = last2, end2 = c.start2 }
    end
    last1, last2 = c.end1, c.end2
  end
  if last1 < n1 or last2 < n2 then
    unchanged[#unchanged + 1] = { start1 = last1, end1 = n1, start2 = last2, end2 = n2 }
  end
  return unchanged
end

local function changes_from_unchanged(unchanged, n1, n2)
  local changes = {}
  local last1, last2 = 0, 0
  for _, u in ipairs(unchanged) do
    if u.start1 > last1 or u.start2 > last2 then
      changes[#changes + 1] = { start1 = last1, end1 = u.start1, start2 = last2, end2 = u.start2 }
    end
    last1, last2 = u.end1, u.end2
  end
  if last1 < n1 or last2 < n2 then
    changes[#changes + 1] = { start1 = last1, end1 = n1, start2 = last2, end2 = n2 }
  end
  return changes
end

-- TrimUtil.expand* over an equals(i1, i2) predicate (0-based indices).
local function expand_forward(s1, s2, e1, e2, equals)
  local count = 0
  while s1 + count < e1 and s2 + count < e2 and equals(s1 + count, s2 + count) do
    count = count + 1
  end
  return count
end

local function expand_backward(s1, s2, e1, e2, equals)
  local count = 0
  while e1 - count > s1 and e2 - count > s2 and equals(e1 - count - 1, e2 - count - 1) do
    count = count + 1
  end
  return count
end

local function expand_range(s1, s2, e1, e2, equals)
  local f = expand_forward(s1, s2, e1, e2, equals)
  s1, s2 = s1 + f, s2 + f
  local b = expand_backward(s1, s2, e1, e2, equals)
  return { start1 = s1, end1 = e1 - b, start2 = s2, end2 = e2 - b }
end

local function iw_equals(lines1, lines2)
  return function(i1, i2)
    return lines1[i1 + 1].iw == lines2[i2 + 1].iw
  end
end

local function exact_equals(lines1, lines2)
  return function(i1, i2)
    return lines1[i1 + 1].content == lines2[i2 + 1].content
  end
end

-- DiffIterableUtil.ChangeBuilder / ExpandChangeBuilder: collects monotonically
-- increasing matched regions; everything between them becomes a change. With
-- an `expand_equals` predicate, emitted changes are trimmed of equal
-- head/tail pairs first (ExpandChangeBuilder).
local function new_change_builder(n1, n2, expand_equals)
  local b = { index1 = 0, index2 = 0, n1 = n1, n2 = n2, changes = {} }

  local function add_change(s1, s2, e1, e2)
    if expand_equals then
      local r = expand_range(s1, s2, e1, e2, expand_equals)
      if r.start1 == r.end1 and r.start2 == r.end2 then
        return
      end
      s1, s2, e1, e2 = r.start1, r.start2, r.end1, r.end2
    end
    b.changes[#b.changes + 1] = { start1 = s1, end1 = e1, start2 = s2, end2 = e2 }
  end

  function b.mark_equal(i1, i2, e1, e2)
    if i1 == e1 and i2 == e2 then
      return
    end
    if b.index1 ~= i1 or b.index2 ~= i2 then
      add_change(b.index1, b.index2, i1, i2)
    end
    b.index1, b.index2 = e1, e2
  end

  function b.finish()
    if b.n1 ~= b.index1 or b.n2 ~= b.index2 then
      add_change(b.index1, b.index2, b.n1, b.n2)
    end
    return b.changes
  end

  return b
end

-- ByLineRt.compareSmart + ChangeCorrector.SmartLineChangeCorrector:
-- diff only the "important" lines, then re-diff the gaps between matched
-- important lines. All comparisons whitespace-agnostic (primary matching).
local function compare_smart(lines1, lines2)
  local n1, n2 = #lines1, #lines2
  local big1, idx1 = {}, {}
  for i, l in ipairs(lines1) do
    if l.nonspace > UNIMPORTANT_LINE_CHAR_COUNT then
      big1[#big1 + 1] = l.iw
      idx1[#idx1 + 1] = i - 1
    end
  end
  local big2, idx2 = {}, {}
  for i, l in ipairs(lines2) do
    if l.nonspace > UNIMPORTANT_LINE_CHAR_COUNT then
      big2[#big2 + 1] = l.iw
      idx2[#idx2 + 1] = i - 1
    end
  end

  local big_unchanged = unchanged_from_changes(sequence_diff(big1, big2), #big1, #big2)

  local builder = new_change_builder(n1, n2)
  local eq = iw_equals(lines1, lines2)

  local function match_gap(s1, e1, s2, e2)
    local ex = expand_range(s1, s2, e1, e2, eq)
    builder.mark_equal(s1, s2, ex.start1, ex.start2)
    local inner1, inner2 = {}, {}
    for i = ex.start1, ex.end1 - 1 do
      inner1[#inner1 + 1] = lines1[i + 1].iw
    end
    for i = ex.start2, ex.end2 - 1 do
      inner2[#inner2 + 1] = lines2[i + 1].iw
    end
    local inner_unchanged = unchanged_from_changes(sequence_diff(inner1, inner2), #inner1, #inner2)
    for _, u in ipairs(inner_unchanged) do
      builder.mark_equal(ex.start1 + u.start1, ex.start2 + u.start2, ex.start1 + u.end1, ex.start2 + u.end2)
    end
    builder.mark_equal(ex.end1, ex.end2, e1, e2)
  end

  local last1, last2 = 0, 0
  for _, u in ipairs(big_unchanged) do
    for i = 0, (u.end1 - u.start1) - 1 do
      local o1 = idx1[u.start1 + i + 1]
      local o2 = idx2[u.start2 + i + 1]
      match_gap(last1, o1, last2, o2)
      builder.mark_equal(o1, o2, o1 + 1, o2 + 1)
      last1, last2 = o1 + 1, o2 + 1
    end
  end
  match_gap(last1, n1, last2, n2)

  return builder.finish()
end

-- ChunkOptimizer.LineChunkOptimizer: merge touching change blocks, slide
-- ambiguous boundaries toward empty/unimportant lines. Operates on the
-- unchanged-ranges view; equality here is exact (original-policy lines).
local function optimize_line_chunks(lines1, lines2, changes, eq)
  local n1, n2 = #lines1, #lines2
  local unchanged = unchanged_from_changes(changes, n1, n2)
  eq = eq or exact_equals(lines1, lines2)

  local function find_next_unimportant(lines, offset, count, threshold)
    for i = 0, count - 1 do
      local l = lines[offset + i + 1]
      if not l then
        return -1
      end
      if l.nonspace <= threshold then
        return i
      end
    end
    return -1
  end

  local function find_prev_unimportant(lines, offset, count, threshold)
    for i = 0, count - 1 do
      local l = lines[offset - i + 1]
      if not l then
        return -1
      end
      if l.nonspace <= threshold then
        return i
      end
    end
    return -1
  end

  local function pick_shift(fwd, bwd)
    if fwd == -1 and bwd == -1 then
      return nil
    end
    if fwd == 0 or bwd == 0 then
      return 0
    end
    if fwd ~= -1 then
      return fwd
    end
    return -bwd
  end

  -- Priority order from LineChunkOptimizer.getShift: boundary at an empty
  -- line in the unchanged run, then in the changed run, then the same two
  -- with the unimportant-line threshold.
  local function get_shift(touch_left, equal_forward, equal_backward, r1, r2)
    for _, spec in ipairs({
      { threshold = 0, changed = false },
      { threshold = 0, changed = true },
      { threshold = UNIMPORTANT_LINE_CHAR_COUNT, changed = false },
      { threshold = UNIMPORTANT_LINE_CHAR_COUNT, changed = true },
    }) do
      local shift
      if not spec.changed then
        local touch_lines = touch_left and lines1 or lines2
        local touch_start = touch_left and r2.start1 or r2.start2
        shift = pick_shift(
          find_next_unimportant(touch_lines, touch_start, equal_forward + 1, spec.threshold),
          find_prev_unimportant(touch_lines, touch_start - 1, equal_backward + 1, spec.threshold))
      else
        local non_lines = touch_left and lines2 or lines1
        local change_start = touch_left and r1.end2 or r1.end1
        local change_end = touch_left and r2.start2 or r2.start1
        shift = pick_shift(
          find_next_unimportant(non_lines, change_start, equal_forward + 1, spec.threshold),
          find_prev_unimportant(non_lines, change_end - 1, equal_backward + 1, spec.threshold))
      end
      if shift then
        return shift
      end
    end
    return 0
  end

  local ranges = {}
  local function process_last_ranges()
    while true do
      if #ranges < 2 then
        return
      end
      local r1, r2 = ranges[#ranges - 1], ranges[#ranges]
      if r1.end1 ~= r2.start1 and r1.end2 ~= r2.start2 then
        return
      end
      local count1 = r1.end1 - r1.start1
      local count2 = r2.end1 - r2.start1
      local equal_forward = expand_forward(
        r1.end1, r1.end2,
        math.min(r1.end1 + count2, n1), math.min(r1.end2 + count2, n2), eq)
      local equal_backward = expand_backward(
        math.max(r2.start1 - count1, 0), math.max(r2.start2 - count1, 0),
        r2.start1, r2.start2, eq)
      if equal_forward == 0 and equal_backward == 0 then
        return
      end
      if equal_forward == count2 then
        -- merge chunks left [A]B[B] -> [AB]B
        table.remove(ranges)
        table.remove(ranges)
        ranges[#ranges + 1] = {
          start1 = r1.start1, end1 = r1.end1 + count2,
          start2 = r1.start2, end2 = r1.end2 + count2,
        }
      elseif equal_backward == count1 then
        -- merge chunks right [A]A[B] -> A[AB]
        table.remove(ranges)
        table.remove(ranges)
        ranges[#ranges + 1] = {
          start1 = r2.start1 - count1, end1 = r2.end1,
          start2 = r2.start2 - count1, end2 = r2.end2,
        }
      else
        local touch_left = r1.end1 == r2.start1
        local shift = get_shift(touch_left, equal_forward, equal_backward, r1, r2)
        if shift ~= 0 then
          table.remove(ranges)
          table.remove(ranges)
          ranges[#ranges + 1] = {
            start1 = r1.start1, end1 = r1.end1 + shift,
            start2 = r1.start2, end2 = r1.end2 + shift,
          }
          ranges[#ranges + 1] = {
            start1 = r2.start1 + shift, end1 = r2.end1,
            start2 = r2.start2 + shift, end2 = r2.end2,
          }
        end
        return
      end
    end
  end

  for _, u in ipairs(unchanged) do
    ranges[#ranges + 1] = u
    process_last_ranges()
  end

  return changes_from_unchanged(ranges, n1, n2)
end

-- ByLineRt.correctChangesSecondStep: primary matching was whitespace-agnostic;
-- keep exactly-equal matched pairs, and inside each run of IW-equal-only
-- matches find the alignment that maximizes exact matches (brute force,
-- skipped when the search space exceeds C(n,k) with n > 10).
local function correct_changes_second_step(lines1, lines2, iw_changes)
  local n1, n2 = #lines1, #lines2
  local unchanged = unchanged_from_changes(iw_changes, n1, n2)
  local builder = new_change_builder(n1, n2, exact_equals(lines1, lines2))

  local sample = nil
  local last1, last2 = 0, 0

  local function align_exact_matching(sub1, sub2)
    local n = math.max(#sub1, #sub2)
    if n > 10 or #sub1 == #sub2 then
      for i = 1, math.min(#sub1, #sub2) do
        local i1, i2 = sub1[i], sub2[i]
        if lines1[i1 + 1].content == lines2[i2 + 1].content then
          builder.mark_equal(i1, i2, i1 + 1, i2 + 1)
        end
      end
      return
    end

    local small, large, small_lines, large_lines, swapped
    if #sub1 < #sub2 then
      small, large, small_lines, large_lines, swapped = sub1, sub2, lines1, lines2, false
    else
      small, large, small_lines, large_lines, swapped = sub2, sub1, lines2, lines1, true
    end

    local size = #small
    local comb, best = {}, {}
    for i = 1, size do
      best[i] = i
    end
    local best_weight = 0

    local function process_combination()
      local weight = 0
      for i = 1, size do
        if small_lines[small[i] + 1].content == large_lines[large[comb[i]] + 1].content then
          weight = weight + 1
        end
      end
      if weight > best_weight then
        best_weight = weight
        for i = 1, size do
          best[i] = comb[i]
        end
      end
    end

    local function combinations(start, k)
      if k > size then
        process_combination()
        return
      end
      for i = start, #large do
        comb[k] = i
        combinations(i + 1, k + 1)
      end
    end
    combinations(1, 1)

    for i = 1, size do
      local i1 = swapped and large[best[i]] or small[i]
      local i2 = swapped and small[i] or large[best[i]]
      if lines1[i1 + 1].content == lines2[i2 + 1].content then
        builder.mark_equal(i1, i2, i1 + 1, i2 + 1)
      end
    end
  end

  local function flush(line1_end, line2_end)
    if sample == nil then
      return
    end
    local start1 = math.max(last1, builder.index1)
    local start2 = math.max(last2, builder.index2)

    local sub1, sub2 = {}, {}
    for i = start1, line1_end - 1 do
      if lines1[i + 1].iw == sample then
        sub1[#sub1 + 1] = i
        last1 = i + 1
      end
    end
    for i = start2, line2_end - 1 do
      if lines2[i + 1].iw == sample then
        sub2[#sub2 + 1] = i
        last2 = i + 1
      end
    end

    align_exact_matching(sub1, sub2)
    sample = nil
  end

  for _, u in ipairs(unchanged) do
    for i = 0, (u.end1 - u.start1) - 1 do
      local i1, i2 = u.start1 + i, u.start2 + i
      local l1, l2 = lines1[i1 + 1], lines2[i2 + 1]
      if sample == nil or l1.iw ~= sample then
        if l1.content == l2.content then
          flush(i1, i2)
          builder.mark_equal(i1, i2, i1 + 1, i2 + 1)
        else
          flush(i1, i2)
          sample = l1.iw
        end
      end
    end
  end
  flush(n1, n2)

  return builder.finish()
end

-- Full pipeline: raw line arrays in, change ranges (0-based half-open) out.
-- opts.ignore_whitespace selects the IGNORE_WHITESPACES policy path
-- (ByLineRt: optimize with whitespace-agnostic equality and expand
-- IW-equal edges out of each change — whitespace-only blocks vanish —
-- instead of the exact re-alignment second step).
function M.compare_lines(raw1, raw2, opts)
  local lines1 = make_lines(raw1)
  local lines2 = make_lines(raw2)
  local iw_changes = compare_smart(lines1, lines2)

  if opts and opts.ignore_whitespace then
    local eq = iw_equals(lines1, lines2)
    iw_changes = optimize_line_chunks(lines1, lines2, iw_changes, eq)
    local out = {}
    for _, c in ipairs(iw_changes) do
      local r = expand_range(c.start1, c.start2, c.end1, c.end2, eq)
      if r.start1 ~= r.end1 or r.start2 ~= r.end2 then
        out[#out + 1] = r
      end
    end
    return out
  end

  iw_changes = optimize_line_chunks(lines1, lines2, iw_changes)
  return correct_changes_second_step(lines1, lines2, iw_changes)
end

return M
