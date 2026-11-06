-- Git hunk actions: stage/unstage/discard/undo, the editable undo stack, and
-- toggling already-staged added files and hunks (ported from run.sh).
local child_mod = require("helpers.child")
local verify = require("helpers.verify")
local state = require("helpers.state")

local child = child_mod.new({ columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local function check(name, dir, capture_name)
  local plain, ansi = child:capture(dir, capture_name)
  local errors = verify.check(name, plain, ansi)
  if #errors > 0 then
    error(string.format("%s failed (capture: %s/%s.ansi):\n  - %s", name, dir, capture_name,
      table.concat(errors, "\n  - ")), 0)
  end
end

local function commit_baseline(repo, files)
  local args = { "add" }
  vim.list_extend(args, files)
  state.git(repo, args)
  state.git(repo, { "commit", "-m", "baseline" })
end

-- Next chunk, then <Space> (stage/unstage toggle), settled.
local function toggle_next_chunk()
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
end

T["actions"] = function()
  local dir = child_mod.case_dir("git-actions")
  local repo = state.init_repo(dir .. "/actions-repo")
  state.write(repo .. "/action.txt", { "action base line", "stable action line" })
  commit_baseline(repo, { "action.txt" })
  state.write(repo .. "/action.txt", { "action changed line", "stable action line" })

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- action.txt"):settle()
  check("git:action-unstaged-marker", dir, "git-action-unstaged-marker")

  toggle_next_chunk()
  state.diff_contains(repo, "cached", "action.txt", "action changed line", "space should stage hunk")
  state.diff_clean(repo, "worktree", "action.txt", "space should leave no unstaged diff")

  child:cmd("DBFocus right")
  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "action.txt", "u should undo staged hunk")
  state.diff_contains(repo, "worktree", "action.txt", "action changed line", "u should restore unstaged hunk")

  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "cached", "action.txt", "action changed line", "second space should stage hunk")
  state.diff_clean(repo, "worktree", "action.txt", "second space should leave no unstaged diff")

  child:keys(">>")
  child:settle()
  state.diff_contains(repo, "worktree", "action.txt", "action base line",
    ">> should discard worktree side while staged change remains")

  child:keys("u")
  child:settle()
  state.diff_contains(repo, "cached", "action.txt", "action changed line", "u after >> should leave staged hunk intact")
  state.diff_clean(repo, "worktree", "action.txt", "u after >> should restore worktree to staged content")

  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "action.txt", "second u should undo the staged hunk")
  state.diff_contains(repo, "worktree", "action.txt", "action changed line", "second u should restore unstaged hunk")
  child:stop()

  state.git(repo, { "add", "action.txt" })
  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit --staged -- action.txt"):settle()
  check("git:action-staged-marker", dir, "git-action-staged-marker")

  toggle_next_chunk()
  state.diff_clean(repo, "cached", "action.txt", "space should unstage staged hunk")
  state.diff_contains(repo, "worktree", "action.txt", "action changed line", "unstage should leave worktree change")
end

T["editable undo stack"] = function()
  local dir = child_mod.case_dir("git-editable-undo-stack")
  local repo = state.init_repo(dir .. "/editable-undo-stack-repo")
  state.write(repo .. "/editable.lua", { 'local value = "base"', "return value" })
  commit_baseline(repo, { "editable.lua" })
  state.write(repo .. "/editable.lua", { 'local value = "changed"', "return value" })

  child:start({ lines = 18, cwd = repo })
  child:cmd("DiffBanditGit -- editable.lua"):settle()
  child:cmd("DBFocus right")
  child:keys("gg0")
  child:keys("i", "typed ", "<Esc>")
  child:settle()
  child:state("DBWriteEditableState", dir, "editable-undo-stack-typed")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.index_equals(repo, "editable.lua", 'typed local value = "changed"\nreturn value',
    "space should stage the edited live right buffer")

  child:keys("u")
  child:settle()
  local unstaged, unstaged_path = child:state("DBWriteEditableState", dir, "editable-undo-stack-unstaged")
  state.index_equals(repo, "editable.lua", 'local value = "base"\nreturn value',
    "first u should undo the newer stage action")
  state.contains(unstaged, 'line1=typed local value = "changed"',
    "first u should preserve the newer editable buffer text (" .. unstaged_path .. ")")

  child:keys("u")
  child:settle()
  local undone, undone_path = child:state("DBWriteEditableState", dir, "editable-undo-stack-undone")
  state.contains(undone, 'line1=local value = "changed"',
    "second u should undo the older native buffer edit (" .. undone_path .. ")")
