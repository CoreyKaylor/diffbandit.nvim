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
  state.eq(child:lua(VIEW).chunk, 3, "with the last hunk gone, the view sits past the two that are left")

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

-- The default mode keeps staged lines on screen; these need hunks that go away.
local function open_unstaged()
  child:lua([[require("diffbandit").git({ mode = "unstaged" })]])
  child:settle()
end

local function shown_path()
  return child:lua([[
    local s = _G.DiffBanditTestSession()
    local entry = s.file_queue.entries[s.file_queue_index]
    return entry and entry.path or vim.NIL
  ]])
end

T["an action off a hunk only falls to an active hunk that can be seen"] = function()
  local repo = view_repo("git-action-offscreen")
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "line 5 work", "fixture: the first hunk is staged")
  state.eq(child:lua(VIEW).cursor, 5, "the cursor stays where the hunk was")

  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "worktree", "a.txt", "line 30 work", "the hunk at line 30 is off-screen, so it stays unstaged")
  child:keys(">>")
  child:settle()
  state.diff_contains(repo, "worktree", "a.txt", "line 30 work", "and it is not discarded")

  child:keys("]c")
  child:settle()
  state.eq(child:lua(VIEW).cursor, 30, "]c reaches the hunk that slid into place instead of skipping it")
  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "line 30 work", "from there it stages")
end

T["repeating an action works through hunks on screen"] = function()
  local dir = child_mod.case_dir("git-action-onscreen")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", numbered(20, {}))
  commit_baseline(repo, { "a.txt" })
  state.write(repo .. "/a.txt", numbered(20, { [3] = "line 3 work", [6] = "line 6 work" }))
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "line 3 work", "first press")
  state.diff_contains(repo, "cached", "a.txt", "line 6 work", "second press")
end

local function added_block_repo(name)
  local dir = child_mod.case_dir(name)
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", numbered(60, {}))
  commit_baseline(repo, { "a.txt" })
  local lines = numbered(60, {})
  for n = 1, 100 do
    table.insert(lines, 4 + n, "added " .. n)
  end
  state.write(repo .. "/a.txt", lines)
  return repo
end

local PANES = [[
  local s = _G.DiffBanditTestSession()
  return {
    left_top = vim.fn.getwininfo(s.left_win)[1].topline,
    right_top = vim.fn.getwininfo(s.right_win)[1].topline,
    left_cursor = vim.api.nvim_win_get_cursor(s.left_win)[1],
    right_cursor = vim.api.nvim_win_get_cursor(s.right_win)[1],
    right_text = vim.api.nvim_get_current_line(),
  }
]]

T["staging an added block keeps the panes together"] = function()
  local repo = added_block_repo("git-action-drift-stage")
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  child:keys("60G")
  child:settle()
  local before = child:lua(PANES)
  child:keys("<Space>")
  child:settle()
  local after = child:lua(PANES)
  state.eq(after.right_cursor, 60, "the focused pane's text did not change")
  state.eq(after.right_top, before.right_top, "nor did its scroll position")
  state.truthy(math.abs(after.left_top - after.right_top) <= 5,
    "both sides hold the same text now, so they stay level", vim.inspect(after))
  state.truthy(math.abs(after.left_cursor - after.right_cursor) <= 5,
    "cursors too", vim.inspect(after))
end

T["discarding an added block moves the cursor to the text after it"] = function()
  local repo = added_block_repo("git-action-drift-discard")
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  child:keys("60G")
  child:settle()
  child:keys(">>")
  child:settle()
  local after = child:lua(PANES)
  state.eq(after.right_cursor, 5, "the block is gone, so the cursor sits where it was")
  state.eq(after.right_text, "line 5", "on the line that followed it")
  state.truthy(math.abs(after.left_top - after.right_top) <= 5, "the panes stay level", vim.inspect(after))
end

