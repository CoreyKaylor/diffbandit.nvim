-- Anti-aliased ribbon rasterizer for the image connector (pure; LuaJIT ffi
-- when available, a plain-table fallback otherwise — both byte-identical).
--
-- Each ribbon edge is IntelliJ's divider curve (DiffDrawUtil.makeCurve):
--   P0 = (0, y1), P1 = (c*w, y1), P2 = ((1-c)*w, y2), P3 = (w, y2), c = 0.3.
-- x(t) depends only on the width, and with control heights (y1, y1, y2, y2)
-- y(t) = y1 + (y2 - y1) * S(t), S(t) = 3t^2 - 2t^3. So one per-width table
-- of S at each pixel sub-sample serves every edge of every ribbon: the fill
-- is a per-column span between the top and bottom edges, with 4x horizontal
-- sub-sampling and exact vertical coverage for anti-aliasing.
--
-- Like DiffDrawUtil.drawCurveTrapezium, the band is never thinner than a
-- minimum thickness (so empty ranges — the add/delete insertion side —
-- still read as a line), and the active chunk gets a border stroke along both
-- edges (drawCurveLine).
local curves = require("diffbandit.connector.curves")

local M = {}

local has_ffi, ffi = pcall(require, "ffi")
M.has_ffi = has_ffi

local SUBSAMPLES = 4
local INTELLIJ_LINE_PX = require("diffbandit.connector.width").INTELLIJ_LINE_PX
local floor, ceil, max, min, sqrt = math.floor, math.ceil, math.max, math.min, math.sqrt
local unpack = unpack or table.unpack -- luacheck: ignore

-- --- curve shape tables --------------------------------------------------

local shape_cache = {}

local function bezier_x(t, c)
  local u = 1 - t
  return 3 * c * u * u * t + 3 * (1 - c) * u * t * t + t * t * t
end

local function bezier_dx(t, c)
  local u = 1 - t
  return 3 * c * (u * u - 2 * t * u) + 3 * (1 - c) * (2 * t * u - t * t) + 3 * t * t
end

--- S (normalized edge progress) and dS/dx (per px) at each sub-sample of a
--- `width`-px image whose curve occupies [x0, x0 + cw) px — IntelliJ draws the
--- band flat across the gutters and curves only over the divider. Left of
--- the curve S = 0, right of it S = 1. x0/cw default to the full width.
--- Cached per (width, x0, cw).
function M.shape(width, x0, cw)
  x0 = x0 or 0
  cw = cw or width
  local key = width .. ":" .. x0 .. ":" .. cw
  local cached = shape_cache[key]
  if cached then
    return cached
  end
  local c = curves.CTRL_PROXIMITY_X
  local n = width * SUBSAMPLES
  local S, D = {}, {}
  for i = 0, n - 1 do
    local u = ((i + 0.5) / SUBSAMPLES - x0) / cw
    if u <= 0 then
      S[i], D[i] = 0, 0
    elseif u >= 1 then
      S[i], D[i] = 1, 0
    else
      local lo, hi = 0, 1
      for _ = 1, 40 do
        local mid = (lo + hi) / 2
        if bezier_x(mid, c) < u then
          lo = mid
        else
          hi = mid
        end
      end
      local t = (lo + hi) / 2
      S[i] = 3 * t * t - 2 * t * t * t
      local dxdt = bezier_dx(t, c) * cw
      D[i] = dxdt > 1e-9 and (6 * t - 6 * t * t) / dxdt or 0
    end
  end
  cached = { S = S, D = D, n = n }
  shape_cache[key] = cached
  return cached
end

-- --- pixel buffers --------------------------------------------------------

local ffi_buffer, ffi_buffer_size = nil, 0

local function new_buffer(n, use_ffi)
  if use_ffi then
    if ffi_buffer and ffi_buffer_size == n then
      ffi.fill(ffi_buffer, n, 0)
      return ffi_buffer
    end
    ffi_buffer = ffi.new("uint8_t[?]", n)
    ffi_buffer_size = n
    return ffi_buffer
  end
  return {}
