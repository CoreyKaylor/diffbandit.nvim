-- DiffBandit's diff views with real vim-fugitive (pinned in tests/deps.sh):
-- commands run from fugitive's own buffers, and the :Git difftool quickfix list
-- walked through one diff view. Fixture: a.txt has two unstaged changes, b.txt
-- one, dir/s.txt a staged change, and one commit precedes them.
local child_mod = require("helpers.child")
local state = require("helpers.state")

local child = child_mod.new({ lines = 40, columns = 160 })
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local function numbered(prefix, count, overrides)
  local lines = {}
  for n = 1, count do
    lines[n] = (overrides and overrides[n]) or (prefix .. " " .. n)
  end
  return lines
end

local function diff_repo(name)
  local dir = child_mod.case_dir(name)
  local repo = dir .. "/repo"
  state.init_repo(repo)
  state.write(repo .. "/a.txt", numbered("a", 60))
  state.write(repo .. "/b.txt", numbered("b", 10))
  state.write(repo .. "/dir/s.txt", numbered("s", 10))
  state.git(repo, { "add", "." })
  state.git(repo, { "commit", "-m", "base" })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed" }))
  state.git(repo, { "commit", "-am", "second" })
  state.write(repo .. "/a.txt", numbered("a", 60, { [3] = "a 3 work", [50] = "a 50 work" }))
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 work" }))
  state.write(repo .. "/dir/s.txt", numbered("s", 10, { [5] = "s 5 staged" }))
  state.git(repo, { "add", "dir/s.txt" })
  return repo
end

local function start(cwd)
  child:start({ cwd = cwd })
  child:lua("vim.opt.rtp:prepend(...); vim.cmd('runtime! plugin/fugitive.vim')", { root .. "/deps/vim-fugitive" })
end

local INSPECT = [[
  local s = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
  local function name(buf) return (vim.api.nvim_buf_get_name(buf):gsub(".*/", "")) end
  local out = {
    tabs = #vim.api.nvim_list_tabpages(),
    qf_idx = vim.fn.getqflist({ idx = 0 }).idx,
    cur_win = vim.api.nvim_get_current_win(),
    cur_name = name(0),
    live = s ~= nil,
  }
  if s and s.left_win then
    local q = s.file_queue
    local entry = q and q.entries[s.file_queue_index or 1]
    out.path = entry and entry.path
    out.mode = q and q.opts and q.opts.mode
    out.base = q and q.opts and q.opts.base
    out.target = q and q.opts and q.opts.target
    out.read_only = q and q.opts and q.opts.read_only
    out.review_hash = q and q.opts and q.opts.review and q.opts.review.commit and q.opts.review.commit.hash
    out.panel_title = s.panel and s.panel.details and s.panel.details.title
    out.queue_paths = {}
    for _, e in ipairs(q and q.entries or {}) do out.queue_paths[#out.queue_paths + 1] = e.path end
    out.left_lines = vim.api.nvim_buf_get_lines(s.left_buf, 0, -1, false)
    out.buftype = vim.bo[s.right_buf].buftype
    out.chunk = s.current_chunk
    out.left_win = s.left_win
    out.right_win = s.right_win
    out.left_shows_own = vim.api.nvim_win_get_buf(s.left_win) == s.left_buf
    out.right_shows_own = vim.api.nvim_win_get_buf(s.right_win) == s.right_buf
    out.right_name = name(vim.api.nvim_win_get_buf(s.right_win))
    out.left_name = name(vim.api.nvim_win_get_buf(s.left_win))
    out.left_line1 = vim.api.nvim_buf_get_lines(s.left_buf, 0, 1, false)[1]
    out.right_lines = vim.api.nvim_buf_get_lines(s.right_buf, 0, -1, false)
    local c = s.view.chunks[s.current_chunk]
    out.chunk_right_start = c and c.right.start
    out.chunks = #s.view.chunks
  end
  return out
]]

local function inspect()
  return child:lua(INSPECT)
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function wait_for(pred, what)
  local last
  local reached = state.wait_until(function()
    last = inspect()
    return pred(last)
  end, 5000)
  if not reached then
    last.right_lines = nil
    last.left_lines = nil
    error("timed out waiting for " .. what .. "; state: " .. vim.inspect(last), 2)
  end
  return last
end

local function difftool(args, size)
  child:cmd("Git difftool" .. (args or ""))
  if not state.wait_until(function()
    return child:lua("return vim.fn.getqflist({ size = 0 }).size") == size
  end, 5000) then
    error("difftool list should have " .. size .. " entries: " .. vim.inspect(child:lua("return vim.fn.getqflist({ size = 0 }).size")), 2)
  end
end

local function panes_intact(s, what)
  eq(s.left_shows_own, true, what .. ": left pane keeps its buffer")
  eq(s.right_shows_own, true, what .. ": right pane keeps its buffer")
end

-- Option 1: commands run from fugitive's buffers ---------------------------

local function expect_opens(cmd, path, what)
  child:cmd(cmd)
  child:settle()
  local s = inspect()
  eq(s.live, true, what .. " opens a session")
  if path then
    eq(s.path, path, what .. " opens the right file")
  end
  child:cmd("DiffBanditClose")
  child:settle()
end

T["repository commands work from the status buffer"] = function()
  local repo = diff_repo("fug-status")
  start(repo)
  child:cmd("Git")
  child:settle()
  eq(child:lua("return vim.bo.filetype"), "fugitive", "in the status buffer")
  expect_opens("DiffBanditGit", "a.txt", ":DiffBanditGit")
  expect_opens("DiffBanditGitCommit HEAD", nil, ":DiffBanditGitCommit")
end

T["the status buffer's repository wins over the working directory"] = function()
  local repo = diff_repo("fug-status-cwd")
  local elsewhere = child_mod.case_dir("fug-status-cwd-other")
  start(repo)
  child:cmd("Git")
  child:settle()
  child:lua("vim.cmd.cd(...)", { elsewhere })
  expect_opens("DiffBanditGit", "a.txt", ":DiffBanditGit with cwd outside the repo")
end

T["current-file commands explain themselves from the status buffer"] = function()
  start(diff_repo("fug-status-current"))
  child:cmd("Git")
  child:settle()
  local ok, err = pcall(function() child:cmd("DiffBanditGitCurrent") end)
  child:settle()
  local msg = (ok and child:lua("return vim.fn.execute('messages')") or tostring(err))
  assert(msg:find("no current file", 1, true), "should say there is no current file: " .. msg)
  assert(not msg:find("cannot change to", 1, true), "should not leak git's error: " .. msg)
end

T["current-file commands resolve fugitive object buffers to their file"] = function()
  start(diff_repo("fug-objects"))
  child:cmd("Gedit :a.txt")
  child:settle()
  expect_opens("DiffBanditGitCurrent", "a.txt", "from an index blob")
  child:cmd("Gedit HEAD~1:b.txt")
  child:settle()
  expect_opens("DiffBanditGitCurrent", "b.txt", "from an old revision")
  child:cmd("Gedit :dir/s.txt")
  child:settle()
  expect_opens("DiffBanditGitCurrent --staged", "dir/s.txt", "subdirectory path from an index blob")
end

T["the index side of :Gdiffsplit and a commit object both work"] = function()
  start(diff_repo("fug-gdiffsplit"))
  child:cmd("edit a.txt")
  child:cmd("Gdiffsplit")
  child:settle()
  assert(child:lua("return vim.api.nvim_buf_get_name(0)"):match("^fugitive://"), "focus on the index side")
  expect_opens("DiffBanditGitCurrent", "a.txt", "from Gdiffsplit's index side")
  child:lua("vim.cmd.tabonly(); vim.cmd.only()")
  child:cmd("Gclog")
  state.wait_until(function()
    return child:lua("return vim.fn.getqflist({ size = 0 }).size") == 2
  end, 5000)
  child:settle()
  expect_opens("DiffBanditGitCommit HEAD", nil, "from a commit object")
end

T[":DiffBanditMerge resolves a stage blob to its file"] = function()
  local repo = diff_repo("fug-merge-blob")
  state.git(repo, { "reset", "--hard" })
  local main = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "checkout", "-b", "other" })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 other" }))
  state.git(repo, { "commit", "-am", "other" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 main" }))
  state.git(repo, { "commit", "-am", "main" })
  state.git(repo, { "merge", "other" }, { allow_fail = true })
  start(repo)
  child:cmd("Gedit :2:b.txt")
  child:settle()
  child:cmd("DiffBanditMerge")
  child:settle()
  eq(child:lua("return require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].path"), "b.txt", "merge opens the file")
end

T["fugitive buffers resolve in a linked worktree"] = function()
  local repo = diff_repo("fug-worktree")
  local tree = child_mod.case_dir("fug-worktree-linked") .. "/linked"
  state.git(repo, { "stash" })
  state.git(repo, { "worktree", "add", "-b", "linked", tree })
  state.write(tree .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [7] = "b 7 linked" }))
  start(tree)
  child:cmd("Git")
  child:settle()
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  eq(s.path, "b.txt", "opens the linked worktree's change")
  assert(vim.tbl_contains(s.right_lines, "b 7 linked"), "reads the linked worktree, not the main one")
  child:cmd("DiffBanditClose")
  child:settle()
  child:cmd("Gedit :b.txt")
  child:settle()
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  s = inspect()
  assert(vim.tbl_contains(s.right_lines, "b 7 linked"), "index blob resolves inside the linked worktree")
