-- connector_routes.lua - Pure functions for connector lane/bar/route computation
-- Extracted from session.lua for testability

local M = {}
local connector_width = require("diffbandit.connector.width")

local MAX_VISIBLE_CONNECTOR_ROUTES = connector_width.MAX_VISIBLE_CONNECTOR_ROUTES
M.MAX_VISIBLE_CONNECTOR_ROUTES = MAX_VISIBLE_CONNECTOR_ROUTES

-- Overlap margin for lane assignment: routes whose occupied ranges merely
-- touch (within one row) still take separate lanes. This buys visual
-- separation between adjacent rails at the cost of lane inflation, which
-- feeds gutter width and, in dense conflicts, the overflow cap.
local LANE_COLLISION_MARGIN = 1

-- Triangle glyphs by docking side. "below" means the wedge approaches its
-- target from below (the target sits above the origin). Right-side wedges
-- serve adds and right change endpoints; left-side wedges serve deletes and
-- left change endpoints.
local TRIANGLE = {
  right = { above = "◥", below = "◢" },
  left = { above = "◤", below = "◣" },
}

local function triangle_glyph(side, from_below)
  local set = TRIANGLE[side]
  return from_below and set.below or set.above
end

local function origin_row_for_path(p)
  return p.origin_display_row or p.top or p.display_start_row or p.start_row or 0
end

local function triangle_row_for_path(p)
  return p.triangle_display_row or p.display_start_row or p.start_row or origin_row_for_path(p)
end

-- Visits every row a change path touches in the viewport projection: link
-- endpoints, optionally their underline rows, and edge wedge rows. Filtering
-- and folding stay with the caller (rows may be nil; none of the call sites
-- are order-sensitive).
--   opts.visible_only: only from/to endpoints whose side is visible
--   opts.underlines:   also visit link.underline_row for visible endpoints
local function visit_change_rows(path, opts, fn)
  opts = opts or {}
  for _, link in ipairs(path.viewport_change_links or {}) do
    if not opts.visible_only or link.from_visible then
      fn(link.from_row)
      if opts.underlines then
        fn(link.underline_row)
      end
    end
    if not opts.visible_only or link.to_visible then
      fn(link.to_row)
      if opts.underlines then
        fn(link.underline_row)
      end
    end
  end
  for _, edge in ipairs(path.viewport_change_edges or {}) do
    fn(edge.row)
  end
end

local function sort_row_for_path(p)
  if p.kind == "change" then
    local sort_row
    visit_change_rows(p, { visible_only = true }, function(row)
      if not row then
        return
      end
      if p.lane_occupancy_start and row < p.lane_occupancy_start then
        return
      end
      if p.lane_occupancy_end and row > p.lane_occupancy_end then
        return
      end
      sort_row = sort_row and math.min(sort_row, row) or row
    end)
    if sort_row then
      return sort_row
    end
  end

  if p.lane_occupancy_start and p.lane_occupancy_end then
    local origin_row = origin_row_for_path(p)
    if origin_row < p.lane_occupancy_start or origin_row > p.lane_occupancy_end then
      return triangle_row_for_path(p)
    end
  end

  return origin_row_for_path(p)
end

local function route_source_and_target_rows(p)
  if p.kind == "change" then
    local link = (p.viewport_change_links or {})[1]
    if link and link.from_row and link.to_row then
      return link.from_row, link.to_row
    end

    local edge = (p.viewport_change_edges or {})[1]
    if edge and edge.row then
      return edge.row, edge.row
    end
  end

  return origin_row_for_path(p), triangle_row_for_path(p)
end

local function route_direction(p)
  local source_row, target_row = route_source_and_target_rows(p)
  if not source_row or not target_row then
    return 0
  end
  if target_row > source_row then
    return 1
  elseif target_row < source_row then
    return -1
  end
  return 0
end

local function physical_right_priority(p)
  local source_row, target_row = route_source_and_target_rows(p)
  if not source_row or not target_row then
    return nil
  end

  if target_row > source_row then
    -- Downward routes: the upper source has rightmost priority.
    return -source_row
  elseif target_row < source_row then
    -- Upward routes: the lower source has rightmost priority.
    return source_row
  end

  return -source_row
end

local function lane_family(p)
  return (p.kind == "add") and "add" or "delete"
end

local function visible_endpoint_row_for_path(p)
  if (p.kind == "add" or p.kind == "delete") and not p.hide_triangle then
    return triangle_row_for_path(p)
  end

  if p.kind == "change" then
    local row
    visit_change_rows(p, { visible_only = true }, function(r)
      if r then
        row = row and math.max(row, r) or r
      end
    end)
    return row
  end

  return nil
end

-- Compute occupancy range for overlap detection
-- Returns: start_row, finish_row
local function occupancy_range(p)
  if p.lane_occupancy_start and p.lane_occupancy_end then
    return p.lane_occupancy_start, p.lane_occupancy_end
  end

  if p.kind == "change" then
    local start_row, finish_row
    visit_change_rows(p, nil, function(row)
      if not row then
        return
      end
      start_row = start_row and math.min(start_row, row) or row
      finish_row = finish_row and math.max(finish_row, row) or row
    end)

    if start_row and finish_row then
      return start_row, finish_row
    end
  end

  local origin_row = origin_row_for_path(p)
  local triangle_row = triangle_row_for_path(p)

  local has_vertical_bar = math.abs(triangle_row - origin_row) > 1

  local start_row = math.min(origin_row, triangle_row)
  local finish_row = start_row
  if has_vertical_bar then
    finish_row = math.max(origin_row, triangle_row)
  end

  if finish_row < start_row then
    finish_row = start_row
  end
  return start_row, finish_row
end

-- Path-space vertical bar span (origin/triangle geometry with tail and
-- hidden-triangle adjustments). Returns start_row, end_row; the span is
-- empty when end_row < start_row.
local function path_bar_span(p)
  local origin_row = origin_row_for_path(p)
  local triangle_row = triangle_row_for_path(p)
  local start_row = math.min(origin_row, triangle_row) + 1
  local end_row = math.max(origin_row, triangle_row) - 1
  if p.connect_tail_on_triangle_row and triangle_row < origin_row then
    start_row = triangle_row + 1
    end_row = origin_row
  elseif p.hide_triangle and triangle_row < origin_row then
    end_row = origin_row
  end
  return start_row, end_row
end

-- Whether a path draws a vertical bar at all: shared by route planning and
-- underline bookkeeping, which must agree on it.
local function path_has_vertical(p)
  local origin_row = origin_row_for_path(p)
  local triangle_row = triangle_row_for_path(p)
  return math.abs(triangle_row - origin_row) > 1
    or (p.connect_tail_on_triangle_row == true and triangle_row < origin_row)
end

-- Route-space rail span between source and target rows, extended to the
-- endpoint rows by the docking pipes. May return an empty span
-- (end_row < start_row); callers decide how to treat it.
local function rail_span(source_row, target_row, include_source_pipe, include_target_pipe)
  local start_row = math.min(source_row, target_row) + 1
  local end_row = math.max(source_row, target_row) - 1
  if include_source_pipe then
    if source_row < target_row then
      start_row = source_row
    else
      end_row = source_row
    end
  end
  if include_target_pipe then
    if target_row < source_row then
      start_row = target_row
    else
      end_row = target_row
    end
  end
  return start_row, end_row
end

-- Lane -> column formulas. Add-family rails grow leftward from the glyph
-- edge; delete-family rails grow rightward from just after the left number
-- pane (width 0 when sidecar number panes carry the rails themselves).
local function lane_col_base(lane, glyph_base_col, rail_spacing)
  local idx = math.max(0, lane - 1)
  return glyph_base_col - (idx * (rail_spacing + 1)) - 1
end

local function delete_lane_col_base(lane, left_number_width, rail_spacing)
  local idx = math.max(0, lane - 1)
  return left_number_width + 1 + (idx * (rail_spacing + 1))
end

-- Add and delete segments are mirror images: the origin anchors on the
-- opposite pane from the block, the line/index fields swap sides, and the
-- glyph family flips. The spec captures the mirrored parts; extra_fields
-- carries the historically asymmetric tail. Field NAMES are part of the
-- contract with projection, rendering, and tests -- do not symmetrize them.
local SEGMENT_SPEC = {
  add = {
    origin_side = "left",
    target_side = "right",
    fill_side = "right",
    line_field = "right_line",
    index_field = "right_index",
    origin_index_field = "left_index",
    glyph = function(approach)
      return triangle_glyph("right", approach == "from_below")
    end,
    extra_fields = function(path, origin_meta, start_row, end_row)
      path.start_right_line = start_row
      path.end_right_line = end_row
      path.origin_left_line = origin_meta and origin_meta.left_line or nil
      path.origin_left_index = origin_meta and origin_meta.left_index or nil
      path.origin_kind = origin_meta and origin_meta.kind or nil
      path.embedded_in_change = origin_meta and origin_meta.kind == "change" or false
    end,
  },
  delete = {
    origin_side = "right",
    target_side = "left",
    fill_side = "left",
    line_field = "left_line",
    index_field = "left_index",
    origin_index_field = "right_index",
    -- NOTE: legacy asymmetry, preserved on purpose. Base (unprojected)
    -- deletes use the RIGHT-family ◥ for from-below, unlike projection
    -- (delete_glyph_for_target), which uses ◣. Normalizing this changes
    -- rendered wedges; keep verbatim.
    glyph = function(approach)
      return approach == "from_below" and "◥" or "◤"
    end,
    extra_fields = function(path, origin_meta, start_row, end_row)
      path.start_left_line = start_row
      path.end_left_line = end_row
      path.origin_left_line = origin_meta and origin_meta.left_line or nil
      path.origin_right_line = origin_meta and origin_meta.right_line or nil
      path.origin_right_index = origin_meta and origin_meta.right_index or nil
    end,
  },
}

