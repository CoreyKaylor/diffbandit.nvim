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

M._private = {
  hunk_base_start = hunk_base_start,
  hunk_base_end = hunk_base_end,
  ranges_overlap = ranges_overlap,
  merged_base_count = merged_base_count,
  hunk_replacement = hunk_replacement,
  line_ending = line_ending,
}

return M
