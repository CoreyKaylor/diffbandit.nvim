local diff_mod = require("diffbandit.diff")
local view_builder = require("diffbandit.view")
local state = require("diffbandit.state")
local paths_mod = require("diffbandit.paths")

local Session = {}
Session.__index = Session

local function digits_of(count)
  return math.max(3, #tostring(math.max(1, count)))
end

local function format_line_number(num, width)
  if not num then
    return string.rep(" ", width)
  end
  local fmt = string.format("%%%dd", width)
  return string.format(fmt, num)
end

local function format_line_number_left(num, width)
  if not num then
    return string.rep(" ", width)
  end
  -- Left-align number (pad on right) so numbers expand rightward toward center
  local fmt = string.format("%%-%dd", width)
  return string.format(fmt, num)
end

local function build_display_lines(session)
  -- View arrays have different lengths; copy them so render-time scroll
  -- padding does not mutate the canonical diff view.
  local left_lines = vim.list_extend({}, session.view.left)
  local right_lines = vim.list_extend({}, session.view.right)
  local padding = session:get_scroll_padding()
  for _ = 1, padding do
    left_lines[#left_lines + 1] = ""
    right_lines[#right_lines + 1] = ""
  end
  return left_lines, right_lines
end

local function render_empty_source_notice(buf, namespace, source)
  if not source or not source.empty_reason or #(source.lines or {}) > 0 then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
    virt_text = { { "  " .. source.empty_reason, "DiffBanditEmptyNotice" } },
    virt_text_pos = "overlay",
    priority = 20,
  })
end

local function set_win_view_topline(win, topline)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  topline = math.max(1, topline or 1)
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
  local cursor_line = math.min(topline, line_count)
  pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    view.topline = topline
    pcall(vim.fn.winrestview, view)
  end)
end

local function get_win_view_topline(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 1
  end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if ok and view and view.topline then
    return view.topline
  end
  return 1
end

local function shallow_copy(tbl)
  local copy = {}
  for key, value in pairs(tbl) do
    copy[key] = value
  end
  return copy
end

local function set_buffer_options(buf, opts)
  for key, value in pairs(opts) do
    if value ~= nil then
      vim.api.nvim_buf_set_option(buf, key, value)
    end
  end
end

local function set_window_options(win, opts)
  for key, value in pairs(opts) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = win })
  end
end

local function set_window_width(win, width)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_width, win, math.max(1, width))
  end
end

local function build_view_for_sources(sources, config)
  local hunks, err = diff_mod.compute_hunks(sources.left.text, sources.right.text, config.diff)
  if err then
    return nil, err
  end

  local view = view_builder.build(sources.left.lines, sources.right.lines, hunks, config)
  return hunks, view
end

local function connector_core_base_width(view, config)
  local width = math.max(config.ui.connector_width or 0, 0)
  for _, text in ipairs(view.connectors) do
    local display_width = vim.fn.strdisplaywidth(text)
    if display_width > width then
      width = display_width
    end
  end
  return width
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
  self.current_chunk = view.chunks[1] and 1 or 0
  self.file_queue = opts.queue
  self.file_queue_index = opts.queue and (opts.queue.index or 1) or nil
  self.pending_file_boundary = nil
  self.left_number_width = math.max(2, digits_of(#sources.left.lines))
  self.right_number_width = digits_of(#sources.right.lines)
  self.right_number_padding = self.config.ui.right_number_padding or 2
  self.ns = vim.api.nvim_create_namespace("DiffBanditHighlights" .. self.id)
  self.active_ns = vim.api.nvim_create_namespace("DiffBanditActive" .. self.id)
  self.path_ns = vim.api.nvim_create_namespace("DiffBanditConnectorPaths" .. self.id)
  self.autocmd_group = nil
  self.disposed = false

  self.connector_core_width = connector_core_base_width(view, self.config)
  self.left_number_pane_width = self.left_number_width + 1
  self.right_number_pane_width = self.right_number_width + 1
  self.gutter_width = self.connector_core_width

  self:open_layout()
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

function Session:open_layout()
  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()
  self.tabnr = vim.api.nvim_tabpage_get_number(self.tabpage)

  -- Create buffers with basic options first (avoid bufhidden=wipe until in windows)
  local left_buf = vim.api.nvim_create_buf(false, true)
  local left_num_buf = vim.api.nvim_create_buf(false, true)
  local connector_buf = vim.api.nvim_create_buf(false, true)
  local right_num_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)

  self.left_buf = left_buf
  self.left_num_buf = left_num_buf
  self.connector_buf = connector_buf
  self.right_num_buf = right_num_buf
  self.right_buf = right_buf

  -- Set non-destructive options first
  set_buffer_options(left_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
    filetype = self.left.filetype,
  })

  set_buffer_options(right_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
    filetype = self.right.filetype,
  })

  set_buffer_options(left_num_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
  })

  set_buffer_options(connector_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
  })

  set_buffer_options(right_num_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
  })

  -- Put buffers in windows BEFORE setting bufhidden=wipe.
  -- Final order:
  -- LEFT CONTENT | LEFT NUMBERS | CONNECTOR | RIGHT NUMBERS | RIGHT CONTENT.
  -- nvim_open_win() split configs let gutter panes opt out of mouse/focus where
  -- the running Nvim supports it.

  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  local right_win = vim.api.nvim_open_win(right_buf, false, {
    split = "right",
    win = left_win,
  })
  vim.api.nvim_win_set_buf(right_win, right_buf)

  local function open_gutter_win(buf, anchor_win, width)
    local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
      split = "right",
      win = anchor_win,
      width = width,
      focusable = false,
      mouse = false,
    })
    if ok then
      return win
    end
    win = vim.api.nvim_open_win(buf, false, {
      split = "right",
      win = anchor_win,
      width = width,
    })
    return win
  end

  local left_num_win = open_gutter_win(left_num_buf, left_win, self.left_number_pane_width)
  local connector_win = open_gutter_win(connector_buf, left_num_win, self.connector_core_width)
  local right_num_win = open_gutter_win(right_num_buf, connector_win, self.right_number_pane_width)

  self.left_win = left_win
  self.left_num_win = left_num_win
  self.connector_win = connector_win
  self.right_num_win = right_num_win
  self.right_win = right_win

  local split_winhl = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit"
  local source_winhl = split_winhl .. ",CursorLine:DiffBanditCursorLine"
  local gutter_winhl = "Normal:DiffBanditConnectorContext,NormalNC:DiffBanditConnectorContext,"
    .. split_winhl .. ",CursorLine:DiffBanditCursorLine"

  set_window_options(left_win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = source_winhl,
  })

  set_window_options(left_num_win, {
    number = false,
    relativenumber = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
    winhl = gutter_winhl,
  })

  set_window_options(connector_win, {
    number = false,
    relativenumber = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
    winhl = gutter_winhl,
  })

  set_window_options(right_num_win, {
    number = false,
    relativenumber = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
    winhl = gutter_winhl,
  })

  set_window_options(right_win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = source_winhl,
  })

  self:resize_layout()

  -- Now that all buffers are displayed in windows, set bufhidden=wipe for cleanup
  set_buffer_options(left_buf, { bufhidden = "wipe" })
  set_buffer_options(left_num_buf, { bufhidden = "wipe" })
  set_buffer_options(connector_buf, { bufhidden = "wipe" })
  set_buffer_options(right_num_buf, { bufhidden = "wipe" })
  set_buffer_options(right_buf, { bufhidden = "wipe" })

  -- Set vertical split character to thin line
  vim.opt.fillchars:append({ vert = "│" })

  local navigation = self.config.navigation or {}
  local initial_focus = navigation.initial_focus == "left" and "left" or "right"
  local initial_win = initial_focus == "left" and self.left_win or self.right_win
  vim.api.nvim_set_current_win(initial_win)
  self.last_source_win = initial_win
  self.last_source_side = initial_focus

  local left_name = self.left.label or self.left.path or ""
  local right_name = self.right.label or self.right.path or ""
  self.title = string.format("DiffBandit: %s ↔ %s", left_name, right_name)
  vim.api.nvim_tabpage_set_var(self.tabpage, "diffbandit_title", self.title)
  vim.api.nvim_set_option_value("showtabline", 2, { scope = "global" })
end