end

local function to_bytes(buf, n, use_ffi)
  if use_ffi then
    return ffi.string(buf, n)
  end
  local out = {}
  local step = 4096
  local tmp = {}
  for base = 0, n - 1, step do
    local len = min(step, n - base)
    for j = 1, len do
      tmp[j] = buf[base + j - 1] or 0
    end
    for j = len + 1, #tmp do
      tmp[j] = nil
    end
    out[#out + 1] = string.char(unpack(tmp, 1, len))
  end
  return table.concat(out)
end

-- Straight-alpha source-over of an opaque color at coverage `a` (0..1).
local function blend(buf, i, r, g, b, a)
  if a <= 0 then
    return
  end
  if a >= 1 then
    buf[i] = r
    buf[i + 1] = g
    buf[i + 2] = b
    buf[i + 3] = 255
    return
  end
  local da = (buf[i + 3] or 0) / 255
  local inv = da * (1 - a)
  local oa = a + inv
  buf[i] = floor((r * a + (buf[i] or 0) * inv) / oa + 0.5)
  buf[i + 1] = floor((g * a + (buf[i + 1] or 0) * inv) / oa + 0.5)
  buf[i + 2] = floor((b * a + (buf[i + 2] or 0) * inv) / oa + 0.5)
  buf[i + 3] = floor(oa * 255 + 0.5)
end

-- Widen [top, bot] symmetrically to at least `thick` px.
local function thicken(top, bot, thick)
  if bot - top >= thick then
    return top, bot
  end
  local mid = (top + bot) / 2
  return mid - thick / 2, mid + thick / 2
end

-- One side's pixel extent. An empty range (insertion point at boundary b)
-- becomes the insertion line, drawn where the terminal draws the origin
-- row's underline — `line.thickness` px whose bottom sits `line.offset` px
-- above the boundary — so the line continues the document/number-pane
-- underline seamlessly instead of straddling the boundary.
local function side_extent(top, bot, ch, line)
  if bot > top or not line then
    return top * ch, bot * ch
  end
  local b = top * ch - line.offset
  return b - line.thickness, b
end

local function fill_ribbon(buf, w, h, shape, ribbon, ch, color, min_px, line)
  local S = shape.S
  local lt, lb = side_extent(ribbon.lt, ribbon.lb, ch, line)
  local rt, rb = side_extent(ribbon.rt, ribbon.rb, ch, line)
  lt, lb = thicken(lt, lb, min_px)
  rt, rb = thicken(rt, rb, min_px)
  local dt, db = rt - lt, rb - lb
  local r, g, b = color[1], color[2], color[3]
  local tops, bots = {}, {}
  for x = 0, w - 1 do
    local lo, hi = math.huge, -math.huge
    local max_top, min_bot = -math.huge, math.huge
    local base = x * SUBSAMPLES
    for k = 1, SUBSAMPLES do
      local s = S[base + k - 1]
      local top, bot = thicken(lt + dt * s, lb + db * s, min_px)
      tops[k], bots[k] = top, bot
      if top < lo then lo = top end
      if bot > hi then hi = bot end
      if top > max_top then max_top = top end
      if bot < min_bot then min_bot = bot end
    end
    if hi > 0 and lo < h then
      local full_lo, full_hi = ceil(max_top), floor(min_bot) - 1
      local y0 = max(0, floor(lo))
      local y1 = min(h - 1, ceil(hi) - 1)
      for py = y0, y1 do
        local cov
        if py >= full_lo and py <= full_hi then
          cov = 1
        else
          cov = 0
          for k = 1, SUBSAMPLES do
            local span = min(bots[k], py + 1) - max(tops[k], py)
            if span > 0 then
              cov = cov + span
            end
          end
          cov = cov / SUBSAMPLES
        end
        blend(buf, (py * w + x) * 4, r, g, b, cov)
      end
    end
  end
end

-- A stroke of `thick` px centred on one edge curve; vertical half-extent is
-- scaled by sqrt(1 + slope^2) so steep sections keep their visual weight.
local function stroke_edge(buf, w, h, shape, y1, y2, color, thick)
  local S, D = shape.S, shape.D
  local dy = y2 - y1
  local r, g, b = color[1], color[2], color[3]
  local tops, bots = {}, {}
  for x = 0, w - 1 do
    local lo, hi = math.huge, -math.huge
    local base = x * SUBSAMPLES
    for k = 1, SUBSAMPLES do
      local i = base + k - 1
      local e = y1 + dy * S[i]
      local slope = dy * D[i]
      local half = thick / 2 * sqrt(1 + slope * slope)
      tops[k], bots[k] = e - half, e + half
      if e - half < lo then lo = e - half end
      if e + half > hi then hi = e + half end
    end
    if hi > 0 and lo < h then
      for py = max(0, floor(lo)), min(h - 1, ceil(hi) - 1) do
        local cov = 0
        for k = 1, SUBSAMPLES do
          local span = min(bots[k], py + 1) - max(tops[k], py)
          if span > 0 then
            cov = cov + span
          end
        end
        blend(buf, (py * w + x) * 4, r, g, b, cov / SUBSAMPLES)
      end
    end
  end
end

--- Rasterize ribbons (curves.ribbons output) into RGBA bytes.
--- spec = { cols, rows, cell_w, cell_h, curve_x0?, curve_w?,
---          palette = { add|delete|change = { fill = {r,g,b}, border = {r,g,b} } },
---          min_px?, border_px?, insertion_line? = { thickness, offset }
---          (fractions of the line height), use_ffi? }
--- Returns bytes, width_px, height_px.
function M.render(ribbons, spec)
  local cw, ch = spec.cell_w, spec.cell_h
  local w, h = spec.cols * cw, spec.rows * ch
  local n = w * h * 4
  local use_ffi = has_ffi and spec.use_ffi ~= false
  local buf = new_buffer(n, use_ffi)
  if w <= 0 or h <= 0 then
    return "", w, h
  end
  local curve_w = spec.curve_w and min(spec.curve_w, w) or w
  local curve_x0 = spec.curve_x0 or (w - curve_w) / 2
  local shape = M.shape(w, curve_x0, curve_w)
  -- IntelliJ constants in its logical px, scaled by line height: an empty
  -- range is a 2px line on the line boundary (DividerPolygon.paint widens
  -- it to y-1..y+1), and strokes are 1px (DiffDrawUtil, JBUIScale 1f).
  local logical = ch / INTELLIJ_LINE_PX
  -- Insertion line: match the terminal underline (measured in Ghostty:
  -- 1px, one px above the row boundary at an 18px line). Fractions of the
  -- line height so it scales with the font; ui.kitty.insertion_line tunes it.
  local il = spec.insertion_line or {}
  local line = {
    thickness = max(1, (tonumber(il.thickness) or (1 / 18)) * ch),
    offset = (tonumber(il.offset) or (1 / 18)) * ch,
  }
  local min_px = spec.min_px or line.thickness
  local border_px = spec.border_px or max(1, logical)
  local palette = spec.palette or {}
  for _, ribbon in ipairs(ribbons) do
    local colors = palette[ribbon.kind]
    if colors and colors.fill then
      fill_ribbon(buf, w, h, shape, ribbon, ch, colors.fill, min_px, line)
      if ribbon.active and colors.border then
        stroke_edge(buf, w, h, shape, ribbon.lt * ch, ribbon.rt * ch, colors.border, border_px)
        stroke_edge(buf, w, h, shape, ribbon.lb * ch, ribbon.rb * ch, colors.border, border_px)
      end
    end
  end
  return to_bytes(buf, n, use_ffi), w, h
end

return M
