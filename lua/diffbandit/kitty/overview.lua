-- Image overview: the overview strip beside each pane drawn as one Kitty
-- image per side, at pixel resolution (see kitty/overview_raster.lua).
--
-- The overview sidecar buffer is already static (line r is screen row r and
-- it never scrolls), so its own text is the placeholder grid: no float is
-- needed. The image is re-rasterized and re-sent only when the marks, the
-- strip size, the cell size or the palette change. The viewport band and
-- the cursor row are cell backgrounds (per-row highlight groups that keep
-- the image id as foreground) showing through the transparent pixels, so
-- scrolling and cursor moves only swap highlights.
local canvas = require("diffbandit.kitty.canvas")
local detect = require("diffbandit.kitty.detect")
local protocol = require("diffbandit.kitty.protocol")
local overview_raster = require("diffbandit.kitty.overview_raster")

local M = {}

local function hl_bg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl and hl.bg or nil
end

-- Placeholder groups: fg encodes the image id, bg is the cell background
-- shown through transparent pixels (context, viewport band, cursor row).
local function ensure_groups(st)
  local groups = {
    base = { name = st.hl, bg = hl_bg("DiffBanditOverviewContext") },
    viewport = { name = st.hl .. "Viewport", bg = hl_bg("DiffBanditOverviewViewport") },
    cursor = { name = st.hl .. "Cursor", bg = hl_bg("DiffBanditOverviewCursorBand") },
    selection = { name = st.hl .. "Selection", bg = hl_bg("DiffBanditOverviewSelection") },
  }
  for _, g in pairs(groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = g.name, link = false })
    if not (ok and hl and hl.fg == st.id and hl.bg == g.bg) then
      vim.api.nvim_set_hl(0, g.name, { fg = protocol.id_to_hex(st.id), bg = g.bg })
    end
  end
  return groups
end

local function palette(config)
  local base, key = canvas.palette(config)
  local out = { add = base.add, delete = base.delete, change = base.change }
  out.outline = canvas.image_rgb(config, "DiffBanditOverviewCursor", "fg")
    or canvas.image_rgb(config, "Normal", "fg")
  out.search = canvas.image_rgb(config, "DiffBanditOverviewSearch", "fg")
  local parts = { key, table.concat(out.outline or { "-" }, ","), table.concat(out.search or { "-" }, ",") }
  out.diagnostics = {}
  for sev, name in ipairs({ "Error", "Warn", "Info", "Hint" }) do
    out.diagnostics[sev] = canvas.image_rgb(config, "DiffBanditOverviewDiag" .. name, "fg")
    parts[#parts + 1] = table.concat(out.diagnostics[sev] or { "-" }, ",")
  end
  return out, table.concat(parts, ";")
end

local function set_placeholder_lines(st, buf, cols, rows)
  local key = cols .. "x" .. rows
  if st.lines_key == key and st.lines_buf == buf then
    return true
  end
  local lines = {}
  for r = 0, rows - 1 do
    local run = protocol.placeholder_run(r, 0, cols)
    if not run then
      return false
    end
    lines[#lines + 1] = run
  end
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  st.lines_key, st.lines_buf = key, buf
  return true
end

--- Whether a strip of cols x rows cells can be addressed by placeholders.
function M.fits(cols, rows)
  return cols >= 1 and rows >= 1 and cols <= protocol.MAX_INDEX + 1 and rows <= protocol.MAX_INDEX + 1
end

--- Paint one side. opts = { buf, ns, marks, line_count, map_lines?, rows,
--- cols, overlays (util/overview row_overlays: band, selection,
--- cursor_row, 1-based rows), search_lines?, diagnostics?, code? = { runs, key } }.
--- Returns false when the strip cannot be drawn as an image (the caller
--- then draws cells), true otherwise.
function M.paint(host, side, opts)
  local buf = opts.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) or not M.fits(opts.cols, opts.rows) then
    M.destroy_side(host, side)
    return false
  end
  host.kitty_overview_states = host.kitty_overview_states or {}
  local st = host.kitty_overview_states[side]
  if not st then
    st = canvas.new_state()
    st.host = host
    host.kitty_overview_states[side] = st
  end
  local groups = ensure_groups(st)
  if not set_placeholder_lines(st, buf, opts.cols, opts.rows) then
    M.destroy_side(host, side)
    return false
  end

  local cell = detect.cell_size(host.config)
  local pal, pal_key = palette(host.config)
  -- Cursor moves and scrolling repaint only highlights: reuse the spans and
  -- their key while the marks table (providers cache it) and line count are
  -- the same, and the search key while the search result table is.
  local memo = st.overview_memo or {}
  st.overview_memo = memo
  if memo.marks ~= opts.marks or memo.line_count ~= opts.line_count then
    memo.marks, memo.line_count = opts.marks, opts.line_count
    memo.spans = overview_raster.spans(opts.marks)
    memo.spans_key = overview_raster.spans_key(memo.spans, opts.line_count)
  end
  local spans = memo.spans
  local map_lines = opts.map_lines or opts.line_count
  local search_lines = opts.search_lines or {}
  if memo.search ~= search_lines then
    memo.search = search_lines
    memo.search_key = table.concat(search_lines, ",")
  end
  local diag_parts = {}
  for _, d in ipairs(opts.diagnostics or {}) do
    diag_parts[#diag_parts + 1] = d.line .. ":" .. d.severity
  end
  local key = table.concat({
    table.concat(diag_parts, ","),
    opts.cols, opts.rows, cell.w, cell.h, pal_key, memo.spans_key,
    tostring(map_lines), memo.search_key, opts.code and opts.code.key or "-",
  }, "|")
  if key ~= st.last_key then
    local spec = {
      line_count = opts.line_count,
      map_lines = map_lines,
      cols = opts.cols,
      rows = opts.rows,
      cell_w = cell.w,
      cell_h = cell.h,
      palette = pal,
      search_lines = search_lines,
      diagnostics = opts.diagnostics,
      code = opts.code,
    }
    local bytes, width, height = overview_raster.render(spans, spec)
    canvas.transmit(host, st, bytes, width, height, { cols = opts.cols, rows = opts.rows })
    st.last_key = key
    st.last_spans = spans
  end

  vim.api.nvim_buf_clear_namespace(buf, opts.ns, 0, -1)
  local ov = opts.overlays or {}
  local function within(range, row)
    return range ~= nil and row >= range.first and row <= range.last
  end
  for row = 1, opts.rows do
    local g = groups.base
    if ov.cursor_row == row then
      g = groups.cursor
    elseif within(ov.selection, row) then
      g = groups.selection
    elseif within(ov.band, row) then
      g = groups.viewport
    end
    vim.api.nvim_buf_add_highlight(buf, opts.ns, g.name, row - 1, 0, -1)
  end
  return true
end

--- Forget transmitted images so the next paint re-sends them.
function M.invalidate(host)
  for _, st in pairs(host.kitty_overview_states or {}) do
    st.last_key = nil
  end
end

function M.destroy_side(host, side)
  local states = host.kitty_overview_states
  local st = states and states[side]
  if st then
    canvas.destroy_state(st)
    states[side] = nil
  end
end

--- Delete both sides' images (renderer flip to cells, session close).
function M.destroy(host)
  for side in pairs(host.kitty_overview_states or {}) do
    M.destroy_side(host, side)
  end
  host.kitty_overview_states = nil
end

return M
