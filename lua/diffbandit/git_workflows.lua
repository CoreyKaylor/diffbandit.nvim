local git = require("diffbandit.git")
local nvim = require("diffbandit.nvim")

local M = {}

local function trim_width(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local result = ""
  local marker = "..."
  local char_count = vim.fn.strchars(text)
  for index = 0, char_count - 1 do
    local next_text = result .. vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(next_text .. marker) > width then
      break
    end
    result = next_text
  end
  return result .. marker
end

local function set_modifiable(buf, value)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", value, { buf = buf })
  end
end

local function format_commit(commit, width)
  local hash = commit.short_hash or ""
  local date = commit.date or ""
  local author = commit.author or ""
  local subject = commit.subject or ""
  local prefix = string.format("%-10s %-10s ", hash, date)
  local author_width = math.min(18, math.max(8, math.floor(width / 5)))
  local author_text = trim_width(author, author_width)
  local subject_width = math.max(10, width - vim.fn.strdisplaywidth(prefix) - author_width - 2)
  return prefix .. string.format("%-" .. tostring(author_width) .. "s  %s", author_text, trim_width(subject, subject_width))
end

local function render_log(browser)
  local width = 80
  if browser.win and vim.api.nvim_win_is_valid(browser.win) then
    width = math.max(40, vim.api.nvim_win_get_width(browser.win))
  end
  local lines = { "Git Log" }
  for _, commit in ipairs(browser.commits or {}) do
    lines[#lines + 1] = format_commit(commit, width)
  end
  if #browser.commits == 0 then
    lines[#lines + 1] = "No commits"
  end
  set_modifiable(browser.buf, true)
  vim.api.nvim_buf_set_lines(browser.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(browser.buf, browser.ns, 0, -1)
  vim.api.nvim_buf_add_highlight(browser.buf, browser.ns, "DiffBanditStatusAccent", 0, 0, -1)
  set_modifiable(browser.buf, false)
end

function M.open_log(config, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local root, root_err = git.root(opts)
  if not root then
    return nil, root_err
  end
  local commits, err = git.log(root, opts)
  if not commits then
    return nil, err
  end

  local browser = {
    root = root,
    opts = opts,
    config = config,
    commits = commits,
    callbacks = callbacks,
    ns = vim.api.nvim_create_namespace("DiffBanditGitLog"),
  }
  browser.buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, browser.buf, "diffbandit-git-log")
  nvim.set_buffer_options(browser.buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
    bufhidden = "wipe",
  })
  browser.win = vim.api.nvim_open_win(browser.buf, true, {
    split = "below",
    height = opts.height or 15,
  })
  nvim.set_window_options(browser.win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixheight = true,
    winhl = "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,CursorLine:DiffBanditCursorLine",
  })
  render_log(browser)
  if #commits > 0 then
    pcall(vim.api.nvim_win_set_cursor, browser.win, { 2, 0 })
  end

  local map_opts = { buffer = browser.buf, nowait = true, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    if browser.win and vim.api.nvim_win_is_valid(browser.win) then
      pcall(vim.api.nvim_win_close, browser.win, true)
    end
  end, map_opts)
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(browser.win)[1]
    local commit = browser.commits[line - 1]
    if commit and callbacks.open_commit then
      callbacks.open_commit(commit.hash, { root = root })
    end
  end, map_opts)
  vim.keymap.set("n", "R", function()
    local next_commits, refresh_err = git.log(root, opts)
    if not next_commits then
      vim.notify("DiffBandit: " .. tostring(refresh_err), vim.log.levels.ERROR)
      return
    end
    browser.commits = next_commits
    render_log(browser)
  end, map_opts)

  return browser, nil
end

function M.select_branch(root, prompt, callback, opts)
  opts = opts or {}
  local branches, err = git.list_branches(root)
  if not branches then
    vim.notify("DiffBandit: " .. tostring(err), vim.log.levels.ERROR)
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
