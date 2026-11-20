-- Commit panel: navigation, amend toggle, staging, hide/show, commit via :w,
-- and the panel file actions (ignore / discard / delete). Ported from run.sh.
local child_mod = require("helpers.child")
local state = require("helpers.state")

local child = child_mod.new({ columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local function fail(message, detail)
  error("Git " .. message .. (detail and detail ~= "" and ("\n" .. detail) or ""), 0)
end

-- Panel state lines plus the state path appended to each label.
local function panel_state(dir, name)
  local lines, path = child:state("DBWritePanelState", dir, name)
  return { lines = lines, path = path }
end

local function contains(s, expected, label)
  state.contains(s.lines, expected, label .. " (" .. s.path .. ")")
end

T["commit panel"] = function()
  local dir = child_mod.case_dir("git-commit-panel")
  local repo = state.init_repo(dir .. "/commit-panel-repo")
  state.write(repo .. "/alpha.txt", { "alpha base" })
  state.write(repo .. "/beta.txt", { "beta base" })
  state.git(repo, { "add", "alpha.txt", "beta.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/alpha.txt", { "alpha changed" })
  state.write(repo .. "/beta.txt", { "beta changed" })

  child:start({ lines = 18, cwd = repo })
  child:cmd("DiffBanditCommitPanel"):settle()
  local initial = panel_state(dir, "panel-initial")
  child:keys("cc")
  child:settle()
  child:keys("<Space>")
  child:settle()
  local amend_on = panel_state(dir, "panel-amend-on")
  child:keys("<Space>")
  child:settle()
  local amend_off = panel_state(dir, "panel-amend-off")
  child:keys("<C-w>k")
  child:settle()
  child:keys("j")
  child:settle()
  local first_move = panel_state(dir, "panel-after-first-j")
  child:keys("j")
  child:settle()
  local second_move = panel_state(dir, "panel-after-second-j")
  child:keys("]c")
  child:settle()
  local next_change = panel_state(dir, "panel-after-next-change")
  child:keys("<Space>")
  child:settle()
  local staged = panel_state(dir, "panel-after-stage")
  child:cmd("DiffBanditCommitPanel"):settle()
  local hidden = panel_state(dir, "panel-after-hide")
  child:cmd("DiffBanditCommitPanel"):settle()
  local shown = panel_state(dir, "panel-after-show")
  child:keys("cc")
  child:settle()
  child:keys("i", "panel commit", "<Esc>")
  child:settle()
  child:cmd("w"):settle()
  local committed = panel_state(dir, "panel-after-commit")
  child:stop()

  contains(initial, "surface=panel", "panel command should open only the standalone panel")
  contains(initial, "panel_visible=true", "panel initial visible")
  contains(initial, "focus=panel", "panel initial focus")
  contains(initial, "queue_index=0", "panel should not load a file before selection")
  contains(initial, "row=▾ Changes", "panel should initially rest on the group header")
  contains(amend_on, "focus=commit", "panel amend toggle should run from the commit pane")
  contains(amend_on, "amend=true", "commit pane space should enable amend mode")
  contains(amend_on, "stage_states=1:partial,2:partial", "panel amend mode should evaluate stage states against the amend base")
  contains(amend_off, "amend=false", "commit pane space should disable amend mode")
  contains(amend_off, "stage_states=1:unstaged,2:unstaged", "panel normal mode should restore ordinary stage states")
  contains(first_move, "focus=panel", "panel first j keeps focus")
  contains(first_move, "queue_index=1", "panel first j selects first file")
  contains(first_move, "selected_path=alpha.txt", "panel first j selects alpha")
  contains(second_move, "focus=panel", "panel second j keeps focus")
  contains(second_move, "queue_index=2", "panel second j previews second file")
  contains(second_move, "selected_path=beta.txt", "panel second j selects beta")
  contains(next_change, "focus=panel", "panel ]c keeps focus")
  contains(next_change, "surface=session", "panel ]c operates after diff session load")
  contains(next_change, "queue_index=2", "panel ]c stays on selected file")
  contains(next_change, "chunk=1", "panel ]c moves to the first hunk")
  contains(staged, "2:staged", "panel space stages selected file")
  contains(hidden, "panel_visible=false", "panel command hides panel")
  contains(shown, "panel_visible=true", "panel command shows panel")
  contains(committed, "queue_count=1", "panel commit refreshes remaining queue")

  local message = state.git(repo, { "log", "-1", "--pretty=%B" })
  if message:gsub("\n", "") ~= "panel commit" then
    fail("commit panel failed: latest commit message mismatch", message)
  end
  local _, cached_code = state.git(repo, { "diff", "--cached", "--quiet" }, { allow_fail = true })
  if cached_code ~= 0 then
    fail("commit panel failed: cached diff should be clean after commit", state.git(repo, { "diff", "--cached" }))
  end
  if #vim.fn.glob(repo .. "/diffbandit-commit-*", true, true) > 0 then
    fail("commit panel failed: :w should be intercepted, not written to disk")
  end
  state.diff_contains(repo, "worktree", "alpha.txt", "alpha changed", "panel commit should leave unstaged alpha change")
end

-- Issue #39: with preview_on_cursor off, j/k only move the cursor and <CR>
-- loads the selected file and focuses its diff.
T["enter opens the selected file without preview on cursor"] = function()
  local dir = child_mod.case_dir("git-panel-no-preview")
  local repo = state.init_repo(dir .. "/panel-no-preview-repo")
  state.write(repo .. "/alpha.txt", { "alpha base" })
  state.write(repo .. "/beta.txt", { "beta base" })
  state.git(repo, { "add", "alpha.txt", "beta.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/alpha.txt", { "alpha changed" })
  state.write(repo .. "/beta.txt", { "beta changed" })

  child:start({ lines = 18, cwd = repo })
  child:lua("require('diffbandit').setup({ git = { panel = { preview_on_cursor = false } } })")
  child:cmd("DiffBanditCommitPanel"):settle()
  child:keys("j")
  child:settle()
  local moved = panel_state(dir, "no-preview-after-j")
  child:keys("<CR>")
  child:settle()
  local opened = panel_state(dir, "no-preview-after-enter")
  child:lua([[
    local session = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    require("diffbandit.panel").focus_nav(session)
  ]])
  child:keys("j")
  child:settle()
  local moved_again = panel_state(dir, "no-preview-after-second-j")
  child:keys("<CR>")
  child:settle()
  local opened_again = panel_state(dir, "no-preview-after-second-enter")
  child:stop()

  contains(moved, "queue_index=0", "j should not preview the file")
  contains(moved, "selected_path=alpha.txt", "j selects alpha")
  contains(opened, "surface=session", "<CR> loads the selected file into a diff")
  contains(opened, "queue_index=1", "<CR> opens alpha")
  contains(opened, "focus=right", "<CR> focuses the diff")
  contains(moved_again, "focus=panel", "back in the file list")
  contains(moved_again, "queue_index=1", "j still does not preview")
  contains(moved_again, "selected_path=beta.txt", "j selects beta")
  contains(opened_again, "queue_index=2", "<CR> opens beta")
  contains(opened_again, "focus=right", "<CR> focuses beta's diff")
end

T["panel file actions"] = function()
  local dir = child_mod.case_dir("git-panel-file-actions")
  local repo = state.init_repo(dir .. "/panel-file-actions-repo")
  vim.fn.mkdir(repo .. "/logs", "p")
  state.write(repo .. "/tracked.txt", { "base" })
  state.write(repo .. "/deleted.txt", { "deleted base" })
  state.git(repo, { "add", "tracked.txt", "deleted.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/tracked.txt", { "staged" })
  state.git(repo, { "add", "tracked.txt" })
  state.write(repo .. "/tracked.txt", { "worktree" })
  vim.fn.delete(repo .. "/deleted.txt")
  state.write(repo .. "/logs/app.log", { "temporary log" })
  state.write(repo .. "/remove.tmp", { "temporary remove" })

  child:start({ lines = 24, cwd = repo })
  child:cmd("DiffBanditCommitPanel"):settle()
  local initial = panel_state(dir, "panel-file-actions-initial")
  child:cmd("DBSelectPanelPath logs/app.log")
  child:cmd("DBPanelAction ignore:/logs/app.log"):settle()
  local ignore = panel_state(dir, "panel-file-actions-ignore")
  child:cmd("DBSelectPanelPath tracked.txt")
  child:cmd("DBPanelAction discard_worktree"):settle()
  local discard = panel_state(dir, "panel-file-actions-discard")
  child:cmd("DBSelectPanelPath remove.tmp")
  child:cmd("DBPanelAction delete_untracked"):settle()
  local delete = panel_state(dir, "panel-file-actions-delete")
  child:stop()

  contains(initial, "panel_visible=true", "panel file actions initial panel visible")
  contains(ignore, "focus=panel", "ignore action should keep panel focus")
  local ignore_text = table.concat(ignore.lines, "\n")
  if ignore_text:find("selected_path=logs/app.log", 1, true) or vim.tbl_contains(ignore.lines, "selected_path=") then
    fail("panel file actions failed: ignore action should select a remaining file row", ignore_text)
  end
  local gitignore = state.read(repo .. "/.gitignore") or {}
  if not vim.tbl_contains(gitignore, "/logs/app.log") then
    fail("panel file actions failed: .gitignore missing exact path", table.concat(gitignore, "\n"))
  end
  local status = state.git(repo, { "status", "--porcelain", "--", "logs/app.log" })
  if status ~= "" then
    fail("panel file actions failed: ignored file should disappear from status", status)
  end
  local tracked = table.concat(state.read(repo .. "/tracked.txt") or {}, "\n")
  if tracked ~= "staged" then
    fail("panel file actions failed: discard should restore worktree to staged content", tracked)
  end
  state.diff_contains(repo, "cached", "tracked.txt", "staged", "discard action should preserve staged content")
  contains(discard, "focus=panel", "discard action should keep panel focus")
  if vim.fn.filereadable(repo .. "/remove.tmp") == 1 or vim.fn.isdirectory(repo .. "/remove.tmp") == 1 then
    fail("panel file actions failed: delete action should remove untracked file")
  end
  contains(delete, "focus=panel", "delete action should keep panel focus")
end

return T
