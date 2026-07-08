local git = require("diffbandit.git")
local nvim = require("diffbandit.util.nvim")
local log_view = require("diffbandit.util.log_view")

local M = {}

function M.open_log(config, opts, callbacks)
  return log_view.open(config, opts, callbacks)
end

function M.select_branch(root, prompt, callback, opts)
  opts = opts or {}
  local branches, err = git.list_branches(root)
  if not branches then
    nvim.notify_error(tostring(err))
    return
  end
  if opts.local_only then
    local local_branches = {}
    for _, branch in ipairs(branches) do
      if not branch.remote then
        local_branches[#local_branches + 1] = branch
      end
    end
    branches = local_branches
  end
  vim.ui.select(branches, {
    prompt = prompt or "DiffBandit branch",
    format_item = function(branch)
      return (branch.current and "* " or "  ") .. branch.name
    end,
  }, function(branch)
    if branch then
      callback(branch.name, branch)
    end
  end)
end

function M.open_menu(root, callbacks)
  callbacks = callbacks or {}
  local actions = {
    { label = "Local Changes / Commit Panel", id = "changes" },
    { label = "Compare Branches", id = "compare" },
    { label = "Show Log", id = "log" },
    { label = "Show Current File History", id = "file_log" },
    { label = "Checkout Branch", id = "checkout" },
  }
  vim.ui.select(actions, {
    prompt = "DiffBandit Git",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if not action then
      return
    end
    if action.id == "changes" and callbacks.changes then
      callbacks.changes({ root = root })
    elseif action.id == "compare" and callbacks.compare then
      callbacks.compare({ root = root })
    elseif action.id == "log" and callbacks.log then
      callbacks.log({ root = root, all = true })
    elseif action.id == "file_log" and callbacks.file_log then
      callbacks.file_log({ root = root, scope = "current" })
    elseif action.id == "checkout" and callbacks.checkout then
      callbacks.checkout({ root = root })
    end
  end)
end

return M
