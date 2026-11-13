-- Separator bridges for the cell (glyph) connector renderer.
--
-- Neovim always keeps a separator column between side-by-side windows, so
-- the two separators between the number panes and the connector core would
-- otherwise sit as a blank cell between a triangle/wedge and the underline,
-- rail end or change band it connects to. Both separators are hidden
-- (util/layout.win_opts.gutter(nil, true)); a one-column float over each one
-- copies the styling of the connector cell beside it (the core's first
-- column for the screen-left separator, its last column for the
-- screen-right one): backgrounds and the active-chunk tint, plus blank
-- underline runs. Glyphs (rails) stay in the core, so a rail running down
-- the core's edge column never leaks into the bridge.
--
-- The outer separators (document | number pane) stay visible, but on band
-- rows they would cut the band in two (document band | separator | number
-- band). A float over each of them keeps the separator glyph on plain rows,
-- takes the band colour where the number pane's outer cell carries one, and
-- underlines the glyph where that cell is underlined (an insertion point),
-- so bands and insertion lines run unbroken from one document to the other.
-- Number panes scroll with their documents, so these follow the number
-- window's own topline. (The image renderer has its own edges.)
--
-- The floats hold one line per screen row and are recomputed from the
-- connector buffer's extmarks on every paint and on WinScrolled, which
-- fires before the redraw, so scrolling never shows a stale bridge.
-- State is keyed by connector window: merge rebuilds its pair renderers but
-- keeps their windows, so the floats survive a rebuild.
local winbar = require("diffbandit.util.winbar")

local M = {}

local ns = vim.api.nvim_create_namespace("DiffBanditSeparatorBridge")
local BASE_HL = "DiffBanditConnectorContext"
local SPLIT_HL = "DiffBanditSplit"
local EDGES = { "left", "right", "outer_left", "outer_right" }

-- connector win -> { host, left, right, outer_left, outer_right = edge }
local bridges = {}
local group = nil

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function close_edge(edge)
  if edge and valid_win(edge.win) then
    pcall(vim.api.nvim_win_close, edge.win, true)
  end
  if edge then
    edge.win = nil
    edge.cfg_key = nil
  end
end

local function close_entry(conn_win)
  local entry = bridges[conn_win]
  if not entry then
    return
  end
  for _, key in ipairs(EDGES) do
    close_edge(entry[key])
  end
  bridges[conn_win] = nil
end

--- Screen-left number window of a host (merge's result→remote pair mirrors
--- its sides, so its "right" number pane is on screen left).
local function screen_left_num_win(host)
  if host.mirror_connector_sides then
    return host.right_num_win
  end
  return host.left_num_win
end

local function screen_right_num_win(host)
  if host.mirror_connector_sides then
    return host.left_num_win
  end
  return host.right_num_win
end

local function vert_char()
  local ok, fc = pcall(function()
    return vim.opt_global.fillchars:get()
  end)
  local ch = ok and fc and fc.vert or nil
  return (ch and ch ~= "" and ch ~= " ") and ch or "│"
end

local function covers(mark_row, mark_col, d, row, col)
  local end_row = d.end_row or mark_row
  local end_col = d.end_col or mark_col
  if row < mark_row or row > end_row then
    return false
  end
  if row == mark_row and col < mark_col then
    return false
  end
  -- An end at column 0 of a later row is exclusive of that row.
  if row == end_row and end_row > mark_row and end_col == 0 then
    return false
  end
  if row == end_row and col >= end_col and not d.hl_eol then
    return false
  end
  return true
end

