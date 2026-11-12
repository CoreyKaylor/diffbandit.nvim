local M = {}

local function notify(msg, level, prefix)
  vim.notify((prefix or "DiffBandit") .. ": " .. msg, level)
end

function M.notify_error(msg, prefix)
  notify(msg, vim.log.levels.ERROR, prefix)
end

function M.notify_info(msg, prefix)
  notify(msg, vim.log.levels.INFO, prefix)
end

function M.notify_warn(msg, prefix)
  notify(msg, vim.log.levels.WARN, prefix)
end

function M.set_buffer_options(buf, opts)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for key, value in pairs(opts or {}) do
    if value ~= nil then
      vim.api.nvim_set_option_value(key, value, { buf = buf })
    end
  end
end

function M.set_window_options(win, opts)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for key, value in pairs(opts or {}) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = win })
  end
end

function M.set_window_width(win, width)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_width, win, math.max(1, width))
  end
end

function M.set_window_height(win, height)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_height, win, math.max(1, height))
  end
end

function M.get_window_width(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
  return 0
end

-- Text rows of a window. nvim_win_get_height counts the winbar row too;
-- every DiffBandit viewport computation means the rows code is drawn on.
function M.get_window_height(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return math.max(0, vim.fn.winheight(win))
  end
  return 0
end

-- Rows 'scrolloff' keeps around the cursor in win ('scrolloff=999' asks for a
-- centered cursor, so the value is capped at half the window).
function M.scrolloff_rows(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return 0
  end
  local half = math.floor((M.get_window_height(win) - 1) / 2)
  return math.max(0, math.min(vim.wo[win].scrolloff, half))
end

-- Rows above a jump target. A topline inside a pane's 'scrolloff' does not hold
-- (see set_win_view_topline) and each pane would move by its own amount, so the
-- context covers the margin of every pane.
function M.jump_context(navigation, wins)
  local context = math.max(0, tonumber(navigation and navigation.jump_context) or 0)
  for _, win in ipairs(wins) do
    context = math.max(context, M.scrolloff_rows(win))
  end
  return context
end

function M.set_win_view_topline(win, topline, opts)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  topline = math.max(1, topline or 1)
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
  local cursor_line = math.min(topline, line_count)
  local preserve_cursor = opts and opts.preserve_cursor
  pcall(vim.api.nvim_win_call, win, function()
    if not preserve_cursor then
      pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    end
    local view = vim.fn.winsaveview()
    view.topline = topline
    pcall(vim.fn.winrestview, view)
    -- Neovim applies 'scrolloff' to the restored view only when the view is next
    -- validated. Settle it now, or the redraw moves the pane after its gutters
    -- were synced and without a WinScrolled to bring them along.
    vim.fn.line("w0")
  end)
end

--- Windows a WinScrolled event covers. <amatch> names only the first: one
--- scroll moves every 'scrollbind' window at once, sidecars included. An
--- event fired by hand carries no v:event, so fall back to <amatch>.
function M.scrolled_wins(event)
  local wins = {}
  for key in pairs(vim.v.event or {}) do
    local win = tonumber(key)
    if win then
      wins[#wins + 1] = win
    end
  end
  if #wins == 0 then
    wins[1] = tonumber(event and event.match)
  end
  return wins
end

function M.get_win_view_topline(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return 1
  end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if ok and view and view.topline then
    return view.topline
  end
  return 1
end

function M.make_buffer(name, lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  if name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  M.set_buffer_options(buf, {
    buftype = opts.buftype or "nofile",
    bufhidden = opts.bufhidden or "wipe",
    swapfile = false,
    modifiable = true,
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
  M.set_buffer_options(buf, {
    modifiable = opts.modifiable ~= false,
    filetype = opts.filetype,
  })
  return buf
end

return M
