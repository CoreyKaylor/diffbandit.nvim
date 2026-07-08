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

-- Test Suite 4m: Visible local routes stay planned before clipped continuations
do
  local long_delete = {}
  local long_change = {}
  local middle_delete = {}
  local middle_change = {}
  local lower_delete = {}
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 40,
      triangle_display_row = 61,
      target_start_index = 61,
      route_group = long_delete,
      hide_triangle = true,
      suppress_tail = true,
    },
    {
      kind = "change",
      route_group = long_change,
      viewport_change_links = {
        {
          from_side = "right",
          from_row = 51,
          from_glyph = "◢",
          from_visible = true,
          to_side = "left",
          to_row = 61,
          to_glyph = "◤",
          to_visible = false,
          underline_row = 51,
        },
      },
    },
    {
      kind = "delete",
      origin_display_row = 8,
      triangle_display_row = 31,
      target_start_index = 31,
      route_group = middle_delete,
    },
    {
      kind = "change",
      route_group = middle_change,
      viewport_change_links = {
        {
          from_side = "right",
          from_row = 9,
          from_glyph = "◢",
          from_visible = true,
          to_side = "left",
          to_row = 39,
          to_glyph = "◤",
          to_visible = true,
        },
      },
    },
    {
      kind = "delete",
      origin_display_row = 9,
      triangle_display_row = 40,
      target_start_index = 40,
      route_group = lower_delete,
    },
  }

  local plan = paths_mod.plan_routes(projected_paths, {
    connector_core_width = 12,
    viewport_topline = 1,
    viewport_height = 60,
    max_route_backtrack_steps = 500,
  })
  assert_eq(plan.strategy, "greedy",
    "Visible adjacent route layout should not require backtracking during render")

  local function route_for(group)
    for _, route in ipairs(plan.routes or {}) do
      if route.group == group then
        return route
      end
    end
    return nil
  end

  for _, group in ipairs({ middle_delete, middle_change, lower_delete }) do
    local route = route_for(group)
    assert_eq(route ~= nil, true, "Visible adjacent route should be retained")
    assert_eq(route.overflow_hidden == true, false, "Visible adjacent route should not be hidden by a clipped route")
    assert_eq(#(route.segments or {}) > 0, true, "Visible adjacent route should keep connector geometry")
  end
end

-- Test Suite 4n: Offscreen-below change links anchor on the visible endpoint row
do
  local fake_session = setmetatable({ view = {}, left = { lines = {} }, right = { lines = {} } }, Session)
  local projected = fake_session:project_paths_for_toplines({
    {
      kind = "change",
      start_left_index = 117,
      end_left_index = 117,
      start_right_index = 51,
      end_right_index = 51,
      route_group = {},
    },
  }, 1, 1, 60, 60)

  local link = projected[1].viewport_change_links[1]
  assert_eq(link.from_row, 51, "Visible right change wedge should stay on right row 51")
  assert_eq(link.underline_row, 51, "Offscreen-below change connector should anchor at the wedge row")

  local plan = paths_mod.plan_routes(projected, {
    connector_core_width = 12,
    viewport_topline = 1,
    viewport_height = 60,
  })
  assert_eq(plan.routes[1].source_row, 51,
    "Offscreen-below change route should connect from the visible endpoint row")
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

  -- Paths should include both an add path (for Added line 1/2) and a delete path.
  -- The change (left 8 -> right 7) and the following add (right 8-9) abut, so
  -- diff.compute_hunks merges them into one chunk: the add segment is absorbed
  -- into its chunk's change band instead of routing standalone.
  do
    local found_add = false
    local found_delete = false
    local mixed_change = false
    for _, p in ipairs(paths) do
      if p.kind == "add" and p.start_row == 8 and p.end_row == 9 then
        found_add = true
        assert_eq(p.origin_left_line, 8, "Expected add origin to be left line 8")
        assert_eq(p.embedded_in_change, true,
          "Add rows inside a merged chunk should absorb into its change band")
      end
      if p.kind == "delete" and p.start_row == 6 and p.end_row == 6 then
        found_delete = true
        assert_eq(p.origin_right_line, 5, "Expected delete origin to be right line 5")
      end
      if p.kind == "change" then
        if p.mixed_add then
          mixed_change = true
          assert_eq(p.start_left_index, 8, "Merged change band should start at left row 8")
          assert_eq(p.end_right_index, 9, "Merged change band should extend to absorbed right row 9")
        end
      end
    end
    assert_eq(found_add, true, "Expected to find an add path for right lines 8-9")
    assert_eq(found_delete, true, "Expected to find a delete path for left line 6")
    assert_eq(mixed_change, true, "Expected the merged chunk's change band to absorb the add rows")
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
        -- Abutting change+add hunks merge into one chunk: the add block is
        -- absorbed into the chunk's change band, which spans the added rows.
        if p.kind == "change" and p.mixed_add then
          found = true
          longest = math.max(longest, (p.block_display_end or 0) - (p.block_display_start or 0) + 1)
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
  local saw_absorbed_add = false
  for _, p in ipairs(paths) do
    counts[p.kind] = (counts[p.kind] or 0) + 1
    if p.kind == "add" and p.origin_kind == "change" and p.embedded_in_change then
      saw_absorbed_add = true
    end
  end
  assert_eq(counts.add >= 3, true, "Dense mixed fixture should include multiple add routes")
  assert_eq(counts.delete >= 2, true, "Dense mixed fixture should include multiple delete routes")
  assert_eq(counts.change >= 2, true, "Dense mixed fixture should include multiple change routes")
  assert_eq(saw_absorbed_add, true,
    "Dense mixed fixture should absorb the change-adjacent add into its merged chunk's band")

  local projected = fake_session:project_paths_for_toplines(paths, 1, 49, 14, 14)
  local max_lane = paths_mod.max_lane(projected)
  assert_eq(max_lane, 7, "Dense mixed conflict viewport should reserve seven physical lanes")
  local required_width, required_plan = paths_mod.required_connector_core_width_for_paths(projected, 3, 24, {
    viewport_topline = 1,
    viewport_height = 14,
    max_route_backtrack_steps = 500,
  })
  assert_eq(required_width, 14,
    "Seven-lane dense conflict should use the smallest solvable compact connector width")
  assert_eq(required_plan.success, true, "Seven-lane dense conflict should remain collision-free")

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

-- Shared invariant checker for planned connector routes: cell exclusivity
-- (mirroring the planner's endpoint-sharing rule), in-bounds geometry, route
-- shape, visible routes carrying segments, and routes/hidden bookkeeping.
local function assert_plan_invariants(plan, layout, label, opts)
  opts = opts or {}
  if not opts.success_optional then
    local expect_success = opts.expect_success
    if expect_success == nil then
      expect_success = true
    end
    assert_eq(plan.success, expect_success, label .. " plan success flag")
  end

  local function endpoint_at(route, side, row)
    return (route.source_side == side and route.source_row == row and route.source_visible ~= false)
      or (route.target_side == side and route.target_row == row and route.target_visible ~= false)
  end

  -- Mirrors routes_can_share_cell: edge-docked endpoints always start at the
  -- pane edge, so two same-row endpoints can never be separated by widening;
  -- stacking them (with deterministic paint order) is the only solvable
  -- layout and is deliberately legal. A "both"-side horizontal is itself
  -- pinned to its row and may stack with any route ending on that row.
  local function endpoint_on_row(route, row)
    return endpoint_at(route, "left", row) or endpoint_at(route, "right", row)
  end
  local function may_share(route, owner, row, cell_type, side)
    if owner == route or owner.group == route.group then
      return true
    end
    if cell_type ~= "horizontal" or not side then
      return false
    end
    if side == "both" then
      return endpoint_on_row(route, row) and endpoint_on_row(owner, row)
    end
    return endpoint_at(route, side, row) and endpoint_at(owner, side, row)
  end

  local core_width = layout.connector_core_width
  local occupied = {}
  local function check_cell(row, col, route, cell_type, side)
    -- Rows outside the buffer are deliberately allowed: offscreen
    -- continuations emit a stub one row past the top edge, and projected
    -- origins keep their true (possibly negative) rows because every
    -- projected route anchors somewhere visible -- offscreen span overlap
    -- implies visible overlap, so the extra rows add no collision risk,
    -- while clamping them collapses dock ordering and degrades placement.
    -- Rendering clips anything outside the buffer.
    assert_eq(col >= 0 and col <= core_width - 1, true,
      label .. " cell col should stay within the connector core (col " .. tostring(col) .. ")")
    occupied[row] = occupied[row] or {}
    for check_col = col - 1, col + 1 do
      local owner = occupied[row][check_col]
      assert_eq(owner == nil or may_share(route, owner, row, cell_type, side), true,
        label .. " should not crowd connector cells at row " .. tostring(row) .. ", col " .. tostring(col))
    end
    occupied[row][col] = route
  end

  local hidden_set = {}
  for _, route in ipairs(plan.hidden_routes or {}) do
    hidden_set[route] = true
    assert_eq(route.overflow_hidden, true,
      label .. " hidden routes should be marked overflow_hidden")
    assert_eq(route.hide_reason ~= nil, true,
      label .. " hidden routes should record why they were hidden")
  end

  for _, route in ipairs(plan.routes or {}) do
    if not opts.allow_hidden_in_routes then
      assert_eq(hidden_set[route] == nil, true,
        label .. " plan.routes and plan.hidden_routes should be disjoint")
    end
    local horizontal_count = 0
    local vertical_count = 0
    local cell_count = 0
    for _, segment in ipairs(route.segments or {}) do
      if segment.type == "horizontal" then
        if not segment.continuation then
          horizontal_count = horizontal_count + 1
        end
        for col = segment.start_col, segment.end_col do
          check_cell(segment.row, col, route, "horizontal", segment.side)
          cell_count = cell_count + 1
        end
      elseif segment.type == "vertical" then
        vertical_count = vertical_count + 1
        for row = segment.start_row, segment.end_row do
          check_cell(row, segment.col, route, "vertical", nil)
          cell_count = cell_count + 1
        end
      end
    end
    assert_eq(horizontal_count <= 2, true, label .. " route should have at most two horizontal segments")
    assert_eq(vertical_count <= 1, true, label .. " route should have at most one vertical segment")
    if not hidden_set[route] and not opts.allow_empty_visible_routes then
      assert_eq(cell_count >= 1, true,
        label .. " visible routes should draw at least one connector cell")
    end
  end
end

-- Test Suite 12c: Planned connector routes are two-turn, collision-free shapes
do
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense mixed planner)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local projections = {
    { 1, 1, 4, "dense initial" },
    { 1, 38, 10, "dense pre-conflict" },
    { 1, 46, 14, "dense four-route conflict" },
    { 1, 49, 14, "dense lower-route entering" },
    { 1, 53, 14, "dense post-conflict" },
    { 8, 46, 5, "dense lane reuse" },
  }

  for _, projection in ipairs(projections) do
    local projected = fake_session:project_paths_for_toplines(paths, projection[1], projection[2], 14, 14)
    local width, plan = paths_mod.required_connector_core_width_for_paths(projected, 3, 24, {
      viewport_topline = projection[1],
      viewport_height = 14,
      max_route_backtrack_steps = 500,
    })
    assert_eq(width, projection[3], projection[4] .. " should use its compact planned connector width")
    assert_plan_invariants(plan, { connector_core_width = width }, projection[4])
  end

  local function route_segment_counts(plan)
    local counts = { horizontal = 0, vertical = 0 }
    for _, route in ipairs(plan.routes or {}) do
      for _, segment in ipairs(route.segments or {}) do
        counts[segment.type] = (counts[segment.type] or 0) + 1
      end
    end
    return counts
  end

  local one_vertical = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 1,
      triangle_display_row = 4,
      route_group = {},
    },
  }
  local one_width, one_plan = paths_mod.required_connector_core_width_for_paths(one_vertical, 3, 24)
  local one_counts = route_segment_counts(one_plan)
  assert_eq(one_width, 3, "Single vertical route should keep the compact three-column minimum")
  assert_eq(one_counts.horizontal, 2, "Single vertical route should retain both endpoint horizontals")
  assert_eq(one_counts.vertical, 1, "Single vertical route should retain one interior rail")

  local two_vertical = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 1,
      triangle_display_row = 4,
      route_group = {},
    },
    {
      kind = "delete",
      origin_side = "right",
      target_side = "left",
      origin_display_row = 4,
      triangle_display_row = 1,
      route_group = {},
    },
  }
  local two_width, two_plan = paths_mod.required_connector_core_width_for_paths(two_vertical, 3, 24)
  assert_eq(two_width, 5, "Competing vertical routes should widen only enough to avoid collisions")
  assert_plan_invariants(two_plan, { connector_core_width = two_width }, "two compact vertical routes")

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
  assert_plan_invariants(upward_plan, { connector_core_width = 12 }, "upward priority")
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
  assert_plan_invariants(downward_plan, { connector_core_width = 12 }, "downward priority")
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
  assert_plan_invariants(overflow_plan, { connector_core_width = 24 }, "overflow cap")
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

  assert_eq(paths_mod.required_connector_core_width(99, 3), 24,
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
  assert_eq(get_hl("DiffBanditContext").fg, nil,
    "Context backgrounds should not set a foreground that masks syntax highlighting")

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
  assert_eq(get_hl("DiffBanditOverviewAdd").bg, 0x112233,
    "Add override should propagate to overview add markers")
  assert_eq(get_hl("DiffBanditConnectorAddLine").fg, 0x112233,
    "Add override should propagate to add connector rails")
  assert_eq(get_hl("DiffBanditConnectorAddLine").bold, true,
    "Connector rail glyphs should render bold by default")
  assert_eq(get_hl("DiffBanditDelete").bg, 0x445566,
    "Delete override should accept hex strings")
  assert_eq(get_hl("DiffBanditOverviewDelete").bg, 0x445566,
    "Delete override should propagate to overview delete markers")
  assert_eq(get_hl("DiffBanditDeleteRightSeparator").sp, 0x445566,
    "Delete override should propagate to delete underlines")
  assert_eq(get_hl("DiffBanditChangeRight").bg, 0x778899,
    "Change override should set the change source background")
  assert_eq(get_hl("DiffBanditOverviewChange").bg, 0x778899,
    "Change override should propagate to overview change markers")
  assert_eq(get_hl("DiffBanditConnectorExpansionChange").fg, 0x778899,
    "Change override should propagate to change wedges")
  assert_eq(get_hl("DiffBanditConnectorExpansionChange").bold, true,
    "Connector transition glyphs should render bold by default")
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

-- ==============================================================================
-- CONNECTOR HARDENING TESTS (Suite 15)
-- ==============================================================================

-- Test Suite 15a: Hunks at the very first display row keep their connectors
do
  local function project_first_row(left, right, label)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, "diff error (" .. label .. ")")
    local v = view.build(left, right, hunks, config)
    local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
    assert_eq(#paths >= 1, true, label .. " should produce at least one base path")
    local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
    return paths, fake_session:project_paths_for_toplines(paths, 1, 1, 10, 10)
  end

  -- A hunk starting at display row 1 has no origin row above it. build_paths
  -- synthesizes a same-row anchor (synthetic_origin) so the hunk still
  -- projects and routes; renderers skip origin glyphs/underlines for it.
  local function assert_first_row_routes(paths, projected, label)
    assert_eq(paths[1].origin_display_row, 1, label .. " should anchor on its own first row")
    assert_eq(paths[1].synthetic_origin, true, label .. " anchor should be flagged synthetic")
    assert_eq(#projected, 2, label .. " should project the split pair around the anchor row")
    local layout = { connector_core_width = 12 }
    local plan = paths_mod.plan_routes(projected, layout)
    assert_plan_invariants(plan, layout, label)
    assert_eq(#plan.routes >= 1, true, label .. " should plan at least one visible route")
  end

  local add_paths, add_projected = project_first_row(
    { "alpha", "beta" },
    { "new one", "new two", "alpha", "beta" },
    "insert-at-top")
  assert_first_row_routes(add_paths, add_projected, "insert-at-top")

  local delete_paths, delete_projected = project_first_row(
    { "old one", "old two", "alpha", "beta" },
    { "alpha", "beta" },
    "delete-at-top")
  assert_first_row_routes(delete_paths, delete_projected, "delete-at-top")

  local _, change_projected = project_first_row(
    { "old", "alpha" },
    { "new", "alpha" },
    "change-at-top")
  assert_eq(#change_projected >= 1, true,
    "Change hunks at the first display row should still project")
end

-- Test Suite 15b: Embedded adds merge into their own chunk's change band
do
  -- Hand-crafted hunks: the live diff config (linematch) usually splits uneven
  -- changes into separate hunks, but larger hunks bypass linematch and produce
  -- change hunks with uneven counts -- the shape that creates embedded adds.
  local left = { "ctx", "old", "tail" }
  local right = { "ctx", "new", "extra", "tail" }
  local mixed_hunks = {
    { index = 1, type = "change", left = { start = 2, count = 1 }, right = { start = 2, count = 2 } },
  }
  local v = view.build(left, right, mixed_hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  local change_path, add_path
  for _, p in ipairs(paths) do
    if p.kind == "change" then change_path = p end
    if p.kind == "add" then add_path = p end
  end
  assert_eq(add_path ~= nil, true, "Mixed change hunk should produce an embedded add path")
  assert_eq(add_path.embedded_in_change, true, "Extra right-side row should be flagged embedded")
  assert_eq(change_path.mixed_add, true, "Embedded add should merge into the change band")
  assert_eq(change_path.end_right_index, 3, "Merged change band should extend over the added row")

  -- Embedded adds are deliberately not routed on their own; the change band
  -- carries them. Pin that so an unmerged embedded add is visibly a bug.
  local solo_plan = paths_mod.plan_routes({ add_path }, { connector_core_width = 12 })
  assert_eq(#solo_plan.routes, 0, "Embedded add paths should not plan standalone routes")

  -- The merge pass must respect chunk boundaries. With zero-context adjacent
  -- hunks, an add whose origin row is the previous chunk's change row must
  -- NOT merge into that neighboring chunk's band (that would fuse two
  -- independently-stageable chunks); it falls back to normal routing instead.
  local adj_left = { "ctx", "old", "tail" }
  local adj_right = { "ctx", "new", "inserted", "tail" }
  local adjacent_hunks = {
    { index = 1, type = "change", left = { start = 2, count = 1 }, right = { start = 2, count = 1 } },
    { index = 2, type = "add", left = { start = 2, count = 0 }, right = { start = 3, count = 1 } },
  }
  local adj_view = view.build(adj_left, adj_right, adjacent_hunks, config)
  local adj_paths = paths_mod.compute_paths(adj_view.chunks, adj_view.line_meta)
  local adj_change, adj_add
  for _, p in ipairs(adj_paths) do
    if p.kind == "change" then adj_change = p end
    if p.kind == "add" then adj_add = p end
  end
  assert_eq(adj_add.chunk, 2, "Adjacent add path should belong to the second chunk")
  assert_eq(adj_add.embedded_in_change, false,
    "Cross-chunk adds should fall back to normal routing, not stay embedded")
  assert_eq(adj_change.mixed_add, nil,
    "A neighboring chunk's change band should not absorb another chunk's add")
  local adj_layout = { connector_core_width = 12 }
  local adj_plan = paths_mod.plan_routes({ adj_add }, adj_layout)
  assert_plan_invariants(adj_plan, adj_layout, "cross-chunk add")
  assert_eq(#adj_plan.routes, 1, "Cross-chunk add should plan its own visible route")
end

-- Test Suite 15c: Overflow pruning keeps the cap with fully-visible routes
do
  local function overflow_fixture()
    local group = {}
    local paths = {}
    for i = 1, 10 do
      paths[i] = {
        kind = "add",
        chunk = i,
        origin_side = "left",
        target_side = "right",
        origin_display_row = i,
        triangle_display_row = 14,
        route_group = group,
      }
    end
    return paths
  end

  local paths = overflow_fixture()
  local layout = { connector_core_width = 24, viewport_topline = 1, viewport_height = 14 }
  local plan = paths_mod.plan_routes(paths, layout)
  assert_plan_invariants(plan, layout, "fully-visible overflow")
  assert_eq(#plan.routes, paths_mod.MAX_VISIBLE_CONNECTOR_ROUTES,
    "Fully-visible overflow should keep exactly the route cap")
  assert_eq(#plan.hidden_routes, 2, "Fully-visible overflow should hide two routes")
  -- All ten routes are fully on-screen, so hiding is decided purely by the
  -- dock-row tie-break: the two latest origins are dropped, with a reason.
  assert_eq(paths[9].overflow_hidden, true, "Overflow should hide the ninth route")
  assert_eq(paths[10].overflow_hidden, true, "Overflow should hide the tenth route")
  assert_eq(paths[9].hide_reason, "overflow-cap", "Overflow hides should record the cap reason")
  assert_eq(plan.hidden_summary["overflow-cap"], 2, "Plan should summarize cap hides")
  assert_eq(paths[1].overflow_hidden == true, false, "Overflow should keep the first route")

  -- The active chunk's connector is what the user navigated to: it must
  -- survive pruning while any other candidate remains.
  local active_paths = overflow_fixture()
  local active_layout = {
    connector_core_width = 24,
    viewport_topline = 1,
    viewport_height = 14,
    active_chunk_index = 9,
  }
  local active_plan = paths_mod.plan_routes(active_paths, active_layout)
  assert_plan_invariants(active_plan, active_layout, "active-chunk overflow")
  assert_eq(#active_plan.hidden_routes, 2, "Active-chunk overflow should still hide two routes")
  assert_eq(active_paths[9].overflow_hidden == true, false,
    "Overflow should never hide the active chunk's route while others remain")
  assert_eq(active_paths[10].overflow_hidden, true,
    "Overflow should hide the farthest non-active route")
  assert_eq(active_paths[8].overflow_hidden, true,
    "Overflow should hide the next non-active route in dock order")
end

-- Test Suite 15d: Width saturation force-hides routes instead of overlapping
do
  local paths = {}
  for i = 1, 6 do
    paths[i] = {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = i,
      triangle_display_row = i + 7,
      route_group = {},
    }
  end
  local layout = { connector_core_width = 4 }
  local plan = paths_mod.plan_routes(paths, layout)
  assert_eq(plan.strategy, "greedy-hidden", "Width saturation should fall back to greedy-hidden")
  assert_eq(#plan.hidden_routes, 5, "Width saturation should force-hide the unplaceable routes")
  assert_eq(#plan.routes, 1, "Width saturation should keep only the placeable route visible")
  assert_eq(plan.hidden_summary["width-exhausted"], 5,
    "Width saturation hides should record the width reason")
  assert_plan_invariants(plan, layout, "width saturation", { expect_success = false })
end

-- Test Suite 15e: Dense adjacent hunks hold plan and lane invariants under scroll
do
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense hardening)")
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)

  for _, toplines in ipairs({ { 1, 1 }, { 1, 38 }, { 1, 46 }, { 8, 46 }, { 20, 30 }, { 40, 40 } }) do
    local label = string.format("dense hardening %d/%d", toplines[1], toplines[2])
    local projected = fake_session:project_paths_for_toplines(paths, toplines[1], toplines[2], 14, 14)
    -- lane_resolution_bailed=true is expected on dense projections: the
    -- legacy crossing loop oscillates and its pass cap ships a bounded,
    -- collision-free state. The stacking check below is the real invariant;
    -- the flag exists so a bail is observable instead of silent.
    local width, plan = paths_mod.required_connector_core_width_for_paths(projected, 3, 24, {
      viewport_topline = toplines[1],
      viewport_height = 14,
      max_route_backtrack_steps = 500,
    })
    assert_plan_invariants(plan, { connector_core_width = width }, label)

    -- No two same-kind paths may hold the same lane on the same row: their
    -- lane-column formula is shared per kind, so stacking means ambiguous
    -- rails. Different kinds anchor to different edges and may reuse numbers.
    local active_bars = paths_mod.compute_active_bars(projected)
    for row, bars in pairs(active_bars) do
      local seen_lanes = {}
      for _, item in ipairs(bars.__items or {}) do
        local key = item.path.kind .. ":" .. tostring(item.lane)
        assert_eq(seen_lanes[key] == nil, true,
          label .. " row " .. tostring(row) .. " should not stack two rails on " .. key)
        seen_lanes[key] = item.path
      end
    end
  end
end

-- Test Suite 15f: The live pressure sizer stays consistent with the planner
do
  -- The gutter width is sized ONCE per document by pressure_core_width and
  -- never resizes while scrolling. Across a grid of independent topline
  -- pairs, every viewport must either plan cleanly at that width or hide
  -- routes with a recorded reason -- never silently.
  local single = paths_mod.pressure_core_width({
    { kind = "add", origin_display_row = 1, triangle_display_row = 4 },
  }, 3, 24)
  assert_eq(single, 7, "A single routed range should size to minimum plus slack lanes")
  assert_eq(paths_mod.pressure_core_width({}, 3, 24), 3,
    "A document with no routes should keep the compact minimum width")

  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (pressure sizer)")
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local width = paths_mod.pressure_core_width(paths, 3, 24)
  assert_eq(width >= 3 and width <= 24, true, "Pressure width should respect the configured bounds")

  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local toplines = { 1, 10, 20, 30, 40, 50 }
  for _, lt in ipairs(toplines) do
    for _, rt in ipairs(toplines) do
      local label = string.format("pressure sizer %d/%d", lt, rt)
      local projected = fake_session:project_paths_for_toplines(paths, lt, rt, 14, 14)
      local layout = {
        connector_core_width = width,
        viewport_topline = lt,
        viewport_height = 14,
        max_route_backtrack_steps = 500,
      }
      local plan = paths_mod.plan_routes(projected, layout)
      assert_plan_invariants(plan, layout, label, { success_optional = true })
      if not plan.success then
        assert_eq(#plan.hidden_routes >= 1, true,
          label .. " planner failure must surface as recorded hidden routes")
      end
    end
  end
end

-- Test Suite 15g: Offscreen-origin continuations keep a visible anchor
do
  local paths = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 5,
      triangle_display_row = 1,
      hide_triangle = true,
      route_group = {},
    },
  }
  local layout = { connector_core_width = 12 }
  local plan = paths_mod.plan_routes(paths, layout)
  assert_plan_invariants(plan, layout, "hide_triangle continuation")
  assert_eq(#plan.routes, 1, "Hidden-triangle route should still plan")
  local touches_triangle_row = false
  local cell_count = 0
  for _, segment in ipairs(plan.routes[1].segments or {}) do
    if segment.type == "horizontal" then
      cell_count = cell_count + (segment.end_col - segment.start_col + 1)
      if segment.row == 1 then touches_triangle_row = true end
    else
      cell_count = cell_count + (segment.end_row - segment.start_row + 1)
      if segment.start_row <= 1 and segment.end_row >= 1 then touches_triangle_row = true end
    end
  end
  assert_eq(cell_count >= 1, true,
    "Hidden-triangle route should keep at least one visible connector cell")
  assert_eq(touches_triangle_row, false,
    "Hidden-triangle route should not draw on the suppressed triangle row")
end

-- Test Suite 15h: Routes never hide before the connector core is saturated
do
  -- The scroll-aware sizer widens the core for the worst stacking that
  -- independent scrolling can produce, and the render path falls back to an
  -- upward width search (stretched to the core edge) when the fixed-width
  -- tree thrashes. Together: across every topline pair, the only legal hide
  -- reason is the eight-route visibility cap.
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (saturation sweep)")
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local core = paths_mod.pressure_core_width(paths, 3, 24, 14)
  assert_eq(core, 15, "Scroll-aware sizing should widen the dense core for stackable routes")
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)

  for lt = 1, 57, 4 do
    for rt = 1, 57, 4 do
      local label = string.format("saturation %d/%d", lt, rt)
      local projected = fake_session:project_paths_for_toplines(paths, lt, rt, 14, 14)
      local layout = {
        connector_core_width = core,
        viewport_topline = lt,
        viewport_height = 14,
        max_route_backtrack_steps = 500,
      }
      local plan = paths_mod.plan_routes(projected, layout)
      if not plan.success then
        local solved_width, retry = paths_mod.required_connector_core_width_for_paths(projected, 3, core, layout)
        assert_eq(retry.success, true, label .. " fallback width search should solve within the core")
        plan = paths_mod.stretch_plan_to_core(retry, solved_width, core)
        for _, route in ipairs(plan.routes) do
          for _, segment in ipairs(route.segments or {}) do
            if segment.type == "horizontal" and (segment.side == "right" or segment.side == "both") then
              assert_eq(segment.end_col <= core - 1, true,
                label .. " stretched horizontals should stay within the core")
            end
          end
        end
      end
      for _, r in ipairs(plan.hidden_routes) do
        assert_eq(r.hide_reason, "overflow-cap",
          label .. " routes should only hide at the visibility cap, not before saturation")
      end
      assert_plan_invariants(plan, layout, label, { success_optional = true })
    end
  end
end

-- ==============================================================================