end

T["fugitive buffers resolve in a submodule"] = function()
  local dir = child_mod.case_dir("fug-submodule")
  local upstream = dir .. "/upstream"
  state.init_repo(upstream)
  state.write(upstream .. "/m.txt", numbered("m", 10))
  state.git(upstream, { "add", "." })
  state.git(upstream, { "commit", "-m", "base" })
  local super = dir .. "/super"
  state.init_repo(super)
  state.write(super .. "/top.txt", { "top" })
  state.git(super, { "add", "." })
  state.git(super, { "commit", "-m", "base" })
  state.git(super, { "-c", "protocol.file.allow=always", "submodule", "add", upstream, "sub" })
  state.git(super, { "commit", "-m", "add submodule" })
  state.write(super .. "/sub/m.txt", numbered("m", 10, { [4] = "m 4 sub" }))
  start(super .. "/sub")
  child:cmd("Git")
  child:settle()
  assert(child:lua("return vim.api.nvim_buf_get_name(0)"):find(".git/modules/sub", 1, true), "git dir is under modules")
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  eq(s.path, "m.txt", "paths are relative to the submodule")
  assert(vim.tbl_contains(s.right_lines, "m 4 sub"), "reads the submodule's file")
end

T["paths with spaces and percent signs survive fugitive's URLs"] = function()
  local dir = child_mod.case_dir("fug odd path")
  local repo = dir .. "/re po"
  state.init_repo(repo)
  state.write(repo .. "/we ird%20#name.txt", numbered("w", 5))
  state.git(repo, { "add", "." })
  state.git(repo, { "commit", "-m", "base" })
  state.write(repo .. "/we ird%20#name.txt", numbered("w", 5, { [2] = "w 2 work" }))
  start(repo)
  child:lua("vim.cmd('Gedit ' .. ...)", { ":we\\ ird\\%20\\#name.txt" })
  child:settle()
  assert(child:lua("return vim.api.nvim_buf_get_name(0)"):match("^fugitive://"), "on the blob")
  expect_opens("DiffBanditGitCurrent", "we ird%20#name.txt", "odd file name")
end

T["other URL buffers fall back to the working directory"] = function()
  local repo = diff_repo("fug-other-url")
  start(repo)
  child:lua("vim.api.nvim_buf_set_name(0, 'oil:///somewhere/else/')")
  expect_opens("DiffBanditGit", "a.txt", "from an oil:// buffer")
end

-- Option 2: walking :Git difftool through a diff view ----------------------

