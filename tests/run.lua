local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(test_dir .. "/..", ":p")
package.path = package.path .. ";" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua"

local config = require("diffbandit.config").defaults()
local diff = require("diffbandit.diff")
local view = require("diffbandit.view")
local paths_mod = require("diffbandit.paths")

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
      local col = paths_mod.lane_col(lane, glyph_base, rail_spacing)
      assert_eq(cols_used[col] == nil, true,
        "Collision at row " .. row .. " col " .. col .. " (lane " .. lane .. ")")
      cols_used[col] = true
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
  assert_eq(underlines.tail_underlines[7].triangle_col, 7,
    "Delete tail should target the midpoint delete wedge")
  assert_eq(underlines.tail_underlines[7].bar_col < underlines.tail_underlines[7].triangle_col, true,
    "Delete tail should connect from left rail toward midpoint wedge")
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

vim.api.nvim_out_write("OK\n")
vim.cmd("qa")
