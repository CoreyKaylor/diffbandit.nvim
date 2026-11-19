-- :DiffBanditMerge following real vim-fugitive's `:Git mergetool` quickfix list
-- (tests/deps.sh pins fugitive). Fixture: a.txt has two conflicts, b.txt and
-- c.txt one each, so fugitive's per-hunk list has four entries.
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

local function write_sides(repo, side)
  state.write(repo .. "/a.txt", numbered("a", 40, side and { [3] = "a 3 " .. side, [30] = "a 30 " .. side }))
  state.write(repo .. "/b.txt", numbered("b", 10, side and { [5] = "b 5 " .. side }))
  state.write(repo .. "/c.txt", numbered("c", 10, side and { [5] = "c 5 " .. side }))
end

local function conflict_repo(name)
  local dir = child_mod.case_dir(name)
  local repo = dir .. "/repo"
  state.init_repo(repo)
  write_sides(repo)
  state.git(repo, { "add", "." })
  state.git(repo, { "commit", "-m", "base" })
  local main = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "checkout", "-b", "other" })
  write_sides(repo, "other")
  state.git(repo, { "commit", "-am", "other" })
  state.git(repo, { "checkout", main })
  write_sides(repo, "main")
  state.git(repo, { "commit", "-am", "main" })
  local _, code = state.git(repo, { "merge", "other" }, { allow_fail = true })
  assert(code ~= 0, "fixture merge should conflict")
  return repo
end

