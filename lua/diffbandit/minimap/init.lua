-- Minimap: an overview strip describing one target window.
--
-- The same object backs the diff view's overview gutters and the minimap of
-- ordinary editor windows. What differs is supplied by the caller:
--   * a placement (minimap/placement.lua): the diff layout's sidecar split
--     (managed), or a float on the target window's right edge;
--   * a provider (minimap/providers.lua): the lines, hunk marks and
--     diagnostics to draw (diff-view hunks, or git hunks against the index).
-- The minimap owns everything else: viewport / cursor / selection / search
-- overlays, the scale (min_reduction), the code shape, the image or cell
-- renderer (its own Kitty host, unless a host such as the diff session
-- lends its renderer), its triggers and the mouse.
local color = require("diffbandit.kitty.color")
local detect = require("diffbandit.kitty.detect")
local kitty = require("diffbandit.kitty")
local kitty_overview = require("diffbandit.kitty.overview")
local mouse = require("diffbandit.minimap.mouse")
local overview = require("diffbandit.util.overview")
local overview_raster = require("diffbandit.kitty.overview_raster")
local overview_syntax = require("diffbandit.util.overview_syntax")
local ui = require("diffbandit.util.ui")

local Minimap = {}
Minimap.__index = Minimap

local SLOT = "map"
local next_id = 0

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Strip width (cells) for these options and renderer.
function Minimap.width_for(options, renderer)
  return overview.width(options, renderer)
end

--- spec = {
---   config,     full plugin config (Kitty detection, cell size, colour space)
---   options,    overview options: config.ui.overview or config.minimap
---   target,     fn() -> win: the window the strip describes
---   placement,  { ensure(mm, width) -> win, buf | nil, hide(), close() }
---   provider,   { buf(mm) -> buf, lines(mm) -> lines, marks(mm) -> marks,
---                 line_count?(mm), diagnostics?(mm), attach?(mm),
---                 detach?(mm), on_text_changed?(mm) }
---   on_target_closed?(mm)
---   width?(mm, renderer) -> cells: a host-chosen width (the diff view's
---               focus-following wide/compact strips); default from options
---   renderer_host?  a Kitty host whose connector_renderer this minimap
---               follows (the diff session, which also sizes the strip from
---               it); it must repaint the minimap on flips and call
---               refresh_images() on theme refreshes. Default: attach as
---               its own host.
---   on_keyboard_enter?(mm)  entered by keyboard; default focuses the target
--- }
function Minimap.new(spec)
  next_id = next_id + 1
  local mm = setmetatable({
    id = next_id,
    config = spec.config,
    options = spec.options or {},
    target = spec.target,
    placement = spec.placement,
    provider = spec.provider,
    on_target_closed = spec.on_target_closed,
    width_fn = spec.width,
    renderer_host = spec.renderer_host,
    on_keyboard_enter = spec.on_keyboard_enter,
    ns = vim.api.nvim_create_namespace("DiffBanditMinimap" .. next_id),
    code_generation = 0,
  }, Minimap)
  if not mm.renderer_host then
    -- Its own Kitty host: resolves "kitty" | "cells" now, follows a later
    -- probe answer or a terminal rejection, and re-sends on theme changes.
    kitty.attach(mm, {
      on_change = function()
        mm:render()
      end,
      refresh = function()
        mm:refresh_images()
      end,
    })
  end
  if mm.provider.attach then
    mm.provider.attach(mm)
  end
  mm:install_autocmds()
  return mm
end

function Minimap:target_win()
  local win = self.target()
  return valid_win(win) and win or nil
end

function Minimap:target_buf()
  local buf = self.provider.buf(self)
  return valid_buf(buf) and buf or nil
end

--- "kitty" | "cells" for this minimap right now.
function Minimap:renderer()
  local host = self.renderer_host or self
  return overview.renderer(self.options, host.connector_renderer)
end

--- Theme refresh / retransmission: re-send the image, rebuild syntax colours.
function Minimap:refresh_images()
  kitty_overview.invalidate(self)
  self.code_generation = self.code_generation + 1
  self:render()
end

function Minimap:width()
  local renderer = self:renderer()
  if self.width_fn then
    return self.width_fn(self, renderer)
  end
  return Minimap.width_for(self.options, renderer)
end

-- --- state -----------------------------------------------------------------

local function scale(self, line_count, height, renderer)
  local code = overview.code_shape(self.options, renderer)
  local cell, char_px
  if renderer == "kitty" then
    cell = detect.cell_size(self.config)
    char_px = overview_raster.char_px(cell.w)
  end
  local min_red = overview.min_reduction(self.options, code, cell, char_px)
  return {
    code = code,
    cell = cell,
    char_px = char_px,
    map_lines = overview.map_lines(line_count, height, min_red),
  }
