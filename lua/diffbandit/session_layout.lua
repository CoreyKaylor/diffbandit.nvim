-- Window and buffer geometry for a diff session: creates the tabpage, the
-- seven content panes (plus headers and panel when enabled), applies window
-- options, and keeps widths in sync on resize. Pure layout — rendering lives
-- in the session render pipeline.
local nvim = require("diffbandit.nvim")
local document = require("diffbandit.document")
local config_mod = require("diffbandit.config")
local layout = require("diffbandit.layout")

local set_buffer_options = nvim.set_buffer_options
local set_window_options = nvim.set_window_options
local set_window_width = nvim.set_window_width
local set_window_height = nvim.set_window_height

local M = {}

local function create_buffers(session)
  -- Create buffers with basic options first (avoid bufhidden=wipe until in windows)
  local left_buf = vim.api.nvim_create_buf(false, true)
  local left_overview_buf = session.overview_enabled and vim.api.nvim_create_buf(false, true) or nil
  local left_num_buf = vim.api.nvim_create_buf(false, true)
  local connector_buf = vim.api.nvim_create_buf(false, true)
  local right_num_buf = vim.api.nvim_create_buf(false, true)
  local right_overview_buf = session.overview_enabled and vim.api.nvim_create_buf(false, true) or nil
  local right_buf
  if session.right.editable then
    local acquired, acquire_err = document.acquire_buffer(session.right.editable)
    if acquired then
      right_buf = acquired
      document.refresh_source_from_editable(session.right)
    else
      nvim.notify_warn(tostring(acquire_err))
      session.right.editable = nil
      session.preserve_right_buffer_lines = false
    end
  end
  right_buf = right_buf or vim.api.nvim_create_buf(false, true)
  local left_header_buf = session.status_enabled and vim.api.nvim_create_buf(false, true) or nil
  local center_header_buf = session.status_enabled and vim.api.nvim_create_buf(false, true) or nil
  local right_header_buf = session.status_enabled and vim.api.nvim_create_buf(false, true) or nil
  local panel_nav_buf = session.panel_enabled and vim.api.nvim_create_buf(false, true) or nil
  local panel_commit_buf = session.panel_enabled and vim.api.nvim_create_buf(false, true) or nil
  if panel_commit_buf then
    pcall(vim.api.nvim_buf_set_name, panel_commit_buf, "diffbandit-commit-" .. tostring(session.id))
  end

  session.left_buf = left_buf
  session.left_overview_buf = left_overview_buf
  session.left_num_buf = left_num_buf
  session.connector_buf = connector_buf
  session.right_num_buf = right_num_buf
  session.right_overview_buf = right_overview_buf
  session.right_buf = right_buf
  session.left_header_buf = left_header_buf
  session.center_header_buf = center_header_buf
  session.right_header_buf = right_header_buf
  if session.panel_enabled then
    session.panel = {
      nav_buf = panel_nav_buf,
      commit_buf = panel_commit_buf,
      message_lines = session.panel_message_lines or { "" },
      amend = session.panel_amend == true,
      mode = session.panel_mode,
      details = session.panel_details,
      visible = false,
    }
  end

  -- Set non-destructive options first
  set_buffer_options(left_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
    filetype = session.left.filetype,
  })

  if session.right.editable then
    set_buffer_options(right_buf, {
      modifiable = true,
      filetype = session.right.filetype,
    })
  else
    set_buffer_options(right_buf, {
      buftype = "nofile",
      swapfile = false,
      modifiable = true,
      filetype = session.right.filetype,
    })
  end

  for _, buf in ipairs({
    left_overview_buf,
    right_overview_buf,
    left_num_buf,
    connector_buf,
    right_num_buf,
    left_header_buf,
    center_header_buf,
    right_header_buf,
  }) do
    if buf then
      set_buffer_options(buf, {
        buftype = "nofile",
        swapfile = false,
        modifiable = false,
      })
    end
  end

  if panel_nav_buf then
    set_buffer_options(panel_nav_buf, {
      buftype = "nofile",
      swapfile = false,
      modifiable = false,
    })
  end
  if panel_commit_buf then
    set_buffer_options(panel_commit_buf, {
      buftype = "acwrite",
      swapfile = false,
      modifiable = false,
    })
  end
end

