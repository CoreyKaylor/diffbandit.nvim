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
function M.palette()
  local palette = {}
  local parts = {}
  for _, kind in ipairs({ "add", "delete", "change" }) do
    local cap = kind:sub(1, 1):upper() .. kind:sub(2)
    local fill = hl_rgb("DiffBanditConnector" .. cap, "bg")
    local border = hl_rgb("DiffBanditConnector" .. cap .. "Line", "fg") or fill
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

-- --- canvas float ---------------------------------------------------------
--
-- The placeholder cells live in a small non-focusable float laid over the
-- screen columns wedge..wedge (both window separators included). Its buffer
-- is static: line r is image row r, so scrolling never moves a placeholder —
-- only the image content changes — and the separator columns between the
-- number panes and the connector are covered so the ribbon flows through.

local float_group = nil

local function close_float(st)
  if st.float_win and vim.api.nvim_win_is_valid(st.float_win) then
    pcall(vim.api.nvim_win_close, st.float_win, true)
  end
  st.float_win = nil
  st.float_cfg_key = nil
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
        local a = st.float_anchors
        if a and (a[1] == closed or a[2] == closed or a[3] == closed) then
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
  local cfg_key = table.concat({ row, col, layout.cols, layout.rows }, ":")
  st.float_anchors = { host.left_num_win, host.connector_win, host.right_num_win }
  if st.float_win and vim.api.nvim_win_is_valid(st.float_win) then
    if st.float_cfg_key ~= cfg_key then
      pcall(vim.api.nvim_win_set_config, st.float_win, cfg)
      st.float_cfg_key = cfg_key
    end
    return st.float_win
  end
  local open_cfg = vim.tbl_extend("force", cfg, { style = "minimal", noautocmd = true, mouse = false })
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, open_cfg)
  if not ok then
    open_cfg.mouse = nil
    ok, win = pcall(vim.api.nvim_open_win, buf, false, open_cfg)
  end
  if not ok then
    return nil
  end
  local hl = st.hl
  vim.wo[win].winhighlight = table.concat({
    "Normal:" .. hl, "NormalNC:" .. hl, "NormalFloat:" .. hl, "EndOfBuffer:" .. hl,
  }, ",")
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].winblend = 0
  vim.wo[win].fillchars = "eob: "
  st.float_win = win
  st.float_cfg_key = cfg_key
  return win
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
  local palette, palette_key = M.palette()
  local key = table.concat({
    layout.cols, layout.rows, cw, ch, palette_key, curves.geometry_key(ribbons, ch),
    tostring(((host.config or {}).ui or {}).kitty and host.config.ui.kitty.divider_width),
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