end

local function search_lines(self, lines)
  if not overview.search_enabled(self.options) then
    return {}
  end
  local pattern = overview.active_search()
  if not pattern then
    return {}
  end
  local buf = self:target_buf()
  local tick = buf and vim.api.nvim_buf_get_changedtick(buf) or 0
  local key = table.concat({
    pattern, tostring(vim.o.ignorecase), tostring(vim.o.smartcase), tostring(lines), tick,
  }, "\31")
  if self.search_cache and self.search_cache.key == key then
    return self.search_cache.lines
  end
  local found = overview.search_lines(lines, pattern)
  self.search_cache = { key = key, lines = found }
  return found
end

local VISUAL_MODES = { v = true, V = true, ["\22"] = true }

local function selection(win)
  if vim.api.nvim_get_current_win() ~= win then
    return nil
  end
  if not VISUAL_MODES[vim.api.nvim_get_mode().mode] then
    return nil
  end
  return { first = vim.fn.line("v"), last = vim.fn.line(".") }
end

-- Code-shape runs, cached per lines, column count and buffer tick. Edits of
-- the same buffer keep the previous shape until typing pauses: treesitter
-- capture iteration costs ~20ms per 1000 lines. The runs always cover the
-- full-width strip's columns (code_width); a compact strip squeezes them,
-- so switching sizes never rebuilds them.
local function code_layer(self, lines, sc)
  local cols = Minimap.width_for(self.options, "kitty")
  local spec = { cols = cols, rows = 1, cell_w = sc.cell.w, cell_h = sc.cell.h, char_px = sc.char_px }
  local max_cols = overview_raster.code_columns(spec)
  local buf = self:target_buf()
  local tick = buf and vim.api.nvim_buf_get_changedtick(buf) or 0
  -- The filetype is part of the key: a buffer whose filetype is set after
  -- the first build (late detection, :setf) gets its syntax colours.
  local ft = buf and vim.bo[buf].filetype or ""
  local key = table.concat({ tostring(lines), max_cols, tick, self.code_generation, ft }, ":")
  local cached = self.code_cache
  if cached and cached.key == key then
    return cached
  end
  if cached and cached.buf == buf and cached.columns == max_cols and cached.generation == self.code_generation
      and cached.ft == ft then
    local delay = tonumber(self.options.code_debounce_ms) or 400
    ui.reschedule_once(self, "code_rebuild_scheduled", function()
      if self.code_cache == cached then
        self.code_cache = nil
        self:render()
      end
    end, delay)
    return cached
  end
  local space = color.image_colorspace(self.config)
  local built = overview_syntax.build(lines, {
    buf = buf,
    max_cols = max_cols,
    tabstop = buf and vim.bo[buf].tabstop or 8,
    encode = function(rgb)
      if space == "display-p3" then
        return color.srgb_to_display_p3(rgb)
      end
      return rgb
    end,
  })
  built.key = key
  built.buf = buf
  built.generation = self.code_generation
  built.ft = ft
  built.columns = max_cols
  self.code_cache = built
  return built
end

--- Everything one paint needs, or nil when the target is gone.
function Minimap:state()
  local win = self:target_win()
  if not win then
    return nil
  end
  local renderer = self:renderer()
  local height = math.max(1, vim.api.nvim_win_get_height(win))
  -- The text itself is only needed for the code shape and search ticks;
  -- otherwise a line count is enough (no full-buffer copy per keystroke).
  local need_lines = overview.code_shape(self.options, renderer)
    or (overview.search_enabled(self.options) and overview.active_search() ~= nil)
    or not self.provider.line_count
  local lines = need_lines and (self.provider.lines(self) or {}) or {}
  local line_count = need_lines and #lines or self.provider.line_count(self)
  local sc = scale(self, line_count, height, renderer)
  return {
    win = win,
    renderer = renderer,
    scale = sc,
    lines = lines,
    marks = self.provider.marks(self) or {},
    diagnostics = self.provider.diagnostics and self.provider.diagnostics(self) or {},
    line_count = line_count,
    map_lines = sc.map_lines,
    height = height,
    cursor_line = vim.api.nvim_win_get_cursor(win)[1],
    viewport = { first = vim.fn.line("w0", win), last = vim.fn.line("w$", win) },
    selection = overview.selection_enabled(self.options) and selection(win) or nil,
    search_lines = search_lines(self, lines),
  }
end

-- --- paint -----------------------------------------------------------------

local function set_modifiable(buf, value)
  pcall(vim.api.nvim_set_option_value, "modifiable", value, { buf = buf })
end

