local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(test_dir .. "/..", ":p")
package.path = package.path .. ";" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua"

local config_mod = require("diffbandit.config")
local config = config_mod.defaults()
local diff = require("diffbandit.diff")
local highlights = require("diffbandit.highlights")
local view = require("diffbandit.view")
local paths_mod = require("diffbandit.paths")
local Session = require("diffbandit.session")

-- Helper: read file lines
local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return {} end
  return lines
end

-- Helper: convert lines to text
local function to_text(lines)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n"
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "assertion failed") .. string.format("\nExpected: %s\nActual:   %s", tostring(b), tostring(a)))
  end
end

local function assert_ne(a, b, msg)
  if a == b then
    error((msg or "assertion failed") .. string.format("\nExpected values to differ, both were: %s", tostring(a)))
  end
end

local function get_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local function luminance(color)
  if not color then
    return 0
  end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  return ((0.2126 * r) + (0.7152 * g) + (0.0722 * b)) / 255
end

-- Scenario 1: initial state
do
  local left = {"test"}
  local right = {"tast more"}
  local left_text = table.concat(left, "\n") .. "\n"
  local right_text = table.concat(right, "\n") .. "\n"

  local hunks, err = diff.compute_hunks(left_text, right_text, config.diff)
  assert_eq(err, nil, "diff error (scenario 1)")
  local v = view.build(left, right, hunks, config)

  local meta_first
  for _, m in ipairs(v.line_meta) do
    if (m.left_line == 1 or m.right_line == 1) and m.kind ~= "context" then
      meta_first = m
      break
    end
  end
  assert_eq(meta_first and meta_first.kind or nil, "change", "expected 'change' on first line before insertion")
end

-- Scenario 2: right adds a new line; first line should be change with green suffix; new line fully green (add)
do
  local left = {"test"}
  local right = {"test more", "with some additions"}
  local left_text = table.concat(left, "\n") .. "\n"
  local right_text = table.concat(right, "\n") .. "\n"

  local hunks, err = diff.compute_hunks(left_text, right_text, config.diff)
  assert_eq(err, nil, "diff error (scenario 2)")
  local v = view.build(left, right, hunks, config)

  local meta_r1, meta_r2
  for _, m in ipairs(v.line_meta) do
    if m.right_line == 1 then meta_r1 = m end
    if m.right_line == 2 then meta_r2 = m end
  end
  assert_eq(meta_r1 and meta_r1.kind or nil, "change", "first line should be 'change' after insertion")
  assert_eq(meta_r2 and meta_r2.kind or nil, "add", "second line should be 'add' (pure addition)")

  local spans = diff.changed_spans(left[1], right[1])
  assert_eq(#(spans.right_changes), 0, "no blue change spans expected on first line when only suffix added")
end

-- ==============================================================================
-- PATH MODULE UNIT TESTS
-- ==============================================================================

-- Test Suite 3: Lane assignment for extreme overlapping additions
-- Verifies that later overlapping paths get outer lanes (higher lane = further left)
do
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (extreme additions)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  -- Build lookup by origin_left_line
  local by_origin = {}
  for _, p in ipairs(paths) do
    if p.origin_left_line then
      by_origin[p.origin_left_line] = p
    end
  end

  -- Bravo (origin 2): lane 1 (first path, no active lanes)
  assert_eq(by_origin[2] ~= nil, true, "Bravo path should exist")
  assert_eq(by_origin[2].lane, 1, "Bravo should be lane 1")

  -- Charlie (origin 3): lane 1 (Bravo freed at row 2)
  assert_eq(by_origin[3] ~= nil, true, "Charlie path should exist")
  assert_eq(by_origin[3].lane, 1, "Charlie should be lane 1 (Bravo freed)")

  -- Delta (origin 4): lane 2 (Charlie still active)
  assert_eq(by_origin[4] ~= nil, true, "Delta path should exist")
  assert_eq(by_origin[4].lane, 2, "Delta should be lane 2 (nested in Charlie)")

  -- Foxtrot (origin 6): lane 3 (Delta still active at row 6)
  assert_eq(by_origin[6] ~= nil, true, "Foxtrot path should exist")
  assert_eq(by_origin[6].lane, 3, "Foxtrot should be lane 3 (Delta active)")

  -- Golf (origin 7): lane 4 (Foxtrot + Delta active)
  assert_eq(by_origin[7] ~= nil, true, "Golf path should exist")
  assert_eq(by_origin[7].lane, 4, "Golf should be lane 4 (nested in Foxtrot)")

  -- Hotel (origin 8): lane 5 (deepest nesting)
  assert_eq(by_origin[8] ~= nil, true, "Hotel path should exist")
  assert_eq(by_origin[8].lane, 5, "Hotel should be lane 5 (deepest)")
end

-- Test Suite 4: Vertical bar row ranges
-- Verifies bars span from origin_row+1 to triangle_row-1
do
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (bar ranges)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)

  for _, p in ipairs(paths) do
    if p.origin_left_line and (p.kind == "add" or p.kind == "delete") then
      local origin = p.origin_left_line
      local triangle = p.start_row
      local has_bar = (triangle - origin) > 1

      if has_bar then
        -- Bar should exist from origin+1 to triangle-1
        for row = origin + 1, triangle - 1 do
          assert_eq(active_bars[row] ~= nil, true,
            "Bars should exist at row " .. row .. " for origin " .. origin)
          assert_eq(active_bars[row][p.lane] ~= nil, true,
            "Bar at row " .. row .. " should be in lane " .. p.lane)
        end

        -- Bar should NOT exist on origin row
        local no_bar_on_origin = (active_bars[origin] == nil or active_bars[origin][p.lane] == nil)
        assert_eq(no_bar_on_origin, true, "No bar should be on origin row " .. origin)
      end
    end
  end
