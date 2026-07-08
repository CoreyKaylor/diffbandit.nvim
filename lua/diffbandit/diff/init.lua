local text = require("diffbandit.util.text")
local smart_align = require("diffbandit.diff.smart_align")
local word_diff = require("diffbandit.diff.word_diff")

local M = {}

local function split_lines(body)
  if body == "" then
    return {}
  end
  local lines = vim.split(body, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function classify(count_a, count_b)
  if count_a == 0 and count_b > 0 then
    return "add"
  elseif count_b == 0 and count_a > 0 then
    return "delete"
  end
  return "change"
end

function M.read_file(path)
  local ok, contents = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, nil, string.format("Unable to read file: %s", contents)
  end
  return contents, text.to_text(contents)
end

-- Split one fragment side into per-line pieces. `range_s`/`range_e` are
-- 0-based half-open char offsets into the newline-joined sub-block text;
-- pieces come out as 1-based inclusive column spans per absolute line.
local function fragment_line_pieces(range_s, range_e, lines, first_line)
  local out = {}
  local off = 0
  for k = 1, #lines do
    local line_len = #lines[k]
    local line_s, line_e = off, off + line_len
    if line_s > range_e then
      break
    end
    local s = math.max(range_s, line_s)
    local e = math.min(range_e, line_e)
    if s < e then
      out[#out + 1] = {
        line = first_line + k - 1,
        s = s - line_s + 1,
        e = e - line_s,
        at_eol = e == line_e,
      }
    end
    off = line_e + 1
  end
  return out
end

-- Row alignment and intra-line emphasis inside a smart-align change block.
-- IntelliJ derives both from ONE word matching over the whole block
-- (ByWordRt.compareAndSplit): the sub-block split gives the row pairing,
-- and each sub-block's inner fragments give the emphasis spans — see
-- word_diff.lua. Sub-blocks partition the block on both sides, so the
-- aligned view stays fully covered.
--
-- Returns sub_hunks plus `inner_spans` keyed by absolute 1-based line
-- numbers: `left`/`right` are emphasis span lists, `add_start` marks a pure
-- insertion reaching the end of a right line (rendered as the green
-- appended tail).
local function block_sub_hunks(left_lines, right_lines, range)
  local s1, e1, s2, e2 = range.start1, range.end1, range.start2, range.end2
  local c1, c2 = e1 - s1, e2 - s2
  if c1 == 0 or c2 == 0 then
    return nil, nil
  end

  local t1 = table.concat(left_lines, "\n", s1 + 1, e1)
  local t2 = table.concat(right_lines, "\n", s2 + 1, e2)
  local ok, sub_blocks = pcall(word_diff.compare_and_split, t1, t2, c1, c2)
  if not ok then
    return nil, nil
  end

  local spans = { left = {}, right = {}, add_start = {} }
  local subs = {}
  for _, sb in ipairs(sub_blocks) do
    local r = sb.lines
    local sc1, sc2 = r.e1 - r.s1, r.e2 - r.s2
    subs[#subs + 1] = {
      type = classify(sc1, sc2),
      left = { start = sc1 > 0 and (s1 + r.s1 + 1) or (s1 + r.s1), count = sc1 },
      right = { start = sc2 > 0 and (s2 + r.s2 + 1) or (s2 + r.s2), count = sc2 },
    }

    local sub_left, sub_right = {}, {}
    for k = r.s1, r.e1 - 1 do
      sub_left[#sub_left + 1] = left_lines[s1 + k + 1]
    end
    for k = r.s2, r.e2 - 1 do
      sub_right[#sub_right + 1] = right_lines[s2 + k + 1]
    end
    for _, f in ipairs(sb.fragments) do
      for _, p in ipairs(fragment_line_pieces(f.start1, f.end1, sub_left, s1 + r.s1 + 1)) do
        spans.left[p.line] = spans.left[p.line] or {}
        table.insert(spans.left[p.line], { p.s, p.e })
      end
      local is_insertion = f.start1 == f.end1
      for _, p in ipairs(fragment_line_pieces(f.start2, f.end2, sub_right, s2 + r.s2 + 1)) do
        if is_insertion and p.at_eol then
          local prev = spans.add_start[p.line]
          spans.add_start[p.line] = prev and math.min(prev, p.s) or p.s
        else
          spans.right[p.line] = spans.right[p.line] or {}
          table.insert(spans.right[p.line], { p.s, p.e })
        end
      end
    end
  end

  if #subs <= 1 then
    return nil, spans
  end
  return subs, spans
end

local function compute_hunks_smart(left_text, right_text, opts)
  local left_lines = split_lines(left_text)
  local right_lines = split_lines(right_text)

  local ok, ranges = pcall(smart_align.compare_lines, left_lines, right_lines, opts)
  if not ok then
    return {}, string.format("diff failed: %s", ranges)
  end

  local hunks = {}
  for _, r in ipairs(ranges) do
    local c1, c2 = r.end1 - r.start1, r.end2 - r.start2
    local h = {
      index = #hunks + 1,
      type = classify(c1, c2),
      left = { start = c1 > 0 and r.start1 + 1 or r.start1, count = c1 },
      right = { start = c2 > 0 and r.start2 + 1 or r.start2, count = c2 },
    }
    local subs, inner_spans = block_sub_hunks(left_lines, right_lines, r)
    if subs then
      h.sub_hunks = subs
      h.merged = true
    end
    h.inner_spans = inner_spans
    hunks[#hunks + 1] = h
  end
  return hunks, nil
end

function M.compute_hunks(left_text, right_text, opts)
  return compute_hunks_smart(left_text, right_text, opts or {})
end

-- Compute intra-line emphasis spans for a pair of lines; returns lists of
-- {s, e} (1-indexed, inclusive). Spans come from the IntelliJ word engine
-- (word_diff.inner_fragments — word matching, punctuation adjustment,
-- whitespace-edge trimming). A pure insertion at the end of the right line
-- is reported as `add_start` (rendered as an appended green tail); all other
-- difference ranges become emphasis spans.
function M.changed_spans(left_line, right_line)
  local right_len = #right_line
  if left_line == right_line then
    return {
      left = {},
      right_changes = {},
      prefix_len = 0,
      right_len = right_len,
      change_end = 0,
      add_start = nil,
    }
  end

  local prefix = 0
  local max_prefix = math.min(#left_line, right_len)
  while prefix < max_prefix and left_line:byte(prefix + 1) == right_line:byte(prefix + 1) do
    prefix = prefix + 1
  end

  local spans_left, right_changes = {}, {}
  local add_start = nil

  local ok, fragments = pcall(word_diff.inner_fragments, left_line, right_line)
  if ok then
    for i, f in ipairs(fragments) do
      if f.end1 > f.start1 then
        spans_left[#spans_left + 1] = { f.start1 + 1, f.end1 }
      end
      if f.end2 > f.start2 then
        if i == #fragments and f.start1 == f.end1 and f.end2 == right_len then
          add_start = f.start2 + 1
        else
          right_changes[#right_changes + 1] = { f.start2 + 1, f.end2 }
        end
      end
    end
  end

  local change_end = prefix
  if #right_changes > 0 then
    change_end = right_changes[#right_changes][2]
  end

  return {
    left = spans_left,
    right_changes = right_changes,
    prefix_len = prefix,
    right_len = right_len,
    change_end = change_end,
    add_start = add_start,
  }
end

return M
