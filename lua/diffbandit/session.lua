local diff_mod = require("diffbandit.diff")
local view_builder = require("diffbandit.view")
local state = require("diffbandit.state")
local paths_mod = require("diffbandit.connector_routes")
local actions = require("diffbandit.actions")
local status = require("diffbandit.status")
local panel_mod = require("diffbandit.panel")
local nvim = require("diffbandit.nvim")
local document = require("diffbandit.document")
local overview = require("diffbandit.overview")
local amend_mode = require("diffbandit.amend_mode")
local queue_host = require("diffbandit.queue_host")
local ui = require("diffbandit.ui")
local connector_width = require("diffbandit.connector_width")
local keymaps = require("diffbandit.keymaps")
local session_layout = require("diffbandit.session_layout")
local session_render = require("diffbandit.session_render")
local config_mod = require("diffbandit.config")

local Session = {}
Session.__index = Session

local function display_number_width(source)
  local width = ui.digits_of(#(source and source.lines or {}))
  local override = tonumber(source and source.display_number_width)
  if override and override > width then
    width = override
  end
  return width
end

local function is_git_queue(queue)
  return queue and queue.kind == "git"
end

local function git_action_markers_enabled(queue, index)
  if not is_git_queue(queue) then
    return false
  end
  local entry = queue.entries and queue.entries[index or queue.index or 1]
  return entry ~= nil and entry.actions_enabled ~= false
end

local set_win_view_topline = nvim.set_win_view_topline
local get_win_view_topline = nvim.get_win_view_topline

local set_buffer_options = nvim.set_buffer_options

local function build_view_for_sources(sources, config)
  local hunks, err = diff_mod.compute_hunks(sources.left.text, sources.right.text, config.diff)
  if err then
    return nil, err
  end

  local view = view_builder.build(sources.left.lines, sources.right.lines, hunks, config)
  return hunks, view
end

function Session:invalidate_render_caches()
  self.base_paths_cache = nil
  self.overview_marks_cache = nil
  self.changed_spans_cache = nil
  self.display_lines_cache = nil
end

function Session:base_paths()
  if not self.base_paths_cache then
    self.base_paths_cache = paths_mod.compute_paths(self.view.chunks, self.view.line_meta)
  end
  return self.base_paths_cache
end

function Session:display_lines()
  local padding = self:get_scroll_padding()
  if not self.display_lines_cache or self.display_lines_cache.padding ~= padding then
    local left_lines, right_lines = session_render.build_display_lines(self)
    self.display_lines_cache = {
      left = left_lines,
      right = right_lines,
      padding = padding,
    }
  end
  return self.display_lines_cache.left, self.display_lines_cache.right
end

function Session:overview_marks(side)
  self.overview_marks_cache = self.overview_marks_cache or {}
  local key = tostring(side) .. ":" .. tostring(self.current_chunk or 0)
  if not self.overview_marks_cache[key] then
    self.overview_marks_cache[key] = overview.build_marks(self.view, side, self.current_chunk)
  end
  return self.overview_marks_cache[key]
end

-- Width/marker fields shared by Session.start and replace_sources; both must
-- recompute these identically whenever sources or view change.
local function assign_pane_metrics(self, sources, view)
  self.left_number_width = math.max(2, display_number_width(sources.left))
  self.right_number_width = display_number_width(sources.right)
  self.stage_marker_width = git_action_markers_enabled(self.file_queue, self.file_queue_index) and 1 or 0
  self.left_stage_marker_width = 0
  self.right_stage_marker_width = self.stage_marker_width
  self.left_number_pane_width = self.left_number_width + 1 + self.left_stage_marker_width
  self.right_number_pane_width = self.right_number_width + 1 + self.right_stage_marker_width
  self.connector_core_width = connector_width.base(view, self.config)
  self.gutter_width = self.connector_core_width
end

function Session.start(sources, config, opts)
  opts = opts or {}
  local hunks, view = build_view_for_sources(sources, config)
  if not hunks then
    return nil, view
  end

  local self = setmetatable({}, Session)
  self.id = state.next_session_id()
  self.config = config
  self.left = sources.left
  self.right = sources.right
  self.hunks = hunks
  self.view = view
  self.current_chunk = opts.chunk_position == "top" and 0 or (view.chunks[1] and 1 or 0)
  self.file_queue = opts.queue
  self.file_queue_index = opts.queue and (opts.queue.index or 1) or nil
  self.pending_file_boundary = nil
  self.right_number_padding = self.config.ui.right_number_padding or 2
  self.ns = vim.api.nvim_create_namespace("DiffBanditHighlights" .. self.id)
  self.active_ns = vim.api.nvim_create_namespace("DiffBanditActive" .. self.id)
  self.path_ns = vim.api.nvim_create_namespace("DiffBanditConnectorPaths" .. self.id)
  self.overview_ns = vim.api.nvim_create_namespace("DiffBanditOverview" .. self.id)
  self.autocmd_group = nil
  self.disposed = false

  assign_pane_metrics(self, sources, view)
  self.overview_enabled = overview.enabled(self.config)
  self.overview_width = self.overview_enabled and overview.width(self.config) or 0
  self.connector_width_cache = {}
  self:invalidate_render_caches()
  self.staged_chunk_states = actions.staged_chunk_states(self)
  self.status_enabled = status.enabled(self.config)
  self.panel_enabled = opts.panel == true
  self.panel_mode = opts.panel_mode or "commit"
  self.panel_details = opts.panel_details
  self.panel_initial_selection = opts.panel_initial_selection
  self.panel_message_lines = opts.panel_message_lines
  self.panel_amend = opts.panel_amend == true
  self.normal_queue_opts = opts.panel_normal_queue_opts or (self.file_queue and self.file_queue.normal_opts)
  self.return_to = opts.return_to
  self.preserve_right_buffer_lines = self.right.editable ~= nil
  self.suppress_right_context_highlights = self.right.editable ~= nil

  self:open_layout()
  if self.panel_enabled then
    panel_mod.attach(self, {
      initial_selection = self.panel_initial_selection,
      no_initial_selection = not self.panel_initial_selection,
    })
  end
  self:precompute_connector_core_width()
  self:render()
  self:setup_autocmds()
  self:setup_keymaps()

  if self.current_chunk > 0 then
    vim.schedule(function()
      if not self.disposed then
        local chunk = self.view.chunks[self.current_chunk]
        if chunk then
          self:highlight_active_chunk(chunk)
        end
      end
    end)
  end

  return self
end

function Session:left_triangle_col()
  if self.mirror_connector_sides then
    return 0
  end
  return self.left_number_pane_width - 1
end

function Session:left_number_text_start_col()
  return self.mirror_connector_sides and 1 or 0
end

function Session:left_number_text_end_col()
  if self.mirror_connector_sides then
    return -1
  end
  return self:left_triangle_col()
end

function Session:right_triangle_col()
  if self.mirror_connector_sides then
    return self.right_number_pane_width - 1
  end
  return 0
end

function Session:right_number_text_start_col()
  return self.mirror_connector_sides and 0 or 1
end

function Session:right_number_text_end_col()
  if self.mirror_connector_sides then
    return self:right_triangle_col()
  end
  return -1
end

function Session:display_glyph(glyph)
  if not self.mirror_connector_sides then
    return glyph
  end
  local mirrored = {
    ["◤"] = "◥",
    ["◥"] = "◤",
    ["◢"] = "◣",
    ["◣"] = "◢",
  }
  return mirrored[glyph] or glyph
end

function Session:open_layout()
  session_layout.open(self)
end

function Session:resize_layout()
  session_layout.resize(self)
end

function Session:render_overviews()
  if not self.overview_enabled then
    return
  end
  if not (
        self.left_overview_buf
        and self.right_overview_buf
        and self.left_overview_win
        and self.right_overview_win
        and vim.api.nvim_buf_is_valid(self.left_overview_buf)
        and vim.api.nvim_buf_is_valid(self.right_overview_buf)
        and vim.api.nvim_win_is_valid(self.left_overview_win)
        and vim.api.nvim_win_is_valid(self.right_overview_win)
      ) then
    return
  end

  local left_height = math.max(1, vim.api.nvim_win_get_height(self.left_win))
  local right_height = math.max(1, vim.api.nvim_win_get_height(self.right_win))
  local left_cursor = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_cursor(self.left_win)[1] or 1
  local right_cursor = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_cursor(self.right_win)[1] or 1

  set_buffer_options(self.left_overview_buf, { modifiable = true })
  set_buffer_options(self.right_overview_buf, { modifiable = true })
  overview.render_side_with_marks(
    self.left_overview_buf,
    self.overview_ns,
    self:overview_marks("left"),
    #((self.view or {}).left or {}),
    left_height,
    left_cursor,
    self.current_chunk,
    self.config
  )
  overview.render_side_with_marks(
    self.right_overview_buf,
    self.overview_ns,
    self:overview_marks("right"),
    #((self.view or {}).right or {}),
    right_height,
    right_cursor,
    self.current_chunk,
    self.config
  )
  set_buffer_options(self.left_overview_buf, { modifiable = false })
  set_buffer_options(self.right_overview_buf, { modifiable = false })
end

function Session:get_scroll_padding()
  local height = 1
  local wins = { self.left_win, self.right_win, self.connector_win }
  for _, win in ipairs(wins) do
    if win and vim.api.nvim_win_is_valid(win) then
      height = math.max(height, vim.api.nvim_win_get_height(win))
    end
  end
  return math.max(0, height - 1)
end

function Session:setup_autocmds()
  local augroup = vim.api.nvim_create_augroup("DiffBanditSession" .. self.id, { clear = true })
  self.autocmd_group = augroup
  self.syncing_scroll = false  -- Flag to prevent infinite sync loops
  self.rendering_viewport = false

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function(event)
      if tonumber(event.file) == self.tabnr then
        self:dispose()
      end
    end,
  })

  -- Dispose the session when any of its buffers is wiped; the right buffer
  -- survives wipes triggered by replace_sources.
  for _, field in ipairs({
    "left_buf",
    "left_num_buf",
    "right_num_buf",
    "left_overview_buf",
    "right_overview_buf",
    "left_header_buf",
    "center_header_buf",
    "right_header_buf",
  }) do
    local buf = self[field]
    if buf then
      vim.api.nvim_create_autocmd("BufWipeout", {
        group = augroup,
        buffer = buf,
        callback = function()
          self:dispose()
        end,
      })
    end
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = self.right_buf,
    callback = function()
      if self.replacing_sources then
        return
      end
      self:dispose()
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      if self.disposed then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == self.left_win then
        self.last_source_win = self.left_win
        self.last_source_side = "left"
      elseif win == self.right_win then
        if self.right and self.right.editable then
          document.ensure_language_features(self.right_buf, self.right.filetype)
        end
        self.last_source_win = self.right_win
        self.last_source_side = "right"
      elseif win == self.left_num_win
          or win == self.left_overview_win
          or win == self.connector_win
          or win == self.right_num_win
          or win == self.right_overview_win
          or win == self.left_header_win
          or win == self.center_header_win
          or win == self.right_header_win then
        vim.schedule(function()
          if not self.disposed then
            local target
            if self.last_source_side == "left" then
              target = self.right_win
            elseif self.last_source_side == "right" then
              target = self.left_win
            else
              target = self.right_win
            end
            if target and vim.api.nvim_win_is_valid(target) then
              pcall(vim.api.nvim_set_current_win, target)
            end
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function(event)
      if self.syncing_scroll or self.rendering_viewport or self.disposed then
        return
      end
      local win = tonumber(event.winid)
      if win == self.left_header_win
          or win == self.center_header_win
          or win == self.right_header_win
          or win == self.left_overview_win
          or win == self.right_overview_win then
        return
      end
      self:sync_gutter_viewports()
      self:request_viewport_rerender()
    end,
  })

  -- Custom gutter synchronization: numbers follow their owner buffers.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = self.left_buf,
    callback = function()
      if self.syncing_scroll then
        return
      end
      self.last_source_win = self.left_win
      self.last_source_side = "left"
      self:sync_from_left()
      self:render_overviews()
    end,
  })

  -- Custom gutter synchronization: numbers follow their owner buffers.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = self.right_buf,
    callback = function()
      if self.syncing_scroll then
        return
      end
      self.last_source_win = self.right_win
      self.last_source_side = "right"
      self:sync_from_right()
      self:render_overviews()
    end,
  })

  if self.right and self.right.editable then
    vim.api.nvim_create_autocmd("BufEnter", {
      group = augroup,
      buffer = self.right_buf,
      callback = function()
        if self.disposed then
          return
        end
        document.ensure_language_features(self.right_buf, self.right.filetype)
      end,
    })
    vim.api.nvim_create_autocmd("TextChanged", {
      group = augroup,
      buffer = self.right_buf,
      callback = function()
        if self.disposed then
          return
        end
        self:request_editable_right_refresh()
      end,
    })
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = augroup,
      buffer = self.right_buf,
      callback = function()
        if self.disposed then
          return
        end
        document.refresh_source_from_editable(self.right)
      end,
    })
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = augroup,
      buffer = self.right_buf,
      callback = function()
        if self.disposed then
          return
        end
        self:request_editable_right_refresh()
      end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = augroup,
      buffer = self.right_buf,
      callback = function()
        if self.disposed then
          return
        end
        self:request_editable_right_refresh()
      end,
    })
  end