T["cnext and cprev walk difftool's list through one current-file view"] = function()
  start(diff_repo("fug-walk-current"))
  difftool("", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  eq(s.path, "a.txt", "opens fugitive's first file")
  eq(s.tabs, 2, "one tab")

  child:cmd("cnext")
  s = wait_for(function(v) return v.chunk == 2 end, "a.txt's second change")
  eq(s.chunk_right_start, 50, "the chunk the entry points at")
  panes_intact(s, "same file")

  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  eq(s.right_name, "b.txt", "right pane shows b.txt")
  eq(s.left_line1, "b 1", "left pane shows b.txt's base")
  eq(s.tabs, 2, "no new tab")
  eq(s.chunk_right_start, 5, "lands on b.txt's change")
  panes_intact(s, "next file")

  child:cmd("cprev")
  s = wait_for(function(v) return v.path == "a.txt" end, "back to a.txt")
  eq(s.chunk_right_start, 50, "cprev lands on a.txt's second change")
  panes_intact(s, "previous file")
end

T["a repository view moves through its queue"] = function()
  start(diff_repo("fug-walk-repo"))
  difftool("", 3)
  child:cmd("DiffBanditGit")
  child:settle()
  local queued = child:lua("return #require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].file_queue.entries")
  child:cmd("cnfile")
  local s = wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  panes_intact(s, "queue move")
  eq(child:lua("return #require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].file_queue.entries"), queued,
    "the queue keeps its other files")
  eq(child:lua("return require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].file_queue.index"), 2, "queue index follows")
end

T["jumps from the left pane keep the session alive"] = function()
  start(diff_repo("fug-left"))
  difftool("", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  child:lua("vim.api.nvim_set_current_win(...)", { s.left_win })
  child:cmd("cnext")
  s = wait_for(function(v) return v.live and v.chunk == 2 end, "second change from the left pane")
  panes_intact(s, "same file from left")
  eq(s.cur_win, s.left_win, "focus stays left")
  child:cmd("cnext")
  s = wait_for(function(v) return v.live and v.path == "b.txt" end, "b.txt from the left pane")
  panes_intact(s, "next file from left")
  eq(s.right_name, "b.txt", "the real buffer belongs on the right")
  eq(s.cur_win, s.left_win, "focus stays left")
end

T["jumps work from the quickfix window"] = function()
  start(diff_repo("fug-qfwin"))
  difftool("", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  child:cmd("copen")
  child:settle()
  child:cmd("3")
  child:keys("<CR>")
  local s = wait_for(function(v) return v.path == "b.txt" end, "b.txt via <CR>")
  panes_intact(s, "from the quickfix window")
  eq(s.cur_win, s.right_win, "focus lands on the jumped-to pane")
end

T["a staged view with scratch panes follows --cached entries"] = function()
  local repo = diff_repo("fug-staged")
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [8] = "b 8 staged" }))
  state.git(repo, { "add", "b.txt" })
  start(repo)
  difftool(" --cached", 2)
  child:cmd("DiffBanditGit --staged")
  child:settle()
  local s = inspect()
  eq(s.mode, "staged", "staged view")
  local first = s.path
  child:lua("vim.api.nvim_set_current_win(...)", { s.right_win })
  child:cmd("cnext")
  s = wait_for(function(v) return v.live and v.path ~= first end, "next staged file from the scratch right pane")
  panes_intact(s, "staged, from right")
  child:lua("vim.api.nvim_set_current_win(...)", { s.left_win })
  child:cmd("cprev")
  s = wait_for(function(v) return v.live and v.path == first end, "previous staged file from the left pane")
  panes_intact(s, "staged, from left")
end

T["'nohidden' neither blocks the walk nor loses edits"] = function()
  local repo = diff_repo("fug-nohidden")
  start(repo)
  child:cmd("set nohidden")
  difftool("", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  child:cmd("cnext")
  wait_for(function(v) return v.chunk == 2 end, "same-file jump")
  child:cmd("cnext")
  local s = wait_for(function(v) return v.path == "b.txt" end, "b.txt under nohidden")
  panes_intact(s, "nohidden")
  child:cmd("cfirst")
  s = wait_for(function(v) return v.path == "a.txt" end, "back under nohidden")
  panes_intact(s, "nohidden return")
  child:lua("local s = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_buf_set_lines(s.right_buf, 0, 1, false, { 'edit under nohidden' })")
  child:settle()
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "leaving an edited buffer under nohidden")
  child:cmd("cfirst")
  s = wait_for(function(v) return v.path == "a.txt" end, "returning under nohidden")
  eq(s.right_lines[1], "edit under nohidden", "edit survives under nohidden")
  eq(vim.fn.readfile(repo .. "/a.txt")[1], "a 1", "and was not written")
end

