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

function Session.start(sources, config)
  local hunks, err = diff_mod.compute_hunks(sources.left.text, sources.right.text, config.diff)
  if err then
    return nil, err
  end

  local view = view_builder.build(sources.left.lines, sources.right.lines, hunks, config)

  local self = setmetatable({}, Session)
  self.id = state.next_session_id()
  self.config = config
  self.left = sources.left
  self.right = sources.right
  self.hunks = hunks
  self.view = view
  self.current_chunk = view.chunks[1] and 1 or 0
  self.left_number_width = math.max(2, digits_of(#sources.left.lines))
  self.right_number_width = digits_of(#sources.right.lines)
  self.right_number_padding = self.config.ui.right_number_padding or 2
  self.ns = vim.api.nvim_create_namespace("DiffBanditHighlights" .. self.id)
  self.active_ns = vim.api.nvim_create_namespace("DiffBanditActive" .. self.id)
  self.path_ns = vim.api.nvim_create_namespace("DiffBanditConnectorPaths" .. self.id)
  self.autocmd_group = nil
  self.disposed = false

  self.connector_core_width = math.max(self.config.ui.connector_width or 0, 0)
  for _, text in ipairs(view.connectors) do
    local width = vim.fn.strdisplaywidth(text)
    if width > self.connector_core_width then
      self.connector_core_width = width
    end
  end
  self.left_number_pane_width = self.left_number_width + 1
  self.right_number_pane_width = self.right_number_width + 1
  self.gutter_width = self.connector_core_width

  self:open_layout()
  self:render()
  self:setup_autocmds()
  self:setup_keymaps()

  if self.current_chunk > 0 then
    vim.schedule(function()
      if not self.disposed then
        self:goto_chunk(self.current_chunk)
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

  vim.api.nvim_set_current_win(self.left_win)
  self.last_source_win = self.left_win
  self.last_source_side = "left"

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

function Session:project_paths_for_viewport(paths)
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
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
    return other_row > row and "◥" or "◤"
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

function Session:render()
  set_buffer_options(self.left_buf, { modifiable = true })
  set_buffer_options(self.left_num_buf, { modifiable = true })
  set_buffer_options(self.right_buf, { modifiable = true })
  set_buffer_options(self.right_num_buf, { modifiable = true })
  set_buffer_options(self.connector_buf, { modifiable = true })

  local left_lines, right_lines = build_display_lines(self)

  -- Compute connector routing lanes using extracted paths module
  local paths = paths_mod.compute_paths(self.view.chunks, self.view.line_meta)
  local route_paths = self:project_paths_for_viewport(paths)
  local max_lane = 0
  for _, p in ipairs(route_paths) do
    if p.lane and p.lane > max_lane then
      max_lane = p.lane
    end
  end

  -- Build active_vertical_bars[row][lane] tracking which lanes have active bars at each row
  local active_vertical_bars = paths_mod.compute_active_bars(route_paths)

  -- Required connector core width: lanes + glyph column + spacing + indentation buffer
  -- Formula ensures enough room for:
  -- - Lane bars (2 chars each)
  -- - Glyph indentation (can shift right by 2 chars per nesting level)
  -- - Space between rightmost glyph and right line numbers (at least 2 chars)
  local required_core = self.connector_core_width
  if max_lane > 0 then
    -- Each lane needs 3 chars, plus 6 for base glyph area and spacing
    required_core = math.max(required_core, (max_lane * 3) + 6)
  end
  if required_core > self.connector_core_width then
    self.connector_core_width = required_core
    self.gutter_width = self.connector_core_width
    self:resize_layout()
  end

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
  for _, p in ipairs(route_paths) do
    if p.kind == "add"
        and not p.embedded_in_change
        and not p.hide_triangle
        and p.origin_display_row
        and (p.triangle_display_row or p.display_start_row) == p.origin_display_row then
      add_origin_row_has_transition[p.origin_display_row] = true
    end
  end
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)

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
      local stop_col = origin_has_bar[origin_row] and origin_bar_cols[origin_row] or origin_glyph_cols[origin_row]
      local underline_width = math.max(1, (stop_col or self.connector_core_width - 1) + 1)
      underline_width = math.min(underline_width, self.connector_core_width)
      vim.api.nvim_buf_set_extmark(self.left_num_buf, self.linenum_ns, row, self.left_number_width, {
        virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, row, 0, {
        virt_text = { { string.rep(" ", underline_width), "DiffBanditAddLeftSeparatorConnector" } },
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
    local underline_start_col = 0
    if del_info.underline_start_after ~= nil then
      underline_start_col = del_info.underline_start_after + 1
    elseif del_info.glyph_col ~= nil then
      underline_start_col = (del_info.glyph_col == 0) and 0 or (del_info.glyph_col + 1)
    end
    underline_start_col = math.max(0, underline_start_col)
    local underline_width = self.gutter_width - underline_start_col
    underline_width = math.max(1, underline_width)

    vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, row, underline_start_col, {
      virt_text = { { string.rep(" ", underline_width), "DiffBanditDeleteRightSeparatorConnector" } },
      virt_text_pos = "overlay",
    })
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
      for row = p.block_display_start or p.display_start_row, p.block_display_end or p.display_end_row do
        local meta = self.view.line_meta[row]
        if meta and meta.right_index then
          vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorAdd", meta.right_index - 1, 1, -1)
        end
      end
    elseif p.kind == "delete" then
      for row = p.block_display_start or p.display_start_row, p.block_display_end or p.display_end_row do
        local meta = self.view.line_meta[row]
        if meta and meta.left_index then
          vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorDelete", meta.left_index - 1, 0, self.left_number_width)
        end
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

  -- Render connector routing paths (top join, vertical, bottom exit)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.path_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.path_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.path_ns, 0, -1)
  local core_start_col = 0
  local default_change_rail_col = math.max(2, math.floor(self.connector_core_width / 3))

  local function route_bar_col(path, lane)
    if path and path.kind == "delete" then
      return delete_lane_col(lane)
    end
    return lane_col(lane)
  end

  local function change_rail_col_for_path(path)
    if path and path.lane and path.lane > 0 then
      return delete_lane_col(path.lane)
    end
    return default_change_rail_col
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
        if not link.no_vertical then
          local start_row = math.min(link.from_row, link.to_row) + 1
          local end_row = math.max(link.from_row, link.to_row) - 1
          for row = start_row, end_row do
            reserve_change_vertical(row, rail_col)
          end
        end
      end
    end
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

  local function render_change_vertical(row, rail_col)
    if row >= 1 and row <= connector_height then
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, rail_col or default_change_rail_col, {
        virt_text = { { "│", "DiffBanditConnectorChangeLine" } },
        virt_text_pos = "overlay",
      })
    end
  end

  local function occupied_route_cols(row)
    local occupied = {}
    local lanes_at_row = active_vertical_bars[row]
    if lanes_at_row then
      for lane, path in pairs(lanes_at_row) do
        occupied[route_bar_col(path, lane)] = true
      end
    end
    if change_vertical_cols_by_row[row] then
      for col, _ in pairs(change_vertical_cols_by_row[row]) do
        occupied[col] = true
      end
    end
    return occupied
  end

  local function render_change_underline_run(row, start_col, end_col, occupied)
    local run_start = nil
    for col = start_col, end_col do
      if occupied[col] then
        if run_start and col > run_start then
          vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, run_start, {
            virt_text = { { string.rep(" ", col - run_start), "DiffBanditChangeSeparatorConnector" } },
            virt_text_pos = "overlay",
          })
        end
        run_start = nil
      elseif not run_start then
        run_start = col
      end
    end
    if run_start and end_col >= run_start then
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, run_start, {
        virt_text = { { string.rep(" ", end_col - run_start + 1), "DiffBanditChangeSeparatorConnector" } },
        virt_text_pos = "overlay",
      })
    end
  end

  local function render_change_underline(side, row, rail_col, skip_sidecar)
    if row < 1 or row > connector_height then
      return
    end
    rail_col = rail_col or default_change_rail_col
    local occupied = occupied_route_cols(row)
    if side == "left" then
      if not skip_sidecar then
        vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, row - 1, self.left_number_width, {
          virt_text = { { " ", "DiffBanditChangeSeparatorConnector" } },
          virt_text_pos = "overlay",
        })
      end
      if rail_col > 0 then
        render_change_underline_run(row, 0, rail_col - 1, occupied)
      end
    else
      if not skip_sidecar then
        local right_index = right_topline + (row - left_topline)
        if right_index >= 1 and right_index <= #right_lines then
          vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, right_index - 1, 0, {
            virt_text = { { " ", "DiffBanditChangeSeparatorConnector" } },
            virt_text_pos = "overlay",
          })
        end
      end
      local start_col = math.min(self.connector_core_width - 1, rail_col + 1)
      if start_col <= self.connector_core_width - 1 then
        render_change_underline_run(row, start_col, self.connector_core_width - 1, occupied)
      end
    end
  end

  local function render_change_vertical_between(from_row, to_row, rail_col)
    local start_row = math.min(from_row, to_row) + 1
    local end_row = math.max(from_row, to_row) - 1
    for row = start_row, end_row do
      render_change_vertical(row, rail_col)
    end
  end

  local function endpoint_underline_row(side, row, glyph)
    if side == "left" and glyph == "◤" then
      return math.max(left_topline, row - 1)
    end
    return row
  end

  for _, p in ipairs(route_paths) do
    if p.kind == "change" and p.viewport_change_edges then
      for _, edge in ipairs(p.viewport_change_edges) do
        render_change_wedge(edge.side, edge.row, edge.glyph)
      end
    end
    if p.kind == "change" and p.viewport_change_links then
      for _, link in ipairs(p.viewport_change_links) do
        if link.from_visible then
          render_change_wedge(link.from_side, link.from_row, link.from_glyph)
        end
        if link.to_visible then
          render_change_wedge(link.to_side, link.to_row, link.to_glyph)
        end

        local rail_col = change_rail_col_for_path(p)
        local from_underline_row = link.underline_row
          or endpoint_underline_row(link.from_side, link.from_row, link.from_glyph)
        local to_underline_row = link.underline_row
          or endpoint_underline_row(link.to_side, link.to_row, link.to_glyph)
        local skip_from_sidecar = link.from_visible and link.from_row == from_underline_row
        local skip_to_sidecar = link.to_visible and link.to_row == to_underline_row
        if link.from_visible then
          render_change_underline(link.from_side, from_underline_row, rail_col, skip_from_sidecar)
        end
        if link.to_visible then
          render_change_underline(link.to_side, to_underline_row, rail_col, skip_to_sidecar)
        end
        if not link.no_vertical then
          render_change_vertical_between(link.from_row, link.to_row, rail_col)
        end
      end
    end
  end

  -- Build row-centric bar collection: maps each row to the lanes with active vertical bars.
  local active_bars = {}  -- row -> { [lane] = { path, fg_group } }
  local glyph_rows_by_lane = {}
  local function add_active_bar(row, lane, path)
    active_bars[row] = active_bars[row] or {}
    active_bars[row][lane] = {
      path = path,
      fg_group = connector_line_highlight(path.kind),
    }
  end

  for _, p in ipairs(route_paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change and not p.hide_triangle then
      local lane = p.lane or 1
      glyph_rows_by_lane[lane] = glyph_rows_by_lane[lane] or {}
      glyph_rows_by_lane[lane][p.triangle_display_row or p.display_start_row or p.start_row] = true
    end
  end

  for row, lanes_at_row in pairs(active_vertical_bars) do
    for lane, p in pairs(lanes_at_row) do
      local lane_has_glyph = glyph_rows_by_lane[lane] and glyph_rows_by_lane[lane][row]
      if not lane_has_glyph or p.connect_tail_on_triangle_row then
        add_active_bar(row, lane, p)
      end
    end
  end

   -- Note: Middle bars for multi-line blocks are now handled by glyph rendering
   -- to ensure proper per-row indentation. The spine bars section was removed
   -- to prevent duplicate rendering on glyph rows.

  for _, p in ipairs(route_paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change then
      local lane = math.max(1, p.lane)
      local col = lane_col(lane)
      local fg_group = connector_line_highlight(p.kind)
      local start_display_row = p.triangle_display_row or p.display_start_row or p.start_row
      local top_row = (p.top or start_display_row) - 1

      -- If there's no origin line, draw top curve
      if not p.top and top_row >= 0 and top_row < connector_height then
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, top_row, core_start_col, {
          virt_text = {
            {string.rep("─", math.max(0, col - core_start_col)), fg_group},
          },
          virt_text_pos = "overlay",
        })

        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, top_row, col, {
          virt_text = { {(p.kind == "add") and "╮" or "╭", fg_group} },
          virt_text_pos = "overlay",
        })
      end

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
       if p.hide_triangle then
         -- Clipped route: keep rails/tails from projected geometry, but do
         -- not invent a transition glyph at the viewport edge.
       elseif p.kind == "add" and p.target_start_index then
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

       -- Middle rows: lane vertical bars from active_bars rendering provide visual continuity.
    end
  end

  -- Render all vertical bars from active_bars (row-centric approach)
  -- This allows multiple bars from different paths to appear on the same row
  for row, lanes_on_row in pairs(active_bars) do
    if row >= 1 and row <= connector_height then
      for lane, bar_info in pairs(lanes_on_row) do
        local bar_col
        local kind = bar_info.path and bar_info.path.kind or "add"
        if kind == "delete" then
          bar_col = delete_lane_col(lane)
        else
          bar_col = lane_col(lane)
        end

        -- Primary spine rail
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, bar_col, {
          virt_text = { { "│", bar_info.fg_group } },
          virt_text_pos = "overlay",
        })
      end
    end
  end

  -- Render tail underlines (horizontal connector from bar to triangle)
  for row, tail_info in pairs(tail_underlines) do
    if row >= 1 and row <= connector_height and tail_info.kind == "delete" then
      local bar_col = math.max(0, tail_info.bar_col or 0)
      if bar_col > 0 then
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, 0, {
          virt_text = { { string.rep(" ", bar_col), "DiffBanditDeleteRightSeparatorConnector" } },
          virt_text_pos = "overlay",
        })
      else
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, 1, {
          virt_text = { { " ", "DiffBanditDeleteRightSeparatorConnector" } },
          virt_text_pos = "overlay",
        })
      end
    elseif row >= 1 and row <= connector_height then
      local underline_start = math.min(tail_info.bar_col, tail_info.triangle_col) + 1
      local underline_end = math.max(tail_info.bar_col, tail_info.triangle_col)
      local underline_width = underline_end - underline_start
      if tail_info.kind == "add" then
        underline_width = underline_width + 1
      end
      if underline_width > 0 then
        local fg_group = (tail_info.kind == "add")
          and "DiffBanditAddLeftSeparatorConnector" or "DiffBanditDeleteRightSeparatorConnector"
        local extmark_opts = {
          virt_text = { { string.rep(" ", underline_width), fg_group } },
          virt_text_pos = "overlay",
        }
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, underline_start, extmark_opts)
      end
    end
  end
end

function Session:highlight_active_chunk(chunk)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.active_ns, 0, -1)

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
  if index < 1 then
    index = 1
  elseif index > #self.view.chunks then
    index = #self.view.chunks
  end
  self.current_chunk = index
  local chunk = self.view.chunks[self.current_chunk]
  self:highlight_active_chunk(chunk)
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
    vim.notify("DiffBandit: already at first change", vim.log.levels.INFO)
    return
  end
  self:goto_chunk(self.current_chunk - 1)
end

return Session
