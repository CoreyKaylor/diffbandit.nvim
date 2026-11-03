-- Pixel overview strip for the image overview (pure: no Neovim API).
--
-- The cell overview projects every changed line onto one of `rows` screen
-- rows, so hunks that share a row collapse into one block. The image gives
-- every hunk its own mark at its exact proportional position: with an
-- 18-24px line, the strip has roughly 20x the vertical resolution.
--
-- Marks are horizontal bars, so every pixel row is uniform apart from its
-- left/right inset columns. Each row is therefore two RGBA values ("edge"
-- for the inset columns, "inner" for the rest), expanded into bytes at the
-- end. The inset leaves a transparent margin around marks so the cell
-- background (viewport band, cursor row) shows on both sides of a mark. The
-- current chunk's outline is drawn in that margin.
local M = {}

local floor, max, min = math.floor, math.max, math.min

-- Paint order: later kinds win where marks overlap (same as the cell
-- overview's same-row priority).
local KIND_PRIORITY = { delete = 1, add = 2, change = 3 }

--- Group per-line marks (overview.build_marks output) into contiguous spans
--- of the same kind and current-chunk flag. Returns spans sorted by line:
--- { first, last, kind, current }.
function M.spans(marks)
  local sorted = {}
  for _, mark in ipairs(marks or {}) do
    if mark.line and KIND_PRIORITY[mark.kind] then
      sorted[#sorted + 1] = mark
    end
  end
  table.sort(sorted, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return (KIND_PRIORITY[a.kind] or 0) < (KIND_PRIORITY[b.kind] or 0)
  end)
  local spans = {}
  local cur
  for _, mark in ipairs(sorted) do
    local current = mark.current == true
    if cur and cur.kind == mark.kind and cur.current == current and mark.line <= cur.last + 1 then
      cur.last = max(cur.last, mark.line)
    else
      cur = { first = mark.line, last = mark.line, kind = mark.kind, current = current }
      spans[#spans + 1] = cur
    end
  end
  return spans
end

--- Stable key for the raster inputs that depend on the marks.
function M.spans_key(spans, line_count)
  local parts = { tostring(line_count) }
  for _, s in ipairs(spans) do
    parts[#parts + 1] = s.first .. "-" .. s.last .. (s.kind:sub(1, 1)) .. (s.current and "*" or "")
  end
  return table.concat(parts, ",")
end

-- Straight-alpha source-over of opaque `rgb` at coverage `a` onto px.
local function blend(px, rgb, a)
  if a <= 0 then
    return
  end
  if a >= 1 then
    px[1], px[2], px[3], px[4] = rgb[1], rgb[2], rgb[3], 1
    return
  end
  local da = px[4]
  local inv = da * (1 - a)
  local oa = a + inv
  px[1] = (rgb[1] * a + px[1] * inv) / oa
  px[2] = (rgb[2] * a + px[2] * inv) / oa
  px[3] = (rgb[3] * a + px[3] * inv) / oa
  px[4] = oa
end

-- Paint the vertical extent [y0, y1) (fractional px) into one column class,
-- with exact coverage on the partial top/bottom rows.
local function paint(column, h, y0, y1, rgb, alpha)
  if not rgb or y1 <= y0 then
    return
  end
  alpha = alpha or 1
  for py = max(0, floor(y0)), min(h - 1, math.ceil(y1) - 1) do
    local cov = min(y1, py + 1) - max(y0, py)
    if cov > 0 then
      blend(column[py], rgb, min(1, cov) * alpha)
    end
  end
end

-- Widen [y0, y1) to at least `thick` px, kept inside [0, h). A widened mark
-- starts on the whole pixel holding its first line, so it stays crisp
-- instead of straddling two half-covered pixel rows.
local function at_least(y0, y1, thick, h)
  -- Marks are rectangles: snap both edges to whole pixels so they stay crisp
  -- (a fractional edge would add a half-intensity row that reads as a seam).
  y0, y1 = floor(y0 + 0.5), floor(y1 + 0.5)
  if y1 - y0 >= thick then
    return y0, y1
  end
  y1 = y0 + thick
  if y0 < 0 then
    y0, y1 = 0, thick
  elseif y1 > h then
    y0, y1 = h - thick, h
  end
  return max(0, y0), min(h, y1)
end

local function byte(v)
  return floor(v + 0.5)
end

local function encode(px)
  if px[4] <= 0 then
    return "\0\0\0\0"
  end
  return string.char(byte(px[1]), byte(px[2]), byte(px[3]), byte(px[4] * 255))
end

--- Pixel layout for a strip: width/height, inset, minimum mark height and
--- outline thickness (px). Exposed for tests.
function M.metrics(spec)
  local cw, ch = spec.cell_w, spec.cell_h
  local w, h = spec.cols * cw, spec.rows * ch
  local inset = spec.inset
  if inset == nil then
    inset = w >= 5 and max(1, floor(cw / 8)) or 0
  end
  inset = max(0, min(inset, floor((w - 1) / 2)))
  local char_px = spec.char_px or M.char_px(cw)
  -- A code layer built for more columns than fit (the compact strip shares
  -- the wide strip's columns) is squeezed: characters become fractional
  -- pixels, blended by coverage, so the silhouette survives.
  local columns = spec.code and spec.code.columns
  if columns and columns > 0 then
    char_px = min(char_px, max(1, w - 2 * inset) / columns)
  end
  return {
    width = w,
    height = h,
    inset = inset,
    min_px = spec.min_px or max(2, floor(ch / 10 + 0.5)),
    outline_px = max(1, inset),
    char_px = char_px,
  }
end

--- Code-shape character width in px for a cell `cell_w` px wide: 1px at
--- ordinary DPI, 2px on HiDPI cells, so a 12-cell strip holds ~120 columns.
function M.char_px(cell_w)
  return max(1, floor((cell_w or 10) / 8))
end

--- Columns of text the code-shape strip can show.
function M.code_columns(spec)
  local m = M.metrics(spec)
  return max(1, floor((m.width - 2 * m.inset) / m.char_px))
end

--- Pixel extent [y0, y1) of a span before the minimum-height rule.
function M.span_extent(span, line_count, height)
  line_count = max(1, line_count or 1)
  local first = max(1, min(line_count, span.first))
  local last = max(first, min(line_count, span.last))
  return (first - 1) * height / line_count, last * height / line_count
end

-- Overlay runs: per pixel row, { x0, x1, rgb, alpha } painted per pixel on
-- top of the row's edge/inner background.
local function add_run(overlay, py, x0, x1, rgb, alpha)
  local row = overlay[py]
  if not row then
    row = {}
    overlay[py] = row
  end
  row[#row + 1] = { x0, x1, rgb, alpha }
end

-- Code shape: each line's text as char_px-wide pixels. Lines taller than
-- 2px leave a gap below the text (glyphs ~70% of the line); thinner lines
-- share pixel rows and blend by coverage.
local function code_runs(overlay, code, m, map_lines, h)
  local lp = h / max(1, map_lines)
  local glyph = lp >= 2 and max(1, floor(lp * 0.7)) or lp
  local x_max = m.width - m.inset
  for line, runs in pairs(code.runs or {}) do
    local y0 = (line - 1) * lp
    local py0, py1, alpha
    if lp >= 2 then
      py0 = floor(y0)
      py1 = py0 + glyph - 1
      alpha = 0.9
    else
      py0 = floor(y0)
      py1 = min(h - 1, floor(y0 + glyph - 1e-9))
      alpha = 0.9 * min(1, glyph)
    end
    if py0 < h then
      for _, run in ipairs(runs) do
        local x0 = m.inset + run[1] * m.char_px
        local x1 = min(x_max, m.inset + run[2] * m.char_px) -- fractional when squeezed
        if x1 > x0 then
          for py = py0, min(h - 1, py1) do
            add_run(overlay, py, x0, x1, run[3], alpha)
          end
        end
      end
    end
  end
end

--- Rasterize the strip. spec = { line_count, map_lines?, cols, rows,
--- cell_w, cell_h, palette = { add|delete|change = { fill = {r,g,b} },
--- outline = {r,g,b}, search = {r,g,b}, diagnostics = { [severity] = rgb } },
--- search_lines?, diagnostics? = { { line, severity } }, code? = { runs },
--- inset?, min_px?, char_px? }. code.columns (optional) is the number of
--- text columns the runs were built for; a narrower strip squeezes them. `map_lines` (default line_count) is the
--- number of lines the full height represents. Hunk marks fill the inner
--- columns; with `code`, text is drawn over them and search matches are a
--- translucent band under the text, otherwise a right-half tick on top.
--- Returns bytes (RGBA), width_px, height_px.
function M.render(spans, spec)
  local m = M.metrics(spec)
  local w, h = m.width, m.height
  if w <= 0 or h <= 0 then
    return "", w, h
  end
  local map_lines = max(1, spec.map_lines or spec.line_count or 1)
  local edge, inner = {}, {}
  for y = 0, h - 1 do
    edge[y] = { 0, 0, 0, 0 }
    inner[y] = { 0, 0, 0, 0 }
  end
  local palette = spec.palette or {}
  local ordered = {}
  for i, s in ipairs(spans or {}) do
    ordered[i] = s
  end
  -- Other chunks first (by kind priority), the current chunk on top.
  table.sort(ordered, function(a, b)
    if a.current ~= b.current then
      return not a.current
    end
    local pa, pb = KIND_PRIORITY[a.kind] or 0, KIND_PRIORITY[b.kind] or 0
    if pa ~= pb then
      return pa < pb
    end
    return a.first < b.first
  end)

  local extents = {}
  for i, s in ipairs(ordered) do
    local y0, y1 = M.span_extent(s, map_lines, h)
    extents[i] = { at_least(y0, y1, m.min_px, h) }
  end
  -- Outlines go under every current fill, so a chunk made of several spans
  -- (a change with embedded adds) reads as one outlined block.
  local outline = palette.outline
  for i, s in ipairs(ordered) do
    if s.current and outline then
      local y0, y1 = extents[i][1] - m.outline_px, extents[i][2] + m.outline_px
      paint(edge, h, y0, y1, outline)
      paint(inner, h, y0, y1, outline)
    end
  end
  for i, s in ipairs(ordered) do
    local colors = palette[s.kind]
    if colors and colors.fill then
      paint(inner, h, extents[i][1], extents[i][2], colors.fill)
    end
  end

  local overlay = {}
  local search = palette.search
  if search then
    for _, line in ipairs(spec.search_lines or {}) do
      local y0, y1 = at_least((line - 1) * h / map_lines, line * h / map_lines, m.min_px, h)
      if spec.code then
        paint(inner, h, y0, y1, search, 0.6)
      else
        local x0 = floor(w / 2)
        for py = floor(y0), min(h - 1, math.ceil(y1) - 1) do
          add_run(overlay, py, x0, w - m.inset, search, 1)
        end
      end
    end
  end
  if spec.code then
    code_runs(overlay, spec.code, m, map_lines, h)
  end
  -- Diagnostics: a tick over the left third, on top of everything.
  local diag_colors = palette.diagnostics or {}
  local tick_w = max(2, floor(w / 3))
  for _, d in ipairs(spec.diagnostics or {}) do
    local rgb = diag_colors[d.severity]
    if rgb then
      local y0, y1 = at_least((d.line - 1) * h / map_lines, d.line * h / map_lines, m.min_px, h)
      for py = max(0, y0), min(h - 1, y1 - 1) do
        add_run(overlay, py, 0, tick_w, rgb, 1)
      end
    end
  end

  local inner_w = w - 2 * m.inset
  local rows_out = {}
  local cache = {}
  local transparent = "\0\0\0\0"
  for y = 0, h - 1 do
    local runs = overlay[y]
    if runs then
      -- Per-pixel row: background, then each run blended on top.
      local px = {}
      local e, n = edge[y], inner[y]
      for x = 0, w - 1 do
        local src = (x < m.inset or x >= w - m.inset) and e or n
        px[x] = { src[1], src[2], src[3], src[4] }
      end
      for _, run in ipairs(runs) do
        local x0, x1 = run[1], run[2]
        for x = max(0, floor(x0)), min(w, math.ceil(x1)) - 1 do
          local cov = min(x1, x + 1) - max(x0, x)
          if cov > 0 then
            blend(px[x], run[3], run[4] * min(1, cov))
          end
        end
      end
      local parts = {}
      for x = 0, w - 1 do
        parts[x + 1] = px[x][4] > 0 and encode(px[x]) or transparent
      end
      rows_out[y + 1] = table.concat(parts)
    else
      local e, n = encode(edge[y]), encode(inner[y])
      local key = e .. n
      local row = cache[key]
      if not row then
        local side = string.rep(e, m.inset)
        row = side .. string.rep(n, inner_w) .. side
        cache[key] = row
      end
      rows_out[y + 1] = row
    end
  end
  return table.concat(rows_out), w, h
end

return M