end

-- Test Suite 4b: Projected routes can run upward after independent scrolling
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 1,
      triangle_display_row = 1,
      lane = 1,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[2] ~= nil, true,
    "Projected upward add route should keep a rail between target and lower origin")
  assert_eq(active_bars[2][1] ~= nil, true,
    "Projected upward add route should use the assigned lane for the rail")
  assert_eq(active_bars[1] == nil or active_bars[1][1] == nil, true,
    "Projected upward add route should not draw a rail on the transition row")
  assert_eq(active_bars[3] == nil or active_bars[3][1] == nil, true,
    "Projected upward add route should not draw a rail on the origin row")
  assert_eq(underlines.origin_has_bar[3], true,
    "Projected upward add origin should connect to a vertical rail")
  assert_eq(underlines.tail_underlines[2] ~= nil, true,
    "Projected upward add route should place the tail underline below the transition")
  assert_eq(underlines.tail_underlines[2].kind, "add",
    "Projected upward tail underline should keep add styling")
end

-- Test Suite 4c: Projected route lanes are assigned from viewport geometry
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "add",
      origin_display_row = 7,
      top = 7,
      display_start_row = 3,
      triangle_display_row = 3,
      route_group = lower_group,
      connect_tail_on_triangle_row = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end
  local active_bars = paths_mod.compute_active_bars(projected_paths)

  assert_eq(by_group[upper_group].lane, 2,
    "Hidden projected continuation should step outward around a visible route")
  assert_eq(by_group[lower_group].lane, 1,
    "Visible projected route should keep the inner add lane")
  assert_eq(active_bars[3] ~= nil and active_bars[3][2] ~= nil, true,
    "Hidden upward continuation should include the origin row to avoid a broken corner")
  assert_eq(active_bars[3] == nil or active_bars[3][1] == nil, true,
    "Visible lower route should not draw its inner rail on the triangle row")
  assert_eq(active_bars[7] ~= nil and active_bars[7][1] ~= nil, true,
    "Visible lower route should terminate on its origin row")
end

-- Test Suite 4d: Split triangles for one projected addition share a lane
do
  local group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 2,
      triangle_display_row = 2,
      route_group = group,
    },
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 4,
      triangle_display_row = 4,
      route_group = group,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  assert_eq(projected_paths[1].lane, projected_paths[2].lane,
    "Split triangles from the same added block should stay on one lane")
end

-- Test Suite 4e: Hidden continuations only step outward on real overlap
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "add",
      origin_display_row = 7,
      top = 7,
      display_start_row = 5,
      triangle_display_row = 5,
      route_group = lower_group,
      connect_tail_on_triangle_row = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end

  assert_eq(by_group[upper_group].lane, 1,
    "Hidden continuation should stay inner when the visible route starts after a full-row gap")
  assert_eq(by_group[lower_group].lane, 1,
    "Visible route should reuse the inner lane when there is no adjacent collision")
end

-- Test Suite 4f: Adjacent upward projected additions still draw a tail
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 2,
      triangle_display_row = 2,
      lane = 1,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[2] == nil or active_bars[2][1] == nil, true,
    "Adjacent upward add route should not draw a rail on the triangle row")
  assert_eq(active_bars[3] ~= nil and active_bars[3][1] ~= nil, true,
    "Adjacent upward add route should terminate on the origin row")
  assert_eq(underlines.origin_has_bar[3], true,
    "Adjacent upward add origin should connect to the triangle-row rail")
  assert_eq(underlines.tail_underlines[2] ~= nil, true,
    "Adjacent upward add route should underline from the rail to the triangle")
end

-- Test Suite 4g: Lower hidden upward continuations keep the inner lane
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = -10,
      triangle_display_row = -10,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "add",
      origin_display_row = 7,
      top = 7,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = lower_group,
      hide_triangle = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end

  assert_eq(by_group[lower_group].lane, 1,
    "Lower clipped upward route should keep the inner add lane")
  assert_eq(by_group[upper_group].lane, 2,
    "Upper clipped upward route should step outward around the lower route")
end

-- Test Suite 4h: Same-row projected additions do not draw an extra tail
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 3,
      triangle_display_row = 3,
      lane = 1,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[3] == nil or active_bars[3][1] == nil, true,
    "Same-row add transition should not draw a vertical rail")
  assert_eq(underlines.origin_has_bar[3], false,
    "Same-row add transition should use the glyph column, not a routed bar")
  assert_eq(underlines.tail_underlines[2] == nil, true,
    "Same-row add transition should not underline the row above the glyph")
  assert_eq(underlines.tail_underlines[3] == nil, true,
    "Same-row add transition should not create a separate tail underline")
end

-- Test Suite 4i: Adjacent upward projected deletions mirror addition tail behavior
do
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 3,
      origin_right_line = 3,
      top = 3,
      display_start_row = 2,
      triangle_display_row = 2,
      lane = 1,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[2] == nil or active_bars[2][1] == nil, true,
    "Adjacent upward delete route should not draw a rail on the triangle row")
  assert_eq(active_bars[3] ~= nil and active_bars[3][1] ~= nil, true,
    "Adjacent upward delete route should terminate on the origin row")
  assert_eq(underlines.origin_has_bar[3], true,
    "Adjacent upward delete origin should connect to the triangle-row rail")
  assert_eq(underlines.tail_underlines[2] ~= nil, true,
    "Adjacent upward delete route should underline from the triangle toward the rail")
  assert_eq(underlines.tail_underlines[2].kind, "delete",
    "Adjacent upward delete tail underline should keep delete styling")
  assert_eq(underlines.delete_origin_right_lines[3].underline_start_after, 1,
    "Adjacent upward delete origin underline should start after the rail column")
end