local function open_windows(session)
  -- Put buffers in windows BEFORE setting bufhidden=wipe.
  -- Final order:
  -- LEFT OVERVIEW | LEFT CONTENT | LEFT NUMBERS | CONNECTOR | RIGHT NUMBERS | RIGHT CONTENT | RIGHT OVERVIEW.
  -- nvim_open_win() split configs let gutter panes opt out of mouse/focus where
  -- the running Nvim supports it.
  local left_win
  local left_overview_win
  local right_win
  local right_overview_win
  local left_header_win
  local center_header_win
  local right_header_win
  local panel_nav_win
  local panel_commit_win
  local left_num_win
  local connector_win
  local right_num_win

  local function open_gutter_win(buf, anchor_win, width)
    return layout.open_unfocusable_win(buf, anchor_win, { width = width })
  end

  local function open_sidecar_win(buf, anchor_win, split, width)
    return layout.open_unfocusable_win(buf, anchor_win, { split = split, width = width })
  end

  local function open_status_win(buf, anchor_win, split)
    return layout.open_unfocusable_win(buf, anchor_win, { split = split })
  end

  if session.panel_enabled then
    local panel_config = config_mod.section(session.config, "git", "panel")
    panel_nav_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(panel_nav_win, session.panel.nav_buf)
    set_window_width(panel_nav_win, panel_config.width or 42)
    if session.status_enabled then
      left_header_win = vim.api.nvim_open_win(session.left_header_buf, false, {
        split = "right",
        win = panel_nav_win,
      })
    else
      left_win = vim.api.nvim_open_win(session.left_buf, false, {
        split = "right",
        win = panel_nav_win,
      })
      left_overview_win = open_sidecar_win(session.left_overview_buf, left_win, "left", session.overview_width)
    end
    panel_commit_win = vim.api.nvim_open_win(session.panel.commit_buf, false, {
      split = "below",
      win = panel_nav_win,
      height = panel_config.commit_height or 10,
    })
  end

  if session.status_enabled then
    if not session.panel_enabled then
      left_header_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_header_win, session.left_header_buf)
    end
    left_win = vim.api.nvim_open_win(session.left_buf, false, {
      split = "below",
      win = left_header_win,
    })
    left_overview_win = open_sidecar_win(session.left_overview_buf, left_win, "left", session.overview_width)

    center_header_win = open_status_win(session.center_header_buf, left_header_win, "right")
    right_header_win = open_status_win(session.right_header_buf, center_header_win, "right")

    right_win = vim.api.nvim_open_win(session.right_buf, false, {
      split = "right",
      win = left_win,
    })
    left_num_win = open_gutter_win(session.left_num_buf, left_win, session.left_number_pane_width)
    connector_win = open_gutter_win(session.connector_buf, left_num_win, session.connector_core_width)
    right_num_win = open_gutter_win(session.right_num_buf, connector_win, session.right_number_pane_width)
    right_overview_win = open_sidecar_win(session.right_overview_buf, right_win, "right", session.overview_width)
  else
    if not session.panel_enabled then
      left_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_win, session.left_buf)
    end
    if not left_overview_win then
      left_overview_win = open_sidecar_win(session.left_overview_buf, left_win, "left", session.overview_width)
    end
    right_win = vim.api.nvim_open_win(session.right_buf, false, {
      split = "right",
      win = left_win,
    })
    vim.api.nvim_win_set_buf(right_win, session.right_buf)
    left_num_win = open_gutter_win(session.left_num_buf, left_win, session.left_number_pane_width)
    connector_win = open_gutter_win(session.connector_buf, left_num_win, session.connector_core_width)
    right_num_win = open_gutter_win(session.right_num_buf, connector_win, session.right_number_pane_width)
    right_overview_win = open_sidecar_win(session.right_overview_buf, right_win, "right", session.overview_width)
  end

  session.left_win = left_win
  session.left_overview_win = left_overview_win
  session.left_num_win = left_num_win
  session.connector_win = connector_win
  session.right_num_win = right_num_win
  session.right_overview_win = right_overview_win
  session.right_win = right_win
  session.left_header_win = left_header_win
  session.center_header_win = center_header_win
  session.right_header_win = right_header_win
  if session.panel_enabled then
    session.panel.nav_win = panel_nav_win
    session.panel.commit_win = panel_commit_win
  end
end

local function apply_window_options(session)
  local right_source_winhl = session.overview_enabled and layout.winhl.hidden_source or layout.winhl.source

  set_window_options(session.left_win, layout.win_opts.source())

  for _, win in ipairs({ session.left_overview_win, session.right_overview_win }) do
    if win then
      set_window_options(win, layout.win_opts.gutter(layout.winhl.overview))
      set_window_width(win, session.overview_width)
    end
  end

  for _, win in ipairs({ session.left_num_win, session.connector_win, session.right_num_win }) do
    set_window_options(win, layout.win_opts.gutter())
  end

  set_window_options(session.right_win, layout.win_opts.source(right_source_winhl, {
    signcolumn = session.right.editable and "auto" or "no",
  }))

  for _, win in ipairs({ session.left_header_win, session.center_header_win, session.right_header_win }) do
    if win then
      set_window_options(win, layout.win_opts.header())
      set_window_height(win, 1)
    end
  end

  if session.panel_enabled then
    local panel_config = config_mod.section(session.config, "git", "panel")
    for _, win in ipairs({ session.panel.nav_win, session.panel.commit_win }) do
      if win then
        set_window_options(win, layout.win_opts.panel())
        set_window_width(win, panel_config.width or 42)
      end
    end
    if session.panel.commit_win then
      set_window_height(session.panel.commit_win, panel_config.commit_height or 10)
    end
  end
end

