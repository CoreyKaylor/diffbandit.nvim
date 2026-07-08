-- Shared window-layout idioms: the unfocusable-window opener, the canonical
-- winhl strings, and the per-pane-role window option tables used by the
-- diff session, merge, folder, and commit panel layouts.
local M = {}

-- Open a helper window (gutter, overview sidecar, status header) that should
-- not take focus. Older Neovim versions reject focusable/mouse for splits, so
-- fall back to a plain split when the first attempt fails.
function M.open_unfocusable_win(buf, anchor_win, opts)
  if not buf then
    return nil
  end
  opts = opts or {}
  local base = {
    split = opts.split or "right",
    win = anchor_win,
    width = opts.width,
    height = opts.height,
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, vim.tbl_extend("force", base, {
    focusable = false,
    mouse = false,
  }))
  if ok then
    return win
  end
  return vim.api.nvim_open_win(buf, false, base)
end

local split = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit"
local hidden_split = "VertSplit:DiffBanditHiddenSplit,WinSeparator:DiffBanditHiddenSplit"

M.winhl = {
  split = split,
  hidden_split = hidden_split,
  source = split .. ",CursorLine:DiffBanditCursorLine,SignColumn:DiffBanditSignColumn",
  hidden_source = hidden_split .. ",CursorLine:DiffBanditCursorLine,SignColumn:DiffBanditSignColumn",
  gutter = "Normal:DiffBanditConnectorContext,NormalNC:DiffBanditConnectorContext,"
    .. split .. ",CursorLine:DiffBanditCursorLine",
  overview = "Normal:DiffBanditOverviewContext,NormalNC:DiffBanditOverviewContext,"
    .. hidden_split .. ",CursorLine:DiffBanditCursorLine",
  status = "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,"
    .. "StatusLine:DiffBanditStatusLine,StatusLineNC:DiffBanditStatusLine,"
    .. split .. ",CursorLine:DiffBanditStatus",
  panel = split .. ",Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,CursorLine:DiffBanditCursorLine",
}

M.win_opts = {}

-- Source/content pane: cursorline on, no gutter columns.
function M.win_opts.source(winhl, overrides)
  local opts = {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = winhl or M.winhl.source,
  }
  if overrides then
    opts = vim.tbl_extend("force", opts, overrides)
  end
  return opts
end

-- Fixed-width helper pane (number gutters, connectors, overview sidecars).
function M.win_opts.gutter(winhl)
  return {
    number = false,
    relativenumber = false,
    list = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
    winhl = winhl or M.winhl.gutter,
  }
end

-- One-line status header above a pane.
function M.win_opts.header(winhl)
  return {
    number = false,
    relativenumber = false,
    list = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixheight = true,
    statusline = " ",
    winhl = winhl or M.winhl.status,
  }
end

-- Commit-panel nav/commit windows.
function M.win_opts.panel()
  return {
    number = false,
    relativenumber = false,
    list = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
    winhl = M.winhl.panel,
  }
end

return M