T["unsaved edits in the right pane survive moving away and back"] = function()
  local repo = diff_repo("fug-edits")
  start(repo)
  difftool("", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  child:lua("local s = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_buf_set_lines(s.right_buf, 0, 1, false, { 'my unsaved edit' })")
  child:settle()
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  child:cmd("cfirst")
  local s = wait_for(function(v) return v.path == "a.txt" end, "back to a.txt")
  eq(s.right_lines[1], "my unsaved edit", "edit is still there")
  eq(vim.fn.readfile(repo .. "/a.txt")[1], "a 1", "and was not written")
  child:cmd("DiffBanditClose")
  child:settle()
  eq(child:lua("return vim.bo[vim.fn.bufnr('a.txt')].modified"), true, "still modified after closing")
end

T["an entry with no changes in the view leaves it intact"] = function()
  local repo = diff_repo("fug-nochange")
  state.write(repo .. "/clean.txt", { "clean" })
  state.git(repo, { "add", "clean.txt" })
  state.git(repo, { "commit", "-m", "clean", "--", "clean.txt" })
  start(repo)
  child:lua("vim.fn.setqflist({ { filename = 'a.txt', lnum = 3, text = 'x' }, { filename = 'clean.txt', lnum = 1, text = 'y' } })")
  child:cmd("cfirst")
  child:cmd("DiffBanditGit")
  child:settle()
  child:cmd("cnext")
  local s = wait_for(function(v) return v.qf_idx == 2 and v.right_shows_own and v.left_shows_own end, "panes restored")
  eq(s.path, "a.txt", "the view stays put when the file has no change")
  eq(s.live, true, "session alive")
  assert(child:lua("return vim.fn.execute('messages')"):find("no changes in this view", 1, true), "says why")
end

T["a conflicted file in the queue opens the merge view"] = function()
  local repo = diff_repo("fug-to-merge")
  state.git(repo, { "reset", "--hard" })
  local main = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "checkout", "-b", "other" })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 other" }))
  state.git(repo, { "commit", "-am", "other" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 main" }))
  state.git(repo, { "commit", "-am", "main" })
  state.git(repo, { "merge", "--no-commit", "other" }, { allow_fail = true })
  state.write(repo .. "/a.txt", numbered("a", 60, { [3] = "a 3 work" }))
  start(repo)
  child:lua("vim.fn.setqflist({ { filename = 'a.txt', lnum = 3, text = 'x' }, { filename = 'b.txt', lnum = 5, text = 'y' } })")
  child:cmd("cfirst")
  child:cmd("DiffBanditGit")
  child:settle()
  child:cmd("cnext")
  local reached = state.wait_until(function()
    local info = child:lua([=[
      local s = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()]
      return s and { path = s.path, is_merge = s.result_win ~= nil } or {}
    ]=])
    return info.is_merge and info.path == "b.txt"
  end, 5000)
  assert(reached, "b.txt should open in the merge view")
  eq(#child:lua("return vim.api.nvim_list_tabpages()"), 2, "the merge replaces the diff tab")
end

T["moving the list from another tab does not move the view"] = function()
  start(diff_repo("fug-othertab"))
  difftool("", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local tab = child:lua("return vim.api.nvim_get_current_tabpage()")
  child:cmd("tabfirst")
  child:cmd("cnfile")
  child:settle()
  child:lua("vim.api.nvim_set_current_tabpage(...)", { tab })
  child:settle()
  child:lua("vim.wait(100)")
  local s = inspect()
  eq(s.path, "a.txt", "view stays")
  panes_intact(s, "other tab")
end

T["a plain two-file diff is unchanged and closing leaves no scratch panes"] = function()
  local repo = diff_repo("fug-plain")
  start(repo)
  difftool("", 3)
  child:cmd("DiffBanditGit")
  child:settle()
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  child:cmd("DiffBanditClose")
  child:settle()
  local leftovers = child:lua([=[
    local names = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].buftype == "nofile" and vim.api.nvim_buf_get_name(b):find("HEAD", 1, true) then
        names[#names + 1] = vim.api.nvim_buf_get_name(b)
      end
    end
    return names
  ]=])
  eq(#leftovers, 0, "scratch source panes deleted on close: " .. vim.inspect(leftovers))
  child:cmd("DiffBandit a.txt b.txt")
  child:settle()
  eq(child:lua("return vim.bo[require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].left_buf].bufhidden"), "wipe",
    "plain diffs keep wiping their scratch panes")
end

T["moving with ]f keeps the quickfix list's buffers alive"] = function()
  start(diff_repo("fug-filekeys"))
  child:lua("vim.fn.setqflist({ { filename = 'a.txt', lnum = 3, text = 'x' }, { filename = 'b.txt', lnum = 5, text = 'y' } })")
  child:cmd("DiffBanditGit")
  child:settle()
  child:keys("]f")
  child:settle()
  wait_for(function(v) return v.path == "b.txt" end, "b.txt via ]f")
  child:keys("]f")
  child:settle()
  child:keys("[f")
  child:settle()
  child:keys("[f")
  child:settle()
  wait_for(function(v) return v.path == "a.txt" end, "a.txt via [f")
  child:cmd("clast")
  local s = wait_for(function(v) return v.path == "b.txt" end, "b.txt via :clast after ]f left it")
  panes_intact(s, "after ]f")
end

T["a list made after DiffBandit loaded a file survives leaving that file"] = function()
  start(diff_repo("fug-late-list"))
  child:cmd("DiffBanditGit")
  child:settle()
  child:keys("]f")
  child:settle()
  wait_for(function(v) return v.path == "b.txt" end, "b.txt via ]f")
  child:lua("vim.fn.setqflist({ { filename = 'a.txt', lnum = 3, text = 'x' }, { filename = 'b.txt', lnum = 5, text = 'y' } })")
  child:keys("[f")
  child:settle()
  wait_for(function(v) return v.path == "a.txt" end, "a.txt via [f")
  child:cmd("clast")
  local s = wait_for(function(v) return v.path == "b.txt" end, "b.txt through the late list")
  panes_intact(s, "late list")
  assert(vim.tbl_contains(s.right_lines, "b 5 work"), "the unloaded file loads again with its text")
end

-- Item 1: the list's comparison ----------------------------------------------

local function sha(repo, rev)
  return (state.git(repo, { "rev-parse", rev }):gsub("%s+$", ""))
end

local function contains(lines, needle, what)
  assert(vim.tbl_contains(lines, needle), what .. ": expected " .. needle .. " in " .. vim.inspect(lines))
end

T["opening from a commit difftool shows that range and walks it"] = function()
  local repo = diff_repo("fug-range-open")
  start(repo)
  difftool(" HEAD~1", 5)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  eq(s.mode, "all", "commit against worktree")
  eq(s.base, sha(repo, "HEAD~1"), "base is the entry's commit")
  eq(s.chunk_right_start, 3, "lands on the entry's change")
  child:cmd("cnext")
  wait_for(function(v) return v.chunk_right_start == 50 end, "a.txt's second change")
  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  eq(s.chunk_right_start, 2, "the commit's change, which a HEAD view would not show")
  contains(s.left_lines, "b 2", "left is the old commit")
  child:cmd("cnext")
  s = wait_for(function(v) return v.chunk_right_start == 5 end, "b.txt's work change")
  panes_intact(s, "range walk")
end

T["plain difftool shows unstaged changes, not the default HEAD view"] = function()
  local repo = diff_repo("fug-range-unstaged")
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 staged" }))
  state.git(repo, { "add", "b.txt" })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 staged", [8] = "b 8 work" }))
  state.write(repo .. "/untracked.txt", { "new" })
  start(repo)
  difftool("", 3)
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  eq(s.mode, "unstaged", "matches git diff")
  assert(not vim.tbl_contains(s.queue_paths, "dir/s.txt"), "staged-only file is out of an unstaged view")
  contains(s.queue_paths, "untracked.txt", "adopting a comparison keeps untracked files")
  child:cmd("clast")
  s = wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  contains(s.left_lines, "b 5 staged", "left is the index")
  eq(s.chunks, 1, "only the unstaged change")
  eq(s.chunk_right_start, 8, "on the unstaged change")
end

T["--cached opens the staged view with scratch panes"] = function()
  local repo = diff_repo("fug-range-cached")
  start(repo)
  difftool(" --cached", 1)
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  eq(s.mode, "staged", "index against HEAD")
  eq(s.path, "dir/s.txt", "the staged file")
  eq(s.chunk_right_start, 5, "the staged change")
  eq(s.buftype, "nofile", "the index side is a scratch pane")
end

T["two commits open a read-only comparison"] = function()
  local repo = diff_repo("fug-range-rev")
  state.git(repo, { "stash" })
  state.write(repo .. "/a.txt", numbered("a", 60, { [10] = "a 10 c3" }))
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [9] = "b 9 c3" }))
  state.git(repo, { "commit", "-am", "third" })
  for _, range in ipairs({ " HEAD~2 HEAD", " HEAD~2..HEAD", " HEAD~2...HEAD" }) do
    start(repo)
    difftool(range, 3)
    child:cmd("DiffBanditGit")
    child:settle()
    local s = inspect()
    eq(s.mode, "rev", range)
    eq(s.base, sha(repo, "HEAD~2"), range .. " base")
    eq(s.target, sha(repo, "HEAD"), range .. " target")
    eq(s.read_only, true, range .. " is read-only")
    eq(s.buftype, "nofile", range .. " right side is not the worktree")
    child:cmd("cnext")
    s = wait_for(function(v) return v.path == "b.txt" end, range .. " b.txt")
    panes_intact(s, range)
    eq(s.chunk_right_start, 2, range .. " first change in b.txt")
    child:stop()
  end
end

T["an explicit mode wins when opening; walking then adopts the list's"] = function()
  local repo = diff_repo("fug-range-explicit")
  start(repo)
  difftool(" HEAD~1", 5)
  child:cmd("DiffBanditGit --staged")
  child:settle()
  local s = inspect()
  eq(s.mode, "staged", "explicit mode wins")
  child:cmd("cnext")
  s = wait_for(function(v) return v.mode == "all" end, "the list's comparison on the first jump")
  eq(s.base, sha(repo, "HEAD~1"), "with the entry's commit")
  eq(s.path, "a.txt", "on the entry's file")
  eq(s.chunk_right_start, 50, "and its change")
  panes_intact(s, "explicit then walk")
end

T["--cached against another commit keeps the view's comparison"] = function()
  local repo = diff_repo("fug-range-cached-rev")
  start(repo)
  child:cmd("DiffBanditGit")
  child:settle()
  local before = inspect()
  child:cmd("Git difftool --cached HEAD~1")
  state.wait_until(function() return child:lua("return vim.fn.getqflist({ size = 0 }).size") == 2 end, 5000)
  child:cmd("clast")
  local s = wait_for(function(v) return v.qf_idx == 2 and v.left_shows_own and v.right_shows_own end, "panes restored")
  eq(s.mode, before.mode, "no way to show it, so the view keeps its comparison")
  eq(s.live, true, "no error ended the session")
end

T["moving between a read-only range and the worktree swaps the right pane"] = function()
  local repo = diff_repo("fug-range-swap")
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 work" }))
  start(repo)
  difftool(" HEAD~1 HEAD", 1)
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  eq(s.buftype, "nofile", "starts read-only")
  child:cmd("Git difftool")
  local reached = wait_for(function(v) return v.mode == "unstaged" and v.left_shows_own and v.right_shows_own end, "the new list's comparison")
  eq(reached.buftype, "", "the right pane is now the real file")
  child:cmd("clast")
  s = wait_for(function(v) return v.path == "b.txt" and v.buftype == "" end, "b.txt editable")
  contains(s.right_lines, "b 5 work", "worktree text")
  child:cmd("DiffBanditClose")
  child:settle()
  local stale = child:lua([=[
    local names = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].buftype == "nofile" and vim.api.nvim_buf_get_name(b):find("b.txt", 1, true)
          and not vim.api.nvim_buf_get_name(b):match("^fugitive") then
        names[#names + 1] = vim.api.nvim_buf_get_name(b)
      end
    end
    return names
  ]=])
  eq(#stale, 0, "no scratch panes left: " .. vim.inspect(stale))
end

T["--name-only entries have no line and land on the first change"] = function()
  local repo = diff_repo("fug-range-names")
  start(repo)
  difftool(" --name-only HEAD~1", 3)
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  eq(s.mode, "all", "the range still applies")
  eq(s.chunk_right_start, 3, "first change")
  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  eq(s.chunk_right_start, 2, "first change in the range")
end

T["added and deleted files in a range are walkable"] = function()
  local repo = diff_repo("fug-range-add-del")
  state.git(repo, { "stash" })
  state.write(repo .. "/added.txt", { "added" })
  vim.fn.delete(repo .. "/b.txt")
  state.git(repo, { "add", "-A" })
  state.git(repo, { "commit", "-m", "add and delete" })
  start(repo)
  difftool(" HEAD~1 HEAD", 2)
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  eq(s.path, "added.txt", "added file first")
  contains(s.right_lines, "added", "its text")
  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" end, "deleted file")
  contains(s.left_lines, "b 5", "deleted text on the left")
  panes_intact(s, "deleted file")
end

-- Item 2: commit lists -------------------------------------------------------

local function gclog(args, size)
  child:cmd("Gclog" .. (args or ""))
  if not state.wait_until(function()
    return child:lua("return vim.fn.getqflist({ size = 0 }).size") == size
  end, 5000) then
    error("Gclog list size: " .. child:lua("return vim.fn.getqflist({ size = 0 }).size"), 2)
  end
end

T[":Gclog walks commit reviews in one view"] = function()
  local repo = diff_repo("fug-log-walk")
  start(repo)
  gclog("", 2)
  child:settle()
  child:cmd("DiffBanditGitCommit")
  child:settle()
  local s = inspect()
  eq(s.review_hash, sha(repo, "HEAD"), "no argument: the commit in the current buffer")
  assert(s.panel_title:find("second", 1, true), "panel names the commit: " .. tostring(s.panel_title))
  eq(s.path, "b.txt", "its file")
  child:cmd("cnext")
  s = wait_for(function(v) return v.review_hash == sha(repo, "HEAD~1") end, "the root commit")
  assert(s.panel_title:find("base", 1, true), "panel follows: " .. tostring(s.panel_title))
  eq(s.tabs, 2, "one view")
  panes_intact(s, "root commit")
  contains(s.queue_paths, "a.txt", "the root commit's files")
  child:cmd("cprev")
  s = wait_for(function(v) return v.review_hash == sha(repo, "HEAD") end, "back")
  eq(s.path, "b.txt", "back on its file")
end

T["a commit list moves an open diff view and the left pane survives"] = function()
  local repo = diff_repo("fug-log-from-diff")
  start(repo)
  child:cmd("DiffBanditGit")
  child:settle()
  local s = inspect()
  child:lua("vim.api.nvim_set_current_win(...)", { s.left_win })
  gclog("", 2)
  s = wait_for(function(v) return v.live and v.left_shows_own and v.right_shows_own end, "panes restored after :Gclog")
  child:cmd("clast")
  s = wait_for(function(v) return v.live and v.review_hash == sha(repo, "HEAD~1") end, "commit review")
  panes_intact(s, "from left pane")
end

T["file history walks one file through its commits"] = function()
  local repo = diff_repo("fug-log-file")
  start(repo)
  child:cmd("edit b.txt")
  gclog(" -- b.txt", 2)
  child:cmd("edit b.txt")
  child:cmd("0Gclog")
  state.wait_until(function() return child:lua("return vim.fn.getqflist({ title = 0 }).title"):find("0,", 1, true) ~= nil end, 5000)
  child:settle()
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  eq(s.mode, "rev", "a version against its parent")
  eq(s.target, sha(repo, "HEAD"), "the newest version")
  eq(s.path, "b.txt", "the file")
  child:cmd("cnext")
  s = wait_for(function(v) return v.review_hash == sha(repo, "HEAD~1") end, "the first version")
  eq(s.path, "b.txt", "stays on the file")
  panes_intact(s, "file history")
end

T["-L lists mix commits and files"] = function()
  local repo = diff_repo("fug-log-range")
  start(repo)
  child:cmd("DiffBanditGit")
  child:settle()
  child:cmd("Gclog -L1,2:b.txt")
  state.wait_until(function() return child:lua("return vim.fn.getqflist({ size = 0 }).size") == 4 end, 5000)
  child:cmd("cc 2")
  local s = wait_for(function(v) return v.target == sha(repo, "HEAD") and v.path == "b.txt" end, "file entry")
  panes_intact(s, "file entry")
  child:cmd("cc 3")
  s = wait_for(function(v) return v.review_hash == sha(repo, "HEAD~1") end, "commit entry")
  child:cmd("cc 4")
  s = wait_for(function(v) return v.path == "b.txt" end, "root file entry")
  eq(s.review_hash, sha(repo, "HEAD~1"), "stays in that commit")
end

T["a commit with no changes leaves the view and says so"] = function()
  local repo = diff_repo("fug-log-empty")
  state.git(repo, { "stash" })
  state.git(repo, { "commit", "--allow-empty", "-m", "empty" })
  start(repo)
  gclog(" -2", 2)
  child:cmd("clast")
  child:settle()
  child:cmd("DiffBanditGitCommit")
  child:settle()
  local first = inspect().review_hash
  child:cmd("cfirst")
  local s = wait_for(function(v) return v.qf_idx == 1 and v.left_shows_own and v.right_shows_own end, "panes restored")
  eq(s.review_hash, first, "stays on the last commit with changes")
  assert(child:lua("return vim.fn.execute('messages')"):find("no changes in this view", 1, true), "says why")
end

T[":DiffBanditGitCommit without a commit asks for one"] = function()
  start(diff_repo("fug-log-noarg"))
  local ok, err = pcall(function() child:cmd("DiffBanditGitCommit") end)
  child:settle()
  local msg = ok and child:lua("return vim.fn.execute('messages')") or tostring(err)
  assert(msg:find("provide a revision", 1, true), msg)
end

-- Item 3: the status buffer --------------------------------------------------

local function open_status()
  child:cmd("Git")
  child:settle()
  eq(child:lua("return vim.bo.filetype"), "fugitive", "in status")
end

local function goto_status_line(needle)
  local row = child:lua([=[
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l == ... then vim.api.nvim_win_set_cursor(0, { i, 0 }); return i end
    end
    return false
  ]=], { needle })
  assert(row, "status line not found: " .. needle .. "\n" .. table.concat(child:lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "\n"))
end

T["status: the cursor's file and section choose what opens"] = function()
  local repo = diff_repo("fug-status-cursor")
  state.write(repo .. "/un tracked.txt", { "new" })
  start(repo)
  open_status()
  goto_status_line("M b.txt")
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  eq(s.path, "b.txt", "unstaged file")
  eq(s.mode, "unstaged", "unstaged section")
  child:cmd("DiffBanditClose")
  child:settle()
  goto_status_line("M dir/s.txt")
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  s = inspect()
  eq(s.path, "dir/s.txt", "staged file")
  eq(s.mode, "staged", "staged section")
  child:cmd("DiffBanditClose")
  child:settle()
  goto_status_line("? un tracked.txt")
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  eq(inspect().path, "un tracked.txt", "untracked file with a space")
end

T["status: a rename opens its new path"] = function()
  local repo = diff_repo("fug-status-rename")
  state.git(repo, { "mv", "a.txt", "re named.txt" })
  start(repo)
  open_status()
  goto_status_line("R a.txt -> re named.txt")
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local s = inspect()
  eq(s.path, "re named.txt", "new path")
  eq(s.mode, "staged", "staged section")
end

T["status: inside an expanded inline diff counts as its file"] = function()
  local repo = diff_repo("fug-status-inline")
  start(repo)
  open_status()
  goto_status_line("M b.txt")
  child:keys("=")
  child:settle()
  goto_status_line("+b 5 work")
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  eq(inspect().path, "b.txt", "the file above the diff line")
end

T["status: the cursor's conflict opens the merge view"] = function()
  local repo = diff_repo("fug-status-merge")
  state.git(repo, { "reset", "--hard" })
  local main = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "checkout", "-b", "other" })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 other" }))
  state.git(repo, { "commit", "-am", "other" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 main" }))
  state.git(repo, { "commit", "-am", "main" })
  state.git(repo, { "merge", "other" }, { allow_fail = true })
  start(repo)
  open_status()
  goto_status_line("U b.txt")
  child:cmd("DiffBanditMerge")
  child:settle()
  eq(child:lua("return require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].path"), "b.txt", "merge opens the conflict")
end

T["status: an unpushed commit line reviews that commit"] = function()
  local repo = diff_repo("fug-status-commit")
  local branch = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "remote", "add", "origin", "." })
  state.git(repo, { "update-ref", "refs/remotes/origin/" .. branch, sha(repo, "HEAD~1") })
  state.git(repo, { "config", "branch." .. branch .. ".remote", "origin" })
  state.git(repo, { "config", "branch." .. branch .. ".merge", "refs/heads/" .. branch })
  start(repo)
  open_status()
  local placed = child:lua([=[
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:match("^%x+ second") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return true
      end
    end
    return false
  ]=])
  assert(placed, "unpushed commit line: " .. table.concat(child:lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "\n"))
  child:cmd("DiffBanditGitCommit")
  child:settle()
  eq(inspect().review_hash, sha(repo, "HEAD"), "that commit")
