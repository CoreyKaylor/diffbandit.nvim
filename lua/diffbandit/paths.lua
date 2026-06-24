-- paths.lua - Pure functions for lane/bar computation
-- Extracted from session.lua for testability

local M = {}

local MAX_VISIBLE_CONNECTOR_ROUTES = 8
M.MAX_VISIBLE_CONNECTOR_ROUTES = MAX_VISIBLE_CONNECTOR_ROUTES

local function origin_row_for_path(p)
  return p.origin_display_row or p.top or p.display_start_row or p.start_row or 0
end

local function triangle_row_for_path(p)
  return p.triangle_display_row or p.display_start_row or p.start_row or origin_row_for_path(p)
end

local function sort_row_for_path(p)
  if p.kind == "change" then
    local sort_row
    local function include_row(row)
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
    end

    for _, link in ipairs(p.viewport_change_links or {}) do
      if link.from_visible then
        include_row(link.from_row)
      end
      if link.to_visible then
        include_row(link.to_row)
      end
    end
    for _, edge in ipairs(p.viewport_change_edges or {}) do
      include_row(edge.row)
    end
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
    for _, link in ipairs(p.viewport_change_links or {}) do
      if link.from_visible then
        row = row and math.max(row, link.from_row) or link.from_row
      end
      if link.to_visible then
        row = row and math.max(row, link.to_row) or link.to_row
      end
    end
    for _, edge in ipairs(p.viewport_change_edges or {}) do
      row = row and math.max(row, edge.row) or edge.row
    end
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
    local function include_row(row)
      if not row then
        return
      end
      start_row = start_row and math.min(start_row, row) or row
      finish_row = finish_row and math.max(finish_row, row) or row
    end

    for _, link in ipairs(p.viewport_change_links or {}) do
      include_row(link.from_row)
      include_row(link.to_row)
    end
    for _, edge in ipairs(p.viewport_change_edges or {}) do
      include_row(edge.row)
    end

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

-- Compute column position for a lane
local function lane_col_base(lane, glyph_base_col, rail_spacing)
  local idx = math.max(0, lane - 1)
  return glyph_base_col - (idx * (rail_spacing + 1)) - 1
end

local function delete_lane_col_base(lane, left_number_width, connector_core_width, rail_spacing)
  local idx = math.max(0, lane - 1)
  return left_number_width + 1 + (idx * (rail_spacing + 1))
end