T["map_line follows a line across text changes"] = function()
  child:start({ lines = 24 })
  local result = child:lua([[
    local map = require("diffbandit.session.keep_view").map_line
    local old = { "a", "b", "c", "d", "e" }
    return {
      unchanged = map(old, old, 3),
      inserted_before = map(old, { "a", "x", "y", "b", "c", "d", "e" }, 4),
      inserted_after = map(old, { "a", "b", "c", "d", "x", "e" }, 2),
      deleted_before = map(old, { "a", "d", "e" }, 4),
      inside_deleted = map(old, { "a", "d", "e" }, 3),
      inside_replaced = map(old, { "a", "x", "y", "d", "e" }, 3),
      inside_shrunk = map(old, { "a", "x", "e" }, 4),
      all_deleted = map(old, {}, 3),
      past_end = map(old, { "a" }, 5),
    }
  ]])
  state.eq(result, {
    unchanged = 3,
    inserted_before = 6,
    inserted_after = 2,
    deleted_before = 2,
    inside_deleted = 2,
    inside_replaced = 3,
    inside_shrunk = 2,
    all_deleted = 1,
    past_end = 1,
  }, "map_line")
end

local function three_staged_files(name)
  local dir = child_mod.case_dir(name)
  local repo = state.init_repo(dir .. "/repo")
  for _, file in ipairs({ "a.txt", "b.txt", "c.txt" }) do
    state.write(repo .. "/" .. file, { file .. " base" })
  end
  commit_baseline(repo, { "a.txt", "b.txt", "c.txt" })
  for _, file in ipairs({ "a.txt", "b.txt", "c.txt" }) do
    state.write(repo .. "/" .. file, { file .. " work" })
  end
  state.git(repo, { "add", "a.txt", "b.txt", "c.txt" })
  return repo
end

T["a file leaving the queue opens the one after it"] = function()
  local repo = three_staged_files("git-action-next-file")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit --staged"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:lua([[_G.DiffBanditTestSession():goto_next_file()]])
  child:settle()
  child:cmd("DBFocus right")
  state.eq(shown_path(), "b.txt", "fixture: on the second file")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "c.txt", "not back to the first file")
end

T["undo reaches a file that left the queue"] = function()
  local repo = three_staged_files("git-action-undo-left")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit --staged"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "b.txt", "a.txt left the queue")
  state.diff_clean(repo, "cached", "a.txt", "a.txt is unstaged")

  child:keys("u")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "a.txt work", "undo restages it")
  state.eq(shown_path(), "a.txt", "and the view returns to it")
  state.eq(child:lua(VIEW).chunk, 1, "on the hunk that was undone")

  child:keys("u")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "a.txt work", "nothing further to undo")
end

T["undo reaches a file after the queue empties"] = function()
  local dir = child_mod.case_dir("git-action-undo-empty")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", { "base" })
  commit_baseline(repo, { "a.txt" })
  state.write(repo .. "/a.txt", { "work" })
  state.git(repo, { "add", "a.txt" })
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit --staged"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.diff_clean(repo, "cached", "a.txt", "fixture: nothing staged is left")

  child:keys("u")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "work", "undo restages it")
  state.eq(shown_path(), "a.txt", "and the view returns to it")
end

T["edits on the file you landed on undo before the action that moved you"] = function()
  local dir = child_mod.case_dir("git-action-undo-edit-first")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", { "a base" })
  state.write(repo .. "/b.txt", { "b base" })
  commit_baseline(repo, { "a.txt", "b.txt" })
  state.write(repo .. "/a.txt", { "a work" })
  state.write(repo .. "/b.txt", { "b work" })
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "b.txt", "a.txt left the queue")
  child:cmd("DBFocus right")
  child:keys("gg0", "i", "typed ", "<Esc>")
  child:settle()
  child:keys("u")
  child:settle()
  state.diff_contains(repo, "cached", "a.txt", "a work", "the edit undoes first, leaving a.txt staged")
  state.eq(child:lua("return vim.api.nvim_get_current_line()"), "b work", "the typed text is gone")
  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "a.txt", "then the action")
  state.eq(shown_path(), "a.txt", "and the view returns to it")
end

T["a hunk action reloads the file once with the panel open"] = function()
  local repo = view_repo("git-action-single-reload")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  goto_line_50()
  child:lua([[
    local s = _G.DiffBanditTestSession()
    local replace = s.replace_sources
    _G.replace_count = 0
    s.replace_sources = function(...)
      _G.replace_count = _G.replace_count + 1
      return replace(...)
    end
  ]])
  child:keys("<Space>")
  child:settle()
  state.eq(child:lua("return _G.replace_count"), 1, "one reload per action")
