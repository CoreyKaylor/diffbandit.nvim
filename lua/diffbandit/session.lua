local diff_mod = require("diffbandit.diff")
local view_builder = require("diffbandit.view")
local state = require("diffbandit.state")

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
  -- Return number without trailing padding to avoid excessive spacing
  return tostring(num)
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
  self.left_number_width = digits_of(#sources.left.lines)
  self.right_number_width = digits_of(#sources.right.lines)
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
  -- Gutter width accounts for: left_number + connector + right_number
  -- Total: left_num + right_num + connector
  self.gutter_width = self.left_number_width + self.right_number_width + self.connector_core_width

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

  local left_buf = vim.api.nvim_create_buf(false, true)
  local connector_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)

  self.left_buf = left_buf
  self.connector_buf = connector_buf
  self.right_buf = right_buf

  set_buffer_options(left_buf, {
    buftype = "nofile",
    bufhidden = "wipe",
    swapfile = false,
    modifiable = false,
    filetype = self.left.filetype,
  })

  set_buffer_options(right_buf, {
    buftype = "nofile",
    bufhidden = "wipe",
    swapfile = false,
    modifiable = false,
    filetype = self.right.filetype,
  })

  set_buffer_options(connector_buf, {
    buftype = "nofile",
    bufhidden = "wipe",
    swapfile = false,
    modifiable = false,
  })

  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), left_buf)

  vim.cmd("vsplit")
  vim.cmd("wincmd h")

  vim.cmd("vsplit")
  local connector_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(connector_win, connector_buf)
  vim.api.nvim_win_set_width(connector_win, self.gutter_width)

  vim.cmd("wincmd h")
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  vim.cmd("wincmd l")
  vim.cmd("wincmd l")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)

  self.left_win = left_win
  self.connector_win = connector_win
  self.right_win = right_win

  set_window_options(left_win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = "VertSplit:VertSplit,CursorLine:DiffBanditCursorLine",
  })

  set_window_options(connector_win, {
    number = false,
    relativenumber = false,
    cursorline = false,
    wrap = false,
    signcolumn = "no",
    winhl = "VertSplit:VertSplit",
  })

  set_window_options(right_win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    winhl = "VertSplit:VertSplit,CursorLine:DiffBanditCursorLine",
  })

  -- Set vertical split character to thin line
  vim.opt.fillchars:append({ vert = "│" })

  vim.api.nvim_set_current_win(self.left_win)

  self.title = string.format("DiffBandit: %s ↔ %s", self.left.label or self.left.path or "", self.right.label or self.right.path or "")
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

function Session:sync_scroll_from_left()
  if self.disposed or not vim.api.nvim_win_is_valid(self.left_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.left_win)
  local left_line = cursor[1]  -- 1-indexed
  local col = cursor[2]

  -- Find the metadata entry for this left buffer line
  local target_meta = nil
  for idx, meta in ipairs(self.view.line_meta) do
    if meta.left_index == left_line then
      target_meta = meta
      break
    end
  end

  if not target_meta then
    return
  end

  -- Sync to right window if it has a corresponding line
  self.syncing_scroll = true
  if target_meta.right_index and vim.api.nvim_win_is_valid(self.right_win) then
    pcall(vim.api.nvim_win_set_cursor, self.right_win, { target_meta.right_index, col })
  end

  -- Sync connector window to the same vertical position as the left buffer
  if vim.api.nvim_win_is_valid(self.connector_win) then
    pcall(vim.api.nvim_win_set_cursor, self.connector_win, { left_line, 0 })
  end
  self.syncing_scroll = false
end

function Session:sync_scroll_from_right()
  if self.disposed or not vim.api.nvim_win_is_valid(self.right_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.right_win)
  local right_line = cursor[1]  -- 1-indexed
  local col = cursor[2]

  -- Find the metadata entry for this right buffer line
  local target_meta = nil
  for idx, meta in ipairs(self.view.line_meta) do
    if meta.right_index == right_line then
      target_meta = meta
      break
    end
  end

  if not target_meta then
    return
  end

  -- Sync to left window if it has a corresponding line
  self.syncing_scroll = true
  if target_meta.left_index and vim.api.nvim_win_is_valid(self.left_win) then
    pcall(vim.api.nvim_win_set_cursor, self.left_win, { target_meta.left_index, col })
  end

  -- Sync connector window to the same vertical position as the right buffer
  if vim.api.nvim_win_is_valid(self.connector_win) then
    pcall(vim.api.nvim_win_set_cursor, self.connector_win, { right_line, 0 })
  end
  self.syncing_scroll = false
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