--- Styling of buffer row `row`, column `col` (0-based) as the bridge copies
--- it: { kind = "hl" | "overlay", hl, priority, hl_mode } per mark covering
--- the cell (overlay glyphs other than blanks are skipped).
local function edge_styles(marks, row, col)
  local out = {}
  for _, m in ipairs(marks) do
    local mrow, mcol, d = m[2], m[3], m[4]
    if d.virt_text and d.virt_text_pos == "overlay" then
      if mrow == row and col >= mcol then
        local offset = col - mcol
        for _, chunk in ipairs(d.virt_text) do
          local text = chunk[1] or ""
          local w = vim.fn.strdisplaywidth(text)
          if offset < w then
            -- Only blank (underline/background) runs carry across; a glyph
            -- at the edge is a rail end, which belongs to the core.
            if vim.fn.strcharpart(text, offset, 1) == " " then
              out[#out + 1] = { kind = "overlay", hl = chunk[2], priority = d.priority or 4096, hl_mode = d.hl_mode }
            end
            break
          end
          offset = offset - w
        end
      end
    elseif d.hl_group and covers(mrow, mcol, d, row, col) then
      out[#out + 1] = { kind = "hl", hl = d.hl_group, priority = d.priority or 4096 }
    end
  end
  return out
end

local function edge_buf(edge, rows, text)
  if not (edge.buf and vim.api.nvim_buf_is_valid(edge.buf)) then
    edge.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[edge.buf].bufhidden = "wipe"
    vim.bo[edge.buf].buftype = "nofile"
    vim.bo[edge.buf].swapfile = false
    vim.bo[edge.buf].undolevels = -1
    edge.lines_key = nil
  end
  local key = rows .. ":" .. text
  if edge.lines_key ~= key then
    local lines = {}
    for r = 1, rows do
      lines[r] = text
    end
    vim.bo[edge.buf].modifiable = true
    vim.api.nvim_buf_set_lines(edge.buf, 0, -1, false, lines)
    vim.bo[edge.buf].modifiable = false
    edge.lines_key = key
  end
  return edge.buf
end

local function place(edge, buf, cfg, base_hl)
  local key = table.concat({ cfg.row, cfg.col, cfg.height }, ":")
  if valid_win(edge.win) then
    if edge.cfg_key ~= key then
      pcall(vim.api.nvim_win_set_config, edge.win, cfg)
      edge.cfg_key = key
    end
    return
  end
  local open_cfg = vim.tbl_extend("force", cfg, { style = "minimal", noautocmd = true, mouse = false })
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, open_cfg)
  if not ok then
    open_cfg.mouse = nil
    ok, win = pcall(vim.api.nvim_open_win, buf, false, open_cfg)
  end
  if not ok then
    return
  end
  vim.wo[win].winhighlight = table.concat({
    "Normal:" .. base_hl, "NormalNC:" .. base_hl, "NormalFloat:" .. base_hl, "EndOfBuffer:" .. base_hl,
  }, ",")
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].winblend = 0
  vim.wo[win].fillchars = "eob: "
  edge.win = win
  edge.cfg_key = key
end

local function paint_inner(buf, marks, topline, rows, line_count, col)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for r = 0, rows - 1 do
    local row = topline - 1 + r
    if row >= line_count then
      break
    end
    for _, style in ipairs(edge_styles(marks, row, col)) do
      if style.kind == "hl" then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, {
          end_row = r,
          end_col = 1,
          hl_group = style.hl,
          priority = style.priority,
        })
      else
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, {
          virt_text = { { " ", style.hl } },
          virt_text_pos = "overlay",
          hl_mode = style.hl_mode or "combine",
          priority = style.priority,
        })
      end
    end
  end
end

