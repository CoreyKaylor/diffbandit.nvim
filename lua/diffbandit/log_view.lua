-- Git log browser: a bottom split listing commits with open/refresh
-- keymaps. Extracted from git_workflows.lua, which keeps only workflow
-- orchestration.
local git = require("diffbandit.git")
local nvim = require("diffbandit.nvim")
local ui = require("diffbandit.ui")

local M = {}

local function format_commit(commit, width)
  local hash = commit.short_hash or ""
  local date = commit.date or ""
  local author = commit.author or ""
  local subject = commit.subject or ""
  local prefix = string.format("%-10s %-10s ", hash, date)
  local author_width = math.min(18, math.max(8, math.floor(width / 5)))
  local author_text = ui.truncate_dotted(author, author_width)
  local subject_width = math.max(10, width - vim.fn.strdisplaywidth(prefix) - author_width - 2)
  return prefix .. string.format("%-" .. tostring(author_width) .. "s  %s", author_text, ui.truncate_dotted(subject, subject_width))
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
  nvim.set_buffer_options(browser.buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(browser.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(browser.buf, browser.ns, 0, -1)
  vim.api.nvim_buf_add_highlight(browser.buf, browser.ns, "DiffBanditStatusAccent", 0, 0, -1)
  nvim.set_buffer_options(browser.buf, { modifiable = false })
end

function M.open(config, opts, callbacks)
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
  browser.buf = nvim.make_buffer("diffbandit-git-log", nil, { modifiable = false })
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
      nvim.notify_error(tostring(refresh_err))
      return
    end
    browser.commits = next_commits
    render_log(browser)
  end, map_opts)

  return browser, nil
end

return M
