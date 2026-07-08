-- Lua port of the word layer of IntelliJ's diff engine (ByWordRt.kt,
-- ChunkOptimizer.WordChunkOptimizer, LineFragmentSplitter.kt from
-- intellij-community platform/util/diff, Apache 2.0).
--
-- Purpose: inside one changed line-block, IntelliJ derives the visible
-- sub-block row alignment from *word* matching — tokenize both sides,
-- Myers-diff the word tokens, slide word matches to whitespace boundaries,
-- then split the block at matched newlines / matched first-words-in-line
-- with merge/squash rules. This module reproduces that split so merged
-- chunks' sub_hunks match the IDE's row pairing.
--
-- Pure Lua, no nvim API. Text offsets are 0-based byte offsets (IntelliJ
-- uses UTF-16 offsets; byte offsets are used consistently on both sides, so
-- boundaries land identically for any valid UTF-8 input). Word indices are
-- 0-based like the original; -1 and #words denote the text boundaries.

local myers = require("diffbandit.diff.myers_lcs")

local M = {}

-- TrimUtil.isPunctuation: ASCII punctuation minus '_'.
local function is_punctuation(b)
  if b == 95 then
    return false
  end
  return (b >= 33 and b <= 47)
    or (b >= 58 and b <= 64)
    or (b >= 91 and b <= 96)
    or (b >= 123 and b <= 126)
end

local function is_space_byte(b)
  return b == 32 or b == 9 or b == 10 or b == 13
end

-- TrimUtil.isContinuousScript, approximated over codepoint ranges: scripts
-- written without spaces get one word per character. Covers the common
-- ranges (CJK, kana, Thai); other non-ASCII codepoints count as word parts,
-- matching the original's default.
local function is_continuous_script(cp)
  if cp < 128 then
    return false
  end
  return (cp >= 0x2E80 and cp <= 0x9FFF) -- CJK radicals..unified ideographs (incl. kana)
    or (cp >= 0xF900 and cp <= 0xFAFF) -- CJK compatibility ideographs
    or (cp >= 0x20000 and cp <= 0x2FA1F) -- CJK extensions
    or (cp >= 0x0E00 and cp <= 0x0E7F) -- Thai
    or (cp >= 0xA980 and cp <= 0xA9DF) -- Javanese
end

-- Iterate UTF-8 codepoints: returns cp, byte length at 1-based position i.
local function codepoint_at(text, i)
  local b = text:byte(i)
  if b < 0x80 then
    return b, 1
  elseif b < 0xE0 then
    return ((b - 0xC0) * 0x40) + (text:byte(i + 1) or 0) - 0x80, 2
  elseif b < 0xF0 then
    return ((b - 0xE0) * 0x1000) + ((text:byte(i + 1) or 0x80) - 0x80) * 0x40
      + ((text:byte(i + 2) or 0x80) - 0x80), 3
  else
    return ((b - 0xF0) * 0x40000) + ((text:byte(i + 1) or 0x80) - 0x80) * 0x1000
      + ((text:byte(i + 2) or 0x80) - 0x80) * 0x40 + ((text:byte(i + 3) or 0x80) - 0x80), 4
  end
end