end

T["undo at the bottom of the file does not skip the last hunk"] = function()
  local repo = view_repo("git-action-undo-bottom")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  child:lua([[_G.DiffBanditTestSession():goto_document_edge("bottom")]])
  child:settle()
  child:keys("u")
  child:settle()
  state.eq(child:lua(VIEW).chunk, 4, "the view stays past the last of three hunks")
  child:keys("[c")
  child:settle()
  state.eq(child:lua(VIEW).cursor, 50, "[c reaches the last hunk")
end

T["the panel selects the file shown after a skipped load"] = function()
  local repo = three_staged_files("git-action-skipped-load")
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit --staged"):settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  -- a.txt leaves the queue and the load of b.txt fails over to c.txt.
  child:lua([[
    local s = _G.DiffBanditTestSession()
    local load = s.load_queue_sources
    s.load_queue_sources = function(self, _, step)
      s.load_queue_sources = nil
      return load(self, 2, step)
    end
  ]])
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "c.txt", "fixture: the load skipped to c.txt")
  local selected = child:lua([[
    local panel = _G.DiffBanditTestSession().panel
    local cursor = vim.api.nvim_win_get_cursor(panel.nav_win)
    local row = panel.rows[cursor[1] ]
    return row and row.index or vim.NIL
  ]])
  state.eq(selected, 2, "the panel row follows it")
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

T["undo does not reverse a stage that has been committed"] = function()
  local dir = child_mod.case_dir("git-action-undo-committed")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", { "a base" })
  state.write(repo .. "/b.txt", { "b base" })
  commit_baseline(repo, { "a.txt", "b.txt" })
  state.write(repo .. "/a.txt", { "a work" })
  state.write(repo .. "/b.txt", { "b work" })
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "b.txt", "a.txt left the queue")
  state.git(repo, { "commit", "-m", "the stage" })

  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "a.txt", "the commit is not reversed in the index")
  state.eq(shown_path(), "b.txt", "and the view stays put")
end

T["undo survives a commit of other files"] = function()
  local dir = child_mod.case_dir("git-action-undo-other-commit")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", { "a base" })
  state.write(repo .. "/b.txt", { "b base" })
  commit_baseline(repo, { "a.txt", "b.txt" })
  state.write(repo .. "/a.txt", { "a work" })
  state.write(repo .. "/b.txt", { "b work" })
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.git(repo, { "commit", "-m", "other", "--allow-empty", "--only", "b.txt" })
  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "a.txt", "a.txt's stage still undoes")
end

T["a stale action on a file out of the queue does not block undo"] = function()
  local dir = child_mod.case_dir("git-action-undo-stale")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", { "a base" })
  state.write(repo .. "/b.txt", numbered(60, {}))
  commit_baseline(repo, { "a.txt", "b.txt" })
  state.write(repo .. "/a.txt", { "a work" })
  state.write(repo .. "/b.txt", numbered(60, { [5] = "line 5 work", [50] = "line 50 work" }))
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:lua([[_G.DiffBanditTestSession():goto_next_file()]])
  child:settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.diff_contains(repo, "cached", "b.txt", "line 5 work", "fixture: older action on b.txt")
  child:lua([[_G.DiffBanditTestSession():goto_prev_file()]])
  child:settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "b.txt", "a.txt left the queue")
  state.write(repo .. "/a.txt", { "a elsewhere" })
  state.git(repo, { "add", "a.txt" })

  child:cmd("DBFocus right")
  child:keys("u")
  child:settle()
  state.contains({ child:lua("return vim.fn.execute('messages')") }, "cannot undo: a.txt", "the stale action is reported")
  state.diff_contains(repo, "cached", "a.txt", "a elsewhere", "and left alone")
  state.diff_clean(repo, "cached", "b.txt", "b.txt's own action still undoes")
end

local STATUS = [[
  local s = _G.DiffBanditTestSession()
  return s.status_lines.center
]]

T["the header shows no active hunk once the last one is gone"] = function()
  local repo = view_repo("git-action-header")
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  goto_line_50()
  child:keys("<Space>")
  child:settle()
  state.eq(child:lua(VIEW).chunk, 3, "fixture: past the two hunks left")
  state.contains({ child:lua(STATUS) }, "h-/2", "header")
