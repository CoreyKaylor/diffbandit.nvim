-- Minimal init for integration tests
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(script_dir .. "/../..", ":p")

-- Set up runtime path
vim.opt.runtimepath:prepend(root)
vim.opt.termguicolors = true

-- Load the plugin
require("diffbandit").setup({})

do
  local Session = require("diffbandit.session")
  if not Session._diffbandit_integration_perf_wrapped then
    Session._diffbandit_integration_perf_wrapped = true
    local original_render = Session.render
    function Session:render(...)
      self.test_render_count = (self.test_render_count or 0) + 1
      return original_render(self, ...)
    end

    local original_request_viewport_rerender = Session.request_viewport_rerender
    function Session:request_viewport_rerender(...)
      self.test_viewport_request_count = (self.test_viewport_request_count or 0) + 1
      return original_request_viewport_rerender(self, ...)
    end
  end
end

function _G.DiffBanditTestSession()
  local sessions = require("diffbandit.state").sessions
  local _, session = next(sessions)
  return session
end

function _G.DiffBanditTestPanel()
  local panel = require("diffbandit.state").panels[vim.api.nvim_get_current_tabpage()]
  if panel and not panel.disposed then
    return panel
  end
  return nil
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
  elseif win == session.left_overview_win then
    return "left_overview"
  elseif win == session.right_win then
    return "right"
  elseif win == session.right_overview_win then
    return "right_overview"
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

function _G.DiffBanditTestResetPerf()
  local session = _G.DiffBanditTestSession()
  if session then
    session.test_render_count = 0
    session.test_viewport_request_count = 0
  end
end

function _G.DiffBanditTestWritePerfState(path)
  local session = _G.DiffBanditTestSession()
  if not session then
    vim.fn.writefile({ "missing_session" }, path)
    return
  end
  local lines = {
    string.format("render_count=%d", session.test_render_count or 0),
    string.format("viewport_request_count=%d", session.test_viewport_request_count or 0),
    string.format("left_top=%d", topline_for(session.left_win)),
    string.format("right_top=%d", topline_for(session.right_win)),
    string.format("left_lines=%d", #(session.left and session.left.lines or {})),
    string.format("right_lines=%d", #(session.right and session.right.lines or {})),
  }
  vim.fn.writefile(lines, path)
end

function _G.DiffBanditTestRapidScroll(count)
  count = tonumber(count) or 1
  local key = vim.api.nvim_replace_termcodes("<C-E>", true, false, true)
  for _ = 1, count do
    vim.api.nvim_feedkeys(key, "nx", false)
  end
end

function _G.DiffBanditTestWriteGitState(path)
  local session = _G.DiffBanditTestSession()
  if not session then
    vim.fn.writefile({ "missing_session" }, path)
    return
  end
  local queue = session.file_queue or {}
  local lines = {
    string.format("queue_index=%d", session.file_queue_index or -1),
    string.format("queue_count=%d", #(queue.entries or {})),
    string.format("chunk=%d", session.current_chunk or -1),
    string.format("left_label=%s", session.left and (session.left.label or session.left.path or "") or ""),
    string.format("right_label=%s", session.right and (session.right.label or session.right.path or "") or ""),
    string.format("status_left=%s", session.status_lines and session.status_lines.left or ""),
    string.format("status_center=%s", session.status_lines and session.status_lines.center or ""),
    string.format("status_right=%s", session.status_lines and session.status_lines.right or ""),
  }
  vim.fn.writefile(lines, path)
end

function _G.DiffBanditTestWritePanelState(path)
  local standalone = _G.DiffBanditTestPanel()
  local session = standalone or _G.DiffBanditTestSession()
  if not session then
    vim.fn.writefile({ "missing_session" }, path)
    return
  end
  local queue = session.file_queue or {}
  local panel = session.panel or {}
  local focus = focused_side(session)
  local current_win = vim.api.nvim_get_current_win()
  if panel.nav_win and current_win == panel.nav_win then
    focus = "panel"
  elseif panel.commit_win and current_win == panel.commit_win then
    focus = "commit"
  end
  local row_text = ""
  local selected_path = ""
  if panel.nav_win and vim.api.nvim_win_is_valid(panel.nav_win) then
    local row = vim.api.nvim_win_get_cursor(panel.nav_win)[1]
    row_text = (vim.api.nvim_buf_get_lines(panel.nav_buf, row - 1, row, false)[1] or "")
    local model = panel.rows and panel.rows[row]
    if model and model.entry then
      selected_path = model.entry.path or ""
    end
  end
  local stage_parts = {}
  for index, state in pairs(panel.stage_states or {}) do
    stage_parts[#stage_parts + 1] = tostring(index) .. ":" .. tostring(state)
  end
  table.sort(stage_parts)
  local lines = {
    string.format("surface=%s", standalone and "panel" or "session"),
    string.format("panel_visible=%s", tostring(panel.visible == true)),
    string.format("focus=%s", focus),
    string.format("queue_index=%d", session.file_queue_index or -1),
    string.format("queue_count=%d", #(queue.entries or {})),
    string.format("chunk=%d", session.current_chunk or -1),
    string.format("amend=%s", tostring(panel.amend == true)),
    string.format("selected_path=%s", selected_path),
    string.format("row=%s", row_text),
    string.format("stage_states=%s", table.concat(stage_parts, ",")),
  }
  vim.fn.writefile(lines, path)
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

vim.api.nvim_create_user_command("DBResetPerf", function()
  _G.DiffBanditTestResetPerf()
end, { nargs = 0 })

vim.api.nvim_create_user_command("DBWritePerfState", function(opts)
  _G.DiffBanditTestWritePerfState(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("DBRapidScroll", function(opts)
  _G.DiffBanditTestRapidScroll(opts.fargs[1])
end, { nargs = 1 })

vim.api.nvim_create_user_command("DBWriteGitState", function(opts)
  _G.DiffBanditTestWriteGitState(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("DBWritePanelState", function(opts)
  _G.DiffBanditTestWritePanelState(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1, complete = "file" })
