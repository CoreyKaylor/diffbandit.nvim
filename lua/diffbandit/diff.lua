local text = require("diffbandit.text")

local M = {}

function M.read_file(path)
  local ok, contents = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, nil, string.format("Unable to read file: %s", contents)
  end
  return contents, text.to_text(contents)
end

function M.compute_hunks(left_text, right_text, opts)
  local diff_opts = {
    result_type = opts.result_type or "indices",
    algorithm = opts.algorithm,
    linematch = opts.linematch,
    ignore_whitespace = opts.ignore_whitespace,
  }

  -- Top-level hunks use line diffs; word/char spans are computed later per line

  local ok, raw = pcall(vim.diff, left_text, right_text, diff_opts)
  if not ok then
    return {}, string.format("diff failed: %s", raw)
  end

  local hunks = {}
  for idx, h in ipairs(raw or {}) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    local htype
    if count_a == 0 and count_b > 0 then
      htype = "add"
    elseif count_b == 0 and count_a > 0 then
      htype = "delete"
    else
      htype = "change"
    end

    hunks[#hunks + 1] = {
      index = idx,
      type = htype,
      left = {
        start = start_a,
        count = count_a,
      },
      right = {
        start = start_b,
        count = count_b,
      },
    }
  end

  return hunks, nil
end

-- Compute char/word spans for a pair of lines; returns list of {s, e} (1-indexed, inclusive)
function M.changed_spans(left_line, right_line)
  if left_line == right_line then
    return {
      left = {},
      right_changes = {},
      prefix_len = 0,
      right_len = #right_line,
      change_end = 0,
      add_start = nil,
    }
  end

  local left_len = #left_line
  local right_len = #right_line

  local prefix = 0
  local max_prefix = math.min(left_len, right_len)
  while prefix < max_prefix do
    local l_char = left_line:sub(prefix + 1, prefix + 1)
    local r_char = right_line:sub(prefix + 1, prefix + 1)
    if l_char ~= r_char then
      break
    end
    prefix = prefix + 1
  end

  local suffix = 0
  local max_suffix = math.min(left_len - prefix, right_len - prefix)
  while suffix < max_suffix do
    local l_char = left_line:sub(left_len - suffix, left_len - suffix)
    local r_char = right_line:sub(right_len - suffix, right_len - suffix)
    if l_char ~= r_char then
      break
    end
    suffix = suffix + 1
  end

  local left_mid_len = math.max(0, left_len - prefix - suffix)
  local right_mid_len = math.max(0, right_len - prefix - suffix)

  local spans_left = {}
  local spans_right_changes = {}

  local change_len = math.min(left_mid_len, right_mid_len)
  local addition_len = math.max(0, right_mid_len - change_len)

  local left_span_start = prefix + 1
  local right_change_start = prefix + 1
  local right_add_start = right_change_start + change_len

  local function is_word_char(char)
    return char ~= nil and char:match("[%w_]") ~= nil
  end

  if left_mid_len > 0 and addition_len > 0 then
    local before_add = right_line:sub(right_add_start - 1, right_add_start - 1)
    local at_add = right_line:sub(right_add_start, right_add_start)
    if is_word_char(before_add) and is_word_char(at_add) then
      change_len = right_mid_len
      addition_len = 0
      right_add_start = right_change_start + change_len
    end
  end

  local shared_change_suffix = 0
  if change_len > 0 and addition_len > 0 then
    while shared_change_suffix < change_len do
      local left_pos = left_span_start + left_mid_len - shared_change_suffix - 1
      local right_pos = right_change_start + change_len - shared_change_suffix - 1
      if left_line:sub(left_pos, left_pos) ~= right_line:sub(right_pos, right_pos) then
        break
      end
      shared_change_suffix = shared_change_suffix + 1
    end
  end

  local left_emphasis_len = math.max(0, left_mid_len - shared_change_suffix)
  local right_emphasis_len = math.max(0, change_len - shared_change_suffix)

  if left_emphasis_len > 0 then
    table.insert(spans_left, { left_span_start, left_span_start + left_emphasis_len - 1 })
  end

  if right_emphasis_len > 0 then
    table.insert(spans_right_changes, { right_change_start, right_change_start + right_emphasis_len - 1 })
  end

  local has_change = change_len > 0
  local has_addition = addition_len > 0

  return {
    left = spans_left,
    right_changes = spans_right_changes,
    prefix_len = prefix,
    right_len = right_len,
    change_end = has_change and (right_change_start + change_len - 1) or prefix,
    add_start = has_addition and right_add_start or nil,
  }
end

return M
