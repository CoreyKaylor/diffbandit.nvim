-- Shared methods for objects painted by session.render.
-- Used by Session (full host) and merge pair_renderer (minimal render context).
-- Keep this free of layout/nav/panel orchestration so pair renderers do not
-- inherit the full Session class.

local connector = require("diffbandit.connector")
local connector_width = require("diffbandit.connector.width")
local nvim = require("diffbandit.util.nvim")
local rowmap = require("diffbandit.util.rowmap")
local session_render = require("diffbandit.session.render")
local ui = require("diffbandit.util.ui")

local M = {}

local get_win_view_topline = nvim.get_win_view_topline

-- Live window key: used only for the pre-paint dedupe gate (is this event a
-- no-op?). After paint, stamp from session._paint_viewport_key (ctx toplines).
local function live_viewport_render_key(self)
  local left_topline, right_topline = self:gutter_toplines()
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and nvim.get_window_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and nvim.get_window_height(self.right_win) or 1
  return ui.viewport_render_key(left_topline, right_topline, left_height, right_height, self.current_chunk)
end

-- Host that owns the idle recovery timer (merge for pairs, else the session).
local function recovery_host(self)
  return self.merge_host or self
end

-- Latch key from paint-stamped keys (ctx-derived), never live window state.
-- Composite for merge so remote/local differences do not double-arm.
local function recovery_latch_key_from_stamps(self)
  local host = self.merge_host
  if not host then
    return self._paint_viewport_key or self.last_viewport_render_key
  end
  local parts = {}
  if host.result_remote_session then
    local p = host.result_remote_session
    parts[#parts + 1] = p._paint_viewport_key or p.last_viewport_render_key or ""
  end
  if host.local_result_session then
    local p = host.local_result_session
    parts[#parts + 1] = p._paint_viewport_key or p.last_viewport_render_key or ""
  end
  return table.concat(parts, "|")
end

--- Clear host-level idle recovery latch + timer. Used by invalidate and
--- Merge:render rebuild (single field list — do not hand-roll elsewhere).
function M.clear_idle_recovery_state(host)
  if not host then
    return
  end
  host._route_plan_needs_idle_recovery = false
  host._route_plan_idle_recovery_key = nil
  host._route_plan_idle_retry_key = nil
  ui.cancel_schedule_once(host, "route_plan_idle_retry_scheduled")
end

function M.invalidate_render_caches(self)
  self.base_paths_cache = nil
  self.row_paths_cache = nil
  self.overview_marks_cache = nil
  self.changed_spans_cache = nil
  self.display_lines_cache = nil
  self.route_plan_cache = nil
  self.document_path_indexes_cache = nil
  -- Force number/connector (and non-preserved source) buffer text rewrite on
  -- the next paint; scroll-only paints keep the previous structural fingerprint.
  self.structural_buffer_key = nil
  self.last_paint_clip = nil
  self.meta_side_index_cache = nil
  -- Content change: re-arm idle recovery for a subsequent degraded paint at
  -- the same viewport key (latch is not session-lifetime).
  M.clear_idle_recovery_state(self)
  if self.merge_host then
    M.clear_idle_recovery_state(self.merge_host)
  end
end

-- Row maps of the two source panes (util/rowmap). Wrapped lines and virtual
-- lines make a buffer line taller than one screen row; the gutters, the
-- connector and the route geometry all work in screen-row space. A change in
-- either map drops every cache derived from row geometry. `opts.verify`
-- re-measures the visible lines (decorations change heights without
-- touching the text) — the render path asks for it once per paint.
function M.row_maps(self, opts)
  local get = (opts and opts.verify) and rowmap.verified or rowmap.get
  local left_map = get(self.left_win, opts)
  local right_map = get(self.right_win, opts)
  local sig = rowmap.signature(left_map, right_map)
  if sig ~= self.row_map_signature then
    local first = self.row_map_signature == nil
    self.row_map_signature = sig
    self.row_paths_cache = nil
    self.document_path_indexes_cache = nil
    if not first then
      self.route_plan_cache = nil
      self.structural_buffer_key = nil
      self.last_paint_clip = nil
      self.last_viewport_render_key = nil
    end
  end
  return left_map, right_map
end

--- Screen-row toplines of the two source panes (what their number panes
--- and the connector scroll to). Uses the maps the gutters were last
--- painted with: sync runs per keystroke, and the gutter text only changes
--- on paint anyway.
function M.gutter_toplines(self)
  local left_map, right_map = self:row_maps({ stale_ok = true })
  return rowmap.topline_row(self.left_win, left_map), rowmap.topline_row(self.right_win, right_map)
end

-- Paths in screen-row space. Without wrapped lines that is line space and
-- the document model's paths are used as-is.
function M.base_paths(self)
  local left_map, right_map = self:row_maps()
  if left_map.identity and right_map.identity then
    if not self.base_paths_cache then
      self.base_paths_cache = connector.compute_paths(self.view.chunks, self.view.line_meta)
      self.meta_side_index_cache = nil
    end
    return self.base_paths_cache
  end
  if not self.row_paths_cache then
    local expanded = rowmap.expand_view(self.view, left_map, right_map)
    self.row_paths_cache = connector.compute_paths(expanded.chunks, expanded.line_meta)
  end
  return self.row_paths_cache
end

-- Document-stable index sets from base paths (not viewport projection),
-- keyed by screen row like the paths themselves.
function M.document_path_indexes(self)
  local paths = self:base_paths()
  if self.document_path_indexes_cache and self.document_path_indexes_cache.paths == paths then
    return self.document_path_indexes_cache
  end
  local embedded_add_terminal_right_indexes = {}
  local embedded_add_origin_left_indexes = {}
  local change_number_left_indexes = {}
  local change_number_right_indexes = {}
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
  self.document_path_indexes_cache = {
    paths = paths,
    embedded_add_terminal_right_indexes = embedded_add_terminal_right_indexes,
    embedded_add_origin_left_indexes = embedded_add_origin_left_indexes,
    change_number_left_indexes = change_number_left_indexes,
    change_number_right_indexes = change_number_right_indexes,
  }
  return self.document_path_indexes_cache
end

-- Dense per-side indexes for O(log n) viewport meta bounds. Parallel numeric
-- arrays (meta_index[], line_index[]) — not per-row tables — keep memory and
-- GC flat on large aligned files. line_meta may have long nil runs on
-- one-sided blocks; bisecting sparse line_meta is O(nil-run × log n).
function M.meta_side_indexes(self)
  if self.meta_side_index_cache then
    return self.meta_side_index_cache
  end
  local left_meta, left_line = {}, {}
  local right_meta, right_line = {}, {}
  local ln, rn = 0, 0
  for i, meta in ipairs(self.view.line_meta or {}) do
    if meta.left_index then
      ln = ln + 1
      left_meta[ln] = i
      left_line[ln] = meta.left_index
    end
    if meta.right_index then
      rn = rn + 1
      right_meta[rn] = i
      right_line[rn] = meta.right_index
    end
  end
  self.meta_side_index_cache = {
    left_meta = left_meta,
    left_line = left_line,
    right_meta = right_meta,
    right_line = right_line,
  }
  return self.meta_side_index_cache
end

function M.get_scroll_padding(self)
  if self.scroll_padding ~= nil then
    return self.scroll_padding
  end
  return 0
end

function M.display_lines(self)
  local padding = self:get_scroll_padding()
  if not self.display_lines_cache or self.display_lines_cache.padding ~= padding then
    local left_lines, right_lines = session_render.build_display_lines(self)
    self.display_lines_cache = {
      left = left_lines,
      right = right_lines,
      padding = padding,
    }
  end
  return self.display_lines_cache.left, self.display_lines_cache.right
end

function M.left_triangle_col(self)
  if self.mirror_connector_sides then
    return 0
  end
  return self.left_number_pane_width - 1
end

function M.left_number_text_start_col(self)
  return self.mirror_connector_sides and 1 or 0
end

function M.left_number_text_end_col(self)
  if self.mirror_connector_sides then
    return -1
  end
  return self:left_triangle_col()
end

function M.right_triangle_col(self)
  if self.mirror_connector_sides then
    return self.right_number_pane_width - 1
  end
  return 0
end

function M.right_number_text_start_col(self)
  return self.mirror_connector_sides and 0 or 1
end

function M.right_number_text_end_col(self)
  if self.mirror_connector_sides then
    return self:right_triangle_col()
  end
  return -1
end

-- Geometric wedges (U+25E2–25E5) are font-drawn in xterm.js and leave a gap
-- under VHS/ttyd. Powerline extra symbols E0B8/BA/BC/BE use xterm's custom
-- cell-fill vectors. Enable only for demos: vim.g.diffbandit_cell_wedges,
-- DIFFBANDIT_CELL_WEDGES=1, or ui.cell_wedges = true. Geometry logic keeps
-- the Unicode codepoints; only paint goes through this map.
local MIRRORED_WEDGES = {
  ["◤"] = "◥",
  ["◥"] = "◤",
  ["◢"] = "◣",
  ["◣"] = "◢",
}

-- U+E0BA lower-right, E0B8 lower-left, E0BC upper-left, E0BE upper-right.
local CELL_WEDGES = {
  ["◢"] = "",
  ["◣"] = "",
  ["◤"] = "",
  ["◥"] = "",
}

function M.cell_wedges_enabled(config)
  if vim.g.diffbandit_cell_wedges == true then
    return true
  end
  local env = vim.env and vim.env.DIFFBANDIT_CELL_WEDGES
  if env == "1" or env == "true" then
    return true
  end
  local ui = (config or {}).ui or {}
  return ui.cell_wedges == true
end

--- Map a route wedge for paint only. Mirror first (Unicode space), then
--- optional Powerline cell-fill remap for VHS/xterm.js demos.
function M.map_display_glyph(glyph, opts)
  opts = opts or {}
  if opts.mirror then
    glyph = MIRRORED_WEDGES[glyph] or glyph
  end
  if opts.cell_wedges then
    glyph = CELL_WEDGES[glyph] or glyph
  end
  return glyph
end

function M.display_glyph(self, glyph)
  return M.map_display_glyph(glyph, {
    mirror = self.mirror_connector_sides,
    cell_wedges = M.cell_wedges_enabled(self.config),
  })
end

function M.project_paths_for_toplines(self, paths, left_topline, right_topline, left_height, right_height)
  return connector.project_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function M.project_paths_for_viewport(self, paths)
  local left_topline, right_topline = self:gutter_toplines()
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and nvim.get_window_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and nvim.get_window_height(self.right_win) or 1
  return self:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function M.precompute_connector_core_width(self)
  local required_core
  if self.connector_renderer == "kitty" then
    -- Image ribbons have no lanes, so rail pressure does not apply: the
    -- core is IntelliJ divider-sized (stable across documents and files).
    required_core = require("diffbandit.kitty").core_width(self.config)
  else
    local viewport_rows = vim.api.nvim_win_is_valid(self.left_win)
        and nvim.get_window_height(self.left_win) or nil
    required_core = connector.pressure_core_width(
      self:base_paths(),
      connector_width.base(self.view, self.config),
      connector_width.maximum(self.config),
      viewport_rows)
  end
  if required_core ~= self.connector_core_width then
    self.connector_core_width = required_core
    if type(self.resize_layout) == "function" then
      self:resize_layout()
    end
  end
  return required_core
end

-- After every paint: always stamp the viewport dedupe key (including degraded
-- plans) so identical-viewport events are no-ops. Separately track degraded
-- state and arm one host-owned, re-debounced idle recovery timer so scroll
-- jiggle does not re-solve mid-stream and merge pairs arm recovery once.
--
-- `key` must be the ctx-derived paint key (session._paint_viewport_key), never
-- live window state after set_lines.
function M.finish_viewport_paint(self, key)
  key = key or self._paint_viewport_key
  -- Stamp unconditionally — restored no-op behavior for WinScrolled jiggle.
  self.last_viewport_render_key = key

  local host = recovery_host(self)
  local degraded = self._last_route_plan_aborted == true

  -- Merge: a clean pair must not cancel recovery still needed by its sibling.
  if self.merge_host and not degraded then
    local other = (host.local_result_session == self)
      and host.result_remote_session
      or host.local_result_session
    if other and other._last_route_plan_aborted then
      degraded = true
    end
  end

  if not degraded then
    -- Latch == last failed recovery: any clean paint clears it so a later
    -- degrade at the same key can recover again (e.g. cache eviction).
    host._route_plan_needs_idle_recovery = false
    host._route_plan_idle_recovery_key = nil
    host._route_plan_idle_retry_key = nil
    ui.cancel_schedule_once(host, "route_plan_idle_retry_scheduled")
    return
  end

  -- Only compute the composite latch key on the degraded path (finding 8).
  local latch_key = recovery_latch_key_from_stamps(self) or key

  -- New viewport key: allow one recovery again (latch is per-key, not lifetime).
  if host._route_plan_idle_retry_key ~= nil and host._route_plan_idle_retry_key ~= latch_key then
    host._route_plan_idle_retry_key = nil
  end

  -- Already recovered once for this key without a clean paint since — leave
  -- the stamped (degraded) paint; do not re-arm.
  if host._route_plan_idle_retry_key == latch_key then
    host._route_plan_needs_idle_recovery = false
    ui.cancel_schedule_once(host, "route_plan_idle_retry_scheduled")
    return
  end

  host._route_plan_needs_idle_recovery = true
  host._route_plan_idle_recovery_key = latch_key

  -- Re-debounce past scroll ticks so recovery is idle-gated, not mid-scroll.
  local scroll_ms = tonumber(((self.config or {}).ui or {}).scroll_debounce_ms) or 16
  local delay = math.max(50, scroll_ms * 2)
  ui.reschedule_once(host, "route_plan_idle_retry_scheduled", function()
    M.run_route_plan_idle_recovery(host)
  end, delay)
end

function M.run_route_plan_idle_recovery(host)
  if host.disposed or not host._route_plan_needs_idle_recovery then
    return
  end
  local key = host._route_plan_idle_recovery_key
  host._route_plan_needs_idle_recovery = false
  -- One recovery attempt per key until a clean paint clears the latch.
  host._route_plan_idle_retry_key = key

  if type(host.rerender_pair_viewports) == "function" then
    -- Merge host: clear both pairs' dedupe keys and mark recovery so the
    -- paint path skips degraded cache entries and re-solves under the bag.
    if host.result_remote_session then
      host.result_remote_session.last_viewport_render_key = nil
      host.result_remote_session.route_plan_recovery = true
    end
    if host.local_result_session then
      host.local_result_session.last_viewport_render_key = nil
      host.local_result_session.route_plan_recovery = true
    end
    host:rerender_pair_viewports({ recovery = true })
  else
    -- Single-session recovery: widen the budget like merge so the re-solve
    -- is not re-starved by the same 25ms that caused the degrade. Flag the
    -- recovery pass so build_render_context evicts the degraded cache hit.
    host.last_viewport_render_key = nil
    host.route_plan_recovery = true
    local budget_ms = ((host.config or {}).ui or {}).route_plan_budget_ms
    host.route_plan_deadline = ui.route_plan_budget_share(
      ui.route_plan_recovery_budget_ms(budget_ms))
    host:rerender_for_viewport()
  end
end

function M.render(self)
  -- Direct/structural paints always repaint; clear dedupe so finish can stamp.
  self.last_viewport_render_key = nil
  session_render.render(self)
  self:finish_viewport_paint(self._paint_viewport_key)
end

function M.rerender_for_viewport(self)
  if self.disposed or self.rendering_viewport then
    return
  end

  -- Full views (not just topline + cursor): a 'smoothscroll' skipcol on a
  -- wrapped topline must survive the paint.
  local function save_view(win)
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return nil
    end
    local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
    return ok and view or nil
  end
  local function restore_view(win, view)
    if view and win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  local left_view = save_view(self.left_win)
  local right_view = save_view(self.right_win)

  -- Dedupe against the last stamped (ctx-derived) key using live window state
  -- before paint — if they match, this event is a pure jiggle no-op.
  local live_key = live_viewport_render_key(self)
  if live_key == self.last_viewport_render_key then
    -- Drop a pre-stamped bag so a drained share cannot leak into a later path.
    self.route_plan_deadline = nil
    return
  end

  local set_win_view_topline = nvim.set_win_view_topline
  self.rendering_viewport = true
  -- Paint without going through M.render's "force clear" — we already decided
  -- this key needs work; finish stamps the ctx-derived key after paint.
  session_render.render(self)
  self:finish_viewport_paint(self._paint_viewport_key)

  restore_view(self.left_win, left_view)
  restore_view(self.right_win, right_view)
  local left_row, right_row = self:gutter_toplines()
  set_win_view_topline(self.left_num_win, left_row)
  set_win_view_topline(self.connector_win, left_row)
  set_win_view_topline(self.right_num_win, right_row)
  self.rendering_viewport = false
end

--- A paint re-wrapped a source pane (see session/render). Merge pairs repaint
--- through their host; a session re-measures and repaints itself.
function M.row_space_shifted(self)
  local host = self.merge_host
  if host then
    host.row_space_dirty = true
    host:request_render()
  elseif type(self.refresh_row_maps) == "function" then
    self:refresh_row_maps()
  end
end

--- Install shared render methods onto a host class table (e.g. Session).
function M.install(class)
  for name, fn in pairs(M) do
    if name ~= "install" and type(fn) == "function" then
      class[name] = fn
    end
  end
end

return M