function Session:resize_layout()
  local windows = {
    self.left_win,
    self.left_num_win,
    self.connector_win,
    self.right_num_win,
    self.right_win,
  }
  for _, win in ipairs(windows) do
    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end
  end

  set_window_width(self.left_num_win, self.left_number_pane_width)
  set_window_width(self.connector_win, self.connector_core_width)
  set_window_width(self.right_num_win, self.right_number_pane_width)

  local total_width = 0
  for _, win in ipairs(windows) do
    total_width = total_width + vim.api.nvim_win_get_width(win)
  end
  local separator_width = #windows - 1
  total_width = total_width + separator_width

  local fixed_width = self.left_number_pane_width + self.connector_core_width + self.right_number_pane_width
  local content_width = total_width - fixed_width - separator_width
  if content_width < 2 then
    return
  end

  local left_width = math.floor(content_width / 2)
  local right_width = content_width - left_width
  set_window_width(self.left_win, left_width)
  set_window_width(self.right_win, right_width)
  set_window_width(self.left_num_win, self.left_number_pane_width)
  set_window_width(self.connector_win, self.connector_core_width)
  set_window_width(self.right_num_win, self.right_number_pane_width)
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

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = self.left_buf,
    callback = function()
      self:dispose()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = self.right_buf,
    callback = function()
      self:dispose()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = self.left_num_buf,
    callback = function()
      self:dispose()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = self.right_num_buf,
    callback = function()
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
        self.last_source_win = self.right_win
        self.last_source_side = "right"
      elseif win == self.left_num_win or win == self.connector_win or win == self.right_num_win then
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
    callback = function()
      if self.syncing_scroll or self.rendering_viewport or self.disposed then
        return
      end
      self:sync_gutter_viewports()
      self:rerender_for_viewport()
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
    end,
  })
end

function Session:setup_keymaps()
  local opts = { nowait = true, noremap = true, silent = true }
  local function map(buf, lhs, rhs)
    vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { buffer = buf }))
  end
  local navigation = self.config.navigation or {}
  local document_keys = navigation.document_keys or {}
  local git_keys = ((self.config.git or {}).file_keys or {})

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
  end

  buffer_maps(self.left_buf)
  buffer_maps(self.right_buf)
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

function Session:set_viewport_toplines(left_topline, right_topline)
  set_win_view_topline(self.left_win, left_topline)
  set_win_view_topline(self.left_num_win, left_topline)
  set_win_view_topline(self.right_win, right_topline)
  set_win_view_topline(self.right_num_win, right_topline)
  set_win_view_topline(self.connector_win, left_topline or 1)
  self:rerender_for_viewport()
end