local function build_paths(chunks, line_meta)
  local paths = {}

  local current_chunk_index = nil

  local function push_segment(seg_kind, seg_start_idx, seg_end_idx)
    local start_meta = line_meta[seg_start_idx]
    local end_meta = line_meta[seg_end_idx]
    if not start_meta or not end_meta then
      return
    end

    local origin_meta = (seg_start_idx > 1) and line_meta[seg_start_idx - 1] or nil
    if seg_kind == "add" then
      local start_row = start_meta.right_line
      local end_row = end_meta.right_line
      if start_row and end_row then
        local visual_origin = origin_meta and origin_meta.left_index or nil
        local visual_start = start_meta.right_index or seg_start_idx
        local visual_end = end_meta.right_index or seg_end_idx
        local approach = "same_row"
        if visual_origin and visual_origin < visual_start then
          approach = "from_above"
        elseif visual_origin and visual_origin > visual_start then
          approach = "from_below"
        end
        paths[#paths + 1] = {
          kind = "add",
          chunk = current_chunk_index,
          top = visual_origin,
          origin_side = "left",
          target_side = "right",
          origin_display_row = visual_origin,
          meta_start_row = seg_start_idx,
          meta_end_row = seg_end_idx,
          display_start_row = visual_start,
          display_end_row = visual_end,
          block_display_start = visual_start,
          block_display_end = visual_end,
          triangle_display_row = visual_start,
          approach = approach,
          triangle_glyph = approach == "from_below" and "◢" or "◥",
          fill_side = "right",
          start_row = start_row,
          end_row = end_row,
          start_right_line = start_row,
          end_right_line = end_row,
          lane = 0,
          origin_left_line = origin_meta and origin_meta.left_line or nil,
          origin_left_index = origin_meta and origin_meta.left_index or nil,
          origin_kind = origin_meta and origin_meta.kind or nil,
          embedded_in_change = origin_meta and origin_meta.kind == "change" or false,
          target_start_index = start_meta.right_index,
          target_end_index = end_meta.right_index,
        }
      end
    elseif seg_kind == "delete" then
      local start_row = start_meta.left_line
      local end_row = end_meta.left_line
      if start_row and end_row then
        local visual_origin = origin_meta and origin_meta.right_index or nil
        local visual_start = start_meta.left_index or seg_start_idx
        local visual_end = end_meta.left_index or seg_end_idx
        local approach = "same_row"
        if visual_origin and visual_origin < visual_start then
          approach = "from_above"
        elseif visual_origin and visual_origin > visual_start then
          approach = "from_below"
        end
        paths[#paths + 1] = {
          kind = "delete",
          chunk = current_chunk_index,
          top = visual_origin,
          origin_side = "right",
          target_side = "left",
          origin_display_row = visual_origin,
          meta_start_row = seg_start_idx,
          meta_end_row = seg_end_idx,
          display_start_row = visual_start,
          display_end_row = visual_end,
          block_display_start = visual_start,
          block_display_end = visual_end,
          triangle_display_row = visual_start,
          approach = approach,
          triangle_glyph = approach == "from_below" and "◥" or "◤",
          fill_side = "left",
          start_row = start_row,
          end_row = end_row,
          start_left_line = start_row,
          end_left_line = end_row,
          lane = 0,
          origin_left_line = origin_meta and origin_meta.left_line or nil,
          origin_right_line = origin_meta and origin_meta.right_line or nil,
          origin_right_index = origin_meta and origin_meta.right_index or nil,
          target_start_index = start_meta.left_index,
          target_end_index = end_meta.left_index,
        }
      end
    end
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
        push_segment(k, i, j)
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

  for _, p in ipairs(paths) do
    if p.kind == "add" and p.embedded_in_change and p.origin_left_index then
      for _, candidate in ipairs(paths) do
        if candidate.kind == "change"
            and candidate.start_left_index
            and candidate.end_left_index
            and p.origin_left_index >= candidate.start_left_index
            and p.origin_left_index <= candidate.end_left_index then
          candidate.mixed_add = true
          candidate.end_right_index = math.max(candidate.end_right_index or 0, p.target_end_index or p.display_end_row or 0)
          candidate.start_right_index = math.min(candidate.start_right_index or candidate.end_right_index, p.target_start_index or p.display_start_row)
          candidate.display_start_row = math.min(candidate.display_start_row or candidate.start_left_index, candidate.start_right_index or p.display_start_row)
          candidate.display_end_row = math.max(candidate.display_end_row or candidate.end_left_index, candidate.end_right_index or p.display_end_row)
          candidate.block_display_start = candidate.display_start_row
          candidate.block_display_end = candidate.display_end_row
          break
        end
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
      if ranges_overlap(as, ae, bs, be, 1) then
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

    local origin_row = origin_row_for_path(path)
    local triangle_row = triangle_row_for_path(path)
    local start_row = math.min(origin_row, triangle_row) + 1
    local end_row = math.max(origin_row, triangle_row) - 1
    if path.connect_tail_on_triangle_row and triangle_row < origin_row then
      start_row = triangle_row + 1
      end_row = origin_row
    elseif path.hide_triangle and triangle_row < origin_row then
      end_row = origin_row
    end
    return row >= start_row and row <= end_row
  end

  local function promote_left_tail_crossings()
    local function change_endpoint_rows(path)
      local rows = {}
      if path.kind ~= "change" then
        return rows
      end

      for _, link in ipairs(path.viewport_change_links or {}) do
        if link.from_visible and link.from_row then
          rows[#rows + 1] = link.from_row
        end
        if link.to_visible and link.to_row then
          rows[#rows + 1] = link.to_row
        end
      end
      for _, edge in ipairs(path.viewport_change_edges or {}) do
        if edge.row then
          rows[#rows + 1] = edge.row
        end
      end
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
                  if rail_path.lane == 1 then
                    rail_path.lane = 3
                    rail_path.collision_lane = rail_path.lane
                    changed = true
                  end
                  local minimum_lane = 7
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
      for _, link in ipairs(path.viewport_change_links or {}) do
        if link.from_visible then
          add_row(link.from_row)
          add_row(link.underline_row)
        end
        if link.to_visible then
          add_row(link.to_row)
          add_row(link.underline_row)
        end
      end
      for _, edge in ipairs(path.viewport_change_edges or {}) do
        add_row(edge.row)
      end
      return rows
    end

    if path.kind == "delete" and not path.suppress_tail then
      add_row(triangle_row_for_path(path))
    end

    return rows
  end

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
          local collision_margin = has_change_path and 1
            or ((p.hide_triangle and triangle_row_for_path(p) < origin_row_for_path(p)) and 1 or 0)
          while lane_has_overlap(lanes, assigned_lane, occupy_start, occupy_end, group, collision_margin) do
            assigned_lane = assigned_lane + 1
          end

          if has_change_path or p.hide_triangle then
            local highest_lane = highest_overlapping_lane(
              lanes,
              occupy_start,
              occupy_end,
              group,
              collision_margin,
              direction
            )
            if highest_lane > 0 and assigned_lane <= highest_lane then
              assigned_lane = highest_lane + 1
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

              local same_direction_lane = highest_overlapping_lane(
                lanes,
                occupy_start,
                occupy_end,
                group,
                collision_margin,
                direction
              )
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
    resolve_left_endpoint_crossings()
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

local function add_route_cells(cells, row, start_col, end_col, kind)
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

  local start_row = math.min(route.source_row, route.target_row) + 1
  local end_row = math.max(route.source_row, route.target_row) - 1
  if route.include_source_pipe then
    if route.source_row < route.target_row then
      start_row = route.source_row
    else
      end_row = route.source_row
    end
  end
  if route.include_target_pipe then
    if route.target_row < route.source_row then
      start_row = route.target_row
    else
      end_row = route.target_row
    end
  end

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

local function mark_route_overflow_hidden(route)
  route.overflow_hidden = true
  if route.link then
    route.link.overflow_hidden = true
  elseif route.path then
    route.path.overflow_hidden = true
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

  local hidden = {}
  local hidden_set = {}

  local function active_routes_on(row)
    local active = {}
    for _, route in ipairs(vertical_routes) do
      if not hidden_set[route]
          and route.vertical_start_row <= row
          and route.vertical_end_row >= row then
        active[#active + 1] = route
      end
    end
    return active
  end

  local function choose_hidden_route(active)
    table.sort(active, function(a, b)
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
          local active = active_routes_on(row)
          if #active > cap then
            overflow_row = row
            overflow_active = active
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
    mark_route_overflow_hidden(route)
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
      add_route_cells(segments, row, 0, math.max(-1, rail_col - 1), h_hl)
    else
      add_route_cells(segments, row, math.min(connector_core_width, rail_col + 1), connector_core_width - 1, h_hl)
    end
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
        h_hl
      )
    else
      if route.source_visible ~= false and route.suppress_source ~= true then
        add_horizontal_for_side(route.source_side, route.source_row)
      end
      if route.target_visible ~= false and route.suppress_target ~= true then
        add_horizontal_for_side(route.target_side, route.target_row)
      end
    end
    return segments
  end

  if route.source_visible ~= false and route.suppress_source ~= true then
    add_horizontal_for_side(route.source_side, route.source_row)
  end
  if route.target_visible ~= false and route.suppress_target ~= true then
    add_horizontal_for_side(route.target_side, route.target_row)
  end
  local vertical_min_row = math.min(route.source_row, route.target_row)
  local vertical_max_row = math.max(route.source_row, route.target_row)
  local extra_min_row = nil
  local extra_max_row = nil
  for _, extra in ipairs(route.extra_horizontals or {}) do
    local before = #segments
    add_horizontal_for_side(extra.side, extra.row)
    for i = before + 1, #segments do
      segments[i].continuation = true
    end
    if extra.row then
      vertical_min_row = math.min(vertical_min_row, extra.row)
      vertical_max_row = math.max(vertical_max_row, extra.row)
      extra_min_row = extra_min_row and math.min(extra_min_row, extra.row) or extra.row
      extra_max_row = extra_max_row and math.max(extra_max_row, extra.row) or extra.row
    end
  end

  local vertical_start = vertical_min_row + 1
  local vertical_end = vertical_max_row - 1
  if route.include_source_pipe then
    if route.source_row < route.target_row then
      vertical_start = route.source_row
    else
      vertical_end = route.source_row
    end
  end
  if route.include_target_pipe then
    if route.target_row < route.source_row then
      vertical_start = route.target_row
    else
      vertical_end = route.target_row
    end
  end
  if extra_min_row then
    vertical_start = math.min(vertical_start, extra_min_row)
    vertical_end = math.max(vertical_end, extra_max_row)
  end
  add_vertical_cells(segments, vertical_start, vertical_end, rail_col, v_hl)

  return segments
end

local function iter_segment_cells(segment, callback)
  if segment.type == "horizontal" then
    for col = segment.start_col, segment.end_col do
      callback(segment.row, col, "horizontal")
    end
  elseif segment.type == "vertical" then
    for row = segment.start_row, segment.end_row do
      callback(row, segment.col, "vertical")
    end
  end
end

local function route_collides(segments, occupied, group)
  for _, segment in ipairs(segments) do
    local hit = false
    local function check_cell(row, col)
      local row_occupied = occupied[row]
      if row_occupied then
        for check_col = col - 1, col + 1 do
          local owner = row_occupied[check_col]
          if owner and owner ~= group then
            return true
          end
        end
      end
      return false
    end

    iter_segment_cells(segment, function(row, col)
      if hit then
        return
      end
      hit = check_cell(row, col)
    end)
    if hit then
      return true
    end
  end
  return false
end

local function reserve_route_segments(segments, occupied, group, marks)
  for _, segment in ipairs(segments) do
    iter_segment_cells(segment, function(row, col)
      occupied[row] = occupied[row] or {}
      if occupied[row][col] == nil then
        occupied[row][col] = group
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
  local has_vertical = math.abs(triangle_row - origin_row) > 1
    or (path.connect_tail_on_triangle_row == true and triangle_row < origin_row)
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
    if link.no_vertical and link.from_row == link.to_row then
      -- Same-row change transitions are a single underline and do not need a rail
      -- reservation, but keeping them in the planner gives rendering one path.
    end

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

  table.sort(routes, route_priority)
  local hidden_routes
  routes, hidden_routes = prune_overflow_routes(routes, {
    max_visible_connector_routes = layout.max_visible_connector_routes,
    viewport_topline = layout.viewport_topline,
    viewport_height = layout.viewport_height,
  })

  local occupied = {}
  local max_used_col = 0
  local function clear_route_assignments()
    for _, route in ipairs(routes) do
      route.rail_col = nil
      route.segments = nil
    end
  end

  local function remaining_routes_have_candidate(start_index)
    for check_index = start_index, #routes do
      local check_route = routes[check_index]
      local has_candidate = false
      for _, check_col in ipairs(route_preferred_columns(check_route, connector_core_width)) do
        local check_segments = build_route_segments(check_route, check_col, connector_core_width)
        if not route_collides(check_segments, occupied, check_route.group) then
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
      for _, col in ipairs(route_preferred_columns(route, connector_core_width)) do
        local segments = build_route_segments(route, col, connector_core_width)
        if not route_collides(segments, occupied, route.group) then
          local marks = {}
          reserve_route_segments(segments, occupied, route.group, marks)
          local leaves_room = remaining_routes_have_candidate(route_index + 1)
          unreserve_route_segments(occupied, marks)
          if leaves_room then
            route.rail_col = col
            route.segments = segments
            reserve_route_segments(segments, occupied, route.group)
            placed = true
            break
          end
        end
      end
      if not placed then
        for _, col in ipairs(route_preferred_columns(route, connector_core_width)) do
          local segments = build_route_segments(route, col, connector_core_width)
          if not route_collides(segments, occupied, route.group) then
            route.rail_col = col
            route.segments = segments
            reserve_route_segments(segments, occupied, route.group)
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
    if backtrack_steps > backtrack_limit then
      return false
    end
    if index > #routes then
      return true
    end

    local route = routes[index]
    for _, col in ipairs(route_preferred_columns(route, connector_core_width)) do
      local segments = build_route_segments(route, col, connector_core_width)
      if not route_collides(segments, occupied, route.group) then
        local marks = {}
        reserve_route_segments(segments, occupied, route.group, marks)
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
  local success, unplaced_routes = solve_greedy()
  if not success then
    strategy = "backtrack"
    occupied = {}
    clear_route_assignments()
    success = solve_route(1)
  end
  if not success then
    strategy = backtrack_steps > backtrack_limit and "bounded-hidden" or "greedy-hidden"
    success, unplaced_routes = solve_greedy()
    hidden_routes = hidden_routes or {}
    for _, route in ipairs(unplaced_routes or {}) do
      mark_route_overflow_hidden(route)
      hidden_routes[#hidden_routes + 1] = route
      route.rail_col = nil
      route.segments = {}
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

  return {
    routes = routes,
    hidden_routes = hidden_routes or {},
    success = success,
    strategy = strategy,
    max_used_col = max_used_col,
    occupied = occupied,
  }
end

function M.required_connector_core_width_for_paths(paths, minimum_width, max_width, layout)
  minimum_width = math.max(1, minimum_width or 1)
  max_width = math.max(minimum_width, max_width or 60)
  layout = layout or {}
  for width = minimum_width, max_width do
    local plan = M.plan_routes(paths, {
      connector_core_width = width,
      viewport_topline = layout.viewport_topline,
      viewport_height = layout.viewport_height,
      max_visible_connector_routes = layout.max_visible_connector_routes,
    })
    if plan.success then
      return width, plan
    end
  end
  return max_width, M.plan_routes(paths, {
    connector_core_width = max_width,
    viewport_topline = layout.viewport_topline,
    viewport_height = layout.viewport_height,
    max_visible_connector_routes = layout.max_visible_connector_routes,
  })
end

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
    local origin_row = origin_row_for_path(p)
    local triangle_row = triangle_row_for_path(p)

    local bar_start = math.min(origin_row, triangle_row) + 1
    local bar_end = math.max(origin_row, triangle_row) - 1
    if p.connect_tail_on_triangle_row and triangle_row < origin_row then
      bar_start = triangle_row + 1
      bar_end = origin_row
    elseif p.hide_triangle and triangle_row < origin_row then
      bar_end = origin_row
    end

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
    if sidecar_numbers then
      local idx = math.max(0, lane - 1)
      return 1 + (idx * (rail_spacing + 1))
    end
    return delete_lane_col_base(lane, left_number_width, connector_core_width, rail_spacing)
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
      if p.origin_display_row then
        origin_glyph_cols[p.origin_display_row] = compute_glyph_col_for_row(p, p.triangle_display_row)

        local origin_row = origin_row_for_path(p)
        local triangle_row = triangle_row_for_path(p)
        local has_bar = math.abs(triangle_row - origin_row) > 1
            or (p.connect_tail_on_triangle_row == true and triangle_row < origin_row)
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

return M
