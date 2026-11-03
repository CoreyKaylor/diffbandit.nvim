local diff = require("diffbandit.diff")
local text = require("diffbandit.util.text")

local M = {}

local function hunk_base_start(hunk)
  return hunk.left.start
end

local function hunk_base_end(hunk)
  if hunk.left.count <= 0 then
    return hunk.left.start
  end
  return hunk.left.start + hunk.left.count - 1
end

local function ranges_overlap(left, right)
  return hunk_base_start(left) <= hunk_base_end(right) and hunk_base_start(right) <= hunk_base_end(left)
end

local function merged_base_count(left, right, start_row, end_row)
  if (not left or left.left.count <= 0) and (not right or right.left.count <= 0) then
    return 0
  end
  return math.max(0, end_row - start_row + 1)
end

local function hunk_replacement(lines, hunk)
  local replacement = {}
  for index = hunk.right.start, hunk.right.start + hunk.right.count - 1 do
    replacement[#replacement + 1] = lines[index] or ""
  end
  return replacement
end

local function line_ending(value)
  if not value or value == "" then
    return "none"
  end
  local crlf = value:find("\r\n", 1, true) ~= nil
  local lf = value:find("[^\r]\n") ~= nil
  if crlf and lf then
    return "mixed"
  elseif crlf then
    return "crlf"
  end
  return "lf"
end

function M.line_ending_warning(parts)
  local seen = {}
  for _, value in pairs(parts) do
    local ending = line_ending(value)
    if ending ~= "none" then
      seen[ending] = true
    end
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  if count > 1 then
    return "line endings differ across conflict stages"
  end
  return nil
end

function M.build_regions(base_lines, local_lines, remote_lines, config)
  local base_text = text.to_text(base_lines)
  local local_hunks = diff.compute_hunks(base_text, text.to_text(local_lines), (config or {}).diff or {})
  local remote_hunks = diff.compute_hunks(base_text, text.to_text(remote_lines), (config or {}).diff or {})
  if type(local_hunks) ~= "table" then
    local_hunks = {}
  end
  if type(remote_hunks) ~= "table" then
    remote_hunks = {}
  end

  local local_conflicted = {}
  local remote_conflicted = {}
  local conflicts = {}
  for local_index, local_hunk in ipairs(local_hunks) do
    for remote_index, remote_hunk in ipairs(remote_hunks) do
      if ranges_overlap(local_hunk, remote_hunk) then
        local_conflicted[local_index] = true
        remote_conflicted[remote_index] = true
        local start_row = math.min(hunk_base_start(local_hunk), hunk_base_start(remote_hunk))
        local end_row = math.max(hunk_base_end(local_hunk), hunk_base_end(remote_hunk))
        local base_count = merged_base_count(local_hunk, remote_hunk, start_row, end_row)
        conflicts[#conflicts + 1] = {
          type = "conflict",
          base_start = start_row,
          base_count = base_count,
          result_start = start_row,
          result_count = base_count,
          local_hunk = local_hunk,
          remote_hunk = remote_hunk,
          local_replacement = hunk_replacement(local_lines, local_hunk),
          remote_replacement = hunk_replacement(remote_lines, remote_hunk),
        }
      end
    end
  end

  table.sort(conflicts, function(left, right)
    return left.base_start < right.base_start
  end)

  local non_conflicting = {}
  for index, hunk in ipairs(local_hunks) do
    if not local_conflicted[index] then
      non_conflicting[#non_conflicting + 1] = {
        side = "local",
        base_start = hunk_base_start(hunk),
        base_count = hunk.left.count,
        hunk = hunk,
        replacement = hunk_replacement(local_lines, hunk),
      }
    end
  end
  for index, hunk in ipairs(remote_hunks) do
    if not remote_conflicted[index] then
      non_conflicting[#non_conflicting + 1] = {
        side = "remote",
        base_start = hunk_base_start(hunk),
        base_count = hunk.left.count,
        hunk = hunk,
        replacement = hunk_replacement(remote_lines, hunk),
      }
    end
  end
  table.sort(non_conflicting, function(left, right)
    return left.base_start > right.base_start
  end)

  return conflicts, non_conflicting, local_hunks, remote_hunks
end

-- Base-coordinate extent of a hunk side as a numeric interval: a range of
-- count > 0 covers lines [start, start + count - 1]; an insertion (count 0)
-- sits in the gap after line `start`, i.e. at start + 0.5.
local function base_extent(start, count)
  if (count or 0) > 0 then
    return start, start + count - 1
  end
  return start + 0.5, start + 0.5
end

--- Set a region's result row count, keeping its start in the right
--- convention: a non-empty region starts at its first row, an empty one
--- sits after row `result_start` (like an insertion hunk). Filling an empty
--- region therefore moves its start down one row, and emptying one moves it
--- up one.
function M.resize_region(region, new_count)
  local old = region.result_count or 0
  new_count = math.max(0, new_count or 0)
  if old == 0 and new_count > 0 then
    region.result_start = (region.result_start or 0) + 1
  elseif old > 0 and new_count == 0 then
    region.result_start = (region.result_start or 1) - 1
  end
  region.result_count = new_count
end

--- Keep conflict regions' result rows in step with an edit of the result
--- that replaced `count` rows at `start` (count 0: inserted after row
--- `start`) with `new_count` rows. Regions wholly below the edit move by the
--- line delta; a region containing the edit grows or shrinks by it. Works
--- for any edit — a whole conflict, part of one, or a non-conflicting hunk —
--- so later conflicts never point at stale rows. An edit that straddles a
--- region boundary (only a hand edit can) leaves that region as it was.
function M.track_result_edit(regions, start, count, new_count)
  local delta = (new_count or 0) - (count or 0)
  local edit_first, edit_last = base_extent(start, count)
  for _, region in ipairs(regions or {}) do
    local rs = region.result_start or 1
    local r_first, r_last = base_extent(rs, region.result_count or 0)
    if r_first > edit_last then
      region.result_start = rs + delta
    elseif r_first <= edit_first and edit_last <= r_last then
      M.resize_region(region, (region.result_count or 0) + delta)
    elseif edit_first <= r_first and r_last <= edit_last then
      -- The edit swallowed the whole region (e.g. accepted across it).
      local n = new_count or 0
      region.result_start = n > 0 and start or (count > 0 and start - 1 or start)
      region.result_count = n
    end
  end
end

--- Plan where each non-conflicting hunk lands in the CURRENT result.
---
--- The result starts as base but conflict resolutions and hand edits change
--- its line count, so base line numbers go stale. Diff base against the
--- result, shift each item by the line delta of every result hunk wholly
--- above it, and skip items whose base range the result already changed
--- (applied before, accepted individually, or edited by hand).
---
--- items: the `non_conflicting` list (base_start/base_count/replacement).
--- Returns { edits, skipped } where edits are bottom-to-top
--- { start, count, replacement, item } in result coordinates (count 0:
--- insert after row `start`), ready for text.replace_range.
function M.plan_non_conflicting(base_lines, result_lines, items, config)
  local result_hunks = diff.compute_hunks(text.to_text(base_lines), text.to_text(result_lines),
    (config or {}).diff or {})
  if type(result_hunks) ~= "table" then
    result_hunks = {}
  end

  local edits, skipped = {}, 0
  for _, item in ipairs(items or {}) do
    local i_first, i_last = base_extent(item.base_start, item.base_count)
    local offset, touched = 0, false
    for _, h in ipairs(result_hunks) do
      local h_first, h_last = base_extent(h.left.start, h.left.count)
      if h_last < i_first then
        offset = offset + (h.right.count - h.left.count)
      elseif h_first <= i_last then
        touched = true
        break
      end
    end
    if touched then
      skipped = skipped + 1
    else
      edits[#edits + 1] = {
        start = item.base_start + offset,
        count = item.base_count or 0,
        replacement = item.replacement or {},
        item = item,
      }
    end
  end
  -- Bottom-to-top: applying a lower edit never moves a higher one.
  table.sort(edits, function(a, b)
    return a.start > b.start
  end)
  return { edits = edits, skipped = skipped }
end

M._private = {
  hunk_base_start = hunk_base_start,
  hunk_base_end = hunk_base_end,
  ranges_overlap = ranges_overlap,
  merged_base_count = merged_base_count,
  hunk_replacement = hunk_replacement,
  line_ending = line_ending,
}

return M
