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