function Session:set_viewport_toplines_preserve_cursors(left_topline, right_topline, left_cursor, right_cursor)
  set_win_view_topline(self.left_win, left_topline)
  set_win_view_topline(self.left_num_win, left_topline)
  set_win_view_topline(self.right_win, right_topline)
  set_win_view_topline(self.right_num_win, right_topline)
  set_win_view_topline(self.connector_win, left_topline or 1)
  if left_cursor then
    pcall(vim.api.nvim_win_set_cursor, self.left_win, { left_cursor, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.left_num_win, { left_cursor, 0 })
  end
  if right_cursor then
    pcall(vim.api.nvim_win_set_cursor, self.right_win, { right_cursor, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.right_num_win, { right_cursor, 0 })
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

function Session:chunk_navigation_anchors(chunk)
  local meta_list = self.view and self.view.line_meta or {}
  local start_idx = chunk and chunk.display_start or 1
  local end_idx = chunk and chunk.display_end or start_idx
  local left_anchor
  local right_anchor

  if chunk and chunk.type == "add" then
    local origin_meta = meta_list[start_idx - 1]
    left_anchor = origin_meta and origin_meta.left_index or 1
    right_anchor = origin_meta and origin_meta.right_index or 1
  elseif chunk and chunk.type == "delete" then
    local _, left_meta = first_meta_index_with(meta_list, start_idx, end_idx, function(meta)
      return meta.left_index ~= nil
    end)
    left_anchor = left_meta and left_meta.left_index or nil
    local origin_meta = meta_list[start_idx - 1]
    right_anchor = origin_meta and origin_meta.right_index or 1
  else
    local _, left_meta = first_meta_index_with(meta_list, start_idx, end_idx, function(meta)
      return meta.left_index ~= nil
    end)
    local _, right_meta = first_meta_index_with(meta_list, start_idx, end_idx, function(meta)
      return meta.right_index ~= nil
    end)
    left_anchor = left_meta and left_meta.left_index or nil
    right_anchor = right_meta and right_meta.right_index or nil
  end

  if not left_anchor then
    local _, left_meta = first_meta_index_with(meta_list, start_idx, end_idx, function(meta)
      return meta.left_index ~= nil
    end)
    left_anchor = left_meta and left_meta.left_index or nil
  end
  if not right_anchor then
    local _, right_meta = first_meta_index_with(meta_list, start_idx, end_idx, function(meta)
      return meta.right_index ~= nil
    end)
    right_anchor = right_meta and right_meta.right_index or nil
  end

  return left_anchor, right_anchor
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

  self:set_viewport_toplines(left_topline, right_topline)

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

function Session:replace_sources(sources, opts)
  opts = opts or {}
  local hunks, view = build_view_for_sources(sources, self.config)
  if not hunks then
    return nil, view
  end

  self.left = sources.left
  self.right = sources.right
  self.hunks = hunks
  self.view = view
  self.current_chunk = view.chunks[1] and 1 or 0
  self.left_number_width = math.max(2, digits_of(#sources.left.lines))
  self.right_number_width = digits_of(#sources.right.lines)
  self.left_number_pane_width = self.left_number_width + 1
  self.right_number_pane_width = self.right_number_width + 1
  self.connector_core_width = connector_core_base_width(view, self.config)
  self.gutter_width = self.connector_core_width
  self:reset_pending_file_boundary()

  set_buffer_options(self.left_buf, { filetype = self.left.filetype })
  set_buffer_options(self.right_buf, { filetype = self.right.filetype })
  self:update_title()
  self:resize_layout()
  self:precompute_connector_core_width()
  self:render()

  pcall(vim.api.nvim_win_set_cursor, self.left_win, { 1, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.left_num_win, { 1, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.right_win, { 1, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.right_num_win, { 1, 0 })
  self:set_viewport_toplines_preserve_cursors(1, 1, 1, 1)

  if opts.chunk_position == "last" and #self.view.chunks > 0 then
    self:goto_chunk(#self.view.chunks)
  elseif #self.view.chunks > 0 then
    self:goto_chunk(1)
  else
    self:clear_active_chunk()
  end

  return true, nil
end

-- Highlight lookup tables for left/right/connector panes
local HIGHLIGHT_LEFT = {
  context = "DiffBanditContext",
  add = "DiffBanditAddLeft",
  delete = "DiffBanditDelete",
  change = { default = "DiffBanditChangeLeft", filler = "DiffBanditGap" },
}

local HIGHLIGHT_RIGHT = {
  context = "DiffBanditContext",
  add = { default = "DiffBanditAdd", filler = "DiffBanditGap" },
  delete = { default = "DiffBanditChangeRight", filler = "DiffBanditGap" },
  change = { default = "DiffBanditChangeRight", filler = "DiffBanditGap" },
}

local function get_highlight(tbl, meta, filler_key)
  local entry = tbl[meta.kind]
  if type(entry) == "table" then
    return meta[filler_key] and entry.filler or entry.default
  end
  return entry
end

local function highlight_for_left(meta)
  return get_highlight(HIGHLIGHT_LEFT, meta, "filler_left")
end

local function highlight_for_right(meta)
  return get_highlight(HIGHLIGHT_RIGHT, meta, "filler_right")
end

local function connector_line_highlight(kind)
  if kind == "add" then
    return "DiffBanditConnectorAddLine"
  end
  return "DiffBanditConnectorDeleteLine"
end

function Session:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
  left_topline = math.max(1, left_topline or 1)
  right_topline = math.max(1, right_topline or 1)
  left_height = math.max(1, left_height or 1)
  right_height = math.max(1, right_height or 1)
  local projected = {}

  local function right_to_connector_row(right_index)
    return left_topline + (right_index - right_topline)
  end

  local function delete_glyph_for_target(origin_row, target_row)
    return origin_row > target_row and "◣" or "◤"
  end

  local function change_glyph_for(side, row, other_row)
    if side == "right" then
      return other_row > row and "◢" or "◥"
    end
    return other_row > row and "◣" or "◤"
  end

  local function set_lane_occupancy(path, row_a, row_b)
    if not row_a or not row_b then
      return
    end
    local viewport_start = left_topline
    local viewport_end = left_topline + left_height - 1
    local start_row = math.max(viewport_start, math.min(row_a, row_b))
    local end_row = math.min(viewport_end, math.max(row_a, row_b))
    if start_row <= end_row then
      path.lane_occupancy_start = start_row
      path.lane_occupancy_end = end_row
    end
  end

  local function add_projected_path(path, target_index, glyph, show_triangle, suppress_tail)
    local projected_target = right_to_connector_row(target_index)
    local q = shallow_copy(path)
    q.route_group = path.route_group or path
    q.top = path.origin_left_index or path.origin_display_row
    q.origin_display_row = q.top
    q.display_start_row = projected_target
    q.display_end_row = projected_target
    q.triangle_display_row = projected_target
    q.target_start_index = target_index
    q.target_end_index = target_index
    q.approach = glyph == "◢" and "from_below" or "from_above"
    q.triangle_glyph = glyph
    q.connect_tail_on_triangle_row = path.kind == "add" and glyph == "◢" and show_triangle ~= false
    q.hide_triangle = show_triangle == false
    q.suppress_tail = suppress_tail == true
    set_lane_occupancy(q, q.origin_display_row, projected_target)
    projected[#projected + 1] = q
  end

  local function add_projected_delete_path(path, origin_row, target_index, glyph, show_triangle, suppress_tail)
    local q = shallow_copy(path)
    q.route_group = path.route_group or path
    q.top = origin_row
    q.origin_display_row = origin_row
    q.display_start_row = target_index
    q.display_end_row = target_index
    q.triangle_display_row = target_index
    q.target_start_index = target_index
    q.target_end_index = target_index
    q.approach = (glyph == "◣" or glyph == "◥") and "from_below" or "from_above"
    q.triangle_glyph = glyph
    q.connect_tail_on_triangle_row = (glyph == "◣" or glyph == "◥") and show_triangle ~= false
    q.hide_triangle = show_triangle == false
    q.suppress_tail = suppress_tail == true
    set_lane_occupancy(q, origin_row, target_index)
    projected[#projected + 1] = q
  end

  local function add_change_link(links, from_side, from_row, to_side, to_row, show_from, show_to, from_glyph, to_glyph, no_vertical, underline_row)
    if not from_row or not to_row then
      return
    end

    links[#links + 1] = {
      from_side = from_side,
      from_row = from_row,
      from_glyph = from_glyph or change_glyph_for(from_side, from_row, to_row),
      from_visible = show_from ~= false,
      to_side = to_side,
      to_row = to_row,
      to_glyph = to_glyph or change_glyph_for(to_side, to_row, from_row),
      to_visible = show_to ~= false,
      no_vertical = no_vertical == true,
      underline_row = underline_row,
    }
  end

  local function add_change_edge(edges, side, row, overlap_row)
    if not row or not overlap_row then
      return
    end
    edges[#edges + 1] = {
      side = side,
      row = row,
      glyph = change_glyph_for(side, row, overlap_row),
    }
  end

  local function set_change_lane_occupancy(path)
    local start_row, end_row
    local viewport_start = left_topline
    local viewport_end = left_topline + left_height - 1
    local function include_row(row)
      if not row then
        return
      end
      row = math.max(viewport_start, math.min(viewport_end, row))
      start_row = start_row and math.min(start_row, row) or row
      end_row = end_row and math.max(end_row, row) or row
    end

    for _, link in ipairs(path.viewport_change_links or {}) do
      include_row(link.from_row)
      include_row(link.to_row)
    end
    for _, edge in ipairs(path.viewport_change_edges or {}) do
      include_row(edge.row)
    end

    if start_row and end_row then
      path.lane_occupancy_start = start_row
      path.lane_occupancy_end = end_row
    end
  end

  local function project_change_path(path)
    local q = shallow_copy(path)
    q.route_group = path.route_group or path
    q.viewport_change_links = {}
    q.viewport_change_edges = {}

    if not (path.start_left_index and path.end_left_index
        and path.start_right_index and path.end_right_index) then
      return q
    end

    local left_visible_start = math.max(path.start_left_index, left_topline)
    local left_visible_end = math.min(path.end_left_index, left_topline + left_height - 1)
    local right_visible_index_start = math.max(path.start_right_index, right_topline)
    local right_visible_index_end = math.min(path.end_right_index, right_topline + right_height - 1)

    if left_visible_start <= left_visible_end then
      q.viewport_left_start = left_visible_start
      q.viewport_left_end = left_visible_end
    end
    if right_visible_index_start <= right_visible_index_end then
      q.viewport_right_index_start = right_visible_index_start
      q.viewport_right_index_end = right_visible_index_end
      q.viewport_right_start = right_to_connector_row(right_visible_index_start)
      q.viewport_right_end = right_to_connector_row(right_visible_index_end)
    end

    local ls, le = q.viewport_left_start, q.viewport_left_end
    local rs, re = q.viewport_right_start, q.viewport_right_end
    if ls and le and rs and re then
      local overlap_start = math.max(ls, rs)
      local overlap_end = math.min(le, re)
      if overlap_start <= overlap_end then
        q.viewport_solid_start = overlap_start
        q.viewport_solid_end = overlap_end

        if rs < overlap_start then
          local edge_row = overlap_start - 1
          add_change_edge(q.viewport_change_edges, "right", edge_row, overlap_start)
        end
        if ls < overlap_start then
          local edge_row = overlap_start - 1
          add_change_edge(q.viewport_change_edges, "left", edge_row, overlap_start)
        end
        if re > overlap_end then
          local edge_row = overlap_end + 1
          add_change_edge(q.viewport_change_edges, "right", edge_row, overlap_end)
        end
        if le > overlap_end then
          local edge_row = overlap_end + 1
          add_change_edge(q.viewport_change_edges, "left", edge_row, overlap_end)
        end
      elseif re < ls then
        if re + 1 == ls then
          add_change_link(q.viewport_change_links, "right", re, "left", ls, true, true,
            change_glyph_for("right", re, ls), change_glyph_for("left", ls, re), true, re)
        else
          add_change_link(q.viewport_change_links, "right", re, "left", ls, true, true)
        end
      elseif le < rs then
        if le + 1 == rs then
          add_change_link(q.viewport_change_links, "left", le, "right", rs, true, true,
            change_glyph_for("left", le, rs), change_glyph_for("right", rs, le), true, le)
        else
          add_change_link(q.viewport_change_links, "left", le, "right", rs, true, true)
        end
      end
    elseif ls and le then
      local projected_right_start = right_to_connector_row(path.start_right_index)
      local projected_right_end = right_to_connector_row(path.end_right_index)
      if projected_right_end < ls then
        add_change_link(q.viewport_change_links, "left", ls, "right", left_topline - 1, true, false,
          nil, nil, false, math.max(left_topline, ls - 1))
      elseif projected_right_start > le then
        add_change_link(q.viewport_change_links, "left", le, "right", left_topline + left_height, true, false,
          nil, nil, false, math.max(left_topline, le - 1))
      end
    elseif rs and re then
      if path.end_left_index < rs then
        add_change_link(q.viewport_change_links, "right", rs, "left", left_topline - 1, true, false,
          nil, nil, false, math.max(left_topline, rs - 1))
      elseif path.start_left_index > re then
        add_change_link(q.viewport_change_links, "right", re, "left", left_topline + left_height, true, false,
          nil, nil, false, math.max(left_topline, re - 1))
      end
    end

    set_change_lane_occupancy(q)
    return q
  end

  for _, p in ipairs(paths) do
    if p.kind == "add" and not p.embedded_in_change then
      local origin_row = p.origin_left_index or p.origin_display_row
      local block_start = p.target_start_index or p.triangle_display_row or p.display_start_row
      local block_end = p.target_end_index or block_start
      if origin_row and block_start and block_end then
        local origin_visible = origin_row >= left_topline and origin_row <= (left_topline + left_height - 1)
        local visible_start = math.max(block_start, right_topline)
        local visible_end = math.min(block_end, right_topline + right_height - 1)
        if visible_start > visible_end then
          if origin_visible then
            if block_start > right_topline + right_height - 1 then
              add_projected_path(p, right_topline + right_height, "◥", false, true)
            elseif block_end < right_topline then
              add_projected_path(p, right_topline - 1, "◢", false, true)
            end
          end
        else
          local visible_start_row = right_to_connector_row(visible_start)
          local visible_end_row = right_to_connector_row(visible_end)
          local right_index_at_origin = right_topline + (origin_row - left_topline)

          if not origin_visible then
            local target = block_start
            if visible_end_row < origin_row then
              target = visible_end
            elseif visible_start_row > origin_row then
              target = visible_start
            end
            add_projected_path(p, target, visible_start_row < origin_row and "◢" or "◥", false)
          elseif visible_start_row > origin_row then
            add_projected_path(p, visible_start, "◥", true)
          elseif visible_end_row < origin_row then
            add_projected_path(p, visible_end, "◢", true)
          else
            local target_above
            local target_below
            if visible_start_row == origin_row then
              target_above = visible_start
              target_below = visible_start + 1
            else
              target_above = right_index_at_origin
              target_below = right_index_at_origin + 1
            end

            if target_above >= visible_start and target_above <= visible_end then
              add_projected_path(p, target_above, "◢", true)
            end
            if target_below >= visible_start and target_below <= visible_end then
              add_projected_path(p, target_below, "◥", true)
            end
          end
        end
      end
    elseif p.kind == "delete" then
      local origin_row = p.origin_right_index and right_to_connector_row(p.origin_right_index) or p.origin_display_row
      local block_start = p.target_start_index or p.triangle_display_row or p.display_start_row
      local block_end = p.target_end_index or block_start
      if origin_row and block_start and block_end then
        local origin_visible = origin_row >= left_topline and origin_row <= (left_topline + left_height - 1)
        local visible_start = math.max(block_start, left_topline)
        local visible_end = math.min(block_end, left_topline + left_height - 1)
        if visible_start > visible_end then
          if origin_visible then
            if block_start > left_topline + left_height - 1 then
              local target = left_topline + left_height
              add_projected_delete_path(p, origin_row, target, delete_glyph_for_target(origin_row, target), false, true)
            elseif block_end < left_topline then
              local target = left_topline - 1
              add_projected_delete_path(p, origin_row, target, delete_glyph_for_target(origin_row, target), false, true)
            end
          end
        elseif not origin_visible then
          local target = block_start
          if visible_end < origin_row then
            target = visible_end
          elseif visible_start > origin_row then
            target = visible_start
          end
          add_projected_delete_path(p, origin_row, target, delete_glyph_for_target(origin_row, target), true)
        elseif visible_start > origin_row then
          add_projected_delete_path(p, origin_row, visible_start, "◤", true)
        elseif visible_end < origin_row then
          add_projected_delete_path(p, origin_row, visible_end, "◣", true)
        else
          local target_above
          local target_below
          if visible_start == origin_row then
            target_above = visible_start
            target_below = visible_start + 1
          else
            target_above = origin_row
            target_below = origin_row + 1
          end

          if target_above >= visible_start and target_above <= visible_end then
            add_projected_delete_path(p, origin_row, target_above, "◣", true)
          end
          if target_below >= visible_start and target_below <= visible_end then
            add_projected_delete_path(p, origin_row, target_below, "◤", true)
          end
        end
      end
    elseif p.kind == "change" then
      projected[#projected + 1] = project_change_path(p)
    else
      local q = shallow_copy(p)
      q.route_group = p.route_group or p
      projected[#projected + 1] = q
    end
  end

  paths_mod.assign_lanes(projected)
  return projected
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

local function add_topline_candidate(candidates, index, height, line_count)
  if not index then
    return
  end
  local max_topline = math.max(1, line_count)
  for screen_row = 1, height do
    local topline = index - screen_row + 1
    if topline >= 1 and topline <= max_topline then
      candidates[topline] = true
    end
  end
end

function Session:precompute_connector_core_width()
  local paths = paths_mod.compute_paths(self.view.chunks, self.view.line_meta)
  local minimum_width = self.connector_core_width
  local required_core = minimum_width

  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
  local padding = self:get_scroll_padding()
  local left_line_count = math.max(1, #self.view.left + padding)
  local right_line_count = math.max(1, #self.view.right + padding)
  local left_candidates = { [1] = true, [left_line_count] = true }
  local right_candidates = { [1] = true, [right_line_count] = true }

  for _, p in ipairs(paths) do
    if p.kind == "add" then
      add_topline_candidate(left_candidates, p.origin_left_index or p.origin_display_row, left_height, left_line_count)
      add_topline_candidate(right_candidates, p.target_start_index or p.display_start_row, right_height, right_line_count)
      add_topline_candidate(right_candidates, p.target_end_index or p.display_end_row, right_height, right_line_count)
    elseif p.kind == "delete" then
      add_topline_candidate(left_candidates, p.target_start_index or p.display_start_row, left_height, left_line_count)
      add_topline_candidate(left_candidates, p.target_end_index or p.display_end_row, left_height, left_line_count)
      add_topline_candidate(right_candidates, p.origin_right_index or p.origin_display_row, right_height, right_line_count)
    elseif p.kind == "change" then
      add_topline_candidate(left_candidates, p.start_left_index or p.display_start_row, left_height, left_line_count)
      add_topline_candidate(left_candidates, p.end_left_index or p.display_end_row, left_height, left_line_count)
      add_topline_candidate(right_candidates, p.start_right_index or p.display_start_row, right_height, right_line_count)
      add_topline_candidate(right_candidates, p.end_right_index or p.display_end_row, right_height, right_line_count)
    end
  end

  local left_toplines = sorted_keys(left_candidates)
  local right_toplines = sorted_keys(right_candidates)
  for _, left_topline in ipairs(left_toplines) do
    for _, right_topline in ipairs(right_toplines) do
      local projected = self:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
      required_core = paths_mod.required_connector_core_width(paths_mod.max_lane(projected), required_core)
    end
  end

  if required_core > self.connector_core_width then
    self.connector_core_width = required_core
    self.gutter_width = required_core
    self:resize_layout()
  end

  return required_core
end

function Session:render()
  set_buffer_options(self.left_buf, { modifiable = true })
  set_buffer_options(self.left_num_buf, { modifiable = true })
  set_buffer_options(self.right_buf, { modifiable = true })
  set_buffer_options(self.right_num_buf, { modifiable = true })
  set_buffer_options(self.connector_buf, { modifiable = true })

  local left_lines, right_lines = build_display_lines(self)
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)

  -- Compute connector routing lanes using extracted paths module
  local paths = paths_mod.compute_paths(self.view.chunks, self.view.line_meta)
  local route_paths = self:project_paths_for_viewport(paths)
  local route_plan = paths_mod.plan_routes(route_paths, {
    connector_core_width = self.connector_core_width,
    viewport_topline = left_topline,
    viewport_height = left_height,
  })

  -- Build active_vertical_bars[row][lane] tracking which lanes have active bars at each row
  local active_vertical_bars = paths_mod.compute_active_bars(route_paths)

  -- Define positioning functions now that connector_core_width is finalized
  -- Glyphs are positioned per lane with indentation; vertical bars (rails) sit to the left
  local rail_spacing = 1
  local glyph_base_col = self.connector_core_width - 1
  local function rail_col_for_lane(lane)
    local idx = math.max(0, lane - 1)
    return glyph_base_col - (idx * (rail_spacing + 1)) - 1
  end
  local function lane_col(lane)
    return rail_col_for_lane(lane)
  end
  local function delete_lane_col(lane)
    local idx = math.max(0, lane - 1)
    return 1 + (idx * (rail_spacing + 1))
  end
  local default_change_rail_col = math.max(2, math.floor(self.connector_core_width / 3))
  local use_lane_bound_change_rails = #route_paths >= 5
  local has_projected_change_path = false
  for _, p in ipairs(route_paths) do
    if p.kind == "change" then
      has_projected_change_path = true
      break
    end
  end

  local function is_clipped_change_path(path)
    if not path or path.kind ~= "change" then
      return false
    end
    for _, link in ipairs(path.viewport_change_links or {}) do
      if link.from_visible == false or link.to_visible == false then
        return true
      end
    end
    return false
  end

  local function change_rail_col_for_path(path)
    if path and path.planned_rail_col ~= nil then
      return path.planned_rail_col
    end
    if path and path.lane and path.lane > 0 then
      if not use_lane_bound_change_rails
          and path.kind == "change"
          and path.mixed_add
          and path.lane == 1 then
        return math.min(self.connector_core_width - 1, default_change_rail_col + 1)
      end
      local col = delete_lane_col(path.lane)
      if is_clipped_change_path(path) and path.lane > 1 then
        col = math.min(self.connector_core_width - 1, col + 2)
      end
      return col
    end
    return default_change_rail_col
  end

  -- Compute underline data using extracted helper
  local underline_layout = {
    left_number_width = 0,
    connector_core_width = self.connector_core_width,
    rail_spacing = 1,
    sidecar_numbers = true,
  }
  local underline_data = paths_mod.compute_underlines(route_paths, active_vertical_bars, underline_layout)
  local origin_glyph_cols = underline_data.origin_glyph_cols
  local origin_bar_cols = underline_data.origin_bar_cols
  local origin_has_bar = underline_data.origin_has_bar
  local tail_underlines = underline_data.tail_underlines
  local delete_origin_right_lines = underline_data.delete_origin_right_lines or {}
  local add_origin_row_has_transition = {}
  local delete_target_rows = {}
  for _, p in ipairs(route_paths) do
    if p.kind == "add"
        and not p.embedded_in_change
        and not p.hide_triangle
        and not p.overflow_hidden
        and p.origin_display_row
        and (p.triangle_display_row or p.display_start_row) == p.origin_display_row then
      add_origin_row_has_transition[p.origin_display_row] = true
    end
    if p.kind == "delete" and not p.hide_triangle and not p.overflow_hidden then
      local target_start = p.block_display_start or p.target_start_index or p.display_start_row or p.triangle_display_row
      local target_end = p.block_display_end or p.target_end_index or p.display_end_row or target_start
      if target_start and target_end then
        for target_row = target_start, target_end do
          delete_target_rows[target_row] = true
        end
      end
    end
  end
  local embedded_add_terminal_right_indexes = {}
  local embedded_add_origin_left_indexes = {}
  local change_number_left_indexes = {}
  local change_number_right_indexes = {}
  local solid_change_number_left_indexes = {}
  local solid_change_number_right_indexes = {}
  for _, p in ipairs(paths) do
    if p.kind == "add" and p.embedded_in_change then
      if p.origin_left_index then
        embedded_add_origin_left_indexes[p.origin_left_index] = true
      end
      if p.target_start_index and p.target_end_index then
        embedded_add_terminal_right_indexes[p.target_end_index] = true
      end
    elseif p.kind == "change" then
      if p.start_left_index and p.end_left_index then
        for row = p.start_left_index, p.end_left_index do
          change_number_left_indexes[row] = true
        end
      end
      if p.start_right_index and p.end_right_index then
        for row = p.start_right_index, p.end_right_index do
          change_number_right_indexes[row] = true
        end
      end
    end
  end
  for _, p in ipairs(route_paths) do
    if p.kind == "change" and p.viewport_solid_start and p.viewport_solid_end then
      for row = p.viewport_solid_start, p.viewport_solid_end do
        if row >= left_topline then
          solid_change_number_left_indexes[row] = true
          local right_index = right_topline + (row - left_topline)
          if right_index >= 1 then
            solid_change_number_right_indexes[right_index] = true
          end
        end
      end
    end
  end

  -- The connector buffer owns the aligned display model and must include the
  -- same scroll padding as the source panes so routes can remain visible while
  -- either side is scrolled past real EOF.
  local connector_height = math.max(#self.view.line_meta, #left_lines, #right_lines)
  local connector_lines = {}
  for i = 1, connector_height do
    -- Initialize with spaces for the full gutter width
    connector_lines[i] = string.rep(" ", self.gutter_width)
  end

  local change_vertical_cols_by_row = {}
  local function reserve_change_vertical(row, rail_col)
    if row >= 1 and row <= connector_height then
      change_vertical_cols_by_row[row] = change_vertical_cols_by_row[row] or {}
      change_vertical_cols_by_row[row][rail_col] = true
    end
  end

  for _, p in ipairs(route_paths) do
    if p.kind == "change" then
      local rail_col = change_rail_col_for_path(p)
      for _, link in ipairs(p.viewport_change_links or {}) do
        if not link.overflow_hidden and not link.no_vertical then
          local start_row = math.min(link.from_row, link.to_row) + 1
          local end_row = math.max(link.from_row, link.to_row) - 1
          for row = start_row, end_row do
            reserve_change_vertical(row, rail_col)
          end
        end
      end
    end
  end

  local function each_active_vertical_bar(lanes_at_row, callback)
    if not lanes_at_row then
      return
    end
    if lanes_at_row.__items then
      for _, item in ipairs(lanes_at_row.__items) do
        callback(item.lane, item.path)
      end
      return
    end
    for lane, path in pairs(lanes_at_row) do
      if type(lane) == "number" then
        callback(lane, path)
      end
    end
  end

  local function route_bar_col(path, lane)
    if path and path.planned_rail_col ~= nil then
      return path.planned_rail_col
    end
    if path and path.kind == "delete" then
      return delete_lane_col(lane)
    end
    return lane_col(lane)
  end

  local function route_key(kind, lane)
    return tostring(kind or "add") .. ":" .. tostring(lane or 1)
  end

  local function build_rendered_active_bars()
    local rendered_bars = {}
    local glyph_rows_by_lane = {}
    local visible_glyph_rows_by_kind = {}

    local function add_rendered_bar(row, lane, path)
      rendered_bars[row] = rendered_bars[row] or {}
      local row_bars = rendered_bars[row]
      row_bars.__items = row_bars.__items or {}
      row_bars.__items[#row_bars.__items + 1] = {
        lane = lane,
        path = path,
        fg_group = connector_line_highlight(path.kind),
      }
    end

    for _, p in ipairs(route_paths) do
      if (p.kind == "add" or p.kind == "delete")
          and not p.embedded_in_change
          and not p.hide_triangle
          and not p.overflow_hidden then
        local lane = p.lane or 1
        local key = route_key(p.kind, lane)
        glyph_rows_by_lane[key] = glyph_rows_by_lane[key] or {}
        glyph_rows_by_lane[key][p.triangle_display_row or p.display_start_row or p.start_row] = true
        local glyph_row = p.triangle_display_row or p.display_start_row or p.start_row
        visible_glyph_rows_by_kind[glyph_row] = visible_glyph_rows_by_kind[glyph_row] or {}
        visible_glyph_rows_by_kind[glyph_row][p.kind] = true
      end
    end

    for row, lanes_at_row in pairs(active_vertical_bars) do
      each_active_vertical_bar(lanes_at_row, function(lane, p)
        local key = route_key(p.kind, lane)
        local lane_has_glyph = glyph_rows_by_lane[key] and glyph_rows_by_lane[key][row]
        if not lane_has_glyph or p.connect_tail_on_triangle_row then
          local render_lane = lane
          if p.kind == "delete"
              and p.hide_triangle
              and lane == 1
              and visible_glyph_rows_by_kind[row]
              and visible_glyph_rows_by_kind[row].delete then
            render_lane = lane + 1
          end
          add_rendered_bar(row, render_lane, p)
        end
      end)
    end

    return rendered_bars
  end

  local active_bars = build_rendered_active_bars()

  local function occupied_route_cols(row)
    local occupied = {}
    local function reserve_col(col, with_spacer)
      if with_spacer then
        occupied[col - 1] = true
        occupied[col] = true
        occupied[col + 1] = true
      else
        occupied[col] = true
      end
    end
    local lanes_at_row = active_bars[row]
    each_active_vertical_bar(lanes_at_row, function(lane, path)
      reserve_col(route_bar_col(path, lane), false)
    end)
    if change_vertical_cols_by_row[row] then
      for col, _ in pairs(change_vertical_cols_by_row[row]) do
        reserve_col(col, true)
      end
    end
    return occupied
  end

  local function occupied_route_cols_for_span(row, start_row, end_row)
    local occupied = occupied_route_cols(row)
    if not start_row or not end_row then
      return occupied
    end
    local function reserve_route_bar(path, col)
      if path and (path.kind == "add" or path.kind == "delete") then
        occupied[col - 1] = true
        occupied[col] = true
        occupied[col + 1] = true
      else
        occupied[col] = true
      end
    end
    local span_start = math.max(1, math.min(start_row, end_row))
    local span_end = math.min(connector_height, math.max(start_row, end_row))
    for span_row = span_start, span_end do
      each_active_vertical_bar(active_bars[span_row], function(lane, path)
        reserve_route_bar(path, route_bar_col(path, lane))
      end)
      each_active_vertical_bar(active_vertical_bars[span_row], function(lane, path)
        reserve_route_bar(path, route_bar_col(path, lane))
      end)
    end
    return occupied
  end

  local function render_connector_underline_run(row, start_col, end_col, hl_group, occupied, namespace)
    if row < 1 or row > connector_height or end_col < start_col then
      return
    end
    namespace = namespace or self.path_ns
    start_col = math.max(0, start_col)
    end_col = math.min(self.connector_core_width - 1, end_col)
    if end_col < start_col then
      return
    end

    local run_start = nil
    for col = start_col, end_col do
      if occupied and occupied[col] then
        if run_start and col > run_start then
          vim.api.nvim_buf_set_extmark(self.connector_buf, namespace, row - 1, run_start, {
            virt_text = { { string.rep(" ", col - run_start), hl_group } },
            virt_text_pos = "overlay",
          })
        end
        run_start = nil
      elseif not run_start then
        run_start = col
      end
    end
    if run_start and end_col >= run_start then
      vim.api.nvim_buf_set_extmark(self.connector_buf, namespace, row - 1, run_start, {
        virt_text = { { string.rep(" ", end_col - run_start + 1), hl_group } },
        virt_text_pos = "overlay",
      })
    end
  end

  local function endpoint_underline_row(side, row, glyph)
    if side == "left" and glyph == "◤" then
      return math.max(left_topline, row - 1)
    end
    if side == "right" and glyph == "◥" then
      return math.max(left_topline, row - 1)
    end
    return row
  end

  local change_horizontal_cols_by_row = {}
  local function reserve_change_horizontal(row, side, rail_col)
    if row < 1 or row > connector_height then
      return
    end
    local start_col, end_col
    if side == "left" then
      start_col = 0
      end_col = rail_col - 1
    else
      start_col = math.min(self.connector_core_width - 1, rail_col + 1)
      end_col = self.connector_core_width - 1
    end
    if end_col < start_col then
      return
    end
    change_horizontal_cols_by_row[row] = change_horizontal_cols_by_row[row] or {}
    for col = start_col, end_col do
      change_horizontal_cols_by_row[row][col] = true
    end
  end

  for _, p in ipairs(route_paths) do
    if p.kind == "change" and p.viewport_change_links then
      local rail_col = change_rail_col_for_path(p)
      for _, link in ipairs(p.viewport_change_links) do
        if not link.overflow_hidden and link.from_visible then
          local row = link.underline_row
            or endpoint_underline_row(link.from_side, link.from_row, link.from_glyph)
          reserve_change_horizontal(row, link.from_side, rail_col)
        end
        if not link.overflow_hidden and link.to_visible then
          local row = link.underline_row
            or endpoint_underline_row(link.to_side, link.to_row, link.to_glyph)
          reserve_change_horizontal(row, link.to_side, rail_col)
        end
      end
    end
  end

  local same_row_horizontal_cols_by_row = {}

  local function reserve_same_row_horizontal(row, start_col, end_col)
    if row < 1 or row > connector_height or end_col < start_col then
      return
    end
    same_row_horizontal_cols_by_row[row] = same_row_horizontal_cols_by_row[row] or {}
    start_col = math.max(0, start_col - 1)
    end_col = math.min(self.connector_core_width - 1, end_col + 1)
    for col = start_col, end_col do
      same_row_horizontal_cols_by_row[row][col] = true
    end
  end

  local function leftmost_same_row_horizontal(row)
    local cols = same_row_horizontal_cols_by_row[row]
    local leftmost
    for col, _ in pairs(cols or {}) do
      if not leftmost or col < leftmost then
        leftmost = col
      end
    end
    return leftmost
  end

  local function rightmost_same_row_horizontal(row)
    local cols = same_row_horizontal_cols_by_row[row]
    local rightmost
    for col, _ in pairs(cols or {}) do
      if not rightmost or col > rightmost then
        rightmost = col
      end
    end
    return rightmost
  end

  local function occupied_underline_cols(row)
    local occupied = occupied_route_cols(row)
    if change_horizontal_cols_by_row[row] then
      for col, _ in pairs(change_horizontal_cols_by_row[row]) do
        occupied[col] = true
      end
    end
    if same_row_horizontal_cols_by_row[row] then
      for col, _ in pairs(same_row_horizontal_cols_by_row[row]) do
        occupied[col] = true
      end
    end
    return occupied
  end

  -- Left and right buffers now have different line counts
  local left_num_lines = {}
  for i = 1, #left_lines do
    left_num_lines[i] = string.rep(" ", self.left_number_pane_width)
  end
  local right_num_lines = {}
  for i = 1, #right_lines do
    right_num_lines[i] = string.rep(" ", self.right_number_pane_width)
  end
  for _, meta in ipairs(self.view.line_meta) do
    if meta.left_index then
      left_num_lines[meta.left_index] = format_line_number(meta.left_line, self.left_number_width) .. " "
    end
    if meta.right_index then
      right_num_lines[meta.right_index] = " " .. format_line_number_left(meta.right_line, self.right_number_width)
    end
  end

  vim.api.nvim_buf_set_lines(self.left_buf, 0, -1, false, left_lines)
  vim.api.nvim_buf_set_lines(self.left_num_buf, 0, -1, false, left_num_lines)
  vim.api.nvim_buf_set_lines(self.right_buf, 0, -1, false, right_lines)
  vim.api.nvim_buf_set_lines(self.right_num_buf, 0, -1, false, right_num_lines)
  vim.api.nvim_buf_set_lines(self.connector_buf, 0, -1, false, connector_lines)

  set_buffer_options(self.left_buf, { modifiable = false })
  set_buffer_options(self.left_num_buf, { modifiable = false })
  set_buffer_options(self.right_buf, { modifiable = false })
  set_buffer_options(self.right_num_buf, { modifiable = false })
  set_buffer_options(self.connector_buf, { modifiable = false })

  vim.api.nvim_buf_clear_namespace(self.left_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.ns, 0, -1)

  -- Clear extmark namespace for full-width backgrounds
  self.extmark_ns = self.extmark_ns or vim.api.nvim_create_namespace("DiffBanditExtmarks" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.extmark_ns, 0, -1)

  -- Clear namespace for line number virtual text
  self.linenum_ns = self.linenum_ns or vim.api.nvim_create_namespace("DiffBanditLineNums" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.linenum_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.linenum_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.linenum_ns, 0, -1)

  render_empty_source_notice(self.left_buf, self.extmark_ns, self.left)
  render_empty_source_notice(self.right_buf, self.extmark_ns, self.right)

  -- Apply highlights to left and right buffers (pane-wide backgrounds)
  for _, meta in ipairs(self.view.line_meta) do
    local left_hl = highlight_for_left(meta)
    local right_hl = highlight_for_right(meta)
    local final_left_hl = left_hl
    local final_right_hl = right_hl

    if meta.filler_left and meta.kind ~= "context" then
      final_left_hl = "DiffBanditPlaceholder"
    end

    if meta.filler_right and meta.kind ~= "context" then
      final_right_hl = "DiffBanditPlaceholder"
    end

    -- IMPORTANT: do NOT apply a full-line background on change lines.
    -- Range extmarks below own those rows so intra-line emphasis can override
    -- the base change background on both panes.
    local skip_left_line_hl = (meta.kind == "change" and not meta.filler_left)
    if final_left_hl and meta.left_index and not skip_left_line_hl then
      local left_row = meta.left_index - 1
      vim.api.nvim_buf_set_extmark(self.left_buf, self.extmark_ns, left_row, 0, {
        line_hl_group = final_left_hl,
        hl_mode = "combine",
      })
    end
    local skip_right_line_hl = (meta.kind == "change" and not meta.filler_right)
    if final_right_hl and meta.right_index and not skip_right_line_hl then
      local right_row = meta.right_index - 1
      vim.api.nvim_buf_set_extmark(self.right_buf, self.extmark_ns, right_row, 0, {
        line_hl_group = final_right_hl,
        hl_mode = "combine",
      })
    end
  end

  -- Apply connector backgrounds and number-pane styling on the same compact
  -- rows as their owner buffers.
  local ctx_hl = "DiffBanditConnectorContext"

  local function right_index_to_connector_row(right_index)
    return left_topline + (right_index - right_topline)
  end

  for row = 0, connector_height - 1 do
    vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, ctx_hl, row, 0, -1)
  end

  local function add_origin_core_underline(origin_row, row, meta)
    if meta.origin == "add" then
      if row < 0 or row >= connector_height then
        return
      end
      vim.api.nvim_buf_set_extmark(self.left_num_buf, self.linenum_ns, row, self.left_number_width, {
        virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
        virt_text_pos = "overlay",
      })
      local right_index_at_row = right_topline + ((row + 1) - left_topline)
      if add_origin_row_has_transition[origin_row]
          and right_index_at_row >= 1
          and right_index_at_row <= #right_lines then
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.linenum_ns, right_index_at_row - 1, 0, {
          virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
          virt_text_pos = "overlay",
        })
      end
    end
  end

  local function set_delete_origin_core(row, right_line)
    local del_info = delete_origin_right_lines[right_line]
    if not del_info then
      return
    end
    if row < 0 or row >= connector_height then
      return
    end
    if delete_target_rows[row + 1] and del_info.origin_display_row ~= row + 1 then
      return
    end
  end

  for idx, meta in ipairs(self.view.line_meta) do
    if meta.left_index then
      local row = meta.left_index - 1

      local left_num_hl
      if meta.origin == "add" and not embedded_add_origin_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftUnderline"
      elseif meta.kind == "delete" then
        left_num_hl = "DiffBanditLineNumberLeftDelete"
      elseif change_number_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftChange"
      else
        left_num_hl = "DiffBanditLineNumberLeft"
      end

      vim.api.nvim_buf_add_highlight(self.left_num_buf, self.linenum_ns, left_num_hl, row, 0, self.left_number_width)
      if meta.kind == "delete" then
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorDelete", row, 0, self.left_number_width)
      elseif change_number_left_indexes[meta.left_index] then
        local end_col = solid_change_number_left_indexes[meta.left_index] and -1 or self.left_number_width
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorChange", row, 0, end_col)
      end
      if not embedded_add_origin_left_indexes[meta.left_index] then
        add_origin_core_underline(meta.left_index, row, meta)
      end
    end

    if meta.right_index then
      local row = meta.right_index - 1

      local is_delete_origin = meta.right_line and delete_origin_right_lines[meta.right_line] ~= nil
      local right_num_hl
      if is_delete_origin then
        right_num_hl = "DiffBanditLineNumberRightUnderline"
      elseif change_number_right_indexes[meta.right_index] then
        right_num_hl = "DiffBanditLineNumberRightChange"
      elseif meta.kind == "add" then
        right_num_hl = "DiffBanditLineNumberRightAdd"
      else
        right_num_hl = "DiffBanditLineNumberRight"
      end

      if is_delete_origin then
        local connector_row = right_index_to_connector_row(meta.right_index) - 1
        set_delete_origin_core(connector_row, meta.right_line)
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.linenum_ns, row, 0, {
          virt_text = { { " ", "DiffBanditDeleteRightSeparatorConnector" } },
          virt_text_pos = "overlay",
        })
      end

      vim.api.nvim_buf_add_highlight(self.right_num_buf, self.linenum_ns, right_num_hl, row, 1, -1)
      if change_number_right_indexes[meta.right_index] then
        local start_col = solid_change_number_right_indexes[meta.right_index] and 0 or 1
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorChange", row, start_col, -1)
      elseif meta.kind == "add" then
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorAdd", row, 1, -1)
      end
    end
  end

  -- Apply route-owned backgrounds. Add/delete fill now belongs to the
  -- sidecar number panes; the connector core is reserved for routes.
  for _, p in ipairs(paths) do
    if p.kind == "add" and not p.embedded_in_change then
      for right_index = p.target_start_index or p.display_start_row, p.target_end_index or p.display_end_row do
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorAdd", right_index - 1, 1, -1)
      end
    elseif p.kind == "delete" then
      for left_index = p.target_start_index or p.display_start_row, p.target_end_index or p.display_end_row do
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorDelete", left_index - 1, 0, self.left_number_width)
      end
    end
  end
  for _, p in ipairs(route_paths) do
    if p.kind == "change" and p.viewport_solid_start and p.viewport_solid_end then
      for row = p.viewport_solid_start, p.viewport_solid_end do
        if row >= 1 and row <= connector_height then
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorChange", row - 1, 0, -1)
        end
      end
    end
  end

  -- Apply change/add-specific highlighting with intra-line spans
  for _, meta in ipairs(self.view.line_meta) do
    local is_change = meta.kind == "change" and meta.left_index and meta.right_index
    local not_filler = not meta.filler_left and not meta.filler_right
    if is_change and not_filler then
      local left_line = self.left.lines and self.left.lines[meta.left_line] or nil
      local right_line = self.right.lines and self.right.lines[meta.right_line] or nil
      if left_line and right_line then
        local spans = diff_mod.changed_spans(left_line, right_line)
        local row_l = meta.left_index - 1
        local row_r = meta.right_index - 1

        pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, 0, {
          hl_group = "DiffBanditChangeLeft",
          end_row = row_l,
          end_col = #left_line,
          hl_mode = "combine",
          priority = 2500,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, #left_line, {
          hl_group = "DiffBanditChangeLeft",
          end_row = row_l + 1,
          end_col = 0,
          hl_eol = true,
          hl_mode = "combine",
          priority = 2500,
        })
        for _, sp in ipairs(spans.left or {}) do
          local s, e = sp[1] - 1, sp[2]
          pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, s, {
            end_row = row_l,
            end_col = e,
            hl_group = "DiffBanditChangeEmphasis",
            hl_mode = "replace",
            priority = 8000,
          })
        end

        local right_line_len = spans.right_len or #right_line
        local change_end = spans.change_end or spans.prefix_len
        local has_change = spans.right_changes and #spans.right_changes > 0

        do
          -- Change (blue) part followed by added suffix (green)
          local add_start = spans.add_start and (spans.add_start - 1) or right_line_len
          add_start = math.max(0, math.min(add_start, right_line_len))

          local blue_end = math.min(add_start, right_line_len)
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
            end_row = row_r,
            end_col = right_line_len,
            hl_group = "DiffBanditChangeRight",
            hl_mode = "combine",
            priority = 2500,
          })
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, right_line_len, {
            end_row = row_r + 1,
            end_col = 0,
            hl_group = "DiffBanditChangeRight",
            hl_eol = true,
            hl_mode = "combine",
            priority = 2500,
          })
          if has_change then
            -- Word emphasis only within the blue change span
            local emph_hl = "DiffBanditChangeEmphasis"
            for _, sp in ipairs(spans.right_changes or {}) do
              local s = sp[1] - 1
              local e = math.min(sp[2], blue_end)
              if s < e then
                pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, s, {
                  end_row = row_r,
                  end_col = e,
                  hl_group = emph_hl,
                  hl_mode = "replace",
                  priority = 8000,
                })
              end
            end
          end

          -- Added suffix (green): from add_start to end-of-line, extend to window edge
          if spans.add_start and add_start < right_line_len then
            local add_hl = "DiffBanditAdd"
            pcall(vim.api.nvim_buf_add_highlight, self.right_buf, self.ns, add_hl, row_r, add_start, right_line_len)
            pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, right_line_len, {
              end_row = row_r + 1,
              end_col = 0,
              hl_group = "DiffBanditAdd",
              hl_eol = true,
              hl_mode = "combine",
              priority = 3000,
            })
          end
        end
      end
    elseif meta.kind == "add" and meta.right_index and not meta.filler_right then
      local row_r = meta.right_index - 1
      local line_content = self.right.lines and self.right.lines[meta.right_line] or ""
      local line_len = #line_content
      local is_embedded_terminal = embedded_add_terminal_right_indexes[meta.right_index] == true
      if is_embedded_terminal then
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          line_hl_group = "DiffBanditChangeRight",
          hl_mode = "combine",
          priority = 2400,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          end_row = row_r,
          end_col = line_len,
          hl_group = "DiffBanditAdd",
          hl_mode = "replace",
          priority = 7000,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, line_len, {
          end_row = row_r + 1,
          end_col = 0,
          hl_group = "DiffBanditChangeRight",
          hl_eol = true,
          hl_mode = "combine",
          priority = 6500,
        })
        local win_width = vim.api.nvim_win_get_width(self.right_win)
        local text_width = vim.fn.strdisplaywidth(line_content)
        local padding_len = math.max(0, win_width - text_width)
        if padding_len > 0 then
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, line_len, {
            virt_text = { { string.rep(" ", padding_len), "DiffBanditChangeRight" } },
            virt_text_pos = "inline",
            priority = 6500,
          })
        end
      else
        -- Ensure added right-only lines are fully green, overriding any stray change spans.
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          end_row = row_r,
          end_col = -1,
          hl_group = "DiffBanditAdd",
          hl_eol = true,
          hl_mode = "replace",
          priority = 7000,
        })
      end
    end
  end

  -- Apply separator lines on ORIGIN row using native underline attributes.
  for _, meta in ipairs(self.view.line_meta) do
    if meta.origin == "add" and not embedded_add_origin_left_indexes[meta.left_index] then
      -- Left buffer: underline on ORIGIN row
      if meta.left_index then
        local origin_row = meta.left_index - 1
        local line_content = vim.api.nvim_buf_get_lines(self.left_buf, origin_row, origin_row + 1, false)[1] or ""
        local text_len = #line_content

        -- Native underline on text portion
        if text_len > 0 then
          pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, origin_row, 0, {
            end_col = text_len,
            hl_group = "DiffBanditAddLeftSeparator",  -- underline=true, sp=add_bg
            hl_mode = "combine",
            priority = 100,
          })
        end

        local win_width = vim.api.nvim_win_get_width(self.left_win)
        local text_width = vim.fn.strdisplaywidth(line_content)
        local padding_len = math.max(0, win_width - text_width)
        if padding_len > 0 then
          pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, origin_row, 0, {
            virt_text = { { string.rep(" ", padding_len), "DiffBanditAddLeftSeparator" } },
            virt_text_win_col = text_width,
            priority = 100,
          })
        end
      end
      -- Connector underline is handled in the line numbers rendering (combined_virt)
    end
  end

  -- Render delete origin underlines in right buffer using delete_origin_right_lines map
  -- This ensures underlines appear at the correct right line numbers
  for right_line_num, _ in pairs(delete_origin_right_lines) do
    -- Right buffer row is right_line_num - 1 (0-indexed)
    local origin_row = right_line_num - 1
    if origin_row >= 0 and origin_row < #right_lines then
      local line_content = vim.api.nvim_buf_get_lines(self.right_buf, origin_row, origin_row + 1, false)[1] or ""
      local text_len = #line_content

      -- Native underline on text portion
      if text_len > 0 then
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, origin_row, 0, {
          end_col = text_len,
          hl_group = "DiffBanditDeleteRightSeparator",  -- underline=true, sp=delete_bg
          hl_mode = "replace",  -- Use replace to ensure correct sp color
          priority = 150,  -- Higher priority to override any existing highlights
        })
      end

      local win_width = vim.api.nvim_win_get_width(self.right_win)
      local text_width = vim.fn.strdisplaywidth(line_content)
      local padding_len = math.max(0, win_width - text_width)
      if padding_len > 0 then
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, origin_row, 0, {
          virt_text = { { string.rep(" ", padding_len), "DiffBanditDeleteRightSeparator" } },
          virt_text_win_col = text_width,
          priority = 150,
        })
      end
    end
  end

  if self.current_chunk > 0 then
    local chunk = self.view.chunks[self.current_chunk]
    if chunk then
      self:highlight_active_chunk(chunk)
    end
  end

  -- Render planned connector routes. Each planned route is limited to one
  -- source horizontal, one vertical rail, and one destination horizontal.
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.path_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.path_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.path_ns, 0, -1)

  local function render_core_underline(row, start_col, end_col, hl_group)
    if row < 1 or row > connector_height or end_col < start_col then
      return
    end
    start_col = math.max(0, start_col)
    end_col = math.min(self.connector_core_width - 1, end_col)
    if end_col < start_col then
      return
    end
    vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, start_col, {
      virt_text = { { string.rep(" ", end_col - start_col + 1), hl_group } },
      virt_text_pos = "overlay",
    })
  end

  local function render_core_vertical(row, col, hl_group)
    if row < 1 or row > connector_height or col < 0 or col >= self.connector_core_width then
      return
    end
    vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, col, {
      virt_text = { { "│", hl_group } },
      virt_text_pos = "overlay",
    })
  end

  local function render_change_wedge(side, row, glyph)
    if row < 1 or row > connector_height then
      return
    end
    if side == "left" then
      vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, row - 1, self.left_number_width, {
        virt_text = { { glyph, "DiffBanditConnectorExpansionChange" } },
        virt_text_pos = "overlay",
      })
    else
      local right_index = right_topline + (row - left_topline)
      if right_index >= 1 and right_index <= #right_lines then
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, right_index - 1, 0, {
          virt_text = { { glyph, "DiffBanditConnectorExpansionChange" } },
          virt_text_pos = "overlay",
        })
      end
    end
  end

  for _, p in ipairs(route_paths) do
    if p.kind == "change" and p.viewport_change_edges then
      for _, edge in ipairs(p.viewport_change_edges) do
        render_change_wedge(edge.side, edge.row, edge.glyph)
      end
    end
    if p.kind == "change" and p.viewport_change_links then
      for _, link in ipairs(p.viewport_change_links) do
        if not link.overflow_hidden and link.from_visible then
          render_change_wedge(link.from_side, link.from_row, link.from_glyph)
        end
        if not link.overflow_hidden and link.to_visible then
          render_change_wedge(link.to_side, link.to_row, link.to_glyph)
        end

      end
    end
  end

  for _, p in ipairs(route_paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change and not p.overflow_hidden then
      local expansion_hl
      if p.kind == "add" then
        expansion_hl = "DiffBanditConnectorExpansionAdd"
        if (p.triangle_display_row or p.display_start_row) == p.origin_display_row
            or p.connect_tail_on_triangle_row then
          expansion_hl = "DiffBanditConnectorExpansionAddUnderline"
        end
      else
        expansion_hl = "DiffBanditConnectorExpansionDelete"
      end

      local glyph = p.triangle_glyph or ((p.kind == "add") and "◥" or "◤")
      if not p.hide_triangle then
        if p.kind == "add" and p.target_start_index then
          vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, p.target_start_index - 1, 0, {
            virt_text = { { glyph, expansion_hl } },
            virt_text_pos = "overlay",
          })
        elseif p.kind == "delete" and p.target_start_index then
          vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, p.target_start_index - 1, self.left_number_width, {
            virt_text = { { glyph, expansion_hl } },
            virt_text_pos = "overlay",
          })
        end
      end
    end
  end

  for _, planned_route in ipairs(route_plan.routes or {}) do
    for _, segment in ipairs(planned_route.segments or {}) do
      if segment.type == "horizontal" then
        render_core_underline(segment.row, segment.start_col, segment.end_col, segment.kind)
      elseif segment.type == "vertical" then
        for row = segment.start_row, segment.end_row do
          render_core_vertical(row, segment.col, segment.kind)
        end
      end
    end
  end

