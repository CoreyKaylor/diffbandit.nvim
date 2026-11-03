-- Image connector canvas: one Kitty image per connector, drawn through
-- Unicode placeholder cells.
--
-- The image spans SCREEN columns from the screen-left number pane's wedge
-- column to the screen-right number pane's wedge column, window separators
-- included. Its placeholder cells live in a static, non-focusable float laid
-- over exactly those columns (see ensure_float): image row r is screen row r
-- of the connector window, so scrolling never touches Neovim text — the
-- image is re-rasterized and re-transmitted only when the ribbon geometry,
-- size, or palette actually changed.
local connector_width = require("diffbandit.connector.width")
local color = require("diffbandit.kitty.color")
local curves = require("diffbandit.connector.curves")
local detect = require("diffbandit.kitty.detect")
local protocol = require("diffbandit.kitty.protocol")
local raster = require("diffbandit.kitty.raster")
local zlib = require("diffbandit.kitty.zlib")

local M = {}

local ID_BASE = 0xDB0000
local next_slot = 0
local live_states = setmetatable({}, { __mode = "k" })

local function now()
  local uv = vim.uv or vim.loop
  return uv and uv.hrtime and uv.hrtime() or 0
end

local function ms(t0)
  return (now() - t0) / 1e6
end

--- Fresh per-connector state. Merge hosts keep one per pair slot so pair
--- renderer rebuilds reuse the same terminal image id.
function M.new_state()
  next_slot = (next_slot % 0xFFFF) + 1
  local id = ID_BASE + next_slot
  local st = {
    id = id,
    hl = "DiffBanditKittyImage" .. id,
    last_key = nil,
    files = {},
    transmits = 0,
  }
  detect.register_id(id)
  live_states[st] = true
  return st
end

function M.state_for(host)
  if not host.kitty_state then
    host.kitty_state = M.new_state()
  end
  return host.kitty_state
end

local function hl_rgb(name, field)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  local v = ok and hl and hl[field] or nil
  if type(v) ~= "number" then
    return nil
  end
  return { math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256 }
end

--- Ribbon palette from the theme-derived connector groups (respects user
--- highlight overrides): band fill = DiffBanditConnector<Kind>.bg, active
--- border = DiffBanditConnector<Kind>Line.fg.
--- A highlight colour ({r,g,b} or nil) in the image colour space.
function M.image_rgb(config, name, field, space)
  local rgb = hl_rgb(name, field)
  space = space or color.image_colorspace(config)
  if rgb and space == "display-p3" then
    return color.srgb_to_display_p3(rgb)
  end
  return rgb
end

function M.palette(config)
  local palette = {}
  local space = color.image_colorspace(config)
  local parts = { space }
  local function encode(rgb)
    if rgb and space == "display-p3" then
      return color.srgb_to_display_p3(rgb)
    end
    return rgb
  end
  for _, kind in ipairs({ "add", "delete", "change" }) do
    local cap = kind:sub(1, 1):upper() .. kind:sub(2)
    local fill = encode(hl_rgb("DiffBanditConnector" .. cap, "bg"))
    local border = encode(hl_rgb("DiffBanditConnector" .. cap .. "Line", "fg")) or fill
    palette[kind] = { fill = fill, border = border }
    parts[#parts + 1] = table.concat(fill or { "-" }, ",") .. "/" .. table.concat(border or { "-" }, ",")
  end
  return palette, table.concat(parts, ";")
end

-- Placeholder cells: fg encodes the image id; bg is the gutter background
-- (DiffBanditConnectorContext) so transparent image pixels match the core.
local function ensure_image_hl(st)
  local ok_bg, ctx_hl = pcall(vim.api.nvim_get_hl, 0, { name = "DiffBanditConnectorContext", link = false })
  local bg = ok_bg and ctx_hl and ctx_hl.bg or nil
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = st.hl, link = false })
  if ok and hl and hl.fg == st.id and hl.bg == bg then
    return
  end
  vim.api.nvim_set_hl(0, st.hl, { fg = protocol.id_to_hex(st.id), bg = bg })
end

local function win_col(win)
  return vim.api.nvim_win_get_position(win)[2]
end

