-- Shared methods for objects painted by session.render.
-- Used by Session (full host) and merge pair_renderer (minimal render context).
-- Keep this free of layout/nav/panel orchestration so pair renderers do not
-- inherit the full Session class.

local connector = require("diffbandit.connector")
local connector_width = require("diffbandit.connector.width")
local nvim = require("diffbandit.util.nvim")
local session_render = require("diffbandit.session.render")
local ui = require("diffbandit.util.ui")

local M = {}

local get_win_view_topline = nvim.get_win_view_topline

-- Live window key: used only for the pre-paint dedupe gate (is this event a
-- no-op?). After paint, stamp from session._paint_viewport_key (ctx toplines).
local function live_viewport_render_key(self)
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
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

function M.base_paths(self)
  if not self.base_paths_cache then
    self.base_paths_cache = connector.compute_paths(self.view.chunks, self.view.line_meta)
    self.document_path_indexes_cache = nil
    self.meta_side_index_cache = nil
  end
  return self.base_paths_cache
end

-- Document-stable index sets from base paths (not viewport projection).
function M.document_path_indexes(self)
  if self.document_path_indexes_cache then
    return self.document_path_indexes_cache
  end
  local paths = self:base_paths()
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

function M.display_glyph(self, glyph)
  if not self.mirror_connector_sides then
    return glyph
  end
  local mirrored = {
    ["◤"] = "◥",
    ["◥"] = "◤",
    ["◢"] = "◣",
    ["◣"] = "◢",
  }
  return mirrored[glyph] or glyph
end

function M.project_paths_for_toplines(self, paths, left_topline, right_topline, left_height, right_height)
  return connector.project_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function M.project_paths_for_viewport(self, paths)
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
  return self:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function M.precompute_connector_core_width(self)
  local viewport_rows = vim.api.nvim_win_is_valid(self.left_win)
      and vim.api.nvim_win_get_height(self.left_win) or nil
  local required_core = connector.pressure_core_width(
    self:base_paths(),
    connector_width.base(self.view, self.config),
    connector_width.maximum(self.config),
    viewport_rows)
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

  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_cursor = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_cursor(self.left_win) or nil
  local right_cursor = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_cursor(self.right_win) or nil

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

  set_win_view_topline(self.left_win, left_topline)
  set_win_view_topline(self.left_num_win, left_topline)
  set_win_view_topline(self.connector_win, left_topline)
  set_win_view_topline(self.right_win, right_topline)
  set_win_view_topline(self.right_num_win, right_topline)
  if left_cursor and vim.api.nvim_win_is_valid(self.left_win) then
    pcall(vim.api.nvim_win_set_cursor, self.left_win, left_cursor)
  end
  if right_cursor and vim.api.nvim_win_is_valid(self.right_win) then
    pcall(vim.api.nvim_win_set_cursor, self.right_win, right_cursor)
  end
  self.rendering_viewport = false
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
