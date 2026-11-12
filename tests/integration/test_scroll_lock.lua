-- Scroll lock (ui.scroll_lock, on by default): scrolling one source pane
-- scrolls the other through the diff. A user's own 'scrollbind' (e.g.
-- `:windo set scrollbind`) must not pull the number gutters, connector, or
-- overviews away from the panes they belong to.
local child_mod = require("helpers.child")

local child = child_mod.new({ lines = 30, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

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

local function open(dir, config)
  local left, right = dir .. "/left.txt", dir .. "/right.txt"
  vim.fn.writefile(left_lines(), left)
  vim.fn.writefile(right_lines(), right)
  child:start()
  if config then
    child:lua("require('diffbandit').setup(...)", { config })
  end
  child:cmd("DiffBandit " .. left .. " " .. right)
  child:settle()
end

local function assert_gutters_follow(dir, name)
  child:settle()
  local plain = child:capture(dir, name)
  local checked = 0
  for _, row in ipairs(plain) do
    local parts = vim.split(row, "│", { plain = true })
    if #parts == 5 then
      local left = vim.trim(parts[1]):match("^base (%d+)")
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

local state = require("helpers.state")

-- Each helper window's 'scrollbind', and the topline of every window named.
local function windows(keys)
  return child:lua([[
    local s = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    local out = {}
    for _, key in ipairs(...) do
      local win = s[key]
      out[key] = {
        top = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end),
        bound = vim.wo[win].scrollbind or vim.wo[win].cursorbind,
      }
    end
    return out
  ]], { keys })
end

local SIDECARS = {
  "left_num_win", "connector_win", "right_num_win",
  "left_overview_win", "right_overview_win",
  "left_header_win", "center_header_win", "right_header_win",
}

local function source_tops()
  local wins = windows({ "left_win", "right_win" })
  return { wins.left_win.top, wins.right_win.top }
end

-- Right: base 1, added 2..31, base 2 (row 32) onward. Left: base N on row N.
T["the lock holds the other pane at an added block's origin"] = function()
  local dir = child_mod.case_dir("scroll-lock-add")
  open(dir)
  child:cmd("DBViewport 1 1")
  child:cmd("DBFocus right")
  child:settle()
  child:keys("10<C-e>")
  child:settle()
  MiniTest.expect.equality(source_tops(), { 1, 11 })
  -- Past the block, unchanged text moves both panes together.
  child:keys("30<C-e>")
  assert_gutters_follow(dir, "past-block")
  MiniTest.expect.equality(source_tops(), { 11, 41 })
end

T["the lock follows from either pane"] = function()
  local dir = child_mod.case_dir("scroll-lock-left")
  open(dir)
  child:cmd("DBViewport 11 41")
  child:cmd("DBFocus left")
  child:settle()
  child:keys("5<C-e>")
  assert_gutters_follow(dir, "left-down")
  MiniTest.expect.equality(source_tops(), { 16, 46 })
  child:keys("3<C-y>")
  child:settle()
  MiniTest.expect.equality(source_tops(), { 13, 43 })
end

-- Navigation sets both panes; the lock keeps the offset it leaves.
T["the lock keeps the offset navigation sets"] = function()
  local dir = child_mod.case_dir("scroll-lock-nav")
  open(dir)
  child:cmd("DBViewport 20 45")
  child:cmd("DBFocus right")
  child:settle()
  child:keys("4<C-e>")
  child:settle()
  MiniTest.expect.equality(source_tops(), { 24, 49 })
end

T["scroll_lock = false scrolls each pane on its own"] = function()
  local dir = child_mod.case_dir("scroll-lock-off")
  open(dir, { ui = { scroll_lock = false } })
  child:cmd("DBViewport 1 1")
  child:cmd("DBFocus left")
  child:settle()
  child:keys("10<C-e>")
  assert_gutters_follow(dir, "left-only")
  MiniTest.expect.equality(source_tops(), { 11, 1 })
end

T["windo scrollbind binds the panes, not DiffBandit's sidecars"] = function()
  local dir = child_mod.case_dir("scrollbind-windo")
  open(dir)
  child:cmd("windo set scrollbind")
  child:settle()
  local wins = windows(vim.list_extend({ "left_win", "right_win" }, SIDECARS))
  MiniTest.expect.equality(wins.left_win.bound, true)
  MiniTest.expect.equality(wins.right_win.bound, true)
  for _, key in ipairs(SIDECARS) do
    MiniTest.expect.equality({ key, wins[key].bound }, { key, false })
  end
end

-- One bound scroll is one WinScrolled for every window it moved; <amatch> is
-- the first of them, which can be an overview. The connector (and its kitty
-- curves) must still repaint for the new toplines.
T["a bound scroll repaints and keeps gutters with their panes"] = function()
  local dir = child_mod.case_dir("scrollbind-scroll")
  open(dir)
  child:cmd("windo set scrollbind")
  child:cmd("DBFocus right")
  child:keys("gg")
  child:settle()
  local function requests()
    return child:lua("return _G.DiffBanditTestSession().test_viewport_request_count or 0")
  end
  local before = requests()
  child:keys("10<C-e>")
  assert_gutters_follow(dir, "right-scroll")
  MiniTest.expect.equality(requests() > before, true)
  local wins = windows({ "left_win", "right_win", "left_overview_win", "right_overview_win" })
  MiniTest.expect.equality(wins.left_win.top, 11)
  MiniTest.expect.equality(wins.right_win.top, 11)
  MiniTest.expect.equality(wins.left_overview_win.top, 1)
  MiniTest.expect.equality(wins.right_overview_win.top, 1)

  child:cmd("DBFocus left")
  before = requests()
  child:keys("15<C-e>")
  assert_gutters_follow(dir, "left-scroll")
  MiniTest.expect.equality(requests() > before, true)
end

T["merge: windo scrollbind leaves gutters to DiffBandit"] = function()
  local dir = child_mod.case_dir("scrollbind-merge")
  local repo = state.init_repo(dir .. "/repo")
  local function body(middle)
    local lines = {}
    for i = 1, 120 do
      lines[i] = i == 60 and middle or ("line " .. i)
    end
    return lines
  end
  state.write(repo .. "/conflict.txt", body("base"))
  state.git(repo, { "add", "conflict.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = vim.trim(state.git(repo, { "rev-parse", "--abbrev-ref", "HEAD" }))
  state.git(repo, { "checkout", "-b", "feature" })
  state.write(repo .. "/conflict.txt", body("remote"))
  state.git(repo, { "commit", "-am", "remote change" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/conflict.txt", body("local"))
  state.git(repo, { "commit", "-am", "local change" })
  state.git(repo, { "merge", "feature" }, { allow_fail = true })

  child:start({ cwd = repo })
  child:cmd("DiffBanditMerge conflict.txt")
  child:settle()
  child:lua([[
    local m = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    local original = m.request_render
    m.request_render = function(self, ...)
      self.test_render_requests = (self.test_render_requests or 0) + 1
      return original(self, ...)
    end
  ]])
  child:cmd("windo set scrollbind")
  child:settle()
  local gutters = {
    "local_num_win", "local_result_connector_win", "result_left_num_win",
    "result_right_num_win", "result_remote_connector_win", "remote_num_win",
    "local_header_win", "result_header_win", "remote_header_win",
  }
  local wins = windows(gutters)
  for _, key in ipairs(gutters) do
    MiniTest.expect.equality({ key, wins[key].bound }, { key, false })
  end
  local function requests()
    return child:lua([[return require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()].test_render_requests or 0]])
  end
  child:lua([[
    local m = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    vim.api.nvim_set_current_win(m.result_win)
  ]])
  child:keys("gg")
  child:settle()
  local before = requests()
  child:keys("10<C-e>")
  child:settle()
  MiniTest.expect.equality(requests() > before, true)
  wins = windows({ "local_win", "result_win", "remote_win", "local_num_win", "result_left_num_win", "remote_num_win" })
  MiniTest.expect.equality(wins.result_win.top, 11)
  MiniTest.expect.equality(wins.local_num_win.top, wins.local_win.top)
  MiniTest.expect.equality(wins.result_left_num_win.top, wins.result_win.top)
  MiniTest.expect.equality(wins.remote_num_win.top, wins.remote_win.top)
end

return T
