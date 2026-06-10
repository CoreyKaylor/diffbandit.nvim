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
  -- View arrays now have different lengths, return them directly
  return session.view.left, session.view.right
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
  -- Gutter width: left_num + connector + right_num + right_padding
  self.gutter_width = self.left_number_width + self.connector_core_width
    + self.right_number_width + self.right_number_padding

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
  local connector_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)

  self.left_buf = left_buf
  self.connector_buf = connector_buf
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

  set_buffer_options(connector_buf, {
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
  })

  -- Put buffers in windows BEFORE setting bufhidden=wipe
  -- We want: LEFT (left_buf) | MIDDLE (connector_buf) | RIGHT (right_buf)
  -- Use explicit split commands to be independent of user's splitright setting

  -- Start: initial window will become the LEFT pane
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  -- Create RIGHT window (rightbelow ensures it goes to the right regardless of splitright)
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)

  -- Go back to left window and create MIDDLE window to its right
  vim.api.nvim_set_current_win(left_win)
  vim.cmd("rightbelow vsplit")
  local connector_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(connector_win, connector_buf)
  vim.api.nvim_win_set_width(connector_win, self.gutter_width)

  self.left_win = left_win
  self.connector_win = connector_win
  self.right_win = right_win

  set_window_options(left_win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit,CursorLine:DiffBanditCursorLine",
  })

  set_window_options(connector_win, {
    number = false,
    relativenumber = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    winhl = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit",
  })

  set_window_options(right_win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit,CursorLine:DiffBanditCursorLine",
  })

  -- Now that all buffers are displayed in windows, set bufhidden=wipe for cleanup
  set_buffer_options(left_buf, { bufhidden = "wipe" })
  set_buffer_options(connector_buf, { bufhidden = "wipe" })
  set_buffer_options(right_buf, { bufhidden = "wipe" })

  -- Set vertical split character to thin line
  vim.opt.fillchars:append({ vert = "│" })

  vim.api.nvim_set_current_win(self.left_win)

  local left_name = self.left.label or self.left.path or ""
  local right_name = self.right.label or self.right.path or ""
  self.title = string.format("DiffBandit: %s ↔ %s", left_name, right_name)
  vim.api.nvim_tabpage_set_var(self.tabpage, "diffbandit_title", self.title)
  vim.api.nvim_set_option_value("showtabline", 2, { scope = "global" })
end

function Session:setup_autocmds()
  local augroup = vim.api.nvim_create_augroup("DiffBanditSession" .. self.id, { clear = true })
  self.autocmd_group = augroup
  self.syncing_scroll = false  -- Flag to prevent infinite sync loops

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

  -- Custom scroll synchronization: sync from left to right and connector
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = self.left_buf,
    callback = function()
      if self.syncing_scroll then
        return
      end
      self:sync_scroll_from_left()
    end,
  })

  -- Custom scroll synchronization: sync from right to left and connector
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = self.right_buf,
    callback = function()
      if self.syncing_scroll then
        return
      end
      self:sync_scroll_from_right()
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
  buffer_maps(self.connector_buf)
end

