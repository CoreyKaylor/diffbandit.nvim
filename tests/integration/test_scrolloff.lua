-- The user's 'scrolloff' applies in the source panes. Real redraws run here:
-- Neovim re-applies the margin to a pinned topline only at redraw, so a topline
-- inside the margin would move a pane away from its gutters and its counterpart.
local child_mod = require("helpers.child")

local child = child_mod.new({ lines = 30, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

-- Context text is the same on both sides ("base N"); the right side adds lines
-- after these base lines, tagged with their own right line number. The long
-- first add puts a counterpart far from a cursor near the top of the file.
local ADDS = { [1] = 30, [100] = 4 }

local function left_lines()
  local lines = {}
  for i = 1, 200 do
    lines[i] = "base " .. i
  end
  return lines
end

local function right_lines()
  local lines = {}
  for i = 1, 200 do
    lines[#lines + 1] = "base " .. i
    for _ = 1, ADDS[i] or 0 do
      lines[#lines + 1] = "added " .. (#lines + 1)
    end
  end
  return lines
end

local function right_number(text)
  local added = text:match("^added (%d+)")
  if added then
    return added
  end
  local base = tonumber(text:match("^base (%d+)"))
  if not base then
    return nil
  end
  local shift = 0
  for after, count in pairs(ADDS) do
    if base > after then
      shift = shift + count
    end
  end
  return tostring(base + shift)
end

local function open(dir, scrolloff)
  local left, right = dir .. "/left.txt", dir .. "/right.txt"
  vim.fn.writefile(left_lines(), left)
  vim.fn.writefile(right_lines(), right)
  child:start()
  child:cmd("set scrolloff=" .. scrolloff)
  child:cmd("DiffBandit " .. left .. " " .. right)
  child:settle()
end

-- On every row, each pane's number gutter names the line drawn beside it.
local function assert_gutters_follow(dir, name)
  child:settle()
  local plain = child:capture(dir, name)
  local checked = 0
  for _, row in ipairs(plain) do
    local parts = vim.split(row, "│", { plain = true })
    if #parts == 5 then
      local left_text = vim.trim(parts[1])
      local left = left_text:match("^base (%d+)")
      local right = right_number(vim.trim(parts[5]))
      if left then
        checked = checked + 1
        MiniTest.expect.equality(parts[2]:match("(%d+)"), left)
      end
      if right then
        checked = checked + 1
        MiniTest.expect.equality(parts[4]:match("(%d+)"), right)
      end
    end
  end
  if checked == 0 then
    error(name .. ": no tagged rows on screen:\n" .. table.concat(plain, "\n"), 0)
  end
end

local function view()
  return child:lua([[return (function()
    local session = _G.DiffBanditTestSession()
    local function info(win)
      return vim.api.nvim_win_call(win, function()
        return { top = vim.fn.line("w0"), cursor = vim.fn.line("."), so = vim.wo[win].scrolloff }
      end)
    end
    return { left = info(session.left_win), right = info(session.right_win) }
  end)()]])
end

T["]c lands aligned with the margin kept"] = function()
  local dir = child_mod.case_dir("scrolloff-jump")
  open(dir, 8)
  -- The session opens on the first add; ]c goes to the second, whose origin is
  -- left 100 / right 130.
  child:keys("]c")
  assert_gutters_follow(dir, "jump")
  local v = view()
  MiniTest.expect.equality(v.right.so, 8)
  MiniTest.expect.equality(v.left.top, 92)
  MiniTest.expect.equality(v.right.top, 122)
  MiniTest.expect.equality(v.right.cursor, 131)
end

T["]s near the top of a file keeps gutters in step"] = function()
  local dir = child_mod.case_dir("scrolloff-snap")
  open(dir, 8)
  child:cmd("DBFocus left")
  child:keys("gg", "jj", "]s")
  assert_gutters_follow(dir, "snap")
  -- The counterpart of left 3 is right 33; the margin holds its cursor 8 rows in.
  local v = view()
  MiniTest.expect.equality(v.right.cursor, 33)
  MiniTest.expect.equality(v.right.top, 25)
end

-- Reads in the same tick as the snap: every RPC call into the child runs the
-- main loop, whose WinScrolled would resync a gutter left behind and hide it. A
-- user sees that gutter stale until their next key.
T["a topline inside the margin settles before gutters sync"] = function()
  local dir = child_mod.case_dir("scrolloff-settle")
  open(dir, 8)
  child:cmd("DBFocus left")
  child:keys("gg", "jj")
  child:settle()
  local tops = child:lua([[return (function()
    local session = _G.DiffBanditTestSession()
    session:snap_to_cursor()
    local gutter = vim.api.nvim_win_call(session.right_num_win, vim.fn.winsaveview).topline
    local pane = vim.api.nvim_win_call(session.right_win, function()
      return vim.fn.line("w0")
    end)
    return { gutter = gutter, pane = pane }
  end)()]])
  MiniTest.expect.equality(tops.pane, 25)
  MiniTest.expect.equality(tops.gutter, tops.pane)
end

T["]d leaves the panes level and gutters in step"] = function()
  local dir = child_mod.case_dir("scrolloff-edge")
  open(dir, 8)
  child:keys("]d")
  assert_gutters_follow(dir, "bottom")
  local v = view()
  MiniTest.expect.equality(v.left.cursor, 200)
  MiniTest.expect.equality(v.right.cursor, 234)
  MiniTest.expect.equality(v.right.top - v.left.top, 34)
end

T["cursor motion keeps the margin"] = function()
  local dir = child_mod.case_dir("scrolloff-motion")
  open(dir, 8)
  -- One press at a time: a large count recenters natively.
  child:keys("gg", string.rep("j", 30))
  assert_gutters_follow(dir, "down")
  local v = view()
  local height = child:lua("return vim.fn.winheight(_G.DiffBanditTestSession().right_win)")
  MiniTest.expect.equality(v.right.cursor - v.right.top, height - 1 - 8)
end

T["a centering scrolloff keeps gutters in step"] = function()
  local dir = child_mod.case_dir("scrolloff-center")
  open(dir, 999)
  child:keys("]c")
  assert_gutters_follow(dir, "jump")
  child:keys("20j")
  assert_gutters_follow(dir, "motion")
end

T["a centering scrolloff keeps the unfocused gutter in step"] = function()
  local dir = child_mod.case_dir("scrolloff-center-left")
  open(dir, 999)
  child:cmd("DBFocus left")
  child:keys("]c")
  assert_gutters_follow(dir, "jump")
end

T["folder panes opt out, having no scroll sync"] = function()
  child:start()
  child:cmd("set scrolloff=8")
  local root = child_mod.case_dir("scrolloff-folder")
  for _, side in ipairs({ "a", "b" }) do
    vim.fn.mkdir(root .. "/" .. side, "p")
    for i = 1, 100 do
      vim.fn.writefile({ side .. i }, string.format("%s/%s/f%03d.txt", root, side, i))
    end
  end
  child:lua("require('diffbandit').folder_diff(...)", { root .. "/a", root .. "/b" })
  child:settle()
  local so = child:lua("return vim.wo[vim.api.nvim_get_current_win()].scrolloff")
  MiniTest.expect.equality(so, 0)
end

return T