end

function Session:clear_active_chunk()
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.active_ns, 0, -1)
end

function Session:highlight_active_chunk(chunk)
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

  -- Position cursor at the start of the chunk
  local first_meta = self.view.line_meta[chunk.display_start]
  if first_meta then
    if first_meta.left_index then
      vim.api.nvim_win_set_cursor(self.left_win, { first_meta.left_index, 0 })
    end
    if first_meta.right_index then
      vim.api.nvim_win_set_cursor(self.right_win, { first_meta.right_index, 0 })
    end
    vim.api.nvim_win_set_cursor(self.connector_win, { chunk.display_start, 0 })
  end
  self:sync_gutter_viewports()
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
  local queue = self.file_queue
  if not queue or type(queue.load) ~= "function" then
    return nil, nil, "no file queue configured"
  end

  local count = #(queue.entries or {})
  local current = index
  while current >= 1 and current <= count do
    local loaded, err = queue.load(current)
    if loaded and loaded.left and loaded.right then
      return { left = loaded.left, right = loaded.right }, current, nil
    end
    vim.notify("DiffBandit: skipping " .. tostring(err or "unreadable git file"), vim.log.levels.WARN)
    current = current + step
  end

  return nil, nil, "no readable changed file"
end

function Session:goto_queue_file(index, chunk_position)
  local current = self.file_queue_index or 1
  local step = index >= current and 1 or -1
  local sources, resolved_index, err = self:load_queue_sources(index, step)
  if not sources then
    vim.notify("DiffBandit: " .. err, vim.log.levels.INFO)
    self:reset_pending_file_boundary()
    return false
  end

  self.file_queue_index = resolved_index
  if self.file_queue then
    self.file_queue.index = resolved_index
  end
  local ok, replace_err = self:replace_sources(sources, { chunk_position = chunk_position })
  if not ok then
    vim.notify("DiffBandit: " .. replace_err, vim.log.levels.ERROR)
    return false
  end
  return true
