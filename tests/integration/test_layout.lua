-- Foreign splits in a DiffBandit tab (issue #28): a file tree (Neo-tree,
-- nvim-tree, …) opening and closing hands its columns to whichever
-- DiffBandit window was adjacent. The session must lay its widths out again,
-- so the panel and gutters return to their sizes and the panes are not
-- squeezed, while the user's own separator drags between the panes stay.
local child_mod = require("helpers.child")
local state = require("helpers.state")
local files = child_mod.files

local child = child_mod.new({ lines = 30, columns = 160 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

-- Non-floating windows of the current tab, left to right / top to bottom.
local function widths()
  return child:lua([[
    local out = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        out[#out + 1] = vim.api.nvim_win_get_width(win)
      end
    end
    return out
  ]])
end

local function session_wins()
  return child:lua([[
    local s = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    return { left = s.left_win, right = s.right_win,
      nav = s.panel and s.panel.nav_win or nil }
  ]])
end

local function width_of(win)
  return child:lua("return vim.api.nvim_win_get_width(...)", { win })
end

-- What a file tree does: a full-height split on the far left, then closed.
local function toggle_tree()
  child:cmd("topleft 40vnew")
  child:cmd("redraw")
  child:settle()
  child:cmd("close")
  child:cmd("redraw")
  child:settle()
end

local function same(expected, actual, label)
  local a, b = table.concat(expected, " "), table.concat(actual, " ")
  if a ~= b then
    error(label .. ": window widths changed\n  expected " .. a .. "\n  actual   " .. b, 0)
  end
end

T["file tree toggle restores the diff layout"] = function()
  child:start()
  child:cmd("DiffBandit " .. files .. "/left_wrap.txt " .. files .. "/right_wrap.txt")
  child:cmd("redraw")
  child:settle()
  local initial = widths()
  for i = 1, 3 do
    toggle_tree()
    same(initial, widths(), "toggle " .. i)
  end
end

T["file tree toggle keeps the commit panel width"] = function()
  local dir = child_mod.case_dir("layout-panel")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/alpha.txt", { "alpha base", "two", "three" })
  state.git(repo, { "add", "alpha.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/alpha.txt", { "alpha changed", "two", "three", "four" })

  child:start({ cwd = repo })
  child:cmd("DiffBanditCommitPanel"):settle()
  child:keys("j", "<CR>")
  child:cmd("redraw")
  child:settle()
  local wins = session_wins()
  if not (wins.left and wins.nav) then
    error("expected a diff session with the commit panel attached", 0)
  end
  local initial = widths()
  for i = 1, 3 do
    toggle_tree()
    same(initial, widths(), "toggle " .. i)
  end
end

T["file tree toggle restores the merge layout"] = function()
  local dir = child_mod.case_dir("layout-merge")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/conflict.txt", { "one", "base", "three" })
  state.git(repo, { "add", "conflict.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = vim.trim(state.git(repo, { "rev-parse", "--abbrev-ref", "HEAD" }))
  state.git(repo, { "checkout", "-b", "feature" })
  state.write(repo .. "/conflict.txt", { "one", "remote", "three" })
  state.git(repo, { "commit", "-am", "remote change" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/conflict.txt", { "one", "local", "three" })
  state.git(repo, { "commit", "-am", "local change" })
  state.git(repo, { "merge", "feature" }, { allow_fail = true })

  child:start({ cwd = repo })
  child:cmd("DiffBanditMerge conflict.txt")
  child:cmd("redraw")
  child:settle()
  local initial = widths()
  for i = 1, 3 do
    toggle_tree()
    same(initial, widths(), "toggle " .. i)
  end
end

T["dragging the pane separator survives a redraw"] = function()
  child:start()
  child:cmd("DiffBandit " .. files .. "/left_wrap.txt " .. files .. "/right_wrap.txt")
  child:cmd("redraw")
  child:settle()
  local wins = session_wins()
  local before = width_of(wins.left)
  child:lua("vim.api.nvim_win_set_width(...)", { wins.left, before - 10 })
  child:cmd("redraw")
  child:settle()
  local after = width_of(wins.left)
  if after ~= before - 10 then
    error(string.format("left pane width %d after drag, expected %d", after, before - 10), 0)
  end
end

return T