-- Now that all buffers are displayed in windows, set bufhidden for cleanup:
-- wipe for session-owned scratch buffers, hide for panel and editable buffers
-- that outlive the layout.
local function finalize_bufhidden(session)
  for _, field in ipairs({
    "left_buf",
    "left_overview_buf",
    "right_overview_buf",
    "left_num_buf",
    "connector_buf",
    "right_num_buf",
    "left_header_buf",
    "center_header_buf",
    "right_header_buf",
  }) do
    local buf = session[field]
    if buf then
      set_buffer_options(buf, { bufhidden = "wipe" })
    end
  end
  set_buffer_options(session.right_buf, { bufhidden = session.right.editable and "hide" or "wipe" })
  if session.panel then
    for _, buf in ipairs({ session.panel.nav_buf, session.panel.commit_buf }) do
      if buf then
        set_buffer_options(buf, { bufhidden = "hide" })
      end
    end
  end
end

local function set_initial_focus(session)
  local navigation = session.config.navigation or {}
  local initial_focus = navigation.initial_focus == "left" and "left" or "right"
  local initial_win = initial_focus == "left" and session.left_win or session.right_win
  if session.panel_enabled and (config_mod.section(session.config, "git", "panel").focus_on_open or "panel") == "panel" then
    initial_win = session.panel.nav_win
  end
  document.ensure_syntax_features(session.left_buf, session.left.filetype)
  if session.right.editable then
    document.ensure_language_features(session.right_buf, session.right.filetype)
  else
    document.ensure_syntax_features(session.right_buf, session.right.filetype)
  end
  vim.api.nvim_set_current_win(initial_win)
  session.last_source_win = (session.panel and initial_win == session.panel.nav_win) and session.right_win or initial_win
  session.last_source_side = initial_focus

  local left_name = session.left.label or session.left.path or ""
  local right_name = session.right.label or session.right.path or ""
  session.title = string.format("DiffBandit: %s ↔ %s", left_name, right_name)
  vim.api.nvim_tabpage_set_var(session.tabpage, "diffbandit_title", session.title)
end

function M.open(session)
  vim.cmd("tabnew")
  session.tabpage = vim.api.nvim_get_current_tabpage()
  session.tabnr = vim.api.nvim_tabpage_get_number(session.tabpage)

  create_buffers(session)
  open_windows(session)
  apply_window_options(session)
  session:resize_layout()
  finalize_bufhidden(session)

  -- Set vertical split character to thin line
  vim.opt.fillchars:append({ vert = "│" })

  set_initial_focus(session)
end

function M.resize(session)
  if session.panel then
    local panel_config = config_mod.section(session.config, "git", "panel")
    if session.panel.nav_win and vim.api.nvim_win_is_valid(session.panel.nav_win) then
      set_window_width(session.panel.nav_win, panel_config.width or 42)
    end
    if session.panel.commit_win and vim.api.nvim_win_is_valid(session.panel.commit_win) then
      set_window_width(session.panel.commit_win, panel_config.width or 42)
      set_window_height(session.panel.commit_win, panel_config.commit_height or 10)
    end
  end

  local windows = {
    session.left_overview_win,
    session.left_win,
    session.left_num_win,
    session.connector_win,
    session.right_num_win,
    session.right_win,
    session.right_overview_win,
  }
  local valid_windows = {}
  for _, win in ipairs(windows) do
    if win then
      valid_windows[#valid_windows + 1] = win
    end
  end
  for _, win in ipairs(valid_windows) do
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
  end

  local function apply_fixed_widths()
    if session.left_overview_win then
      set_window_width(session.left_overview_win, session.overview_width)
    end
    set_window_width(session.left_num_win, session.left_number_pane_width)
    set_window_width(session.connector_win, session.connector_core_width)
    set_window_width(session.right_num_win, session.right_number_pane_width)
    if session.right_overview_win then
      set_window_width(session.right_overview_win, session.overview_width)
    end
  end

  apply_fixed_widths()

  local total_width = 0
  for _, win in ipairs(valid_windows) do
    total_width = total_width + vim.api.nvim_win_get_width(win)
  end
  local separator_width = #valid_windows - 1
  total_width = total_width + separator_width

  local overview_fixed_width = (session.overview_enabled and (session.overview_width * 2) or 0)
  local fixed_width = session.left_number_pane_width + session.connector_core_width
    + session.right_number_pane_width + overview_fixed_width
  local content_width = total_width - fixed_width - separator_width
  if content_width < 2 then
    return
  end

  local left_width = math.floor(content_width / 2)
  local right_width = content_width - left_width
  set_window_width(session.left_win, left_width)
  set_window_width(session.right_win, right_width)
  apply_fixed_widths()

  if session.status_enabled then
    local overview_header_extra = session.overview_enabled and (session.overview_width + 1) or 0
    local center_fixed_width = session.left_number_pane_width + session.connector_core_width + session.right_number_pane_width
    set_window_width(session.left_header_win, left_width + overview_header_extra)
    set_window_width(session.center_header_win, center_fixed_width + 2)
    set_window_width(session.right_header_win, right_width + overview_header_extra)
    set_window_height(session.left_header_win, 1)
    set_window_height(session.center_header_win, 1)
    set_window_height(session.right_header_win, 1)
    session:render_status_headers()
  end
end

return M