end

T["a re-diff keeps the position between hunks"] = function()
  local repo = view_repo("git-action-rediff")
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  child:lua([[_G.DiffBanditTestSession():refresh_editable_right()]])
  child:settle()
  child:keys("]c")
  child:settle()
  state.eq(child:lua(VIEW).cursor, 30, "]c still reaches the hunk that slid into place")

  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(child:lua(VIEW).chunk, 2, "fixture: past the one hunk left")
  child:lua([[_G.DiffBanditTestSession():refresh_editable_right()]])
  child:settle()
  state.eq(child:lua(VIEW).chunk, 2, "the position past the end survives too")
end

T["undoing into a file that stays out of the queue keeps the view"] = function()
  local dir = child_mod.case_dir("git-action-undo-filtered")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", { "a base" })
  state.write(repo .. "/b.txt", numbered(60, {}))
  commit_baseline(repo, { "a.txt", "b.txt" })
  state.write(repo .. "/b.txt", numbered(60, { [50] = "line 50 work" }))
  state.write(repo .. "/a.txt", { "a work" })
  state.git(repo, { "add", "a.txt" })
  child:start({ lines = 24, cwd = repo })
  child:lua([[require("diffbandit").git({ mode = "unstaged", pathspecs = { "b.txt" } })]])
  child:settle()
  child:cmd("DiffBanditCommitPanel"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:lua([[
    local s = _G.DiffBanditTestSession()
    s.action_undo = { ["a.txt"] = { {
      path = "a.txt", target = "index", before = "a base\n", after = "a work\n", head = "a base\n", seq = 1,
    } } }
  ]])
  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "a.txt", "fixture: the undo ran")
  state.eq(shown_path(), "b.txt", "the filtered queue never shows a.txt")
  state.eq(child:lua(VIEW).cursor, 50, "and b.txt keeps its place")
end

T["undo positions belong to the buffer they were taken in"] = function()
  local dir = child_mod.case_dir("git-action-undo-buffers")
  local repo = state.init_repo(dir .. "/repo")
  for _, file in ipairs({ "a.txt", "b.txt", "c.txt" }) do
    state.write(repo .. "/" .. file, { file .. " base" })
  end
  commit_baseline(repo, { "a.txt", "b.txt", "c.txt" })
  for _, file in ipairs({ "a.txt", "b.txt", "c.txt" }) do
    state.write(repo .. "/" .. file, { file .. " work" })
  end
  child:start({ lines = 24, cwd = repo })
  open_unstaged()
  child:cmd("DiffBanditCommitPanel"):settle()
  local go = [[
    local s = _G.DiffBanditTestSession()
    s:goto_queue_file(...)
  ]]
  -- An older edit in c.txt, from before the action.
  child:lua(go, { 3, "top" })
  child:settle()
  child:cmd("DBFocus right")
  child:keys("gg0", "i", "older ", "<Esc>")
  child:settle()
  child:lua(go, { 1, "top" })
  child:settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("<Space>")
  child:settle()
  state.eq(shown_path(), "b.txt", "a.txt left the queue")
  child:lua(go, { 2, "top" })
  child:settle()
  state.eq(shown_path(), "c.txt", "fixture: on the file with the older edit")
  child:cmd("DBFocus right")

  child:keys("u")
  child:settle()
  state.diff_clean(repo, "cached", "a.txt", "the action undoes first")
  state.contains(child:lua([[return vim.fn.getbufline(vim.fn.bufnr("c.txt"), 1)]]), "older", "the older edit stays")
end

T["unstaging reports an off-screen active hunk"] = function()
  local repo = view_repo("git-action-unstage-message")
  state.git(repo, { "add", "a.txt" })
  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditGit"):settle()
  child:cmd("DBFocus right")
  child:keys("]c")
  child:settle()
  child:keys("G")
  child:settle()
  child:cmd("DBViewport 42 42"):settle()
  local result = child:lua([[
    local s = _G.DiffBanditTestSession()
    local ok, err = require("diffbandit.session.actions").unstage(s)
    return { ok = ok, err = err }
  ]])
  state.eq(result, { ok = false, err = "the active hunk is off-screen; jump to it first" }, "unstage")
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