-- Test Suite 4j: Upward left-side overlaps give the lower route the rightmost lane
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 3,
      top = 3,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "delete",
      origin_display_row = 7,
      top = 7,
      display_start_row = 3,
      triangle_display_row = 3,
      route_group = lower_group,
      connect_tail_on_triangle_row = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end
  local active_bars = paths_mod.compute_active_bars(projected_paths)

  assert_eq(by_group[upper_group].lane, 1,
    "Upper upward deletion continuation should keep the left-side inner lane")
  assert_eq(by_group[lower_group].lane, 2,
    "Lower upward deletion route should take the rightmost lane")
  assert_eq(active_bars[3] ~= nil and active_bars[3][1] ~= nil, true,
    "Upper upward deletion continuation should include the origin row to avoid a broken corner")
  assert_eq(active_bars[3] == nil or active_bars[3][2] == nil, true,
    "Lower upward deletion route should not draw its outer rail on the triangle row")
  assert_eq(active_bars[7] ~= nil and active_bars[7][2] ~= nil, true,
    "Lower upward deletion route should terminate on its origin row")
end

-- Test Suite 4k: Multiple route tails can share one display row
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 11,
      top = 11,
      display_start_row = 18,
      triangle_display_row = 18,
      lane = 2,
    },
    {
      kind = "delete",
      origin_display_row = 45,
      top = 45,
      display_start_row = 17,
      triangle_display_row = 17,
      lane = 3,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 24,
    rail_spacing = 1,
    sidecar_numbers = true,
  })
  local row_tails = underlines.tail_underlines[17] and underlines.tail_underlines[17].__items or {}
  local saw_add = false
  local saw_delete = false
  for _, tail in ipairs(row_tails) do
    saw_add = saw_add or tail.kind == "add"
    saw_delete = saw_delete or tail.kind == "delete"
  end

  assert_eq(#row_tails, 2, "Shared tail row should retain both route underlines")
  assert_eq(saw_add, true, "Shared tail row should retain the add route underline")
  assert_eq(saw_delete, true, "Shared tail row should retain the delete route underline")
end

-- Test Suite 4l: Change endpoints do not cross nearby deletion rails
do
  local change_group = {}
  local delete_group = {}
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 2,
      top = 2,
      display_start_row = 6,
      triangle_display_row = 6,
      route_group = delete_group,
    },
    {
      kind = "change",
      route_group = change_group,
      viewport_change_links = {
        {
          from_side = "right",
          from_row = 1,
          from_glyph = "◢",
          from_visible = true,
          to_side = "left",
          to_row = 3,
          to_glyph = "◤",
          to_visible = true,
        },
      },
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end

  assert_eq(by_group[change_group].lane < by_group[delete_group].lane, true,
    "Visible change endpoint should not underline through the nearby deletion rail")
end

-- Test Suite 5: No visual collisions between bars
-- Verifies different lanes have different column positions
do
  local glyph_base = 14  -- Example value
  local rail_spacing = 1

  -- Test lane_col returns different values for different lanes
  local col1 = paths_mod.lane_col(1, glyph_base, rail_spacing)
  local col2 = paths_mod.lane_col(2, glyph_base, rail_spacing)
  local col3 = paths_mod.lane_col(3, glyph_base, rail_spacing)

  assert_eq(col1 ~= col2, true, "Lane 1 and 2 should have different columns")
  assert_eq(col2 ~= col3, true, "Lane 2 and 3 should have different columns")
  assert_eq(col1 > col2, true, "Lane 1 should be further right (higher col) than lane 2")
  assert_eq(col2 > col3, true, "Lane 2 should be further right than lane 3")

  -- Test with actual paths - verify no collisions on any row
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, _ = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)

  for row, lanes_at_row in pairs(active_bars) do
    local cols_used = {}
    for lane, _ in pairs(lanes_at_row) do
      if type(lane) == "number" then
        local col = paths_mod.lane_col(lane, glyph_base, rail_spacing)
        assert_eq(cols_used[col] == nil, true,
          "Collision at row " .. row .. " col " .. col .. " (lane " .. lane .. ")")
        cols_used[col] = true
      end
    end
  end
end

-- Test Suite 6: Underline endpoint calculation
-- Verifies underlines are within valid bounds
do
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, _ = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)

  local layout = {
    left_number_width = 3,
    connector_core_width = 12,
    rail_spacing = 1,
  }

  local underlines = paths_mod.compute_underlines(paths, active_bars, layout)

  -- Verify bar columns are within connector bounds
  for origin_row, bar_col in pairs(underlines.origin_bar_cols) do
    assert_eq(bar_col >= layout.left_number_width, true,
      "Bar col at row " .. origin_row .. " should be >= left_number_width")
    assert_eq(bar_col < layout.left_number_width + layout.connector_core_width, true,
      "Bar col at row " .. origin_row .. " should be < connector end")
  end

  -- Verify tail underlines exist for paths with bars
  for tail_row, tail_info in pairs(underlines.tail_underlines) do
    assert_eq(tail_info.bar_col ~= nil, true, "Tail underline at row " .. tail_row .. " should have bar_col")
    assert_eq(tail_info.triangle_col ~= nil, true, "Tail underline at row " .. tail_row .. " should have triangle_col")
    assert_eq(tail_info.kind ~= nil, true, "Tail underline at row " .. tail_row .. " should have kind")
  end
end