end

function Session:setup_keymaps()
  local opts = { nowait = true, noremap = true, silent = true }
  local function map(buf, lhs, rhs)
    self:set_buffer_keymap("n", buf, lhs, rhs, opts)
  end
  local function action_map(buf, lhs, command, fallback)
    if vim.fn.exists(":" .. command) == 2 then
      map(buf, lhs, "<Cmd>" .. command .. "<CR>")
    else
      map(buf, lhs, fallback)
    end
  end
  local navigation = self.config.navigation or {}
  local document_keys = navigation.document_keys or {}
  local git_keys = config_mod.section(self.config, "git", "file_keys")
  local panel_keys = config_mod.section(self.config, "git", "panel", "keys")
  local action_keys = ((self.config.actions or {}).keys or {})

  local function buffer_maps(buf)
    map(buf, "]c", function()
      self:goto_next_chunk()
    end)
    map(buf, "[c", function()
      self:goto_prev_chunk()
    end)
    map(buf, "q", function()
      self:close()
    end)
    if document_keys.top then
      map(buf, document_keys.top, function()
        self:goto_document_edge("top")
      end)
    end
    if document_keys.bottom then
      map(buf, document_keys.bottom, function()
        self:goto_document_edge("bottom")
      end)
    end
    if self.file_queue and git_keys.next then
      map(buf, git_keys.next, function()
        self:goto_next_file()
      end)
    end
    if self.file_queue and git_keys.prev then
      map(buf, git_keys.prev, function()
        self:goto_prev_file()
      end)
    end
    if action_keys.toggle_stage then
      action_map(buf, action_keys.toggle_stage, "DiffBanditToggleStageHunk", function()
        self:toggle_stage_hunk()
      end)
    end
    if action_keys.apply_left then
      action_map(buf, action_keys.apply_left, "DiffBanditApplyLeftHunk", function()
        self:apply_left_hunk()
      end)
    end
    if action_keys.apply_right then
      action_map(buf, action_keys.apply_right, "DiffBanditApplyRightHunk", function()
        self:apply_right_hunk()
      end)
    end
    if action_keys.undo then
      if buf == self.right_buf and self.right and self.right.editable then
        map(buf, action_keys.undo, function()
          self:undo_edit_or_action()
        end)
      else
        action_map(buf, action_keys.undo, "DiffBanditUndo", function()
          self:undo_action()
        end)
      end
    end
  end

  buffer_maps(self.left_buf)
  buffer_maps(self.left_num_buf)
  buffer_maps(self.connector_buf)
  buffer_maps(self.right_num_buf)
  buffer_maps(self.right_buf)
  if self.file_queue and panel_keys.focus_panel then
    map(self.left_buf, panel_keys.focus_panel, function()
      self:focus_commit_panel_for_current_file()
    end)
    map(self.right_buf, panel_keys.focus_panel, function()
      self:focus_commit_panel_for_current_file()
    end)
  end
  map(self.left_buf, "<C-w>l", function()
    if self.right_win and vim.api.nvim_win_is_valid(self.right_win) then
      vim.api.nvim_set_current_win(self.right_win)
    end
  end)
  map(self.right_buf, "<C-w>h", function()
    if self.left_win and vim.api.nvim_win_is_valid(self.left_win) then
      vim.api.nvim_set_current_win(self.left_win)
    end
  end)
