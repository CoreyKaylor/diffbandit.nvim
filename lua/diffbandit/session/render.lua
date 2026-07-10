-- The session render pipeline: builds display/number-pane text, applies
-- pane and connector backgrounds, intra-line change emphasis, origin
-- underlines, and connector route glyphs. Extracted from session.lua; every
-- stage takes the session as its first argument and renders into the
-- session's buffers and namespaces.
local nvim = require("diffbandit.util.nvim")
local connector = require("diffbandit.connector")
local diff_mod = require("diffbandit.diff")
local connector_width = require("diffbandit.connector.width")
local ui = require("diffbandit.util.ui")

local set_buffer_options = nvim.set_buffer_options
local get_win_view_topline = nvim.get_win_view_topline

local M = {}

-- --- Perf instrumentation (opt-in via ui.perf or DIFFBANDIT_PERF=1) ---

local function perf_config(session)
  return ((session.config or {}).ui or {}).perf or {}
end

local function perf_enabled(session)
  if vim.env.DIFFBANDIT_PERF == "1" then
    return true
  end
  return perf_config(session).enabled == true
end

local function perf_should_log(session)
  if vim.env.DIFFBANDIT_PERF == "1" then
    return true
  end
  local cfg = perf_config(session)
  return cfg.enabled == true and cfg.log == true
end

local function perf_now()
  if vim.uv and vim.uv.hrtime then
    return vim.uv.hrtime()
  end
  return 0
end

local function perf_ms(t0, t1)
  if not t0 or not t1 or t1 < t0 then
    return 0
  end
  return (t1 - t0) / 1e6
end

-- --- Structural buffer fingerprint (document model vs viewport paint) ---