-- Test Suite 7: Simple additions (pure_additions case)
do
  local left = read_file(root .. "/tests/files/left_additions.txt")
  local right = read_file(root .. "/tests/files/right_additions.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (simple additions)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  -- Count addition paths
  local add_paths = 0
  for _, p in ipairs(paths) do
    if p.kind == "add" then
      add_paths = add_paths + 1
    end
  end

  -- Should have multiple addition blocks
  assert_eq(add_paths >= 1, true, "Should have at least 1 addition path")

  -- Verify origin markers in line_meta
  local origin_count = 0
  for _, meta in ipairs(v.line_meta) do
    if meta.origin == "add" then
      origin_count = origin_count + 1
    end
  end
  assert_eq(origin_count >= 1, true, "Should have at least 1 origin row marked")

  local by_right_start = {}
  for _, p in ipairs(paths) do
    if p.kind == "add" then
      by_right_start[p.start_right_line] = p
    end
  end
  assert_eq(by_right_start[3].origin_display_row, 2,
    "First addition should originate from compact left row 2")
  assert_eq(by_right_start[7].origin_display_row, 4,
    "Second addition should originate from compact left row 4")
  assert_eq(by_right_start[11].origin_display_row, 5,
    "Third addition should originate from compact left row 5")
  assert_eq(by_right_start[11].display_start_row, 11,
    "Addition triangle should use compact right target row")

  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local projected = fake_session:project_paths_for_toplines(paths, 1, 1, 40, 40)
  local plan = paths_mod.plan_routes(projected, {
    connector_core_width = 12,
    viewport_topline = 1,
    viewport_height = 40,
  })
  assert_eq(plan.success, true, "Simple additions should produce a planned route")

  local routes_by_origin = {}
  for _, route in ipairs(plan.routes or {}) do
    if route.kind == "add" and route.path and route.path.origin_display_row then
      routes_by_origin[route.path.origin_display_row] = route
    end
  end

  local function count_segments(route, segment_type)
    local count = 0
    for _, segment in ipairs(route.segments or {}) do
      if segment.type == segment_type then
        count = count + 1
      end
    end
    return count
  end

  assert_eq(count_segments(routes_by_origin[2], "horizontal"), 1,
    "Adjacent top addition should be a single straight connector underline")
  assert_eq(count_segments(routes_by_origin[2], "vertical"), 0,
    "Adjacent top addition should not introduce a connector pipe")
  assert_eq(routes_by_origin[2].segments[1].row, 2,
    "Adjacent top addition should connect along the bottom edge of its origin row")
  assert_eq(routes_by_origin[2].segments[1].start_col, 0,
    "Adjacent top addition should start at the connector core left edge")
  assert_eq(routes_by_origin[2].segments[1].end_col, 11,
    "Adjacent top addition should reach the right transition edge")
  assert_eq(count_segments(routes_by_origin[5], "horizontal"), 2,
    "Lower addition should keep both source and target horizontal segments")
  assert_eq(count_segments(routes_by_origin[5], "vertical"), 1,
    "Lower addition should connect those horizontals with one vertical pipe")
  assert_eq(routes_by_origin[4].rail_col > routes_by_origin[5].rail_col, true,
    "Middle addition should step outward so the lower addition keeps its source bend")
end

-- Test Suite 8: Simple deletions (pure_deletions case)
do
  local left = read_file(root .. "/tests/files/left_deletions.txt")
  local right = read_file(root .. "/tests/files/right_deletions.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (simple deletions)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)
  local underlines = paths_mod.compute_underlines(paths, active_bars, {
    left_number_width = 3,
    connector_core_width = 12,
    rail_spacing = 1,
  })

  local by_start = {}
  for _, p in ipairs(paths) do
    if p.kind == "delete" then
      by_start[p.start_row] = p
    end
  end

  assert_eq(by_start[3] ~= nil, true, "First deletion path should start at left line 3")
  assert_eq(by_start[3].end_row, 5, "First deletion path should end at left line 5")
  assert_eq(by_start[3].origin_right_line, 2, "First deletion origin should be right line 2")

  assert_eq(by_start[8] ~= nil, true, "Second deletion path should start at left line 8")
  assert_eq(by_start[8].end_row, 9, "Second deletion path should end at left line 9")
  assert_eq(by_start[8].origin_right_line, 4, "Second deletion origin should be right line 4")

  for row = 5, 7 do
    assert_eq(active_bars[row] ~= nil, true, "Second deletion should have a bar at row " .. row)
    assert_eq(active_bars[row][by_start[8].lane] ~= nil, true,
      "Second deletion bar should use its assigned lane at row " .. row)
  end

  assert_eq(underlines.delete_origin_right_lines[2] ~= nil, true,
    "First delete origin should be tracked by right line")
  assert_eq(underlines.delete_origin_right_lines[4] ~= nil, true,
    "Second delete origin should be tracked by right line")
  assert_eq(underlines.tail_underlines[7] ~= nil, true,
    "Second deletion should have a tail underline before its triangle")
  assert_eq(underlines.tail_underlines[7].triangle_col, 3,
    "Pure delete tail should start at the compact left-side delete wedge")
  assert_eq(underlines.tail_underlines[7].bar_col > underlines.tail_underlines[7].triangle_col, true,
    "Delete tail should connect from the left-side wedge toward the route rail")
  local sidecar_underlines = paths_mod.compute_underlines(paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })
  assert_eq(sidecar_underlines.tail_underlines[7].triangle_col, 0,
    "Sidecar delete tail should start at connector-pane column 0 adjacent to the left number pane")
  assert_eq(sidecar_underlines.tail_underlines[7].bar_col, 1,
    "Sidecar delete rail should leave one connector cell for the underscore before the pipe")
  assert_eq(sidecar_underlines.delete_origin_right_lines[4].underline_start_after, 1,
    "Sidecar delete origin underline should start after the rail column")
  assert_eq(by_start[8].origin_display_row, 4,
    "Second deletion should originate from compact right row 4")
  assert_eq(by_start[8].display_start_row, 8,
    "Second deletion triangle should use compact left target row 8")
end

-- Test Suite 9: Mixed changes + deletions + additions in one file
do
  local left = read_file(root .. "/tests/files/left_mixed.txt")
  local right = read_file(root .. "/tests/files/right_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (mixed)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)
  local underlines = paths_mod.compute_underlines(paths, active_bars, {
    left_number_width = 3,
    connector_core_width = 12,
    rail_spacing = 1,
  })

  local function find_meta(predicate)
    for idx, m in ipairs(v.line_meta) do
      if predicate(m) then
        return idx, m
      end
    end
    return nil, nil
  end

  -- Change block 1: left 3/4 vs right 3/4 should be change
  do
    local _, m3 = find_meta(function(m) return m.left_line == 3 and m.right_line == 3 end)
    local _, m4 = find_meta(function(m) return m.left_line == 4 and m.right_line == 4 end)
    assert_eq(m3 and m3.kind or nil, "change", "Expected line 3 to be a change")
    assert_eq(m4 and m4.kind or nil, "change", "Expected line 4 to be a change")
  end

  -- Deletion: left line 6 is deleted
  do
    local _, md = find_meta(function(m) return m.left_line == 6 end)
    assert_eq(md and md.kind or nil, "delete", "Expected left line 6 to be delete")
  end

  -- Additions: right lines 8/9 are added (Added line 1/2)
  local idx_a8, ma8 = find_meta(function(m) return m.right_line == 8 end)
  local idx_a9, ma9 = find_meta(function(m) return m.right_line == 9 end)
  assert_eq(ma8 and ma8.kind or nil, "add", "Expected right line 8 to be add")
  assert_eq(ma9 and ma9.kind or nil, "add", "Expected right line 9 to be add")

  -- Add rows produced inside change hunks must not carry change connector glyphs
  do
    local c8 = idx_a8 and v.connectors[idx_a8] or nil
    local c9 = idx_a9 and v.connectors[idx_a9] or nil
    assert_eq(c8 and c8:match("^%s*$") ~= nil or false, true, "Expected connector for added line 1 to be spaces")
    assert_eq(c9 and c9:match("^%s*$") ~= nil or false, true, "Expected connector for added line 2 to be spaces")
  end

  -- Mixed replacement row should remain a change with a separate added suffix.
  do
    local spans = diff.changed_spans("Original text here", "Modified text here with extra content")
    assert_eq(spans.add_start, 19, "Mixed replacement should split added suffix after replacement text")
    assert_eq(#spans.right_changes, 1, "Mixed replacement should keep a right-side change span")
    assert_eq(spans.right_changes[1][1], 1, "Mixed replacement change span should start at first column")
    assert_eq(spans.right_changes[1][2], 8, "Mixed replacement emphasis should cover only the changed word")
  end

  -- Paths should include both an add path (for Added line 1/2) and a delete path
  do
    local found_add = false
    local found_delete = false
    local found_mixed_change = false
    for _, p in ipairs(paths) do
      if p.kind == "add" and p.start_row == 8 and p.end_row == 9 then
        found_add = true
        assert_eq(p.origin_left_line, 8, "Expected add origin to be left line 8")
        assert_eq(p.embedded_in_change, true, "Expected adjacent add path to be embedded in change envelope")
      end
      if p.kind == "delete" and p.start_row == 6 and p.end_row == 6 then
        found_delete = true
        assert_eq(p.origin_right_line, 5, "Expected delete origin to be right line 5")
      end
      if p.kind == "change" and p.mixed_add then
        found_mixed_change = true
        assert_eq(p.start_left_index, 8, "Mixed change envelope should start at compact left row 8")
        assert_eq(p.start_right_index, 7, "Mixed change envelope should start at compact right row 7")
        assert_eq(p.end_right_index, 9, "Mixed change envelope should include adjacent right add rows")
      end
    end
    assert_eq(found_add, true, "Expected to find an add path for right lines 8-9")
    assert_eq(found_delete, true, "Expected to find a delete path for left line 6")
    assert_eq(found_mixed_change, true, "Expected mixed change envelope for adjacent change+add hunks")
    assert_eq(underlines.delete_origin_right_lines[5].glyph_col, 3,
      "Mixed delete wedge should stay compact after the left line number")
  end
end

-- Test Suite 10: Comprehensive routes include compact-row offset changes
do
  local left = read_file(root .. "/tests/files/left_comprehensive.txt")
  local right = read_file(root .. "/tests/files/right_comprehensive.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (comprehensive)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  local saw_offset_change = false
  local saw_add_with_different_meta_and_visual_rows = false
  local saw_delete_with_right_origin = false

  for _, p in ipairs(paths) do
    if p.kind == "change" and p.offset then
      saw_offset_change = true
      assert_eq(p.display_start_row ~= nil, true, "Offset change should have display_start_row")
      assert_eq(p.display_end_row ~= nil, true, "Offset change should have display_end_row")
    elseif p.kind == "add" and p.meta_start_row ~= p.display_start_row then
      saw_add_with_different_meta_and_visual_rows = true
      assert_eq(p.origin_side, "left", "Add route origin side")
      assert_eq(p.target_side, "right", "Add route target side")
    elseif p.kind == "delete" and p.origin_right_line then
      saw_delete_with_right_origin = true
      assert_eq(p.origin_side, "right", "Delete route origin side")
      assert_eq(p.target_side, "left", "Delete route target side")
    end
  end

  assert_eq(saw_offset_change, true, "Comprehensive case should include an offset change route")
  assert_eq(saw_add_with_different_meta_and_visual_rows, true,
    "Comprehensive case should prove routes use compact visual rows, not metadata rows")
  assert_eq(saw_delete_with_right_origin, true,
    "Comprehensive case should include a delete route with right-side origin")
end

-- Test Suite 11: Independent viewport projection uses each side's topline
do
  local left = read_file(root .. "/tests/files/left_mixed.txt")
  local right = read_file(root .. "/tests/files/right_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (viewport projection mixed)")

  local v = view.build(left, right, hunks, config)

  assert_eq(#v.line_meta, 12, "Mixed aligned connector model should have 12 visual rows")
  assert_eq(#v.left, 10, "Mixed left compact buffer should have 10 real rows")
  assert_eq(#v.right, 11, "Mixed right compact buffer should have 11 real rows")

  local left_by_index = {}
  local right_by_index = {}
  for _, meta in ipairs(v.line_meta) do
    if meta.left_index then
      left_by_index[meta.left_index] = meta
    end
    if meta.right_index then
      right_by_index[meta.right_index] = meta
    end
  end

  local left_topline = 3
  local right_topline = 7
  local screen_row = 2
  local left_meta = left_by_index[left_topline + screen_row - 1]
  local right_meta = right_by_index[right_topline + screen_row - 1]

  assert_eq(left_meta.left_line, 4, "Left number projection follows left topline")
  assert_eq(right_meta.right_line, 8, "Right number projection follows right topline")
  assert_eq(left_meta.left_line ~= right_meta.right_line, true,
    "Independent projection must not force matching line numbers on a screen row")
end

-- Test Suite 12: Scroll fixtures expose long add/delete/mixed regions
do
  local fixtures = {
    {
      name = "scroll additions",
      left = root .. "/tests/files/left_scroll_additions.txt",
      right = root .. "/tests/files/right_scroll_additions.txt",
      expected_kind = "add",
    },
    {
      name = "scroll deletions",
      left = root .. "/tests/files/left_scroll_deletions.txt",
      right = root .. "/tests/files/right_scroll_deletions.txt",
      expected_kind = "delete",
    },
    {
      name = "scroll mixed",
      left = root .. "/tests/files/left_scroll_mixed.txt",
      right = root .. "/tests/files/right_scroll_mixed.txt",
      expected_kind = "mixed",
    },
    {
      name = "scroll changes",
      left = root .. "/tests/files/left_scroll_changes.txt",
      right = root .. "/tests/files/right_scroll_changes.txt",
      expected_kind = "change",
    },
  }

  for _, fixture in ipairs(fixtures) do
    local left = read_file(fixture.left)
    local right = read_file(fixture.right)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, "diff error (" .. fixture.name .. ")")

    local v = view.build(left, right, hunks, config)
    local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
    local longest = 0
    local found = false
    for _, p in ipairs(paths) do
      if fixture.expected_kind == "mixed" then
        if p.kind == "change" and p.mixed_add then
          found = true
          longest = math.max(longest, (p.end_right_index or 0) - (p.start_right_index or 0) + 1)
        end
      elseif fixture.expected_kind == "change" then
        if p.kind == "change" then
          found = true
          longest = math.max(longest, (p.end_left_index or 0) - (p.start_left_index or 0) + 1)
        end
      elseif p.kind == fixture.expected_kind and not p.embedded_in_change then
        found = true
        longest = math.max(longest, (p.block_display_end or 0) - (p.block_display_start or 0) + 1)
      end
    end
    assert_eq(found, true, fixture.name .. " should produce the expected route type")
    if fixture.expected_kind == "change" then
      assert_eq(longest >= 3, true, fixture.name .. " should include multiple changed rows")
    else
      assert_eq(longest >= 6, true, fixture.name .. " should include a scrollable route")
    end
  end
end

-- Test Suite 12b: Dense mixed fixture forces stable multi-lane width
do
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense mixed)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)

  local counts = { add = 0, delete = 0, change = 0 }
  local saw_mixed_change = false
  for _, p in ipairs(paths) do
    counts[p.kind] = (counts[p.kind] or 0) + 1
    if p.kind == "change" and p.mixed_add then
      saw_mixed_change = true
    end
  end
  assert_eq(counts.add >= 3, true, "Dense mixed fixture should include multiple add routes")
  assert_eq(counts.delete >= 2, true, "Dense mixed fixture should include multiple delete routes")
  assert_eq(counts.change >= 2, true, "Dense mixed fixture should include multiple change routes")
  assert_eq(saw_mixed_change, true, "Dense mixed fixture should include a mixed change/add envelope")

  local projected = fake_session:project_paths_for_toplines(paths, 1, 49, 14, 14)
  local max_lane = paths_mod.max_lane(projected)
  assert_eq(max_lane, 7, "Dense mixed conflict viewport should reserve seven physical lanes")
  assert_eq(paths_mod.required_connector_core_width(max_lane, 12), 22,
    "Seven-lane conflict should expand connector core width from 12 to 22")
  assert_eq(paths_mod.required_connector_core_width(3, 12), 12,
    "Three-lane routes should still fit the default connector width")
  assert_eq(paths_mod.required_connector_core_width(1, 12), 12,
    "Single-lane routes should keep the default connector width")

  local active_bars = paths_mod.compute_active_bars(projected)
  local function row_has_bar(row, kind, lane, origin)
    local row_bars = active_bars[row]
    if not row_bars or not row_bars.__items then
      return false
    end
    for _, item in ipairs(row_bars.__items) do
      if item.lane == lane
          and item.path.kind == kind
          and item.path.origin_display_row == origin then
        return true
      end
    end
    return false
  end
  assert_eq(row_has_bar(1, "add", 1, 11), true,
    "Clipped add route from origin 11 should enter from the top edge")
  assert_eq(row_has_bar(9, "add", 1, 11), true,
    "Clipped add route from origin 11 should not be overwritten by same-lane delete/add routes")
  assert_eq(row_has_bar(9, "delete", 7, 5), true,
    "Dense conflict should keep the lower deletion route active alongside add routes")
end

-- Test Suite 12c: Planned connector routes are two-turn, collision-free shapes
do
  local function assert_clean_plan(plan, label)
    assert_eq(plan.success, true, label .. " should produce a solvable route plan")

    local occupied = {}
    local function check_cell(row, col, group, row_margin)
      occupied[row] = occupied[row] or {}
      row_margin = row_margin or 0
      for check_row = row - row_margin, row + row_margin do
        local row_occupied = occupied[check_row]
        if row_occupied then
          for check_col = col - 1, col + 1 do
            local owner = row_occupied[check_col]
            assert_eq(owner == nil or owner == group, true,
              label .. " should not crowd connector cells at row " .. tostring(row) .. ", col " .. tostring(col))
          end
        end
      end
      occupied[row][col] = group
    end

    for _, route in ipairs(plan.routes or {}) do
      local horizontal_count = 0
      local vertical_count = 0
      for _, segment in ipairs(route.segments or {}) do
        if segment.type == "horizontal" then
          if not segment.continuation then
            horizontal_count = horizontal_count + 1
          end
          for col = segment.start_col, segment.end_col do
            check_cell(segment.row, col, route.group)
          end
        elseif segment.type == "vertical" then
          vertical_count = vertical_count + 1
          for row = segment.start_row, segment.end_row do
            check_cell(row, segment.col, route.group)
          end
        end
      end
      assert_eq(horizontal_count <= 2, true, label .. " route should have at most two horizontal segments")
      assert_eq(vertical_count <= 1, true, label .. " route should have at most one vertical segment")
    end
  end

  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense mixed planner)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local projections = {
    { 1, 1, "dense initial" },
    { 1, 38, "dense pre-conflict" },
    { 1, 46, "dense four-route conflict" },
    { 1, 49, "dense lower-route entering" },
    { 1, 53, "dense post-conflict" },
    { 8, 46, "dense lane reuse" },
  }

  for _, projection in ipairs(projections) do
    local projected = fake_session:project_paths_for_toplines(paths, projection[1], projection[2], 14, 14)
    local width, plan = paths_mod.required_connector_core_width_for_paths(projected, 12, 24)
    assert_eq(width <= 24, true, projection[3] .. " should not require an excessive connector width")
    assert_clean_plan(plan, projection[3])
  end

  local upward = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 5,
      triangle_display_row = 1,
      route_group = {},
    },
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 6,
      triangle_display_row = 2,
      route_group = {},
    },
  }
  local upward_plan = paths_mod.plan_routes(upward, { connector_core_width = 12 })
  assert_clean_plan(upward_plan, "upward priority")
  assert_eq(upward[1].planned_rail_col < upward[2].planned_rail_col, true,
    "Top-edge upward route should take the leftmost rail")

  local downward = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 1,
      triangle_display_row = 5,
      route_group = {},
    },
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 2,
      triangle_display_row = 6,
      route_group = {},
    },
  }
  local downward_plan = paths_mod.plan_routes(downward, { connector_core_width = 12 })
  assert_clean_plan(downward_plan, "downward priority")
  assert_eq(downward[2].planned_rail_col < downward[1].planned_rail_col, true,
    "Bottom-edge downward route should take the leftmost rail")

  local overflow = {}
  local overflow_group = {}
  for i = 1, 10 do
    overflow[i] = {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 12,
      triangle_display_row = 1 - i,
      route_group = overflow_group,
    }
  end
  local overflow_plan = paths_mod.plan_routes(overflow, {
    connector_core_width = 24,
    viewport_topline = 1,
    viewport_height = 14,
  })
  assert_clean_plan(overflow_plan, "overflow cap")
  assert_eq(#overflow_plan.routes, paths_mod.MAX_VISIBLE_CONNECTOR_ROUTES,
    "Overflow planner should keep at most eight vertical routes")
  assert_eq(#overflow_plan.hidden_routes, 2,
    "Overflow planner should hide routes beyond the eight-route cap")
  assert_eq(overflow[10].overflow_hidden, true,
    "Overflow planner should hide the farthest top-docked route first")
  assert_eq(overflow[9].overflow_hidden, true,
    "Overflow planner should hide the second farthest top-docked route")
  assert_eq(overflow[1].overflow_hidden == true, false,
    "Overflow planner should keep the nearest visible route")

  assert_eq(paths_mod.required_connector_core_width(99, 12), 24,
    "Connector width should cap at the eight-route width")