function Minimap:render()
  if self.disposed then
    return
  end
  local state = self:state()
  if not state then
    self.placement.hide(self)
    return
  end
  local width = self:width()
  local win, buf = self.placement.ensure(self, width)
  if not (valid_win(win) and valid_buf(buf)) then
    return
  end
  self.win, self.buf = win, buf
  if overview.mouse_enabled(self.options) then
    mouse.register(win, buf, self)
  end
  set_modifiable(buf, true)
  local painted = false
  if state.renderer == "kitty" then
    painted = kitty_overview.paint(self, SLOT, {
      buf = buf,
      ns = self.ns,
      marks = state.marks,
      line_count = state.line_count,
      map_lines = state.map_lines,
      rows = state.height,
      cols = width,
      overlays = overview.row_overlays(state, self.options),
      search_lines = state.search_lines,
      diagnostics = state.diagnostics,
      code = state.scale.code and code_layer(self, state.lines, state.scale) or nil,
    })
  else
    kitty_overview.destroy_side(self, SLOT)
  end
  if not painted then
    overview.render_side(buf, self.ns, state, self.options)
  end
  set_modifiable(buf, false)
end

--- Debounced repaint (cursor moves, scrolling, mode changes).
function Minimap:request_render()
  if self.disposed then
    return
  end
  local delay = tonumber(self.options.debounce_ms) or 32
  ui.schedule_once(self, "render_scheduled", function()
    self:render()
  end, delay)
end

--- The image state of this minimap (tests, perf).
function Minimap:image_state()
  return (self.kitty_overview_states or {})[SLOT]
end

--- Drop the cached code shape (a new document).
function Minimap:reset_code()
  self.code_cache = nil
end

-- --- interaction -------------------------------------------------------------

--- Centre the target on the line under strip row `row` (1-based).
function Minimap:jump_to_row(row)
  local state = self:state()
  if not state then
    return
  end
  local line = overview.line_for_row(row, state.line_count, state.map_lines, state.height)
  pcall(vim.api.nvim_win_set_cursor, state.win, { line, 0 })
  pcall(vim.api.nvim_win_call, state.win, function()
    vim.cmd("normal! zz")
  end)
  self:render()
end

--- Scroll the target by `count` lines (positive = down).
function Minimap:scroll(count)
  local win = self:target_win()
  if not win or count == 0 then
    return
  end
  local key = count > 0 and "\5" or "\25"
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! " .. math.abs(count) .. key)
  end)
end

function Minimap:focus_target()
  local win = self:target_win()
  if win and vim.api.nvim_get_current_win() ~= win then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

-- --- lifecycle ---------------------------------------------------------------

function Minimap:install_autocmds()
  local group = vim.api.nvim_create_augroup("DiffBanditMinimap" .. self.id, { clear = true })
  self.augroup = group
  local function on_target(fn)
    return function(ev)
      if self.disposed then
        return
      end
      return fn(ev)
    end
  end
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = on_target(function()
      -- ev.match names only the first scrolled window; v:event has all.
      local target = self:target_win()
      if target and (vim.v.event or {})[tostring(target)] then
        self:request_render()
      end
    end),
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged" }, {
    group = group,
    callback = on_target(function()
      if vim.api.nvim_get_current_win() == self:target_win() then
        self:request_render()
      end
    end),
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    pattern = { "/", "?" },
    callback = on_target(function()
      vim.schedule(function()
        self:request_render()
      end)
    end),
  })
  if self.provider.diagnostics then
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = group,
      callback = on_target(function(ev)
        if ev.buf == self:target_buf() then
          self:request_render()
        end
      end),
    })
  end
  if self.provider.on_text_changed then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      callback = on_target(function(ev)
        if ev.buf == self:target_buf() then
          self.provider.on_text_changed(self)
        end
      end),
    })
  end
  if self.placement.follows_layout then
    -- A float must follow its target when the layout moves.
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      group = group,
      callback = on_target(function()
        vim.schedule(function()
          self:render()
        end)
      end),
    })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = on_target(function(ev)
      if tonumber(ev.match) == self.target() then
        vim.schedule(function()
          if self.on_target_closed then
            self.on_target_closed(self)
          else
            self:close()
          end
        end)
      end
    end),
  })
end

function Minimap:close()
  if self.disposed then
    return
  end
  self.disposed = true
  ui.cancel_schedule_once(self, "render_scheduled")
  ui.cancel_schedule_once(self, "code_rebuild_scheduled")
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  mouse.unregister(self)
  if self.provider.detach then
    self.provider.detach(self)
  end
  if self.renderer_host then
    kitty_overview.destroy(self)
  else
    kitty.detach(self)
  end
  self.placement.close(self)
end

return Minimap