-- Resolved highlight attributes, cached for one refresh pass.
local function resolver()
  local cache = {}
  return function(name)
    if type(name) == "table" then
      name = name[#name]
    end
    if not name then
      return {}
    end
    local hl = cache[name]
    if not hl then
      local ok, got = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
      hl = ok and got or {}
      cache[name] = hl
    end
    return hl
  end
end

-- Separator glyph underlined like `name` (the underline colour is its sp).
local function underline_group(name, resolve)
  local group = "DiffBanditBridgeUnderline" .. tostring(name):gsub("%W", "")
  local split = resolve(SPLIT_HL)
  local hl = resolve(name)
  vim.api.nvim_set_hl(0, group, { fg = split.fg, bg = split.bg, underline = true, sp = hl.sp or hl.fg })
  return group
end

-- Outer separator rows from the number pane's outer cell: the band colour
-- (blank cell) where it has a non-context background, else the separator
-- glyph, underlined where the cell is underlined.
local function paint_outer(buf, marks, topline, rows, line_count, col, glyph, resolve)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local context_bg = resolve(BASE_HL).bg
  local underlines = {}
  for r = 0, rows - 1 do
    local row = topline - 1 + r
    if row >= line_count then
      break
    end
    local band, band_prio, underline = nil, -1, nil
    for _, style in ipairs(edge_styles(marks, row, col)) do
      local hl = resolve(style.hl)
      if hl.bg and hl.bg ~= context_bg and style.priority >= band_prio then
        band, band_prio = style.hl, style.priority
      end
      if hl.underline then
        underline = style.hl
      end
    end
    local chunk
    if band then
      chunk = { " ", underline and { band, underline } or band }
    elseif underline then
      local key = type(underline) == "table" and underline[#underline] or underline
      underlines[key] = underlines[key] or underline_group(key, resolve)
      chunk = { glyph, underlines[key] }
    end
    if chunk then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, {
        virt_text = { chunk },
        virt_text_pos = "overlay",
        priority = 200,
      })
    end
  end
end

local FLOAT = { relative = "editor", width = 1, focusable = false, zindex = 1, border = "none" }

local function float_cfg(row, col, height)
  return vim.tbl_extend("force", FLOAT, { row = row, col = col, height = height })
end

-- Outer bridge for one number window: `sep_col` is the separator's screen
-- column, `src_col` the number pane cell it takes its style from.
local function refresh_outer(edge, num_win, sep_col, src_col, glyph, resolve)
  if sep_col < 0 or sep_col >= vim.o.columns then
    close_edge(edge)
    return
  end
  local buf = vim.api.nvim_win_get_buf(num_win)
  local rows = vim.fn.winheight(num_win)
  if rows < 1 then
    close_edge(edge)
    return
  end
  local topline = vim.fn.line("w0", num_win)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { topline - 1, 0 }, { topline - 1 + rows, -1 }, {
    details = true,
    overlap = true,
  })
  local ebuf = edge_buf(edge, rows, glyph)
  paint_outer(ebuf, marks, topline, rows, vim.api.nvim_buf_line_count(buf), src_col, glyph, resolve)
  local row = vim.api.nvim_win_get_position(num_win)[1] + winbar.rows(num_win)
  place(edge, ebuf, float_cfg(row, sep_col, rows), SPLIT_HL)
end

local function refresh_entry(conn_win, entry)
  local host = entry.host
  local num_win = screen_left_num_win(host)
  local buf = host.connector_buf
  local right_num = screen_right_num_win(host)
  if host.disposed or host.connector_win ~= conn_win
      or not valid_win(conn_win) or not valid_win(num_win) or not valid_win(right_num)
      or not (buf and vim.api.nvim_buf_is_valid(buf)) then
    close_entry(conn_win)
    return
  end
  -- Editor-relative floats open in the current tab; a background tab waits
  -- for TabEnter.
  if vim.api.nvim_win_get_tabpage(conn_win) ~= vim.api.nvim_get_current_tabpage() then
    return
  end
  local pos = vim.api.nvim_win_get_position(conn_win)
  local core_width = vim.api.nvim_win_get_width(conn_win)
  local rows = vim.fn.winheight(conn_win)
  if rows < 1 or core_width < 1 then
    for _, key in ipairs(EDGES) do
      close_edge(entry[key])
    end
    return
  end
  local row = pos[1] + winbar.rows(conn_win)
  local topline = vim.fn.line("w0", conn_win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { topline - 1, 0 }, { topline - 1 + rows, -1 }, {
    details = true,
    overlap = true,
  })
  local num_pos = vim.api.nvim_win_get_position(num_win)
  local sides = {
    { key = "left", col = num_pos[2] + vim.api.nvim_win_get_width(num_win), core_col = 0 },
    { key = "right", col = pos[2] + core_width, core_col = core_width - 1 },
  }
  for _, side in ipairs(sides) do
    local edge = entry[side.key]
    if side.col >= vim.o.columns then
      close_edge(edge)
    else
      local ebuf = edge_buf(edge, rows, " ")
      paint_inner(ebuf, marks, topline, rows, line_count, side.core_col)
      place(edge, ebuf, float_cfg(row, side.col, rows), BASE_HL)
    end
  end

  local resolve = resolver()
  local glyph = vert_char()
  local right_pos = vim.api.nvim_win_get_position(right_num)
  local right_width = vim.api.nvim_win_get_width(right_num)
  refresh_outer(entry.outer_left, num_win, num_pos[2] - 1, 0, glyph, resolve)
  refresh_outer(entry.outer_right, right_num, right_pos[2] + right_width, right_width - 1, glyph, resolve)