local INSPECT = [[
  local tab = vim.api.nvim_get_current_tabpage()
  local s = require("diffbandit.state").sessions[tab]
  local function name(buf) return (vim.api.nvim_buf_get_name(buf):gsub(".*/", "")) end
  local out = {
    tabs = #vim.api.nvim_list_tabpages(),
    qf_idx = vim.fn.getqflist({ idx = 0 }).idx,
    cur_win = vim.api.nvim_get_current_win(),
  }
  if s then
    out.path = s.path
    out.conflict = s.current_conflict
    out.result_win_buf = name(vim.api.nvim_win_get_buf(s.result_win))
    out.local_win_buf = name(vim.api.nvim_win_get_buf(s.local_win))
    out.remote_win_buf = name(vim.api.nvim_win_get_buf(s.remote_win))
    out.result_win = s.result_win
    out.local_win = s.local_win
    out.remote_win = s.remote_win
    out.result_lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
    out.cursor = vim.api.nvim_win_get_cursor(s.result_win)[1]
    out.result_start = s.conflicts[s.current_conflict] and s.conflicts[s.current_conflict].result_start
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
    error("timed out waiting for " .. what .. "; state: " .. vim.inspect(last), 2)
  end
  return last
end

local function buffer_state(file)
  return child:lua([[
    local buf = vim.fn.bufnr(...)
    if buf < 1 or not vim.api.nvim_buf_is_loaded(buf) then return { loaded = false } end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local markers = 0
    for _, l in ipairs(lines) do if l:match("^<<<<<<<") then markers = markers + 1 end end
    return { loaded = true, markers = markers, modified = vim.bo[buf].modified }
  ]], { file })
end

local function disk_markers(repo, file)
  local count = 0
  for _, line in ipairs(vim.fn.readfile(repo .. "/" .. file)) do
    if line:match("^<<<<<<<") then
      count = count + 1
    end
  end
  return count
end

local function start_flow(repo, setup)
  child:start({ cwd = repo })
  child:lua("vim.opt.rtp:prepend(...); vim.cmd('runtime! plugin/fugitive.vim')", { root .. "/deps/vim-fugitive" })
  if setup then
    child:cmd(setup)
  end
  child:cmd("Git mergetool")
  state.wait_until(function()
    return child:lua("return vim.fn.getqflist({ size = 0 }).size") == 4
  end, 5000)
  child:cmd("DiffBanditMerge")
  child:settle()
  local s = inspect()
  eq(s.path, "a.txt", "merge opens on fugitive's first file")
  eq(s.tabs, 2, "merge opens one tab")
  return s
end

T["cnext and cprev walk fugitive's list through one merge view"] = function()
  start_flow(conflict_repo("fugitive-walk"))

  child:cmd("cnext")
  local s = wait_for(function(v) return v.conflict == 2 end, "second conflict of a.txt")
  eq(s.path, "a.txt", "a hunk entry in the same file stays on the file")
  eq(s.cursor, s.result_start, "cursor lands on the second conflict")

  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  eq(s.result_win_buf, "b.txt", "result pane shows the new file's buffer")
  eq(s.local_win_buf, "b.txt (local)", "local pane follows")
  eq(s.remote_win_buf, "b.txt (remote)", "remote pane follows")
  eq(s.tabs, 2, "no new tab")
  eq(s.conflict, 1, "first conflict of the new file")

  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "c.txt" end, "c.txt")

  child:cmd("cprev")
  s = wait_for(function(v) return v.path == "b.txt" end, "back to b.txt")
  child:cmd("cprev")
  s = wait_for(function(v) return v.path == "a.txt" end, "back to a.txt")
  eq(s.conflict, 2, "cprev lands on a.txt's last conflict")
  eq(s.qf_idx, 2, "quickfix position stays authoritative")
end

T["merge keys and :w act on the file the jump landed on"] = function()
  local repo = conflict_repo("fugitive-resolve")
  start_flow(repo)
  child:cmd("cfirst")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  child:keys(">>")
  child:settle()
  child:cmd("write")
  child:settle()
  local status = state.git(repo, { "status", "--short" })
  -- Accepting local matches HEAD, so a staged b.txt shows no status line at all.
  assert(not status:find("b.txt", 1, true), "b.txt should be resolved and staged after :w: " .. status)
  assert(status:find("UU a.txt", 1, true), "a.txt must stay conflicted: " .. status)
  eq(disk_markers(repo, "b.txt"), 0, "b.txt resolved on disk")
  assert(vim.fn.join(vim.fn.readfile(repo .. "/b.txt"), "\n"):find("b 5 main", 1, true),
    "accepting local should write the local text")
  eq(disk_markers(repo, "a.txt"), 2, "a.txt untouched on disk")
end

T["leaving without edits gives every file back its conflict markers"] = function()
  local repo = conflict_repo("fugitive-restore")
  start_flow(repo)
  child:cmd("cnext")
  child:cmd("cnext")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  local a = buffer_state("a.txt")
  eq(a.markers, 2, "a.txt regains its markers when the merge moves on")
  eq(a.modified, false, "a.txt is unmodified again")

  child:cmd("DiffBanditClose")
  child:settle()
  a = buffer_state("a.txt")
  eq(a.markers, 2, "a.txt keeps its markers after close")
  eq(a.modified, false, "a.txt stays unmodified after close")
  local b = buffer_state("b.txt")
  if b.loaded then
    eq(b.markers, 1, "b.txt regains its marker after close")
    eq(b.modified, false, "b.txt unmodified after close")
  end
  child:cmd("wall")
  child:settle()
  for file, count in pairs({ ["a.txt"] = 2, ["b.txt"] = 1, ["c.txt"] = 1 }) do
    eq(disk_markers(repo, file), count, ":wall leaves " .. file .. " conflicted on disk")
  end
  local line = child:lua("return vim.fn.getqflist()[2].lnum")
  child:cmd("cc 2")
  eq(child:lua("return vim.fn.line('.')"), line, "quickfix line numbers survive the merge")
  local got = child:lua("return vim.fn.getline('.')")
  assert(got:match("^<<<<<<<") or got:match("a 30"), "cc 2 should land on a.txt's second conflict, got: " .. got)
end

T["unsaved edits survive leaving a file and coming back"] = function()
  local repo = conflict_repo("fugitive-draft")
  start_flow(repo)
  child:keys(">>")
  child:settle()
  child:lua("local s = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_buf_set_lines(s.result_buf, 0, 1, false, { 'my unsaved edit' })")
  child:settle()
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  child:cmd("cfirst")
  local s = wait_for(function(v) return v.path == "a.txt" end, "back to a.txt")
  eq(s.result_lines[1], "my unsaved edit", "hand edit survives the round trip")
  assert(vim.tbl_contains(s.result_lines, "a 3 main"), "accepted conflict survives the round trip")
  child:cmd("write")
  child:settle()
  local written = vim.fn.readfile(repo .. "/a.txt")
  eq(written[1], "my unsaved edit", ":w after returning writes the draft")
  assert(state.git(repo, { "status", "--short" }):find("M  a.txt", 1, true), "a.txt staged")
end

T["jumps work from every pane and keep focus there"] = function()
  local s = start_flow(conflict_repo("fugitive-panes"))
  child:lua("vim.api.nvim_set_current_win(...)", { s.local_win })
  child:cmd("cnext")
  s = wait_for(function(v) return v.conflict == 2 and v.local_win_buf == "a.txt (local)" end, "local pane restored")
  eq(s.cur_win, s.local_win, "focus stays in the local pane")
  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" and v.local_win_buf == "b.txt (local)" end, "b.txt from local pane")
  eq(s.result_win_buf, "b.txt", "the real buffer belongs in the result pane")
  child:lua("vim.api.nvim_set_current_win(...)", { s.remote_win })
  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "c.txt" and v.remote_win_buf == "c.txt (remote)" end, "c.txt from remote pane")
  eq(s.cur_win, s.remote_win, "focus stays in the remote pane")