end

-- Test Suite 13: Chunk navigation anchors align semantic origins and targets
do
  local function anchors_for(left, right)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, "diff error (navigation anchors)")
    local v = view.build(left, right, hunks, config)
    local session = { view = v }
    return Session.chunk_navigation_anchors(session, v.chunks[1])
  end

  local left_anchor, right_anchor = anchors_for(
    { "alpha", "bravo", "charlie" },
    { "alpha", "bravo", "added", "charlie" }
  )
  assert_eq(left_anchor, 2, "Add navigation should anchor left on the origin row")
  assert_eq(right_anchor, 2, "Add navigation should anchor right on the row above the insertion")

  left_anchor, right_anchor = anchors_for(
    { "alpha", "bravo", "deleted", "charlie" },
    { "alpha", "bravo", "charlie" }
  )
  assert_eq(left_anchor, 3, "Delete navigation should anchor left on the first deleted row")
  assert_eq(right_anchor, 2, "Delete navigation should anchor right on the origin row")

  left_anchor, right_anchor = anchors_for(
    { "alpha", "old", "charlie" },
    { "alpha", "new", "charlie" }
  )
  assert_eq(left_anchor, 2, "Change navigation should anchor left on the first changed row")
  assert_eq(right_anchor, 2, "Change navigation should anchor right on the first changed row")

  left_anchor, right_anchor = anchors_for(
    { "alpha", "old one", "old two", "charlie" },
    { "alpha", "new one", "new two", "added", "charlie" }
  )
  assert_eq(left_anchor, 2, "Mixed navigation should anchor left on the first changed row")
  assert_eq(right_anchor, 2, "Mixed navigation should anchor right on the first changed row")