local function highlight_for_left(meta)
  if meta.kind == "context" then
    return "DiffBanditContext"
  end
  if meta.kind == "add" then
    return "DiffBanditAddLeft"
  end
  if meta.kind == "delete" then
    return "DiffBanditDelete"
  end
  if meta.kind == "change" then
    return meta.filler_left and "DiffBanditGap" or "DiffBanditChangeLeft"
  end
  return nil
end

local function highlight_for_right(meta)
  if meta.kind == "context" then
    return "DiffBanditContext"
  end
  if meta.kind == "add" then
    return meta.filler_right and "DiffBanditGap" or "DiffBanditAdd"
  end
  if meta.kind == "delete" then
    if meta.filler_right then
      return "DiffBanditGap"
    end
    return "DiffBanditChangeRight"
  end
  if meta.kind == "change" then
    return meta.filler_right and "DiffBanditGap" or "DiffBanditChangeRight"
  end
  return nil
end

local function highlight_for_connector(meta)
  if meta.kind == "context" then
    if meta.origin == "add" then
      return "DiffBanditConnectorAdd"
    elseif meta.origin == "delete" then
      return "DiffBanditConnectorDelete"
    end
    return "DiffBanditConnectorContext"
  end
  if meta.kind == "add" then
    return "DiffBanditConnectorAdd"
  end
  if meta.kind == "delete" then
    return "DiffBanditConnectorDelete"
  end
  return "DiffBanditConnectorChange"
end

