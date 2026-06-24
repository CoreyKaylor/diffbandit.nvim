local diffbandit = require("diffbandit")

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

vim.api.nvim_create_user_command("DiffBandit", function(opts)
  local args = opts.fargs
  if #args < 2 then
    vim.notify("DiffBandit: provide two file paths", vim.log.levels.ERROR)
    return
  end

  local left = vim.fn.expand(args[1])
  local right = vim.fn.expand(args[2])

  local session, err = diffbandit.files(left, right)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
end, {
  nargs = "+",
  complete = "file",
  desc = "Open DiffBandit diff view for two files",
})

vim.api.nvim_create_user_command("DiffBanditBuffers", function(opts)
  local args = opts.fargs
  if #args < 2 then
    vim.notify("DiffBanditBuffers: provide two buffer numbers", vim.log.levels.ERROR)
    return
  end

  local bufnr_a = tonumber(args[1])
  local bufnr_b = tonumber(args[2])
  if not bufnr_a or not vim.api.nvim_buf_is_valid(bufnr_a) then
    vim.notify("DiffBanditBuffers: invalid first buffer", vim.log.levels.ERROR)
    return
  end
  if not bufnr_b or not vim.api.nvim_buf_is_valid(bufnr_b) then
    vim.notify("DiffBanditBuffers: invalid second buffer", vim.log.levels.ERROR)
    return
  end

  local session, err = diffbandit.buffers(bufnr_a, bufnr_b)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
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
  local session, err = diffbandit.git(git_opts)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
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
  local session, err = diffbandit.git_file(path, git_opts)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  complete = "file",
  desc = "Open DiffBandit git diff view for the current file",
})

vim.api.nvim_create_user_command("DiffBanditCommitPanel", function(opts)
  local git_opts = parse_git_args(opts.fargs, {})
  local session, err = diffbandit.commit_panel(git_opts)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  complete = "file",
  desc = "Toggle the DiffBandit Git commit panel",
})

vim.api.nvim_create_user_command("DiffBanditToggleStageHunk", function()
  diffbandit.toggle_stage_hunk()
end, {
  desc = "Toggle staged state for the current DiffBandit Git hunk",
})

vim.api.nvim_create_user_command("DiffBanditStageHunk", function()
  diffbandit.stage_hunk()
end, {
  desc = "Stage the current DiffBandit Git hunk",
})

vim.api.nvim_create_user_command("DiffBanditUnstageHunk", function()
  diffbandit.unstage_hunk()
end, {
  desc = "Unstage the current DiffBandit Git hunk",
})

vim.api.nvim_create_user_command("DiffBanditDiscardHunk", function()
  diffbandit.discard_hunk()
end, {
  desc = "Discard the current DiffBandit Git hunk",
})

vim.api.nvim_create_user_command("DiffBanditApplyLeftHunk", function()
  diffbandit.apply_left_hunk()
end, {
  desc = "Apply the left DiffBandit hunk side to the right target",
})

vim.api.nvim_create_user_command("DiffBanditApplyRightHunk", function()
  diffbandit.apply_right_hunk()
end, {
  desc = "Apply the right DiffBandit hunk side to the left target",
})

vim.api.nvim_create_user_command("DiffBanditUndo", function()
  diffbandit.undo()
end, {
  desc = "Undo the last DiffBandit action for the current file",
})
