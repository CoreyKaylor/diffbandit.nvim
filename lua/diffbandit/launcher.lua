-- Standalone launcher behind bin/diffbandit: parses git-diff-style arguments,
-- opens the matching DiffBandit view for the repository at cwd, and quits
-- nvim once the last DiffBandit view closes.
--
--   diffbandit [--cached] [--no-untracked] [<rev> [<rev>] | <a>..<b> | <a>...<b>] [--] [<path>...]
--   diffbandit show <rev> [--] [<path>...]
--   diffbandit compare [--direct | --unpushed] [<base> [<target>]] [--] [<path>...]
--   diffbandit log [--all] [-n <count>] [<rev>] [--] [<path>...]
--   diffbandit stash [<n> | stash@{<n>}] [--] [<path>...]

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

-- Positionals and pathspecs for the subcommands: bare arguments that name
-- revisions come first (up to max_revs); the rest, and anything after --,
-- are pathspecs. on_flag(arg, next_arg) returns how many arguments it
-- consumed (0 for an unknown option).
local function parse_subcommand(args, is_rev, max_revs, on_flag)
  local revs, pathspecs = {}, {}
  local i = 2
  while i <= #args do
    local arg = args[i]
    if arg == "--" then
      for j = i + 1, #args do
        pathspecs[#pathspecs + 1] = args[j]
      end
      break
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
      local used = on_flag(arg, args[i + 1])
      if used == 0 then
        return nil, nil, "unknown option: " .. arg
      elseif used == nil then
        return nil, nil, arg .. " needs a value"
      end
      i = i + used
    else
      if #pathspecs == 0 and #revs < max_revs and is_rev(arg) then
        revs[#revs + 1] = arg
      else
        pathspecs[#pathspecs + 1] = arg
      end
      i = i + 1
    end
  end
  return revs, pathspecs, nil
end

local function parse_compare(args, is_rev)
  local plan = { kind = "compare", opts = {} }
  -- compare <a>...<b> / <a>..<b>: the range forms of the two-ref review.
  local range = args[2] and args[2]:find("%.%.") and split_range(args[2], is_rev)
  if range then
    local rest = { "compare", range.base, range.target }
    for i = 3, #args do
      rest[#rest + 1] = args[i]
    end
    if not range.merge_base then
      table.insert(rest, 2, "--direct")
    end
    return parse_compare(rest, is_rev)
  end
  local revs, pathspecs, err = parse_subcommand(args, is_rev, 2, function(arg)
    if arg == "--direct" then
      plan.direct = true
    elseif arg == "--unpushed" then
      plan.unpushed = true
    elseif arg == "--no-untracked" then
      plan.opts.include_untracked = false
    else
      return 0
    end
    return 1
  end)
  if not revs then
    return nil, err
  end
  if plan.unpushed and #revs > 0 then
    return nil, "--unpushed compares with the upstream; it takes no revisions"
  end
  plan.base, plan.target = revs[1], revs[2]
  plan.opts.pathspecs = pathspecs
  if plan.target then
    -- Two refs: the read-only review (same as <base>...<target>).
    return { kind = "compare", base = plan.base, target = plan.target, opts = { direct = plan.direct, pathspecs = pathspecs } }
  end
  plan.kind = "compare_worktree"
  return plan
end

local function parse_log(args, is_rev)
  local opts = {}
  -- git log takes ranges (main..feature) as well as single revisions.
  local function is_log_rev(arg)
    return is_rev(arg) or (arg:find("%.%.") ~= nil and split_range(arg, is_rev) ~= nil)
  end
  local revs, pathspecs, err = parse_subcommand(args, is_log_rev, 1, function(arg, value)
    if arg == "--all" then
      opts.all = true
      return 1
    end
    local inline = arg:match("^%-n(%d+)$") or arg:match("^%-%-max%-count=(%d+)$")
    if inline then
      opts.max_count = tonumber(inline)
      return 1
    end
    if arg == "-n" or arg == "--max-count" then
      if not (value and value:match("^%d+$")) then
        return nil
      end
      opts.max_count = tonumber(value)
      return 2
    end
    return 0
  end)
  if not revs then
    return nil, err
  end
  if opts.all and revs[1] then
    return nil, "log --all lists every ref; it takes no revision"
  end
  opts.rev = revs[1]
  opts.pathspecs = pathspecs
  return { kind = "log", opts = opts }
end

local function parse_stash(args)
  local rev = "stash@{0}"
  local pathspecs = {}
  local i = 2
  while i <= #args do
    local arg = args[i]
    if arg == "--" then
      for j = i + 1, #args do
        pathspecs[#pathspecs + 1] = args[j]
      end
      break
    elseif i == 2 and arg:match("^%d+$") then
      rev = "stash@{" .. arg .. "}"
    elseif i == 2 and arg:match("^stash@{%d+}$") then
      rev = arg
    else
      return nil, "usage: diffbandit stash [<n> | stash@{<n>}] [--] [<path>...]"
    end
    i = i + 1
  end
  return { kind = "commit", rev = rev, stash = true, opts = { pathspecs = pathspecs } }
end

local subcommands = {
  compare = parse_compare,
  log = parse_log,
  stash = parse_stash,
}

-- Pure: turns argv into a plan. is_rev(arg) decides whether a bare positional
-- names a revision (otherwise it is a pathspec, as with `git diff`). A
-- subcommand name wins over a same-named revision or path; put `--` first
-- (diffbandit -- log) to mean the path.
function M.parse(args, is_rev)
  args = args or {}
  if subcommands[args[1]] then
    return subcommands[args[1]](args, is_rev)
  end
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
-- folder), a commit panel whose windows are still open, or a registered view
-- such as the log browser. except_tabpage leaves out the views on that tab.
function M.has_live_view(except_tabpage)
  for tabpage, session in pairs(state.sessions) do
    if session and not session.disposed and tabpage ~= except_tabpage then
      return true
    end
  end
  for tabpage, panel in pairs(state.panels) do
    if panel and not panel.disposed and panel_mod.is_open(panel) and tabpage ~= except_tabpage then
      return true
    end
  end
  for view in pairs(state.views) do
    if view:is_open() and view:tabpage() ~= except_tabpage then
      return true
    end
  end
  return false
end

-- Under the launcher, a close key quits nvim once nothing else would be
-- left open; with another view open (a commit review opened from the log)
-- it only closes its own view.
function M.should_quit_on_close(tabpage)
  return state.quit_on_close == true and not M.has_live_view(tabpage or vim.api.nvim_get_current_tabpage())
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

-- Commits the launcher's log loads unless -n says otherwise: git log over a
-- long history is slow, and the browser is for recent work.
M.LOG_DEFAULT_COUNT = 1000

-- `compare` without a target: the working tree (commits, staged, unstaged,
-- untracked) against where the branch left its base, with the commit panel.
function M.launch_compare_worktree(diffbandit, root, plan)
  local base_ref, err = plan.base, nil
  if plan.unpushed then
    base_ref, err = git.upstream(root)
  elseif not base_ref then
    base_ref, err = git.default_branch(root)
  end
  if not base_ref then
    return nil, err
  end
  local base, label = base_ref, base_ref
  if not plan.direct then
    local merge_base, merge_err = git.merge_base(root, base_ref, "HEAD")
    if not merge_base then
      return nil, merge_err or ("no merge base with " .. base_ref)
    end
    base, label = merge_base, "merge-base " .. base_ref
  end
  local opts = vim.tbl_extend("force", plan.opts, { mode = "all", base = base, base_label = label })
  return diffbandit.git_panel(opts)
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
  if plan.kind == "commit" and plan.stash and not git.is_revision(root, plan.rev) then
    return nil, "no stash entry " .. plan.rev
  end
  if plan.kind == "compare_worktree" then
    host, err = M.launch_compare_worktree(diffbandit, root, plan)
  elseif plan.kind == "log" then
    plan.opts.fill = true
    plan.opts.max_count = plan.opts.max_count or M.LOG_DEFAULT_COUNT
    host, err = diffbandit.git_log(plan.opts)
  elseif plan.kind == "commit" then
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