--- Screen layout of the image for this host, or nil when windows are gone.
function M.layout(host)
  local wins = { host.left_num_win, host.connector_win, host.right_num_win }
  for _, w in ipairs(wins) do
    if not w or not vim.api.nvim_win_is_valid(w) then
      return nil
    end
  end
  local mirror = host.mirror_connector_sides == true
  local sl = mirror
    and { buf = host.right_num_buf, win = host.right_num_win, col = host:right_triangle_col(), side = "right" }
    or { buf = host.left_num_buf, win = host.left_num_win, col = host:left_triangle_col(), side = "left" }
  local sr = mirror
    and { buf = host.left_num_buf, win = host.left_num_win, col = host:left_triangle_col(), side = "left" }
    or { buf = host.right_num_buf, win = host.right_num_win, col = host:right_triangle_col(), side = "right" }
  local left_edge = win_col(sl.win) + sl.col
  local right_edge = win_col(sr.win) + sr.col
  local cols = right_edge - left_edge + 1
  local core_start = win_col(host.connector_win) - left_edge
  local rows = math.min(vim.api.nvim_win_get_height(host.connector_win), protocol.MAX_INDEX + 1)
  if cols < 1 or cols > protocol.MAX_INDEX + 1 or rows < 1 or core_start < 0 then
    return nil
  end
  return {
    cols = cols,
    rows = rows,
    core_start = core_start,
    core_width = vim.api.nvim_win_get_width(host.connector_win),
    screen_left = sl,
    screen_right = sr,
  }
end

-- Shrink cell pixels proportionally when the image would exceed the cap; the
-- placement still spans cols x rows cells and the terminal scales it up.
local function capped_cell(cell, cols, rows, max_px)
  local w, h = cell.w, cell.h
  max_px = tonumber(max_px) or 4e6
  local area = cols * w * rows * h
  if area > max_px and area > 0 then
    local scale = math.sqrt(max_px / area)
    w = math.max(1, math.floor(w * scale))
    h = math.max(1, math.floor(h * scale))
  end
  return w, h
end

local function transmit(host, st, bytes, width, height, layout)
  local medium = detect.transmission(host.config)
  local chunks
  if medium == "file" then
    local path = detect.temp_path(tostring(st.id))
    local fh = io.open(path, "wb")
    if fh then
      fh:write(bytes)
      fh:close()
      st.files[#st.files + 1] = path
      if #st.files > 8 then
        -- Terminals delete t=t files after reading them; one this many
        -- frames old has long been consumed, so remove any leftover.
        pcall(os.remove, table.remove(st.files, 1))
      end
      chunks = protocol.transmit({
        id = st.id, width = width, height = height,
        cols = layout.cols, rows = layout.rows,
        medium = "t", path = path, quiet = 1,
      })
    end
  end
  if not chunks then
    -- Direct transmission crosses the pty as base64: compress (o=z) when
    -- libz is available — connector images are mostly transparent.
    local kitty_cfg = (((host.config or {}).ui or {}).kitty) or {}
    local payload, compressed = bytes, false
    if kitty_cfg.compress ~= false then
      local z = zlib.compress(bytes, 1)
      if z and #z < #bytes then
        payload, compressed = z, true
      end
    end
    chunks = protocol.transmit({
      id = st.id, width = width, height = height,
      cols = layout.cols, rows = layout.rows,
      medium = "d", data = payload, compressed = compressed, quiet = 1,
    })
  end
  st.transmits = st.transmits + 1
  return detect.send(table.concat(chunks))
end
-- layout = { cols, rows }: the placement size in cells.
M.transmit = transmit

-- --- canvas float ---------------------------------------------------------
--
-- The placeholder cells live in a small non-focusable float laid over the
-- screen columns wedge..wedge (both window separators included). Its buffer
-- is static: line r is image row r, so scrolling never moves a placeholder —
-- only the image content changes — and the separator columns between the
-- number panes and the connector are covered so the ribbon flows through.

local float_group = nil
local ensure_edges

local function close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function close_float(st)
  close_win(st.float_win)
  st.float_win = nil
  st.float_cfg_key = nil
  for _, edge in pairs(st.edges or {}) do
    close_win(edge.win)
    edge.win = nil
    edge.cfg_key = nil
  end
end

-- Layout moved without a diffbandit render (panel toggle, split resize,
-- terminal resize): keep the float glued to the gutter, and repaint the
-- image when its cell size changed.
local function follow_layout()
  for st in pairs(live_states) do
    local host = st.host
    if host and not host.disposed and st.last_layout and not st.destroyed then
      local layout = M.layout(host)
      if not layout then
        close_float(st)
      else
        local last = st.last_layout
        M._ensure_float(host, st, layout)
        if not last or last.cols ~= layout.cols or last.rows ~= layout.rows then
          st.last_key = nil
          local owner = host.merge_host
          if host.request_viewport_rerender then
            host.last_viewport_render_key = nil
            host:request_viewport_rerender()
          elseif owner and owner.render and not owner.disposed then
            pcall(owner.render, owner, { force_viewport = true })
          end
        end
      end
    end
  end
end

local function install_float_cleanup()
  if float_group then
    return
  end
  float_group = vim.api.nvim_create_augroup("DiffBanditKittyCanvas", { clear = true })
  -- A pane that disappears (merge hide_pane, :close, :only) must take the
  -- floating canvas with it; the next paint re-creates it where valid.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = float_group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      for st in pairs(live_states) do
        local hit = false
        for _, w in ipairs(st.float_anchors or {}) do
          hit = hit or w == closed
        end
        if hit then
          vim.schedule(function()
            close_float(st)
          end)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
    group = float_group,
    callback = function()
      vim.schedule(follow_layout)
    end,
  })