end

-- Issue #33: a hunk action leaves the reviewer where they were, with or without
-- the commit panel (which refreshes the file queue after the action).
local VIEW = [[
  local s = _G.DiffBanditTestSession()
  local win = s.right_win
  local jumps = vim.fn.getjumplist(win)
  return {
    focused = vim.api.nvim_get_current_win() == win,
    cursor = vim.api.nvim_win_get_cursor(win)[1],
    topline = vim.fn.getwininfo(win)[1].topline,
    jumps = #jumps[1],
    chunk = s.current_chunk,
  }
]]

local function numbered(count, overrides)
  local lines = {}
  for n = 1, count do
    lines[n] = overrides[n] or ("line " .. n)
  end
  return lines
end

local function view_repo(name)
  local dir = child_mod.case_dir(name)
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", numbered(60, {}))
  state.write(repo .. "/b.txt", { "b base" })
  commit_baseline(repo, { "a.txt", "b.txt" })
  state.write(repo .. "/a.txt", numbered(60, { [5] = "line 5 work", [30] = "line 30 work", [50] = "line 50 work" }))
  state.write(repo .. "/b.txt", { "b work" })
  return repo
end

local function goto_line_50()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("]c")
  child:settle()
  child:keys("]c")
  child:settle()
end

local function assert_view_kept(before, label)
  local after = child:lua(VIEW)
  state.eq(after.focused, true, label .. ": focus stays in the right pane")
  state.eq(after.cursor, before.cursor, label .. ": cursor line")
  state.eq(after.topline, before.topline, label .. ": topline")
  state.eq(after.jumps, before.jumps, label .. ": jumplist length")
end

for _, panel in ipairs({ false, true }) do
  local variant = panel and "with panel" or "without panel"

  T["hunk actions keep the view " .. variant] = function()
    local repo = view_repo("git-action-view-" .. (panel and "panel" or "plain"))
    child:start({ lines = 24, cwd = repo })
    child:cmd("DiffBanditGit"):settle()
    if panel then
      child:cmd("DiffBanditCommitPanel"):settle()
    end
    goto_line_50()
    local before = child:lua(VIEW)
    state.eq(before.cursor, 50, "fixture: third hunk is on line 50")

    child:keys("<Space>")
    child:settle()
    state.diff_contains(repo, "cached", "a.txt", "line 50 work", "space should stage the hunk")
    assert_view_kept(before, "stage")

    child:keys("u")
    child:settle()
    state.diff_clean(repo, "cached", "a.txt", "u should undo the stage")
    assert_view_kept(before, "undo")
  end
end

T["unstaging keeps the view while the file stays in the queue"] = function()
  local repo = view_repo("git-action-view-staged")
  state.git(repo, { "add", "a.txt", "b.txt" })
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit --staged"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  goto_line_50()
  local before = child:lua(VIEW)
  state.eq(before.cursor, 50, "fixture: third hunk is on line 50")

  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "worktree", "a.txt", "line 50 work", "space should unstage the hunk")
  assert_view_kept(before, "unstage")
  state.eq(child:lua(VIEW).chunk, 2, "the active chunk clamps to what is left")

  child:keys("u")
  child:settle()
  assert_view_kept(before, "undo")
  state.eq(child:lua(VIEW).chunk, 3, "undo makes the restored hunk under the cursor active")
  child:keys("[c")
  child:settle()
  state.eq(child:lua(VIEW).cursor, 30, "[c from the restored hunk reaches the one before it")
end