end

T["jumps work from the quickfix window"] = function()
  local s = start_flow(conflict_repo("fugitive-qfwin"))
  child:cmd("copen")
  child:settle()
  local qf_win = child:lua("return vim.api.nvim_get_current_win()")
  child:cmd("cnext")
  child:cmd("cnext")
  s = wait_for(function(v) return v.path == "b.txt" end, "b.txt via :cnext in the qf window")
  eq(s.result_win_buf, "b.txt", "result pane shows b.txt")
  eq(s.local_win_buf, "b.txt (local)", "local pane intact")
  -- Native :cnext leaves the quickfix window for the file's window.
  assert(s.cur_win ~= qf_win, "focus moves to the jumped-to pane")
  eq(s.cur_win, s.result_win, "focus lands in the result pane")
  child:cmd("copen")
  child:settle()
  child:cmd("4")
  child:keys("<CR>")
  s = wait_for(function(v) return v.path == "c.txt" end, "c.txt via <CR>")
  eq(s.remote_win_buf, "c.txt (remote)", "remote pane intact")
end

T["a resolved file's stale entries leave the view intact"] = function()
  local repo = conflict_repo("fugitive-stale")
  start_flow(repo)
  child:keys(">>")
  child:settle()
  child:cmd("write")
  child:settle()
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  child:cmd("cfirst")
  wait_for(function(v) return v.qf_idx == 1 end, "jump onto stale entry")
  child:settle()
  local s = wait_for(function(v) return v.result_win_buf == "b.txt" end, "pane restored")
  eq(s.path, "b.txt", "stale entry keeps the current merge")
  eq(s.local_win_buf, "b.txt (local)", "local pane intact")
  child:cmd("clast")
  wait_for(function(v) return v.path == "c.txt" end, "moving on still works")
end

T["'nohidden' does not block the walk"] = function()
  start_flow(conflict_repo("fugitive-nohidden"), "set nohidden")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt under nohidden")
  child:cmd("cfirst")
  local s = wait_for(function(v) return v.path == "a.txt" end, "a.txt under nohidden")
  eq(s.result_win_buf, "a.txt", "result pane shows a.txt")
end

T["'autowrite' and 'autowriteall' never resolve a file by jumping"] = function()
  local repo = conflict_repo("fugitive-autowrite")
  start_flow(repo, "set autowrite autowriteall")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt under autowrite")
  child:settle()
  local status = state.git(repo, { "status", "--short" })
  assert(status:find("UU a.txt", 1, true), "jumping must not resolve a.txt: " .. status)
  eq(disk_markers(repo, "a.txt"), 2, "a.txt still conflicted on disk")
end

T["an unrelated quickfix list and plain :edit do not hijack the session"] = function()
  local repo = conflict_repo("fugitive-unrelated")
  start_flow(repo)
  state.write(repo .. "/note.txt", { "note" })
  child:lua("vim.fn.setqflist({ { filename = ... , lnum = 1, text = 'x' } }, ' ')", { repo .. "/note.txt" })
  child:settle()
  local s = inspect()
  eq(s.path, "a.txt", "replacing the list without jumping does nothing")
  eq(s.result_win_buf, "a.txt", "result pane unchanged")
  state.write(repo .. "/other.txt", { "other" })
  child:cmd("edit " .. repo .. "/other.txt")
  child:settle()
  s = inspect()
  eq(s.result_win_buf, "other.txt", ":edit of a file off the list is left alone")
  eq(s.path, "a.txt", "the session does not move")
end


