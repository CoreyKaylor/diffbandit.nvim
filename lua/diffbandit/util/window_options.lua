-- Keep DiffBandit's window options inside DiffBandit's windows.
--
-- Neovim remembers the window-local options a buffer last had in a window
-- and gives them back when the buffer is shown in a window it has not been
-- in before. A file a view loaded outlives the view (quickfix lists and the
-- jump list still point at it), so it carries the pane's look out with it:
-- `:edit`, `:buffer`, `:cnext` or a picker would show the file with the
-- padding winbar, DiffBandit's highlights, no number column and a hidden
-- split separator. `:tabedit` and `:split` from a pane copy the same options.
--
-- DiffBandit marks every window it styles (util/nvim.set_window_options).
-- When a buffer enters a window that is not marked but still wears
-- DiffBandit's highlights, those options go back to the user's values.
local layout = require("diffbandit.util.layout")

local M = {}

M.MARK = "diffbandit_window"

local installed = false

local function option_names()
  local names = { winbar = true, fillchars = true, statusline = true }
  for _, opts in ipairs({
    layout.win_opts.source(),
    layout.win_opts.gutter(nil, true),
    layout.win_opts.header(),
    layout.win_opts.panel(),
  }) do
    for name in pairs(opts) do
      names[name] = true
    end
  end
  return names
end

--- True when the window carries options DiffBandit set but is not one of
--- DiffBandit's own windows.
function M.leaked(win)
  if not (win and vim.api.nvim_win_is_valid(win)) or vim.w[win][M.MARK] then
    return false
  end
  local winhl = vim.api.nvim_get_option_value("winhighlight", { win = win })
  return winhl:find("DiffBandit", 1, true) ~= nil
end

--- Put DiffBandit's window options on `win` back to the user's global values.
--- Does nothing unless the window carries them and is not DiffBandit's own.
function M.reset(win)
  if not M.leaked(win) then
    return false
  end
  vim.api.nvim_win_call(win, function()
    for name in pairs(option_names()) do
      local info = vim.api.nvim_get_option_info2(name, {})
      -- Global-local options drop their local value; window-local ones
      -- copy the global one.
      pcall(vim.cmd, (info.global_local and "set " or "setlocal ") .. name .. "<")
    end
  end)
  return true
end

local function install()
  if installed then
    return
  end
  installed = true
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = vim.api.nvim_create_augroup("DiffBanditWindowOptions", { clear = true }),
    callback = function()
      M.reset(vim.api.nvim_get_current_win())
    end,
  })
end

--- Mark `win` as a DiffBandit window, whose options are DiffBandit's to set.
--- The first mark installs the reset for every other window.
function M.mark(win)
  install()
  vim.w[win][M.MARK] = true
end

return M