end

function Session:goto_next_file()
  if not self.file_queue then
    vim.notify("DiffBandit: no changed file queue configured", vim.log.levels.INFO)
    return
  end
  self:reset_pending_file_boundary()
  self:goto_queue_file((self.file_queue_index or 1) + 1, "first")
end

function Session:goto_prev_file()
  if not self.file_queue then
    vim.notify("DiffBandit: no changed file queue configured", vim.log.levels.INFO)
    return
  end
  self:reset_pending_file_boundary()
  self:goto_queue_file((self.file_queue_index or 1) - 1, "last")
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
    vim.notify("DiffBandit: already at " .. label .. " changed file", vim.log.levels.INFO)
    return true
  end

  local pending = self.pending_file_boundary
  if pending and pending.direction == direction and pending.file_index == current then
    self:reset_pending_file_boundary()
    self:goto_queue_file(target, direction == "next" and "first" or "last")
    return true
  end

  self.pending_file_boundary = {
    direction = direction,
    file_index = current,
  }

  if direction == "next" then
    vim.notify("DiffBandit: end of this file; press ]c again for next changed file", vim.log.levels.INFO)
  else
    vim.notify("DiffBandit: start of this file; press [c again for previous changed file", vim.log.levels.INFO)
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
          vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
        end
      else
        vim.notify("DiffBandit: no next file handler configured", vim.log.levels.INFO)
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
    vim.notify("DiffBandit: already at first change", vim.log.levels.INFO)
    return
  end
  self:goto_chunk(self.current_chunk - 1)
end

return Session