end

local function canvas_buf(st)
  if st.float_buf and vim.api.nvim_buf_is_valid(st.float_buf) then
    return st.float_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  st.float_buf = buf
  st.float_lines_key = nil
  return buf
end

local function set_canvas_lines(st, buf, cols, rows)
  local key = cols .. "x" .. rows
  if st.float_lines_key == key then
    return
  end
  local lines = {}
  for r = 0, rows - 1 do
    lines[#lines + 1] = protocol.placeholder_run(r, 0, cols) or ""
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  st.float_lines_key = key
end

-- Open or move a canvas-style float (minimal, unfocusable, mouse
-- transparent, borderless). Returns win, cfg_key.
local function place_float(win, cfg_key, buf, cfg, hl)
  local key = table.concat({ cfg.row, cfg.col, cfg.width, cfg.height }, ":")
  if win and vim.api.nvim_win_is_valid(win) then
    if cfg_key ~= key then
      pcall(vim.api.nvim_win_set_config, win, cfg)
    end
    return win, key
  end
  local open_cfg = vim.tbl_extend("force", cfg, { style = "minimal", noautocmd = true, mouse = false })
  local ok, new_win = pcall(vim.api.nvim_open_win, buf, false, open_cfg)
  if not ok then
    open_cfg.mouse = nil
    ok, new_win = pcall(vim.api.nvim_open_win, buf, false, open_cfg)
  end
  if not ok then
    return nil, nil
  end
  vim.wo[new_win].winhighlight = table.concat({
    "Normal:" .. hl, "NormalNC:" .. hl, "NormalFloat:" .. hl, "EndOfBuffer:" .. hl,
  }, ",")
  vim.wo[new_win].wrap = false
  vim.wo[new_win].cursorline = false
  vim.wo[new_win].winblend = 0
  vim.wo[new_win].fillchars = "eob: "
  return new_win, key
end

-- --- document-edge bridges -----------------------------------------------
--
-- The window separators between each number pane and its document would
-- still cut every band (content band | separator | number band). A one-column
-- float over each of them keeps the separator glyph on context rows and
-- paints the band colour on band rows, so a band runs unbroken from the
-- document through the numbers and the curve into the other document.

local edge_ns = vim.api.nvim_create_namespace("DiffBanditKittyEdges")

local KIND_HL = { add = "DiffBanditConnectorAdd", delete = "DiffBanditConnectorDelete", change = "DiffBanditConnectorChange" }

local function vert_char()
  local ok, fc = pcall(function()
    return vim.opt.fillchars:get()
  end)
  local ch = ok and fc and fc.vert or nil
  return (ch and ch ~= "") and ch or "│"
end

local function edge_columns(host, layout)
  local sl, sr = layout.screen_left, layout.screen_right
  local out = {}
  local lcol = win_col(sl.win) - 1
  if lcol >= 0 then
    out.left = lcol
  end
  local rcol = win_col(sr.win) + vim.api.nvim_win_get_width(sr.win)
  if rcol < vim.o.columns then
    out.right = rcol
  end
  return out
end

local function edge_buf(edge, rows)
  if not (edge.buf and vim.api.nvim_buf_is_valid(edge.buf)) then
    edge.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[edge.buf].bufhidden = "hide"
    vim.bo[edge.buf].buftype = "nofile"
    vim.bo[edge.buf].swapfile = false
    vim.bo[edge.buf].undolevels = -1
    edge.lines_key = nil
  end
  local glyph = vert_char()
  local key = rows .. ":" .. glyph
  if edge.lines_key ~= key then
    local lines = {}
    for r = 1, rows do
      lines[r] = glyph
    end
    vim.bo[edge.buf].modifiable = true
    vim.api.nvim_buf_set_lines(edge.buf, 0, -1, false, lines)
    vim.bo[edge.buf].modifiable = false
    edge.lines_key = key
    edge.marks_key = nil
  end
  return edge.buf
end

-- Separator glyph underlined in a kind's colour: the insertion point of an
-- add/delete is an underline on the origin row (documents and number panes
-- draw it), so the bridge carries it too.
local function underline_hl(kind)
  local cap = kind:sub(1, 1):upper() .. kind:sub(2)
  local name = "DiffBanditKittyEdgeUnderline" .. cap
  local ok_c, color = pcall(vim.api.nvim_get_hl, 0, { name = KIND_HL[kind], link = false })
  local ok_s, split = pcall(vim.api.nvim_get_hl, 0, { name = "DiffBanditSplit", link = false })
  vim.api.nvim_set_hl(0, name, {
    fg = ok_s and split.fg or nil,
    bg = ok_s and split.bg or nil,
    underline = true,
    sp = ok_c and color.bg or nil,
  })
  return name
end

-- Band rows on one screen side: [top, bottom) of every ribbon with a
-- non-empty extent there, in screen rows. An empty extent (insertion point
-- at boundary `top`) underlines the origin row above it.
local function paint_edge_marks(edge, ribbons, side, rows, key)
  if edge.marks_key == key then
    return
  end
  vim.api.nvim_buf_clear_namespace(edge.buf, edge_ns, 0, -1)
  local glyph = vert_char()
  local function mark(r, text, hl)
    pcall(vim.api.nvim_buf_set_extmark, edge.buf, edge_ns, r, 0, {
      virt_text = { { text, hl } },
      virt_text_pos = "overlay",
      priority = 200,
    })
  end
  local underlines, banded = {}, {}
  for _, rb in ipairs(ribbons) do
    local top, bot
    if side == "left" then
      top, bot = rb.lt, rb.lb
    else
      top, bot = rb.rt, rb.rb
    end
    local hl = KIND_HL[rb.kind]
    if hl and bot > top then
      for r = math.max(0, math.floor(top)), math.min(rows, math.ceil(bot)) - 1 do
        mark(r, " ", hl)
        banded[r] = true
      end
    elseif hl then
      local r = math.floor(top) - 1
      if r >= 0 and r < rows then
        underlines[r] = rb.kind
      end
    end
  end
  for r, kind in pairs(underlines) do
    -- A band ending on the origin row already joins the two sides.
    if not banded[r] then
      mark(r, glyph, underline_hl(kind))
    end
  end
  edge.marks_key = key
end

function ensure_edges(host, st, layout, row)
  st.edges = st.edges or {}
  local cols = edge_columns(host, layout)
  local ribbons = st.last_ribbons or {}
  local key = (st.last_key or "") .. "|" .. layout.rows
  for _, side in ipairs({ "left", "right" }) do
    local edge = st.edges[side] or {}
    st.edges[side] = edge
    local col = cols[side]
    if not col then
      close_win(edge.win)
      edge.win = nil
    else
      local buf = edge_buf(edge, layout.rows)
      paint_edge_marks(edge, ribbons, side, layout.rows, key)
      edge.win, edge.cfg_key = place_float(edge.win, edge.cfg_key, buf, {
        relative = "editor",
        row = row,
        col = col,
        width = 1,
        height = layout.rows,
        focusable = false,
        zindex = 1,
        border = "none",
      }, "DiffBanditSplit")
    end
  end
end

local function ensure_float(host, st, layout)
  install_float_cleanup()
  -- Editor-relative floats open in the CURRENT tab: a paint for a host in a
  -- background tab (theme refresh, detection flip) waits for TabEnter.
  if vim.api.nvim_win_get_tabpage(host.connector_win) ~= vim.api.nvim_get_current_tabpage() then
    return st.float_win
  end
  local buf = canvas_buf(st)
  set_canvas_lines(st, buf, layout.cols, layout.rows)
  -- Editor-relative at the connector's screen row and the screen-left wedge
  -- column (relative="win" floats mis-position under some grids); paint
  -- re-checks the position every time, so layout changes follow on the
  -- next render.
  local row = vim.api.nvim_win_get_position(host.connector_win)[1]
  local col = vim.api.nvim_win_get_position(layout.screen_left.win)[2] + layout.screen_left.col
  local cfg = {
    relative = "editor",
    row = row,
    col = col,
    width = layout.cols,
    height = layout.rows,
    focusable = false,
    zindex = 1,
    -- Explicit: a global 'winborder' would otherwise frame the canvas and
    -- shift its cells one row down / one column right over the numbers.
    border = "none",
  }
  st.float_anchors = { host.left_num_win, host.connector_win, host.right_num_win, host.left_win, host.right_win }
  st.float_win, st.float_cfg_key = place_float(st.float_win, st.float_cfg_key, buf, cfg, st.hl)
  ensure_edges(host, st, layout, row)
  return st.float_win
end
M._ensure_float = ensure_float

--- Paint the image connector for this render. Returns stage timings (ms)
--- { curves, raster, transmit } for the perf instrumentation.
function M.paint(host, ctx)
  local timings = { curves = 0, raster = 0, transmit = 0 }
  local layout = M.layout(host)
  if not layout then
    if host.kitty_state then
      close_float(host.kitty_state)
    end
    return timings
  end
  local st = M.state_for(host)
  st.host = host
  ensure_image_hl(st)

  local t0 = now()
  local ribbons = curves.ribbons(host:base_paths(), {
    left_topline = ctx.left_topline,
    right_topline = ctx.right_topline,
    rows = layout.rows,
    active_chunk = host.current_chunk,
    mirror = host.mirror_connector_sides == true,
  })
  local cell = detect.cell_size(host.config)
  local kitty_cfg = (((host.config or {}).ui or {}).kitty) or {}
  local cw, ch = capped_cell(cell, layout.cols, layout.rows, kitty_cfg.max_image_px)
  local palette, palette_key = M.palette(host.config)
  local key = table.concat({
    layout.cols, layout.rows, cw, ch, palette_key, curves.geometry_key(ribbons, ch),
    tostring(kitty_cfg.divider_width),
    vim.inspect(kitty_cfg.insertion_line or false),
  }, "|")
  timings.curves = ms(t0)

  if key ~= st.last_key then
    t0 = now()
    -- The curve is IntelliJ divider-wide, centred between the two wedge
    -- columns; the band runs flat across the wedge columns themselves.
    local inner = math.max(1, layout.cols - 2) * cw
    local curve_w = math.min(inner, connector_width.kitty_divider_px(host.config, { w = cw, h = ch }))
    local bytes, width, height = raster.render(ribbons, {
      cols = layout.cols,
      rows = layout.rows,
      cell_w = cw,
      cell_h = ch,
      curve_x0 = (layout.cols > 2 and cw or 0) + (inner - curve_w) / 2,
      curve_w = curve_w,
      palette = palette,
      insertion_line = kitty_cfg.insertion_line,
    })
    timings.raster = ms(t0)
    t0 = now()
    transmit(host, st, bytes, width, height, layout)
    timings.transmit = ms(t0)
    st.last_key = key
  end
  st.last_ribbons = ribbons
  st.last_layout = layout

  ensure_float(host, st, layout)
  return timings
end

--- Forget the transmitted image so the next paint re-sends it.
function M.invalidate(host)
  local st = host.kitty_state
  if st then
    st.last_key = nil
  end
end

--- Delete the terminal image and any temp files still on disk.
function M.destroy_state(st)
  if not st or st.destroyed then
    return
  end
  st.destroyed = true
  close_float(st)
  if st.float_buf and vim.api.nvim_buf_is_valid(st.float_buf) then
    pcall(vim.api.nvim_buf_delete, st.float_buf, { force = true })
  end
  st.float_buf = nil
  for _, edge in pairs(st.edges or {}) do
    if edge.buf and vim.api.nvim_buf_is_valid(edge.buf) then
      pcall(vim.api.nvim_buf_delete, edge.buf, { force = true })
    end
  end
  st.edges = nil
  detect.send(protocol.delete(st.id))
  detect.unregister_id(st.id)
  for _, path in ipairs(st.files or {}) do
    pcall(os.remove, path)
  end
  st.files = {}
  live_states[st] = nil
end

function M.destroy(host)
  if host.kitty_state then
    M.destroy_state(host.kitty_state)
    host.kitty_state = nil
  end
end

--- States still holding a terminal image (for ColorScheme refresh/tests).
function M.live_states()
  local out = {}
  for st in pairs(live_states) do
    out[#out + 1] = st
  end
  return out
end

return M