end

local function refresh_all()
  for conn_win, entry in pairs(bridges) do
    refresh_entry(conn_win, entry)
  end
end

local function install()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("DiffBanditSeparatorBridge", { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized", "TabEnter" }, {
    group = group,
    callback = refresh_all,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      for conn_win, entry in pairs(bridges) do
        local host = entry.host
        if closed == conn_win or closed == host.left_num_win or closed == host.right_num_win then
          vim.schedule(function()
            close_entry(conn_win)
          end)
        end
      end
    end,
  })
end

--- Paint (or re-place) the bridges of a cell-rendered host.
function M.paint(host)
  local conn_win = host.connector_win
  if not valid_win(conn_win) then
    return
  end
  install()
  local entry = bridges[conn_win]
  if not entry then
    entry = { left = {}, right = {}, outer_left = {}, outer_right = {} }
    bridges[conn_win] = entry
  end
  entry.host = host
  refresh_entry(conn_win, entry)
end

--- Remove a host's bridges (image renderer took over, or the view closed).
function M.close(host)
  if host and host.connector_win then
    close_entry(host.connector_win)
  end
end

--- Screen cells of every hidden (inner) bridged separator in the current
--- tab, for test
--- captures: { { win, col, row, top, bottom }, ... } (0-based; `row` is the
--- float's first screen row, top..bottom the separator's full height
--- including a winbar row).
--- opts.outer lists the document | number pane separators instead; each
--- then has `side` ("left": number pane to its right, "right": to its left).
function M.separator_cells(opts)
  local outer = opts and opts.outer
  local out = {}
  local tab = vim.api.nvim_get_current_tabpage()
  for conn_win, entry in pairs(bridges) do
    if valid_win(conn_win) and vim.api.nvim_win_get_tabpage(conn_win) == tab then
      local edges = outer and { entry.outer_left, entry.outer_right } or { entry.left, entry.right }
      for i, edge in ipairs(edges) do
        if valid_win(edge.win) then
          local cfg = vim.api.nvim_win_get_config(edge.win)
          local top = vim.api.nvim_win_get_position(conn_win)[1]
          out[#out + 1] = {
            win = edge.win,
            col = math.floor(tonumber(cfg.col) or 0),
            row = math.floor(tonumber(cfg.row) or 0),
            top = top,
            bottom = top + vim.api.nvim_win_get_height(conn_win) - 1,
            side = i == 1 and "left" or "right",
          }
        end
      end
    end
  end
  return out
end

--- Bridge float windows of a host, for tests:
--- { left, right, outer_left, outer_right = win? }.
function M.windows(host)
  local entry = host and bridges[host.connector_win]
  if not entry then
    return {}
  end
  return {
    left = entry.left.win,
    right = entry.right.win,
    outer_left = entry.outer_left.win,
    outer_right = entry.outer_right.win,
  }
end

return M