T["undo from the top of the file does not skip the first hunk"] = function()
  local repo = view_repo("git-action-view-undo-top")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  goto_line_50()
  child:keys("<Space>")
  child:settle()
  child:lua([[_G.DiffBanditTestSession():goto_document_edge("top")]])
  child:settle()

  child:keys("u")
  child:settle()
  local after = child:lua(VIEW)
  state.eq(after.cursor, 1, "undo stays at the top")
  state.eq(after.chunk, 0, "no hunk becomes active without being shown")
  child:keys("]c")
  child:settle()
  state.eq(child:lua(VIEW).cursor, 5, "]c reaches the first hunk")
end

T["a kept view is dropped when the load lands on another file"] = function()
  local repo = view_repo("git-action-view-skipped-load")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit"):settle()
  child:cmd("DBFocus right")
  goto_line_50()
  child:lua([[
    local s = _G.DiffBanditTestSession()
    local load = s.load_queue_sources
    s.load_queue_sources = function(self)
      s.load_queue_sources = nil
      return load(self, 2, 1)
    end
    s:goto_queue_file(1, "preserve", { preserve_view = true, preferred_chunk = 3 })
  ]])
  child:settle()
  state.eq(child:lua(VIEW).cursor, 1, "the file the load landed on opens at its top")
end

T["a file that leaves the queue opens another one at its top"] = function()
  local repo = view_repo("git-action-view-last-hunk")
  state.write(repo .. "/a.txt", numbered(60, { [50] = "line 50 work" }))
  state.git(repo, { "add", "a.txt", "b.txt" })
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit --staged"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  local after = child:lua([[
    local s = _G.DiffBanditTestSession()
    return { path = s.file_queue.entries[s.file_queue_index].path, cursor = vim.api.nvim_win_get_cursor(s.right_win)[1] }
  ]])
  state.eq(after.path, "b.txt", "a.txt has nothing left to unstage")
  state.eq(after.cursor, 1, "a different file opens at its top")
end

T["staged added toggle"] = function()
  local dir = child_mod.case_dir("git-staged-added-toggle")
  local repo = state.init_repo(dir .. "/staged-added-toggle-repo")
  state.write(repo .. "/tracked.txt", { "baseline line" })
  commit_baseline(repo, { "tracked.txt" })
  state.write(repo .. "/already_staged_added.txt", { "already staged added one", "already staged added two" })
  state.git(repo, { "add", "already_staged_added.txt" })

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- already_staged_added.txt"):settle()
  toggle_next_chunk()
  state.diff_clean(repo, "cached", "already_staged_added.txt", "space should unstage an already staged added file")
end

T["staged added hunk toggle"] = function()
  local dir = child_mod.case_dir("git-staged-added-hunk-toggle")
  local repo = state.init_repo(dir .. "/staged-added-hunk-toggle-repo")
  local file = "already_staged_added_hunk.txt"
  state.write(repo .. "/" .. file, { "one", "three" })
  commit_baseline(repo, { file })
  state.write(repo .. "/" .. file, { "one", "two", "three" })
  state.git(repo, { "add", file })

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- " .. file):settle()
  toggle_next_chunk()
  state.diff_clean(repo, "cached", file, "space should unstage an already staged added hunk")
  state.diff_contains(repo, "worktree", file, "two", "unstage should leave staged added hunk in the worktree")
end

T["mixed staged added hunk toggle"] = function()
  local dir = child_mod.case_dir("git-mixed-staged-added-hunk-toggle")
  local repo = state.init_repo(dir .. "/mixed-staged-added-hunk-toggle-repo")
  local file = "mixed_staged_added_hunk.txt"
  state.write(repo .. "/" .. file, { "one", "three", "four" })
  commit_baseline(repo, { file })
  state.write(repo .. "/" .. file, { "one", "two", "three", "four" })
  state.git(repo, { "add", file })
  state.write(repo .. "/" .. file, { "one", "two", "THREE", "four" })

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- " .. file):settle()
  toggle_next_chunk()
  state.diff_clean(repo, "cached", file, "space should unstage only the staged added hunk")
  state.diff_contains(repo, "worktree", file, "two", "unstage should leave the added worktree line")
  state.diff_contains(repo, "worktree", file, "THREE", "unstage should leave nearby worktree edits")
end

return T