end

-- Opt-in: fugitive's own commands open DiffBandit ------------------------------

local function auto_open(value)
  child:lua("require('diffbandit').setup({ fugitive = { auto_open = ... } })", { value })
end

local function conflict_repo_for_auto(name)
  local repo = diff_repo(name)
  state.git(repo, { "reset", "--hard" })
  local main = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "checkout", "-b", "other" })
  state.write(repo .. "/a.txt", numbered("a", 60, { [3] = "a 3 other" }))
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 other" }))
  state.git(repo, { "commit", "-am", "other" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/a.txt", numbered("a", 60, { [3] = "a 3 main" }))
  state.write(repo .. "/b.txt", numbered("b", 10, { [2] = "b 2 committed", [5] = "b 5 main" }))
  state.git(repo, { "commit", "-am", "main" })
  state.git(repo, { "merge", "other" }, { allow_fail = true })
  return repo
end

local function merge_info()
  return child:lua([=[
    local s = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()]
    return { live = s ~= nil, path = s and s.path, is_merge = s ~= nil and s.result_win ~= nil, tabs = #vim.api.nvim_list_tabpages() }
  ]=])
end

local function window_count()
  return child:lua("return #vim.api.nvim_tabpage_list_wins(0)")
end

T["auto-open is off by default: fugitive's commands open nothing"] = function()
  local repo = conflict_repo_for_auto("fug-auto-off")
  start(repo)
  child:cmd("Git mergetool")
  child:settle()
  eq(merge_info().live, false, ":Git mergetool opens no view")
  eq(merge_info().tabs, 1, "no tab")
  child:cmd("cclose")
  child:cmd("Git")
  child:settle()
  goto_status_line("U b.txt")
  child:keys("dd")
  child:settle()
  eq(merge_info().live, false, "dd stays fugitive's")
end

T["auto-open: :Git mergetool opens the merge view, and it walks"] = function()
  local repo = conflict_repo_for_auto("fug-auto-merge")
  start(repo)
  auto_open(true)
  child:cmd("Git mergetool")
  child:settle()
  local info = merge_info()
  eq(info.is_merge, true, "merge view")
  eq(info.path, "a.txt", "first conflict")
  eq(info.tabs, 2, "one tab")
  child:cmd("cnext")
  state.wait_until(function() return merge_info().path == "b.txt" end, 5000)
  info = merge_info()
  eq(info.path, "b.txt", "walks")
  eq(info.tabs, 2, "same tab")
  child:cmd("Git mergetool")
  child:settle()
  state.wait_until(function() return merge_info().path == "a.txt" end, 5000)
  info = merge_info()
  eq(info.path, "a.txt", "a new list moves the open view")
  eq(info.tabs, 2, "and does not stack a tab")
end

T["auto-open: :Git difftool opens the entry's comparison"] = function()
  local repo = diff_repo("fug-auto-diff")
  start(repo)
  auto_open(true)
  child:cmd("Git difftool")
  child:settle()
  local s = inspect()
  eq(s.live, true, "plain difftool opens")
  eq(s.mode, "unstaged", "unstaged")
  eq(s.path, "a.txt", "first file")
  eq(s.chunk_right_start, 3, "first change")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "walks to b.txt")
  child:cmd("DiffBanditClose")
  child:settle()
  child:cmd("cclose")
  child:cmd("Git difftool HEAD~1")
  child:settle()
  s = inspect()
  eq(s.mode, "all", "range")
  eq(s.base, sha(repo, "HEAD~1"), "the commit")
  child:cmd("DiffBanditClose")
  child:settle()
  child:cmd("Git difftool --cached")
  child:settle()
  s = inspect()
  eq(s.mode, "staged", "--cached")
  eq(s.path, "dir/s.txt", "staged file")
end

T["auto-open leaves other commands alone"] = function()
  local repo = diff_repo("fug-auto-others")
  start(repo)
  auto_open(true)
  child:cmd("Git! difftool")
  child:settle()
  eq(merge_info().live, false, ":Git! difftool does not jump, so nothing opens")
  child:lua("vim.cmd.cclose(); vim.cmd.only()")
  child:cmd("Gclog")
  child:settle()
  eq(merge_info().live, false, ":Gclog opens nothing")
  child:lua("vim.cmd.cclose(); vim.cmd.only()")
  child:cmd("edit a.txt")
  child:cmd("Gdiffsplit")
  child:settle()
  eq(merge_info().live, false, ":Gdiffsplit opens nothing")
  eq(child:lua("return vim.wo.diff"), true, "and stays vimdiff")
  child:cmd("diffoff!")
  child:lua("vim.cmd.only()")
  child:cmd("Git difftool -y")
  child:settle()
  eq(merge_info().live, false, ":Git difftool -y opens nothing")
end

T["auto-open with nothing to list opens nothing"] = function()
  local repo = conflict_repo_for_auto("fug-auto-empty")
  state.git(repo, { "merge", "--abort" })
  start(repo)
  auto_open(true)
  child:cmd("Git mergetool")
  child:settle()
  local info = merge_info()
  eq(info.live, false, "no conflicts, no view")
  eq(info.tabs, 1, "no tab")
end

T["auto-open flows are chosen one at a time"] = function()
  local repo = conflict_repo_for_auto("fug-auto-flows")
  start(repo)
  auto_open({ difftool = true })
  child:cmd("Git mergetool")
  child:settle()
  eq(merge_info().live, false, "mergetool is off")
  child:lua("vim.cmd.cclose()")
  child:cmd("Git")
  child:settle()
  goto_status_line("U b.txt")
  child:keys("dd")
  child:settle()
  eq(merge_info().live, false, "dd is off")
  child:stop()

  local diff = diff_repo("fug-auto-flows-2")
  start(diff)
  auto_open({ mergetool = true })
  child:cmd("Git difftool")
  child:settle()
  eq(merge_info().live, false, "difftool is off")
end

T["auto-open dd: the cursor's file, its section, and conflicts"] = function()
  local repo = diff_repo("fug-auto-dd")
  start(repo)
  auto_open({ dd = true })
  open_status()
  goto_status_line("M b.txt")
  child:keys("dd")
  child:settle()
  local s = inspect()
  eq(s.path, "b.txt", "unstaged file")
  eq(s.mode, "unstaged", "unstaged section")
  child:cmd("DiffBanditClose")
  child:settle()
  goto_status_line("M dir/s.txt")
  child:keys("dd")
  child:settle()
  s = inspect()
  eq(s.path, "dir/s.txt", "staged file")
  eq(s.mode, "staged", "staged section")
  child:stop()

  start(conflict_repo_for_auto("fug-auto-dd-merge"))
  auto_open({ dd = true })
  open_status()
  goto_status_line("U b.txt")
  child:keys("dd")
  child:settle()
  local info = merge_info()
  eq(info.is_merge, true, "a conflict opens the merge view")
  eq(info.path, "b.txt", "on that file")
end

T["auto-open dd only maps the status buffer"] = function()
  local repo = diff_repo("fug-auto-dd-scope")
  start(repo)
  auto_open(true)
  open_status()
  eq(child:lua("return vim.fn.maparg('dd', 'n', false, true).buffer"), 1, "buffer-local in status")
  child:cmd("edit b.txt")
  eq(child:lua("return next(vim.fn.maparg('dd', 'n', false, true)) == nil"), true, "no dd mapping in a normal buffer")
  local count = child:lua("return vim.api.nvim_buf_line_count(0)")
  child:keys("dd")
  eq(child:lua("return vim.api.nvim_buf_line_count(0)"), count - 1, "dd deletes a line")
end

T["auto-open dd stays fugitive's off a file line, and after a status reload"] = function()
  local repo = diff_repo("fug-auto-dd-fallback")
  local branch = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "remote", "add", "origin", "." })
  state.git(repo, { "update-ref", "refs/remotes/origin/" .. branch, sha(repo, "HEAD~1") })
  state.git(repo, { "config", "branch." .. branch .. ".remote", "origin" })
  state.git(repo, { "config", "branch." .. branch .. ".merge", "refs/heads/" .. branch })
  start(repo)
  auto_open({ dd = true })
  open_status()
  eq(child:lua("return vim.fn.maparg('dd', 'n', false, true).desc"), "DiffBandit: Diff the file under the cursor", "mapped")
  child:lua([=[
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:match("^%x+ second") then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
    end
  ]=])
  local before = window_count()
  child:keys("dd")
  child:settle()
  state.wait_until(function() return window_count() > before end, 5000)
  eq(merge_info().live, false, "a commit line opens no view")
  assert(window_count() > before, "fugitive's own dd ran: it splits the window")
  child:lua("vim.cmd.only()")

  -- Staging reloads the status buffer, which re-fires FugitiveIndex.
  child:cmd("Git")
  child:settle()
  goto_status_line("M b.txt")
  child:keys("s")
  child:settle()
  state.wait_until(function()
    return child:lua("return vim.fn.search('^M b.txt', 'n') > 0 and vim.fn.getline(vim.fn.search('^Staged', 'n')) ~= ''")
  end, 5000)
  goto_status_line("M a.txt")
  child:keys("dd")
  child:settle()
  eq(inspect().path, "a.txt", "dd still opens DiffBandit after the reload")
end

return T