local function staged_fingerprint(states)
  if not states then
    return ""
  end
  local parts = {}
  for k, v in pairs(states) do
    if v then
      parts[#parts + 1] = tostring(k)
    end
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Iterate meta indexes covered by the paint clip. Prefer disjoint meta_ranges
-- (independent scroll) so a left@1 / right@500k viewport does not walk the gap.
local function for_each_meta_index(ctx, fn)
  local ranges = ctx.meta_ranges
  if ranges and #ranges > 0 then
    for ri = 1, #ranges do
      local r = ranges[ri]
      for idx = r[1], r[2] do
        fn(idx)
      end
    end
    return
  end
  local lo = ctx.meta_min or 1
  local hi = ctx.meta_max or 0
  for idx = lo, hi do
    fn(idx)
  end
end

-- Key for number/connector (and non-preserved source) buffer text. Scroll does
-- not change this; open / replace_sources / width / padding / stage markers do.
local function structural_buffer_key(self, left_n, right_n, connector_height)
  return table.concat({
    tostring(left_n),
    tostring(right_n),
    tostring(connector_height),
    tostring(self.connector_core_width or 0),
    tostring(self.left_number_pane_width or 0),
    tostring(self.right_number_pane_width or 0),
    tostring(self.left_number_width or 0),
    tostring(self.right_number_width or 0),
    tostring(self.left_stage_marker_width or 0),
    tostring(self.right_stage_marker_width or 0),
    tostring(self.mirror_connector_sides and 1 or 0),
    staged_fingerprint(self.staged_chunk_states),
    tostring(self.view and #(self.view.line_meta or {}) or 0),
    tostring(self.view and #(self.view.chunks or {}) or 0),
  }, ":")
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
  -- Left-align number (pad on right) so numbers expand rightward toward center
  local fmt = string.format("%%-%dd", width)
  return string.format(fmt, num)
end

local function source_display_number(source, line_num)
  if not line_num then
    return nil
  end
  local display_numbers = source and source.display_numbers
  if display_numbers and display_numbers[line_num] then
    return display_numbers[line_num]
  end
  return line_num
end

local function format_display_number(value, width, align_left)
  if not value then
    return string.rep(" ", width)
  end
  if type(value) == "number" then
    if align_left then
      return format_line_number_left(value, width)
    end
    return format_line_number(value, width)
  end
  value = tostring(value)
  local display = vim.fn.strdisplaywidth(value)
  if display >= width then
    return value
  end
  local padding = string.rep(" ", width - display)
  if align_left then
    return value .. padding
  end
  return padding .. value
end

local function build_display_lines(session)
  -- View arrays have different lengths; copy them so render-time scroll
  -- padding does not mutate the canonical diff view.
  local left_lines = vim.list_extend({}, session.view.left)
  local right_lines = vim.list_extend({}, session.view.right)
  local padding = session:get_scroll_padding()
  for _ = 1, padding do
    left_lines[#left_lines + 1] = ""
    right_lines[#right_lines + 1] = ""
  end
  return left_lines, right_lines
end

local function render_empty_source_notice(buf, namespace, source)
  if not source or not source.empty_reason or #(source.lines or {}) > 0 then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
    virt_text = { { "  " .. source.empty_reason, "DiffBanditEmptyNotice" } },
    virt_text_pos = "overlay",
    priority = 20,
  })
end

-- Highlight lookup tables for left/right/connector panes
local HIGHLIGHT_LEFT = {
  context = "DiffBanditContext",
  add = "DiffBanditAddLeft",
  delete = "DiffBanditDelete",
  change = { default = "DiffBanditChangeLeft", filler = "DiffBanditGap" },
}

local HIGHLIGHT_RIGHT = {
  context = "DiffBanditContext",
  add = { default = "DiffBanditAdd", filler = "DiffBanditGap" },
  delete = { default = "DiffBanditChangeRight", filler = "DiffBanditGap" },
  change = { default = "DiffBanditChangeRight", filler = "DiffBanditGap" },
}

local function get_highlight(tbl, meta, filler_key)
  local entry = tbl[meta.kind]
  if type(entry) == "table" then
    return meta[filler_key] and entry.filler or entry.default
  end
  return entry
end

local function highlight_for_left(meta)
  return get_highlight(HIGHLIGHT_LEFT, meta, "filler_left")
end

local function highlight_for_right(meta)
  return get_highlight(HIGHLIGHT_RIGHT, meta, "filler_right")
end

-- Gather everything the render stages need in one pass: display lines,
-- viewport toplines, projected routes with their plan, and the per-row index
-- sets that steer number-pane and background styling.
local function build_render_context(self)
  local left_lines, right_lines = self:display_lines()
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_text_hl_mode = self.right.editable and "combine" or "replace"

  -- Compute connector routing lanes using extracted paths module. Projection
  -- and planning are the most expensive render stages, and both are pure
  -- functions of the viewport state — cache per state so revisited viewports
  -- (navigation back and forth, debounced duplicate repaints) are free.
  local paths = self:base_paths()
  local win_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
  local plan_cache_key = string.format("%s:%s:%d:%d:%d:%d",
    tostring(left_topline), tostring(right_topline), left_height, win_height,
    self.current_chunk or 0, self.connector_core_width or 0)
  self.route_plan_cache = self.route_plan_cache or { n = 0 }
  local route_paths, route_plan
  local delete_origin_right_lines
  local add_origin_row_has_transition
  local solid_change_number_left_indexes
  local solid_change_number_right_indexes
  -- Wall-clock budget for plan + near-width + width-search. Merge stamps a
  -- shared remaining-ms bag so the two pair solves share one budget and paint
  -- between them does not drain the sibling's leftover ms. Mint only when
  -- actually planning (cache hits must not debit the sibling).
  local budget_ms = tonumber((self.config.ui or {}).route_plan_budget_ms) or 25
  local budget_share = self.route_plan_deadline
  self.route_plan_deadline = nil
  local deadline = nil
  local cascade_time_truncated = false
  local function should_abort()
    if deadline == nil then
      return false
    end
    -- Guard the clock: ui may hand back deadline 0 when exhausted/no-clock;
    -- unguarded vim.uv.hrtime crashes vim.loop-only runtimes.
    local hr = vim.uv and vim.uv.hrtime
    if not hr then
      return deadline == 0
    end
    return hr() > deadline
  end
  local function plan_route_count(plan)
    return #((plan and plan.routes) or {})
  end
  -- Degraded: wall-clock abort on the plan itself, OR a cascade truncated by
  -- the clock that kept an incomplete (non-success) plan — e.g. deterministic
  -- bounded-hidden core kept because width search never ran under time pressure.
  local function plan_is_degraded(plan)
    if cascade_time_truncated then
      return true
    end
    return plan ~= nil and plan.aborted == true
  end

  local plan_degraded = false
  -- Recovery pass must re-solve: skip (and drop) a degraded cache entry so the
  -- widened recovery budget is actually consumed by the solver.
  local recovery_pass = self.route_plan_recovery == true
  self.route_plan_recovery = nil
  local cached_plan = self.route_plan_cache[plan_cache_key]
  if cached_plan and recovery_pass and cached_plan.degraded then
    self.route_plan_cache[plan_cache_key] = nil
    if self.route_plan_cache.n and self.route_plan_cache.n > 0 then
      self.route_plan_cache.n = self.route_plan_cache.n - 1
    end
    cached_plan = nil
  end
  if cached_plan then
    route_paths = cached_plan.route_paths
    route_plan = cached_plan.route_plan
    delete_origin_right_lines = cached_plan.delete_origin_right_lines
    add_origin_row_has_transition = cached_plan.add_origin_row_has_transition
    solid_change_number_left_indexes = cached_plan.solid_change_number_left_indexes
    solid_change_number_right_indexes = cached_plan.solid_change_number_right_indexes
    -- Replay paint from cache; keep recovery eligibility via degraded marker.
    plan_degraded = cached_plan.degraded == true
  else
    -- Project first, then mint the deadline — projection is one of the two
    -- most expensive stages and must not debit the solver budget.
    route_paths = self:project_paths_for_viewport(paths)
    deadline = ui.route_plan_deadline(budget_ms, budget_share)

    local plan_layout = {
      connector_core_width = self.connector_core_width,
      viewport_topline = left_topline,
      viewport_height = left_height,
      max_route_backtrack_steps = 500,
      -- deadline == 0 means exhausted shared bag (always abort). nil = no budget.
      should_abort = (deadline ~= nil) and should_abort or nil,
      -- The navigated chunk's connector is the one the user is looking at;
      -- overflow pruning hides it only when no other candidate remains.
      active_chunk_index = (self.current_chunk or 0) > 0 and self.current_chunk or nil,
    }
    route_plan = connector.plan_routes(route_paths, plan_layout)
    if not route_plan.success and not (plan_layout.should_abort and plan_layout.should_abort()) then
      -- Wide cores can make the fixed-width search tree thrash on viewports
      -- that a narrower working width solves immediately — solvability is
      -- NOT monotone in width. Try a few near-core widths first (the usual
      -- cure for fixed-width thrash, often solving in one attempt), then
      -- fall back to the upward width search from the minimum. Successful
      -- narrower solutions get their edge-docked horizontals stretched out
      -- to the real core edge; the gutter width itself never changes here.
      local min_width = connector_width.minimum(self.config)
      local core_plan = route_plan
      for width = self.connector_core_width - 1, math.max(min_width, self.connector_core_width - 3), -1 do
        if plan_layout.should_abort and plan_layout.should_abort() then
          break
        end
        local near_layout = vim.tbl_extend("force", {}, plan_layout, { connector_core_width = width })
        local near_plan = connector.plan_routes(route_paths, near_layout)
        if near_plan.success then
          route_plan = connector.stretch_plan_to_core(near_plan, width, self.connector_core_width)
          break
        end
        if near_plan.aborted then
          -- Stretch narrow-core geometry to the real core before paint.
          -- Prefer strictly more routes; on a tie keep the cacheable
          -- deterministic plan over an aborted one with identical output.
          local stretched = connector.stretch_plan_to_core(near_plan, width, self.connector_core_width)
          if plan_route_count(stretched) > plan_route_count(core_plan) then
            route_plan = stretched
          else
            route_plan = core_plan
          end
          break
        end
      end
      if not route_plan.success and not route_plan.aborted
          and not (plan_layout.should_abort and plan_layout.should_abort()) then
        -- Width-search step cap lives in required_connector_core_width_for_paths
        -- (generous default; wall-clock abort still inherited).
        local solved_width, retry_plan = connector.required_connector_core_width_for_paths(
          route_paths,
          min_width,
          self.connector_core_width,
          plan_layout)
        if retry_plan.success then
          route_plan = connector.stretch_plan_to_core(retry_plan, solved_width, self.connector_core_width)
        elseif retry_plan.aborted and solved_width then
          local stretched = connector.stretch_plan_to_core(retry_plan, solved_width, self.connector_core_width)
          if plan_route_count(stretched) > plan_route_count(route_plan) then
            route_plan = stretched
          end
        else
          if plan_route_count(retry_plan) > plan_route_count(route_plan) then
            route_plan = retry_plan
          end
        end
      end
    end

    -- Clock expired with an incomplete plan: cascade (near-width / width
    -- search) may never have run. Treat as degraded so we do not cache a
    -- time-truncated bounded-hidden core and replay it forever at idle.
    if not route_plan.success and deadline ~= nil and should_abort() then
      cascade_time_truncated = true
    end

    -- plan_routes mutates hide/planned flags on the shared paths. Multi-plan
    -- selection may keep an earlier plan while a discarded solve left its
    -- flags behind — re-apply the chosen plan so paint matches segments.
    connector.apply_plan_path_state(route_paths, route_plan)

    -- Debit shared remaining-ms bag immediately after cascade selection so
    -- underline/solid-index prep does not drain the sibling pair's budget.
    ui.route_plan_budget_release(budget_share, deadline)

    -- Underline / solid-band helpers ride the same viewport cache.
    local underline_layout = {
      left_number_width = 0,
      connector_core_width = self.connector_core_width,
      rail_spacing = 1,
      sidecar_numbers = true,
    }
    local underline_data = connector.compute_underlines(
      route_paths, connector.compute_active_bars(route_paths), underline_layout)
    delete_origin_right_lines = underline_data.delete_origin_right_lines or {}
    add_origin_row_has_transition = {}
    for _, p in ipairs(route_paths) do
      if p.kind == "add"
          and not p.embedded_in_change
          and not p.hide_triangle
          and not p.overflow_hidden
          and p.origin_display_row
          and (p.triangle_display_row or p.display_start_row) == p.origin_display_row then
        add_origin_row_has_transition[p.origin_display_row] = true
      end
    end
    solid_change_number_left_indexes = {}
    solid_change_number_right_indexes = {}
    for _, p in ipairs(route_paths) do
      if p.kind == "change" and p.viewport_solid_start and p.viewport_solid_end then
        -- viewport_solid rows are the side-by-side overlap in LEFT-row space
        -- (projection maps right rows into it via the screen alignment), NOT
        -- line_meta display indexes: map back directly.
        for row = p.viewport_solid_start, p.viewport_solid_end do
          if row >= 1 and row <= #left_lines then
            solid_change_number_left_indexes[row] = true
          end
          local right_index = right_topline + (row - left_topline)
          if right_index >= 1 and right_index <= #right_lines then
            solid_change_number_right_indexes[right_index] = true
          end
        end
      end
    end

    -- Cache every plan including degraded ones. Mark degraded so paint can
    -- replay without re-solving (avoids re-aborting on every jiggle) while
    -- finish_viewport_paint still arms idle recovery.
    plan_degraded = plan_is_degraded(route_plan)
    if self.route_plan_cache.n >= 48 then
      self.route_plan_cache = { n = 0 }
    end
    self.route_plan_cache[plan_cache_key] = {
      route_paths = route_paths,
      route_plan = route_plan,
      delete_origin_right_lines = delete_origin_right_lines,
      add_origin_row_has_transition = add_origin_row_has_transition,
      solid_change_number_left_indexes = solid_change_number_left_indexes,
      solid_change_number_right_indexes = solid_change_number_right_indexes,
      degraded = plan_degraded,
    }
    self.route_plan_cache.n = self.route_plan_cache.n + 1
  end

  local doc_indexes = self:document_path_indexes()
  local embedded_add_terminal_right_indexes = doc_indexes.embedded_add_terminal_right_indexes
  local embedded_add_origin_left_indexes = doc_indexes.embedded_add_origin_left_indexes
  local change_number_left_indexes = doc_indexes.change_number_left_indexes
  local change_number_right_indexes = doc_indexes.change_number_right_indexes
  local function display_row_to_left_index(display_row)
    local meta = self.view.line_meta[display_row]
    if meta and meta.left_index then
      return meta.left_index
    end
    if display_row and display_row >= 1 and display_row <= #left_lines then
      return display_row
    end
    return nil
  end
  local function display_row_to_right_index(display_row)
    local meta = self.view.line_meta[display_row]
    if meta and meta.right_index then
      return meta.right_index
    end
    local right_index = right_topline + ((display_row or left_topline) - left_topline)
    if right_index >= 1 and right_index <= #right_lines then
      return right_index
    end
    return nil
  end

  -- The connector buffer owns the aligned display model and must include the
  -- same scroll padding as the source panes so routes can remain visible while
  -- either side is scrolled past real EOF.
  local connector_height = math.max(#self.view.line_meta, #left_lines, #right_lines)

  -- Structural buffer text (numbers, blank connector rows, non-preserved
  -- sources) is document-model state: rewrite only when the fingerprint
  -- changes. Pure viewport paints reuse existing buffer lines and only
  -- re-project / replan / repaint extmarks.
  local struct_key = structural_buffer_key(self, #left_lines, #right_lines, connector_height)
  local write_structural = self.structural_buffer_key ~= struct_key

  local connector_lines = nil
  local right_stage_markers = {}
  if write_structural then
    connector_lines = {}
    local blank = string.rep(" ", self.connector_core_width)
    for i = 1, connector_height do
      connector_lines[i] = blank
    end

    if (self.right_stage_marker_width or 0) > 0 then
      local indicator = ((self.config.actions or {}).staged_indicator or {})
      local staged_glyph = indicator.staged or "▣"
      local unstaged_glyph = indicator.unstaged or "□"
      local staged_states = self.staged_chunk_states or {}

      local function marker_for_chunk(chunk_index)
        return staged_states[chunk_index] and staged_glyph or unstaged_glyph
      end

      local function mark_right(row, chunk_index)
        if row and row >= 1 and row <= #right_lines then
          right_stage_markers[row] = marker_for_chunk(chunk_index)
        end
      end

      -- Exactly one marker per chunk, anchored to stable view geometry (NOT
      -- route geometry: projected routes mark several rows for a wide block,
      -- and hidden/clipped routes mark none — duplicated or missing boxes).
      -- The marker sits on the chunk's first real right-pane row; pure
      -- deletions have no right rows, so they anchor on the context row the
      -- deletion attaches to (above, falling back to below at file top).
      for _, chunk in ipairs(self.view.chunks) do
        local marker_row = nil
        for idx = chunk.display_start, chunk.display_end do
          local meta = self.view.line_meta[idx]
          if meta and meta.right_index and not meta.filler_right then
            marker_row = meta.right_index
            break
          end
        end
        if not marker_row then
          for idx = chunk.display_start - 1, 1, -1 do
            local meta = self.view.line_meta[idx]
            if meta and meta.right_index then
              marker_row = meta.right_index
              break
            end
          end
        end
        if not marker_row then
          for idx = chunk.display_end + 1, #self.view.line_meta do
            local meta = self.view.line_meta[idx]
            if meta and meta.right_index then
              marker_row = meta.right_index
              break
            end
          end
        end
        mark_right(marker_row, chunk.index)
      end
    end
  end

  -- Viewport clipping bounds for the per-row mark loops. Document-wide
  -- extmark application dominated render cost on large files; marks are only
  -- needed for rows that can appear on screen before the next debounced
  -- scroll re-render, so each loop skips rows outside the padded viewports.
  -- Headroom (viewport_clip_pad) covers multi-screen flings within one tick;
  -- connector solid projection stays strict-window.
  local right_height = win_height
  local clip_pad = connector_width.viewport_clip_pad(left_height, right_height)
  local left_row_min = math.max(1, (left_topline or 1) - clip_pad)
  local left_row_max = (left_topline or 1) + left_height + clip_pad
  local right_row_min = math.max(1, (right_topline or 1) - clip_pad)
  local right_row_max = (right_topline or 1) + right_height + clip_pad
  local function left_row_visible(row)
    return row ~= nil and row >= left_row_min and row <= left_row_max
  end
  local function right_row_visible(row)
    return row ~= nil and row >= right_row_min and row <= right_row_max
  end
  local function meta_visible(meta)
    return left_row_visible(meta.left_index) or right_row_visible(meta.right_index)
  end
  -- Meta-space bounds: each side's non-nil indexes are monotone in line_meta
  -- order. Bisect parallel numeric arrays (left_line/left_meta, …). Keep
  -- left and right as separate intervals and merge only when they overlap —
  -- collapsing into one meta_min..meta_max under divergent independent
  -- scroll (left near 1, right near 500k) would scan the entire gap.
  local meta_list = self.view.line_meta
  local meta_n = #meta_list
  local meta_min, meta_max = 1, meta_n
  local meta_ranges = {}
  if meta_n == 0 then
    meta_min, meta_max = 1, 0
  else
    local side_idx = self:meta_side_indexes()
    local function first_ge(line_arr, meta_arr, bound)
      local lo, hi, ans = 1, #line_arr, nil
      while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if line_arr[mid] < bound then
          lo = mid + 1
        else
          ans = meta_arr[mid]
          hi = mid - 1
        end
      end
      return ans
    end
    local function last_le(line_arr, meta_arr, bound)
      local lo, hi, ans = 1, #line_arr, nil
      while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if line_arr[mid] > bound then
          hi = mid - 1
        else
          ans = meta_arr[mid]
          lo = mid + 1
        end
      end
      return ans
    end
    local first_left = first_ge(side_idx.left_line, side_idx.left_meta, left_row_min)
    local first_right = first_ge(side_idx.right_line, side_idx.right_meta, right_row_min)
    local last_left = last_le(side_idx.left_line, side_idx.left_meta, left_row_max)
    local last_right = last_le(side_idx.right_line, side_idx.right_meta, right_row_max)
    local raw = {}
    if first_left and last_left and first_left <= last_left then
      raw[#raw + 1] = { first_left, last_left }
    end
    if first_right and last_right and first_right <= last_right then
      raw[#raw + 1] = { first_right, last_right }
    end
    if #raw == 0 then
      meta_min, meta_max = 1, 0
    elseif #raw == 1 then
      meta_ranges = raw
      meta_min, meta_max = raw[1][1], raw[1][2]
    else
      -- Sort and merge overlapping / adjacent intervals.
      if raw[1][1] > raw[2][1] then
        raw[1], raw[2] = raw[2], raw[1]
      end
      if raw[2][1] <= raw[1][2] + 1 then
        meta_ranges = { { raw[1][1], math.max(raw[1][2], raw[2][2]) } }
      else
        meta_ranges = raw
      end
      meta_min = meta_ranges[1][1]
      meta_max = meta_ranges[#meta_ranges][2]
    end
  end

  -- Single paint-clip record for this render (namespace clears + path glyphs).
  -- Previous frame's clip lives on self.last_paint_clip until paint finishes.
  local paint_clip = {
    left_min = left_row_min,
    left_max = left_row_max,
    right_min = right_row_min,
    right_max = right_row_max,
    meta_min = meta_min,
    meta_max = meta_max,
    meta_ranges = meta_ranges,
    connector_min = left_row_min,
    connector_max = math.min(left_row_max, connector_height),
  }

  -- Navigation uses this to decide whether a target viewport is already
  -- fully styled (defer the repaint through the scroll debounce) or needs a
  -- synchronous render (long jump outside the clipped window).
  -- Connector buffer rows are left-scroll-aligned (same topline as left).
  self.last_render_clip = paint_clip

  -- External signs (diagnostics etc.) make the right pane's sign column
  -- visible; band rows then need their own sign-column fill. Our own band
  -- signs from the previous render are still present at this point (the
  -- namespaces clear later), so they must not count as "external".
  local right_has_signs = false
  local right_diag_severity = {}
  local diag_sign_text = { "E", "W", "I", "H" }
  local diag_signs_enabled = true
  do
    local signs_cfg = (vim.diagnostic.config() or {}).signs
    if signs_cfg == false then
      diag_signs_enabled = false
    elseif type(signs_cfg) == "table" and type(signs_cfg.text) == "table" then
      for severity, glyph in pairs(signs_cfg.text) do
        if type(severity) == "number" then
          diag_sign_text[severity] = glyph
        end
      end
    end
  end
  if self.right_buf and vim.api.nvim_buf_is_valid(self.right_buf) then
    if diag_signs_enabled then
      local ok_diag, diags = pcall(vim.diagnostic.get, self.right_buf)
      for _, d in ipairs(ok_diag and diags or {}) do
        local lnum = d.lnum + 1
        local severity = d.severity or vim.diagnostic.severity.ERROR
        if not right_diag_severity[lnum] or severity < right_diag_severity[lnum] then
          right_diag_severity[lnum] = severity
        end
        right_has_signs = true
      end
    end
    if not right_has_signs then
      local sign_marks = vim.api.nvim_buf_get_extmarks(self.right_buf, -1, 0, -1, { type = "sign", details = true })
      for _, mark in ipairs(sign_marks) do
        local d = mark[4] or {}
        if d.ns_id ~= self.extmark_ns then
          right_has_signs = true
          break
        end
      end
    end
  end
  -- Remembered so the DiagnosticChanged autocmd can tell whether sign
  -- presence actually flipped since the last render.
  self.right_signs_state = right_has_signs

  return {
    right_has_signs = right_has_signs,
    right_diag_severity = right_diag_severity,
    diag_sign_text = diag_sign_text,
    left_lines = left_lines,
    right_lines = right_lines,
    left_topline = left_topline,
    right_topline = right_topline,
    left_height = left_height,
    right_height = win_height,
    right_text_hl_mode = right_text_hl_mode,
    left_row_visible = left_row_visible,
    right_row_visible = right_row_visible,
    meta_visible = meta_visible,
    meta_min = meta_min,
    meta_max = meta_max,
    meta_ranges = meta_ranges,
    left_row_min = left_row_min,
    left_row_max = left_row_max,
    right_row_min = right_row_min,
    right_row_max = right_row_max,
    paths = paths,
    route_paths = route_paths,
    route_plan = route_plan,
    -- Abort or time-truncated cascade (including degraded cache replays).
    route_plan_aborted = plan_degraded,
    paint_clip = paint_clip,
    delete_origin_right_lines = delete_origin_right_lines,
    add_origin_row_has_transition = add_origin_row_has_transition,
    embedded_add_terminal_right_indexes = embedded_add_terminal_right_indexes,
    embedded_add_origin_left_indexes = embedded_add_origin_left_indexes,
    change_number_left_indexes = change_number_left_indexes,
    change_number_right_indexes = change_number_right_indexes,
    solid_change_number_left_indexes = solid_change_number_left_indexes,
    solid_change_number_right_indexes = solid_change_number_right_indexes,
    connector_height = connector_height,
    connector_lines = connector_lines,
    right_stage_markers = right_stage_markers,
    write_structural = write_structural,
    structural_key = struct_key,
    display_row_to_left_index = display_row_to_left_index,
    display_row_to_right_index = display_row_to_right_index,
  }
end

-- Build the fixed-width number-pane text for both sides, including stage
-- markers when enabled.
local function render_number_panes(self, ctx)
  -- Left and right buffers now have different line counts
  ctx.left_num_lines = {}
  for i = 1, #ctx.left_lines do
    ctx.left_num_lines[i] = string.rep(" ", self.left_number_pane_width)
  end
  ctx.right_num_lines = {}
  for i = 1, #ctx.right_lines do
    ctx.right_num_lines[i] = string.rep(" ", self.right_number_pane_width)
  end
  for _, meta in ipairs(self.view.line_meta) do
    if meta.left_index then
      if (self.left_stage_marker_width or 0) > 0 then
        ctx.left_num_lines[meta.left_index] = " "
          .. format_display_number(source_display_number(self.left, meta.left_line), self.left_number_width, false)
          .. " "
      else
        ctx.left_num_lines[meta.left_index] = format_display_number(source_display_number(self.left, meta.left_line), self.left_number_width, false) .. " "
      end
    end
    if meta.right_index then
      if self.mirror_connector_sides then
        ctx.right_num_lines[meta.right_index] = format_display_number(source_display_number(self.right, meta.right_line), self.right_number_width, false) .. " "
      elseif (self.right_stage_marker_width or 0) > 0 then
        ctx.right_num_lines[meta.right_index] = " "
          .. format_display_number(source_display_number(self.right, meta.right_line), self.right_number_width, true)
          .. (ctx.right_stage_markers[meta.right_index] or " ")
      else
        ctx.right_num_lines[meta.right_index] = " " .. format_display_number(source_display_number(self.right, meta.right_line), self.right_number_width, true)
      end
    end
  end
end

-- Write display lines into buffers. Number/connector (and non-preserved
-- sources) are document-model state: only rewritten when write_structural.
local function apply_buffer_lines(self, ctx)
  if not ctx.write_structural then
    return
  end
  if not self.preserve_left_buffer_lines then
    vim.api.nvim_buf_set_lines(self.left_buf, 0, -1, false, ctx.left_lines)
  end
  vim.api.nvim_buf_set_lines(self.left_num_buf, 0, -1, false, ctx.left_num_lines)
  if not self.preserve_right_buffer_lines then
    vim.api.nvim_buf_set_lines(self.right_buf, 0, -1, false, ctx.right_lines)
  end
  vim.api.nvim_buf_set_lines(self.right_num_buf, 0, -1, false, ctx.right_num_lines)
  vim.api.nvim_buf_set_lines(self.connector_buf, 0, -1, false, ctx.connector_lines)
  self.structural_buffer_key = ctx.structural_key

  set_buffer_options(self.left_buf, { modifiable = false })
  set_buffer_options(self.left_num_buf, { modifiable = false })
  set_buffer_options(self.right_buf, { modifiable = self.right.editable ~= nil })
  set_buffer_options(self.right_num_buf, { modifiable = false })
  set_buffer_options(self.connector_buf, { modifiable = false })
end

-- Clear a namespace over a 1-based inclusive row range (or full buffer).
-- end_row is exclusive for the Neovim API (0-indexed line_end).
local function clear_ns_range(buf, ns, row_min, row_max, full)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not ns then
    return
  end
  if full or not row_min or not row_max or row_max < row_min then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, math.max(0, row_min - 1), row_max)
end

-- Union of previous and current viewport clips (1-based inclusive ranges).
-- Shared by namespace clear and path_ns clear so pad/coord changes stay in sync.
local function union_clip_ranges(prev, cur_left_min, cur_left_max, cur_right_min, cur_right_max, cur_conn_min, cur_conn_max)
  local left_min, left_max = cur_left_min, cur_left_max
  local right_min, right_max = cur_right_min, cur_right_max
  local connector_min, connector_max = cur_conn_min, cur_conn_max
  if prev then
    left_min = math.min(left_min, prev.left_min or left_min)
    left_max = math.max(left_max, prev.left_max or left_max)
    right_min = math.min(right_min, prev.right_min or right_min)
    right_max = math.max(right_max, prev.right_max or right_max)
    connector_min = math.min(connector_min, prev.connector_min or connector_min)
    connector_max = math.max(connector_max, prev.connector_max or connector_max)
  end
  return left_min, left_max, right_min, right_max, connector_min, connector_max
end

-- Reset paint namespaces. Structural (document) paints clear everything;
-- viewport paints clear the union of the previous and current clip so marks
-- do not accumulate off-screen while scroll stays O(viewport).
--
-- Coordinate spaces (do not mix):
--   left_*/right_*  → source + number pane buffer rows
--   connector_*     → connector buffer rows (= left-row/screen space; the
--                     connector window shares the left pane's topline)
--   meta_*          → line_meta indexes only (iteration bounds), NOT buffer rows
--
-- Does not advance self.last_paint_clip — path-glyph clear also needs the
-- previous frame's range; render() commits the clip once after all clears.
local function clear_render_namespaces(self, ctx)
  self.extmark_ns = self.extmark_ns or vim.api.nvim_create_namespace("DiffBanditExtmarks" .. self.id)
  self.linenum_ns = self.linenum_ns or vim.api.nvim_create_namespace("DiffBanditLineNums" .. self.id)

  local full = ctx.write_structural or not self.last_paint_clip
  local cur = ctx.paint_clip
  local left_min, left_max, right_min, right_max, connector_min, connector_max =
      union_clip_ranges(
        (not full) and self.last_paint_clip or nil,
        cur.left_min, cur.left_max, cur.right_min, cur.right_max,
        cur.connector_min, cur.connector_max)

  clear_ns_range(self.left_buf, self.ns, left_min, left_max, full)
  clear_ns_range(self.left_num_buf, self.ns, left_min, left_max, full)
  clear_ns_range(self.right_buf, self.ns, right_min, right_max, full)
  clear_ns_range(self.right_num_buf, self.ns, right_min, right_max, full)
  clear_ns_range(self.connector_buf, self.ns, connector_min, connector_max, full)

  clear_ns_range(self.left_buf, self.extmark_ns, left_min, left_max, full)
  clear_ns_range(self.left_num_buf, self.extmark_ns, left_min, left_max, full)
  clear_ns_range(self.right_buf, self.extmark_ns, right_min, right_max, full)
  clear_ns_range(self.right_num_buf, self.extmark_ns, right_min, right_max, full)
  clear_ns_range(self.connector_buf, self.extmark_ns, connector_min, connector_max, full)

  clear_ns_range(self.left_num_buf, self.linenum_ns, left_min, left_max, full)
  clear_ns_range(self.connector_buf, self.linenum_ns, connector_min, connector_max, full)
  clear_ns_range(self.right_num_buf, self.linenum_ns, right_min, right_max, full)

  -- Carry the clear window so path-glyph clear uses the identical range.
  ctx.clear_full = full
  ctx.clear_left_min = left_min
  ctx.clear_left_max = left_max
  ctx.clear_right_min = right_min
  ctx.clear_right_max = right_max
  ctx.clear_connector_min = connector_min
  ctx.clear_connector_max = connector_max

  -- Empty-source notice is a row-0 extmark. Clipped clears that include row 1
  -- (topline 1 is the empty-pane default) wipe it — repaint whenever the clear
  -- window covers that cell. When row 0 is outside the clear window the prior
  -- mark stays put (no leak, no wipe).
  if full or (left_min and left_min <= 1) then
    render_empty_source_notice(self.left_buf, self.extmark_ns, self.left)
  end
  if full or (right_min and right_min <= 1) then
    render_empty_source_notice(self.right_buf, self.extmark_ns, self.right)
  end
end

local function render_pane_backgrounds(self, ctx)
  -- Apply highlights to left and right buffers (pane-wide backgrounds).
  -- Bound the meta walk to the padded viewport; paint each side only when
  -- that side's row is inside its own clear window (left-visible OR
  -- right-visible can pull a meta into the loop while the opposite index
  -- sits far outside the clear range on a large one-sided block).
  local meta_list = self.view.line_meta
  for_each_meta_index(ctx, function(idx)
    local meta = meta_list[idx]
    if not meta or not ctx.meta_visible(meta) then
      return
    end
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

    -- IMPORTANT: do NOT apply a full-line background on change lines.
    -- Range extmarks below own those rows so intra-line emphasis can override
    -- the base change background on both panes.
    local skip_left_line_hl = (meta.kind == "change" and not meta.filler_left)
    if final_left_hl and meta.left_index and not skip_left_line_hl
        and ctx.left_row_visible(meta.left_index) then
      local left_row = meta.left_index - 1
      vim.api.nvim_buf_set_extmark(self.left_buf, self.extmark_ns, left_row, 0, {
        line_hl_group = final_left_hl,
        hl_mode = "combine",
      })
    end
    local skip_right_line_hl = (meta.kind == "change" and not meta.filler_right)
      -- Shared merge result: line highlights beat range highlights regardless
      -- of priority, so an add line_hl would override the other pair's change
      -- band. Add rows there rely on the low-priority range mark instead.
      or (self.shared_result_right and meta.kind == "add" and not meta.filler_right)
    local skip_right_context_hl = self.suppress_right_context_highlights == true and meta.kind == "context"
    if final_right_hl and meta.right_index and not skip_right_line_hl and not skip_right_context_hl
        and ctx.right_row_visible(meta.right_index) then
      local right_row = meta.right_index - 1
      vim.api.nvim_buf_set_extmark(self.right_buf, self.extmark_ns, right_row, 0, {
        line_hl_group = final_right_hl,
        hl_mode = "combine",
      })
    end
    -- line_hl/range marks never cover the sign column, which punches a
    -- notch into band rows whenever diagnostics make it visible. Fill it
    -- with a low-priority blank sign carrying the band color. Rows that
    -- carry a diagnostic mirror its glyph at high priority with a combined
    -- highlight (diagnostic fg over band bg) — the diagnostic sign's own
    -- highlight is fg-only, which left the glyph cell on the plain
    -- sign-column background inside a band.
    if ctx.right_has_signs and meta.right_index and not meta.filler_right and meta.kind ~= "context"
        and ctx.right_row_visible(meta.right_index) then
      local band = meta.kind == "add" and "Add" or "Change"
      local severity = meta.right_line and ctx.right_diag_severity[meta.right_line]
      if severity then
        local suffix = ({ "Error", "Warn", "Info", "Hint" })[severity] or "Error"
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, meta.right_index - 1, 0, {
          sign_text = ctx.diag_sign_text[severity] or "!",
          sign_hl_group = "DiffBanditSign" .. band .. suffix,
          priority = 100,
        })
      else
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, meta.right_index - 1, 0, {
          sign_text = "  ",
          sign_hl_group = "DiffBanditSign" .. band,
          priority = 1,
        })
      end
    end
  end)
end

local function render_connector_backgrounds(self, ctx)
  -- Apply connector backgrounds and number-pane styling on the same compact
  -- rows as their owner buffers.
  --
  -- The connector window scrolls with the left pane, so connector buffer
  -- rows are left-row/screen space (viewport_solid / route projection use
  -- the same space). Never use line_meta indexes as connector buffer rows —
  -- fillers make meta index diverge from left_index and leave unpainted
  -- (dark) gaps inside solid change bands.
  --
  -- Connector Normal is already DiffBanditConnectorContext via winhl, so we
  -- do NOT paint Context on every row (a same-priority Context extmark can
  -- fight DiffBanditConnectorChange and leave the solid band looking like
  -- sparse route bars only). Solid rows get an explicit high-priority mark
  -- in render_route_backgrounds.

  local function paint_num_band(buf, row, hl, start_col, end_col)
    -- High priority so band fills beat the Normal:Context winhl on gutters
    -- and any same-ns base marks. end_col -1 → line-end via end_row+1.
    if end_col == -1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, row, start_col, {
        end_row = row + 1,
        end_col = 0,
        hl_group = hl,
        hl_eol = true,
        priority = 110,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, row, start_col, {
        end_row = row,
        end_col = end_col,
        hl_group = hl,
        priority = 110,
      })
    end
  end

  local function add_origin_core_underline(origin_row, row, meta)
    if meta.origin == "add" then
      if row < 0 or row >= ctx.connector_height then
        return
      end
      vim.api.nvim_buf_set_extmark(self.left_num_buf, self.linenum_ns, row, self:left_triangle_col(), {
        virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
      local right_index_at_row = ctx.right_topline + ((row + 1) - ctx.left_topline)
      if ctx.add_origin_row_has_transition[origin_row]
          and ctx.right_row_visible(right_index_at_row)
          and right_index_at_row <= #ctx.right_lines then
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.linenum_ns, right_index_at_row - 1, self:right_triangle_col(), {
          virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end
    end
  end

  local meta_list = self.view.line_meta
  for_each_meta_index(ctx, function(idx)
    local meta = meta_list[idx]
    if not meta then
      return
    end
    if meta.left_index and ctx.left_row_visible(meta.left_index) then
      local row = meta.left_index - 1

      local left_num_hl
      if meta.origin == "add" and not ctx.embedded_add_origin_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftUnderline"
      elseif meta.kind == "delete" then
        left_num_hl = "DiffBanditLineNumberLeftDelete"
      elseif ctx.change_number_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftChange"
      else
        left_num_hl = "DiffBanditLineNumberLeft"
      end

      vim.api.nvim_buf_add_highlight(self.left_num_buf, self.linenum_ns, left_num_hl, row,
        self:left_number_text_start_col(), self:left_number_text_end_col())
      if meta.kind == "delete" then
        -- The wedge/spacer column stays clear on delete rows EXCEPT when the
        -- row sits inside the chunk's solid overlap (an embedded delete row
        -- of a merged change block whose band shares this screen row with
        -- the right side): the band must run contiguously through it.
        -- Everywhere else the wedge alone marks the transition and the
        -- corridor carries route lines.
        local solid = ctx.solid_change_number_left_indexes[meta.left_index]
        local start_col = solid and 0 or self:left_number_text_start_col()
        local end_col = solid and -1 or self:left_number_text_end_col()
        paint_num_band(self.left_num_buf, row, "DiffBanditConnectorDelete", start_col, end_col)
      elseif ctx.change_number_left_indexes[meta.left_index] then
        -- The wedge/spacer column carries the band only on solid rows (the
        -- side-by-side overlap; wedges paint the transitions there). On
        -- non-overlapping band rows the corridor shows the route line, so
        -- the fill stops at the number text.
        local start_col = ctx.solid_change_number_left_indexes[meta.left_index] and 0 or self:left_number_text_start_col()
        local end_col = ctx.solid_change_number_left_indexes[meta.left_index] and -1 or self:left_number_text_end_col()
        paint_num_band(self.left_num_buf, row, "DiffBanditConnectorChange", start_col, end_col)
      end
      if not ctx.embedded_add_origin_left_indexes[meta.left_index] then
        add_origin_core_underline(meta.left_index, row, meta)
      end
    end

    if meta.right_index and ctx.right_row_visible(meta.right_index) then
      local row = meta.right_index - 1

      local is_delete_origin = meta.right_line and ctx.delete_origin_right_lines[meta.right_line] ~= nil
      local right_num_hl
      if is_delete_origin then
        right_num_hl = "DiffBanditLineNumberRightUnderline"
      elseif ctx.change_number_right_indexes[meta.right_index] then
        right_num_hl = "DiffBanditLineNumberRightChange"
      elseif meta.kind == "add" then
        right_num_hl = "DiffBanditLineNumberRightAdd"
      else
        right_num_hl = "DiffBanditLineNumberRight"
      end

      if is_delete_origin then
        -- "combine" keeps the number pane's own background (e.g. a change
        -- band) under the underline spacer so the origin underline decorates
        -- the row instead of punching a dark cell into it.
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.linenum_ns, row, self:right_triangle_col(), {
          virt_text = { { " ", "DiffBanditDeleteRightSeparatorConnector" } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end

      vim.api.nvim_buf_add_highlight(self.right_num_buf, self.linenum_ns, right_num_hl, row,
        self:right_number_text_start_col(), self:right_number_text_end_col())
      if ctx.change_number_right_indexes[meta.right_index] then
        -- Solid rows (side-by-side overlap) fill from the pane edge so the
        -- band flows through the wedge/spacer column; other band rows stop
        -- at the number text and leave the corridor to the route line.
        -- Delete-origin rows keep the full fill so the underline spacer
        -- combines over the band instead of a bare cell.
        local full_fill = ctx.solid_change_number_right_indexes[meta.right_index] or is_delete_origin
        local start_col = full_fill and 0 or self:right_number_text_start_col()
        local end_col = full_fill and -1 or self:right_number_text_end_col()
        paint_num_band(self.right_num_buf, row, "DiffBanditConnectorChange", start_col, end_col)
      elseif meta.kind == "add" then
        -- Mirror of the delete rule: embedded add rows inside the chunk's
        -- solid overlap carry the band through the wedge/spacer column.
        local solid = ctx.solid_change_number_right_indexes[meta.right_index]
        local start_col = solid and 0 or self:right_number_text_start_col()
        local end_col = solid and -1 or self:right_number_text_end_col()
        paint_num_band(self.right_num_buf, row, "DiffBanditConnectorAdd", start_col, end_col)
      end
    end
  end)
end

local function render_route_backgrounds(self, ctx)
  -- Apply route-owned backgrounds. Add/delete fill now belongs to the
  -- sidecar number panes; the connector core is reserved for routes.
  for _, p in ipairs(ctx.paths) do
    if p.kind == "add" and not p.embedded_in_change then
      local first = math.max(p.target_start_index or p.display_start_row, ctx.right_row_min)
      local last = math.min(p.target_end_index or p.display_end_row, ctx.right_row_max)
      for right_index = first, last do
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorAdd", right_index - 1,
          self:right_number_text_start_col(), self:right_number_text_end_col())
      end
    elseif p.kind == "delete" then
      local first = math.max(p.target_start_index or p.display_start_row, ctx.left_row_min)
      local last = math.min(p.target_end_index or p.display_end_row, ctx.left_row_max)
      for left_index = first, last do
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorDelete", left_index - 1,
          self:left_number_text_start_col(), self:left_number_text_end_col())
      end
    end
  end
  -- Solid change corridor: one multi-row hl_eol extmark per solid range
  -- (not one mark per row over the pad-extended window).
  local conn_lo = ctx.left_row_min or 1
  local conn_hi = math.min(ctx.left_row_max or ctx.connector_height, ctx.connector_height)
  for _, p in ipairs(ctx.route_paths) do
    if p.kind == "change" and p.viewport_solid_start and p.viewport_solid_end then
      local lo = math.max(p.viewport_solid_start, conn_lo)
      local hi = math.min(p.viewport_solid_end, conn_hi)
      if lo <= hi then
        pcall(vim.api.nvim_buf_set_extmark, self.connector_buf, self.ns, lo - 1, 0, {
          end_row = hi,
          end_col = 0,
          hl_group = "DiffBanditConnectorChange",
          hl_eol = true,
          priority = 120,
        })
      end
    end
  end
end

local function render_intraline_spans(self, ctx)
  -- Apply change/add-specific highlighting with intra-line spans
  self.changed_spans_cache = self.changed_spans_cache or {}
  local meta_list = self.view.line_meta
  for_each_meta_index(ctx, function(meta_idx)
    local meta = meta_list[meta_idx]
    if not meta then
      return
    end
    local is_change = meta.kind == "change" and meta.left_index and meta.right_index
    local not_filler = not meta.filler_left and not meta.filler_right
    -- Paint each side when THAT side is in its clip (independent scroll can
    -- put one counterpart outside the other pane's window).
    if is_change and not_filler and ctx.meta_visible(meta) then
      local left_line = self.left.lines and self.left.lines[meta.left_line] or nil
      local right_line = self.right.lines and self.right.lines[meta.right_line] or nil
      if left_line and right_line then
        local spans = self.changed_spans_cache[meta_idx]
        if not spans then
          -- Smart-align hunks carry block-scoped emphasis spans computed by
          -- the IntelliJ word engine (one matching per change block); rows
          -- without them fall back to the per-row-pair comparison.
          local hunk = meta.chunk and self.hunks and self.hunks[meta.chunk]
          local inner = hunk and hunk.inner_spans
          if inner then
            spans = {
              left = inner.left[meta.left_line] or {},
              right_changes = inner.right[meta.right_line] or {},
              add_start = inner.add_start[meta.right_line],
              right_len = #right_line,
            }
          else
            spans = diff_mod.changed_spans(left_line, right_line)
          end
          self.changed_spans_cache[meta_idx] = spans
        end
        local row_l = meta.left_index - 1
        local row_r = meta.right_index - 1
        local paint_left = ctx.left_row_visible(meta.left_index)
        local paint_right = ctx.right_row_visible(meta.right_index)

        if paint_left then
          pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, 0, {
            hl_group = "DiffBanditChangeLeft",
            end_row = row_l,
            end_col = #left_line,
            hl_mode = "combine",
            priority = 2500,
          })
          pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, #left_line, {
            hl_group = "DiffBanditChangeLeft",
            end_row = row_l + 1,
            end_col = 0,
            hl_eol = true,
            hl_mode = "combine",
            priority = 2500,
          })
          for _, sp in ipairs(spans.left or {}) do
            local s, e = sp[1] - 1, sp[2]
            pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, s, {
              end_row = row_l,
              end_col = e,
              hl_group = "DiffBanditChangeEmphasis",
              hl_mode = "combine",
              priority = 8000,
            })
          end
        end

        if paint_right then
          local right_line_len = spans.right_len or #right_line
          local has_change = spans.right_changes and #spans.right_changes > 0

          -- Change (blue) part followed by added suffix (green)
          local add_start = spans.add_start and (spans.add_start - 1) or right_line_len
          add_start = math.max(0, math.min(add_start, right_line_len))

          local blue_end = math.min(add_start, right_line_len)
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
            end_row = row_r,
            end_col = right_line_len,
            hl_group = "DiffBanditChangeRight",
            hl_mode = "combine",
            priority = 2500,
          })
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, right_line_len, {
            end_row = row_r + 1,
            end_col = 0,
            hl_group = "DiffBanditChangeRight",
            hl_eol = true,
            hl_mode = "combine",
            priority = 2500,
          })
          if has_change then
            -- Word emphasis only within the blue change span
            local emph_hl = "DiffBanditChangeEmphasis"
            for _, sp in ipairs(spans.right_changes or {}) do
              local s = sp[1] - 1
              local e = math.min(sp[2], blue_end)
              if s < e then
                pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, s, {
                  end_row = row_r,
                  end_col = e,
                  hl_group = emph_hl,
                  hl_mode = ctx.right_text_hl_mode,
                  priority = 8000,
                })
              end
            end
          end

          -- Added suffix (green): from add_start to end-of-line, extend to window edge
          if spans.add_start and add_start < right_line_len then
            if self.shared_result_right then
              -- The shared merge result pane reads as change + inner-change
              -- emphasis: appended text is emphasized instead of add-colored
              -- so green marks never fight the other pair's change diff.
              pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, add_start, {
                end_row = row_r,
                end_col = right_line_len,
                hl_group = "DiffBanditChangeEmphasis",
                hl_mode = ctx.right_text_hl_mode,
                priority = 8000,
              })
            else
              local add_hl = "DiffBanditAdd"
              pcall(vim.api.nvim_buf_add_highlight, self.right_buf, self.ns, add_hl, row_r, add_start, right_line_len)
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
    elseif meta.kind == "add" and meta.right_index and not meta.filler_right
        and ctx.right_row_visible(meta.right_index) then
      local row_r = meta.right_index - 1
      local line_content = self.right.lines and self.right.lines[meta.right_line] or ""
      local line_len = #line_content
      local is_embedded_terminal = ctx.embedded_add_terminal_right_indexes[meta.right_index] == true
      if is_embedded_terminal then
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          line_hl_group = "DiffBanditChangeRight",
          hl_mode = "combine",
          priority = 2400,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          end_row = row_r,
          end_col = line_len,
          hl_group = "DiffBanditAdd",
          hl_mode = ctx.right_text_hl_mode,
          priority = 7000,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, line_len, {
          end_row = row_r + 1,
          end_col = 0,
          hl_group = "DiffBanditChangeRight",
          hl_eol = true,
          hl_mode = "combine",
          priority = 6500,
        })
        local win_width = vim.api.nvim_win_get_width(self.right_win)
        local text_width = vim.fn.strdisplaywidth(line_content)
        local padding_len = math.max(0, win_width - text_width)
        if padding_len > 0 then
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, line_len, {
            virt_text = { { string.rep(" ", padding_len), "DiffBanditChangeRight" } },
            virt_text_pos = "inline",
            priority = 6500,
          })
        end
      elseif self.shared_result_right then
        -- Plain add rows are normally painted by the base line highlight, but
        -- in the shared merge result the add band must sit just below the
        -- change band (2500) so the other pair's change diff plus inner
        -- emphasis owns contested rows. That contest needs a range mark —
        -- line highlights win over range highlights regardless of priority.
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          end_row = row_r + 1,
          end_col = 0,
          hl_group = "DiffBanditAdd",
          hl_eol = true,
          hl_mode = ctx.right_text_hl_mode,
          priority = 2450,
        })
      end
    end
  end)
