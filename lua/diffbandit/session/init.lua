local state = require("diffbandit.state")
local actions = require("diffbandit.session.actions")
local status = require("diffbandit.util.status")
local panel_mod = require("diffbandit.panel")
local nvim = require("diffbandit.util.nvim")
local document = require("diffbandit.util.document")
local overview = require("diffbandit.util.overview")
local amend_mode = require("diffbandit.util.amend_mode")
local queue_host = require("diffbandit.host.queue")
local ui = require("diffbandit.util.ui")
local rowmap = require("diffbandit.util.rowmap")
local connector_width = require("diffbandit.connector.width")
local keymaps = require("diffbandit.util.keymaps")
local session_layout = require("diffbandit.session.layout")
local render_host = require("diffbandit.session.render_host")
local config_mod = require("diffbandit.config")
local keyhelp = require("diffbandit.util.keyhelp")
local view_builder = require("diffbandit.diff.view")
local keep_view = require("diffbandit.session.keep_view")
local diff_document = require("diffbandit.diff.document")
local kitty = require("diffbandit.kitty")
local winbar = require("diffbandit.util.winbar")
local layout = require("diffbandit.util.layout")

local Session = {}
Session.__index = Session
render_host.install(Session)

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

local function apply_document_model(self, model, invalidate)
  self.hunks = model.hunks
  self.view = model.view
  self.document_model = model
  self.document_identity = model.identity
  if invalidate ~= false then
    self:invalidate_render_caches()
  end
  if model.base_paths then
    self.base_paths_cache = model.base_paths
  end
end

local function build_document_for_sources(self, sources, config)
  self.document_lru = self.document_lru or diff_document.new_lru()
  return diff_document.get_or_build(sources, config, {
    store = diff_document.resolve_store(self, sources),
    lru = self.document_lru,
  })
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
end

function Session.start(sources, config, opts)
  opts = opts or {}
  local self = setmetatable({}, Session)
  self.id = state.next_session_id()
  self.config = config
  self.file_queue = opts.queue
  self.file_queue_index = opts.queue and (opts.queue.index or 1) or nil
  self.document_lru = diff_document.new_lru()
  local model, err = build_document_for_sources(self, sources, config)
  if not model then
    return nil, err
  end

  self.left = sources.left
  self.right = sources.right
  apply_document_model(self, model, false)
  local view = model.view
  self.current_chunk = opts.chunk_position == "top" and 0 or (view.chunks[1] and 1 or 0)
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
  if model.base_paths then
    self.base_paths_cache = model.base_paths
  end
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

  -- Optional Kitty graphics connector: resolves "kitty" or "cells" now and
  -- flips later if an "auto" probe answers (or the terminal rejects images).
  kitty.attach(self, {
    on_change = function()
      if self.disposed then
        return
      end
      self:invalidate_render_caches()
      self:precompute_connector_core_width()
      self.last_viewport_render_key = nil
      self:rerender_for_viewport()
    end,
    refresh = function()
      if self.disposed then
        return
      end
      self.last_viewport_render_key = nil
      self:rerender_for_viewport()
    end,
  })

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
  if self.file_queue and #(self.file_queue.entries or {}) > 1 then
    -- Warm the next file once the first paint (and the editor's own
    -- FileType/LSP work) has had its turn, so the first ]f is instant too.
    queue_host.prefetch_neighbors(self, self.file_queue_index, 120)
  end

  if self.current_chunk > 0 then
    vim.schedule(function()
      if not self.disposed then
        local chunk = self.view.chunks[self.current_chunk]
        if chunk then
          -- Mirror goto_chunk's clip-bounded active paint, but only scroll
          -- when the first hunk is outside the initial top-of-file viewport.
          -- Near-top diffs (and the integration visual contracts) keep
          -- document start; distant first hunks still jump so the clip
          -- covers the overlay.
          local clip = self.last_render_clip or self.last_paint_clip
          local in_open_viewport = false
          if clip and clip.meta_min and clip.meta_max then
            in_open_viewport = chunk.display_end >= clip.meta_min
              and chunk.display_start <= clip.meta_max
          end
          if not in_open_viewport then
            self:align_chunk_viewports(chunk)
            clip = self.last_render_clip or self.last_paint_clip
          end
          self:highlight_active_chunk(chunk, {
            clip = clip,
            -- Align already placed cursors/gutters; otherwise match the
            -- pre-scroll open path (cursor on hunk, toplines unchanged).
            position_cursor = in_open_viewport,
            sync_gutters = in_open_viewport,
            render_chrome = true,
          })
        end
      end
    end)
  end

  return self
end

function Session:open_layout()
  session_layout.open(self)
end

function Session:resize_layout()
  session_layout.resize(self)
  self.foreign_layout_key = layout.foreign_layout_key(self.tabpage, self:owned_windows())
end