function Session:render()
  set_buffer_options(self.left_buf, { modifiable = true })
  set_buffer_options(self.right_buf, { modifiable = true })
  set_buffer_options(self.connector_buf, { modifiable = true })

  local left_lines, right_lines = build_display_lines(self)

  -- Precompute connector routing lanes and required core width
  local paths = {}
  local function add_path(kind, top_row, start_row, end_row)
    if top_row and start_row and end_row and start_row <= end_row then
      paths[#paths + 1] = { kind = kind, top = top_row, start_row = start_row, end_row = end_row, lane = 0 }
    end
  end

  -- Determine per-chunk path spans
  for _, chunk in ipairs(self.view.chunks) do
    if chunk.type == "add" then
      local origin_meta = self.view.line_meta[chunk.display_start - 1]
      local top_row = origin_meta and (origin_meta.left_index or origin_meta.right_index)
      local s, e = nil, nil
      for i = chunk.display_start, chunk.display_end do
        local m = self.view.line_meta[i]
        if m and m.kind == "add" then
          local row = m.right_index or m.left_index
          if row then
            s = s and math.min(s, row) or row
            e = e and math.max(e, row) or row
          end
        end
      end
      add_path("add", top_row, s, e)
    elseif chunk.type == "delete" then
      local origin_meta = self.view.line_meta[chunk.display_start - 1]
      local top_row = origin_meta and (origin_meta.right_index or origin_meta.left_index)
      local s, e = nil, nil
      for i = chunk.display_start, chunk.display_end do
        local m = self.view.line_meta[i]
        if m and m.kind == "delete" then
          local row = m.left_index or m.right_index
          if row then
            s = s and math.min(s, row) or row
            e = e and math.max(e, row) or row
          end
        end
      end
      add_path("delete", top_row, s, e)
    elseif chunk.type == "change" then
      local s, e = nil, nil
      for i = chunk.display_start, chunk.display_end do
        local m = self.view.line_meta[i]
        if m and m.kind == "change" then
          local row = m.left_index or m.right_index
          if row then
            s = s and math.min(s, row) or row
            e = e and math.max(e, row) or row
          end
        end
      end
      if s and e then
        paths[#paths + 1] = { kind = "change", start_row = s, end_row = e }
      end
    end
  end

  -- Lane allocation for add/delete vertical paths
  table.sort(paths, function(a, b)
    local as = a.start_row or 0
    local bs = b.start_row or 0
    return as < bs
  end)
  local lanes = {} -- each lane keeps last end_row
  local max_lane = 0
  for _, p in ipairs(paths) do
    if p.kind == "add" or p.kind == "delete" then
      local assigned = false
      for li = 1, #lanes do
        if (lanes[li] or 0) < (p.start_row or 0) then
          p.lane = li
          lanes[li] = p.end_row or lanes[li]
          assigned = true
          break
        end
      end
      if not assigned then
        p.lane = #lanes + 1
        lanes[#lanes + 1] = p.end_row or 0
      end
      if p.lane > max_lane then
        max_lane = p.lane
      end
    end
  end

  -- Required connector core width: one column per lane with one space between = (lanes*2-1)
  local required_core = max_lane > 0 and (max_lane * 2 - 1) or self.connector_core_width
  if required_core > self.connector_core_width then
    self.connector_core_width = required_core
    self.gutter_width = self.left_number_width + self.right_number_width + self.connector_core_width
    if self.connector_win and vim.api.nvim_win_is_valid(self.connector_win) then
      vim.api.nvim_win_set_width(self.connector_win, self.gutter_width)
    end
  end

  -- Make connector buffer as tall as the maximum of left and right buffers
  local connector_height = math.max(#left_lines, #right_lines)
  local connector_lines = {}
  for i = 1, connector_height do
    -- Initialize with spaces for the full gutter width
    connector_lines[i] = string.rep(" ", self.gutter_width)
  end

  -- Store gutter layout information for each metadata entry
  -- We'll use this for positioning line numbers and glyphs
  for idx, meta in ipairs(self.view.line_meta) do
    meta.connector_text = self.view.connectors[idx] or string.rep(" ", self.connector_core_width)
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

  -- Clear namespace for line number virtual text
  self.linenum_ns = self.linenum_ns or vim.api.nvim_create_namespace("DiffBanditLineNums" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.linenum_ns, 0, -1)

  -- Track chunk edge rows for separator rendering
  local chunk_edges = {}

  -- Apply highlights to left and right buffers (pane-wide backgrounds)
  for idx, meta in ipairs(self.view.line_meta) do
    local left_hl = highlight_for_left(meta)
    local right_hl = highlight_for_right(meta)
    local final_left_hl = left_hl
    local final_right_hl = right_hl

    -- Filler line visual flow: match IntelliJ's subtle separator approach
    if meta.filler_left and meta.kind ~= "context" then
      final_left_hl = "DiffBanditPlaceholder"
    end

    if meta.filler_right and meta.kind ~= "context" then
      final_right_hl = "DiffBanditPlaceholder"
    end

    -- Apply full-line highlights using line_hl_group to ensure fill to window edge
    if final_left_hl and meta.left_index then
      local left_row = meta.left_index - 1
      vim.api.nvim_buf_set_extmark(self.left_buf, self.extmark_ns, left_row, 0, {
        line_hl_group = final_left_hl,
        hl_mode = "combine",
      })
    end
    -- IMPORTANT: do NOT apply a full-line background on the right for change lines
    -- We render right change/add backgrounds with precise ranges later
    local skip_right_line_hl = (meta.kind == "change" and not meta.filler_right)
    if final_right_hl and meta.right_index and not skip_right_line_hl then
      local right_row = meta.right_index - 1
      vim.api.nvim_buf_set_extmark(self.right_buf, self.extmark_ns, right_row, 0, {
        line_hl_group = final_right_hl,
        hl_mode = "combine",
      })
    end
  end

  -- Apply connector backgrounds and position line numbers; ensure numbers appear on their own rows
  -- For add/delete, use split backgrounds (left vs right portions)
  local core_start_col_base = self.left_number_width  -- left_num
  local right_col_base = core_start_col_base + self.connector_core_width

  for idx, meta in ipairs(self.view.line_meta) do
    local connector_hl = highlight_for_connector(meta)
    local connector_bg_hl = connector_hl or "DiffBanditConnectorContext"
    local same_row = meta.left_index and meta.right_index and meta.left_index == meta.right_index
    if same_row then
      local row = meta.left_index - 1

      -- Split background for add/delete to match IntelliJ's asymmetric gutter coloring
      if meta.kind == "add" then
        -- Normal background on left portion, green background on right portion (from right number onwards)
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorContext", row, 0, right_col_base)
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, row, right_col_base, -1)
      elseif meta.kind == "delete" then
        -- Delete background on left portion, normal background on right portion
        local left_end_col = core_start_col_base + self.connector_core_width
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, row, 0, left_end_col)
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorContext", row, left_end_col, -1)
      else
        -- Change and context: full-line background
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, row, 0, -1)
      end

      local connector_text = meta.connector_text or string.rep(" ", self.connector_core_width)
      local left_number = meta.left_line and format_line_number(meta.left_line, self.left_number_width) or string.rep(" ", self.left_number_width)
      local right_number = meta.right_line and format_line_number_left(meta.right_line, self.right_number_width) or string.rep(" ", self.right_number_width)

      -- Use background-aware highlights for same-row add/delete split backgrounds
      local left_num_hl = (meta.kind == "delete") and "DiffBanditLineNumberLeftDelete" or "DiffBanditLineNumberLeft"
      local right_num_hl = (meta.kind == "add") and "DiffBanditLineNumberRightAdd" or "DiffBanditLineNumberRight"

      local combined_virt = {
        {left_number, left_num_hl},
        {connector_text, "DiffBanditConnectorText"},
        {right_number, right_num_hl},
      }
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, row, 0, {
        virt_text = combined_virt,
        virt_text_pos = "overlay",
      })
    else
      -- Separate rows for left and right numbers
      if meta.left_index then
        local left_row = meta.left_index - 1

        -- For deletions on separate rows, apply delete background only on left portion
        if meta.kind == "delete" then
          local left_end_col = core_start_col_base + self.connector_core_width
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, left_row, 0, left_end_col)
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorContext", left_row, left_end_col, -1)
        elseif meta.kind == "add" then
          -- For additions, left rows get normal background (no colored portion on left side)
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorContext", left_row, 0, -1)
        else
          -- Change and context: full-line background
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, left_row, 0, -1)
        end
        local left_number = meta.left_line and format_line_number(meta.left_line, self.left_number_width) or string.rep(" ", self.left_number_width)

        -- Use background-aware highlights for deletions to show delete background
        local left_num_hl = (meta.kind == "delete") and "DiffBanditLineNumberLeftDelete" or "DiffBanditLineNumberLeft"

        local left_virt = {
          {left_number, left_num_hl},
        }
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, left_row, 0, {
          virt_text = left_virt,
          virt_text_pos = "overlay",
        })
      end

      if meta.right_index then
        local right_row = meta.right_index - 1

        -- For additions on separate rows, apply green background only on right portion
        if meta.kind == "add" then
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorContext", right_row, 0, right_col_base)
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, right_row, right_col_base, -1)
        elseif meta.kind == "delete" then
          -- For deletions, right rows get normal background (no colored portion on right side)
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorContext", right_row, 0, -1)
        else
          -- Change and context: full-line background
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, connector_bg_hl, right_row, 0, -1)
        end
        local right_number = meta.right_line and format_line_number_left(meta.right_line, self.right_number_width) or string.rep(" ", self.right_number_width)

        -- Use background-aware highlights for additions to show green background
        local right_num_hl = (meta.kind == "add") and "DiffBanditLineNumberRightAdd" or "DiffBanditLineNumberRight"

        -- start col for right number: left_num + core
        local right_col_base = self.left_number_width + self.connector_core_width
        local right_virt = {
          {right_number, right_num_hl},
        }
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.linenum_ns, right_row, right_col_base, {
          virt_text = right_virt,
          virt_text_pos = "overlay",
        })
      end
    end
  end

  -- Add full-width backgrounds using extmarks and capture separator anchors
  for idx, meta in ipairs(self.view.line_meta) do
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

    local skip_right_line_hl = (meta.kind == "change" and not meta.filler_right)

    if final_left_hl and final_left_hl ~= "DiffBanditContext" and meta.left_index then
      vim.api.nvim_buf_set_extmark(self.left_buf, self.extmark_ns, meta.left_index - 1, 0, {
        line_hl_group = final_left_hl,
        hl_mode = "combine",
      })
    end

    if final_right_hl and final_right_hl ~= "DiffBanditContext" and meta.right_index and not skip_right_line_hl then
      vim.api.nvim_buf_set_extmark(self.right_buf, self.extmark_ns, meta.right_index - 1, 0, {
        line_hl_group = final_right_hl,
        hl_mode = "combine",
      })
    end

    if meta.kind == "add" then
      chunk_edges[meta.chunk] = chunk_edges[meta.chunk] or {}
      local edge = chunk_edges[meta.chunk]
      if meta.left_index then
        edge.add_left = edge.add_left or {}
        edge.add_left[#edge.add_left + 1] = meta.left_index - 1
      end
    elseif meta.kind == "delete" then
      chunk_edges[meta.chunk] = chunk_edges[meta.chunk] or {}
      local edge = chunk_edges[meta.chunk]
      if meta.right_index then
        edge.delete_right = edge.delete_right or {}
        edge.delete_right[#edge.delete_right + 1] = meta.right_index - 1
      end
    elseif meta.kind == "change" and meta.left_index and meta.right_index then
      local left_line = self.left.lines and self.left.lines[meta.left_line] or nil
      local right_line = self.right.lines and self.right.lines[meta.right_line] or nil
      if left_line and right_line then
        local diff_mod = require("diffbandit.diff")
        local spans = diff_mod.changed_spans(left_line, right_line)
        local row_l = meta.left_index - 1
        local row_r = meta.right_index - 1

        pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, 0, {
          hl_group = "DiffBanditChangeLeft",
          end_row = row_l,
          end_col = -1,
          hl_eol = true,
        })
        for _, sp in ipairs(spans.left or {}) do
          local s, e = sp[1] - 1, sp[2]
          pcall(vim.api.nvim_buf_add_highlight, self.left_buf, self.ns, "DiffBanditChangeEmphasis", row_l, s, e)
        end

        local right_line_len = spans.right_len or #right_line
        local change_end = spans.change_end or spans.prefix_len

        -- Change segment (blue): show even for pure additions, up to add_start
        local add_start = spans.add_start and (spans.add_start - 1) or change_end
        local blue_end = math.min(add_start, right_line_len)
        if blue_end > 0 then
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
            end_row = row_r,
            end_col = blue_end,
            hl_group = "DiffBanditChangeRight",
            hl_eol = false,
            hl_mode = "replace",
            priority = 5000,
          })
        end

        -- Word emphasis only within the blue change span
        for _, sp in ipairs(spans.right_changes or {}) do
          local s = sp[1] - 1
          local e = math.min(sp[2], blue_end)
          if s < e then
            pcall(vim.api.nvim_buf_add_highlight, self.right_buf, self.ns, "DiffBanditChangeEmphasis", row_r, s, e)
          end
        end

        -- Added suffix (green): from add_start to end-of-line, extend to window edge
        if add_start < right_line_len then
          -- Color the added text span itself
          pcall(vim.api.nvim_buf_add_highlight, self.right_buf, self.ns, "DiffBanditAdd", row_r, add_start, right_line_len)
          -- Then extend to the end of line (and to the window edge) from the last character
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
  end

  -- Apply underline separators for additions (left side) and deletions (right side)
  for _, edge in pairs(chunk_edges) do
    if edge.add_left and #edge.add_left > 0 then
      local row = edge.add_left[1]
      pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row, 0, {
        hl_group = "DiffBanditAddLeftSeparator",
        end_row = row,
        end_col = -1,
        hl_eol = true,
      })
      pcall(vim.api.nvim_buf_set_extmark, self.connector_buf, self.extmark_ns, row, 0, {
        hl_group = "DiffBanditAddLeftSeparator",
        end_row = row,
        end_col = -1,
        hl_eol = true,
      })
    end
    if edge.delete_right and #edge.delete_right > 0 then
      local row = edge.delete_right[1]
      local function underline(buf)
        pcall(vim.api.nvim_buf_set_extmark, buf, self.extmark_ns, row, 0, {
          hl_group = "DiffBanditDeleteRightSeparator",
          end_row = row,
          end_col = -1,
          hl_eol = true,
        })
      end
      underline(self.right_buf)
      underline(self.connector_buf)
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
  local core_start_col = self.left_number_width  -- left_num
  local core_end_col = core_start_col + self.connector_core_width - 1
  local gutter_end_col = core_end_col + 1
  local function lane_col(lane)
    -- lanes are 1-indexed; columns inside core are spaced by 2: 0,2,4...
    return core_start_col + (lane - 1) * 2 + 1
  end

  for _, p in ipairs(paths) do
    if p.kind == "add" or p.kind == "delete" then
      local col = lane_col(math.max(1, p.lane))
      local fg_group = (p.kind == "add") and "DiffBanditConnectorAddLine" or "DiffBanditConnectorDeleteLine"
      local top_row = (p.top or p.start_row) - 1
      local bottom_row = p.end_row - 1

      -- Only render top horizontal/curve if there's no origin line (p.top not set)
      -- Origin lines already have connector symbols in their connector_text
      if not p.top then
        -- Top horizontal within connector core area (don't overlap left numbers)
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

      -- Vertical spine down the lane (skip top/bottom rows where tees will go)
      for r = p.start_row + 1, p.end_row - 1 do
        vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, r - 1, col, {
          virt_text = { {"│", fg_group} },
          virt_text_pos = "overlay",
        })
      end

      -- Top tee (first row of add/delete region) for visual transition
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, p.start_row - 1, col, {
        virt_text = {
          {(p.kind == "add") and "├" or "┤", fg_group},
        },
        virt_text_pos = "overlay",
      })

      -- Bottom tee (last row of add/delete region) for visual transition
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, bottom_row, col, {
        virt_text = {
          {(p.kind == "add") and "├" or "┤", fg_group},
        },
        virt_text_pos = "overlay",
      })
    elseif p.kind == "change" then
      local fg_group = "DiffBanditConnectorChangeLine"
      local row_top = p.start_row - 1
      local row_bot = p.end_row - 1
      local line = string.rep("─", math.max(0, self.connector_core_width))
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row_top, core_start_col, {
        virt_text = { {line, fg_group} },
        virt_text_pos = "overlay",
      })
      vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row_bot, core_start_col, {
        virt_text = { {line, fg_group} },
        virt_text_pos = "overlay",
      })
    end
  end

  -- Debug: Check highlights on row 0 at the END of render()
  print("=== AT END OF RENDER ===")
  local final_highlights = vim.api.nvim_buf_get_extmarks(self.right_buf, self.ns, {0, 0}, {0, -1}, {details = true})
  print("Highlights in self.ns on row 0 at END of render:")
  for _, mark in ipairs(final_highlights) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    print(string.format("  id=%d, col=%d, end_col=%s, hl_group=%s", id, col, tostring(details.end_col), tostring(details.hl_group)))
  end

  -- Debug: Check actual colors of the highlight groups
  print("\n=== HIGHLIGHT GROUP COLORS ===")
  local change_right_hl = vim.api.nvim_get_hl(0, {name = "DiffBanditChangeRight"})
  local add_hl = vim.api.nvim_get_hl(0, {name = "DiffBanditAdd"})
  print(string.format("DiffBanditChangeRight: bg=%s, fg=%s", tostring(change_right_hl.bg), tostring(change_right_hl.fg)))
  print(string.format("DiffBanditAdd: bg=%s, fg=%s", tostring(add_hl.bg), tostring(add_hl.fg)))