local function build_paths(chunks, line_meta)
  local paths = {}

  local current_chunk_index = nil

  local function push_segment(seg_kind, seg_start_idx, seg_end_idx)
    local spec = SEGMENT_SPEC[seg_kind]
    local start_meta = line_meta[seg_start_idx]
    local end_meta = line_meta[seg_end_idx]
    if not spec or not start_meta or not end_meta then
      return
    end

    local origin_meta = (seg_start_idx > 1) and line_meta[seg_start_idx - 1] or nil
    local start_row = start_meta[spec.line_field]
    local end_row = end_meta[spec.line_field]
    if not start_row or not end_row then
      return
    end

    local visual_origin = origin_meta and origin_meta[spec.origin_index_field] or nil
    local visual_start = start_meta[spec.index_field] or seg_start_idx
    local visual_end = end_meta[spec.index_field] or seg_end_idx
    -- A hunk at the very first display row (or one whose preceding row has
    -- no counterpart on the origin side) has no anchor line above it.
    -- Anchor on the block's own first row so the path still projects and
    -- routes; origin trimmings are skipped via the flag.
    local synthetic_origin = false
    if not visual_origin then
      visual_origin = visual_start
      synthetic_origin = true
    end
    local approach = "same_row"
    if visual_origin < visual_start then
      approach = "from_above"
    elseif visual_origin > visual_start then
      approach = "from_below"
    end

    local path = {
      kind = seg_kind,
      chunk = current_chunk_index,
      top = visual_origin,
      origin_side = spec.origin_side,
      target_side = spec.target_side,
      origin_display_row = visual_origin,
      meta_start_row = seg_start_idx,
      meta_end_row = seg_end_idx,
      display_start_row = visual_start,
      display_end_row = visual_end,
      block_display_start = visual_start,
      block_display_end = visual_end,
      triangle_display_row = visual_start,
      approach = approach,
      synthetic_origin = synthetic_origin,
      triangle_glyph = spec.glyph(approach),
      fill_side = spec.fill_side,
      start_row = start_row,
      end_row = end_row,
      lane = 0,
      target_start_index = start_meta[spec.index_field],
      target_end_index = end_meta[spec.index_field],
    }
    spec.extra_fields(path, origin_meta, start_row, end_row)
    paths[#paths + 1] = path
  end

  for _, chunk in ipairs(chunks) do
    current_chunk_index = chunk.index

    -- Build add/delete paths from contiguous segments regardless of chunk.type
    local i = chunk.display_start
    while i <= chunk.display_end do
      local m = line_meta[i]
      local k = m and m.kind
      if k == "add" or k == "delete" then
        local j = i
        while j + 1 <= chunk.display_end and line_meta[j + 1] and line_meta[j + 1].kind == k do
          j = j + 1
        end
        local before = #paths
        push_segment(k, i, j)
        -- Merged chunks (word-driven sub-blocks of one change block) are
        -- one logical change region: every interior add/delete segment is
        -- absorbed into the chunk's change band instead of routing standalone.
        if chunk.merged and #paths > before then
          paths[#paths].embedded_in_change = true
          paths[#paths].embedded_merged = true
        end
        i = j + 1
      else
        i = i + 1
      end
    end

    -- Change paths (for connector stroke rendering). These are display-row
    -- routes; the legacy start_row/end_row fields are kept for older tests.
    do
      local display_s, display_e = nil, nil
      local left_s, left_e = nil, nil
      local right_s, right_e = nil, nil
      local offset = false
      for j = chunk.display_start, chunk.display_end do
        local mj = line_meta[j]
        if mj and mj.kind == "change" then
          display_s = display_s and math.min(display_s, j) or j
          display_e = display_e and math.max(display_e, j) or j
          if mj.left_index then
            left_s = left_s and math.min(left_s, mj.left_index) or mj.left_index
            left_e = left_e and math.max(left_e, mj.left_index) or mj.left_index
          end
          if mj.right_index then
            right_s = right_s and math.min(right_s, mj.right_index) or mj.right_index
            right_e = right_e and math.max(right_e, mj.right_index) or mj.right_index
          end
          if not (mj.left_index and mj.right_index and mj.left_index == mj.right_index) then
            offset = true
          end
        end
      end
      if display_s and display_e then
        paths[#paths + 1] = {
          kind = "change",
          chunk = chunk.index,
          display_start_row = display_s,
          display_end_row = display_e,
          block_display_start = display_s,
          block_display_end = display_e,
          start_row = left_s or display_s,
          end_row = left_e or display_e,
          start_left_index = left_s,
          end_left_index = left_e,
          start_right_index = right_s,
          end_right_index = right_e,
          offset = offset,
        }
      end
    end
  end

  -- Embedded adds (extra right-side rows inside a change hunk) are absorbed
  -- into their chunk's change band instead of routing standalone. The merge
  -- must stay within the add's own chunk: with zero-context adjacent hunks an
  -- add's origin row can be the PREVIOUS chunk's change row, and merging
  -- across would fuse two independently-stageable chunks into one band.
  for _, p in ipairs(paths) do
    if (p.kind == "add" or p.kind == "delete") and p.embedded_in_change
        and (p.embedded_merged or (p.kind == "add" and p.origin_left_index)) then
      local merged = false
      for _, candidate in ipairs(paths) do
        if candidate.kind == "change" and candidate.chunk == p.chunk then
          -- Segments from merged chunks belong to their chunk's band by
          -- construction; origin-anchored embedded adds additionally require
          -- the origin row to sit inside the band.
          local in_band = p.embedded_merged
            or (candidate.start_left_index
              and candidate.end_left_index
              and p.origin_left_index >= candidate.start_left_index
              and p.origin_left_index <= candidate.end_left_index)
          if in_band then
            if p.kind == "add" then
              candidate.mixed_add = true
              candidate.end_right_index = math.max(candidate.end_right_index or 0, p.target_end_index or p.display_end_row or 0)
              candidate.start_right_index = math.min(candidate.start_right_index or candidate.end_right_index, p.target_start_index or p.display_start_row)
            else
              candidate.mixed_delete = true
              candidate.end_left_index = math.max(candidate.end_left_index or 0, p.target_end_index or p.display_end_row or 0)
              candidate.start_left_index = math.min(candidate.start_left_index or candidate.end_left_index, p.target_start_index or p.display_start_row)
              candidate.start_row = candidate.start_left_index or candidate.start_row
              candidate.end_row = candidate.end_left_index or candidate.end_row
            end
            if p.embedded_merged then
              candidate.display_start_row = math.min(candidate.display_start_row or p.display_start_row, p.display_start_row)
              candidate.display_end_row = math.max(candidate.display_end_row or p.display_end_row, p.display_end_row)
            else
              candidate.display_start_row = math.min(candidate.display_start_row or candidate.start_left_index, candidate.start_right_index or p.display_start_row)
              candidate.display_end_row = math.max(candidate.display_end_row or candidate.end_left_index, candidate.end_right_index or p.display_end_row)
            end
            candidate.block_display_start = candidate.display_start_row
            candidate.block_display_end = candidate.display_end_row
            merged = true
            break
          end
        end
      end
      -- No same-chunk change band absorbed this segment: route it normally
      -- instead of leaving it flagged, which would drop it entirely
      -- (add_basic_plan_route skips embedded paths).
      if not merged then
        p.embedded_in_change = false
      end
    end
  end

  return paths
end

-- Assign lanes to paths based on overlap detection
-- Mutates paths in place, returns max_lane
local function assign_lanes(paths)
  local use_projected_intervals = false
  local has_change_path = false
  for idx, p in ipairs(paths) do
    p.lane_order = idx
    if p.route_group ~= nil then
      use_projected_intervals = true
    end
    if p.kind == "change" then
      has_change_path = true
    end
  end
  local use_spacer_lanes = use_projected_intervals and #paths >= 5

  local function ranges_overlap(start_a, end_a, start_b, end_b, margin)
    margin = margin or 0
    return start_a <= end_b + margin and end_a + margin >= start_b
  end

  -- Sort by occupied range so viewport-projected routes are lane-assigned
  -- from their actual on-screen geometry, not only from their source hunk row.
  table.sort(paths, function(a, b)
    if lane_family(a) == lane_family(b) then
      local as, ae = occupancy_range(a)
      local bs, be = occupancy_range(b)
      if ranges_overlap(as, ae, bs, be, LANE_COLLISION_MARGIN) then
        local ap = physical_right_priority(a)
        local bp = physical_right_priority(b)
        local ad = route_direction(a)
        local bd = route_direction(b)
        if lane_family(a) ~= "add" and ad ~= bd then
          local av = visible_endpoint_row_for_path(a)
          local bv = visible_endpoint_row_for_path(b)
          local a_endpoint_inside_b = av and av >= bs and av <= be
          local b_endpoint_inside_a = bv and bv >= as and bv <= ae
          if a_endpoint_inside_b ~= b_endpoint_inside_a then
            return a_endpoint_inside_b
          end
          if a_endpoint_inside_b and b_endpoint_inside_a and av ~= bv then
            return av < bv
          end
        end
        if ap and bp and ap ~= bp and ad ~= 0 and ad == bd then
          if lane_family(a) == "add" then
            -- Add lane 1 is physically rightmost, so higher right-priority
            -- routes must be assigned first.
            return ap > bp
          end
          -- Delete/change lane numbers grow to the right. Assign lower-priority
          -- routes first so the route with rightmost priority is pushed outward
          -- by ordinary overlap detection instead of by diff-type rules.
          return ap < bp
        end

        if (a.lane_order or 0) ~= (b.lane_order or 0) then
          return (a.lane_order or 0) < (b.lane_order or 0)
        end
      end
    end

    local a_hidden = a.hide_triangle and 1 or 0
    local b_hidden = b.hide_triangle and 1 or 0
    if a_hidden ~= b_hidden then
      return a_hidden < b_hidden
    end

    if a.hide_triangle and b.hide_triangle then
      local a_origin = origin_row_for_path(a)
      local b_origin = origin_row_for_path(b)
      local a_triangle = triangle_row_for_path(a)
      local b_triangle = triangle_row_for_path(b)
      local a_upward = a_triangle < a_origin
      local b_upward = b_triangle < b_origin
      if a_upward and b_upward and a_origin ~= b_origin then
        return a_origin > b_origin
      end
    end

    local as = occupancy_range(a)
    local bs = occupancy_range(b)
    if as == bs then
      local ao = sort_row_for_path(a)
      local bo = sort_row_for_path(b)
      if ao == bo then
        return triangle_row_for_path(a) < triangle_row_for_path(b)
      end
      return ao < bo
    end
    return as < bs
  end)

  local lanes_add = {}
  local lanes_delete = {}
  local group_lanes_add = {}
  local group_lanes_delete = {}
  local max_lane = 0

  local function lane_has_overlap(lane_ranges, lane, start_row, end_row, group, margin)
    local ranges = lane_ranges[lane]
    if not ranges then
      return false
    end
    margin = margin or 0
    for _, range in ipairs(ranges) do
      if range.group ~= group
          and start_row <= range.finish_row + margin
          and end_row + margin >= range.start_row then
        return true
      end
    end
    return false
  end

  local function highest_overlapping_lane(lane_ranges, start_row, end_row, group, margin, direction)
    local highest_lane = 0
    margin = margin or 0
    for lane, ranges in pairs(lane_ranges) do
      for _, range in ipairs(ranges) do
        local same_direction = direction == nil
          or range.direction == nil
          or range.direction == direction
        local usable_reservation = not range.reservation
          or direction == nil
          or range.direction == nil
          or range.direction == direction
        if same_direction
            and usable_reservation
            and range.group ~= group
            and start_row <= range.finish_row + margin
            and end_row + margin >= range.start_row
            and lane > highest_lane then
          highest_lane = lane
        end
      end
    end
    return highest_lane
  end

  local function add_lane_range(lane_ranges, lane, start_row, end_row, group, direction, reservation)
    lane_ranges[lane] = lane_ranges[lane] or {}
    lane_ranges[lane][#lane_ranges[lane] + 1] = {
      start_row = start_row,
      finish_row = end_row,
      group = group,
      direction = direction,
      reservation = reservation == true,
    }
  end

  local function route_has_vertical_on_row(path, row)
    if not row then
      return false
    end

    if path.kind == "change" then
      for _, link in ipairs(path.viewport_change_links or {}) do
        if not link.no_vertical and link.from_row and link.to_row then
          local start_row = math.min(link.from_row, link.to_row) + 1
          local end_row = math.max(link.from_row, link.to_row) - 1
          if row >= start_row and row <= end_row then
            return true
          end
        end
      end
      return false
    end

    local start_row, end_row = path_bar_span(path)
    return row >= start_row and row <= end_row
  end

  local function promote_left_tail_crossings()
    -- Unlike endpoint_rows_for_path this deliberately skips underline rows:
    -- tail-crossing promotion only cares where wedges dock, not where their
    -- underlines run.
    local function change_endpoint_rows(path)
      local rows = {}
      if path.kind ~= "change" then
        return rows
      end
      visit_change_rows(path, { visible_only = true }, function(row)
        if row then
          rows[#rows + 1] = row
        end
      end)
      return rows
    end

    local changed = true
    while changed do
      changed = false
      for _, rail_path in ipairs(paths) do
        if rail_path.kind == "change" and lane_family(rail_path) ~= "add" and rail_path.lane then
          for _, tail_path in ipairs(paths) do
            if tail_path ~= rail_path
                and tail_path.kind == "delete"
                and tail_path.lane
                and not tail_path.hide_triangle then
              local tail_row = triangle_row_for_path(tail_path)
              if route_has_vertical_on_row(rail_path, tail_row) and rail_path.lane <= tail_path.lane then
                rail_path.lane = tail_path.lane + 1
                rail_path.collision_lane = rail_path.lane
                changed = true
              end
            end
          end
        end
        if rail_path.kind == "delete" and rail_path.lane == 1 then
          for _, endpoint_path in ipairs(paths) do
            if endpoint_path ~= rail_path and endpoint_path.kind == "change" and endpoint_path.lane then
              for _, endpoint_row in ipairs(change_endpoint_rows(endpoint_path)) do
                if route_has_vertical_on_row(rail_path, endpoint_row) then
                  -- Escalation constants: the inner delete rail hops past the
                  -- change's inner lane pair (1,2 -> 3), and the change
                  -- endpoint claims the lane just inside the eight-route cap
                  -- so its horizontals clear any compact conflict cluster.
                  -- These are deliberate worst-case jumps, not derived from
                  -- current occupancy: the fixed-point loop has no occupancy
                  -- ledger at this stage, so conservative hops guarantee the
                  -- crossing clears in one move instead of ping-ponging.
                  if rail_path.lane == 1 then
                    rail_path.lane = 3
                    rail_path.collision_lane = rail_path.lane
                    changed = true
                  end
                  local minimum_lane = MAX_VISIBLE_CONNECTOR_ROUTES - 1
                  if endpoint_path.lane < minimum_lane then
                    endpoint_path.lane = minimum_lane
                    endpoint_path.collision_lane = endpoint_path.lane
                    changed = true
                    break
                  end
                end
              end
            end
            if changed then
              break
            end
          end
        end
      end
    end
  end

  local function endpoint_rows_for_path(path)
    local rows = {}
    local seen = {}
    local function add_row(row)
      if row and not seen[row] then
        seen[row] = true
        rows[#rows + 1] = row
      end
    end

    if path.kind == "change" then
      visit_change_rows(path, { visible_only = true, underlines = true }, add_row)
      return rows
    end

    if path.kind == "delete" and not path.suppress_tail then
      add_row(triangle_row_for_path(path))
    end

    return rows
  end

  -- Returns true when crossing resolution converged within its pass budget.
  -- The inward move (horizontal drops just inside the crossing vertical) is
  -- load-bearing for convergence: gating it behind whole-range occupancy
  -- checks was tried and made this loop ping-pong outward on the dense
  -- fixture, inflating lanes before bailing. The pass cap is the safety
  -- net; a bail leaves lanes as-is and is reported via
  -- lane_resolution_bailed. Same-lane rail stacking is guarded separately
  -- by tests over compute_active_bars.
  local function resolve_left_endpoint_crossings()
    local changed = true
    local pass = 0
    while changed and pass < 20 do
      changed = false
      pass = pass + 1

      for _, horizontal_path in ipairs(paths) do
        if horizontal_path.lane
            and lane_family(horizontal_path) ~= "add"
            and not horizontal_path.hide_triangle then
          for _, row in ipairs(endpoint_rows_for_path(horizontal_path)) do
            for _, vertical_path in ipairs(paths) do
              if vertical_path ~= horizontal_path
                  and vertical_path.lane
                  and lane_family(vertical_path) ~= "add"
                  and route_has_vertical_on_row(vertical_path, row)
                  and vertical_path.lane <= horizontal_path.lane then
                local inner_lane = vertical_path.lane - 1
                if inner_lane >= 1 then
                  horizontal_path.lane = inner_lane
                  horizontal_path.collision_lane = inner_lane
                else
                  vertical_path.lane = horizontal_path.lane + 1
                  vertical_path.collision_lane = vertical_path.lane
                end
                changed = true
              end
            end
          end
        end
      end
    end
    return not changed
  end

  -- Assign lanes so later paths go to OUTER lanes (further from triangle)
  for _, p in ipairs(paths) do
    if p.kind == "add" or p.kind == "delete" or p.kind == "change" then
      local occupy_start, occupy_end = occupancy_range(p)

      local lanes = (p.kind == "add") and lanes_add or lanes_delete
      local group_lanes = (p.kind == "add") and group_lanes_add or group_lanes_delete
      local group = p.route_group
      local direction = route_direction(p)

      local assigned_lane = group and group_lanes[group] or nil
      if not assigned_lane then
        if use_projected_intervals then
          assigned_lane = 1
          local collision_margin = has_change_path and LANE_COLLISION_MARGIN
            or ((p.hide_triangle and triangle_row_for_path(p) < origin_row_for_path(p)) and LANE_COLLISION_MARGIN or 0)
          while lane_has_overlap(lanes, assigned_lane, occupy_start, occupy_end, group, collision_margin) do
            assigned_lane = assigned_lane + 1
          end

          if has_change_path or p.hide_triangle then
            -- Nothing mutates `lanes` between these queries, so the
            -- same-direction result is computed once and reused for both
            -- the base bump and the spacer bump below.
            local same_direction_lane = highest_overlapping_lane(
              lanes,
              occupy_start,
              occupy_end,
              group,
              collision_margin,
              direction
            )
            if same_direction_lane > 0 and assigned_lane <= same_direction_lane then
              assigned_lane = same_direction_lane + 1
            end

            if use_spacer_lanes and has_change_path and p.kind ~= "add" and direction ~= 0 then
              local any_direction_lane = highest_overlapping_lane(
                lanes,
                occupy_start,
                occupy_end,
                group,
                collision_margin,
                nil
              )
              if any_direction_lane > 0 and assigned_lane <= any_direction_lane + 1 then
                assigned_lane = any_direction_lane + 2
              end

              if same_direction_lane > 0 and assigned_lane <= same_direction_lane + 1 then
                assigned_lane = same_direction_lane + 2
              end
            end
          end
        else
          local origin_row = origin_row_for_path(p)
          local highest_active_lane = 0
          for li = 1, #lanes do
            if (lanes[li] or 0) >= origin_row then
              if li > highest_active_lane then
                highest_active_lane = li
              end
            end
          end
          assigned_lane = highest_active_lane + 1
        end
        if group then
          group_lanes[group] = assigned_lane
        end
      end

      p.lane = assigned_lane
      if use_projected_intervals then
        p.collision_lane = assigned_lane
        add_lane_range(lanes, assigned_lane, occupy_start, occupy_end, group, direction, false)
      else
        lanes[assigned_lane] = math.max(lanes[assigned_lane] or occupy_end, occupy_end)
      end

      if p.lane > max_lane then
        max_lane = p.lane
      end
    end
  end

  promote_left_tail_crossings()
  if has_change_path then
    if not resolve_left_endpoint_crossings() then
      -- Observable by tests: lanes are left as-is rather than half-moved.
      paths.lane_resolution_bailed = true
    end
  end
  max_lane = 0
  for _, p in ipairs(paths) do
    if p.lane and p.lane > max_lane then
      max_lane = p.lane
    end
    if p.collision_lane and p.collision_lane > max_lane then
      max_lane = p.collision_lane
    end
  end

  return max_lane
end

-- Compute paths with lane assignments (convenience function)
function M.compute_paths(chunks, line_meta)
  local paths = build_paths(chunks, line_meta)
  assign_lanes(paths)
  return paths
end

M.assign_lanes = assign_lanes

-- Exported for testing: compute column position for a lane
M.lane_col = lane_col_base

function M.max_lane(paths)
  local max_lane = 0
  for _, p in ipairs(paths or {}) do
    if p.lane and p.lane > max_lane then
      max_lane = p.lane
    end
    if p.collision_lane and p.collision_lane > max_lane then
      max_lane = p.collision_lane
    end
  end
  return max_lane
end

function M.required_connector_core_width(max_lane, minimum_width)
  local width = math.max(minimum_width or 0, 0)
  if max_lane then
    max_lane = math.min(max_lane, MAX_VISIBLE_CONNECTOR_ROUTES)
  end
  if max_lane and max_lane >= 4 then
    -- Rails are spaced two cells apart. Keep a small buffer for opposing
    -- sidecar routes, but do not scale by three cells per lane; that
    -- over-widens the gutter and pushes left-side rails back toward each other.
    width = math.max(width, (max_lane * 2) + 8)
  end
  return width
end

local function endpoint_underline_row(side, row, glyph, viewport_topline)
  viewport_topline = viewport_topline or 1
  if side == "left" and glyph == "◤" then
    return math.max(viewport_topline, row - 1)
  end
  if side == "right" and glyph == "◥" then
    return math.max(viewport_topline, row - 1)
  end
  return row
end

local function add_route_cells(cells, row, start_col, end_col, kind, side)
  if not row or not start_col or not end_col then
    return
  end
  if end_col < start_col then
    return
  end
  cells[#cells + 1] = {
    type = "horizontal",
    row = row,
    start_col = start_col,
    end_col = end_col,
    kind = kind,
    side = side,
  }
end

local function add_vertical_cells(cells, start_row, end_row, col, kind)
  if not start_row or not end_row or not col then
    return
  end
  if end_row < start_row then
    return
  end
  cells[#cells + 1] = {
    type = "vertical",
    start_row = start_row,
    end_row = end_row,
    col = col,
    kind = kind,
  }
end

local function route_edge_col(side, connector_core_width)
  if side == "right" then
    return connector_core_width - 1
  end
  return 0
end

local function route_preferred_columns(route, connector_core_width)
  local cols = {}
  local min_col = 0
  local max_col = connector_core_width > 2 and connector_core_width - 2 or connector_core_width - 1
  local has_vertical_span = math.abs((route.source_row or 0) - (route.target_row or 0)) > 1
    or route.include_source_pipe == true
    or route.include_target_pipe == true
  if has_vertical_span
      and ((route.source_visible ~= false and route.suppress_source ~= true and route.source_side == "left")
        or (route.target_visible ~= false and route.suppress_target ~= true and route.target_side == "left"))
      and min_col + 1 <= max_col then
    min_col = min_col + 1
  end
  if route.avoid_change_inner_rail and min_col + 1 <= max_col then
    min_col = min_col + 1
  end
  if max_col < min_col then
    return cols
  end

  for col = min_col, max_col do
    cols[#cols + 1] = col
  end

  if route.shared_visible_endpoint
      and route.direction > 0
      and route.source_side == "right"
      and route.target_side == "left" then
    local reversed = {}
    for index = #cols, 1, -1 do
      reversed[#reversed + 1] = cols[index]
    end
    return reversed
  end

  return cols
end

local function route_priority(a, b)
  if a.direction ~= b.direction then
    if a.direction == 0 then
      return false
    end
    if b.direction == 0 then
      return true
    end
    return a.direction < b.direction
  end

  local a_hidden_endpoints = ((a.source_visible == false) and 1 or 0)
    + ((a.target_visible == false) and 1 or 0)
  local b_hidden_endpoints = ((b.source_visible == false) and 1 or 0)
    + ((b.target_visible == false) and 1 or 0)
  if a_hidden_endpoints ~= b_hidden_endpoints then
    return a_hidden_endpoints < b_hidden_endpoints
  end

  if a.direction < 0 then
    -- Upward routes dock from the top edge. This keeps the rail order stable
    -- as a constant upward scroll eventually clips each route at the top.
    local a_top = math.min(a.source_row, a.target_row)
    local b_top = math.min(b.source_row, b.target_row)
    if a_top ~= b_top then
      return a_top < b_top
    end
  elseif a.direction > 0 then
    -- Downward routes dock from the bottom edge for the matching reason.
    local a_bottom = math.max(a.source_row, a.target_row)
    local b_bottom = math.max(b.source_row, b.target_row)
    if a_bottom ~= b_bottom then
      return a_bottom > b_bottom
    end
  elseif a.source_row ~= b.source_row then
    return a.source_row < b.source_row
  end

  if a.target_row ~= b.target_row then
    return a.target_row < b.target_row
  end
  return (a.order or 0) < (b.order or 0)
end

local function route_vertical_span(route)
  if route.source_row == route.target_row or route.no_vertical then
    return nil, nil
  end

  local start_row, end_row = rail_span(route.source_row, route.target_row,
    route.include_source_pipe, route.include_target_pipe)
  if end_row < start_row then
    return nil, nil
  end
  return start_row, end_row
end

local function route_dock_row(route)
  if route.direction < 0 then
    return math.min(route.source_row, route.target_row)
  elseif route.direction > 0 then
    return math.max(route.source_row, route.target_row)
  end
  return route.source_row
end

local function route_offscreen_distance(route, viewport_topline, viewport_height)
  if not viewport_topline or not viewport_height then
    return 0
  end

  local viewport_end = viewport_topline + viewport_height - 1
  local function distance(row)
    if row < viewport_topline then
      return viewport_topline - row
    elseif row > viewport_end then
      return row - viewport_end
    end
    return 0
  end

  return math.max(distance(route.source_row), distance(route.target_row))
end

-- Single choke point for hiding a route. Every hide records why, so a
-- missing connector is always attributable: "overflow-cap" (more than
-- MAX_VISIBLE_CONNECTOR_ROUTES rails share a row), "width-exhausted" (no
-- collision-free placement exists at the current core width), or
-- "backtrack-bounded" (the solver hit its step budget before finding one).
-- overflow_hidden stays set for renderer/back-compat checks.
local function hide_route(route, reason)
  route.overflow_hidden = true
  route.hide_reason = reason
  if route.link then
    route.link.overflow_hidden = true
    route.link.hide_reason = reason
  elseif route.path then
    route.path.overflow_hidden = true
    route.path.hide_reason = reason
  end
end

local function prune_overflow_routes(routes, layout)
  local cap = layout.max_visible_connector_routes or MAX_VISIBLE_CONNECTOR_ROUTES
  if cap <= 0 then
    return {}, routes
  end

  local vertical_routes = {}
  for _, route in ipairs(routes) do
    route.overflow_hidden = nil
    route.hide_reason = nil
    local start_row, end_row = route_vertical_span(route)
    route.vertical_start_row = start_row
    route.vertical_end_row = end_row
    if start_row and end_row then
      vertical_routes[#vertical_routes + 1] = route
    end
  end

  if #vertical_routes <= cap then
    return routes, {}
  end

  local active_by_row = {}
  local active_count_by_row = {}
  for _, route in ipairs(vertical_routes) do
    for row = route.vertical_start_row, route.vertical_end_row do
      active_by_row[row] = active_by_row[row] or {}
      active_by_row[row][#active_by_row[row] + 1] = route
      active_count_by_row[row] = (active_count_by_row[row] or 0) + 1
    end
  end

  local hidden = {}
  local hidden_set = {}

  local function active_routes_on(row)
    local active = {}
    for _, route in ipairs(active_by_row[row] or {}) do
      if not hidden_set[route]
          and route.vertical_start_row <= row
          and route.vertical_end_row >= row then
        active[#active + 1] = route
      end
    end
    return active
  end

  -- Hiding priority: never the active chunk's route while any other
  -- candidate remains, then the route farthest offscreen (fully-visible
  -- routes have distance 0 and are hidden last), then routes with an
  -- invisible endpoint, then a deterministic dock-row tie-break.
  local function route_is_active_chunk(route)
    local active_chunk = layout.active_chunk_index
    return active_chunk ~= nil and route.path ~= nil and route.path.chunk == active_chunk
  end

  local function choose_hidden_route(active)
    table.sort(active, function(a, b)
      local a_active = route_is_active_chunk(a)
      local b_active = route_is_active_chunk(b)
      if a_active ~= b_active then
        return not a_active
      end

      local ad = route_offscreen_distance(a, layout.viewport_topline, layout.viewport_height)
      local bd = route_offscreen_distance(b, layout.viewport_topline, layout.viewport_height)
      if ad ~= bd then
        return ad > bd
      end

      local a_hidden = (a.source_visible == false or a.target_visible == false) and 1 or 0
      local b_hidden = (b.source_visible == false or b.target_visible == false) and 1 or 0
      if a_hidden ~= b_hidden then
        return a_hidden > b_hidden
      end

      local ar = route_dock_row(a)
      local br = route_dock_row(b)
      if ar ~= br then
        if a.direction < 0 and b.direction < 0 then
          return ar < br
        elseif a.direction > 0 and b.direction > 0 then
          return ar > br
        end
        return ar < br
      end

      return (a.order or 0) > (b.order or 0)
    end)
    return active[1]
  end

  while true do
    local overflow_row = nil
    local overflow_active = nil
    for _, route in ipairs(vertical_routes) do
      if not hidden_set[route] then
        for row = route.vertical_start_row, route.vertical_end_row do
          if (active_count_by_row[row] or 0) > cap then
            overflow_row = row
            overflow_active = active_routes_on(row)
            break
          end
        end
      end
      if overflow_row then
        break
      end
    end

    if not overflow_row then
      break
    end

    local route = choose_hidden_route(overflow_active)
    if not route then
      break
    end
    hidden_set[route] = true
    hidden[#hidden + 1] = route
    hide_route(route, "overflow-cap")
    for row = route.vertical_start_row, route.vertical_end_row do
      active_count_by_row[row] = math.max(0, (active_count_by_row[row] or 0) - 1)
    end
  end

  if #hidden == 0 then
    return routes, hidden
  end

  local visible = {}
  for _, route in ipairs(routes) do
    if not hidden_set[route] then
      visible[#visible + 1] = route
    end
  end

  return visible, hidden
end

local function route_kind_highlights(kind)
  if kind == "add" then
    return "DiffBanditAddLeftSeparatorConnector", "DiffBanditConnectorAddLine"
  elseif kind == "change" then
    return "DiffBanditChangeSeparatorConnector", "DiffBanditConnectorChangeLine"
  end
  return "DiffBanditDeleteRightSeparatorConnector", "DiffBanditConnectorDeleteLine"
end

local function build_route_segments(route, rail_col, connector_core_width)
  local segments = {}
  local h_hl, v_hl = route_kind_highlights(route.kind)
  local source_edge_col = route_edge_col(route.source_side, connector_core_width)
  local target_edge_col = route_edge_col(route.target_side, connector_core_width)

  local function add_horizontal_for_side(side, row)
    if not row then
      return
    end
    if side == "left" then
      add_route_cells(segments, row, 0, math.max(-1, rail_col - 1), h_hl, side)
    else
      add_route_cells(segments, row, math.min(connector_core_width, rail_col + 1), connector_core_width - 1, h_hl, side)
    end
  end

  -- A route with a visible, unsuppressed endpoint must never render as
  -- nothing at all: when rail placement leaves no room for its horizontals
  -- (rail column 0 with a left-side endpoint, or the mirrored right case)
  -- and no vertical was emitted, dock a single stub cell at the endpoint
  -- edge so the connector stays anchored on screen.
  local function with_visible_stub(segs)
    if #segs > 0 then
      return segs
    end
    if route.source_visible ~= false and route.suppress_source ~= true then
      add_route_cells(segs, route.source_row, source_edge_col, source_edge_col, h_hl, route.source_side)
    elseif route.target_visible ~= false and route.suppress_target ~= true then
      add_route_cells(segs, route.target_row, target_edge_col, target_edge_col, h_hl, route.target_side)
    end
    return segs
  end

  if route.source_row == route.target_row then
    if route.source_visible ~= false
        and route.target_visible ~= false
        and route.suppress_source ~= true
        and route.suppress_target ~= true then
      add_route_cells(
        segments,
        route.source_row,
        math.min(source_edge_col, target_edge_col),
        math.max(source_edge_col, target_edge_col),
        h_hl,
        "both"
      )
    else
      if route.source_visible ~= false and route.suppress_source ~= true then
        add_horizontal_for_side(route.source_side, route.source_row)
      end
      if route.target_visible ~= false and route.suppress_target ~= true then
        add_horizontal_for_side(route.target_side, route.target_row)
      end
    end
    return with_visible_stub(segments)
  end

  if route.source_visible ~= false and route.suppress_source ~= true then
    add_horizontal_for_side(route.source_side, route.source_row)
  end
  if route.target_visible ~= false and route.suppress_target ~= true then
    add_horizontal_for_side(route.target_side, route.target_row)
  end
  local extra_min_row = nil
  local extra_max_row = nil
  for _, extra in ipairs(route.extra_horizontals or {}) do
    local before = #segments
    add_horizontal_for_side(extra.side, extra.row)
    for i = before + 1, #segments do
      segments[i].continuation = true
    end
    if extra.row then
      extra_min_row = extra_min_row and math.min(extra_min_row, extra.row) or extra.row
      extra_max_row = extra_max_row and math.max(extra_max_row, extra.row) or extra.row
    end
  end

  -- Rail between the endpoints, extended by docking pipes, then stretched to
  -- reach any continuation horizontals (extras always win the final min/max,
  -- so merging them after the pipe adjustments is equivalent to the old
  -- extras-first accumulation).
  local vertical_start, vertical_end = rail_span(route.source_row, route.target_row,
    route.include_source_pipe, route.include_target_pipe)
  if extra_min_row then
    vertical_start = math.min(vertical_start, extra_min_row)
    vertical_end = math.max(vertical_end, extra_max_row)
  end
  add_vertical_cells(segments, vertical_start, vertical_end, rail_col, v_hl)

  return with_visible_stub(segments)
end

local function iter_segment_cells(segment, callback)
  if segment.type == "horizontal" then
    for col = segment.start_col, segment.end_col do
      callback(segment.row, col, "horizontal", segment.side)
    end
  elseif segment.type == "vertical" then
    for row = segment.start_row, segment.end_row do
      callback(row, segment.col, "vertical")
    end
  end
end

local function route_has_endpoint(route, side, row)
  return (route.source_side == side and route.source_row == row and route.source_visible ~= false)
    or (route.target_side == side and route.target_row == row and route.target_visible ~= false)
end

local function route_endpoint_on_row(route, row)
  return route_has_endpoint(route, "left", row) or route_has_endpoint(route, "right", row)
end

local function routes_can_share_cell(route, owner, row, cell_type, side)
  if owner == route or owner.group == route.group then
    return true
  end
  if cell_type ~= "horizontal" or not side then
    return false
  end
  -- Two routes may stack on a horizontal cell when both genuinely end
  -- there. Edge-docked endpoints always start at the pane edge, so two
  -- same-row endpoints can never be separated by widening -- sharing the
  -- cell (with deterministic paint order) is the only solvable layout.
  -- A "both"-side horizontal (same-row route spanning edge to edge) is
  -- itself pinned to its row, so it may stack with any route ending on
  -- that row on either side; rails merely passing through still collide.
  if side == "both" then
    return route_endpoint_on_row(route, row) and route_endpoint_on_row(owner, row)
  end
  return route_has_endpoint(route, side, row) and route_has_endpoint(owner, side, row)
end

local function route_collides(segments, occupied, route)
  for _, segment in ipairs(segments) do
    local hit = false
    local function check_cell(row, col, cell_type, side)
      local row_occupied = occupied[row]
      if row_occupied then
        for check_col = col - 1, col + 1 do
          local owner = row_occupied[check_col]
          if owner and not routes_can_share_cell(route, owner, row, cell_type, side) then
            return true
          end
        end
      end
      return false
    end

    iter_segment_cells(segment, function(row, col, cell_type, side)
      if hit then
        return
      end
      hit = check_cell(row, col, cell_type, side)
    end)
    if hit then
      return true
    end
  end
  return false
end

local function reserve_route_segments(segments, occupied, route, marks)
  for _, segment in ipairs(segments) do
    iter_segment_cells(segment, function(row, col)
      occupied[row] = occupied[row] or {}
      if occupied[row][col] == nil then
        occupied[row][col] = route
        if marks then
          marks[#marks + 1] = { row = row, col = col }
        end
      end
    end)
  end
end

local function unreserve_route_segments(occupied, marks)
  for i = #marks, 1, -1 do
    local mark = marks[i]
    if occupied[mark.row] then
      occupied[mark.row][mark.col] = nil
    end
  end
end

local function add_plan_route(routes, route)
  if not route.source_row or not route.target_row then
    return
  end
  route.direction = route.target_row > route.source_row and 1
    or (route.target_row < route.source_row and -1 or 0)
  route.order = #routes + 1
  routes[#routes + 1] = route
end

local function add_basic_plan_route(routes, path)
  if path.embedded_in_change then
    return
  end
  local origin_row = origin_row_for_path(path)
  local triangle_row = triangle_row_for_path(path)
  if not origin_row or not triangle_row then
    return
  end

  local direction = triangle_row > origin_row and 1
    or (triangle_row < origin_row and -1 or 0)
  local has_vertical = path_has_vertical(path)
  local target_row = triangle_row
  if has_vertical and direction ~= 0 then
    target_row = triangle_row - direction
    if path.connect_tail_on_triangle_row and triangle_row < origin_row then
      target_row = triangle_row
    end
  end
  if path.kind == "delete"
      and (path.target_side or "left") == "left"
      and path.triangle_glyph == "◤"
      and triangle_row == origin_row + 1 then
    target_row = math.max(1, triangle_row - 1)
  end
  if path.kind == "add"
      and (path.target_side or "right") == "right"
      and path.triangle_glyph == "◥"
      and triangle_row == origin_row + 1 then
    target_row = math.max(1, triangle_row - 1)
  end

  add_plan_route(routes, {
    kind = path.kind,
    path = path,
    group = path.route_group or path,
    source_side = path.origin_side or (path.kind == "delete" and "right" or "left"),
    source_row = origin_row,
    source_visible = path.origin_display_row ~= nil,
    target_side = path.target_side or (path.kind == "delete" and "left" or "right"),
    target_row = target_row,
    target_visible = path.hide_triangle ~= true,
    suppress_target = path.suppress_tail == true,
    include_source_pipe = (path.connect_tail_on_triangle_row == true and triangle_row < origin_row)
      or (path.suppress_tail == true and direction < 0),
    include_target_pipe = ((path.kind == "add" or path.kind == "delete") and has_vertical and direction > 0)
      or path.suppress_tail == true,
  })
end

local function add_change_plan_routes(routes, path, viewport_topline)
  for link_index, link in ipairs(path.viewport_change_links or {}) do
    link.overflow_hidden = nil

    local from_row = (link.from_visible and link.underline_row)
      or endpoint_underline_row(link.from_side, link.from_row, link.from_glyph, viewport_topline)
    local to_row = (link.to_visible and link.underline_row)
      or endpoint_underline_row(link.to_side, link.to_row, link.to_glyph, viewport_topline)
    local avoid_inner_rail = (link.from_visible and link.from_side == "left" and link.from_glyph == "◤")
      or (link.to_visible and link.to_side == "left" and link.to_glyph == "◤")

    add_plan_route(routes, {
      kind = "change",
      path = path,
      link = link,
      link_index = link_index,
      group = path.route_group or path,
      source_side = link.from_side,
      source_row = from_row,
      source_visible = link.from_visible,
      target_side = link.to_side,
      target_row = to_row,
      target_visible = link.to_visible,
      suppress_source = link.from_visible == false,
      suppress_target = link.to_visible == false,
      include_source_pipe = from_row ~= link.from_row,
      include_target_pipe = true,
      avoid_change_inner_rail = avoid_inner_rail,
      no_vertical = link.no_vertical == true,
    })
  end
end

function M.plan_routes(paths, layout)
  layout = layout or {}
  local connector_core_width = math.max(1, layout.connector_core_width or 1)
  local viewport_topline = layout.viewport_topline or 1
  local routes = {}

  for _, path in ipairs(paths or {}) do
    path.planned_routes = nil
    path.planned_segments = nil
    path.planned_rail_col = nil
    path.overflow_hidden = nil
    path.hide_reason = nil
    if path.kind == "add" or path.kind == "delete" then
      add_basic_plan_route(routes, path)
    elseif path.kind == "change" then
      add_change_plan_routes(routes, path, viewport_topline)
    end
  end

  local has_change_route = false
  for _, route in ipairs(routes) do
    if route.kind == "change" then
      has_change_route = true
      break
    end
  end
  if has_change_route then
    for _, route in ipairs(routes) do
      if route.kind ~= "change" and route.source_side == "right" and route.target_side == "left" then
        route.avoid_change_inner_rail = true
      end
    end
  end

  local same_row_add_origins = {}
  for _, route in ipairs(routes) do
    if route.kind == "add"
        and route.source_side == "left"
        and route.target_side == "right"
        and route.source_row == route.target_row then
      same_row_add_origins[route.group] = same_row_add_origins[route.group] or {}
      same_row_add_origins[route.group][route.source_row] = true
    end
  end
  for _, route in ipairs(routes) do
    if route.kind == "add"
        and route.source_side == "left"
        and route.target_side == "right"
        and route.target_row == route.source_row + 1
        and same_row_add_origins[route.group]
        and same_row_add_origins[route.group][route.source_row] then
      route.suppress_target = true
    end
  end

  local visible_endpoint_counts = {}
  local function endpoint_key(side, row)
    if not side or not row then
      return nil
    end
    return side .. "\0" .. tostring(row)
  end
  for _, route in ipairs(routes) do
    if route.source_visible ~= false then
      local key = endpoint_key(route.source_side, route.source_row)
      if key then
        visible_endpoint_counts[key] = (visible_endpoint_counts[key] or 0) + 1
      end
    end
    if route.target_visible ~= false then
      local key = endpoint_key(route.target_side, route.target_row)
      if key then
        visible_endpoint_counts[key] = (visible_endpoint_counts[key] or 0) + 1
      end
    end
  end
  for _, route in ipairs(routes) do
    local source_key = route.source_visible ~= false and endpoint_key(route.source_side, route.source_row) or nil
    local target_key = route.target_visible ~= false and endpoint_key(route.target_side, route.target_row) or nil
    route.shared_visible_endpoint = (source_key and (visible_endpoint_counts[source_key] or 0) > 1)
      or (target_key and (visible_endpoint_counts[target_key] or 0) > 1)
      or false
  end

  table.sort(routes, route_priority)
  local hidden_routes
  routes, hidden_routes = prune_overflow_routes(routes, {
    max_visible_connector_routes = layout.max_visible_connector_routes,
    viewport_topline = layout.viewport_topline,
    viewport_height = layout.viewport_height,
    active_chunk_index = layout.active_chunk_index,
  })

  local occupied = {}
  local max_used_col = 0
  local function clear_route_assignments()
    for _, route in ipairs(routes) do
      route.rail_col = nil
      route.segments = nil
    end
  end

  -- Optional wall-clock budget (layout.should_abort). When it trips, the
  -- solver degrades exactly like the backtrack bound: lookahead is disabled,
  -- the search stops, and unplaced routes are hidden with a recorded reason.
  -- Renders must never hang on a pathological projection.
  local planning_aborted = false
  local function check_abort()
    if planning_aborted then
      return true
    end
    if layout.should_abort and layout.should_abort() then
      planning_aborted = true
      return true
    end
    return false
  end

  -- Memoize segment builds and preferred columns per route for this solve
  -- only (greedy lookahead / backtrack re-request many times). Solve-local
  -- so cached plans do not retain the memo tables.
  local segments_memo = {}
  local function segments_for(route, col)
    local cache = segments_memo[route]
    if not cache then
      cache = {}
      segments_memo[route] = cache
    end
    local segments = cache[col]
    if not segments then
      segments = build_route_segments(route, col, connector_core_width)
      cache[col] = segments
    end
    return segments
  end

  local preferred_cols_memo = {}
  local function preferred_cols(route)
    local cols = preferred_cols_memo[route]
    if not cols then
      cols = route_preferred_columns(route, connector_core_width)
      preferred_cols_memo[route] = cols
    end
    return cols
  end

  -- O(n²) lookahead is only worth it when several routes compete; small sets
  -- and budget pressure use plain first-fit.
  local skip_lookahead = #routes <= 3

  local function remaining_routes_have_candidate(start_index)
    if skip_lookahead or check_abort() then
      -- Budget expired or lookahead disabled: greedy first-fit only.
      return true
    end
    for check_index = start_index, #routes do
      local check_route = routes[check_index]
      local has_candidate = false
      for _, check_col in ipairs(preferred_cols(check_route)) do
        local check_segments = segments_for(check_route, check_col)
        if not route_collides(check_segments, occupied, check_route) then
          has_candidate = true
          break
        end
      end
      if not has_candidate then
        return false
      end
    end
    return true
  end

  local function solve_greedy()
    occupied = {}
    clear_route_assignments()
    local unplaced = {}
    for route_index, route in ipairs(routes) do
      local placed = false
      for _, col in ipairs(preferred_cols(route)) do
        local segments = segments_for(route, col)
        if not route_collides(segments, occupied, route) then
          local marks = {}
          reserve_route_segments(segments, occupied, route, marks)
          local leaves_room = remaining_routes_have_candidate(route_index + 1)
          unreserve_route_segments(occupied, marks)
          if leaves_room then
            route.rail_col = col
            route.segments = segments
            reserve_route_segments(segments, occupied, route)
            placed = true
            break
          end
        end
      end
      if not placed then
        for _, col in ipairs(preferred_cols(route)) do
          local segments = segments_for(route, col)
          if not route_collides(segments, occupied, route) then
            route.rail_col = col
            route.segments = segments
            reserve_route_segments(segments, occupied, route)
            placed = true
            break
          end
        end
      end
      if not placed then
        unplaced[#unplaced + 1] = route
      end
    end
    return #unplaced == 0, unplaced
  end

  local backtrack_steps = 0
  local backtrack_limit = tonumber(layout.max_route_backtrack_steps) or 20000
  local function solve_route(index)
    backtrack_steps = backtrack_steps + 1
    if backtrack_steps > backtrack_limit or check_abort() then
      return false
    end
    if index > #routes then
      return true
    end

    local route = routes[index]
    for _, col in ipairs(preferred_cols(route)) do
      local segments = segments_for(route, col)
      if not route_collides(segments, occupied, route) then
        local marks = {}
        reserve_route_segments(segments, occupied, route, marks)
        route.rail_col = col
        route.segments = segments
        if solve_route(index + 1) then
          return true
        end
        route.rail_col = nil
        route.segments = nil
        unreserve_route_segments(occupied, marks)
      end
    end

    return false
  end

  local strategy = "greedy"
  local success = solve_greedy()
  if not success then
    strategy = "backtrack"
    occupied = {}
    clear_route_assignments()
    success = solve_route(1)
  end
  if not success then
    strategy = (backtrack_steps > backtrack_limit or planning_aborted) and "bounded-hidden" or "greedy-hidden"
    local _, unplaced_routes = solve_greedy()
    hidden_routes = hidden_routes or {}
    local unplaced_set = {}
    local reason = strategy == "bounded-hidden" and "backtrack-bounded" or "width-exhausted"
    for _, route in ipairs(unplaced_routes or {}) do
      hide_route(route, reason)
      hidden_routes[#hidden_routes + 1] = route
      unplaced_set[route] = true
      route.rail_col = nil
      route.segments = {}
    end
    -- Keep routes/hidden_routes disjoint (mirroring prune_overflow_routes)
    -- so force-hidden routes never reach the planned_routes aggregation.
    if next(unplaced_set) then
      local placed = {}
      for _, route in ipairs(routes) do
        if not unplaced_set[route] then
          placed[#placed + 1] = route
        end
      end
      routes = placed
    end
    success = #unplaced_routes == 0
  end

  for _, route in ipairs(routes) do
    max_used_col = math.max(max_used_col, route.rail_col or 0)
    local path = route.path
    path.planned_routes = path.planned_routes or {}
    path.planned_routes[#path.planned_routes + 1] = route
    path.planned_segments = path.planned_segments or {}
    for _, segment in ipairs(route.segments or {}) do
      path.planned_segments[#path.planned_segments + 1] = segment
    end
    path.planned_rail_col = path.planned_rail_col or route.rail_col
    if route.link then
      route.link.planned_rail_col = route.rail_col
      route.link.planned_segments = route.segments
    end
  end

  local hidden_summary = nil
  for _, route in ipairs(hidden_routes or {}) do
    hidden_summary = hidden_summary or {}
    local reason = route.hide_reason or "unknown"
    hidden_summary[reason] = (hidden_summary[reason] or 0) + 1
  end

  -- aborted only when the wall-clock abort actually left the solve incomplete
  -- (routes hidden/unplaced). A deadline trip mid-lookahead that still places
  -- every route is a complete plan and must not latch aborted.
  local aborted = planning_aborted and not success

  return {
    routes = routes,
    hidden_routes = hidden_routes or {},
    success = success,
    strategy = strategy,
    -- True when wall-clock should_abort caused incomplete placement (not
    -- merely backtrack-capped, and not a successful place-after-abort).
    -- Live paint must not cache aborted plans — they hide routes under time
    -- pressure and would otherwise replay forever at that viewport.
    aborted = aborted,
    max_used_col = max_used_col,
    occupied = occupied,
    hidden_summary = hidden_summary,
  }
end

-- Re-apply a plan's hide + planned_* fields onto the shared path objects.
-- plan_routes mutates paths in place; multi-plan cascades (near-width / width
-- search) may keep an earlier plan while a discarded solve left its flags on
-- the paths. Call after the final plan is selected so paint matches segments.
function M.apply_plan_path_state(paths, plan)
  for _, path in ipairs(paths or {}) do
    path.planned_routes = nil
    path.planned_segments = nil
    path.planned_rail_col = nil
    path.overflow_hidden = nil
    path.hide_reason = nil
    for _, link in ipairs(path.viewport_change_links or {}) do
      link.overflow_hidden = nil
      link.hide_reason = nil
      link.planned_rail_col = nil
      link.planned_segments = nil
    end
  end

  for _, route in ipairs((plan and plan.routes) or {}) do
    local path = route.path
    if path then
      path.planned_routes = path.planned_routes or {}
      path.planned_routes[#path.planned_routes + 1] = route
      path.planned_segments = path.planned_segments or {}
      for _, segment in ipairs(route.segments or {}) do
        path.planned_segments[#path.planned_segments + 1] = segment
      end
      path.planned_rail_col = path.planned_rail_col or route.rail_col
      if route.link then
        route.link.planned_rail_col = route.rail_col
        route.link.planned_segments = route.segments
        route.link.overflow_hidden = nil
        route.link.hide_reason = nil
      end
    end
  end

  for _, route in ipairs((plan and plan.hidden_routes) or {}) do
    hide_route(route, route.hide_reason or "unknown")
  end
end


function M.required_connector_core_width_for_paths(paths, minimum_width, max_width, layout)
  minimum_width = math.max(1, minimum_width or 1)
  max_width = math.max(minimum_width, max_width or 60)
  layout = layout or {}
  local function plan_at(width)
    -- Width search owns its own step cap here (not layout.max_route_backtrack_steps
    -- from the live 500-cap core solve). When no wall-clock deadline exists
    -- (route_plan_budget_ms = 0), the cap alone bounds the UI-thread work.
    local WIDTH_SEARCH_BACKTRACK = 20000
    return M.plan_routes(paths, {
      connector_core_width = width,
      viewport_topline = layout.viewport_topline,
      viewport_height = layout.viewport_height,
      max_visible_connector_routes = layout.max_visible_connector_routes,
      active_chunk_index = layout.active_chunk_index,
      should_abort = layout.should_abort,
      max_route_backtrack_steps = WIDTH_SEARCH_BACKTRACK,
    })
  end
  for width = minimum_width, max_width do
    local plan = plan_at(width)
    if plan.success then
      return width, plan
    end
    -- Wall-clock budget expired: stop probing widths and ship the bounded
    -- max-width plan below (hidden routes carry recorded reasons).
    if layout.should_abort and layout.should_abort() then
      break
    end
  end
  return max_width, plan_at(max_width)
end

-- ===========================================================================
-- LEGACY LANE LAYER (underlines / active bars)
-- Rail drawing is owned by plan_routes/segments. Lane numbers from
-- assign_lanes feed only a narrow set of live outputs from
-- compute_active_bars/compute_underlines -- delete_origin_right_lines
-- (right-pane origin underlines) and sorted path order. origin_glyph_cols,
-- origin_bar_cols, and underline_start_after are tests-only; do not build
-- new rendering on them. Candidate for a future connector/underlines.lua
-- extract once underlines fold into plan segments.
-- ===========================================================================

-- Compute active vertical bars per row
-- Returns: active_bars[row][lane] = path
function M.compute_active_bars(paths)
  local active_vertical_bars = {}

  local function add_active_bar(row, lane, path)
    active_vertical_bars[row] = active_vertical_bars[row] or {}
    local row_bars = active_vertical_bars[row]
    row_bars.__items = row_bars.__items or {}
    row_bars.__items[#row_bars.__items + 1] = {
      lane = lane,
      path = path,
    }

    -- Keep the historical lane lookup for focused tests and simple callers.
    if row_bars[lane] == nil then
      row_bars[lane] = path
    end
  end

  -- Collect origins sorted by row
  local sorted_origins = {}
  for _, p in ipairs(paths) do
    if (p.kind == "add" or p.kind == "delete")
        and p.origin_display_row
        and not p.embedded_in_change
        and not p.overflow_hidden then
      sorted_origins[#sorted_origins + 1] = { row = p.origin_display_row, lane = p.lane, path = p }
    end
  end
  table.sort(sorted_origins, function(a, b) return a.row < b.row end)

  -- For each path, create bars from origin+1 to triangle-1
  -- For additions: origin is on LEFT pane (use origin_left_line)
  -- For deletions: origin is on RIGHT pane (use origin_right_line)
  for _, origin in ipairs(sorted_origins) do
    local p = origin.path
    local bar_start, bar_end = path_bar_span(p)

    if bar_end >= bar_start then
      for row = bar_start, bar_end do
        add_active_bar(row, p.lane, p)
      end
    end
  end

  return active_vertical_bars
end

-- Compute underline endpoints and tail underlines
-- layout = { left_number_width, connector_core_width, rail_spacing }
-- Returns: { origin_bar_cols, origin_glyph_cols, origin_has_bar, tail_underlines }
function M.compute_underlines(paths, active_bars, layout)
  local left_number_width = layout.left_number_width
  local connector_core_width = layout.connector_core_width
  local rail_spacing = layout.rail_spacing or 1
  local sidecar_numbers = layout.sidecar_numbers or false
  local glyph_base_col = left_number_width + connector_core_width - 1

  local function lane_col(lane)
    return lane_col_base(lane, glyph_base_col, rail_spacing)
  end

  local function delete_lane_col(lane)
    -- Sidecar number panes carry the delete rails themselves, so the rail
    -- origin ignores the left number width (column 0 is the pane edge).
    return delete_lane_col_base(lane, sidecar_numbers and 0 or left_number_width, rail_spacing)
  end

  local function glyph_col_for_lane(lane)
    return lane_col(lane) + 1
  end

  local function compute_glyph_col_for_row(path, row)
    if path.kind == "delete" then
      return left_number_width
    end

    if not active_bars[row] then
      return glyph_col_for_lane(path.lane)
    end

    local rightmost_bar_col = nil
    for earlier_lane = 1, path.lane - 1 do
      if active_bars[row][earlier_lane] then
        local bar_col = lane_col(earlier_lane)
        if not rightmost_bar_col or bar_col > rightmost_bar_col then
          rightmost_bar_col = bar_col
        end
      end
    end

    if rightmost_bar_col then
      return rightmost_bar_col + 1
    else
      return glyph_col_for_lane(path.lane)
    end
  end

  local origin_glyph_cols = {}
  local origin_bar_cols = {}
  local origin_has_bar = {}
  local tail_underlines = {}
  -- Map right line numbers to delete origin info (for rendering underlines at correct display rows)
  local delete_origin_right_lines = {}

  local function add_tail_underline(row, info)
    local existing = tail_underlines[row]
    if not existing then
      info.__items = { info }
      tail_underlines[row] = info
      return
    end

    existing.__items = existing.__items or { existing }
    existing.__items[#existing.__items + 1] = info
  end

  local function bar_col_for_kind(kind, lane)
    if kind == "delete" then
      return delete_lane_col(lane)
    end
    return lane_col(lane)
  end

  local function bar_col_for_path(path, lane)
    return bar_col_for_kind(path and path.kind or "add", lane)
  end

  local function choose_outer_bar_col(kind, current_col, candidate_col)
    if kind == "delete" then
      return (candidate_col > current_col) and candidate_col or current_col
    end
    return (candidate_col < current_col) and candidate_col or current_col
  end

  local function outer_active_bar_col(row, kind, initial_col)
    local lanes_at_row = active_bars[row]
    if not lanes_at_row then
      return initial_col
    end
    local selected_col = initial_col
    if lanes_at_row.__items then
      for _, item in ipairs(lanes_at_row.__items) do
        selected_col = choose_outer_bar_col(kind, selected_col, bar_col_for_path(item.path, item.lane))
      end
      return selected_col
    end

    for bar_lane, _ in pairs(lanes_at_row) do
      if type(bar_lane) == "number" then
        selected_col = choose_outer_bar_col(kind, selected_col, bar_col_for_kind(kind, bar_lane))
      end
    end
    return selected_col
  end

  local function rightmost_delete_bar_col(row, initial_col)
    local lanes_at_row = active_bars[row]
    if not lanes_at_row then
      return initial_col
    end
    local selected_col = initial_col
    if lanes_at_row.__items then
      for _, item in ipairs(lanes_at_row.__items) do
        local bar_col = bar_col_for_path(item.path, item.lane)
        if not selected_col or bar_col > selected_col then
          selected_col = bar_col
        end
      end
      return selected_col
    end

    for bar_lane, _ in pairs(lanes_at_row) do
      if type(bar_lane) == "number" then
        local bar_col = delete_lane_col(bar_lane)
        if not selected_col or bar_col > selected_col then
          selected_col = bar_col
        end
      end
    end
    return selected_col
  end

  for _, p in ipairs(paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change and not p.overflow_hidden then
      local lane = math.max(1, p.lane)
      -- Synthetic origins anchor on the block's own first row; they have no
      -- real origin line to decorate with glyphs, bars, or underlines.
      if p.origin_display_row and not p.synthetic_origin then
        origin_glyph_cols[p.origin_display_row] = compute_glyph_col_for_row(p, p.triangle_display_row)

        local origin_row = origin_row_for_path(p)
        local triangle_row = triangle_row_for_path(p)
        local has_bar = path_has_vertical(p)
        origin_has_bar[p.origin_display_row] = has_bar

        -- Find the outermost active bar on the origin row.
        local outer_bar_col = outer_active_bar_col(origin_row, p.kind, bar_col_for_kind(p.kind, lane))
        local direction = triangle_row < origin_row and -1 or 1
        if has_bar then
          outer_bar_col = outer_active_bar_col(origin_row + direction, p.kind, outer_bar_col)
        end
        origin_bar_cols[p.origin_display_row] = outer_bar_col

        if has_bar and not p.suppress_tail then
          local tail_row = triangle_row - direction
          if p.connect_tail_on_triangle_row and triangle_row < origin_row then
            tail_row = triangle_row
          end
          -- Triangle position depends on kind:
          -- Additions dock to the target edge. Deletions start immediately
          -- after the left line number and use compact rails/underlines to
          -- reach the right side without occupying the whole gutter.
          local tri_col, bar_col_for_tail
          if p.kind == "delete" then
            tri_col = left_number_width
            bar_col_for_tail = delete_lane_col(lane)
          else
            tri_col = left_number_width + connector_core_width - 1
            bar_col_for_tail = lane_col(lane)
          end
          add_tail_underline(tail_row, {
            bar_col = bar_col_for_tail,
            triangle_col = tri_col,
            kind = p.kind,
          })
        end

        -- For deletions, track which right line number is the origin
        -- This allows session.lua to render underlines at the correct display row
        if p.kind == "delete" and p.origin_right_line then
          -- For deletions, the rail sits left of the right-docked cutout wedge.
          local delete_bar_col = delete_lane_col(lane)

          -- Find where underline should start for this delete origin
          -- Must account for: (1) any active bars from other deletions, (2) this deletion's own bar
          -- The underline should start AFTER the rightmost bar position
          -- If this deletion has a vertical bar, leave space for where it connects even
          -- though the bar itself starts after the origin row.
          local underline_start_after = rightmost_delete_bar_col(origin_row, has_bar and delete_bar_col or nil)

          delete_origin_right_lines[p.origin_right_line] = {
            has_bar = has_bar,
            bar_col = delete_bar_col,
            glyph_col = origin_glyph_cols[p.origin_display_row],
            lane = lane,
            origin_display_row = p.origin_display_row,
            origin_right_index = p.origin_right_index,
            underline_start_after = underline_start_after,  -- Column after which underline starts
          }
        end
      end
    end
  end

  return {
    origin_glyph_cols = origin_glyph_cols,
    origin_bar_cols = origin_bar_cols,
    origin_has_bar = origin_has_bar,
    tail_underlines = tail_underlines,
    delete_origin_right_lines = delete_origin_right_lines,
  }
end


-- Viewport projection: clip each route to the visible topline/height window
-- of both panes, splitting add/delete routes into per-target projected
-- segments and clamping change bands, then assign lanes to the result.
local function shallow_copy(tbl)
  local copy = {}
  for key, value in pairs(tbl) do
    copy[key] = value
  end
  return copy
end

function M.project_for_toplines(paths, left_topline, right_topline, left_height, right_height)
  left_topline = math.max(1, left_topline or 1)
  right_topline = math.max(1, right_topline or 1)
  left_height = math.max(1, left_height or 1)
  right_height = math.max(1, right_height or 1)
  local projected = {}

  local function right_to_connector_row(right_index)
    return left_topline + (right_index - right_topline)
  end

  local function delete_glyph_for_target(origin_row, target_row)
    return triangle_glyph("left", origin_row > target_row)
  end

  local function change_glyph_for(side, row, other_row)
    return triangle_glyph(side, other_row > row)
  end

  local function set_lane_occupancy(path, row_a, row_b)
    if not row_a or not row_b then
      return
    end
    local viewport_start = left_topline
    local viewport_end = left_topline + left_height - 1
    local start_row = math.max(viewport_start, math.min(row_a, row_b))
    local end_row = math.min(viewport_end, math.max(row_a, row_b))
    if start_row <= end_row then
      path.lane_occupancy_start = start_row
      path.lane_occupancy_end = end_row
    end
  end

  -- Shared constructor for projected add/delete routes. Adds and deletes use
  -- mirrored glyph sets, so classify approach per kind: for deletes ◣/◥
  -- approach from below; for adds ◢ does.
  local function add_projected(path, origin_row, target_index, target_row, glyph, show_triangle, suppress_tail)
    local q = shallow_copy(path)
    q.route_group = path.route_group or path
    -- Far-offscreen origins keep their true (possibly negative) rows on
    -- purpose. Every projected route anchors somewhere visible, so spans
    -- that overlap offscreen also overlap inside the viewport -- the
    -- offscreen cells add no real collision constraints -- while clamping
    -- origins onto a shared edge row collapses the dock ordering and
    -- degrades rail placement. Rendering clips rows outside the buffer.
    q.top = origin_row
    q.origin_display_row = origin_row
    q.display_start_row = target_row
    q.display_end_row = target_row
    q.triangle_display_row = target_row
    q.target_start_index = target_index
    q.target_end_index = target_index
    local from_below
    if path.kind == "delete" then
      from_below = glyph == TRIANGLE.left.below
    else
      from_below = glyph == TRIANGLE.right.below
    end
    q.approach = from_below and "from_below" or "from_above"
    q.triangle_glyph = glyph
    q.connect_tail_on_triangle_row = from_below and show_triangle ~= false
    q.hide_triangle = show_triangle == false
    q.suppress_tail = suppress_tail == true
    set_lane_occupancy(q, origin_row, target_row)
    projected[#projected + 1] = q
  end

  local function add_change_link(links, from_side, from_row, to_side, to_row, show_from, show_to, from_glyph, to_glyph, no_vertical, underline_row)
    if not from_row or not to_row then
      return
    end

    links[#links + 1] = {
      from_side = from_side,
      from_row = from_row,
      from_glyph = from_glyph or change_glyph_for(from_side, from_row, to_row),
      from_visible = show_from ~= false,
      to_side = to_side,
      to_row = to_row,
      to_glyph = to_glyph or change_glyph_for(to_side, to_row, from_row),
      to_visible = show_to ~= false,
      no_vertical = no_vertical == true,
      underline_row = underline_row,
    }
  end

  local function add_change_edge(edges, side, row, overlap_row)
    if not row or not overlap_row then
      return
    end
    edges[#edges + 1] = {
      side = side,
      row = row,
      glyph = change_glyph_for(side, row, overlap_row),
    }
  end

  local function set_change_lane_occupancy(path)
    local start_row, end_row
    local viewport_start = left_topline
    local viewport_end = left_topline + left_height - 1
    visit_change_rows(path, nil, function(row)
      if not row then
        return
      end
      row = math.max(viewport_start, math.min(viewport_end, row))
      start_row = start_row and math.min(start_row, row) or row
      end_row = end_row and math.max(end_row, row) or row
    end)

    if start_row and end_row then
      path.lane_occupancy_start = start_row
      path.lane_occupancy_end = end_row
    end
  end

  local function project_change_path(path)
    local q = shallow_copy(path)
    q.route_group = path.route_group or path
    q.viewport_change_links = {}
    q.viewport_change_edges = {}

    if not (path.start_left_index and path.end_left_index
        and path.start_right_index and path.end_right_index) then
      return q
    end

    -- Strict window bounds drive solid corridor, edges, and links together so
    -- solid rows always have matching wedge transitions (pad-extended solid
    -- without wedges violated documented band semantics).
    local left_visible_start = math.max(path.start_left_index, left_topline)
    local left_visible_end = math.min(path.end_left_index, left_topline + left_height - 1)
    local right_visible_index_start = math.max(path.start_right_index, right_topline)
    local right_visible_index_end = math.min(path.end_right_index, right_topline + right_height - 1)

    if left_visible_start <= left_visible_end then
      q.viewport_left_start = left_visible_start
      q.viewport_left_end = left_visible_end
    end
    if right_visible_index_start <= right_visible_index_end then
      q.viewport_right_index_start = right_visible_index_start
      q.viewport_right_index_end = right_visible_index_end
      q.viewport_right_start = right_to_connector_row(right_visible_index_start)
      q.viewport_right_end = right_to_connector_row(right_visible_index_end)
    end

    local ls, le = q.viewport_left_start, q.viewport_left_end
    local rs, re = q.viewport_right_start, q.viewport_right_end
    if ls and le and rs and re then
      local overlap_start = math.max(ls, rs)
      local overlap_end = math.min(le, re)
      if overlap_start <= overlap_end then
        q.viewport_solid_start = overlap_start
        q.viewport_solid_end = overlap_end
        if rs < overlap_start then
          local edge_row = overlap_start - 1
          add_change_edge(q.viewport_change_edges, "right", edge_row, overlap_start)
        end
        if ls < overlap_start then
          local edge_row = overlap_start - 1
          add_change_edge(q.viewport_change_edges, "left", edge_row, overlap_start)
        end
        if re > overlap_end then
          local edge_row = overlap_end + 1
          add_change_edge(q.viewport_change_edges, "right", edge_row, overlap_end)
        end
        if le > overlap_end then
          local edge_row = overlap_end + 1
          add_change_edge(q.viewport_change_edges, "left", edge_row, overlap_end)
        end
      elseif re < ls then
        if re + 1 == ls then
          add_change_link(q.viewport_change_links, "right", re, "left", ls, true, true,
            change_glyph_for("right", re, ls), change_glyph_for("left", ls, re), true, re)
        else
          add_change_link(q.viewport_change_links, "right", re, "left", ls, true, true)
        end
      elseif le < rs then
        if le + 1 == rs then
          add_change_link(q.viewport_change_links, "left", le, "right", rs, true, true,
            change_glyph_for("left", le, rs), change_glyph_for("right", rs, le), true, le)
        else
          add_change_link(q.viewport_change_links, "left", le, "right", rs, true, true)
        end
      end
    elseif ls and le then
      -- One-sided continuations: the visible band end links toward the
      -- offscreen counterpart. The from-side wedge only docks on the band's
      -- REAL edge; a clip boundary (band continuing past the viewport)
      -- keeps line/background continuity — no synthetic triangles at
      -- viewport edges.
      local projected_right_start = right_to_connector_row(path.start_right_index)
      local projected_right_end = right_to_connector_row(path.end_right_index)
      if projected_right_end < ls then
        add_change_link(q.viewport_change_links, "left", ls, "right", left_topline - 1,
          q.viewport_left_start == path.start_left_index, false,
          nil, nil, false, math.max(left_topline, ls - 1))
      elseif projected_right_start > le then
        add_change_link(q.viewport_change_links, "left", le, "right", left_topline + left_height,
          q.viewport_left_end == path.end_left_index, false,
          nil, nil, false, le)
      end
    elseif rs and re then
      if path.end_left_index < rs then
        add_change_link(q.viewport_change_links, "right", rs, "left", left_topline - 1,
          q.viewport_right_index_start == path.start_right_index, false,
          nil, nil, false, math.max(left_topline, rs - 1))
      elseif path.start_left_index > re then
        add_change_link(q.viewport_change_links, "right", re, "left", left_topline + left_height,
          q.viewport_right_index_end == path.end_right_index, false,
          nil, nil, false, re)
      end
    end

    set_change_lane_occupancy(q)
    return q
  end

  -- One skeleton projects both add and delete block paths; the specs below
  -- map the mirrored parts. Cases: (a) block fully outside the viewport
  -- with a visible origin -> suppressed stub one index past the edge;
  -- (b) origin scrolled offscreen -> single continuation toward the nearer
  -- visible end; (c) block strictly below/above a visible origin -> single
  -- wedge; (d) origin inside the visible block -> split wedge pair around
  -- the origin row.
  local function project_block_path(p, spec)
    local origin_row = spec.origin_row(p)
    local block_start = p.target_start_index or p.triangle_display_row or p.display_start_row
    local block_end = p.target_end_index or block_start
    if not origin_row or not block_start or not block_end then
      return
    end

    local function emit(target_index, glyph, show_triangle, suppress_tail)
      add_projected(p, origin_row, target_index, spec.to_row(target_index),
        glyph, show_triangle, suppress_tail)
    end

    local origin_visible = origin_row >= left_topline and origin_row <= (left_topline + left_height - 1)
    local visible_start = math.max(block_start, spec.clip_lo)
    local visible_end = math.min(block_end, spec.clip_hi)
    if visible_start > visible_end then
      if origin_visible then
        if block_start > spec.clip_hi then
          emit(spec.clip_hi + 1, triangle_glyph(spec.side, false), false, true)
        elseif block_end < spec.clip_lo then
          emit(spec.clip_lo - 1, triangle_glyph(spec.side, true), false, true)
        end
      end
      return
    end

    local visible_start_row = spec.to_row(visible_start)
    local visible_end_row = spec.to_row(visible_end)

    if not origin_visible then
      local target = block_start
      if visible_end_row < origin_row then
        target = visible_end
      elseif visible_start_row > origin_row then
        target = visible_start
      end
      local show_triangle = spec.show_triangle_when_origin_hidden
      if show_triangle and spec.dock_only_real_edges then
        -- Only a real block edge docks; a clip boundary (block continuing
        -- past the viewport) keeps rail/background continuity instead.
        show_triangle = (target == block_start and block_start >= spec.clip_lo)
          or (target == block_end and block_end <= spec.clip_hi)
      end
      emit(target, spec.offscreen_origin_glyph(origin_row, target, visible_start_row),
        show_triangle)
    elseif visible_start_row > origin_row then
      emit(visible_start, triangle_glyph(spec.side, false), true)
    elseif visible_end_row < origin_row then
      emit(visible_end, triangle_glyph(spec.side, true), true)
    else
      local origin_target = spec.origin_target_index(origin_row)
      local target_above = origin_target
      local target_below = origin_target + 1
      if visible_start_row == origin_row then
        target_above = visible_start
        target_below = visible_start + 1
      end

      if target_above >= visible_start and target_above <= visible_end then
        emit(target_above, triangle_glyph(spec.side, true), true)
      end
      if target_below >= visible_start and target_below <= visible_end then
        emit(target_below, triangle_glyph(spec.side, false), true)
      end
    end
  end

  -- Add targets live in right-buffer index space and convert to connector
  -- rows; the origin is already in left/connector space.
  local add_projection = {
    side = "right",
    clip_lo = right_topline,
    clip_hi = right_topline + right_height - 1,
    origin_row = function(p)
      return p.origin_left_index or p.origin_display_row
    end,
    to_row = right_to_connector_row,
    origin_target_index = function(origin_row)
      return right_topline + (origin_row - left_topline)
    end,
    -- Kept verbatim: compares the visible block start, not the chosen
    -- target, and diverges from the delete rule only when the panes have
    -- different heights. Normalizing would change rendered wedges.
    offscreen_origin_glyph = function(origin_row, _, visible_start_row)
      return visible_start_row < origin_row and "◢" or "◥"
    end,
    -- Visible REAL targets always dock: like deletes, an add with an
    -- offscreen origin draws its target horizontal and wedge when the
    -- docking row is the block's true edge. (Historically adds hid the
    -- wedge here, which left rails dangling one row short of a visible
    -- target with no triangle.) Clipped block edges are NOT real targets:
    -- when the block continues past the viewport, the clip boundary shows
    -- rails/background only — no synthetic triangles at viewport edges.
    show_triangle_when_origin_hidden = true,
    dock_only_real_edges = true,
  }

  -- Delete targets are already connector rows; the origin projects over
  -- from the right pane.
  local delete_projection = {
    side = "left",
    clip_lo = left_topline,
    clip_hi = left_topline + left_height - 1,
    origin_row = function(p)
      return p.origin_right_index and right_to_connector_row(p.origin_right_index) or p.origin_display_row
    end,
    to_row = function(index)
      return index
    end,
    origin_target_index = function(origin_row)
      return origin_row
    end,
    offscreen_origin_glyph = function(origin_row, target)
      return delete_glyph_for_target(origin_row, target)
    end,
    show_triangle_when_origin_hidden = true,
  }

  for _, p in ipairs(paths) do
    if p.kind == "add" and not p.embedded_in_change then
      project_block_path(p, add_projection)
    elseif p.kind == "delete" and not p.embedded_in_change then
      project_block_path(p, delete_projection)
    elseif p.kind == "change" then
      projected[#projected + 1] = project_change_path(p)
    else
      local q = shallow_copy(p)
      q.route_group = p.route_group or p
      projected[#projected + 1] = q
    end
  end

  assign_lanes(projected)
  return projected
end


-- Width pressure / plan stretch live in connector.width (shared with min/max).
M.pressure_core_width = connector_width.pressure_core_width
M.stretch_plan_to_core = connector_width.stretch_plan_to_core

return M