end

function Session:set_buffer_keymap(mode, buf, lhs, rhs, opts)
  keymaps.set(self, mode, buf, lhs, rhs, opts)
end

function Session:clear_keymaps()
  keymaps.clear(self)
end

local function sync_source_to_gutter(self, source_win, number_win)
  if self.disposed or not vim.api.nvim_win_is_valid(source_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(source_win)
  local source_line = cursor[1]

  self.syncing_scroll = true
  if number_win and vim.api.nvim_win_is_valid(number_win) then
    pcall(vim.api.nvim_win_set_cursor, number_win, { source_line, 0 })
    set_win_view_topline(number_win, get_win_view_topline(source_win))
  end
  if self.connector_win and vim.api.nvim_win_is_valid(self.connector_win) then
    set_win_view_topline(self.connector_win, get_win_view_topline(self.left_win))
  end
  self.syncing_scroll = false
end

function Session:sync_gutter_viewports()
  self.syncing_scroll = true
  set_win_view_topline(self.left_num_win, get_win_view_topline(self.left_win))
  set_win_view_topline(self.right_num_win, get_win_view_topline(self.right_win))
  set_win_view_topline(self.connector_win, get_win_view_topline(self.left_win))
  self.syncing_scroll = false
end

function Session:sync_from_left()
  sync_source_to_gutter(self, self.left_win, self.left_num_win)
end

function Session:sync_from_right()
  sync_source_to_gutter(self, self.right_win, self.right_num_win)
end

-- Debounce a per-session action behind a boolean flag field: the first call
-- schedules, later calls coalesce until the deferred fn clears the flag.
local function schedule_once(self, flag_field, fn)
  if self[flag_field] then
    return
  end
  self[flag_field] = true
  local delay = tonumber(config_mod.section(self.config, "ui").scroll_debounce_ms) or 16
  vim.defer_fn(function()
    self[flag_field] = false
    if self.disposed then
      return
    end
    fn()
  end, math.max(0, delay))
end

function Session:request_viewport_rerender()
  if self.disposed or self.rendering_viewport then
    return
  end
  schedule_once(self, "viewport_rerender_scheduled", function()
    self:rerender_for_viewport()
  end)
end

function Session:request_editable_right_refresh()
  if self.disposed or not (self.right and self.right.editable) then
    return
  end
  schedule_once(self, "editable_right_refresh_scheduled", function()
    if not (self.right and self.right.editable) then
      return
    end
    document.refresh_source_from_editable(self.right)
    self:replace_sources({
      left = self.left,
      right = self.right,
    }, {
      preserve_view = true,
      chunk_position = "preserve",
      preferred_chunk = self.current_chunk,
    })
  end)
end

local function apply_viewport_toplines(self, left_topline, right_topline)
  set_win_view_topline(self.left_win, left_topline)
  set_win_view_topline(self.left_num_win, left_topline)
  set_win_view_topline(self.right_win, right_topline)
  set_win_view_topline(self.right_num_win, right_topline)
  set_win_view_topline(self.connector_win, left_topline or 1)
end

function Session:set_viewport_toplines(left_topline, right_topline)
  apply_viewport_toplines(self, left_topline, right_topline)
  self:rerender_for_viewport()
end

function Session:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_cursor, right_cursor)
  apply_viewport_toplines(self, left_topline, right_topline)
  local function cursor_pair(cursor)
    if type(cursor) == "table" then
      return { math.max(1, cursor[1] or 1), math.max(0, cursor[2] or 0) }
    end
    if cursor then
      return { math.max(1, cursor), 0 }
    end
    return nil
  end
  local left_pair = cursor_pair(left_cursor)
  local right_pair = cursor_pair(right_cursor)
  if left_pair then
    pcall(vim.api.nvim_win_set_cursor, self.left_win, left_pair)
    pcall(vim.api.nvim_win_set_cursor, self.left_num_win, { left_pair[1], 0 })
  end
  if right_pair then
    pcall(vim.api.nvim_win_set_cursor, self.right_win, right_pair)
    pcall(vim.api.nvim_win_set_cursor, self.right_num_win, { right_pair[1], 0 })
  end
  self:rerender_for_viewport()
