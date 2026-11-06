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

--- Key for the parts of a tabpage's layout DiffBandit does not own: the
--- editor size plus every foreign split window (file trees, quickfix, …) with
--- its size. Owned windows contribute only their id, so resizing them (the
--- user dragging the separator between the source panes, or DiffBandit's own
--- relayout) leaves the key alone, while opening, closing, or resizing a
--- foreign window changes it. Floats are ignored.
function M.foreign_layout_key(tabpage, owned)
  if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
    return nil
  end
  local is_owned = {}
  for _, win in pairs(owned or {}) do
    is_owned[win] = true
  end
  local parts = { vim.o.columns .. "x" .. vim.o.lines }
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      if is_owned[win] then
        parts[#parts + 1] = tostring(win)
      else
        parts[#parts + 1] = win .. ":" .. vim.api.nvim_win_get_width(win)
          .. "x" .. vim.api.nvim_win_get_height(win)
      end
    end
  end
  return table.concat(parts, ",")
end

local split = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit"
local hidden_split = "VertSplit:DiffBanditHiddenSplit,WinSeparator:DiffBanditHiddenSplit"

M.winhl = {
  split = split,
  hidden_split = hidden_split,
  source = split .. ",CursorLine:DiffBanditCursorLine,SignColumn:DiffBanditSignColumn",
  hidden_source = hidden_split .. ",CursorLine:DiffBanditCursorLine,SignColumn:DiffBanditSignColumn",
  gutter = "Normal:DiffBanditConnectorContext,NormalNC:DiffBanditConnectorContext,"
    .. "WinBar:DiffBanditConnectorContext,WinBarNC:DiffBanditConnectorContext,"
    .. split .. ",CursorLine:DiffBanditCursorLine",
  overview = "Normal:DiffBanditOverviewContext,NormalNC:DiffBanditOverviewContext,"
    .. "WinBar:DiffBanditOverviewContext,WinBarNC:DiffBanditOverviewContext,"
    .. hidden_split .. ",CursorLine:DiffBanditCursorLine",
  status = "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,"
    .. "StatusLine:DiffBanditStatusLine,StatusLineNC:DiffBanditStatusLine,"
    .. "WinBar:DiffBanditStatus,WinBarNC:DiffBanditStatus,"
    .. split .. ",CursorLine:DiffBanditStatus",
  panel = split .. ",Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,CursorLine:DiffBanditCursorLine",
}

M.win_opts = {}

--- Window-local 'fillchars' for windows whose separator is hidden
--- (winhl.hidden_split): the user's global fillchars with a blank `vert`.
--- DiffBanditHiddenSplit alone paints the glyph fg = bg, which only hides it
--- when the background is opaque; a transparent theme would show the glyph in
--- the reference colour over the terminal background.
function M.hidden_separator_fillchars()
  local chars = vim.opt_global.fillchars:get()
  chars.vert = " "
  local parts = {}
  for key, value in pairs(chars) do
    parts[#parts + 1] = key .. ":" .. value
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Source/content pane: cursorline on, no gutter columns. 'scrolloff' -1 defers
-- to the user's global value, which diff and merge navigation allow for
-- (nvim.jump_context, nvim.scrolloff_rows).
function M.win_opts.source(winhl, overrides)
  local opts = {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    scrolloff = -1,
    sidescrolloff = 0,
    foldenable = false,
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
    scrolloff = 0,
    sidescrolloff = 0,
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