local function sync_scroll(self, source_win, source_key, target_win, target_key)
  if self.disposed or not vim.api.nvim_win_is_valid(source_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(source_win)
  local source_line = cursor[1]
  local col = cursor[2]

  local target_meta = nil
  local display_idx = nil
  for idx, meta in ipairs(self.view.line_meta) do
    if meta[source_key] == source_line then
      target_meta = meta
      display_idx = idx
      break
    end
  end

  if not target_meta then
    return
  end

  self.syncing_scroll = true
  if target_meta[target_key] and vim.api.nvim_win_is_valid(target_win) then
    pcall(vim.api.nvim_win_set_cursor, target_win, { target_meta[target_key], col })
  end
  if vim.api.nvim_win_is_valid(self.connector_win) then
    pcall(vim.api.nvim_win_set_cursor, self.connector_win, { display_idx or source_line, 0 })
  end
  self.syncing_scroll = false
end

function Session:sync_scroll_from_left()
  sync_scroll(self, self.left_win, "left_index", self.right_win, "right_index")
end

function Session:sync_scroll_from_right()
  sync_scroll(self, self.right_win, "right_index", self.left_win, "left_index")
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

local HIGHLIGHT_CONNECTOR = {
  context = "DiffBanditConnectorContext",
  add = "DiffBanditConnectorAdd",
  delete = "DiffBanditConnectorDelete",
  change = "DiffBanditConnectorChange",
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

local function highlight_for_connector(meta)
  return HIGHLIGHT_CONNECTOR[meta.kind] or "DiffBanditConnectorChange"
end

function Session:render()
  set_buffer_options(self.left_buf, { modifiable = true })
  set_buffer_options(self.right_buf, { modifiable = true })
  set_buffer_options(self.connector_buf, { modifiable = true })

  local left_lines, right_lines = build_display_lines(self)

  -- Compute connector routing lanes using extracted paths module
  local paths = paths_mod.compute_paths(self.view.chunks, self.view.line_meta)
  local max_lane = 0
  for _, p in ipairs(paths) do
    if p.lane and p.lane > max_lane then
      max_lane = p.lane
    end
  end

  -- Build active_vertical_bars[row][lane] tracking which lanes have active bars at each row
  local active_vertical_bars = paths_mod.compute_active_bars(paths)

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
    self.gutter_width = self.left_number_width + self.connector_core_width
      + self.right_number_width + self.right_number_padding
    if self.connector_win and vim.api.nvim_win_is_valid(self.connector_win) then
      vim.api.nvim_win_set_width(self.connector_win, self.gutter_width)
    end
  end

  -- Define positioning functions now that connector_core_width is finalized
  -- Glyphs are positioned per lane with indentation; vertical bars (rails) sit to the left
  local rail_spacing = 1
  local glyph_base_col = self.left_number_width + self.connector_core_width - 1
  local function rail_col_for_lane(lane)
    local idx = math.max(0, lane - 1)
    return glyph_base_col - (idx * (rail_spacing + 1)) - 1
  end
  local function lane_col(lane)
    return rail_col_for_lane(lane)
  end
  local function delete_lane_col(lane)
    local idx = math.max(0, lane - 1)
    return self.left_number_width + 1 + (idx * (rail_spacing + 1))
  end

  -- Compute underline data using extracted helper
  local underline_layout = {
    left_number_width = self.left_number_width,
    connector_core_width = self.connector_core_width,
    rail_spacing = 1,
  }
  local underline_data = paths_mod.compute_underlines(paths, active_vertical_bars, underline_layout)
  local origin_glyph_cols = underline_data.origin_glyph_cols
  local origin_bar_cols = underline_data.origin_bar_cols
  local origin_has_bar = underline_data.origin_has_bar
  local tail_underlines = underline_data.tail_underlines
  local delete_origin_right_lines = underline_data.delete_origin_right_lines or {}

  local embedded_add_right_indexes = {}
  local embedded_add_terminal_right_indexes = {}
  local embedded_add_origin_left_indexes = {}
  local mixed_envelope_left_indexes = {}
  local mixed_envelope_right_indexes = {}
  local mixed_envelope_connector_rows = {}
  local change_connector_rows = {}
  for _, p in ipairs(paths) do
    if p.kind == "add" and p.embedded_in_change then
      if p.origin_left_index then
        embedded_add_origin_left_indexes[p.origin_left_index] = true
      end
      if p.target_start_index and p.target_end_index then
        for row = p.target_start_index, p.target_end_index do
          embedded_add_right_indexes[row] = true
        end
        embedded_add_terminal_right_indexes[p.target_end_index] = true
      end
    elseif p.kind == "change" and p.mixed_add then
      local start_row = p.display_start_row or p.start_row
      local end_row = p.display_end_row or p.end_row or start_row
      if start_row and end_row then
        for row = start_row, end_row do
          change_connector_rows[row] = true
        end
      end
      if p.start_left_index and p.end_left_index then
        for row = p.start_left_index, p.end_left_index do
          mixed_envelope_left_indexes[row] = true
        end
      end
      if p.start_right_index and p.end_right_index then
        for row = p.start_right_index, p.end_right_index do
          mixed_envelope_right_indexes[row] = true
          mixed_envelope_connector_rows[row] = true
        end
      end
      if p.start_left_index and p.end_left_index then
        for row = p.start_left_index, p.end_left_index do
          mixed_envelope_connector_rows[row] = true
        end
      end
    elseif p.kind == "change" then
      local start_row = p.display_start_row or p.start_row
      local end_row = p.display_end_row or p.end_row or start_row
      if start_row and end_row then
        for row = start_row, end_row do
          change_connector_rows[row] = true
        end
      end
    end
  end

  local function delete_triangle_col(_, core_start_col, _)
    return core_start_col
  end

  -- The connector buffer owns the aligned display model.
  local connector_height = #self.view.line_meta
  local connector_lines = {}
  for i = 1, connector_height do
    -- Initialize with spaces for the full gutter width
    connector_lines[i] = string.rep(" ", self.gutter_width)
  end

  -- Store gutter layout information for each metadata entry
  -- We'll use this for positioning line numbers and glyphs
  -- Ensure connector_text is always padded to full connector_core_width for alignment
  for idx, meta in ipairs(self.view.line_meta) do
    local raw_connector = self.view.connectors[idx] or ""
    local conn_width = vim.fn.strdisplaywidth(raw_connector)
    local padding_needed = self.connector_core_width - conn_width
    if padding_needed > 0 then
      meta.connector_text = raw_connector .. string.rep(" ", padding_needed)
    else
      meta.connector_text = raw_connector
    end
  end

  -- Left and right buffers now have different line counts
  vim.api.nvim_buf_set_lines(self.left_buf, 0, -1, false, left_lines)
  vim.api.nvim_buf_set_lines(self.right_buf, 0, -1, false, right_lines)
  vim.api.nvim_buf_set_lines(self.connector_buf, 0, -1, false, connector_lines)

  set_buffer_options(self.left_buf, { modifiable = false })
  set_buffer_options(self.right_buf, { modifiable = false })
  set_buffer_options(self.connector_buf, { modifiable = false })

  vim.api.nvim_buf_clear_namespace(self.left_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.ns, 0, -1)

  -- Clear extmark namespace for full-width backgrounds
  self.extmark_ns = self.extmark_ns or vim.api.nvim_create_namespace("DiffBanditExtmarks" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.extmark_ns, 0, -1)

  -- Clear namespace for line number virtual text
  self.linenum_ns = self.linenum_ns or vim.api.nvim_create_namespace("DiffBanditLineNums" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.linenum_ns, 0, -1)

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

  -- Apply connector backgrounds and line numbers on the same screen rows as
  -- the compact left/right source buffers.
  local core_start_col_base = self.left_number_width
  local right_col_base = core_start_col_base + self.connector_core_width
  local ctx_hl = "DiffBanditConnectorContext"

  for row = 0, connector_height - 1 do
    vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, ctx_hl, row, 0, -1)
  end

  local function add_connector_bg(row, meta, connector_bg_hl, side)
    if meta.kind == "change" and not mixed_envelope_connector_rows[row + 1] then
      vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, row, 0, -1)
    end
  end

  local function add_origin_core_virt(origin_row, meta)
    if meta.origin == "add" then
      local stop_col = origin_has_bar[origin_row] and origin_bar_cols[origin_row] or origin_glyph_cols[origin_row]
      local underline_width = math.max(1, (stop_col or right_col_base - 1) - self.left_number_width)
      underline_width = math.min(underline_width, self.connector_core_width)
      return { { string.rep(" ", underline_width), "DiffBanditAddLeftSeparatorConnector" } }
    end
    return nil
  end

  local function set_delete_origin_core(row, right_line)
    local del_info = delete_origin_right_lines[right_line]
    if not del_info then
      return
    end
    local underline_start_col = self.left_number_width + 1
    if del_info.glyph_col ~= nil then
      underline_start_col = del_info.glyph_col + 1
    elseif del_info.underline_start_after ~= nil then
      underline_start_col = del_info.underline_start_after + 1
    end
    underline_start_col = math.max(self.left_number_width + 1, underline_start_col)
    local underline_width = self.gutter_width - underline_start_col
    underline_width = math.max(1, underline_width)

    vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, row, underline_start_col, {
      virt_text = { { string.rep(" ", underline_width), "DiffBanditDeleteRightSeparatorConnector" } },
      virt_text_pos = "overlay",
    })
  end

  for idx, meta in ipairs(self.view.line_meta) do
    local connector_hl = highlight_for_connector(meta)
    local connector_bg_hl = connector_hl or "DiffBanditConnectorContext"

    if meta.left_index then
      local row = meta.left_index - 1
      add_connector_bg(row, meta, connector_bg_hl, "left")

      local left_num_hl
      if meta.origin == "add" and not embedded_add_origin_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftUnderline"
      elseif meta.kind == "delete" then
        left_num_hl = "DiffBanditLineNumberLeftDelete"
      elseif meta.kind == "change" or mixed_envelope_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftChange"
      else
        left_num_hl = "DiffBanditLineNumberLeft"
      end

      local virt = {
        { format_line_number(meta.left_line, self.left_number_width), left_num_hl },
      }
      local origin_virt = nil
      if not embedded_add_origin_left_indexes[meta.left_index] then
        origin_virt = add_origin_core_virt(meta.left_index, meta)
      end
      if origin_virt then
        vim.list_extend(virt, origin_virt)
      end

      vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, row, 0, {
        virt_text = virt,
        virt_text_pos = "overlay",
      })
    end

    if meta.right_index then
      local row = meta.right_index - 1
      add_connector_bg(row, meta, connector_bg_hl, "right")

      local is_delete_origin = meta.right_line and delete_origin_right_lines[meta.right_line] ~= nil
      local right_num_hl
      if is_delete_origin then
        right_num_hl = "DiffBanditLineNumberRightUnderline"
      elseif meta.kind == "change" or mixed_envelope_right_indexes[meta.right_index] then
        right_num_hl = "DiffBanditLineNumberRightChange"
      elseif meta.kind == "add" and not embedded_add_right_indexes[meta.right_index] then
        right_num_hl = "DiffBanditLineNumberRightAdd"
      else
        right_num_hl = "DiffBanditLineNumberRight"
      end

      if is_delete_origin then
        set_delete_origin_core(row, meta.right_line)
      end

      vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, row, right_col_base, {
        virt_text = {
          { format_line_number_left(meta.right_line, self.right_number_width), right_num_hl },
        },
        virt_text_pos = "overlay",
      })
    end
  end

  -- Apply route-owned connector backgrounds. Add/delete fill begins only on the
  -- actual diff block rows; origin rows stay as thin separators.
  for _, p in ipairs(paths) do
    if p.kind == "add" and not p.embedded_in_change then
      local triangle_col = right_col_base - 1
      local fill_start_col = triangle_col + 1
      for row = p.block_display_start or p.display_start_row, p.block_display_end or p.display_end_row do
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorAdd", row - 1, fill_start_col, -1)
      end
    elseif p.kind == "delete" then
      local triangle_col = delete_triangle_col(p, core_start_col_base, right_col_base)
      for row = p.block_display_start or p.display_start_row, p.block_display_end or p.display_end_row do
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorDelete", row - 1, 0, triangle_col)
      end
    elseif p.kind == "change" then
      if p.mixed_add and p.start_left_index and p.start_right_index then
        local mid_col = core_start_col_base + math.floor(self.connector_core_width / 2)
        local right_start = p.start_right_index
        local right_end = p.end_right_index or p.start_right_index
        for row = right_start, right_end do
          local start_col = mid_col
          if row >= p.start_left_index and row <= (p.end_left_index or p.start_left_index) then
            start_col = 0
          end
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorChange", row - 1, start_col, -1)
        end
      elseif p.offset and p.start_left_index and p.start_right_index then
        local mid_col = core_start_col_base + math.floor(self.connector_core_width / 2)
        local min_row = math.min(p.start_left_index, p.start_right_index)
        local max_row = math.max(p.end_left_index or p.start_left_index, p.end_right_index or p.start_right_index)
        for row = p.start_left_index, p.end_left_index or p.start_left_index do
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorChange", row - 1, 0, mid_col + 1)
        end
        for row = p.start_right_index, p.end_right_index or p.start_right_index do
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorChange", row - 1, mid_col, -1)
        end
        for row = min_row + 1, max_row - 1 do
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorChange", row - 1, mid_col, mid_col + 1)
        end
      else
        for row = p.display_start_row, p.display_end_row do
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
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.path_ns, 0, -1)
  local core_start_col = self.left_number_width

   -- Build row-centric bar collection: maps each row to the lanes with active vertical bars
   -- This enables multiple bars from different paths to coexist on the same row (expansion zones)
   local active_bars = {}  -- row -> { [lane] = {path, fg_group} }

   -- Build per-lane glyph tracking to avoid duplicate rendering
   -- glyph_rows_by_lane[lane][row] = true if that lane has a glyph on that row
   -- Only mark the triangle row (start_row), not the entire block range
   local glyph_rows_by_lane = {}
   for _, p in ipairs(paths) do
     if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change then
       local lane = p.lane or 1
       glyph_rows_by_lane[lane] = glyph_rows_by_lane[lane] or {}
       -- Only the triangle row has a glyph, not the whole block
       glyph_rows_by_lane[lane][p.triangle_display_row or p.display_start_row or p.start_row] = true
     end
   end

   -- Create vertical bars using active_vertical_bars (already computed with proper extended ranges)
   -- This shows visual overlap where later blocks start within earlier blocks' vertical extent
   -- Only skip bar rendering if THIS SPECIFIC LANE has a glyph on this row
   for row, lanes_at_row in pairs(active_vertical_bars) do
     for lane, p in pairs(lanes_at_row) do
       -- Only render bar if this lane doesn't have a glyph on this row
       local lane_has_glyph = glyph_rows_by_lane[lane] and glyph_rows_by_lane[lane][row]
       if not lane_has_glyph then
         active_bars[row] = active_bars[row] or {}
         active_bars[row][lane] = {
           path = p,
           fg_group = (p.kind == "add") and "DiffBanditConnectorAddLine" or "DiffBanditConnectorDeleteLine"
         }
       end
     end
   end

   -- Note: Middle bars for multi-line blocks are now handled by glyph rendering
   -- to ensure proper per-row indentation. The spine bars section was removed
   -- to prevent duplicate rendering on glyph rows.

  for _, p in ipairs(paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change then
      local lane = math.max(1, p.lane)
      local col = lane_col(lane)
      local fg_group = (p.kind == "add") and "DiffBanditConnectorAddLine" or "DiffBanditConnectorDeleteLine"
      local start_display_row = p.triangle_display_row or p.display_start_row or p.start_row
      local top_row = (p.top or start_display_row) - 1

      -- If there's no origin line, draw top curve
      if not p.top then
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

       -- Triangle glyph position depends on kind:
       -- Additions dock to the right edge. Deletions start immediately after
       -- the left line number, then use compact rails/underlines to route.
       local triangle_col
       if p.kind == "add" then
         triangle_col = right_col_base - 1
       else
         triangle_col = delete_triangle_col(p, core_start_col, right_col_base)
       end
       local expansion_hl
       if p.kind == "add" then
         expansion_hl = "DiffBanditConnectorExpansionAdd"
       else
         expansion_hl = "DiffBanditConnectorExpansionDelete"
       end
       local glyph = p.triangle_glyph or ((p.kind == "add") and "◥" or "◤")

       vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, start_display_row - 1, triangle_col, {
         virt_text = {
           {glyph, expansion_hl},
         },
         virt_text_pos = "overlay",
       })

       -- Middle rows: No glyph - lane vertical bars from active_bars rendering provide visual continuity

       -- Last row: No glyph - only the top triangle marks the expansion point
    elseif p.kind == "change" then
      -- Change routes are expressed with background spans. For mixed change/add
      -- envelopes, add one-cell colored wedges at the stepped edge so the
      -- terminal shape reads closer to IntelliJ's softened route.
      if p.mixed_add and p.start_left_index and p.end_left_index
          and p.start_right_index and p.end_right_index then
        local mid_col = core_start_col + math.floor(self.connector_core_width / 2)
        local wedge_col = math.max(core_start_col, mid_col - 1)

        if p.start_right_index < p.start_left_index then
          vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, p.start_right_index - 1, wedge_col, {
            virt_text = { { "◢", "DiffBanditConnectorExpansionChange" } },
            virt_text_pos = "overlay",
          })
        end

        if p.end_right_index > p.end_left_index then
          vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, p.end_right_index - 1, wedge_col, {
            virt_text = { { "◥", "DiffBanditConnectorExpansionChange" } },
            virt_text_pos = "overlay",
          })
        end
      end
    end
  end

   -- Render all vertical bars from active_bars (row-centric approach)
   -- This allows multiple bars from different paths to appear on the same row
   for row, lanes_on_row in pairs(active_bars) do
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
         virt_text = { {"│", bar_info.fg_group} },
         virt_text_pos = "overlay",
       })
     end
   end

   -- Render tail underlines (horizontal connector from bar to triangle)
   for row, tail_info in pairs(tail_underlines) do
     local underline_start = math.min(tail_info.bar_col, tail_info.triangle_col) + 1
     local underline_end = math.max(tail_info.bar_col, tail_info.triangle_col)
     local underline_width = underline_end - underline_start
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

function Session:highlight_active_chunk(chunk)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.active_ns, 0, -1)
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
      end

      -- Highlight right buffer if this metadata has a right line
      if meta.right_index and not has_strong_bg then
        local row = meta.right_index - 1
        add_hl(self.right_buf, self.active_ns, active_hl, row, 0, -1)
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
