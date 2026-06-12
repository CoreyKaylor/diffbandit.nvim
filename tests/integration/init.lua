-- Minimal init for integration tests
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(script_dir .. "/../..", ":p")

-- Set up runtime path
vim.opt.runtimepath:prepend(root)

-- Load the plugin
require("diffbandit").setup({})

function _G.DiffBanditTestSession()
  local sessions = require("diffbandit.state").sessions
  local _, session = next(sessions)
  return session
end

function _G.DiffBanditTestSetViewports(left_topline, right_topline)
  local session = _G.DiffBanditTestSession()
  if session then
    session:set_viewport_toplines(left_topline, right_topline)
  end
end

function _G.DiffBanditTestFocus(side)
  local session = _G.DiffBanditTestSession()
  if not session then
    return
  end
  if side == "left" then
    vim.api.nvim_set_current_win(session.left_win)
  elseif side == "right" then
    vim.api.nvim_set_current_win(session.right_win)
  else
    vim.api.nvim_set_current_win(session.connector_win)
  end
end

vim.api.nvim_create_user_command("DBViewport", function(opts)
  local left_topline = tonumber(opts.fargs[1])
  local right_topline = tonumber(opts.fargs[2])
  _G.DiffBanditTestSetViewports(left_topline, right_topline)
  vim.cmd("redraw!")
end, { nargs = "*" })

vim.api.nvim_create_user_command("DBFocus", function(opts)
  _G.DiffBanditTestFocus(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = "*" })