end

function Session:highlight_active_chunk(chunk)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.active_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.active_ns, 0, -1)

  -- Highlight using buffer-specific indices from metadata
  for meta_idx = chunk.display_start, chunk.display_end do
    local meta = self.view.line_meta[meta_idx]
    if meta then
      -- Skip active chunk highlighting for change lines - they have special blue/green backgrounds
      local is_change_line = (meta.kind == "change" and not meta.filler_left and not meta.filler_right)

      -- Highlight left buffer if this metadata has a left line
      if meta.left_index and not is_change_line then
        vim.api.nvim_buf_add_highlight(self.left_buf, self.active_ns, "DiffBanditActiveChunk", meta.left_index - 1, 0, -1)
        -- Also highlight connector at the same vertical position
        vim.api.nvim_buf_add_highlight(self.connector_buf, self.active_ns, "DiffBanditActiveChunk", meta.left_index - 1, 0, -1)
      end

      -- Highlight right buffer if this metadata has a right line
      if meta.right_index and not is_change_line then
        vim.api.nvim_buf_add_highlight(self.right_buf, self.active_ns, "DiffBanditActiveChunk", meta.right_index - 1, 0, -1)
        -- Also highlight connector at the same vertical position if no left index
        if not meta.left_index then
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.active_ns, "DiffBanditActiveChunk", meta.right_index - 1, 0, -1)
        end
      end
    end
  end

  -- Position cursor at the start of the chunk
  local first_meta = self.view.line_meta[chunk.display_start]
  if first_meta then
    local connector_pos = first_meta.left_index or first_meta.right_index or 1
    if first_meta.left_index then
      vim.api.nvim_win_set_cursor(self.left_win, { first_meta.left_index, 0 })
    end
    if first_meta.right_index then
      vim.api.nvim_win_set_cursor(self.right_win, { first_meta.right_index, 0 })
    end
    vim.api.nvim_win_set_cursor(self.connector_win, { connector_pos, 0 })
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
