-- Number panes and the connector core read as one gutter (cell renderer):
-- each number pane is exactly one blank cell, the widest number, and one
-- blank cell wide; the separators between the number panes and the core are
-- invisible; and a one-column bridge over each of them carries the core's
-- edge cell across, so underlines and change bands run straight into the
-- triangles and wedges docked in the number panes.
local child_mod = require("helpers.child")
local state = require("helpers.state")
local files = child_mod.files

local child = child_mod.new({ lines = 40, columns = 140 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local function fail(message, detail)
  error(message .. (detail and ("\n" .. detail) or ""), 0)
end

-- Runs in the child: for every bridged separator of the current tab, the
-- bridge cell and the core and number cells beside it, plus the widths and
-- lines of the number panes. A headless child does not composite floats
-- into the default grid, so the bridge cell's style is resolved from its
-- float's marks (highest-priority background, any underline) while the core
-- and number cells come from the screen; grid 1 at the bridge column is the
-- hidden separator underneath, which must be blank.
local INSPECT = [[
local bridge = require("diffbandit.connector.bridge")
local wins = ...
local out = { panes = {}, rows = {} }
for _, w in ipairs(wins.nums) do
  local buf = vim.api.nvim_win_get_buf(w)
  out.panes[#out.panes + 1] = {
    width = vim.api.nvim_win_get_width(w),
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
  }
end
local context = vim.api.nvim_get_hl(0, { name = "DiffBanditConnectorContext", link = false })
out.context_bg = context.bg
local function cell(r, c)
  local info = vim.api.nvim__inspect_cell(1, r, c)
  local attrs = info[2] or {}
  return { text = info[1], underline = attrs.underline == true, bg = attrs.background or out.context_bg }
end
local function bridge_cell(win, r, base_bg)
  local buf = vim.api.nvim_win_get_buf(win)
  local bg, prio, underline = base_bg or out.context_bg, -1, false
  local text = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1]
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { r, 0 }, { r, -1 }, { details = true })) do
    local d = m[4]
    local chunk = d.virt_text and d.virt_text[1]
    local names = d.hl_group or (chunk and chunk[2])
    if chunk then
      text = chunk[1]
    end
    for _, name in ipairs(type(names) == "table" and names or { names }) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      if hl.underline then
        underline = true
      end
      if hl.bg and (d.priority or 4096) >= prio then
        bg, prio = hl.bg, d.priority or 4096
      end
    end
  end
  return { underline = underline, bg = bg, text = text }
end
local seps = bridge.separator_cells()
table.sort(seps, function(a, b) return a.col < b.col end)
out.separators = #seps
for i, sep in ipairs(seps) do
  -- Odd separators sit left of a core (core edge to their right), even ones
  -- right of it.
  local core_col = (i % 2 == 1) and (sep.col + 1) or (sep.col - 1)
  local tri_col = (i % 2 == 1) and (sep.col - 1) or (sep.col + 1)
  local height = vim.api.nvim_win_get_height(sep.win)
  for r = 0, height - 1 do
    local row = sep.row + r
    out.rows[#out.rows + 1] = {
      row = row, col = sep.col,
      separator = cell(row, sep.col).text,
      bridge = bridge_cell(sep.win, r), core = cell(row, core_col), number = cell(row, tri_col),
    }
  end
end
-- Outer (document | number pane) bridges: style from the number pane's
-- outer cell beside them.
local split = vim.api.nvim_get_hl(0, { name = "DiffBanditSplit", link = false })
out.outer = {}
local outer = bridge.separator_cells({ outer = true })
out.outer_separators = #outer
for _, sep in ipairs(outer) do
  local num_col = sep.side == "left" and (sep.col + 1) or (sep.col - 1)
  local height = vim.api.nvim_win_get_height(sep.win)
  for r = 0, height - 1 do
    local row = sep.row + r
    out.outer[#out.outer + 1] = {
      row = row, col = sep.col,
      bridge = bridge_cell(sep.win, r, split.bg), number = cell(row, num_col),
    }
  end
end
return out
]]

-- The first read after a highlight redefinition can resolve cells against a
-- stale attribute table (see helpers/child.lua capture): read until stable.
local function inspect(wins)
  local info = child:lua(INSPECT, { wins })
  for _ = 1, 20 do
    local again = child:lua(INSPECT, { wins })
    if vim.deep_equal(again, info) then
      break
    end
    info = again
  end
  return info
end

local TRIANGLES = { ["◤"] = true, ["◥"] = true, ["◣"] = true, ["◢"] = true }

local function check_bridges(info, label)
  local underlined, triangle_links, banded = 0, 0, 0
  for _, r in ipairs(info.rows) do
    local where = string.format("%s: screen row %d col %d", label, r.row, r.col)
    if r.separator ~= " " then
      fail(where .. ": the number pane | core separator is visible (" .. r.separator .. ")")
    end
    if r.core.text == " " and r.core.underline and not r.bridge.underline then
      fail(where .. ": the core's underline stops at the bridge")
    end
    if r.core.bg ~= info.context_bg and r.bridge.bg ~= r.core.bg then
      fail(where .. ": the core's band does not continue across the bridge")
    end
    if r.bridge.underline then
      underlined = underlined + 1
      if TRIANGLES[r.number.text] then
        triangle_links = triangle_links + 1
      end
    end
    if r.bridge.bg ~= info.context_bg then
      banded = banded + 1
    end
  end
  return underlined, triangle_links, banded