-- Split windows this session lays out (content, gutters, sidecars, headers,
-- and the attached commit panel).
function Session:owned_windows()
  local panel = self.panel or {}
  local wins = {}
  for _, win in ipairs({
    self.left_overview_win, self.left_win, self.left_num_win, self.connector_win,
    self.right_num_win, self.right_win, self.right_overview_win,
    self.left_header_win, self.center_header_win, self.right_header_win,
    panel.nav_win, panel.commit_win,
  }) do
    if win then
      wins[#wins + 1] = win
    end
  end
  return wins
end

-- Wrapped line heights follow the source panes' width and wrap-related
-- options ('wrap', 'linebreak', 'tabstop', …). When either row map
-- changes, the gutters and routes must be rebuilt in the new row space.
function Session:refresh_row_maps()
  ui.schedule_once(self, "row_map_refresh_scheduled", function()
    if self.disposed then
      return
    end
    local before = self.row_map_signature
    self:row_maps({ verify = true })
    if self.row_map_signature ~= before then
      self:render()
      self:sync_gutter_viewports()
    end
  end, 0)
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

  local left_height = math.max(1, nvim.get_window_height(self.left_win))
  local right_height = math.max(1, nvim.get_window_height(self.right_win))
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
      height = math.max(height, nvim.get_window_height(win))
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

  -- Diagnostics arriving (or clearing) after the initial render toggle the
  -- editable pane's sign column: the band-colored sign fills must be
  -- (re)painted, and the viewport dedupe key would otherwise skip the
  -- repaint since nothing else changed. Checked by buffer in the callback
  -- because replace_sources swaps the right buffer.
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = augroup,
    callback = function(event)
      if self.disposed or event.buf ~= self.right_buf then
        return
      end
      -- Band rows mirror diagnostic glyphs in the sign column, so any
      -- diagnostic change (arrival, clearing, moving lines, severity)
      -- needs a repaint; the request is debounced, and the dedupe key must
      -- not swallow it since the viewport itself is unchanged.
      self.last_viewport_render_key = nil
      pcall(Session.request_viewport_rerender, self)
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

  -- A winbar set on a source pane after open (breadcrumb plugins attach
  -- lazily) moves its text a row down; give the gutters the same bar row.
  winbar.watch(self, function()
    return session_layout.winbar_spec(self)
  end, function()
    self:sync_gutter_viewports()
    self:render()
  end)

  local function on_height_change()
    if self.disposed or self.rendering_viewport then
      return
    end
    self:refresh_row_maps()
  end
  -- A foreign split (a file tree, quickfix, …) opening or closing in this
  -- tabpage, or the editor resizing, hands columns to whichever DiffBandit
  -- window is adjacent; re-run the width layout so the panel and gutters
  -- return to their sizes and the source panes split what is left. Resizes
  -- of DiffBandit's own windows (a dragged separator) keep the key and stay.
  local function on_resize()
    if self.disposed then
      return
    end
    on_height_change()
    ui.schedule_once(self, "foreign_layout_scheduled", function()
      if self.disposed or vim.api.nvim_get_current_tabpage() ~= self.tabpage then
        return
      end
      if layout.foreign_layout_key(self.tabpage, self:owned_windows()) ~= self.foreign_layout_key then
        self:resize_layout()
      end
    end, 0)
  end
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = augroup, callback = on_resize })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = augroup,
    pattern = rowmap.HEIGHT_OPTIONS,
    callback = on_height_change,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function(event)
      if self.syncing_scroll or self.rendering_viewport or self.disposed then
        return
      end
      -- WinScrolled delivers the scrolled window ID via <amatch>.
      local win = tonumber(event.match)
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
      self:request_overview_render()
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
      self:request_overview_render()
    end,
  })

  -- LSP configs commonly install buffer-local diagnostic maps ([d/]d) from
  -- LspAttach handlers; those fire after this session claimed a real file
  -- buffer and would shadow the document-navigation maps. Re-assert ours
  -- after the handlers have run. BufEnter covers git file-queue swaps where
  -- gitsigns (and similar) bind ]c from a scheduled attach, not LspAttach.
  local function reassert_source_maps(args)
    if self.disposed then
      return
    end
    if args.buf == self.left_buf or args.buf == self.right_buf then
      keymaps.reassert_later(self, { args.buf })
    end
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    callback = reassert_source_maps,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = reassert_source_maps,
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
        -- Undo records the post-undo changedtick; only suppress TextChanged
        -- when the tick still matches (if TextChanged never fires, a later
        -- real edit has a new tick and must not be swallowed).
        local suppress_tick = self.suppress_editable_textchanged_tick
        if suppress_tick ~= nil then
          self.suppress_editable_textchanged_tick = nil
          if vim.api.nvim_buf_get_changedtick(self.right_buf) == suppress_tick then
            return
          end
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
  -- section/desc label the mapping for the help window (util/keyhelp).
  local function map(buf, lhs, rhs, section, desc)
    self:set_buffer_keymap("n", buf, lhs, rhs, keyhelp.opts(buf, section, desc, opts))
  end
  local function action_map(buf, lhs, command, fallback, desc)
    if vim.fn.exists(":" .. command) == 2 then
      map(buf, lhs, "<Cmd>" .. command .. "<CR>", "Staging and actions", desc)
    else
      map(buf, lhs, fallback, "Staging and actions", desc)
    end
  end
  local navigation = self.config.navigation or {}
  local document_keys = navigation.document_keys or {}
  local git_keys = config_mod.section(self.config, "git", "file_keys")
  local panel_keys = config_mod.section(self.config, "git", "panel", "keys")
  local action_keys = ((self.config.actions or {}).keys or {})
  local is_git = self.file_queue and self.file_queue.kind == "git"

  local function buffer_maps(buf)
    if navigation.help_key then
      map(buf, navigation.help_key, function()
        self:show_key_help()
      end, "General", "Show this key help")
    end
    if navigation.close_key then
      map(buf, navigation.close_key, function()
        self:close()
      end, "General", "Close this view")
    end
    map(buf, "]c", function()
      self:goto_next_chunk()
    end, "Hunks", "Next hunk")
    map(buf, "[c", function()
      self:goto_prev_chunk()
    end, "Hunks", "Previous hunk")
    if document_keys.top then
      map(buf, document_keys.top, function()
        self:goto_document_edge("top")
      end, "Navigation", "Align both panes to the top")
    end
    if document_keys.bottom then
      map(buf, document_keys.bottom, function()
        self:goto_document_edge("bottom")
      end, "Navigation", "Align both panes to the bottom")
    end
    if navigation.snap_key then
      map(buf, navigation.snap_key, function()
        self:snap_to_cursor()
      end, "Navigation", "Line up the other pane with the cursor line")
    end
    if self.file_queue and git_keys.next then
      map(buf, git_keys.next, function()
        self:goto_next_file()
      end, "Files", "Next file")
    end
    if self.file_queue and git_keys.prev then
      map(buf, git_keys.prev, function()
        self:goto_prev_file()
      end, "Files", "Previous file")
    end
    if action_keys.toggle_stage then
      action_map(buf, action_keys.toggle_stage, "DiffBanditToggleStageHunk", function()
        self:toggle_stage_hunk()
      end, "Stage or unstage the active hunk")
    end
    if action_keys.apply_left then
      action_map(buf, action_keys.apply_left, "DiffBanditApplyLeftHunk", function()
        self:apply_left_hunk()
      end, "Copy the left side of the hunk to the right")
    end
    if action_keys.apply_right then
      action_map(buf, action_keys.apply_right, "DiffBanditApplyRightHunk", function()
        self:apply_right_hunk()
      end, "Copy the right side of the hunk to the left")
    end
    if action_keys.undo then
      if buf == self.right_buf and self.right and self.right.editable then
        map(buf, action_keys.undo, function()
          self:undo_edit_or_action()
        end, "Staging and actions", "Undo the last edit or hunk action")
      else
        action_map(buf, action_keys.undo, "DiffBanditUndo", function()
          self:undo_action()
        end, "Undo the last hunk action")
      end
    end
  end

  buffer_maps(self.left_buf)
  buffer_maps(self.left_num_buf)
  buffer_maps(self.connector_buf)
  buffer_maps(self.right_num_buf)
  buffer_maps(self.right_buf)
  if self.file_queue and panel_keys.focus_panel then
    for _, buf in ipairs({ self.left_buf, self.right_buf }) do
      map(buf, panel_keys.focus_panel, function()
        self:focus_commit_panel_for_current_file()
      end, "Panel", "Open or focus the commit panel")
    end
  end
  if is_git and panel_keys.toggle_panel then
    for _, buf in ipairs({ self.left_buf, self.right_buf }) do
      map(buf, panel_keys.toggle_panel, function()
        self:toggle_commit_panel()
      end, "Panel", "Show or hide the commit panel")
    end
    self:map_panel_toggle()
  end
  map(self.left_buf, "<C-w>l", function()
    if self.right_win and vim.api.nvim_win_is_valid(self.right_win) then
      vim.api.nvim_set_current_win(self.right_win)
    end
  end, "Navigation", "Go to the right pane")
  map(self.right_buf, "<C-w>h", function()
    if self.left_win and vim.api.nvim_win_is_valid(self.left_win) then
      vim.api.nvim_set_current_win(self.left_win)
    end
  end, "Navigation", "Go to the left pane")
  keymaps.reassert_later(self, { self.left_buf, self.right_buf })