end

-- Native underline on an origin row's text, with virtual-text padding
-- extending the underline to the window edge.
local function underline_origin_row(self, buf, win, row, hl_group, hl_mode, priority)
  local line_content = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local text_len = #line_content
  if text_len > 0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, self.extmark_ns, row, 0, {
      end_col = text_len,
      hl_group = hl_group,
      hl_mode = hl_mode,
      priority = priority,
    })
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local win_width = vim.api.nvim_win_get_width(win)
  local text_width = vim.fn.strdisplaywidth(line_content)
  local padding_len = math.max(0, win_width - text_width)
  if padding_len > 0 then
    -- "combine" keeps the row's own trailing background (e.g. a change band's
    -- eol fill) underneath the underline padding instead of cutting it off.
    pcall(vim.api.nvim_buf_set_extmark, buf, self.extmark_ns, row, 0, {
      virt_text = { { string.rep(" ", padding_len), hl_group } },
      virt_text_win_col = text_width,
      hl_mode = "combine",
      priority = priority,
    })
  end
end

-- Separator lines on ORIGIN rows: add origins underline their left-pane row;
-- delete origins underline the right-pane row mapped through
-- delete_origin_right_lines. The connector-side underline is handled during
-- line-number rendering.
local function render_origin_underlines(self, ctx)
  local meta_list = self.view.line_meta
  for_each_meta_index(ctx, function(idx)
    local meta = meta_list[idx]
    if meta and meta.origin == "add" and not ctx.embedded_add_origin_left_indexes[meta.left_index]
        and ctx.left_row_visible(meta.left_index) then
      underline_origin_row(self, self.left_buf, self.left_win, meta.left_index - 1,
        "DiffBanditAddLeftSeparator", "combine", 100)
    end
  end)
  for right_line_num in pairs(ctx.delete_origin_right_lines) do
    local origin_row = right_line_num - 1
    if origin_row >= 0 and origin_row < #ctx.right_lines and ctx.right_row_visible(right_line_num) then
      underline_origin_row(self, self.right_buf, self.right_win, origin_row,
        "DiffBanditDeleteRightSeparator", ctx.right_text_hl_mode, 150)
    end
  end