end

local function first_meta_index_with(meta_list, start_idx, end_idx, predicate)
  for idx = start_idx, end_idx do
    local meta = meta_list[idx]
    if meta and predicate(meta) then
      return idx, meta
    end
  end
  return nil, nil
end

-- Shared scanner for chunk anchors (viewport alignment) and cursor rows
-- (cursor placement). The two differ only in how an add chunk picks its right
-- row (origin row vs first real right line) and whether missing origin rows
-- fall back to row 1.
local function chunk_rows(self, chunk, opts)
  local meta_list = self.view and self.view.line_meta or {}
  local start_idx = chunk and chunk.display_start or 1
  local end_idx = chunk and chunk.display_end or start_idx

  local function first_left()
    local _, meta = first_meta_index_with(meta_list, start_idx, end_idx, function(m)
      return m.left_index ~= nil
    end)
    return meta and meta.left_index or nil
  end
  local function first_right()
    local _, meta = first_meta_index_with(meta_list, start_idx, end_idx, function(m)
      return m.right_index ~= nil
    end)
    return meta and meta.right_index or nil
  end

  local left_row
  local right_row
  if chunk and chunk.type == "add" then
    local origin_meta = meta_list[start_idx - 1]
    left_row = origin_meta and origin_meta.left_index or opts.origin_fallback
    if opts.add_right_from_origin then
      right_row = origin_meta and origin_meta.right_index or opts.origin_fallback
    else
      right_row = first_right()
    end
  elseif chunk and chunk.type == "delete" then
    left_row = first_left()
    local origin_meta = meta_list[start_idx - 1]
    right_row = origin_meta and origin_meta.right_index or opts.origin_fallback
  else
    left_row = first_left()
    right_row = first_right()
  end

  return left_row or first_left(), right_row or first_right()
end

function Session:chunk_navigation_anchors(chunk)
  return chunk_rows(self, chunk, { origin_fallback = 1, add_right_from_origin = true })
end

function Session:chunk_cursor_rows(chunk)
  return chunk_rows(self, chunk, { add_right_from_origin = false })
end

function Session:align_chunk_viewports(chunk)
  local navigation = self.config.navigation or {}
  if navigation.align_on_jump == false then
    self:sync_gutter_viewports()
    return
  end

  local focused_win = vim.api.nvim_get_current_win()
  local left_anchor, right_anchor = self:chunk_navigation_anchors(chunk)
  if not left_anchor or not right_anchor then
    self:sync_gutter_viewports()
    return
  end

  local context = math.max(0, tonumber(navigation.jump_context) or 0)
  local left_topline = math.max(1, left_anchor - context)
  local right_topline = math.max(1, right_anchor - context)
  local left_cursor, right_cursor = self:chunk_cursor_rows(chunk)
  left_cursor = left_cursor or left_topline
  right_cursor = right_cursor or right_topline

  self:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_cursor, right_cursor)

  if focused_win == self.left_win or focused_win == self.right_win then
    pcall(vim.api.nvim_set_current_win, focused_win)
  elseif self.last_source_win and vim.api.nvim_win_is_valid(self.last_source_win) then
    pcall(vim.api.nvim_set_current_win, self.last_source_win)
  end
end

