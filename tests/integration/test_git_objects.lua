-- Git object kinds: binary (hex view), truncated binary, symlink, mode-only,
-- unmerged and submodule entries, each opened via :DiffBanditGit and checked
-- with verify "git:<phase>".
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

local function check(phase, dir)
  local plain, ansi = child:capture(dir, "git-" .. phase)
  local errors = verify.check("git:" .. phase, plain, ansi)
  if #errors > 0 then
    error(string.format("git-%s failed (capture: %s/git-%s.ansi):\n  - %s", phase, dir, phase,
      table.concat(errors, "\n  - ")), 0)
  end
end

-- capture_git_command: fresh session in repo, run one command, verify.
local function capture_git_command(phase, dir, repo, command, before)
  child:start({ lines = 16, cwd = repo })
  if before then
    child:cmd(before)
    child:settle()
  end
  child:cmd(command)
  child:settle()
  check(phase, dir)
end

local function new_repo(phase)
  local dir = child_mod.case_dir("git-" .. phase)
  local repo = state.init_repo(dir .. "/" .. phase .. "-repo")
  return dir, repo
end

T["binary"] = function()
  local dir, repo = new_repo("binary")
  state.write(repo .. "/binary.bin", "\0\1\2\3ABCD")
  state.git(repo, { "add", "binary.bin" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/binary.bin", "\0\1\2\4ABCE")
  capture_git_command("binary", dir, repo, "DiffBanditGit -- binary.bin")
end

T["binary-truncated"] = function()
  local dir, repo = new_repo("binary-truncated")
  state.write(repo .. "/large.bin", "\0\1\2\3ABCD1234")
  state.git(repo, { "add", "large.bin" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/large.bin", "\0\1\2\4ABCE5678")
  capture_git_command("binary-truncated", dir, repo, "DiffBanditGit -- large.bin",
    "lua require('diffbandit').setup({ ui = { hex = { max_bytes = 8, bytes_per_row = 4 } } })")
end

T["symlink"] = function()
  local dir, repo = new_repo("symlink")
  assert(vim.uv.fs_symlink("old-target.txt", repo .. "/link.txt"))
  state.git(repo, { "add", "link.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  vim.fn.delete(repo .. "/link.txt")
  assert(vim.uv.fs_symlink("new-target.txt", repo .. "/link.txt"))
  capture_git_command("symlink", dir, repo, "DiffBanditGit -- link.txt")
end

T["mode-only"] = function()
  local dir, repo = new_repo("mode-only")
  state.write(repo .. "/mode_only.sh", { "#!/bin/sh", "echo mode" })
  state.git(repo, { "add", "mode_only.sh" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.git(repo, { "update-index", "--chmod=+x", "mode_only.sh" })
  capture_git_command("mode-only", dir, repo, "DiffBanditGit --staged -- mode_only.sh")
end

T["unmerged"] = function()
  local dir, repo = new_repo("unmerged")
  state.write(repo .. "/conflict.txt", { "base" })
  state.git(repo, { "add", "conflict.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.git(repo, { "checkout", "-b", "side" })
  state.write(repo .. "/conflict.txt", { "side" })
  state.git(repo, { "commit", "-am", "side" })
  local _, code = state.git(repo, { "checkout", "main" }, { allow_fail = true })
  if code ~= 0 then
    state.git(repo, { "checkout", "master" })
  end
  state.write(repo .. "/conflict.txt", { "main" })
  state.git(repo, { "commit", "-am", "main" })
  state.git(repo, { "merge", "side" }, { allow_fail = true })
  capture_git_command("unmerged", dir, repo, "DiffBanditGit -- conflict.txt")
end

T["submodule"] = function()
  local dir, repo = new_repo("submodule")
  local old_oid = "1111111111111111111111111111111111111111"
  local new_oid = "2222222222222222222222222222222222222222"
  state.git(repo, { "update-index", "--add", "--cacheinfo", "160000," .. old_oid .. ",vendor/lib" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.git(repo, { "update-index", "--add", "--cacheinfo", "160000," .. new_oid .. ",vendor/lib" })
  capture_git_command("submodule", dir, repo, "DiffBanditGit --staged -- vendor/lib")
end

return T
