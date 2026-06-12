-- paths.lua - Pure functions for lane/bar computation
-- Extracted from session.lua for testability

local M = {}

local function origin_row_for_path(p)
  return p.origin_display_row or p.top or p.display_start_row or p.start_row or 0
end

local function triangle_row_for_path(p)
  return p.triangle_display_row or p.display_start_row or p.start_row or origin_row_for_path(p)
end

-- Compute occupancy range for overlap detection
-- Returns: start_row, finish_row
local function occupancy_range(p)
  local origin_row = origin_row_for_path(p)
  local triangle_row = triangle_row_for_path(p)

  local has_vertical_bar = (triangle_row - origin_row) > 1

  local start_row = origin_row
  local finish_row
  if has_vertical_bar then
    finish_row = triangle_row - 1
  else
    finish_row = origin_row
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
  -- Sort by start_row
  table.sort(paths, function(a, b)
    local as = a.display_start_row or a.start_row or 0
    local bs = b.display_start_row or b.start_row or 0
    return as < bs
  end)

  local lanes_add = {}
  local lanes_delete = {}
  local max_lane = 0

  -- Assign lanes so later paths go to OUTER lanes (further from triangle)
  for _, p in ipairs(paths) do
    if p.kind == "add" or p.kind == "delete" then
      local occupy_start, occupy_end = occupancy_range(p)
      local origin_row = origin_row_for_path(p)

      local lanes = (p.kind == "delete") and lanes_delete or lanes_add

      -- Find the highest lane number that is still active at this origin row
      local highest_active_lane = 0
      for li = 1, #lanes do
        if (lanes[li] or 0) >= origin_row then
          if li > highest_active_lane then
            highest_active_lane = li
          end
        end
      end

      -- Assign to the next lane after the highest active one
      local assigned_lane = highest_active_lane + 1

      p.lane = assigned_lane
      lanes[assigned_lane] = occupy_end

      if p.lane > max_lane then
        max_lane = p.lane
      end
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

-- Exported for testing: compute column position for a lane
M.lane_col = lane_col_base

-- Compute active vertical bars per row
-- Returns: active_bars[row][lane] = path
function M.compute_active_bars(paths)
  local active_vertical_bars = {}

  -- Collect origins sorted by row
  local sorted_origins = {}
  for _, p in ipairs(paths) do
    if (p.kind == "add" or p.kind == "delete") and p.origin_display_row and not p.embedded_in_change then
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

    local bar_start = origin_row + 1
    local bar_end = triangle_row - 1

    if bar_end >= bar_start then
      for row = bar_start, bar_end do
        active_vertical_bars[row] = active_vertical_bars[row] or {}
        active_vertical_bars[row][p.lane] = p
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

  local function delete_glyph_col_for_lane(path)
    return left_number_width
  end

  local function compute_glyph_col_for_row(path, row)
    if path.kind == "delete" then
      return delete_glyph_col_for_lane(path)
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

  for _, p in ipairs(paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change then
      local lane = math.max(1, p.lane)
      if p.origin_display_row then
        origin_glyph_cols[p.origin_display_row] = compute_glyph_col_for_row(p, p.triangle_display_row)

        local origin_row = origin_row_for_path(p)
        local triangle_row = triangle_row_for_path(p)
        local has_bar = (triangle_row - origin_row) > 1
        origin_has_bar[p.origin_display_row] = has_bar

        -- Find leftmost active bar on origin row
        local leftmost_bar_col = (p.kind == "delete") and delete_lane_col(lane) or lane_col(lane)
        if active_bars[origin_row] then
          for bar_lane, _ in pairs(active_bars[origin_row]) do
            local bar_col = (p.kind == "delete") and delete_lane_col(bar_lane) or lane_col(bar_lane)
            if p.kind == "delete" then
              if bar_col > leftmost_bar_col then
                leftmost_bar_col = bar_col
              end
            elseif bar_col < leftmost_bar_col then
              leftmost_bar_col = bar_col
            end
          end
        end
        if has_bar and active_bars[origin_row + 1] then
          for bar_lane, _ in pairs(active_bars[origin_row + 1]) do
            local bar_col = (p.kind == "delete") and delete_lane_col(bar_lane) or lane_col(bar_lane)
            if p.kind == "delete" then
              if bar_col > leftmost_bar_col then
                leftmost_bar_col = bar_col
              end
            elseif bar_col < leftmost_bar_col then
              leftmost_bar_col = bar_col
            end
          end
        end
        origin_bar_cols[p.origin_display_row] = leftmost_bar_col

        if has_bar then
          local tail_row = triangle_row - 1
          -- Triangle position depends on kind:
          -- Additions dock to the target edge. Deletions start immediately
          -- after the left line number and use compact rails/underlines to
          -- reach the right side without occupying the whole gutter.
          local tri_col, bar_col_for_tail
          if p.kind == "delete" then
            tri_col = delete_glyph_col_for_lane(p)
            bar_col_for_tail = delete_lane_col(lane)
          else
            tri_col = left_number_width + connector_core_width - 1
            bar_col_for_tail = lane_col(lane)
          end
          tail_underlines[tail_row] = {
            bar_col = bar_col_for_tail,
            triangle_col = tri_col,
            kind = p.kind,
          }
        end

        -- For deletions, track which right line number is the origin
        -- This allows session.lua to render underlines at the correct display row
        if p.kind == "delete" and p.origin_right_line then
          -- For deletions, the rail sits left of the right-docked cutout wedge.
          local delete_bar_col = delete_lane_col(lane)

          -- Find where underline should start for this delete origin
          -- Must account for: (1) any active bars from other deletions, (2) this deletion's own bar
          -- The underline should start AFTER the rightmost bar position
          local underline_start_after = nil

          -- Check active bars from other deletions
          if active_bars[origin_row] then
            for bar_lane, _ in pairs(active_bars[origin_row]) do
              local bar_col = delete_lane_col(bar_lane)
              if not underline_start_after or bar_col > underline_start_after then
                underline_start_after = bar_col
              end
            end
          end

          -- Also account for THIS deletion's bar column (even though bar starts at origin+1,
          -- the underline at origin should leave space for where the bar connects)
          if has_bar then
            if not underline_start_after or delete_bar_col > underline_start_after then
              underline_start_after = delete_bar_col
            end
          end

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
