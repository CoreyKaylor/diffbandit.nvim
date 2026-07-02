local diffbandit = require("diffbandit")
local nvim = require("diffbandit.nvim")

local function report(result, err)
  if not result and err then
    nvim.notify_error(err)
  end
end

local function parse_git_args(args, defaults)
  local opts = vim.tbl_extend("force", {}, defaults or {})
  opts.pathspecs = {}

  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == "--current" then
      opts.scope = "current"
    elseif arg == "--staged" or arg == "--cached" then
      opts.mode = "staged"
    elseif arg == "--all" then
      opts.mode = "all"
    elseif arg == "--no-untracked" then
      opts.include_untracked = false
    elseif arg == "--base" then
      opts.mode = "all"
      opts.base = args[i + 1]
      i = i + 1
    elseif arg == "--rev" then
      opts.mode = "rev"
      local spec = args[i + 1]
      if spec and spec:find("%.%.") then
        local left, right = spec:match("^(.-)%.%.(.+)$")
        opts.base = left
        opts.target = right
        i = i + 1
      else
        opts.base = args[i + 1]
        opts.target = args[i + 2]
        i = i + 2
      end
    elseif arg == "--" then
      for j = i + 1, #args do
        opts.pathspecs[#opts.pathspecs + 1] = args[j]
      end
      break
    else
      opts.pathspecs[#opts.pathspecs + 1] = arg
    end
    i = i + 1
  end

  return opts
end

local function parse_log_args(args)
  local opts = { pathspecs = {} }
  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == "--all" then
      opts.all = true
    elseif arg == "--max-count" then
      opts.max_count = tonumber(args[i + 1])
      i = i + 1
    elseif arg == "--" then
      for j = i + 1, #args do
        opts.pathspecs[#opts.pathspecs + 1] = args[j]
      end
      break
    else
      opts.pathspecs[#opts.pathspecs + 1] = arg
    end
    i = i + 1
  end
  return opts
end

local function parse_compare_args(args)
  local opts = {}
  local refs = {}
  for _, arg in ipairs(args) do
    if arg == "--direct" then
      opts.direct = true
    else
      refs[#refs + 1] = arg
    end
  end
  return refs[1], refs[2], opts
end

vim.api.nvim_create_user_command("DiffBandit", function(opts)
  local args = opts.fargs
  if #args < 2 then
    nvim.notify_error("provide two file paths")
    return
  end

  local left = vim.fn.expand(args[1])
  local right = vim.fn.expand(args[2])

  report(diffbandit.files(left, right))
end, {
  nargs = "+",
  complete = "file",
  desc = "Open DiffBandit diff view for two files",
})

vim.api.nvim_create_user_command("DiffBanditBuffers", function(opts)
  local args = opts.fargs
  if #args < 2 then
    nvim.notify_error("provide two buffer numbers", "DiffBanditBuffers")
    return
  end

  local bufnr_a = tonumber(args[1])
  local bufnr_b = tonumber(args[2])
  if not bufnr_a or not vim.api.nvim_buf_is_valid(bufnr_a) then
    nvim.notify_error("invalid first buffer", "DiffBanditBuffers")
    return
  end
  if not bufnr_b or not vim.api.nvim_buf_is_valid(bufnr_b) then
    nvim.notify_error("invalid second buffer", "DiffBanditBuffers")
    return
  end

  report(diffbandit.buffers(bufnr_a, bufnr_b))
end, {
  nargs = "+",
  complete = function()
    local items = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        table.insert(items, tostring(buf))
      end
    end
    return items
  end,
  desc = "Open DiffBandit diff view for two buffers",
})

vim.api.nvim_create_user_command("DiffBanditGit", function(opts)
  local git_opts = parse_git_args(opts.fargs, {})
  report(diffbandit.git(git_opts))
end, {
  nargs = "*",
  complete = "file",
  desc = "Open DiffBandit git diff view",
})

vim.api.nvim_create_user_command("DiffBanditGitCurrent", function(opts)
  local git_opts = parse_git_args(opts.fargs, { scope = "current" })
  local path
  if #git_opts.pathspecs > 0 then
    path = git_opts.pathspecs[1]
    git_opts.pathspecs = {}
  end
  report(diffbandit.git_file(path, git_opts))
end, {
  nargs = "*",
  complete = "file",
  desc = "Open DiffBandit git diff view for the current file",
})

vim.api.nvim_create_user_command("DiffBanditCommitPanel", function(opts)
  local git_opts = parse_git_args(opts.fargs, {})
  report(diffbandit.commit_panel(git_opts))
end, {
  nargs = "*",
  complete = "file",
  desc = "Toggle the DiffBandit Git commit panel",
})

vim.api.nvim_create_user_command("DiffBanditGitMenu", function(opts)
  local git_opts = parse_git_args(opts.fargs, {})
  report(diffbandit.git_menu(git_opts))
end, {
  nargs = "*",
  complete = "file",
  desc = "Open the DiffBandit Git workflow menu",
})

vim.api.nvim_create_user_command("DiffBanditGitLog", function(opts)
  local log_opts = parse_log_args(opts.fargs)
  report(diffbandit.git_log(log_opts))
end, {
  nargs = "*",
  complete = "file",
  desc = "Open the DiffBandit Git log browser",
})

vim.api.nvim_create_user_command("DiffBanditGitCommit", function(opts)
  local rev = opts.fargs[1]
  if not rev or rev == "" then
    nvim.notify_error("provide a revision", "DiffBanditGitCommit")
    return
  end
  report(diffbandit.git_commit(rev))
end, {
  nargs = 1,
  desc = "Open a read-only DiffBandit review for a commit",
})

vim.api.nvim_create_user_command("DiffBanditGitCompare", function(opts)
  local base, target, compare_opts = parse_compare_args(opts.fargs)
  if not base or not target then
    report(diffbandit.git_compare_branches(compare_opts))
    return
  end
  report(diffbandit.git_compare(base, target, compare_opts))
end, {
  nargs = "*",
  desc = "Open a read-only DiffBandit comparison between two refs",
})

vim.api.nvim_create_user_command("DiffBanditGitCheckout", function(opts)
  report(diffbandit.git_checkout(opts.fargs[1]))
end, {
  nargs = "?",
  desc = "Checkout a Git branch with DiffBandit safeguards",
})

vim.api.nvim_create_user_command("DiffBanditMerge", function(opts)
  local path = opts.fargs[1]
  report(diffbandit.merge(path))
end, {
  nargs = "?",
  complete = "file",
  desc = "Open DiffBandit merge conflict resolver",
})

vim.api.nvim_create_user_command("DiffBanditFolderDiff", function(opts)
  local args = opts.fargs
  if #args < 2 then
    nvim.notify_error("provide two folder paths", "DiffBanditFolderDiff")
    return
  end

  local left = vim.fn.expand(args[1])
  local right = vim.fn.expand(args[2])
  report(diffbandit.folder_diff(left, right))
end, {
  nargs = "+",
  complete = "dir",
  desc = "Open DiffBandit folder diff view",
})

local hunk_commands = {
  { "DiffBanditToggleStageHunk", "toggle_stage_hunk", "Toggle staged state for the current DiffBandit Git hunk" },
  { "DiffBanditStageHunk", "stage_hunk", "Stage the current DiffBandit Git hunk" },
  { "DiffBanditUnstageHunk", "unstage_hunk", "Unstage the current DiffBandit Git hunk" },
  { "DiffBanditDiscardHunk", "discard_hunk", "Discard the current DiffBandit Git hunk" },
  { "DiffBanditApplyLeftHunk", "apply_left_hunk", "Apply the left DiffBandit hunk side to the right target" },
  { "DiffBanditApplyRightHunk", "apply_right_hunk", "Apply the right DiffBandit hunk side to the left target" },
  { "DiffBanditUndo", "undo", "Undo the last DiffBandit action for the current file" },
}

for _, command in ipairs(hunk_commands) do
  local name, method, desc = command[1], command[2], command[3]
  vim.api.nvim_create_user_command(name, function()
    diffbandit[method]()
  end, { desc = desc })
end