-- Harder shapes: a subdirectory, an auto-merged hunk between conflicts, a
-- modify/delete and an add/add, each listed by real fugitive.
local function varied_repo(name)
  local dir = child_mod.case_dir(name)
  local repo = dir .. "/repo"
  state.init_repo(repo)
  local function sub(ov) return numbered("s", 60, ov) end
  state.write(repo .. "/dir/sub.txt", sub())
  state.write(repo .. "/gone.txt", numbered("g", 5))
  state.git(repo, { "add", "." })
  state.git(repo, { "commit", "-m", "base" })
  local main = state.git(repo, { "branch", "--show-current" }):gsub("%s+$", "")
  state.git(repo, { "checkout", "-b", "other" })
  state.write(repo .. "/dir/sub.txt", sub({ [5] = "s 5 other", [20] = "s 20 other only", [40] = "s 40 other" }))
  vim.fn.delete(repo .. "/gone.txt")
  state.write(repo .. "/added.txt", { "added other" })
  state.git(repo, { "add", "-A" })
  state.git(repo, { "commit", "-m", "other" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/dir/sub.txt", sub({ [5] = "s 5 main", [40] = "s 40 main" }))
  state.write(repo .. "/gone.txt", numbered("g", 5, { [2] = "g 2 main" }))
  state.write(repo .. "/added.txt", { "added main" })
  state.git(repo, { "add", "-A" })
  state.git(repo, { "commit", "-m", "main" })
  local _, code = state.git(repo, { "merge", "other" }, { allow_fail = true })
  assert(code ~= 0, "fixture merge should conflict")
  return repo
end

local function start_varied(repo, from_subdir)
  child:start({ cwd = from_subdir and (repo .. "/dir") or repo })
  child:lua("vim.opt.rtp:prepend(...); vim.cmd('runtime! plugin/fugitive.vim')", { root .. "/deps/vim-fugitive" })
  child:cmd("Git mergetool")
  state.wait_until(function()
    return child:lua("return vim.fn.getqflist({ size = 0 }).size") > 0
  end, 5000)
  return child:lua([=[
    local out = {}
    for _, e in ipairs(vim.fn.getqflist()) do
      out[#out + 1] = { file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(e.bufnr), ":t"), lnum = e.lnum, valid = e.valid }
    end
    return out
  ]=])
end

T["every kind of conflict fugitive lists is reachable, with conflicts in step"] = function()
  local repo = varied_repo("fugitive-varied")
  local entries = start_varied(repo)
  child:cmd("DiffBanditMerge")
  child:settle()
  local seen = {}
  local counts = {}
  for _, e in ipairs(entries) do
    counts[e.file] = (counts[e.file] or 0) + 1
  end
  for index = 1, #entries do
    if index > 1 then
      child:cmd("cnext")
    end
    local s = wait_for(function(v) return v.qf_idx == index end, "entry " .. index)
    s = wait_for(function(v) return v.path and v.path:gsub(".*/", "") == entries[index].file end,
      "entry " .. index .. " file " .. entries[index].file)
    seen[entries[index].file] = (seen[entries[index].file] or 0) + 1
    eq(s.result_win_buf, entries[index].file, "result pane at entry " .. index)
    eq(s.conflict, seen[entries[index].file], "conflict for entry " .. index .. " of " .. vim.inspect(entries))
    local total = child:lua("return #require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].conflicts")
    eq(total, counts[entries[index].file], "git and DiffBandit agree on conflicts in " .. entries[index].file)
  end
  for _, file in ipairs({ "added.txt", "gone.txt", "sub.txt" }) do
    assert(seen[file], "fugitive should list " .. file .. ": " .. vim.inspect(entries))
  end
end

T["works when nvim was started in a subdirectory"] = function()
  local repo = varied_repo("fugitive-subdir")
  start_varied(repo, true)
  child:cmd("DiffBanditMerge")
  child:settle()
  local first = inspect().path
  child:cmd("cnfile")
  local s = wait_for(function(v) return v.path ~= first end, "next file from a subdirectory")
  assert(s.local_win_buf:find(s.path:gsub(".*/", ""), 1, true), "panes follow: " .. vim.inspect(s))
end

T["the panel selection follows a quickfix jump"] = function()
  local repo = conflict_repo("fugitive-panel")
  child:start({ cwd = repo })
  child:lua("vim.opt.rtp:prepend(...); vim.cmd('runtime! plugin/fugitive.vim')", { root .. "/deps/vim-fugitive" })
  child:cmd("Git mergetool")
  state.wait_until(function()
    return child:lua("return vim.fn.getqflist({ size = 0 }).size") == 4
  end, 5000)
  child:lua("require('diffbandit').git_panel()")
  child:settle()
  eq(inspect().path, "a.txt", "panel opens on the first conflict")
  child:cmd("cnfile")
  local s = wait_for(function(v) return v.path == "b.txt" end, "b.txt with a panel open")
  eq(s.result_win_buf, "b.txt", "result pane follows with a panel open")
  eq(child:lua("return require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].file_queue_index"), 2,
    "queue index follows")
  local nav = child:lua("return require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].panel.nav_win")
  child:lua("vim.api.nvim_set_current_win(...)", { nav })
  child:cmd("cnfile")
  s = wait_for(function(v) return v.path == "c.txt" end, "c.txt jumping from the panel")
  eq(child:lua([=[
    local p = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()].panel
    return vim.api.nvim_win_get_buf(p.nav_win) == p.nav_buf
  ]=]), true, "panel window keeps its buffer")
end

T["closing restores text the buffer held before the merge, unsaved changes included"] = function()
  local repo = conflict_repo("fugitive-premodified")
  child:start({ cwd = repo })
  child:cmd("edit a.txt")
  child:lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'typed before the merge' }); vim.api.nvim_win_set_cursor(0, { 9, 0 })")
  child:cmd("DiffBanditMerge")
  child:settle()
  child:cmd("DiffBanditClose")
  child:settle()
  eq(child:lua("return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]"), "typed before the merge", "text restored")
  eq(child:lua("return vim.bo.modified"), true, "still modified, as it was before")
  eq(child:lua("return vim.fn.line('.')"), 9, "cursor restored")