end

-- Header legend for the help window: what the compact status fields mean.
function Session:key_help_notes()
  if not self.status_enabled then
    return nil
  end
  local rows = {}
  if self.file_queue and self.file_queue.kind == "git" then
    rows[#rows + 1] = { keys = "all/unstg/stg", desc = "Which changes this review shows" }
    rows[#rows + 1] = { keys = "2/6", desc = "File 2 of 6 in the review" }
    rows[#rows + 1] = { keys = "h3/5", desc = "Hunk 3 of 5 (h-/5: cursor is between hunks)" }
    rows[#rows + 1] = { keys = "M A D R ??", desc = "Git status of this file (?? untracked)" }
    rows[#rows + 1] = { keys = "1/5", desc = "Hunks of this file that are staged" }
  else
    rows[#rows + 1] = { keys = "h3/5", desc = "Hunk 3 of 5 (h-/5: cursor is between hunks)" }
  end
  return { { title = "Header", rows = rows } }
end

function Session:show_key_help()
  keyhelp.open(vim.api.nvim_get_current_buf(), {
    title = "Diff",
    notes = self:key_help_notes(),
    help_key = (self.config.navigation or {}).help_key,
  })
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

  local left_row, right_row = self:gutter_toplines()
  local left_map, right_map = self:row_maps({ stale_ok = true })
  local map = source_win == self.left_win and left_map or right_map
  self.syncing_scroll = true
  if number_win and vim.api.nvim_win_is_valid(number_win) then
    pcall(vim.api.nvim_win_set_cursor, number_win, { map:first_row(source_line), 0 })
    set_win_view_topline(number_win, source_win == self.left_win and left_row or right_row)
  end
  if self.connector_win and vim.api.nvim_win_is_valid(self.connector_win) then
    set_win_view_topline(self.connector_win, left_row)
  end
  self.syncing_scroll = false
end

function Session:sync_gutter_viewports()
  local left_row, right_row = self:gutter_toplines()
  self.syncing_scroll = true
  set_win_view_topline(self.left_num_win, left_row)
  set_win_view_topline(self.right_num_win, right_row)
  set_win_view_topline(self.connector_win, left_row)
  self.syncing_scroll = false
end

function Session:sync_from_left()
  sync_source_to_gutter(self, self.left_win, self.left_num_win)
end

function Session:sync_from_right()
  sync_source_to_gutter(self, self.right_win, self.right_num_win)
end

function Session:request_viewport_rerender()
  if self.disposed or self.rendering_viewport then
    return
  end
  local delay = tonumber(config_mod.section(self.config, "ui").scroll_debounce_ms) or 16
  ui.schedule_once(self, "viewport_rerender_scheduled", function()
    self:rerender_for_viewport()
  end, delay)
end

-- Debounced overview paint for CursorMoved (full render still paints immediately).
function Session:request_overview_render()
  if self.disposed or not self.overview_enabled then
    return
  end
  local overview_cfg = config_mod.section(self.config, "ui", "overview")
  local delay = tonumber(overview_cfg.debounce_ms)
  if delay == nil then
    delay = 32
  end
  ui.schedule_once(self, "overview_rerender_scheduled", function()
    self:render_overviews()
  end, delay)
end

-- Immediate re-diff after editable right text changed (also used after undo).
function Session:refresh_editable_right()
  if self.disposed or not (self.right and self.right.editable) then
    return
  end
  -- Cancel any armed debounce so the deferred callback does not re-diff again.
  ui.cancel_schedule_once(self, "editable_right_refresh_scheduled")
  document.refresh_source_from_editable(self.right)
  self:replace_sources({
    left = self.left,
    right = self.right,
  }, {
    preserve_view = true,
    chunk_position = "preserve",
    preferred_chunk = self.current_chunk,
    chunk_from_cursor = true,
  })
end

-- Debounced re-diff for typing (TextChanged). Undo / InsertLeave can call
-- refresh_editable_right() for an immediate model rebuild.
function Session:request_editable_right_refresh()
  if self.disposed or not (self.right and self.right.editable) then
    return
  end
  local ui_cfg = config_mod.section(self.config, "ui")
  local delay = tonumber(ui_cfg.edit_refresh_debounce_ms)
  if delay == nil then
    delay = 150
  end
  -- Restart the timer on each keystroke so a sustained edit burst only
  -- re-diffs after idle (schedule_once would fire mid-stream).
  ui.reschedule_once(self, "editable_right_refresh_scheduled", function()
    self:refresh_editable_right()
  end, delay)
end

local function apply_viewport_toplines(self, left_topline, right_topline, opts)
  set_win_view_topline(self.left_win, left_topline, opts)
  set_win_view_topline(self.right_win, right_topline, opts)
  local left_row, right_row = self:gutter_toplines()
  set_win_view_topline(self.left_num_win, left_row, opts)
  set_win_view_topline(self.right_num_win, right_row, opts)
  set_win_view_topline(self.connector_win, left_row, opts)
end

function Session:set_viewport_toplines(left_topline, right_topline)
  apply_viewport_toplines(self, left_topline, right_topline)
  self:rerender_for_viewport()
end

function Session:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_cursor, right_cursor, opts)
  opts = opts or {}
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
  -- nvim_win_set_cursor honors 'scrolloff', which independently shifts each
  -- pane (add/delete cursors are not the same offset from the navigation
  -- anchors). Re-apply the intended toplines after cursor placement without
  -- resetting the cursor column; a topline inside the margin still moves.
  apply_viewport_toplines(self, left_topline, right_topline, { preserve_cursor = true })
  if opts.defer_render then
    -- The viewport (text, backgrounds, cursors) moves immediately; only the
    -- route overlay repaint rides the scroll debounce, so rapid navigation
    -- coalesces into one render — same contract as wheel scrolling.
    self:request_viewport_rerender()
  else
    self:rerender_for_viewport()
  end
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

  local context = nvim.jump_context(navigation, { self.left_win, self.right_win })
  local left_topline = math.max(1, left_anchor - context)
  local right_topline = math.max(1, right_anchor - context)
  local left_cursor, right_cursor = self:chunk_cursor_rows(chunk)
  left_cursor = left_cursor or left_topline
  right_cursor = right_cursor or right_topline

  -- Defer the route repaint through the scroll debounce when the target
  -- viewport is already inside the last render's styled window: rapid ]c/[c
  -- keeps the UI responsive and coalesces repaints. Long jumps outside the
  -- window render synchronously so no unstyled rows ever appear.
  local clip = self.last_render_clip
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and nvim.get_window_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and nvim.get_window_height(self.right_win) or 1
  local within_styled_window = clip ~= nil
    and left_topline >= clip.left_min
    and (left_topline + left_height) <= clip.left_max
    and right_topline >= clip.right_min
    and (right_topline + right_height) <= clip.right_max

  self:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_cursor, right_cursor,
    { defer_render = within_styled_window })

  if focused_win == self.left_win or focused_win == self.right_win then
    pcall(vim.api.nvim_set_current_win, focused_win)
  elseif self.last_source_win and vim.api.nvim_win_is_valid(self.last_source_win) then
    pcall(vim.api.nvim_set_current_win, self.last_source_win)
  end
end

-- Scroll the opposite pane so the row facing the cursor line sits at the same
-- screen offset, and put its cursor on that row. Panes scroll independently;
-- this is the manual "re-align on demand" complement to ]c alignment. Snap is
-- a viewport operation, not navigation — it never touches chunk or
-- file-boundary state.
function Session:snap_to_cursor()
  local focused_win = vim.api.nvim_get_current_win()
  local source_win
  if focused_win == self.left_win or focused_win == self.right_win then
    source_win = focused_win
  elseif focused_win == self.left_num_win then
    source_win = self.left_win
  elseif focused_win == self.right_num_win then
    source_win = self.right_win
  elseif self.last_source_win and vim.api.nvim_win_is_valid(self.last_source_win) then
    source_win = self.last_source_win
  end
  if not (source_win and vim.api.nvim_win_is_valid(source_win)) then
    return
  end
  local from_side = source_win == self.left_win and "left" or "right"

  local source_cursor = vim.api.nvim_win_get_cursor(source_win)
  local cursor_row = source_cursor[1]
  local topline = get_win_view_topline(source_win)
  local offset = math.max(0, cursor_row - topline)

  local target_row = view_builder.counterpart_row(self.view.line_meta, from_side, cursor_row)
  local target_lines = from_side == "left" and #self.view.right or #self.view.left
  target_row = math.min(math.max(1, target_row), math.max(1, target_lines))
  local target_topline = math.max(1, target_row - offset)

  -- Pass the full {row, col} pair for the focused side so its cursor column
  -- survives the snap untouched.
  if from_side == "left" then
    self:set_viewport_toplines_preserve_cursors(topline, target_topline, source_cursor, target_row)
  else
    self:set_viewport_toplines_preserve_cursors(target_topline, topline, target_row, source_cursor)
  end

  if focused_win ~= vim.api.nvim_get_current_win() then
    pcall(vim.api.nvim_set_current_win, focused_win)
  end
end

function Session:goto_document_edge(edge)
  self:reset_pending_file_boundary()
  self.chunk_not_reached = false
  local focused_win = vim.api.nvim_get_current_win()
  local left_line_count = math.max(1, #self.view.left)
  local right_line_count = math.max(1, #self.view.right)
  local left_line = edge == "bottom" and left_line_count or 1
  local right_line = edge == "bottom" and right_line_count or 1
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and nvim.get_window_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and nvim.get_window_height(self.right_win) or 1
  -- The margin holds only in a pane with padding below its last line, so ask
  -- for it in every pane to keep them level.
  local left_topline = edge == "bottom" and math.max(1, left_line_count - left_height + 1 + nvim.scrolloff_rows(self.left_win)) or 1
  local right_topline = edge == "bottom" and math.max(1, right_line_count - right_height + 1 + nvim.scrolloff_rows(self.right_win)) or 1

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
  -- Viewport paint is non-structural and skips chrome; chunk index still
  -- changed, so refresh status/overview explicitly for top/bottom position.
  self:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_line, right_line)
  self:render_status_headers()
  ui.cancel_schedule_once(self, "overview_rerender_scheduled")
  self:render_overviews()

  if focused_win == self.left_win or focused_win == self.right_win then
    pcall(vim.api.nvim_set_current_win, focused_win)
  elseif self.last_source_win and vim.api.nvim_win_is_valid(self.last_source_win) then
    pcall(vim.api.nvim_set_current_win, self.last_source_win)
  end
end

-- Remove DiffBandit paint marks from a buffer that may outlive the session
-- (editable right / worktree buffers keep bufhidden=hide). Scratch panes are
-- wiped on tab close, but clearing them here is harmless and keeps one path.
function Session:clear_buffer_paint_namespaces(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  for _, ns in ipairs({ self.ns, self.active_ns, self.extmark_ns, self.path_ns }) do
    if ns then
      pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    end
  end
end

function Session:dispose()
  if self.disposed then
    return
  end
  panel_mod.save_draft(self)
  self.disposed = true
  kitty.detach(self)
  self:clear_keymaps()
  panel_mod.delete_buffers(self)
  -- Editable right reuses the user's buffer; without this, band/intraline
  -- extmarks stay visible after q returns to that buffer (issue #5).
  self:clear_buffer_paint_namespaces(self.right_buf)
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

-- Switching the panel between a changed file and a merge conflict starts a
-- different host in its own tab; close this one so the switch replaces the
-- view instead of stacking a tab per move (issue #20). Unlike close(), this
-- never returns to a parent view: the replacement is where focus belongs.
function Session:close_for_replacement(next_host)
  if self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, self.tabpage)
    pcall(vim.cmd, "tabclose")
  end
  self:dispose()
  local next_tab = next_host and next_host.tabpage
  if next_tab and vim.api.nvim_tabpage_is_valid(next_tab) then
    pcall(vim.api.nvim_set_current_tabpage, next_tab)
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
  ui.set_header_line_with_right(
    self.right_header_buf,
    self.ns,
    self.status_lines.right,
    keyhelp.hint((self.config.navigation or {}).help_key),
    vim.api.nvim_win_get_width(self.right_header_win)
  )
end

-- The render above ran with a provisional active chunk.
local function clear_active_position(self)
  self:clear_active_chunk()
  self:render_status_headers()
  self:render_overviews()
  self:rerender_for_viewport()
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

  local model, model_err
  local same_live = self.left == (sources and sources.left)
    and self.right == (sources and sources.right)
    and self.document_model
    and self.hunks
    and self.view
  local same_document = same_live
  if same_live and sources.right and sources.right.editable then
    same_document = diff_document.same_identity(self, sources, self.config)
  end
  if same_document then
    model = self.document_model
  else
    model, model_err = build_document_for_sources(self, sources, self.config)
    if not model then
      return nil, model_err
    end
  end
  local view = model.view
  if opts.view_before then
    local planned = keep_view.plan(opts.view_before, view, sources.left.lines, sources.right.lines)
    preserved_left_topline, preserved_right_topline = planned.left.topline, planned.right.topline
    preserved_left_cursor, preserved_right_cursor = planned.left.cursor, planned.right.cursor
  end
  self.chunk_not_reached = false

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
      -- Window-local options are per (window, buffer); the swap reverted
      -- them to the new buffer's defaults ('wrap' on desyncs the pane's
      -- screen rows from its gutters).
      session_layout.apply_right_source_window_options(self)
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
      session_layout.apply_right_source_window_options(self)
    end
    set_buffer_options(self.right_buf, { bufhidden = "wipe" })
  end
  if old_right_buf ~= self.right_buf then
    -- Detached right buffers (esp. editable worktree files) must not keep
    -- DiffBandit band/sign marks after the session moves on.
    self:clear_buffer_paint_namespaces(old_right_buf)
    document.cleanup_created_buffer(old_right_editable)
  end
  session_layout.name_source_buffers(self)
  self.replacing_sources = previous_replacing_sources
  apply_document_model(self, model, not same_document)
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
    local at_cursor = opts.chunk_from_cursor and actions.chunk_index_at_cursor(self) or nil
    local preferred = at_cursor or opts.preferred_chunk or self.current_chunk or 1
    local count = #self.view.chunks
    if preferred < 1 or count == 0 then
      -- Above the first chunk (the top of the file): ]c should still reach it.
      self.current_chunk = 0
      clear_active_position(self)
    elseif opts.chunk_from_cursor and preferred > count then
      -- Past the last chunk: [c should still reach it.
      self.current_chunk = count + 1
      clear_active_position(self)
    elseif count > 0 then
      self.current_chunk = math.min(preferred, count)
      local chunk = self.view.chunks[self.current_chunk]
      self:highlight_active_chunk(chunk, {
        position_cursor = false,
        clip = self.last_render_clip or self.last_paint_clip,
      })
      -- The next chunk slid into this index while the cursor stayed put.
      self.chunk_not_reached = opts.chunk_from_cursor == true
        and not at_cursor
        and not actions.chunk_on_screen(self, chunk)
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

local function clear_active_ns_range(buf, ns, row_min, row_max, full)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not ns then
    return
  end
  if full or not row_min or not row_max or row_max < row_min then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, math.max(0, row_min - 1), row_max)
end

function Session:clear_active_chunk(clip)
  -- Full clear when no clip; viewport paints clear only the padded window so
  -- a multi-thousand-row active chunk does not thrash the whole buffer.
  local full = not clip
  local left_min = clip and clip.left_min
  local left_max = clip and clip.left_max
  local right_min = clip and clip.right_min
  local right_max = clip and clip.right_max
  local conn_min = clip and clip.connector_min
  local conn_max = clip and clip.connector_max
  clear_active_ns_range(self.left_buf, self.active_ns, left_min, left_max, full)
  clear_active_ns_range(self.left_num_buf, self.active_ns, clip and clip.left_nmin, clip and clip.left_nmax, full)
  clear_active_ns_range(self.right_buf, self.active_ns, right_min, right_max, full)
  clear_active_ns_range(self.right_num_buf, self.active_ns, clip and clip.right_nmin, clip and clip.right_nmax, full)
  clear_active_ns_range(self.connector_buf, self.active_ns, conn_min, conn_max, full)
end

function Session:highlight_active_chunk(chunk, opts)
  opts = opts or {}
  local clip = opts.clip
  local prev_clip = opts.prev_clip
  -- Union prev+cur clip for clear so marks do not accumulate off-screen.
  -- Connector active marks use meta-index rows (same as historical paint);
  -- clear them via meta_min/max, not left-row connector bounds.
  local clear_clip = nil
  if clip then
    local meta_lo = clip.meta_min
    local meta_hi = clip.meta_max
    if prev_clip then
      if prev_clip.meta_min then
        meta_lo = math.min(meta_lo or prev_clip.meta_min, prev_clip.meta_min)
      end
      if prev_clip.meta_max then
        meta_hi = math.max(meta_hi or prev_clip.meta_max, prev_clip.meta_max)
      end
    end
    local function lo(field)
      return prev_clip and math.min(prev_clip[field] or clip[field], clip[field]) or clip[field]
    end
    local function hi(field)
      return prev_clip and math.max(prev_clip[field] or clip[field], clip[field]) or clip[field]
    end
    clear_clip = {
      left_min = lo("left_min"),
      left_max = hi("left_max"),
      right_min = lo("right_min"),
      right_max = hi("right_max"),
      left_nmin = lo("left_nmin"),
      left_nmax = hi("left_nmax"),
      right_nmin = lo("right_nmin"),
      right_nmax = hi("right_nmax"),
      connector_min = meta_lo,
      connector_max = meta_hi,
    }
  end
  self:clear_active_chunk(clear_clip)

  local active_hl = "DiffBanditActiveChunk"
  local add_hl = vim.api.nvim_buf_add_highlight
  local left_map, right_map = self:row_maps()
  local left_min = clip and clip.left_min
  local left_max = clip and clip.left_max
  local right_min = clip and clip.right_min
  local right_max = clip and clip.right_max

  local function left_ok(row)
    return not clip or (row and row >= left_min and row <= left_max)
  end
  local function right_ok(row)
    return not clip or (row and row >= right_min and row <= right_max)
  end

  -- Walk only chunk ∩ viewport meta ranges (or the full chunk when unclipped).
  local function paint_meta(meta_idx)
    local meta = self.view.line_meta[meta_idx]
    if not meta then
      return
    end
    -- Skip sides with strong backgrounds to avoid washing out colors.
    -- Strength is PER SIDE: an embedded add row is a gap on the left but
    -- real green content (and its gutter band) on the right — a single
    -- per-row flag painted the overlay across the right gutter and
    -- punched holes in the band above the wedge (and symmetrically over
    -- the left delete background).
    local left_strong = meta.kind ~= "context" and not meta.filler_left
    local right_strong = meta.kind ~= "context" and not meta.filler_right

    if meta.left_index and not left_strong and left_ok(meta.left_index) then
      local row = meta.left_index - 1
      add_hl(self.left_buf, self.active_ns, active_hl, row, 0, -1)
      local first = left_map:first_row(meta.left_index)
      for r = first, first + left_map:height(meta.left_index) - 1 do
        add_hl(self.left_num_buf, self.active_ns, active_hl, r - 1, 0, -1)
      end
    end

    if meta.right_index and not right_strong and right_ok(meta.right_index) then
      local row = meta.right_index - 1
      add_hl(self.right_buf, self.active_ns, active_hl, row, 0, -1)
      local first = right_map:first_row(meta.right_index)
      for r = first, first + right_map:height(meta.right_index) - 1 do
        add_hl(self.right_num_buf, self.active_ns, active_hl, r - 1, 0, -1)
      end
    end

    -- Connector active overlay uses meta-index rows (display model), matching
    -- the historical unclipped paint and connector buffer layout.
    if not (left_strong and right_strong) then
      add_hl(self.connector_buf, self.active_ns, active_hl, meta_idx - 1, 0, -1)
    end
  end

  local ranges = clip and clip.meta_ranges
  if ranges and #ranges > 0 then
    for _, r in ipairs(ranges) do
      local lo = math.max(chunk.display_start, r[1])
      local hi = math.min(chunk.display_end, r[2])
      for meta_idx = lo, hi do
        paint_meta(meta_idx)
      end
    end
  else
    local lo = chunk.display_start
    local hi = chunk.display_end
    if clip and clip.meta_min and clip.meta_max then
      lo = math.max(lo, clip.meta_min)
      hi = math.min(hi, clip.meta_max)
    end
    for meta_idx = lo, hi do
      paint_meta(meta_idx)
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
  if opts.sync_gutters ~= false then
    self:sync_gutter_viewports()
  end
  if opts.render_chrome ~= false then
    self:render_status_headers()
    self:render_overviews()
  end
end

function Session:goto_chunk(index)
  if #self.view.chunks == 0 then
    return
  end
  self:reset_pending_file_boundary()
  self.chunk_not_reached = false
  if index < 1 then
    index = 1
  elseif index > #self.view.chunks then
    index = #self.view.chunks
  end
  self.current_chunk = index
  local chunk = self.view.chunks[self.current_chunk]
  -- Align first so last_render_clip matches the destination viewport, then
  -- paint the active overlay only inside that clip (large hunks stay cheap).
  self:align_chunk_viewports(chunk)
  self:highlight_active_chunk(chunk, {
    clip = self.last_render_clip or self.last_paint_clip,
    -- align_chunk_viewports already placed cursors and synced gutters.
    position_cursor = false,
    sync_gutters = false,
    render_chrome = true,
  })
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
  actions.note_file_shown(self)
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
  self:close_for_replacement(session)
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
    on_queue = function(session, queue, target_index)
      local target = queue.entries and queue.entries[target_index]
      local on_preferred = preferred_path
        and target
        and (target.path == preferred_path or target.old_path == preferred_path)
      local already_loaded = refresh_opts.keep_loaded_file and on_preferred
      if refresh_opts.stay_on and not on_preferred then
        -- An undo elsewhere changed nothing about the file on screen.
        for index, entry in ipairs(queue.entries or {}) do
          if entry.path == refresh_opts.stay_on then
            target_index = index
            queue_host.set_index(session, index)
            already_loaded = true
            break
          end
        end
      end
      if already_loaded then
        -- The hunk action reloaded this file; only the queue around it is new.
        session:prefetch_queue_neighbors(target_index)
      else
        session:goto_queue_file(target_index, "top", {
          preserve_focus = session.panel and session.panel.visible,
          skip_panel_render = true,
        })
      end
      if session.panel then
        -- The load may have skipped an unreadable file: select the one shown.
        local selected = refresh_opts.preserve_panel_selection or session.file_queue_index or target_index
        panel_mod.render(session, selected, { refresh_stage_states = true })
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
  self:map_panel_toggle()
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

-- The toggle key also hides the panel while focused in it (as in merge).
-- Panel buffers can be created after setup_keymaps, so show_commit_panel
-- re-runs this.
function Session:map_panel_toggle()
  local key = config_mod.section(self.config, "git", "panel", "keys").toggle_panel
  local panel = self.panel
  if not (key and panel and self.file_queue and self.file_queue.kind == "git") then
    return
  end
  for _, buf in ipairs({ panel.nav_buf, panel.commit_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      self:set_buffer_keymap("n", buf, key, function()
        self:toggle_commit_panel()
      end, keyhelp.opts(buf, "Panel", "Hide the commit panel", { nowait = true, noremap = true, silent = true }))
    end
  end
end

function Session:hide_commit_panel()
  if not self.panel then
    return false
  end
  local current = vim.api.nvim_get_current_win()
  local in_panel = current == self.panel.nav_win or current == self.panel.commit_win
  panel_mod.close(self)
  self:resize_layout()
  if in_panel then
    local target = self.last_source_win
    if not (target and vim.api.nvim_win_is_valid(target)) then
      target = self.right_win
    end
    if target and vim.api.nvim_win_is_valid(target) then
      pcall(vim.api.nvim_set_current_win, target)
    end
  end
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
  if self.chunk_not_reached and actions.chunk_index_at_cursor(self) ~= self.current_chunk then
    self:goto_chunk(self.current_chunk)
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
  -- Set by undoing an action on a file that had left the queue.
  local undo_return = self.undo_return
  self.undo_return = nil
  if not (ok and self.file_queue and (self.panel or undo_return)) then
    return
  end
  local entry = queue_host.current_entry(self)
  local path = undo_return and undo_return.path or (entry and entry.path)
  self:refresh_git_queue(path, {
    keep_loaded_file = not undo_return,
    stay_on = undo_return and entry and entry.path or nil,
    fallback_index = self.file_queue_index,
  })

  local shown = queue_host.current_entry(self)
  local on_path = shown and path and (shown.path == path or shown.old_path == path)
  if undo_return and on_path and undo_return.chunk then
    self:goto_chunk(undo_return.chunk)
  end
  if path and (undo_return or not on_path) then
    -- The pane shows another buffer now, so edits made from here count from it.
    actions.mark_undo_position(self, path)
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

function Session:undo_edit_or_action()
  if self.right and self.right.editable and vim.api.nvim_get_current_buf() == self.right_buf then
    local undo_seq = buffer_undo_seq(self.right_buf)
    local action_entry = actions.latest_undo(self)
    if action_entry
        and undo_seq ~= nil
        and action_entry.right_undo_seq == undo_seq
        and action_entry.right_undo_buf == self.right_buf then
      self:undo_action()
      return
    end
    if buffer_has_undo(self.right_buf) then
      local before_tick = vim.api.nvim_buf_get_changedtick(self.right_buf)
      local ok = pcall(vim.cmd, "silent undo")
      if ok and vim.api.nvim_buf_get_changedtick(self.right_buf) ~= before_tick then
        -- Record post-undo tick before re-diff so the TextChanged that follows
        -- undo is a no-op; a later real edit advances the tick and is not swallowed.
        self.suppress_editable_textchanged_tick = vim.api.nvim_buf_get_changedtick(self.right_buf)
        self:refresh_editable_right()
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
