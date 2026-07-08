local config_mod = require("diffbandit.config")
local M = {}

local ABSOLUTE_MIN_WIDTH = 3
local DEFAULT_MAX_WIDTH = 24
-- Canonical eight-rail visibility cap (owned here; connector.init re-exports).
M.MAX_VISIBLE_CONNECTOR_ROUTES = 8
local MAX_VISIBLE_CONNECTOR_ROUTES = M.MAX_VISIBLE_CONNECTOR_ROUTES

local function ui_config(config)
  return config_mod.section(config, "ui")
end

function M.minimum(config)
  local width = tonumber(ui_config(config).connector_width)
  if not width then
    width = ABSOLUTE_MIN_WIDTH
  end
  return math.max(ABSOLUTE_MIN_WIDTH, math.floor(width))
end

function M.maximum(config)
  local width = tonumber(ui_config(config).connector_max_width)
  if not width then
    width = DEFAULT_MAX_WIDTH
  end
  return math.max(M.minimum(config), math.floor(width))
end

-- Base width for a view's connector pane. view.connectors only ever holds
-- blank strings of exactly minimum width (view.build fills them; glyphs are
-- extmark overlays, never buffer text), so this is minimum(config) today.
-- The view parameter stays for API stability with callers and tests.
function M.base(view, config)
  local _ = view
  return M.minimum(config)
end


-- Pressure sizer: the live gutter width is computed ONCE per document (never
-- while scrolling -- resizing mid-scroll is jarring) and defines the
-- connector capacity; hiding is only acceptable once that capacity is
-- genuinely saturated (up to MAX_VISIBLE_CONNECTOR_ROUTES rails).
--
-- Two sweeps over the routed ranges, each widening by two columns per
-- overlapping route:
--   1. Document pressure: overlap of the ranges as aligned, plus one slack
--      lane -- the historical compact sizing.
--   2. Scroll pressure (when viewport_rows is known): any routes whose
--      anchors fit inside one viewport height can be stacked into parallel
--      full-height rails by scrolling the panes independently, and each
--      left-side underline forces every rail crossing it further outward
--      (about two columns per route). Expanding each range by
--      viewport_rows - 1 before the sweep counts that worst case, capped at
--      the eight-rail visibility limit.
-- The result never narrows below the document sizing, so sparse diffs keep
-- their compact gutter; only scroll-stackable regions widen. If a viewport
-- still cannot be planned at this width, routes hide with a recorded reason
-- rather than resizing.
function M.pressure_core_width(paths, minimum_width, maximum_width, viewport_rows)
  local doc_events = {}
  local left_events = {}
  local right_events = {}
  local scroll_reach = viewport_rows and math.max(0, math.floor(viewport_rows) - 1) or nil

  local function add_range(events, start_row, end_row, reach)
    if not start_row then
      return
    end
    end_row = end_row or start_row
    start_row = math.floor(start_row)
    end_row = math.floor(end_row)
    if end_row < start_row then
      start_row, end_row = end_row, start_row
    end
    reach = reach or 0
    events[start_row - reach] = (events[start_row - reach] or 0) + 1
    events[end_row + 1] = (events[end_row + 1] or 0) - 1
  end

  for _, path in ipairs(paths or {}) do
    if path.kind == "add" or path.kind == "delete" then
      if not path.embedded_in_change then
        add_range(doc_events, path.origin_display_row, path.triangle_display_row or path.display_start_row)
        if scroll_reach then
          if path.kind == "add" then
            add_range(left_events, path.origin_left_index, path.origin_left_index, scroll_reach)
            add_range(right_events, path.target_start_index, path.target_end_index, scroll_reach)
          else
            add_range(left_events, path.target_start_index, path.target_end_index, scroll_reach)
            add_range(right_events, path.origin_right_index, path.origin_right_index, scroll_reach)
          end
        end
      end
    elseif path.kind == "change" then
      -- Document pressure keeps its historical offset-only rule (aligned
      -- changes draw no rail in the aligned view), but ANY change grows
      -- rails once the panes scroll apart, so scroll pressure counts all.
      if path.offset then
        local start_row = math.min(path.start_left_index or path.display_start_row or 0,
          path.start_right_index or path.display_start_row or 0)
        local end_row = math.max(path.end_left_index or path.display_end_row or start_row,
          path.end_right_index or path.display_end_row or start_row)
        add_range(doc_events, start_row, end_row)
      end
      if scroll_reach then
        add_range(left_events, path.start_left_index, path.end_left_index, scroll_reach)
        add_range(right_events, path.start_right_index, path.end_right_index, scroll_reach)
      end
    end
  end

  local function max_overlap(events)
    local rows = {}
    for row in pairs(events) do
      rows[#rows + 1] = row
    end
    table.sort(rows)
    local active = 0
    local peak = 0
    for _, row in ipairs(rows) do
      active = active + events[row]
      peak = math.max(peak, active)
    end
    return peak
  end

  local doc_pressure = max_overlap(doc_events)
  if doc_pressure > 0 then
    doc_pressure = doc_pressure + 1
  end
  local scroll_pressure = math.min(
    math.max(max_overlap(left_events), max_overlap(right_events)),
    MAX_VISIBLE_CONNECTOR_ROUTES)
  local max_pressure = math.max(doc_pressure, scroll_pressure)

  local required_core = math.max(minimum_width, minimum_width + (max_pressure * 2))
  return math.min(maximum_width, required_core)
end

-- Adapts a plan solved at a narrower working width for rendering inside a
-- wider core: right- and both-side horizontals dock at the pane edge, so
-- their edge cells move out to the real core edge; everything else (rails,
-- left horizontals) is position-stable. Used by the live fallback when the
-- full-width search tree thrashes but a narrower width solves quickly --
-- extending into the virgin columns cannot create collisions.
function M.stretch_plan_to_core(plan, planned_width, core_width)
  if core_width <= planned_width then
    return plan
  end
  local planned_edge = planned_width - 1
  local core_edge = core_width - 1
  for _, route in ipairs(plan.routes or {}) do
    for _, segment in ipairs(route.segments or {}) do
      if segment.type == "horizontal"
          and (segment.side == "right" or segment.side == "both")
          and segment.end_col == planned_edge then
        if segment.start_col == planned_edge then
          segment.start_col = core_edge
        end
        segment.end_col = core_edge
      end
    end
  end
  return plan
end

return M
