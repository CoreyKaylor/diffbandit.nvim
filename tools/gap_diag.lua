-- Diagnostic dump for the gutter-band gap investigation.
-- Reproduce the gap on screen, then run:  :luafile tools/gap_diag.lua
-- (from the diffbandit repo dir, or use the absolute path)
-- Output: /tmp/diffbandit_gap.txt — paste or hand back the file.

local out = {}
local function w(fmt, ...)
  out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

-- 1. Which code is actually loaded (file paths + mtimes + key function lines)
w("nvim: %s", tostring(vim.version()))
for _, mod in ipairs({ "diffbandit.session_render", "diffbandit.session", "diffbandit.session_layout", "diffbandit.diff" }) do
  local ok, m = pcall(require, mod)
  if ok then
    local info
    for _, fn in pairs(m) do
      if type(fn) == "function" then
        info = debug.getinfo(fn, "S")
        break
      end
    end
    if info then
      local path = info.source:gsub("^@", "")
      w("%s -> %s (mtime %s)", mod, path, os.date("%H:%M:%S", vim.fn.getftime(path)))
    end
  end
end

-- 2. Find the session (registered, or fall back to scanning panels/tabs)
local state = require("diffbandit.state")
local session = state.sessions[vim.api.nvim_get_current_tabpage()]
if not session then
  for _, s in pairs(state.sessions or {}) do
    session = s
    break
  end
end
if not session then
  w("NO SESSION FOUND (tab=%s, sessions registered: %d)", tostring(vim.api.nvim_get_current_tabpage()),
    vim.tbl_count(state.sessions or {}))
  vim.fn.writefile(out, "/tmp/diffbandit_gap.txt")
  print("wrote /tmp/diffbandit_gap.txt (no session)")
  return
end

-- 3. Geometry
local function wininfo(name, win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    w("%s: invalid", name)
    return
  end
  local topline = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
  w("%s: win=%d topline=%d height=%d width=%d wrap=%s", name, win, topline,
    vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win),
    tostring(vim.api.nvim_get_option_value("wrap", { win = win })))
end
wininfo("left_win", session.left_win)
wininfo("left_num_win", session.left_num_win)
wininfo("connector_win", session.connector_win)
wininfo("right_num_win", session.right_num_win)
wininfo("right_win", session.right_win)
w("current_chunk=%s connector_core_width=%s", tostring(session.current_chunk), tostring(session.connector_core_width))
w("last_viewport_render_key=%s", tostring(session.last_viewport_render_key))

-- 4. Visible right rows: meta + all extmarks on the right num buffer
local right_top = vim.api.nvim_win_call(session.right_win, function()
  return vim.fn.line("w0")
end)
local right_bot = vim.api.nvim_win_call(session.right_win, function()
  return vim.fn.line("w$")
end)
w("right visible rows %d..%d", right_top, right_bot)
for idx, meta in ipairs(session.view.line_meta) do
  if meta.right_index and meta.right_index >= right_top and meta.right_index <= math.min(right_bot, right_top + 45) then
    w("meta %d: kind=%s chunk=%s l=%s r=%s fl=%s fr=%s", idx, meta.kind, tostring(meta.chunk),
      tostring(meta.left_index), tostring(meta.right_index), tostring(meta.filler_left), tostring(meta.filler_right))
  end
end
for _, nsname in ipairs({ "ns", "linenum_ns", "active_ns", "path_ns", "extmark_ns" }) do
  local ns_id = session[nsname]
  if ns_id then
    local marks = vim.api.nvim_buf_get_extmarks(session.right_num_buf, ns_id, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      local row = mark[2] + 1
      if row >= right_top and row <= math.min(right_bot, right_top + 45) then
        local d = mark[4] or {}
        w("rnum %s row=%d col=%d hl=%s end=%s,%s prio=%s vt=%s", nsname, row, mark[3],
          tostring(d.hl_group), tostring(d.end_row), tostring(d.end_col), tostring(d.priority),
          d.virt_text and d.virt_text[1] and d.virt_text[1][1] or "")
      end
    end
  end
end

-- 5. Rendered truth: sample the actual screen cells of the right num pane
-- column, mapping screen rows back through the window position.
local pos = vim.fn.win_screenpos(session.right_num_win)
local srow, scol = pos[1], pos[2]
local height = vim.api.nvim_win_get_height(session.right_num_win)
local width = vim.api.nvim_win_get_width(session.right_num_win)
w("right_num screen origin row=%d col=%d", srow, scol)
for r = 0, math.min(height - 1, 45) do
  local chars, attrs = {}, {}
  for c = 0, width - 1 do
    chars[#chars + 1] = vim.fn.screenstring(srow + r, scol + c)
    attrs[#attrs + 1] = tostring(vim.fn.screenattr(srow + r, scol + c))
  end
  w("screen r+%d: %q attrs=%s", r, table.concat(chars), table.concat(attrs, ","))
end

-- 6. Highlight definitions that matter
for _, hl in ipairs({ "DiffBanditConnectorChange", "DiffBanditConnectorAdd", "DiffBanditConnectorDelete",
  "DiffBanditLineNumberRightChange", "DiffBanditActiveChunk", "DiffBanditConnectorContext" }) do
  local def = vim.api.nvim_get_hl(0, { name = hl, link = false })
  w("hl %s = %s", hl, vim.inspect(def):gsub("%s+", " "))
end

vim.fn.writefile(out, "/tmp/diffbandit_gap.txt")
print("wrote /tmp/diffbandit_gap.txt")
