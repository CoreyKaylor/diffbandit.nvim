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
  local current = sessions[vim.api.nvim_get_current_tabpage()]
  if current then
    return current
  end
  local _, session = next(sessions)
  return session
end

local function current_diffbandit_session()
  return require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
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

function _G.DiffBanditTestSelectFolderPath(rel)
  local session = current_diffbandit_session()
  if not session or not session.left_root or type(session.set_selected_index) ~= "function" then
    error("missing DiffBandit folder session")
  end
  for index, row in ipairs(session.visible_rows or {}) do
    if row.rel == rel then
      session:set_selected_index(index)
      if session.left_win and vim.api.nvim_win_is_valid(session.left_win) then
        vim.api.nvim_set_current_win(session.left_win)
      end
      return
    end
  end
  error("folder path not found: " .. tostring(rel))
end

function _G.DiffBanditTestWriteFolderState(path)
  local session = current_diffbandit_session()
  if not session then
    vim.fn.writefile({ "missing_session" }, path)
    return
  end
  if session.left_root then
    local selected = session.selected_rel or ""
    local row = selected ~= "" and session.rows_by_rel and session.rows_by_rel[selected] or nil
    local focus = "other"
    local current = vim.api.nvim_get_current_win()
    if current == session.left_win then
      focus = "left"
    elseif current == session.right_win then
      focus = "right"
    elseif current == session.gutter_win then
      focus = "gutter"
    end
    vim.fn.writefile({
      "surface=folder",
      "focus=" .. focus,
      "selected_rel=" .. selected,
      "selected_status=" .. tostring(row and row.status or ""),
      "filter=" .. tostring(session.filter or ""),
      "visible_count=" .. tostring(#(session.visible_rows or {})),
      "left_root=" .. tostring(session.left_root or ""),
      "right_root=" .. tostring(session.right_root or ""),
    }, path)
    return
  end
  vim.fn.writefile({
    "surface=file",
    "left_label=" .. tostring(session.left and (session.left.label or session.left.path or "") or ""),
    "right_label=" .. tostring(session.right and (session.right.label or session.right.path or "") or ""),
    "has_return_to=" .. tostring(session.return_to ~= nil),
  }, path)
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

function _G.DiffBanditTestOpenQueuePath(path)
  local session = _G.DiffBanditTestSession() or _G.DiffBanditTestPanel()
  if not session or not session.file_queue then
    error("missing DiffBandit queue")
  end
  for index, entry in ipairs(session.file_queue.entries or {}) do
    if entry.path == path or entry.old_path == path then
      if (entry.status == "U" or entry.kind == "unmerged") and type(session.open_merge_file) == "function" then
        assert(session:open_merge_file(index, { preserve_focus = true }))
      elseif type(session.goto_queue_file) == "function" then
        assert(session:goto_queue_file(index, { preserve_focus = true }))
      else
        error("queue session cannot open " .. tostring(path))
      end
      return
    end
  end
  error("queue path not found: " .. tostring(path))
end

function _G.DiffBanditTestSelectPanelPath(path)
  local session = _G.DiffBanditTestSession() or _G.DiffBanditTestPanel()
  if not session or not session.panel or not session.panel.nav_win then
    error("missing commit panel")
  end
  require("diffbandit.panel").render(session, nil, { refresh_stage_states = true })
  local panel = session.panel
  for row_index, row in ipairs(panel.rows or {}) do
    if row.entry and (row.entry.path == path or row.entry.old_path == path) then
      vim.api.nvim_set_current_win(panel.nav_win)
      vim.api.nvim_win_set_cursor(panel.nav_win, { row_index, row.name_col or 0 })
      return
    end
  end
  error("panel path not found: " .. tostring(path))
end

function _G.DiffBanditTestRunPanelAction(action_id)
  local session = _G.DiffBanditTestSession() or _G.DiffBanditTestPanel()
  if not session then
    error("missing DiffBandit session")
  end
  local ok, err = require("diffbandit.panel").run_file_action(session, action_id, { confirm = false })
  if not ok then
    error(tostring(err or "panel action failed"))
  end
end

function _G.DiffBanditTestAcceptResolve(side)
  local session = _G.DiffBanditTestSession()
  if not session or type(session.accept) ~= "function" or type(session.resolve) ~= "function" then
    error("missing merge session")
  end
  assert(session:accept(side))
  assert(session:resolve())
end

function _G.DiffBanditTestWritePanelCommit(message)
  local session = _G.DiffBanditTestSession() or _G.DiffBanditTestPanel()
  if not session or not session.panel or not session.panel.commit_buf then
    error("missing commit panel")
  end
  local panel = session.panel
  local lines = vim.split(message or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  panel.message_lines = lines
  panel.message_initialized = false
  require("diffbandit.panel").render_commit(session)
  vim.api.nvim_set_current_win(panel.commit_win)
  vim.cmd("write")
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

vim.api.nvim_create_user_command("DBSelectFolderPath", function(opts)
  _G.DiffBanditTestSelectFolderPath(opts.args)
  vim.cmd("redraw!")
end, { nargs = 1 })

vim.api.nvim_create_user_command("DBWriteFolderState", function(opts)
  _G.DiffBanditTestWriteFolderState(opts.fargs[1])
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

vim.api.nvim_create_user_command("DBOpenQueuePath", function(opts)
  _G.DiffBanditTestOpenQueuePath(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("DBSelectPanelPath", function(opts)
  _G.DiffBanditTestSelectPanelPath(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("DBPanelAction", function(opts)
  _G.DiffBanditTestRunPanelAction(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1 })

vim.api.nvim_create_user_command("DBAcceptResolve", function(opts)
  _G.DiffBanditTestAcceptResolve(opts.fargs[1])
  vim.cmd("redraw!")
end, { nargs = 1 })

vim.api.nvim_create_user_command("DBPanelCommit", function(opts)
  _G.DiffBanditTestWritePanelCommit(opts.args)
  vim.cmd("redraw!")
end, { nargs = "*" })