end

T["stacked merges of one buffer still restore the original text"] = function()
  local repo = conflict_repo("fugitive-stacked")
  child:start({ cwd = repo })
  child:cmd("edit a.txt")
  child:cmd("DiffBanditMerge")
  child:settle()
  child:cmd("DiffBanditMerge")
  child:settle()
  eq(inspect().tabs, 3, "second merge stacks a tab")
  child:cmd("DiffBanditClose")
  child:settle()
  child:cmd("DiffBanditClose")
  child:settle()
  local a = buffer_state("a.txt")
  eq(a.markers, 2, "markers restored once the last session closes")
  eq(a.modified, false, "unmodified again")
end

T["closing with edits keeps them and warns"] = function()
  local repo = conflict_repo("fugitive-close-edits")
  start_flow(repo)
  child:lua("local s = require('diffbandit.state').sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_buf_set_lines(s.result_buf, 0, 1, false, { 'kept edit' })")
  child:settle()
  child:cmd("DiffBanditClose")
  child:settle()
  eq(child:lua("return vim.api.nvim_buf_get_lines(vim.fn.bufnr('a.txt'), 0, 1, false)[1]"), "kept edit", "edit kept")
  eq(buffer_state("a.txt").modified, true, "buffer stays modified")
  assert(child:lua("return vim.fn.execute('messages')"):find("unsaved merge edits", 1, true), "close warns about the edits")
  eq(disk_markers(repo, "a.txt"), 2, "nothing written to disk")
end

T["moving through the list from another tab does not move the merge"] = function()
  local s = start_flow(conflict_repo("fugitive-othertab"))
  local merge_tab = child:lua("return vim.api.nvim_get_current_tabpage()")
  child:cmd("tabfirst")
  child:settle()
  child:cmd("cnfile")
  child:settle()
  eq(child:lua("return vim.fn.expand('%:t')"), "b.txt", "the first tab jumps normally")
  child:lua("vim.api.nvim_set_current_tabpage(...)", { merge_tab })
  child:settle()
  child:lua("vim.wait(100)")
  s = inspect()
  eq(s.path, "a.txt", "the merge stays where it was")
  eq(s.result_win_buf, "a.txt", "result pane untouched")
  child:cmd("cnext")
  wait_for(function(v) return v.path == "c.txt" end, "next jump from the merge tab follows")
end

T["re-running :Git mergetool inside the merge view keeps it working"] = function()
  local s = start_flow(conflict_repo("fugitive-rerun"))
  child:lua("vim.api.nvim_set_current_win(...)", { s.local_win })
  child:cmd("Git mergetool")
  s = wait_for(function(v) return v.local_win_buf == "a.txt (local)" end, "local pane restored")
  eq(s.path, "a.txt", "fugitive's first entry is the same file")
  eq(s.tabs, 2, "no new tab")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "the new list drives the view")
end

T["'nohidden' can walk away from a file and back to it, repeatedly"] = function()
  start_flow(conflict_repo("fugitive-nohidden-repeat"), "set nohidden")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "b.txt" end, "b.txt")
  child:cmd("cnfile")
  wait_for(function(v) return v.path == "c.txt" end, "c.txt")
  child:cmd("cpfile")
  wait_for(function(v) return v.path == "b.txt" end, "back to b.txt")
  child:cmd("cpfile")
  wait_for(function(v) return v.path == "a.txt" end, "back to a.txt")
  child:cmd("clast")
  local s = wait_for(function(v) return v.path == "c.txt" end, "c.txt again")
  eq(s.result_win_buf, "c.txt", "result pane")
end

return T