function Session:goto_document_edge(edge)
  self:reset_pending_file_boundary()
  local focused_win = vim.api.nvim_get_current_win()
  local left_line_count = math.max(1, #self.view.left)
  local right_line_count = math.max(1, #self.view.right)
  local left_line = edge == "bottom" and left_line_count or 1
  local right_line = edge == "bottom" and right_line_count or 1
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
  local left_topline = edge == "bottom" and math.max(1, left_line_count - left_height + 1) or 1
  local right_topline = edge == "bottom" and math.max(1, right_line_count - right_height + 1) or 1

  self.syncing_scroll = true
  pcall(vim.api.nvim_win_set_cursor, self.left_win, { left_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.left_num_win, { left_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.right_win, { right_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.right_num_win, { right_line, 0 })
  self.syncing_scroll = false

  if edge == "bottom" then
    self.current_chunk = #self.view.chunks + 1
  else
    self.current_chunk = 0
  end
  self:clear_active_chunk()
  self:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_line, right_line)

  if focused_win == self.left_win or focused_win == self.right_win then
    pcall(vim.api.nvim_set_current_win, focused_win)
  elseif self.last_source_win and vim.api.nvim_win_is_valid(self.last_source_win) then
    pcall(vim.api.nvim_set_current_win, self.last_source_win)
  end
end

function Session:rerender_for_viewport()
  if self.disposed or self.rendering_viewport then
    return
  end

  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_cursor = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_cursor(self.left_win) or nil
  local right_cursor = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_cursor(self.right_win) or nil
  self.rendering_viewport = true
  self:render()
  set_win_view_topline(self.left_win, left_topline)
  set_win_view_topline(self.left_num_win, left_topline)
  set_win_view_topline(self.connector_win, left_topline)
  set_win_view_topline(self.right_win, right_topline)
  set_win_view_topline(self.right_num_win, right_topline)
  if left_cursor and vim.api.nvim_win_is_valid(self.left_win) then
    pcall(vim.api.nvim_win_set_cursor, self.left_win, left_cursor)
  end
  if right_cursor and vim.api.nvim_win_is_valid(self.right_win) then
    pcall(vim.api.nvim_win_set_cursor, self.right_win, right_cursor)
  end
  self.rendering_viewport = false
end

function Session:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:clear_keymaps()
  document.cleanup_created_buffer(self.right and self.right.editable)
  state.unregister(self.tabpage)
  if self.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
    self.autocmd_group = nil
  end
end

function Session:close()
  if self.disposed then
    return
  end
  local return_to = self.return_to
  if return_to then
    local parent_session = return_to.session
    local parent_tab = return_to.tabpage
    if self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
      pcall(vim.api.nvim_set_current_tabpage, self.tabpage)
      pcall(vim.cmd, "tabclose")
    else
      self:dispose()
    end
    if parent_session and not parent_session.disposed
        and parent_tab and vim.api.nvim_tabpage_is_valid(parent_tab) then
      pcall(vim.api.nvim_set_current_tabpage, parent_tab)
      if type(parent_session.restore_from_child) == "function" then
        parent_session:restore_from_child(return_to.context or {})
      end
    end
    return
  end
  if vim.api.nvim_tabpage_is_valid(self.tabpage) then
    local current = vim.api.nvim_get_current_tabpage()
    pcall(vim.api.nvim_set_current_tabpage, self.tabpage)
    pcall(vim.cmd, "tabclose")
    if vim.api.nvim_tabpage_is_valid(current) then
      pcall(vim.api.nvim_set_current_tabpage, current)
    end
  else
    self:dispose()
  end
end

function Session:reset_pending_file_boundary()
  self.pending_file_boundary = nil
end

function Session:update_title()
  if not (self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage)) then
    return
  end
  local left_name = self.left.label or self.left.path or ""
  local right_name = self.right.label or self.right.path or ""
  self.title = string.format("DiffBandit: %s ↔ %s", left_name, right_name)
  vim.api.nvim_tabpage_set_var(self.tabpage, "diffbandit_title", self.title)
end

function Session:render_status_headers()
  if not self.status_enabled then
    return
  end
  if not (
        self.left_header_win
        and self.center_header_win
        and self.right_header_win
        and vim.api.nvim_win_is_valid(self.left_header_win)
        and vim.api.nvim_win_is_valid(self.center_header_win)
        and vim.api.nvim_win_is_valid(self.right_header_win)
      ) then
    return
  end

  local lines = status.build(self)
  local center_width = vim.api.nvim_win_get_width(self.center_header_win)
  if lines.center_compact and vim.fn.strdisplaywidth(lines.center) > math.max(1, center_width - 1) then
    lines.center = lines.center_compact
  end
  self.status_lines = lines
  ui.set_header_line(self.left_header_buf, self.ns, self.status_lines.left, vim.api.nvim_win_get_width(self.left_header_win))
  ui.set_header_line(self.center_header_buf, self.ns, self.status_lines.center, center_width)
  ui.set_header_line(self.right_header_buf, self.ns, self.status_lines.right, vim.api.nvim_win_get_width(self.right_header_win))
end

function Session:replace_sources(sources, opts)
  opts = opts or {}
  self:clear_keymaps()
  if sources and sources.right and sources.right.editable then
    local acquired, acquire_err = document.acquire_buffer(sources.right.editable)
    if acquired then
      document.refresh_source_from_editable(sources.right)
    else
      nvim.notify_warn(tostring(acquire_err))
      sources.right.editable = nil
    end
  end
  local preserve_view = opts.preserve_view == true
  local preserved_left_topline = preserve_view and get_win_view_topline(self.left_win) or nil
  local preserved_right_topline = preserve_view and get_win_view_topline(self.right_win) or nil
  local preserved_left_cursor = { 1, 0 }
  local preserved_right_cursor = { 1, 0 }
  if preserve_view then
    local ok_left, left_cursor = pcall(vim.api.nvim_win_get_cursor, self.left_win)
    local ok_right, right_cursor = pcall(vim.api.nvim_win_get_cursor, self.right_win)
    preserved_left_cursor = ok_left and left_cursor or { preserved_left_topline or 1, 0 }
    preserved_right_cursor = ok_right and right_cursor or { preserved_right_topline or 1, 0 }
  end

  local hunks, view = build_view_for_sources(sources, self.config)
  if not hunks then
    return nil, view
  end

  local old_right_editable = self.right and self.right.editable
  local old_right_buf = self.right_buf
  local previous_replacing_sources = self.replacing_sources
  self.replacing_sources = true
  self.left = sources.left
  self.right = sources.right
  self.preserve_right_buffer_lines = self.right.editable ~= nil
  self.suppress_right_context_highlights = self.right.editable ~= nil
  if self.right.editable and self.right.editable.bufnr and self.right.editable.bufnr ~= self.right_buf then
    self.right_buf = self.right.editable.bufnr
    if self.right_win and vim.api.nvim_win_is_valid(self.right_win) then
      vim.api.nvim_win_set_buf(self.right_win, self.right_buf)
    end
  elseif not self.right.editable and old_right_editable then
    self.right_buf = vim.api.nvim_create_buf(false, true)
    set_buffer_options(self.right_buf, {
      buftype = "nofile",
      swapfile = false,
      modifiable = true,
      filetype = self.right.filetype,
    })
    if self.right_win and vim.api.nvim_win_is_valid(self.right_win) then
      vim.api.nvim_win_set_buf(self.right_win, self.right_buf)
    end
    set_buffer_options(self.right_buf, { bufhidden = "wipe" })
  end
  if old_right_buf ~= self.right_buf then
    document.cleanup_created_buffer(old_right_editable)
  end
  self.replacing_sources = previous_replacing_sources
  self.hunks = hunks
  self.view = view
  self:invalidate_render_caches()
  self.current_chunk = opts.chunk_position == "top" and 0 or (view.chunks[1] and 1 or 0)
  assign_pane_metrics(self, sources, view)
  self:reset_pending_file_boundary()
  self.staged_chunk_states = actions.staged_chunk_states(self)

  set_buffer_options(self.left_buf, { filetype = self.left.filetype })
  set_buffer_options(self.right_buf, { filetype = self.right.filetype, modifiable = true })
  document.ensure_syntax_features(self.left_buf, self.left.filetype)
  if self.right.editable then
    document.ensure_language_features(self.right_buf, self.right.filetype)
  else
    document.ensure_syntax_features(self.right_buf, self.right.filetype)
  end
  self:update_title()
  self:resize_layout()
  self:precompute_connector_core_width()
  self:render()
  if self.id then
    self:setup_autocmds()
  end
  self:setup_keymaps()

  if preserve_view then
    local left_cursor = {
      math.max(1, math.min(preserved_left_cursor[1] or 1, math.max(1, #self.left.lines))),
      math.max(0, preserved_left_cursor[2] or 0),
    }
    local right_cursor = {
      math.max(1, math.min(preserved_right_cursor[1] or 1, math.max(1, #self.right.lines))),
      math.max(0, preserved_right_cursor[2] or 0),
    }
    pcall(vim.api.nvim_win_set_cursor, self.left_win, left_cursor)
    pcall(vim.api.nvim_win_set_cursor, self.left_num_win, { left_cursor[1], 0 })
    pcall(vim.api.nvim_win_set_cursor, self.right_win, right_cursor)
    pcall(vim.api.nvim_win_set_cursor, self.right_num_win, { right_cursor[1], 0 })
    self:set_viewport_toplines_preserve_cursors(
      preserved_left_topline or 1,
      preserved_right_topline or 1,
      left_cursor,
      right_cursor
    )
  else
    pcall(vim.api.nvim_win_set_cursor, self.left_win, { 1, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.left_num_win, { 1, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.right_win, { 1, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.right_num_win, { 1, 0 })
    self:set_viewport_toplines_preserve_cursors(1, 1, 1, 1)
  end

  if opts.chunk_position == "top" then
    self.current_chunk = 0
    self:clear_active_chunk()
    self:render_status_headers()
  elseif opts.chunk_position == "preserve" then
    if #self.view.chunks > 0 then
      self.current_chunk = math.max(1, math.min(opts.preferred_chunk or self.current_chunk or 1, #self.view.chunks))
      self:highlight_active_chunk(self.view.chunks[self.current_chunk], { position_cursor = false })
    else
      self:clear_active_chunk()
    end
  elseif opts.chunk_position == "nearest" and opts.preferred_chunk and #self.view.chunks > 0 then
    self:goto_chunk(math.min(opts.preferred_chunk, #self.view.chunks))
  elseif opts.chunk_position == "last" and #self.view.chunks > 0 then
    self:goto_chunk(#self.view.chunks)
  elseif #self.view.chunks > 0 then
    self:goto_chunk(1)
  else
    self:clear_active_chunk()
  end

  return true, nil
end

function Session:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
  return paths_mod.project_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function Session:project_paths_for_viewport(paths)
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
  return self:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

local function sorted_keys(set)
  local keys = {}
  for key, _ in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

function Session:precompute_connector_core_width()
  local minimum_width = connector_width.base(self.view, self.config)
  local pressure_events = {}
  local function add_pressure_range(start_row, end_row)
    if not start_row or not end_row then
      return
    end
    start_row = math.floor(start_row)
    end_row = math.floor(end_row)
    if end_row < start_row then
      start_row, end_row = end_row, start_row
    end
    pressure_events[start_row] = (pressure_events[start_row] or 0) + 1
    pressure_events[end_row + 1] = (pressure_events[end_row + 1] or 0) - 1
  end

  for _, path in ipairs(self:base_paths()) do
    if path.kind == "add" or path.kind == "delete" then
      if not path.embedded_in_change then
        add_pressure_range(path.origin_display_row, path.triangle_display_row or path.display_start_row)
      end
    elseif path.kind == "change" and path.offset then
      local start_row = math.min(path.start_left_index or path.display_start_row or 0,
        path.start_right_index or path.display_start_row or 0)
      local end_row = math.max(path.end_left_index or path.display_end_row or start_row,
        path.end_right_index or path.display_end_row or start_row)
      add_pressure_range(start_row, end_row)
    end
  end

  local rows = sorted_keys(pressure_events)
  local active = 0
  local max_pressure = 0
  for _, row in ipairs(rows) do
    active = active + pressure_events[row]
    max_pressure = math.max(max_pressure, active)
  end
  -- Document-space pressure cannot see overlaps created by scrolling the
  -- panes independently (a route whose origin scrolls off-screen stretches
  -- its rail across rows it never touches in the aligned view). Reserve one
  -- extra lane of slack whenever the document has any routed content so
  -- those transient overlaps still plan without hiding routes.
  if max_pressure > 0 then
    max_pressure = max_pressure + 1
  end
  local required_core = math.max(minimum_width, minimum_width + (max_pressure * 2))
  required_core = math.min(connector_width.maximum(self.config), required_core)
  if required_core ~= self.connector_core_width then
    self.connector_core_width = required_core
    self.gutter_width = required_core
    self:resize_layout()
  end

  return required_core
end

function Session:render()
  session_render.render(self)
end

function Session:clear_active_chunk()
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.active_ns, 0, -1)
end

function Session:highlight_active_chunk(chunk, opts)
  opts = opts or {}
  self:clear_active_chunk()

  local active_hl = "DiffBanditActiveChunk"
  local add_hl = vim.api.nvim_buf_add_highlight

  -- Highlight using buffer-specific indices from metadata
  for meta_idx = chunk.display_start, chunk.display_end do
    local meta = self.view.line_meta[meta_idx]
    if meta then
      -- Skip for diff lines with strong backgrounds to avoid washing out colors
      local has_strong_bg = meta.kind ~= "context" and not meta.filler_left and not meta.filler_right

      -- Highlight left buffer if this metadata has a left line
      if meta.left_index and not has_strong_bg then
        local row = meta.left_index - 1
        add_hl(self.left_buf, self.active_ns, active_hl, row, 0, -1)
        add_hl(self.left_num_buf, self.active_ns, active_hl, row, 0, -1)
      end

      -- Highlight right buffer if this metadata has a right line
      if meta.right_index and not has_strong_bg then
        local row = meta.right_index - 1
        add_hl(self.right_buf, self.active_ns, active_hl, row, 0, -1)
        add_hl(self.right_num_buf, self.active_ns, active_hl, row, 0, -1)
      end

      if not has_strong_bg then
        add_hl(self.connector_buf, self.active_ns, active_hl, meta_idx - 1, 0, -1)
      end
    end
  end

  if opts.position_cursor ~= false then
    -- Position source cursors on real hunk content where possible, while
    -- keeping the opposite side on the contextual origin for pure add/delete hunks.
    local left_cursor, right_cursor = self:chunk_cursor_rows(chunk)
    if left_cursor then
      vim.api.nvim_win_set_cursor(self.left_win, { left_cursor, 0 })
    end
    if right_cursor then
      vim.api.nvim_win_set_cursor(self.right_win, { right_cursor, 0 })
    end
    vim.api.nvim_win_set_cursor(self.connector_win, { chunk.display_start, 0 })
  end
  self:sync_gutter_viewports()
  self:render_status_headers()
  self:render_overviews()
end

function Session:goto_chunk(index)
  if #self.view.chunks == 0 then
    return
  end
  self:reset_pending_file_boundary()
  if index < 1 then
    index = 1
  elseif index > #self.view.chunks then
    index = #self.view.chunks
  end
  self.current_chunk = index
  local chunk = self.view.chunks[self.current_chunk]
  self:highlight_active_chunk(chunk)
  self:align_chunk_viewports(chunk)
end

function Session:load_queue_sources(index, step)
  return queue_host.load_sources(self, index, step)
end

function Session:prefetch_queue_neighbors(index)
  queue_host.prefetch_neighbors(self, index)
end

function Session:goto_queue_file(index, chunk_position, opts)
  opts = opts or {}
  local current = self.file_queue_index or 1
  local step = index >= current and 1 or -1
  local sources, resolved_index, err = self:load_queue_sources(index, step)
  if not sources then
    nvim.notify_info(err)
    self:reset_pending_file_boundary()
    return false
  end

  queue_host.set_index(self, resolved_index)
  local focused_win = opts.preserve_focus and vim.api.nvim_get_current_win() or nil
  local ok, replace_err = self:replace_sources(sources, { chunk_position = chunk_position })
  if not ok then
    nvim.notify_error(replace_err)
    return false
  end
  if self.panel and not opts.skip_panel_render then
    panel_mod.render(self, resolved_index)
  end
  self:prefetch_queue_neighbors(resolved_index)
  if focused_win and vim.api.nvim_win_is_valid(focused_win) then
    pcall(vim.api.nvim_set_current_win, focused_win)
  end
  return true
end

function Session:open_merge_file(index, opts)
  opts = opts or {}
  local queue = self.file_queue
  local entry = queue and queue.entries and queue.entries[index]
  if not entry then
    return false
  end
  local Merge = require("diffbandit.merge")
  local data, err = Merge.load(queue.root, entry.path, self.config)
  if not data then
    nvim.notify_error(tostring(err))
    return false
  end
  queue.index = index
  self.file_queue_index = index
  local panel_message_lines = self.panel and panel_mod.capture_message_lines(self) or nil
  local session, start_err = Merge.start(data, self.config, {
    queue = queue,
    queue_index = index,
    panel = self.panel and self.panel.visible == true,
    panel_initial_selection = index,
    panel_message_lines = panel_message_lines,
    panel_amend = self.panel and self.panel.amend == true,
  })
  if not session then
    nvim.notify_error(tostring(start_err))
    return false
  end
  if opts.navigate_change == "prev" then
    session:goto_prev_conflict()
  elseif opts.navigate_change == "next" then
    session:goto_next_conflict()
  end
  if opts.preserve_focus
      and session.panel
      and session.panel.nav_win
      and vim.api.nvim_win_is_valid(session.panel.nav_win) then
    pcall(vim.api.nvim_set_current_win, session.panel.nav_win)
  end
  return true
end

function Session:goto_next_file()
  if not self.file_queue then
    nvim.notify_info("no changed file queue configured")
    return
  end
  self:reset_pending_file_boundary()
  self:goto_queue_file((self.file_queue_index or 1) + 1, "top")
end

function Session:goto_prev_file()
  if not self.file_queue then
    nvim.notify_info("no changed file queue configured")
    return
  end
  self:reset_pending_file_boundary()
  self:goto_queue_file((self.file_queue_index or 1) - 1, "top")
end

local function empty_git_source(label)
  return {
    path = nil,
    label = label,
    lines = {},
    text = "",
    filetype = nil,
    empty_reason = label,
  }
end

function Session:refresh_git_queue(preferred_path, refresh_opts)
  refresh_opts = refresh_opts or {}
  return panel_mod.refresh_git_queue(self, {
    preferred_path = preferred_path,
    default_index = refresh_opts.default_index or 1,
    fallback_index = refresh_opts.fallback_index,
    empty_index = 1,
    on_no_changes = function(session)
      session:replace_sources({
        left = empty_git_source("No Git changes"),
        right = empty_git_source("No Git changes"),
      }, { chunk_position = "top" })
      if session.panel then
        panel_mod.render(session, nil, { refresh_stage_states = true, no_initial_selection = true })
      end
    end,
    on_queue = function(session, _, target_index)
      session:goto_queue_file(target_index, "top", {
        preserve_focus = session.panel and session.panel.visible,
        skip_panel_render = true,
      })
      if session.panel then
        panel_mod.render(session, refresh_opts.preserve_panel_selection or target_index, { refresh_stage_states = true })
      end
    end,
  })
end

function Session:set_amend_mode(enabled)
  return amend_mode.set_amend_mode(self, enabled)
end

function Session:clear_amend_mode()
  amend_mode.clear_amend_mode(self)
end

function Session:ensure_panel_buffers()
  if self.panel and self.panel.nav_buf and vim.api.nvim_buf_is_valid(self.panel.nav_buf) then
    return
  end
  local nav_buf = vim.api.nvim_create_buf(false, true)
  local commit_buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, commit_buf, "diffbandit-commit-" .. tostring(self.id))
  set_buffer_options(nav_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
    bufhidden = "hide",
  })
  set_buffer_options(commit_buf, {
    buftype = "acwrite",
    swapfile = false,
    modifiable = false,
    bufhidden = "hide",
  })
  self.panel = self.panel or {}
  self.panel.nav_buf = nav_buf
  self.panel.commit_buf = commit_buf
  self.panel.message_lines = self.panel.message_lines or { "" }
  self.panel.amend = self.panel.amend or false
  self.panel.mode = self.panel.mode or self.panel_mode or "commit"
  self.panel.details = self.panel.details or self.panel_details
end

function Session:show_commit_panel(opts)
  opts = opts or {}
  if not self.file_queue or self.file_queue.kind ~= "git" then
    nvim.notify_info("commit panel is only available for Git diff sessions")
    return false
  end
  self:ensure_panel_buffers()
  if panel_mod.is_open(self) then
    panel_mod.focus_nav(self)
    return true
  end

  local anchor = self.left_win
    or self.right_win
    or self.left_header_win
    or vim.api.nvim_get_current_win()
  if not (anchor and vim.api.nvim_win_is_valid(anchor)) then
    return false
  end

  panel_mod.open_windows(self, anchor)
  if opts.select_current_file then
    panel_mod.attach(self, {
      initial_selection = self.file_queue_index or self.file_queue.index or 1,
      no_initial_selection = false,
    })
  else
    panel_mod.attach(self)
  end
  self:resize_layout()
  panel_mod.focus_nav(self)
  return true
end

function Session:focus_commit_panel_for_current_file()
  if not self.file_queue or self.file_queue.kind ~= "git" then
    nvim.notify_info("commit panel is only available for Git diff sessions")
    return false
  end
  local index = self.file_queue_index or self.file_queue.index or 1
  if self.panel
      and self.panel.visible
      and self.panel.nav_win
      and vim.api.nvim_win_is_valid(self.panel.nav_win) then
    panel_mod.render(self, index)
    panel_mod.focus_nav(self)
    return true
  end
  return self:show_commit_panel({ select_current_file = true })
end

function Session:hide_commit_panel()
  if not self.panel then
    return false
  end
  panel_mod.close(self)
  self:resize_layout()
  return true
end

function Session:toggle_commit_panel()
  if self.panel
      and self.panel.visible
      and self.panel.nav_win
      and vim.api.nvim_win_is_valid(self.panel.nav_win) then
    return self:hide_commit_panel()
  end
  return self:show_commit_panel()
end

function Session:confirm_file_boundary(direction)
  local queue = self.file_queue
  if not queue then
    return false
  end

  local current = self.file_queue_index or 1
  local step = direction == "next" and 1 or -1
  local target = current + step
  local count = #(queue.entries or {})
  if target < 1 or target > count then
    self:reset_pending_file_boundary()
    local label = direction == "next" and "last" or "first"
    nvim.notify_info("already at " .. label .. " changed file")
    return true
  end

  local pending = self.pending_file_boundary
  if pending and pending.direction == direction and pending.file_index == current then
    self:reset_pending_file_boundary()
    self:goto_queue_file(target, "top")
    return true
  end

  self.pending_file_boundary = {
    direction = direction,
    file_index = current,
  }

  if direction == "next" then
    nvim.notify_info("end of this file; press ]c again for next changed file")
  else
    nvim.notify_info("start of this file; press [c again for previous changed file")
  end
  return true
end

function Session:prompt_next_file()
  local navigation = self.config.navigation or {}
  local prompt = navigation.prompt_message or "Open next diff file?"

  vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
    if choice == "Yes" then
      if type(navigation.on_request_next_file) == "function" then
        local ok, err = pcall(navigation.on_request_next_file, self)
        if not ok then
          nvim.notify_error(err)
        end
      else
        nvim.notify_info("no next file handler configured")
      end
    end
  end)
end

function Session:goto_next_chunk()
  if #self.view.chunks == 0 then
    return
  end
  if self.current_chunk >= #self.view.chunks then
    if self:confirm_file_boundary("next") then
      return
    end
    self:prompt_next_file()
    return
  end
  self:goto_chunk(self.current_chunk + 1)
end

function Session:goto_prev_chunk()
  if #self.view.chunks == 0 then
    return
  end
  if self.current_chunk <= 1 then
    if self:confirm_file_boundary("prev") then
      return
    end
    nvim.notify_info("already at first change")
    return
  end
  self:goto_chunk(self.current_chunk - 1)
end

local function notify_action_result(ok, err)
  if not ok and err then
    nvim.notify_info(err)
  end
  return ok, err
end

function Session:after_git_action(ok)
  if ok and self.panel and self.file_queue then
    local entry = queue_host.current_entry(self)
    self:refresh_git_queue(entry and entry.path)
  end
end

-- Each wrapper runs the action, notifies on failure, and refreshes the panel queue.
for method, action in pairs({
  toggle_stage_hunk = "toggle_stage",
  stage_hunk = "stage",
  unstage_hunk = "unstage",
  discard_hunk = "discard",
  apply_left_hunk = "apply_left",
  apply_right_hunk = "apply_right",
  undo_action = "undo",
}) do
  Session[method] = function(self)
    self:after_git_action(notify_action_result(actions[action](self)))
  end
end

local function buffer_has_undo(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  local ok, tree = pcall(vim.api.nvim_buf_call, bufnr, vim.fn.undotree)
  return ok and type(tree) == "table" and tonumber(tree.seq_cur or 0) > 0
end

local function buffer_undo_seq(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local ok, tree = pcall(vim.api.nvim_buf_call, bufnr, vim.fn.undotree)
  if not (ok and type(tree) == "table") then
    return nil
  end
  return tonumber(tree.seq_cur or 0) or 0
end

local function current_action_undo_entry(session)
  local queue = session and session.file_queue
  if not (queue and queue.kind == "git") then
    return nil
  end
  local entry = queue.entries and queue.entries[session.file_queue_index or queue.index or 1]
  local stack = entry and session.action_undo and session.action_undo[entry.path]
  return stack and stack[#stack] or nil
end

function Session:undo_edit_or_action()
  if self.right and self.right.editable and vim.api.nvim_get_current_buf() == self.right_buf then
    local undo_seq = buffer_undo_seq(self.right_buf)
    local action_entry = current_action_undo_entry(self)
    if action_entry and undo_seq ~= nil and action_entry.right_undo_seq == undo_seq then
      self:undo_action()
      return
    end
    if buffer_has_undo(self.right_buf) then
      local before_tick = vim.api.nvim_buf_get_changedtick(self.right_buf)
      local ok = pcall(vim.cmd, "silent undo")
      if ok and vim.api.nvim_buf_get_changedtick(self.right_buf) ~= before_tick then
        self:request_editable_right_refresh()
        return
      end
    elseif not self.file_queue then
      pcall(vim.cmd, "undo")
      return
    end
  end
  self:undo_action()
end

return Session