end

local function check_outer(info, label)
  local banded, underlined = 0, 0
  for _, r in ipairs(info.outer) do
    local where = string.format("%s: outer separator, screen row %d col %d", label, r.row, r.col)
    if r.number.bg ~= info.context_bg then
      banded = banded + 1
      if r.bridge.bg ~= r.number.bg then
        fail(where .. ": the band breaks at the document | number pane separator")
      end
    elseif r.bridge.text ~= "│" then
      fail(where .. ": a plain row should keep the separator glyph, found " .. vim.inspect(r.bridge.text))
    end
    if r.number.underline then
      underlined = underlined + 1
      if not r.bridge.underline then
        fail(where .. ": the insertion underline breaks at the separator")
      end
    end
  end
  return banded, underlined
end

local function check_panes(info, digits, label)
  for i, pane in ipairs(info.panes) do
    if pane.width ~= digits + 2 then
      fail(string.format("%s: number pane %d is %d wide, expected %d (one blank, %d digits, one blank)",
        label, i, pane.width, digits + 2, digits))
    end
    for n, line in ipairs(pane.lines) do
      if line:find("%d") and (line:sub(1, 1) ~= " " or line:sub(-1) ~= " ") then
        fail(string.format("%s: number pane %d line %d %q is not padded on both sides", label, i, n, line))
      end
    end
  end
end

T["diff number panes are exact and bridged to the core"] = function()
  child:start()
  child:cmd("DiffBandit " .. files .. "/left_comprehensive.txt " .. files .. "/right_comprehensive.txt")
  child:cmd("redraw")
  child:settle()
  local wins = child:lua([[
    local s = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    return { nums = { s.left_num_win, s.right_num_win },
      left = #vim.api.nvim_buf_get_lines(s.left_buf, 0, -1, false),
      right = #vim.api.nvim_buf_get_lines(s.right_buf, 0, -1, false) }
  ]])
  local info = inspect(wins)
  if info.separators ~= 2 then
    fail("expected two bridged separators, found " .. tostring(info.separators))
  end
  -- Both panes share nothing: each sizes to its own document.
  local left_info = { panes = { info.panes[1] } }
  local right_info = { panes = { info.panes[2] } }
  check_panes(left_info, #tostring(wins.left), "left")
  check_panes(right_info, #tostring(wins.right), "right")
  local underlined, triangle_links, banded = check_bridges(info, "diff")
  if underlined == 0 or triangle_links == 0 then
    fail(string.format("expected routes to underline the bridges into a triangle (underlined=%d, at a triangle=%d)",
      underlined, triangle_links))
  end
  if banded == 0 then
    fail("expected a change band to run across the bridges")
  end
  if info.outer_separators ~= 2 then
    fail("expected two outer bridges, found " .. tostring(info.outer_separators))
  end
  local outer_banded, outer_underlined = check_outer(info, "diff")
  if outer_banded == 0 or outer_underlined == 0 then
    fail(string.format("expected bands and insertion underlines at the outer separators (banded=%d, underlined=%d)",
      outer_banded, outer_underlined))
  end

  -- Scrolling repaints the bridges before the next redraw.
  child:keys("<C-e><C-e><C-e>")
  child:cmd("redraw")
  child:settle()
  local scrolled = inspect(wins)
  check_bridges(scrolled, "diff after scroll")
  check_outer(scrolled, "diff after scroll")
end

T["merge number panes are exact and bridged to both cores"] = function()
  local dir = child_mod.case_dir("gutter-bridge-merge")
  local repo = state.init_repo(dir .. "/repo")
  local base = {}
  for i = 1, 12 do
    base[i] = "line " .. i
  end
  state.write(repo .. "/conflict.txt", base)
  state.git(repo, { "add", "conflict.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = vim.trim(state.git(repo, { "rev-parse", "--abbrev-ref", "HEAD" }))
  state.git(repo, { "checkout", "-b", "feature" })
  local remote = vim.deepcopy(base)
  remote[5] = "remote five"
  state.write(repo .. "/conflict.txt", remote)
  state.git(repo, { "commit", "-am", "remote change" })
  state.git(repo, { "checkout", main })
  local mine = vim.deepcopy(base)
  mine[5] = "local five"
  state.write(repo .. "/conflict.txt", mine)
  state.git(repo, { "commit", "-am", "local change" })
  state.git(repo, { "merge", "feature" }, { allow_fail = true })

  child:start({ cwd = repo })
  child:cmd("DiffBanditMerge conflict.txt")
  child:cmd("redraw")
  child:settle()
  local wins = child:lua([[
    local m = _G.DiffBanditTestSession()
    return { nums = { m.local_num_win, m.result_left_num_win, m.result_right_num_win, m.remote_num_win } }
  ]])
  local info = inspect(wins)
  if info.separators ~= 4 then
    fail("expected four bridged separators, found " .. tostring(info.separators))
  end
  check_panes(info, 2, "merge")
  local _, _, banded = check_bridges(info, "merge")
  if banded == 0 then
    fail("expected the conflict band to run across the bridges")
  end
  if info.outer_separators ~= 4 then
    fail("expected four outer bridges, found " .. tostring(info.outer_separators))
  end
  local outer_banded = check_outer(info, "merge")
  if outer_banded == 0 then
    fail("expected the conflict band to run across the outer separators")
  end
end

return T