end

-- Test Suite 14: Theme-derived highlights preserve existing color semantics
do
  local function set_palette(groups)
    for name, opts in pairs(groups) do
      vim.api.nvim_set_hl(0, name, opts)
    end
  end

  set_palette({
    Normal = { fg = 0xE0E2EA, bg = 0x14161B },
    LineNr = { fg = 0x4F5258 },
    Comment = { fg = 0x9B9EA4 },
    DiffAdd = { fg = 0xEEF1F8, bg = 0x005523 },
    DiffDelete = { fg = 0xFFC0B9 },
    DiffChange = { fg = 0xEEF1F8, bg = 0x4F5258 },
    DiffText = { fg = 0xEEF1F8, bg = 0x007373 },
  })
  highlights.apply(config_mod.defaults())

  assert_eq(get_hl("DiffBanditAdd").bg, 0x005523,
    "Default-like palette should keep usable DiffAdd background")
  assert_eq(get_hl("DiffBanditChangeLeft").bg, 0x4F5258,
    "Default-like palette should keep usable DiffChange background")
  assert_ne(get_hl("DiffBanditDelete").bg, 0xD3D3D3,
    "Default-like palette should not fall back to light delete gray")
  assert_eq(luminance(get_hl("DiffBanditDelete").bg) < 0.5, true,
    "Default-like palette should synthesize a dark delete background")
  assert_ne(get_hl("DiffBanditChangeEmphasis").bg, get_hl("DiffBanditChangeLeft").bg,
    "Change emphasis should remain distinct from the base change background")
  assert_ne(get_hl("DiffBanditChangeEmphasis").bg, 0x007373,
    "Change emphasis should be adaptive instead of using DiffText directly")

  set_palette({
    Normal = { fg = 0x101010, bg = 0xFFFFFF },
    LineNr = { fg = 0x808080 },
    Comment = { fg = 0x707070 },
    DiffAdd = { fg = 0x006B2B },
    DiffDelete = { fg = 0xB00020 },
    DiffChange = { bg = 0xDDEBFF },
  })
  highlights.apply(config_mod.defaults())
  assert_eq(get_hl("DiffBanditAdd").bg ~= nil, true,
    "Light palette should synthesize add background from foreground when needed")
  assert_eq(get_hl("DiffBanditDelete").bg ~= nil, true,
    "Light palette should synthesize delete background from foreground when needed")
  assert_eq(luminance(get_hl("DiffBanditChangeEmphasis").bg) < luminance(get_hl("DiffBanditChangeLeft").bg), true,
    "Light palette change emphasis should darken the change background")

  set_palette({
    Normal = { fg = 0xEEEEEE, bg = 0x101010 },
    LineNr = { fg = 0x777777 },
    Comment = { fg = 0x909090 },
    DiffAdd = { bg = 0x123D2B },
    DiffDelete = { bg = 0x4A2426 },
    DiffChange = { bg = 0x253344 },
  })
  highlights.apply(config_mod.defaults())
  assert_eq(luminance(get_hl("DiffBanditChangeEmphasis").bg) > luminance(get_hl("DiffBanditChangeLeft").bg), true,
    "Dark palette change emphasis should lighten the change background")

  highlights.apply(config_mod.apply({
    ui = {
      theme = {
        colors = {
          add = 0x112233,
          delete = "#445566",
          change = 0x778899,
          change_emphasis = 0xABCDEF,
        },
      },
    },
  }))
  assert_eq(get_hl("DiffBanditAdd").bg, 0x112233,
    "Add override should set the add source background")
  assert_eq(get_hl("DiffBanditConnectorAddLine").fg, 0x112233,
    "Add override should propagate to add connector rails")
  assert_eq(get_hl("DiffBanditDelete").bg, 0x445566,
    "Delete override should accept hex strings")
  assert_eq(get_hl("DiffBanditDeleteRightSeparator").sp, 0x445566,
    "Delete override should propagate to delete underlines")
  assert_eq(get_hl("DiffBanditChangeRight").bg, 0x778899,
    "Change override should set the change source background")
  assert_eq(get_hl("DiffBanditConnectorExpansionChange").fg, 0x778899,
    "Change override should propagate to change wedges")
  assert_eq(get_hl("DiffBanditChangeEmphasis").bg, 0xABCDEF,
    "Change emphasis override should win over adaptive derivation")

  highlights.apply(config_mod.apply({
    ui = {
      theme = {
        highlights = {
          DiffBanditConnectorAddLine = { fg = 0x010203, bg = 0x040506 },
        },
      },
    },
  }))
  assert_eq(get_hl("DiffBanditConnectorAddLine").fg, 0x010203,
    "Per-group highlight override should apply last")
  assert_eq(get_hl("DiffBanditConnectorAddLine").bg, 0x040506,
    "Per-group highlight override should include background")

  local diffbandit = require("diffbandit")
  set_palette({
    Normal = { fg = 0xEEEEEE, bg = 0x101010 },
    LineNr = { fg = 0x777777 },
    Comment = { fg = 0x909090 },
    DiffAdd = { bg = 0x203040 },
    DiffDelete = { bg = 0x402020 },
    DiffChange = { bg = 0x202040 },
  })
  diffbandit.setup({})
  assert_eq(get_hl("DiffBanditAdd").bg, 0x203040,
    "Setup should apply the current add color")
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x304050 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(get_hl("DiffBanditAdd").bg, 0x304050,
    "ColorScheme refresh should rederive add color")
end

vim.api.nvim_out_write("OK\n")
vim.cmd("qa")
