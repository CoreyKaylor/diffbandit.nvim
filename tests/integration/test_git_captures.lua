-- Git captures on the shared write_git_fixture repo: untracked, deleted and
-- staged-added files opened through :DiffBanditGit (verify "git:<phase>").
local child_mod = require("helpers.child")
local verify = require("helpers.verify")
local state = require("helpers.state")

local child = child_mod.new({ lines = 16, columns = 120 })

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

local CASES = {
  { "untracked", "DiffBanditGit -- z_new_file.txt" },
  { "deleted", "DiffBanditGit -- delete_me.txt" },
  { "staged-added", "DiffBanditGit --staged -- beta_added_staged.txt" },
}

T["capture"] = MiniTest.new_set({ parametrize = CASES })
T["capture"]["git"] = function(phase, command)
  local dir = child_mod.case_dir("git-" .. phase)
  local repo = dir .. "/repo"
  write_git_fixture(repo)
  child:start({ lines = 16, cwd = repo })
  child:cmd(command)
  child:settle()
  local plain, ansi = child:capture(dir, "git-" .. phase)
  local errors = verify.check("git:" .. phase, plain, ansi)
  if #errors > 0 then
    error(string.format("git-%s failed (capture: %s/git-%s.ansi):\n  - %s", phase, dir, phase,
      table.concat(errors, "\n  - ")), 0)
  end
end

return T
