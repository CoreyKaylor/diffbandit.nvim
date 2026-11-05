-- Git queue navigation on the write_git_fixture repo: ]c across file
-- boundaries, ]f / [f, and C opening the commit panel on the current file.
local child_mod = require("helpers.child")
local state = require("helpers.state")

local child = child_mod.new({ lines = 12, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

-- Port of write_git_fixture (run.sh).
local function write_git_fixture(repo)
  state.init_repo(repo)
  state.write(repo .. "/alpha_modified.txt", { "alpha old one", "alpha stable two" })
  state.write(repo .. "/delete_me.txt", { "deleted line one", "deleted line two" })
  state.git(repo, { "add", "." })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/alpha_modified.txt", { "alpha new one", "alpha stable two" })
  vim.fn.delete(repo .. "/delete_me.txt")
  state.write(repo .. "/beta_added_staged.txt", { "staged added line one", "staged added line two" })
  state.git(repo, { "add", "beta_added_staged.txt" })
  state.write(repo .. "/z_new_file.txt", { "brand new content one", "brand new content two" })
end

T["navigation"] = function()
  local dir = child_mod.case_dir("git-queue-navigation")
  local repo = dir .. "/repo"
  write_git_fixture(repo)

  -- Wraps state.contains so failures name the state file, like the bash
  -- "Git navigation state failed (<label>)" output.
  local function contains(snap, expected, label)
    local ok, err = pcall(state.contains, snap.lines, expected, label)
    if not ok then
      error("Git navigation state failed (" .. snap.path .. "): " .. tostring(err), 0)
    end
  end
  local function snapshot(command, name)
    local lines, path = child:state(command, dir, name)
    return { lines = lines, path = path }
  end

  child:start({ lines = 12, cwd = repo })
  child:cmd("DiffBanditGit")
  child:settle()

  local initial = snapshot("DBWriteGitState", "queue-initial")
  child:keys("]", "c")
  child:settle()
  local first_hunk = snapshot("DBWriteGitState", "queue-after-first-hunk")
  child:keys("]", "c")
  child:settle()
  local first_boundary = snapshot("DBWriteGitState", "queue-after-first-boundary")
  child:keys("]", "c")
  child:settle()
  local second_boundary = snapshot("DBWriteGitState", "queue-after-second-boundary")
  child:keys("]", "f")
  child:settle()
  local next_file = snapshot("DBWriteGitState", "queue-after-next-file")
  child:keys("[", "f")
  child:settle()
  local prev_file = snapshot("DBWriteGitState", "queue-after-prev-file")
  child:keys("C")
  child:settle()
  local focus_panel = snapshot("DBWritePanelState", "queue-after-focus-panel")

  contains(initial, "queue_index=1", "initial index")
  contains(initial, "queue_count=4", "initial count")
  contains(initial, "chunk=0", "initial git file should open at top")
  contains(initial, "alpha_modified.txt (HEAD)", "initial left label")
  contains(initial, "alpha_modified.txt (working tree)", "initial right label")
  contains(initial, "status_left=HEAD  alpha_modified.txt", "initial left status")
  contains(initial, "status_center=all 1/4", "initial center status")
  contains(initial, "status_right=working tree  alpha_modified.txt", "initial right status")

  contains(first_hunk, "queue_index=1", "first ]c should stay in the initial file")
  contains(first_hunk, "chunk=1", "first ]c should move to the first hunk")
  contains(first_boundary, "queue_index=1", "second ]c should only arm boundary")
  contains(second_boundary, "queue_index=2", "third ]c should open next file")
  contains(second_boundary, "chunk=0", "third ]c should open next file at top")
  contains(second_boundary, "beta_added_staged.txt", "third ]c next file label")
  contains(second_boundary, "status_center=all 2/4", "second file center status")

  contains(next_file, "queue_index=3", "]f should open third file")
  contains(next_file, "chunk=0", "]f should open third file at top")
  contains(next_file, "delete_me.txt", "]f third file label")
  contains(next_file, "status_center=all 3/4", "]f center status")
  contains(prev_file, "queue_index=2", "[f should return to second file")
  contains(prev_file, "chunk=0", "[f should open previous file at top")
  contains(prev_file, "beta_added_staged.txt", "[f second file label")
  contains(focus_panel, "panel_visible=true", "C should open the commit panel from DiffBanditGit")
  contains(focus_panel, "focus=panel", "C should focus the commit panel")
  contains(focus_panel, "queue_index=2", "C should preserve the current file index")
  contains(focus_panel, "selected_path=beta_added_staged.txt", "C should select the current file in the panel")
end

return T
