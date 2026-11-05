-- :DiffBanditGitCurrent on a modified, unsaved buffer diffs the live buffer
-- text against HEAD (verify "git:live-buffer").
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

T["live-buffer"] = function()
  local dir = child_mod.case_dir("git-live-buffer")
  local repo = state.init_repo(dir .. "/live-buffer-repo")
  state.write(repo .. "/live_buffer.txt", { "saved buffer line", "stable buffer line" })
  state.git(repo, { "add", "live_buffer.txt" })
  state.git(repo, { "commit", "-m", "baseline" })

  child:start({ lines = 16, cwd = repo })
  child:cmd("edit live_buffer.txt")
  child:cmd("call setline(1, 'unsaved buffer line')")
  child:settle()
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  local plain, ansi = child:capture(dir, "git-live-buffer")
  local errors = verify.check("git:live-buffer", plain, ansi)
  if #errors > 0 then
    error(string.format("git-live-buffer failed (capture: %s/git-live-buffer.ansi):\n  - %s", dir,
      table.concat(errors, "\n  - ")), 0)
  end
end

return T
