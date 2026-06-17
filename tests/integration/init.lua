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

local function topline_for(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return -1
  end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if ok and view and view.topline then
    return view.topline
  end
  return -1
end

local function focused_side(session)
  local win = vim.api.nvim_get_current_win()
  if win == session.left_win then
    return "left"
  elseif win == session.right_win then
    return "right"
  elseif win == session.left_num_win then
    return "left_numbers"
  elseif win == session.connector_win then
    return "connector"
  elseif win == session.right_num_win then
    return "right_numbers"
  end
  return "other"
end

function _G.DiffBanditTestWriteState(path)
  local session = _G.DiffBanditTestSession()
  if not session then
    vim.fn.writefile({ "missing_session" }, path)
    return
  end
  local left_cursor = vim.api.nvim_win_get_cursor(session.left_win)[1]
  local right_cursor = vim.api.nvim_win_get_cursor(session.right_win)[1]
  local state = string.format(
    "focus=%s left_top=%d right_top=%d left_cursor=%d right_cursor=%d chunk=%d",
    focused_side(session),
    topline_for(session.left_win),
    topline_for(session.right_win),
    left_cursor,
    right_cursor,
    session.current_chunk or -1
  )
  vim.fn.writefile({ state }, path)
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

vim.api.nvim_create_user_command("DBWriteState", function(opts)
  _G.DiffBanditTestWriteState(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1, complete = "file" })