end

local function render_route_glyphs(self, ctx)
  -- Render planned connector routes. Each planned route is limited to one
  -- source horizontal, one vertical rail, and one destination horizontal.
  -- Paint ONLY inside the same clip window path_ns is cleared over — otherwise
  -- offscreen vertical rails leak extmarks that accumulate forever (independent
  -- scroll can put an origin thousands of rows away).
  -- Clear window is computed once in clear_render_namespaces and carried on ctx
  -- so ns + path clears stay structurally identical.
  local full = ctx.clear_full
  local left_min = ctx.clear_left_min
  local left_max = ctx.clear_left_max
  local right_min = ctx.clear_right_min
  local right_max = ctx.clear_right_max
  local connector_min = ctx.clear_connector_min
  local connector_max = ctx.clear_connector_max
  clear_ns_range(self.left_num_buf, self.path_ns, left_min, left_max, full)
  clear_ns_range(self.connector_buf, self.path_ns, connector_min, connector_max, full)
  clear_ns_range(self.right_num_buf, self.path_ns, right_min, right_max, full)

  -- Paint only the current clip (not the union) — clear already covers the
  -- previous clip so stale marks are gone.
  local cur = ctx.paint_clip
  local paint_conn_min = cur.connector_min
  local paint_conn_max = cur.connector_max
  local paint_left_min, paint_left_max = cur.left_min, cur.left_max
  local paint_right_min, paint_right_max = cur.right_min, cur.right_max

  local function connector_row_paintable(row)
    return row ~= nil and row >= paint_conn_min and row <= paint_conn_max
  end

  local function render_core_underline(row, start_col, end_col, hl_group)
    if not connector_row_paintable(row) or end_col < start_col then
      return
    end
    start_col = math.max(0, start_col)
    end_col = math.min(self.connector_core_width - 1, end_col)
    if self.mirror_connector_sides then
      start_col, end_col = self.connector_core_width - 1 - end_col, self.connector_core_width - 1 - start_col
    end
    if end_col < start_col then
      return
    end
    -- "combine" keeps whatever background the core row already carries (a
    -- solid change band, most notably) underneath the underline run, so a
    -- crossing route decorates the band instead of cutting a gap into it.
    vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, start_col, {
      virt_text = { { string.rep(" ", end_col - start_col + 1), hl_group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end

  local function render_core_vertical(row, col, hl_group)
    if not connector_row_paintable(row) or col < 0 or col >= self.connector_core_width then
      return
    end
    if self.mirror_connector_sides then
      col = self.connector_core_width - 1 - col
    end
    vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, col, {
      virt_text = { { "│", hl_group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end

  local function render_change_wedge(side, row, glyph)
    if not connector_row_paintable(row) then
      return
    end
    glyph = self:display_glyph(glyph)
    if side == "left" then
      local left_index = row
      if left_index and left_index >= paint_left_min and left_index <= paint_left_max
          and left_index <= #ctx.left_lines then
        vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, left_index - 1, self:left_triangle_col(), {
          virt_text = { { glyph, "DiffBanditConnectorExpansionChange" } },
          virt_text_pos = "overlay",
        })
      end
    else
      local right_index = ctx.right_topline + (row - ctx.left_topline)
      if right_index >= paint_right_min and right_index <= paint_right_max
          and right_index <= #ctx.right_lines then
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, right_index - 1, self:right_triangle_col(), {
          virt_text = { { glyph, "DiffBanditConnectorExpansionChange" } },
          virt_text_pos = "overlay",
        })
      end
    end
  end

  for _, p in ipairs(ctx.route_paths) do
    if p.kind == "change" and p.viewport_change_edges then
      for _, edge in ipairs(p.viewport_change_edges) do
        render_change_wedge(edge.side, edge.row, edge.glyph)
      end
    end
    if p.kind == "change" and p.viewport_change_links then
      for _, link in ipairs(p.viewport_change_links) do
        if not link.overflow_hidden and link.from_visible then
          render_change_wedge(link.from_side, link.from_row, link.from_glyph)
        end
        if not link.overflow_hidden and link.to_visible then
          render_change_wedge(link.to_side, link.to_row, link.to_glyph)
        end

      end
    end
  end

  for _, p in ipairs(ctx.route_paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change and not p.overflow_hidden then
      local expansion_hl
      if p.kind == "add" then
        expansion_hl = "DiffBanditConnectorExpansionAdd"
        if (p.triangle_display_row or p.display_start_row) == p.origin_display_row
            or p.connect_tail_on_triangle_row then
          expansion_hl = "DiffBanditConnectorExpansionAddUnderline"
        end
      else
        expansion_hl = "DiffBanditConnectorExpansionDelete"
      end

      local glyph = p.triangle_glyph or ((p.kind == "add") and "◥" or "◤")
      glyph = self:display_glyph(glyph)
      if not p.hide_triangle then
        if p.kind == "add" and p.target_start_index
            and p.target_start_index >= paint_right_min and p.target_start_index <= paint_right_max then
          vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, p.target_start_index - 1, self:right_triangle_col(), {
            virt_text = { { glyph, expansion_hl } },
            virt_text_pos = "overlay",
          })
        elseif p.kind == "delete" and p.target_start_index
            and p.target_start_index >= paint_left_min and p.target_start_index <= paint_left_max then
          vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, p.target_start_index - 1, self:left_triangle_col(), {
            virt_text = { { glyph, expansion_hl } },
            virt_text_pos = "overlay",
          })
        end
      end
    end
  end

  for _, planned_route in ipairs(ctx.route_plan.routes or {}) do
    for _, segment in ipairs(planned_route.segments or {}) do
      if segment.type == "horizontal" then
        render_core_underline(segment.row, segment.start_col, segment.end_col, segment.kind)
      elseif segment.type == "vertical" then
        local seg_lo = math.max(segment.start_row, paint_conn_min)
        local seg_hi = math.min(segment.end_row, paint_conn_max)
        for row = seg_lo, seg_hi do
          render_core_vertical(row, segment.col, segment.kind)
        end
      end
    end
  end
end

function M.build_display_lines(session)
  return build_display_lines(session)
end

function M.render(session)
  local timing = perf_enabled(session)
  local t_total = timing and perf_now() or 0
  local stages = timing and {} or nil
  local function mark(name, t0)
    if stages then
      stages[name] = perf_ms(t0, perf_now())
    end
  end

  local t0 = timing and perf_now() or 0
  local ctx = build_render_context(session)
  mark("context", t0)
  session._last_route_plan_aborted = ctx.route_plan_aborted == true
  -- Viewport key from the toplines/heights this paint actually used — not live
  -- window state after set_lines, which can shift and create phantom keys.
  session._paint_viewport_key = ui.viewport_render_key(
    ctx.left_topline, ctx.right_topline,
    ctx.left_height, ctx.right_height, session.current_chunk)

  t0 = timing and perf_now() or 0
  if ctx.write_structural then
    -- Pure-scroll paints write no buffer text; skip modifiable thrash.
    set_buffer_options(session.left_buf, { modifiable = true })
    set_buffer_options(session.left_num_buf, { modifiable = true })
    set_buffer_options(session.right_buf, { modifiable = true })
    set_buffer_options(session.right_num_buf, { modifiable = true })
    set_buffer_options(session.connector_buf, { modifiable = true })
    render_number_panes(session, ctx)
  end
  apply_buffer_lines(session, ctx)
  mark("set_lines", t0)

  t0 = timing and perf_now() or 0
  clear_render_namespaces(session, ctx)
  mark("clear_ns", t0)

  t0 = timing and perf_now() or 0
  render_pane_backgrounds(session, ctx)
  render_connector_backgrounds(session, ctx)
  render_route_backgrounds(session, ctx)
  render_intraline_spans(session, ctx)
  render_origin_underlines(session, ctx)
  mark("paint_bg", t0)

  -- Active-chunk overlay: always clip to the paint window so a huge active
  -- hunk does not walk every meta row on scroll. Viewport-only paints skip
  -- cursor / gutter / header / overview chrome (navigation paths still do that).
  local viewport_only = not ctx.write_structural
  if session.current_chunk > 0 and type(session.highlight_active_chunk) == "function" then
    local chunk = session.view.chunks[session.current_chunk]
    if chunk then
      session:highlight_active_chunk(chunk, {
        clip = ctx.paint_clip,
        prev_clip = session.last_paint_clip,
        position_cursor = false,
        sync_gutters = not viewport_only,
        render_chrome = false,
      })
    end
  end

  t0 = timing and perf_now() or 0
  render_route_glyphs(session, ctx)
  mark("paint_routes", t0)

  -- One clip field for ns + path clears; commit after both have unioned with
  -- the previous frame so neither clear loses the prior range mid-render.
  session.last_paint_clip = ctx.paint_clip

  if not viewport_only then
    session:render_status_headers()
    -- Full render paints overviews immediately; cancel any armed CursorMoved debounce.
    ui.cancel_schedule_once(session, "overview_rerender_scheduled")
    session:render_overviews()
  end

  if stages then
    stages.total = perf_ms(t_total, perf_now())
    stages.write_structural = ctx.write_structural and 1 or 0
    session._last_render_perf = stages
    if perf_should_log(session) then
      local warn_ms = tonumber(perf_config(session).budget_warn_ms) or 8
      if stages.total >= warn_ms then
        vim.notify(string.format(
          "diffbandit render %.1fms (struct=%s context=%.1f set_lines=%.1f clear=%.1f bg=%.1f routes=%.1f)",
          stages.total,
          ctx.write_structural and "yes" or "no",
          stages.context or 0,
          stages.set_lines or 0,
          stages.clear_ns or 0,
          stages.paint_bg or 0,
          stages.paint_routes or 0
        ), vim.log.levels.DEBUG)
      end
    end
  end
end

return M
