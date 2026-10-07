-- Standalone launcher behind bin/diffbandit: parses git-diff-style arguments,
-- opens the matching DiffBandit view for the repository at cwd, and quits
-- nvim once the last DiffBandit view closes.
--
--   diffbandit [--cached] [--no-untracked] [<rev> [<rev>] | <a>..<b> | <a>...<b>] [--] [<path>...]
--   diffbandit show <rev> [--] [<path>...]

local git = require("diffbandit.git")
local panel_mod = require("diffbandit.panel")
local state = require("diffbandit.state")

local M = {}

-- A..B / A...B, or nil when either named side is not a revision (so paths
-- such as ../file stay pathspecs).
local function split_range(arg, is_rev)
  local left, dots, right = arg:match("^(.-)(%.%.%.?)(.*)$")
  if not left or (left ~= "" and not is_rev(left)) or (right ~= "" and not is_rev(right)) then
    return nil
  end
  return {
    base = left ~= "" and left or "HEAD",
    target = right ~= "" and right or "HEAD",
    merge_base = dots == "...",
  }
end

-- Pure: turns argv into a plan. is_rev(arg) decides whether a bare positional
-- names a revision (otherwise it is a pathspec, as with `git diff`).
function M.parse(args, is_rev)
  args = args or {}
  local pathspecs = {}
  local revs = {}
  local range
  local cached = false
  local include_untracked
  local show = args[1] == "show"
  local i = show and 2 or 1

  while i <= #args do
    local arg = args[i]
    if arg == "--" then
      for j = i + 1, #args do
        pathspecs[#pathspecs + 1] = args[j]
      end
      break
    elseif arg == "--cached" or arg == "--staged" then
      cached = true
    elseif arg == "--no-untracked" then
      include_untracked = false
    elseif arg:sub(1, 1) == "-" then
      return nil, "unknown option: " .. arg
    elseif #pathspecs == 0 and not range and split_range(arg, is_rev) then
      range = split_range(arg, is_rev)
    elseif #pathspecs == 0 and #revs < 2 and is_rev(arg) then
      revs[#revs + 1] = arg
    else
      pathspecs[#pathspecs + 1] = arg
    end
    i = i + 1
  end

  if show then
    if #revs ~= 1 or range or cached then
      return nil, "usage: diffbandit show <rev> [--] [<path>...]"
    end
    return { kind = "commit", rev = revs[1], opts = { pathspecs = pathspecs } }
  end
  if range and #revs > 0 then
    return nil, "a range cannot be combined with other revisions"
  end
  if cached and (range or #revs > 0) then
    return nil, "--cached with a revision is not supported"
  end

  if range or #revs == 2 then
    range = range or { base = revs[1], target = revs[2], merge_base = false }
    return {
      kind = "compare",
      base = range.base,
      target = range.target,
      opts = { direct = not range.merge_base, pathspecs = pathspecs },
    }
  end

  local opts = { pathspecs = pathspecs, include_untracked = include_untracked }
  if #revs == 1 then
    opts.mode = "all"
    opts.base = revs[1]
  elseif cached then
    opts.mode = "staged"
  end
  return { kind = "status", opts = opts }
end

-- True while any DiffBandit view is on screen: a live session (diff, merge,
-- folder) or a commit panel whose windows are still open.
function M.has_live_view()
  for _, session in pairs(state.sessions) do
    if session and not session.disposed then
      return true
    end
  end
  for _, panel in pairs(state.panels) do
    if panel and not panel.disposed and panel_mod.is_open(panel) then
      return true
    end
  end
  return false
end

local quit_group

local function watch_for_quit()
  if quit_group then
    return
  end
  quit_group = vim.api.nvim_create_augroup("DiffBanditLauncher", { clear = true })
  -- Scheduled so file switches (close one host, start the next) settle first.
  vim.api.nvim_create_autocmd({ "TabClosed", "WinClosed" }, {
    group = quit_group,
    callback = function()
      vim.schedule(function()
        if not M.has_live_view() then
          pcall(vim.cmd, "confirm qall")
        end
      end)
    end,
  })
end

function M.launch(args, opts)
  opts = opts or {}
  local diffbandit = require("diffbandit")
  local uv = vim.uv or vim.loop
  local cwd = opts.cwd or uv.cwd()
  local root, root_err = git.find_root(cwd)
  if not root then
    return nil, root_err or "not a git repository"
  end
  local plan, parse_err = M.parse(args, function(arg)
    return git.is_revision(root, arg)
  end)
  if not plan then
    return nil, parse_err
  end
  plan.opts.root = root
  -- Like `git diff`, pathspecs are cwd-relative; git runs from the root here.
  for index, pathspec in ipairs(plan.opts.pathspecs) do
    if pathspec:sub(1, 1) ~= ":" then
      local abs = pathspec:sub(1, 1) == "/" and pathspec or (cwd .. "/" .. pathspec)
      local rel = git.relpath(root, abs)
      plan.opts.pathspecs[index] = rel ~= "" and rel or "."
    end
  end

  local host, err
  if plan.kind == "commit" then
    host, err = diffbandit.git_commit(plan.rev, plan.opts)
  elseif plan.kind == "compare" then
    host, err = diffbandit.git_compare(plan.base, plan.target, plan.opts)
  else
    host, err = diffbandit.git_panel(plan.opts)
  end
  if host and opts.quit_on_close then
    state.quit_on_close = true
    watch_for_quit()
  end
  return host, err
end

local function fail(err)
  local message = tostring(err or "unknown error")
  local errfile = vim.env.DIFFBANDIT_ERRFILE
  if not errfile or errfile == "" then
    vim.api.nvim_err_writeln("diffbandit: " .. message)
    return
  end
  pcall(vim.fn.writefile, { "diffbandit: " .. message }, errfile)
  if message == "no git changes" then
    vim.cmd("qall!")
  else
    vim.cmd("cquit 1")
  end
end

-- Entry point for bin/diffbandit. Arguments arrive in $DIFFBANDIT_ARGV,
-- separated by \31, so nvim never treats them as files to edit.
function M.main()
  if (vim.env.DIFFBANDIT_ERRFILE or "") == "" then
    vim.notify("diffbandit: :DiffBanditLaunch is run by bin/diffbandit", vim.log.levels.ERROR)
    return
  end
  local args = {}
  for arg in (vim.env.DIFFBANDIT_ARGV or ""):gmatch("([^\31]*)\31") do
    args[#args + 1] = arg
  end
  local function run()
    local host, err = M.launch(args, { quit_on_close = true })
    if not host then
      fail(err)
    end
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(run)
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        vim.schedule(run)
      end,
    })
  end
end

return M
