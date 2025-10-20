-- paths.lua - Pure functions for lane/bar computation
-- Extracted from session.lua for testability

local M = {}

-- Compute occupancy range for overlap detection
-- Returns: start_row, finish_row
local function occupancy_range(p)
  local origin_row = p.origin_left_line or p.top or p.start_row or 0
  local triangle_row = p.start_row or origin_row

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

-- Build paths from chunks and line_meta
-- Returns: array of path objects (without lane assignments)
local function build_paths(chunks, line_meta)
  local paths = {}

  for _, chunk in ipairs(chunks) do
    if chunk.type == "add" then
      local origin_meta = line_meta[chunk.display_start - 1]
      local top_row = origin_meta and (chunk.display_start - 1)
      local origin_left_line = origin_meta and origin_meta.left_line
      local s, e = nil, nil
      for i = chunk.display_start, chunk.display_end do
        local m = line_meta[i]
        if m and m.kind == "add" then
          s = s and math.min(s, i) or i
          e = e and math.max(e, i) or i
        end
      end
      if s and e and top_row then
        paths[#paths + 1] = {
          kind = "add",
          top = top_row,
          start_row = s,
          end_row = e,
          lane = 0,
          origin_left_line = origin_left_line
        }
      end
    elseif chunk.type == "delete" then
      local origin_meta = line_meta[chunk.display_start - 1]
      local top_row = origin_meta and (chunk.display_start - 1)
      local origin_left_line = origin_meta and origin_meta.left_line
      local s, e = nil, nil
      for i = chunk.display_start, chunk.display_end do
        local m = line_meta[i]
        if m and m.kind == "delete" then
          s = s and math.min(s, i) or i
          e = e and math.max(e, i) or i
        end
      end
      if s and e and top_row then
        paths[#paths + 1] = {
          kind = "delete",
          top = top_row,
          start_row = s,
          end_row = e,
          lane = 0,
          origin_left_line = origin_left_line
        }
      end
    elseif chunk.type == "change" then
      local s, e = nil, nil
      for i = chunk.display_start, chunk.display_end do
        local m = line_meta[i]
        if m and m.kind == "change" then
          s = s and math.min(s, i) or i
          e = e and math.max(e, i) or i
        end
      end
      if s and e then
        paths[#paths + 1] = { kind = "change", start_row = s, end_row = e }
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
    local as = a.start_row or 0
    local bs = b.start_row or 0
    return as < bs
  end)

  local lanes = {}
  local max_lane = 0

  -- Assign lanes so later paths go to OUTER lanes (further left)
  for _, p in ipairs(paths) do
    if p.kind == "add" or p.kind == "delete" then
      local occupy_start, occupy_end = occupancy_range(p)
      local origin_row = p.origin_left_line or occupy_start

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
    if (p.kind == "add" or p.kind == "delete") and p.top then
      sorted_origins[#sorted_origins + 1] = { row = p.top, lane = p.lane, path = p }
    end
  end
  table.sort(sorted_origins, function(a, b) return a.row < b.row end)

  -- For each path, create bars from origin+1 to triangle-1
  for _, origin in ipairs(sorted_origins) do
    local p = origin.path
    local origin_row = p.origin_left_line or p.top or p.start_row
    local triangle_row = p.start_row

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
  local glyph_base_col = left_number_width + connector_core_width - 1

  local function lane_col(lane)
    return lane_col_base(lane, glyph_base_col, rail_spacing)
  end

  local function glyph_col_for_lane(lane)
    return lane_col(lane) + 1
  end

  local function compute_glyph_col_for_row(path, row)
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

  for _, p in ipairs(paths) do
    if p.kind == "add" or p.kind == "delete" then
      local lane = math.max(1, p.lane)
      if p.top then
        origin_glyph_cols[p.top] = compute_glyph_col_for_row(p, p.start_row)

        local origin_row = p.origin_left_line or p.top
        local triangle_row = p.start_row
        local has_bar = (triangle_row - origin_row) > 1
        origin_has_bar[p.top] = has_bar

        -- Find leftmost active bar on origin row
        local leftmost_bar_col = lane_col(lane)
        if active_bars[origin_row] then
          for bar_lane, _ in pairs(active_bars[origin_row]) do
            local bar_col = lane_col(bar_lane)
            if bar_col < leftmost_bar_col then
              leftmost_bar_col = bar_col
            end
          end
        end
        if has_bar and active_bars[origin_row + 1] then
          for bar_lane, _ in pairs(active_bars[origin_row + 1]) do
            local bar_col = lane_col(bar_lane)
            if bar_col < leftmost_bar_col then
              leftmost_bar_col = bar_col
            end
          end
        end
        origin_bar_cols[p.top] = leftmost_bar_col

        if has_bar then
          local tail_row = triangle_row - 1
          local tri_col = left_number_width + connector_core_width - 1
          tail_underlines[tail_row] = {
            bar_col = lane_col(lane),
            triangle_col = tri_col,
            kind = p.kind,
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
  }
end

return M
