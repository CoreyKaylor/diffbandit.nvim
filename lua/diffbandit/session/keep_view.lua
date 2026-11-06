-- Where the panes should sit after a hunk action changes their text. The focused
-- pane follows its own lines across the change, and the other pane follows the
-- focused one through the new alignment, keeping any offset the reviewer had
-- scrolled the two panes apart by.
local nvim = require("diffbandit.util.nvim")
local view_builder = require("diffbandit.diff.view")

local M = {}

local function pane_state(win, source)
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  cursor = ok and cursor or { 1, 0 }
  return {
    lines = source and source.lines or {},
    cursor = cursor,
    topline = nvim.get_win_view_topline(win) or cursor[1],
  }
end

--- Snapshot taken before the action, since writing the file can move the
--- cursor of a pane showing its live buffer.
function M.capture(session)
  local win = vim.api.nvim_get_current_win()
  local focused_left = win == session.left_win or win == session.left_num_win
  return {
    anchor = focused_left and "left" or "right",
    view = session.view,
    left = pane_state(session.left_win, session.left),
    right = pane_state(session.right_win, session.right),
  }
end

local function to_text(lines)
  return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

local function clamp(line, lines)
  return math.max(1, math.min(line, math.max(1, #lines)))
end

local function line_changes(old_lines, new_lines)
  return vim.diff(to_text(old_lines), to_text(new_lines), { result_type = "indices" })
end

--- A line's position in `new_lines`. A line inside a replaced region keeps its
--- offset where the replacement is long enough; one whose region was removed
--- lands on the line after the gap.
local function map_through(hunks, new_lines, line)
  local delta = 0
  for _, hunk in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
    if old_count == 0 then
      -- An insertion after old_start.
      if line <= old_start then
        break
      end
    else
      if line < old_start then
        break
      end
      if line < old_start + old_count then
        if new_count == 0 then
          return clamp(new_start + 1, new_lines)
        end
        return clamp(new_start + math.min(line - old_start, new_count - 1), new_lines)
      end
    end
    delta = delta + new_count - old_count
  end
  return clamp(line + delta, new_lines)
end

function M.map_line(old_lines, new_lines, line)
  return map_through(line_changes(old_lines, new_lines), new_lines, line)
end

--- New { cursor, topline } for each pane. Text that did not change keeps the
--- captured view exactly.
function M.plan(before, view, left_lines, right_lines)
  local new_lines = { left = left_lines or {}, right = right_lines or {} }
  if vim.deep_equal(before.left.lines, new_lines.left) and vim.deep_equal(before.right.lines, new_lines.right) then
    return {
      left = { cursor = before.left.cursor, topline = before.left.topline },
      right = { cursor = before.right.cursor, topline = before.right.topline },
    }
  end

  local anchor = before.anchor
  local other = anchor == "left" and "right" or "left"

  local anchor_changes = line_changes(before[anchor].lines, new_lines[anchor])
  local function anchored(line)
    return map_through(anchor_changes, new_lines[anchor], line)
  end
  local function followed(old_anchor_line, new_anchor_line, old_other_line)
    local old_counterpart = view_builder.counterpart_row(before.view.line_meta or {}, anchor, old_anchor_line)
    local new_counterpart = view_builder.counterpart_row(view.line_meta or {}, anchor, new_anchor_line)
    return clamp(new_counterpart + old_other_line - old_counterpart, new_lines[other])
  end

  local cursor = anchored(before[anchor].cursor[1])
  local topline = anchored(before[anchor].topline)
  return {
    [anchor] = {
      cursor = { cursor, before[anchor].cursor[2] },
      topline = topline,
    },
    [other] = {
      cursor = { followed(before[anchor].cursor[1], cursor, before[other].cursor[1]), before[other].cursor[2] },
      topline = followed(before[anchor].topline, topline, before[other].topline),
    },
  }
end

return M