-- ByWordRt.getInlineChunks: word chunks (maximal alpha runs; continuous
-- scripts one char per word) and newline chunks. Offsets 0-based half-open.
-- `key` is the equality token: word content, or "\n" for newlines (the
-- classes are disjoint since words never contain whitespace).
function M.tokenize(text)
  local chunks = {}
  local len = #text
  local i = 1 -- 1-based byte position
  local word_start = nil -- 0-based

  while i <= len do
    local cp, width = codepoint_at(text, i)
    local is_alpha = not (cp < 128 and (is_space_byte(cp) or is_punctuation(cp)))
    local is_word_part = is_alpha and not is_continuous_script(cp)

    if is_word_part then
      if not word_start then
        word_start = i - 1
      end
    else
      if word_start then
        chunks[#chunks + 1] = { s = word_start, e = i - 1, newline = false, key = text:sub(word_start + 1, i - 1) }
        word_start = nil
      end
      if is_alpha then
        -- continuous script: one word per character
        chunks[#chunks + 1] = { s = i - 1, e = i - 1 + width, newline = false, key = text:sub(i, i + width - 1) }
      elseif cp == 10 then
        chunks[#chunks + 1] = { s = i - 1, e = i, newline = true, key = "\n" }
      end
    end
    i = i + width
  end
  if word_start then
    chunks[#chunks + 1] = { s = word_start, e = len, newline = false, key = text:sub(word_start + 1, len) }
  end
  return chunks
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

local function has_whitespace_between(text, from, to)
  for i = from + 1, to do -- 0-based half-open [from, to) -> 1-based bytes
    if is_space_byte(text:byte(i) or 32) then
      return true
    end
  end
  return false
end

-- ChunkOptimizer.WordChunkOptimizer: slide word-level change boundaries so
-- matched runs align with whitespace-separated "sentences".
local function optimize_word_chunks(text1, text2, words1, words2, unchanged)
  local n1, n2 = #words1, #words2

  local function eq(i1, i2)
    return words1[i1 + 1].key == words2[i2 + 1].key
  end

  local function is_separated(text, w1, w2)
    if w1.newline or w2.newline then
      return true
    end
    return has_whitespace_between(text, w1.e, w2.s)
  end

  local function find_sequence_edge_shift(text, words, offset, count, left_to_right)
    for i = 0, count - 1 do
      local w1, w2
      if left_to_right then
        w1 = words[offset + i + 1]
        w2 = words[offset + i + 2]
      else
        w1 = words[offset - i]
        w2 = words[offset - i + 1]
      end
      if not w1 or not w2 then
        return -1
      end
      if is_separated(text, w1, w2) then
        return i + 1
      end
    end
    return -1
  end

  local function get_shift(touch_left, equal_forward, equal_backward, r2)
    local touch_words = touch_left and words1 or words2
    local touch_text = touch_left and text1 or text2
    local touch_start = touch_left and r2.start1 or r2.start2

    local before = touch_words[touch_start] -- words[touchStart - 1], 0-based
    local at = touch_words[touch_start + 1]
    if not before or not at or is_separated(touch_text, before, at) then
      return 0
    end

    local left_shift = find_sequence_edge_shift(touch_text, touch_words, touch_start, equal_forward, true)
    if left_shift > 0 then
      return left_shift
    end
    local right_shift = find_sequence_edge_shift(touch_text, touch_words, touch_start - 1, equal_backward, false)
    if right_shift > 0 then
      return -right_shift
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
      local equal_forward, equal_backward = 0, 0
      do
        local e1 = math.min(r1.end1 + count2, n1)
        local e2 = math.min(r1.end2 + count2, n2)
        while r1.end1 + equal_forward < e1 and r1.end2 + equal_forward < e2
          and eq(r1.end1 + equal_forward, r1.end2 + equal_forward) do
          equal_forward = equal_forward + 1
        end
        local s1 = math.max(r2.start1 - count1, 0)
        local s2 = math.max(r2.start2 - count1, 0)
        while r2.start1 - equal_backward > s1 and r2.start2 - equal_backward > s2
          and eq(r2.start1 - equal_backward - 1, r2.start2 - equal_backward - 1) do
          equal_backward = equal_backward + 1
        end
      end
      if equal_forward == 0 and equal_backward == 0 then
        return
      end
      if equal_forward == count2 then
        table.remove(ranges)
        table.remove(ranges)
        ranges[#ranges + 1] = {
          start1 = r1.start1, end1 = r1.end1 + count2,
          start2 = r1.start2, end2 = r1.end2 + count2,
        }
      elseif equal_backward == count1 then
        table.remove(ranges)
        table.remove(ranges)
        ranges[#ranges + 1] = {
          start1 = r2.start1 - count1, end1 = r2.end1,
          start2 = r2.start2 - count1, end2 = r2.end2,
        }
      else
        local touch_left = r1.end1 == r2.start1
        local shift = get_shift(touch_left, equal_forward, equal_backward, r2)
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
  return ranges
end

-- LineFragmentSplitter: split the block into 'logically different' word
-- blocks at matched newlines / matched first-words-in-line, with the
-- original merge/squash rules. Returns word blocks with offset ranges and
-- newline counts per side.
local function split_word_blocks(text1, text2, words1, words2, unchanged)
  local n1, n2 = #words1, #words2
  local result = {}
  local last1, last2 = -1, -1
  local pending = nil

  local function get_offset(words, text, index)
    if index == -1 then
      return 0
    end
    if index == #words then
      return #text
    end
    return words[index + 1].e
  end

  local function strip_ws(s)
    return (s:gsub("%s+", ""))
  end

  local function has_words_inside(block)
    for i = block.words.start1, block.words.end1 - 1 do
      if not words1[i + 1].newline then
        return true
      end
    end
    for i = block.words.start2, block.words.end2 - 1 do
      if not words2[i + 1].newline then
        return true
      end
    end
    return false
  end

  local function create_chunk(s1, s2, e1, e2, has_equal_words)
    local so1 = get_offset(words1, text1, s1)
    local so2 = get_offset(words2, text2, s2)
    local eo1 = get_offset(words1, text1, e1)
    local eo2 = get_offset(words2, text2, e2)
    local block = {
      words = {
        start1 = math.max(0, s1 + 1), end1 = math.min(e1 + 1, n1),
        start2 = math.max(0, s2 + 1), end2 = math.min(e2 + 1, n2),
      },
      offsets = { start1 = so1, end1 = eo1, start2 = so2, end2 = eo2 },
    }
    return {
      block = block,
      has_equal_words = has_equal_words,
      has_words_inside = has_words_inside(block),
      is_equal_iw = strip_ws(text1:sub(so1 + 1, eo1)) == strip_ws(text2:sub(so2 + 1, eo2)),
    }
  end

  local function should_merge(c1, c2)
    if not c1.has_equal_words and not c2.has_equal_words then
      return true -- combine lines matched only by '\n'
    end
    if c1.is_equal_iw and c2.is_equal_iw then
      return true -- combine whitespace-only changed lines
    end
    if not c1.has_words_inside or not c2.has_words_inside then
      return true -- squash block without words in it
    end
    return false
  end

  local function merge_chunks(c1, c2)
    local b1, b2 = c1.block, c2.block
    local block = {
      words = {
        start1 = b1.words.start1, end1 = b2.words.end1,
        start2 = b1.words.start2, end2 = b2.words.end2,
      },
      offsets = {
        start1 = b1.offsets.start1, end1 = b2.offsets.end1,
        start2 = b1.offsets.start2, end2 = b2.offsets.end2,
      },
    }
    return {
      block = block,
      has_equal_words = c1.has_equal_words or c2.has_equal_words,
      has_words_inside = c1.has_words_inside or c2.has_words_inside,
      is_equal_iw = c1.is_equal_iw and c2.is_equal_iw,
    }
  end

  local function add_line_chunk(e1, e2, has_equal_words)
    if last1 > e1 or last2 > e2 then
      return
    end
    local chunk = create_chunk(last1, last2, e1, e2, has_equal_words)
    local o = chunk.block.offsets
    if o.start1 == o.end1 and o.start2 == o.end2 then
      return
    end
    if pending then
      if should_merge(pending, chunk) then
        chunk = merge_chunks(pending, chunk)
      else
        result[#result + 1] = pending.block
      end
    end
    pending = chunk
    last1, last2 = e1, e2
  end

  local function is_first_in_line(words, index)
    if index == 0 then
      return true
    end
    return words[index].newline -- words[(index - 1) + 1]
  end

  local has_equal_words = false
  for _, range in ipairs(unchanged) do
    for i = 0, (range.end1 - range.start1) - 1 do
      local index1 = range.start1 + i
      local index2 = range.start2 + i
      if words1[index1 + 1].newline and words2[index2 + 1].newline then
        add_line_chunk(index1, index2, has_equal_words)
        has_equal_words = false
      else
        if is_first_in_line(words1, index1) and is_first_in_line(words2, index2) then
          add_line_chunk(index1 - 1, index2 - 1, has_equal_words)
          has_equal_words = false
        end
        has_equal_words = true
      end
    end
  end
  add_line_chunk(n1, n2, has_equal_words)

  if pending then
    result[#result + 1] = pending.block
  end
  return result
end

-- Monotonic matched-region collector (DiffIterableUtil.ChangeBuilder):
-- everything between marked-equal regions becomes a change.
local function new_change_builder(n1, n2)
  local b = { index1 = 0, index2 = 0, changes = {} }
  function b.mark_equal(s1, s2, e1, e2)
    if s1 == e1 and s2 == e2 then
      return
    end
    if b.index1 ~= s1 or b.index2 ~= s2 then
      b.changes[#b.changes + 1] = { start1 = b.index1, end1 = s1, start2 = b.index2, end2 = s2 }
    end
    b.index1, b.index2 = e1, e2
  end
  function b.finish()
    if b.index1 ~= n1 or b.index2 ~= n2 then
      b.changes[#b.changes + 1] = { start1 = b.index1, end1 = n1, start2 = b.index2, end2 = n2 }
    end
    return b.changes
  end
  return b
end

-- ByCharRt.comparePunctuation: match punctuation chars between two texts;
-- returns the matched (unchanged) char ranges.
local function compare_punctuation(text1, text2)
  local function punctuation_chars(text)
    local chars, offsets = {}, {}
    for i = 1, #text do
      local byte = text:byte(i)
      if is_punctuation(byte) then
        chars[#chars + 1] = string.char(byte)
        offsets[#offsets + 1] = i - 1
      end
    end
    return chars, offsets
  end

  local chars1, offsets1 = punctuation_chars(text1)
  local chars2, offsets2 = punctuation_chars(text2)
  local unchanged = unchanged_from_changes(myers.diff(chars1, chars2), #chars1, #chars2)

  local builder = new_change_builder(#text1, #text2)
  for _, range in ipairs(unchanged) do
    for i = 0, (range.end1 - range.start1) - 1 do
      local o1 = offsets1[range.start1 + i + 1]
      local o2 = offsets2[range.start2 + i + 1]
      builder.mark_equal(o1, o2, o1 + 1, o2 + 1)
    end
  end
  return unchanged_from_changes(builder.finish(), #text1, #text2)
end

-- ByWordRt.AdjustmentPunctuationMatcher: given matched words, build the
-- char-level matching — matched words map 1:1; the punctuation runs between
-- them are paired via comparePunctuation (including the "complex" case where
-- one side's gap faces two gaps around unmatched words on the other side).
local function match_adjustment_delimiters(text1, text2, words1, words2, unchanged)
  local len1, len2 = #text1, #text2
  local n1, n2 = #words1, #words2
  local builder = new_change_builder(len1, len2)

  local last = nil -- pending forward-matched gap {s1, s2, e1, e2}

  local function start_offset(words, index)
    return words[index + 1].s
  end
  local function end_offset(words, index)
    return words[index + 1].e
  end

  local function match_range(s1, s2, e1, e2)
    if s1 == e1 and s2 == e2 then
      return
    end
    local matched = compare_punctuation(text1:sub(s1 + 1, e1), text2:sub(s2 + 1, e2))
    for _, ch in ipairs(matched) do
      builder.mark_equal(s1 + ch.start1, s2 + ch.start2, s1 + ch.end1, s2 + ch.end2)
    end
  end

  -- comparePunctuation2Side: compare one gap against two concatenated gaps,
  -- splitting the matched ranges at the concatenation seam.
  local function match_complex(one_text, one_start, two_text_a, a_start, two_text_b, b_start, mirrored)
    local merged = two_text_a .. two_text_b
    local matched = compare_punctuation(one_text, merged)
    local seam = #two_text_a
    for _, ch in ipairs(matched) do
      local pieces = {}
      if ch.end2 <= seam then
        pieces[1] = { ch.start1, ch.end1, ch.start2, ch.end2, a_start }
      elseif ch.start2 >= seam then
        pieces[1] = { ch.start1, ch.end1, ch.start2 - seam, ch.end2 - seam, b_start }
      else
        local len_a = seam - ch.start2
        pieces[1] = { ch.start1, ch.start1 + len_a, ch.start2, seam, a_start }
        pieces[2] = { ch.start1 + len_a, ch.end1, 0, ch.end2 - seam, b_start }
      end
      for _, p in ipairs(pieces) do
        local os1, oe1, os2, oe2, other_base = p[1], p[2], p[3], p[4], p[5]
        if mirrored then
          builder.mark_equal(other_base + os2, one_start + os1, other_base + oe2, one_start + oe1)
        else
          builder.mark_equal(one_start + os1, other_base + os2, one_start + oe1, other_base + oe2)
        end
      end
    end
  end

  local function match_backward_range(s1, s2, e1, e2)
    assert(last, "match_forward must precede match_backward")
    if last.s1 == s1 and last.s2 == s2 then
      -- adjacent matched words: one shared gap
      match_range(s1, s2, e1, e2)
      return
    end
    if last.s1 < s1 and last.s2 < s2 then
      -- both sides have unmatched words between: two independent gaps
      match_range(last.s1, last.s2, last.e1, last.e2)
      match_range(s1, s2, e1, e2)
      return
    end
    -- one side is adjacent, the other has unmatched words between
    if last.s1 == s1 and last.e1 == e1 then
      match_complex(text1:sub(s1 + 1, e1), s1,
        text2:sub(last.s2 + 1, last.e2), last.s2,
        text2:sub(s2 + 1, e2), s2, false)
    elseif last.s2 == s2 and last.e2 == e2 then
      match_complex(text2:sub(s2 + 1, e2), s2,
        text1:sub(last.s1 + 1, last.e1), last.s1,
        text1:sub(s1 + 1, e1), s1, true)
    end
  end

  local function match_backward(index1, index2)
    local s1 = index1 == 0 and 0 or end_offset(words1, index1 - 1)
    local s2 = index2 == 0 and 0 or end_offset(words2, index2 - 1)
    local e1 = index1 == n1 and len1 or start_offset(words1, index1)
    local e2 = index2 == n2 and len2 or start_offset(words2, index2)
    match_backward_range(s1, s2, e1, e2)
    last = nil
  end

  local function match_forward(index1, index2)
    local s1 = index1 == -1 and 0 or end_offset(words1, index1)
    local s2 = index2 == -1 and 0 or end_offset(words2, index2)
    local e1 = (index1 + 1 == n1) and len1 or start_offset(words1, index1 + 1)
    local e2 = (index2 + 1 == n2) and len2 or start_offset(words2, index2 + 1)
    last = { s1 = s1, s2 = s2, e1 = e1, e2 = e2 }
  end

  match_forward(-1, -1)
  for _, range in ipairs(unchanged) do
    for i = 0, (range.end1 - range.start1) - 1 do
      local index1 = range.start1 + i
      local index2 = range.start2 + i
      match_backward(index1, index2)
      builder.mark_equal(start_offset(words1, index1), start_offset(words2, index2),
        end_offset(words1, index1), end_offset(words2, index2))
      match_forward(index1, index2)
    end
  end
  match_backward(n1, n2)

  return builder.finish()
end

-- ByWordRt.DefaultCorrector: trim whitespace-only edges from each change
-- (TrimUtil.expandWhitespacesForward/Backward: only equal whitespace pairs).
local function default_corrector(changes, text1, text2)
  local function is_ws(text, i) -- 0-based
    return is_space_byte(text:byte(i + 1) or 0)
  end
  local out = {}
  for _, range in ipairs(changes) do
    local s1, s2, e1, e2 = range.start1, range.start2, range.end1, range.end2
    local end_cut = 0
    while s1 < e1 - end_cut and s2 < e2 - end_cut
      and text1:byte(e1 - end_cut) == text2:byte(e2 - end_cut)
      and is_ws(text1, e1 - end_cut - 1) do
      end_cut = end_cut + 1
    end
    local start_cut = 0
    while s1 + start_cut < e1 - end_cut and s2 + start_cut < e2 - end_cut
      and text1:byte(s1 + start_cut + 1) == text2:byte(s2 + start_cut + 1)
      and is_ws(text1, s1 + start_cut) do
      start_cut = start_cut + 1
    end
    local r = {
      start1 = s1 + start_cut, end1 = e1 - end_cut,
      start2 = s2 + start_cut, end2 = e2 - end_cut,
    }
    if r.start1 ~= r.end1 or r.start2 ~= r.end2 then
      out[#out + 1] = r
    end
  end
  return out
end

-- ByWordRt.compare for the DEFAULT policy: inner difference fragments
-- between two texts, as 0-based half-open char ranges.
function M.inner_fragments(text1, text2)
  local words1 = M.tokenize(text1)
  local words2 = M.tokenize(text2)

  local keys1, keys2 = {}, {}
  for i, w in ipairs(words1) do
    keys1[i] = w.key
  end
  for i, w in ipairs(words2) do
    keys2[i] = w.key
  end

  local unchanged = unchanged_from_changes(myers.diff(keys1, keys2), #words1, #words2)
  unchanged = optimize_word_chunks(text1, text2, words1, words2, unchanged)

  local changes = match_adjustment_delimiters(text1, text2, words1, words2, unchanged)
  return default_corrector(changes, text1, text2)
end

local function count_newlines(words, from, to)
  local count = 0
  for i = from, to - 1 do
    if words[i + 1].newline then
      count = count + 1
    end
  end
  return count
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

-- ByWordRt.compareAndSplit: given the two texts of one changed block
-- (newline-joined lines, no trailing newline) and their line counts, run the
-- word matching ONCE over the whole block, split into sub-blocks
-- (LineFragmentSplitter), and compute each sub-block's inner difference
-- fragments from that same matching restricted to the sub-block
-- (SubiterableDiffIterable) — fragment boundaries genuinely differ from a
-- fresh per-sub-block comparison, and the IDE uses the block-scoped result.
--
-- Returns a list of sub-blocks:
--   lines:     block-local 0-based half-open line ranges {s1, e1, s2, e2}
--              (createInnerWordFragments mapping: newline counts, last block
--              clamps to the block end)
--   offsets:   sub-block start offsets in the block texts {start1, start2}
--   fragments: inner difference char ranges, relative to the sub-block texts
function M.compare_and_split(text1, text2, count1, count2)
  local words1 = M.tokenize(text1)
  local words2 = M.tokenize(text2)
  local n1, n2 = #words1, #words2

  local keys1, keys2 = {}, {}
  for i, w in ipairs(words1) do
    keys1[i] = w.key
  end
  for i, w in ipairs(words2) do
    keys2[i] = w.key
  end

  local unchanged = unchanged_from_changes(myers.diff(keys1, keys2), n1, n2)
  unchanged = optimize_word_chunks(text1, text2, words1, words2, unchanged)
  local changed = changes_from_unchanged(unchanged, n1, n2)
  local blocks = split_word_blocks(text1, text2, words1, words2, unchanged)

  local result = {}
  local line1, line2 = 0, 0
  local index = 1 -- first changed range that may affect the current block

  for i, block in ipairs(blocks) do
    local w, o = block.words, block.offsets

    while index <= #changed do
      local r = changed[index]
      if r.end1 < w.start1 or r.end2 < w.start2 then
        index = index + 1
      else
        break
      end
    end

    -- SubiterableDiffIterable: clip the block-wide changed ranges to this
    -- sub-block's word range, shifted to local word indices.
    local local_changes = {}
    local j = index
    while j <= #changed do
      local r = changed[j]
      j = j + 1
      if r.end1 < w.start1 or r.end2 < w.start2 then
        -- before the sub-block
      elseif r.start1 > w.end1 or r.start2 > w.end2 then
        break
      else
        local nr = {
          start1 = math.max(w.start1, r.start1) - w.start1,
          end1 = math.min(w.end1, r.end1) - w.start1,
          start2 = math.max(w.start2, r.start2) - w.start2,
          end2 = math.min(w.end2, r.end2) - w.start2,
        }
        if nr.start1 ~= nr.end1 or nr.start2 ~= nr.end2 then
          local_changes[#local_changes + 1] = nr
        end
      end
    end

    local subtext1 = text1:sub(o.start1 + 1, o.end1)
    local subtext2 = text2:sub(o.start2 + 1, o.end2)
    local subwords1, subwords2 = {}, {}
    for wi = w.start1, w.end1 - 1 do
      local word = words1[wi + 1]
      subwords1[#subwords1 + 1] = { s = word.s - o.start1, e = word.e - o.start1, newline = word.newline }
    end
    for wi = w.start2, w.end2 - 1 do
      local word = words2[wi + 1]
      subwords2[#subwords2 + 1] = { s = word.s - o.start2, e = word.e - o.start2, newline = word.newline }
    end

    local sub_unchanged = unchanged_from_changes(local_changes, #subwords1, #subwords2)
    local fragments = match_adjustment_delimiters(subtext1, subtext2, subwords1, subwords2, sub_unchanged)
    fragments = default_corrector(fragments, subtext1, subtext2)

    local e1, e2
    if i ~= #blocks then
      e1 = line1 + count_newlines(words1, w.start1, w.end1)
      e2 = line2 + count_newlines(words2, w.start2, w.end2)
    else
      e1 = count1
      e2 = count2
    end
    result[#result + 1] = {
      lines = { s1 = line1, e1 = e1, s2 = line2, e2 = e2 },
      offsets = { start1 = o.start1, start2 = o.start2 },
      fragments = fragments,
    }
    line1, line2 = e1, e2
  end
  return result
end

return M
