#!/usr/bin/env lua
-- Verify tmux capture output for expected visual elements
-- Usage: lua verify.lua <capture_file> [test_name]

local function strip_ansi(s)
  return s:gsub("\27%[[%d;]*m", "")
end

local function read_capture(filepath)
  local file = io.open(filepath, "r")
  if not file then
    io.stderr:write("ERROR: Cannot open capture file: " .. filepath .. "\n")
    os.exit(1)
  end

  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  return lines
end

local function count_occurrences(lines, needle)
  local count = 0
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function sgr_has(codes, wanted)
  local parts = {}
  for code in codes:gmatch("%d+") do
    parts[#parts + 1] = code
  end

  local i = 1
  while i <= #parts do
    local code = parts[i]
    if code == "38" or code == "48" or code == "58" then
      local mode = parts[i + 1]
      if mode == "2" then
        i = i + 5
      elseif mode == "5" then
        i = i + 3
      else
        i = i + 1
      end
    elseif code == wanted then
      return true
    end
    i = i + 1
  end
  return false
end

local function has_ansi_background(line)
  return line:match("\27%[[%d;]*4[0-9]m") ~= nil
    or line:match("\27%[[%d;]*48;[%d;]*m") ~= nil
end

local function has_ansi_underline(line)
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;]*)m", pos)
    if not esc_start then
      return false
    end
    if sgr_has(codes, "4") then
      return true
    end
    pos = esc_end + 1
  end
  return false
end

local function count_ansi_underline_rows(ansi_lines)
  if not ansi_lines then
    return 0
  end
  local count = 0
  for _, line in ipairs(ansi_lines) do
    if has_ansi_underline(line) then
      count = count + 1
    end
  end
  return count
end

local function add_ansi_underline_check(errors, ansi_lines, min_count, label)
  local underline_count = count_ansi_underline_rows(ansi_lines)
  if underline_count < min_count then
    table.insert(errors, string.format(
      "Expected at least %d native underline rows for %s, found %d",
      min_count,
      label,
      underline_count
    ))
  end
end

local function verify_ansi_backgrounds(ansi_lines, labels)
  local errors = {}
  if not ansi_lines then
    table.insert(errors, "ANSI capture missing; cannot verify color spans")
    return errors
  end

  for _, label in ipairs(labels) do
    local found_text = false
    local found_bg = false
    for _, line in ipairs(ansi_lines) do
      if strip_ansi(line):find(label, 1, true) then
        found_text = true
        if has_ansi_background(line) then
          found_bg = true
          break
        end
      end
    end
    if not found_text then
      table.insert(errors, "Expected ANSI capture text: " .. label)
    elseif not found_bg then
      table.insert(errors, "Expected ANSI background color on row containing: " .. label)
    end
  end

  return errors
end

local function ansi_bg_for_text(line, label)
  local current_bg = nil
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;]*)m", pos)
    local chunk_end = (esc_start or (#line + 1)) - 1
    if chunk_end >= pos then
      local chunk = line:sub(pos, chunk_end)
      if chunk:find(label, 1, true) then
        return current_bg
      end
    end
    if not esc_start then
      break
    end

    if sgr_has(codes, "0") or sgr_has(codes, "49") then
      current_bg = nil
    end
    local r, g, b = codes:match("48;2;(%d+);(%d+);(%d+)")
    if r then
      current_bg = table.concat({ r, g, b }, ";")
    end
    pos = esc_end + 1
  end
  return nil
end

local function ansi_bg_for_text_after(line, label, after_label)
  local current_bg = nil
  local seen_after = false
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;]*)m", pos)
    local chunk_end = (esc_start or (#line + 1)) - 1
    if chunk_end >= pos then
      local chunk = line:sub(pos, chunk_end)
      if seen_after and chunk:find(label, 1, true) then
        return current_bg
      end
      if chunk:find(after_label, 1, true) then
        seen_after = true
      end
    end
    if not esc_start then
      break
    end

    if sgr_has(codes, "0") or sgr_has(codes, "49") then
      current_bg = nil
    end
    local r, g, b = codes:match("48;2;(%d+);(%d+);(%d+)")
    if r then
      current_bg = table.concat({ r, g, b }, ";")
    end
    pos = esc_end + 1
  end
  return nil
end

local function ansi_bg_at_plain_byte(line, plain_byte_pos)
  local current_bg = nil
  local plain_pos = 1
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;]*)m", pos)
    local chunk_end = (esc_start or (#line + 1)) - 1
    if chunk_end >= pos then
      local chunk = line:sub(pos, chunk_end)
      local chunk_start = plain_pos
      local chunk_finish = plain_pos + #chunk - 1
      if plain_byte_pos >= chunk_start and plain_byte_pos <= chunk_finish then
        return current_bg
      end
      plain_pos = chunk_finish + 1
    end
    if not esc_start then
      break
    end

    if sgr_has(codes, "0") or sgr_has(codes, "49") then
      current_bg = nil
    end
    local r, g, b = codes:match("48;2;(%d+);(%d+);(%d+)")
    if r then
      current_bg = table.concat({ r, g, b }, ";")
    end
    pos = esc_end + 1
  end
  return nil
end

local function ansi_final_bg(line)
  local current_bg = nil
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;]*)m", pos)
    if not esc_start then
      break
    end
    if sgr_has(codes, "0") or sgr_has(codes, "49") then
      current_bg = nil
    end
    local r, g, b = codes:match("48;2;(%d+);(%d+);(%d+)")
    if r then
      current_bg = table.concat({ r, g, b }, ";")
    end
    pos = esc_end + 1
  end
  return current_bg
end

local function ansi_underline_at_plain_byte(line, plain_byte_pos)
  local underlined = false
  local plain_pos = 1
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;]*)m", pos)
    local chunk_end = (esc_start or (#line + 1)) - 1
    if chunk_end >= pos then
      local chunk = line:sub(pos, chunk_end)
      local chunk_start = plain_pos
      local chunk_finish = plain_pos + #chunk - 1
      if plain_byte_pos >= chunk_start and plain_byte_pos <= chunk_finish then
        return underlined
      end
      plain_pos = chunk_finish + 1
    end
    if not esc_start then
      break
    end

    if sgr_has(codes, "0") or sgr_has(codes, "24") then
      underlined = false
    end
    if sgr_has(codes, "4") then
      underlined = true
    end
    pos = esc_end + 1
  end
  return false
end

local function ansi_glyph_transition_bgs(line, glyph)
  local stripped = strip_ansi(line)
  local glyph_pos = stripped:find(glyph, 1, true)
  if not glyph_pos then
    return nil
  end

  return {
    before = glyph_pos > 1 and ansi_bg_at_plain_byte(line, glyph_pos - 1) or nil,
    glyph = ansi_bg_at_plain_byte(line, glyph_pos),
    after = ansi_bg_at_plain_byte(line, glyph_pos + #glyph),
  }
end

local function add_delete_triangle_transition_check(errors, ansi_lines, label, glyph, description)
  if not ansi_lines then
    table.insert(errors, "ANSI capture missing; cannot verify delete triangle transition for " .. description)
    return
  end

  local found = false
  local transition
  for _, line in ipairs(ansi_lines) do
    local stripped = strip_ansi(line)
    if stripped:find(label, 1, true) and stripped:find(glyph, 1, true) then
      found = true
      transition = ansi_glyph_transition_bgs(line, glyph)
      break
    end
  end

  if not found then
    table.insert(errors, "Expected delete triangle row for " .. description)
    return
  end
  if not transition or not transition.before then
    table.insert(errors, "Expected delete gutter background before the triangle for " .. description)
    return
  end
  if transition.glyph == transition.before then
    table.insert(errors, "Delete triangle cell should not share the left delete gutter background for " .. description)
  end
  if transition.after == transition.before then
    table.insert(errors, "Delete gutter background should not continue broadly after the triangle for " .. description)
  end
end

local function add_add_triangle_transition_check(errors, ansi_lines, label, glyph, description)
  if not ansi_lines then
    table.insert(errors, "ANSI capture missing; cannot verify add triangle transition for " .. description)
    return
  end

  local found = false
  local transition
  for _, line in ipairs(ansi_lines) do
    local stripped = strip_ansi(line)
    if stripped:find(label, 1, true) and stripped:find(glyph, 1, true) then
      found = true
      transition = ansi_glyph_transition_bgs(line, glyph)
      break
    end
  end

  if not found then
    table.insert(errors, "Expected add triangle row for " .. description)
    return
  end
  if not transition or not transition.after then
    table.insert(errors, "Expected add gutter background immediately after the triangle for " .. description)
    return
  end
  if transition.glyph == transition.after then
    table.insert(errors, "Add gutter background should start after the triangle cell for " .. description)
  end
end

local function verify_extreme_additions(lines, ansi_lines)
  local errors = {}

  -- UTF-8 byte sequences for special characters
  local triangle = "\226\151\165"  -- ◥
  local vertical_bar = "\226\148\130"  -- │

  -- Count triangles (should have at least 6 for the extreme test)
  local triangle_count = count_occurrences(lines, triangle)
  if triangle_count < 6 then
    table.insert(errors, string.format("Expected at least 6 triangles, found %d", triangle_count))
  end

  -- Count vertical bars (should have many rows with bars)
  local bar_row_count = count_occurrences(lines, vertical_bar)
  if bar_row_count < 10 then
    table.insert(errors, string.format("Expected at least 10 rows with vertical bars, found %d", bar_row_count))
  end

  -- Check that left line numbers 1-12 appear.
  for i = 1, 12 do
    local found = false
    local num_str = tostring(i)
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      local pattern = "%s" .. num_str .. "[%s%d]"
      if stripped:match(pattern) or stripped:match("^%s*" .. num_str .. "%s") then
        found = true
        break
      end
    end
    if not found then
      table.insert(errors, "Left line number " .. i .. " not found")
    end
  end

  add_ansi_underline_check(errors, ansi_lines, 3, "extreme addition origins")
  add_add_triangle_transition_check(errors, ansi_lines, "New after Bravo 1", triangle, "extreme additions")

  return errors
end

local function verify_pure_additions(lines, ansi_lines)
  local errors = {}

  local triangle = "\226\151\165"  -- ◥

  -- Count triangles (should have at least 3 for pure additions)
  local triangle_count = count_occurrences(lines, triangle)
  if triangle_count < 3 then
    table.insert(errors, string.format("Expected at least 3 triangles, found %d", triangle_count))
  end

  -- Check left line numbers 1-6 (left file has 6 lines)
  for i = 1, 6 do
    local found = false
    local num_str = tostring(i)
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      local pattern = "%s" .. num_str .. "[%s%d]"
      if stripped:match(pattern) or stripped:match("^%s*" .. num_str .. "%s") then
        found = true
        break
      end
    end
    if not found then
      table.insert(errors, "Left line number " .. i .. " not found")
    end
  end

  add_ansi_underline_check(errors, ansi_lines, 3, "pure addition origins")

  local add_triangle_bg, add_after_triangle_bg
  if ansi_lines then
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find("New line 1", 1, true) then
        local triangle_pos = stripped:find(triangle, 1, true)
        if triangle_pos then
          add_triangle_bg = ansi_bg_at_plain_byte(line, triangle_pos)
          add_after_triangle_bg = ansi_bg_at_plain_byte(line, triangle_pos + #triangle)
          break
        end
      end
    end
  end
  if not add_after_triangle_bg then
    table.insert(errors, "Expected add gutter background immediately after the add triangle")
  elseif add_triangle_bg == add_after_triangle_bg then
    table.insert(errors, "Add gutter background should start after the add triangle cell")
  end
  add_add_triangle_transition_check(errors, ansi_lines, "New line 6", triangle, "pure additions tail block")

  return errors
end

local function verify_deletions(lines, ansi_lines)
  local errors = {}

  local delete_triangles = {
    "\226\151\164",  -- ◤
    "\226\151\165",  -- ◥
  }

  local triangle_count = 0
  local saw_deleted_text = false
  local pure_delete_triangle_after_left_number = false
  local second_delete_triangle_after_left_number = false
  local pure_delete_rail_after_left_number = false
  local delete_origin_underline_reaches_edge = false
  local delete_origin_stops_at_rail = false
  local delete_tail_underscore_left_of_pipe = false
  local delete_tail_line_number_clean = false
  for _, line in ipairs(lines) do
    local stripped = strip_ansi(line)
    for _, triangle in ipairs(delete_triangles) do
      if line:find(triangle, 1, true) then
        triangle_count = triangle_count + 1
        break
      end
    end
    if stripped:find("Line to delete 1", 1, true) and stripped:find("Third line", 1, true) then
      saw_deleted_text = true
      if stripped:find("3\226\151\164", 1, true) then
        pure_delete_triangle_after_left_number = true
      end
    elseif stripped:find("Line to delete 4", 1, true) then
      if stripped:find("8\226\151\164", 1, true) then
        second_delete_triangle_after_left_number = true
      end
    elseif stripped:find("Third line", 1, true) and stripped:find("Sixth line", 1, true) then
      if stripped:find("6%s+│%s│%s+│%s*6%s+│Sixth line") then
        pure_delete_rail_after_left_number = true
      end
    end
  end

  if ansi_lines then
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Second line", 1, true) then
        local right_sep_pos = stripped:find("│Second line", 1, true)
        if right_sep_pos then
          delete_origin_underline_reaches_edge =
            delete_origin_underline_reaches_edge or ansi_underline_at_plain_byte(line, right_sep_pos - 1)
        end
      elseif stripped:find("Line to delete 2", 1, true) and stripped:find("Fourth line", 1, true) then
        local left_num_end = stripped:find("  4 │", 1, true)
        if left_num_end then
          local connector_col0 = left_num_end + #"  4 │"
          delete_origin_stops_at_rail =
            not ansi_underline_at_plain_byte(line, connector_col0)
            and not ansi_underline_at_plain_byte(line, connector_col0 + 1)
            and ansi_underline_at_plain_byte(line, connector_col0 + 2)
        end
      elseif stripped:find("Fourth line", 1, true) then
        local rail_pattern = stripped:find("  7 │ │", 1, true)
        if rail_pattern then
          local line_number_spacer = rail_pattern + #"  7"
          local connector_col0 = rail_pattern + #"  7 │"
          local connector_col1 = connector_col0 + 1
          delete_tail_underscore_left_of_pipe =
            ansi_underline_at_plain_byte(line, connector_col0)
            and not ansi_underline_at_plain_byte(line, connector_col1)
          delete_tail_line_number_clean = not ansi_underline_at_plain_byte(line, line_number_spacer)
        end
      end
    end
  end

  if triangle_count < 2 then
    table.insert(errors, string.format("Expected at least 2 delete triangles, found %d", triangle_count))
  end
  if not saw_deleted_text then
    table.insert(errors, "Expected deleted left text and compact right text to appear in the capture")
  end
  if not pure_delete_triangle_after_left_number then
    table.insert(errors, "Pure deletion wedge should sit immediately after the left line number")
  end
  if not second_delete_triangle_after_left_number then
    table.insert(errors, "Second pure deletion wedge should sit immediately after the left line number")
  end
  if not pure_delete_rail_after_left_number then
    table.insert(errors, "Pure deletion continuation rail should stay one connector cell after the left number pane")
  end
  add_ansi_underline_check(errors, ansi_lines, 2, "deletion origins")
  if not delete_origin_underline_reaches_edge then
    table.insert(errors, "Pure deletion origin underline should reach the right edge of the gutter")
  end
  if not delete_origin_stops_at_rail then
    table.insert(errors, "Pure deletion origin underline should start after the route rail, not at the connector edge")
  end
  if not delete_tail_underscore_left_of_pipe then
    table.insert(errors, "Pure deletion tail underscore should sit left of the route pipe in the connector pane")
  end
  if not delete_tail_line_number_clean then
    table.insert(errors, "Pure deletion tail underscore should not be drawn inside the line-number pane")
  end
  add_delete_triangle_transition_check(errors, ansi_lines, "Line to delete 1", "\226\151\164", "first pure deletion")
  add_delete_triangle_transition_check(errors, ansi_lines, "Line to delete 4", "\226\151\164", "second pure deletion")

  return errors
end

local function verify_mixed(lines, ansi_lines)
  local errors = {}

  local delete_triangles = {
    "\226\151\164",  -- ◤
    "\226\151\165",  -- ◥
  }
  local change_wedge_top = "\226\151\162"  -- ◢
  local change_wedge_bottom = "\226\151\165"  -- ◥

  local saw_delete_triangle = false
  local saw_change_wedge_top = false
  local saw_change_wedge_bottom = false
  local saw_changed_text = false
  local saw_added_text = false
  local saw_deleted_text = false

  for _, line in ipairs(lines) do
    local stripped = strip_ansi(line)
    for _, triangle in ipairs(delete_triangles) do
      saw_delete_triangle = saw_delete_triangle or line:find(triangle, 1, true) ~= nil
    end
    saw_change_wedge_top = saw_change_wedge_top or line:find(change_wedge_top, 1, true) ~= nil
    saw_change_wedge_bottom = saw_change_wedge_bottom or line:find(change_wedge_bottom, 1, true) ~= nil
    saw_changed_text = saw_changed_text or stripped:find("Old value A", 1, true) ~= nil
    saw_added_text = saw_added_text or stripped:find("Added line 1", 1, true) ~= nil
    saw_deleted_text = saw_deleted_text or stripped:find("Delete this line", 1, true) ~= nil
  end

  if not saw_delete_triangle then
    table.insert(errors, "Expected a delete triangle in mixed diff")
  end
  if not saw_change_wedge_top then
    table.insert(errors, "Expected mixed change/add route to render a top blue wedge")
  end
  if not saw_change_wedge_bottom then
    table.insert(errors, "Expected mixed change/add route to render a bottom blue wedge")
  end
  if not saw_changed_text then
    table.insert(errors, "Expected changed left text in mixed diff")
  end
  if not saw_added_text then
    table.insert(errors, "Expected added right text in mixed diff")
  end
  if not saw_deleted_text then
    table.insert(errors, "Expected deleted left text in mixed diff")
  end

  local old_word_bg, old_tail_bg, new_word_bg, new_tail_bg, original_word_bg, original_tail_bg
  local modified_word_bg, modified_tail_bg, added_suffix_bg, right_number_bg
  local delete_before_bg, delete_glyph_bg, delete_after_bg
  local before_top_wedge_bg, after_top_wedge_bg
  local top_wedge_docked_to_right_number
  local delete_origin_underline_reaches_edge
  local added_line2_bg, added_line2_after_bg
  if ansi_lines then
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Old value A", 1, true) then
        old_word_bg = ansi_bg_for_text(line, "Old")
        old_tail_bg = ansi_bg_for_text(line, "value A")
        new_word_bg = ansi_bg_for_text(line, "New")
        new_tail_bg = ansi_bg_for_text_after(line, "value A", "New")
      elseif stripped:find("Context line 3", 1, true) then
        local right_sep_pos = stripped:find("│Context line 3", 1, true)
        if right_sep_pos then
          delete_origin_underline_reaches_edge = ansi_underline_at_plain_byte(line, right_sep_pos - 1)
        end
      elseif stripped:find("Delete this line", 1, true) then
        local transition = ansi_glyph_transition_bgs(line, "\226\151\164")
        if transition then
          delete_before_bg = transition.before
          delete_glyph_bg = transition.glyph
          delete_after_bg = transition.after
        end
      elseif stripped:find("Modified text here with extra content", 1, true) then
        modified_word_bg = ansi_bg_for_text(line, "Modified")
        modified_tail_bg = ansi_bg_for_text(line, "text here")
        added_suffix_bg = ansi_bg_for_text(line, "with extra content")
        local number_pos = stripped:find("7%s+│Modified text here")
        if number_pos then
          right_number_bg = ansi_bg_at_plain_byte(line, number_pos)
        end
        local wedge_pos = stripped:find(change_wedge_top, 1, true)
        if wedge_pos then
          before_top_wedge_bg = ansi_bg_at_plain_byte(line, wedge_pos - 1)
          after_top_wedge_bg = ansi_bg_at_plain_byte(line, wedge_pos + #change_wedge_top)
          top_wedge_docked_to_right_number = number_pos and (wedge_pos + #change_wedge_top == number_pos)
        end
      elseif stripped:find("Original text here", 1, true) then
        original_word_bg = ansi_bg_for_text(line, "Original")
        original_tail_bg = ansi_bg_for_text(line, "text here")
      elseif stripped:find("Added line 2", 1, true) then
        local start_pos = stripped:find("Added line 2", 1, true)
        added_line2_bg = ansi_bg_for_text(line, "Added line 2")
        added_line2_after_bg = ansi_bg_at_plain_byte(line, start_pos + #"Added line 2") or ansi_final_bg(line)
      end
    end
  end
  if not old_word_bg or not old_tail_bg then
    table.insert(errors, "Expected ANSI backgrounds for left-side changed word emphasis")
  elseif old_word_bg == old_tail_bg then
    table.insert(errors, "Left replacement row should emphasize only the changed word")
  end
  if not original_word_bg or not original_tail_bg then
    table.insert(errors, "Expected ANSI backgrounds for mixed left replacement emphasis")
  elseif original_word_bg == original_tail_bg then
    table.insert(errors, "Mixed left replacement should emphasize only the changed word")
  end
  if not new_word_bg or not new_tail_bg then
    table.insert(errors, "Expected ANSI backgrounds for right-side changed word emphasis")
  elseif new_word_bg == new_tail_bg then
    table.insert(errors, "Right replacement row should emphasize only the changed word")
  end
  if not modified_word_bg or not modified_tail_bg or not added_suffix_bg then
    table.insert(errors, "Expected ANSI backgrounds for mixed replacement emphasis and added suffix")
  else
    if modified_word_bg == modified_tail_bg then
      table.insert(errors, "Mixed replacement should emphasize only the changed word")
    end
    if modified_tail_bg == added_suffix_bg then
      table.insert(errors, "Mixed replacement row should split change background from added suffix background")
    end
  end
  if not right_number_bg then
    table.insert(errors, "Expected mixed replacement right line number to have an ANSI background")
  elseif not top_wedge_docked_to_right_number then
    table.insert(errors, "Mixed replacement wedge should dock directly against the right line number")
  end
  if not after_top_wedge_bg then
    table.insert(errors, "Expected mixed route background after the top expansion wedge")
  elseif modified_tail_bg and after_top_wedge_bg ~= modified_tail_bg then
    table.insert(errors, "Top mixed expansion wedge should connect directly into the change route")
  elseif before_top_wedge_bg == after_top_wedge_bg then
    table.insert(errors, "Top mixed expansion route should not paint change background before the wedge")
  end
  if not delete_origin_underline_reaches_edge then
    table.insert(errors, "Delete origin underline should reach the right edge of the gutter")
  end
  if not delete_before_bg then
    table.insert(errors, "Expected mixed delete gutter background before the triangle")
  elseif delete_glyph_bg == delete_before_bg then
    table.insert(errors, "Mixed delete triangle cell should not share the left delete gutter background")
  elseif delete_after_bg == delete_before_bg then
    table.insert(errors, "Mixed delete gutter background should not continue broadly after the triangle")
  end
  if not added_line2_bg or not added_line2_after_bg then
    table.insert(errors, "Expected ANSI backgrounds for terminal embedded added row")
  elseif added_line2_bg == added_line2_after_bg then
    table.insert(errors, "Terminal embedded added row should return to change background after its text")
  elseif modified_tail_bg and added_line2_after_bg ~= modified_tail_bg then
    table.insert(errors, "Terminal embedded added row should return to the mixed change envelope")
  end

  return errors
end

local function verify_comprehensive(lines, ansi_lines)
  local errors = {}

  local add_triangle = "\226\151\165"  -- ◥
  local delete_triangle = "\226\151\164"  -- ◤
  local delete_triangle_from_below = "\226\151\165"  -- ◥
  local legacy_delete_triangle = "\226\151\162"  -- ◢
  local vertical_bar = "\226\148\130"  -- │

  if count_occurrences(lines, add_triangle) < 3 then
    table.insert(errors, "Expected at least 3 add triangles in comprehensive diff")
  end
  if (count_occurrences(lines, delete_triangle)
      + count_occurrences(lines, delete_triangle_from_below)
      + count_occurrences(lines, legacy_delete_triangle)) < 1 then
    table.insert(errors, "Expected at least 1 delete triangle in comprehensive diff")
  end
  add_ansi_underline_check(errors, ansi_lines, 3, "comprehensive separator routes")
  if count_occurrences(lines, vertical_bar) < 4 then
    table.insert(errors, "Expected multiple vertical connector rows in comprehensive diff")
  end

  local required_text = {
    "import",
    "\"time\"",
    "This section will",
    "Added timing logic",
    "Added performance check",
  }
  for _, text in ipairs(required_text) do
    local found = false
    for _, line in ipairs(lines) do
      if strip_ansi(line):find(text, 1, true) then
        found = true
        break
      end
    end
    if not found then
      table.insert(errors, "Expected comprehensive text: " .. text)
    end
  end

  return errors
end

local function line_contains_any(line, labels)
  for _, label in ipairs(labels) do
    if line:find(label, 1, true) then
      return true
    end
  end
  return false
end

local function find_plain_line(lines, labels, glyphs)
  for _, line in ipairs(lines) do
    local stripped = strip_ansi(line)
    if line_contains_any(stripped, labels) then
      if not glyphs then
        return line, stripped
      end
      for _, glyph in ipairs(glyphs) do
        if stripped:find(glyph, 1, true) then
          return line, stripped, glyph
        end
      end
    end
  end
  return nil, nil, nil
end

local function glyph_docked_to_right_number(stripped, glyph)
  local pos = stripped:find(glyph, 1, true)
  if not pos then
    return false
  end
  local next_char = stripped:sub(pos + #glyph, pos + #glyph)
  return next_char:match("%d") ~= nil
end

local function contains_any_glyph(lines, labels, glyphs)
  local _, _, glyph = find_plain_line(lines, labels, glyphs)
  return glyph ~= nil
end

local function verify_scroll_additions(lines, ansi_lines, phase)
  local errors = {}
  if phase == "clamped-end" then
    if not find_plain_line(lines, { "Scroll add context 18" }) then
      table.insert(errors, "Expected additions clamped-end capture to include final context")
    end
    return errors
  end

  if phase == "overscroll-end" then
    local first_content = nil
    local saw_blank_padding = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add context 18", 1, true) then
        first_content = first_content or stripped
      elseif first_content and stripped:find("│    │            │    │", 1, true) then
        saw_blank_padding = true
      end
    end
    if not first_content then
      table.insert(errors, "Expected overscroll additions capture to place final context at the top")
    end
    if not saw_blank_padding then
      table.insert(errors, "Expected overscroll additions capture to include blank scroll padding after EOF")
    end
    return errors
  end

  local add_glyphs = { "\226\151\165", "\226\151\162" } -- ◥, ◢
  local function add_glyph_is_underlined(label, glyph)
    if not ansi_lines then
      return false
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) and stripped:find(glyph, 1, true) then
        local glyph_pos = stripped:find(glyph, 1, true)
        if glyph_pos and ansi_underline_at_plain_byte(line, glyph_pos) then
          return true
        end
      end
    end
    return false
  end

  local function add_connector_tail_reaches_glyph(label, glyph)
    if not ansi_lines then
      return false
    end
    local right_separator_width = #"\226\148\130" -- │
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) and stripped:find(glyph, 1, true) then
        local glyph_pos = stripped:find(glyph, 1, true)
        local tail_pos = glyph_pos and (glyph_pos - right_separator_width - 1) or nil
        if tail_pos and tail_pos > 0 and ansi_underline_at_plain_byte(line, tail_pos) then
          return true
        end
      end
    end
    return false
  end

  local function add_connector_edge_cell_is_underlined(label)
    if not ansi_lines then
      return false
    end
    local separator = "\226\148\130" -- │
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      local label_pos = stripped:find(label, 1, true)
      if label_pos then
        local separators = {}
        local pos = 1
        while true do
          local sep_pos = stripped:find(separator, pos, true)
          if not sep_pos or sep_pos >= label_pos then
            break
          end
          separators[#separators + 1] = sep_pos
          pos = sep_pos + #separator
        end
        local right_num_left_sep = separators[#separators - 1]
        if right_num_left_sep and ansi_underline_at_plain_byte(line, right_num_left_sep - 1) then
          return true
        end
      end
    end
    return false
  end

  if phase == "origin-offscreen" then
    if not find_plain_line(lines, { "Added scroll" }) then
      table.insert(errors, "Expected scroll addition viewport to include added content")
    end
    if contains_any_glyph(lines, { "Added scroll" }, add_glyphs) then
      table.insert(errors, "Offscreen-origin addition rows should show rails/background, not synthetic triangles")
    end
    return errors
  end

  if phase == "target-above" then
    local _, _, glyph = find_plain_line(lines, { "Added scroll" }, add_glyphs)
    if not glyph then
      table.insert(errors, "Expected independent addition viewport to show a directional transition glyph")
    end
    if ansi_lines and not add_connector_tail_reaches_glyph("Added scroll B 06", "\226\151\162") then
      table.insert(errors, "Expected adjacent upward addition tail to underline the connector cell before B06")
    end
    return errors
  end

  if phase == "target-flipped" then
    local _, _, glyph = find_plain_line(lines, { "Added scroll A 02" }, add_glyphs)
    if glyph ~= "\226\151\162" then
      table.insert(errors, "Expected addition transition split point to stay anchored to the origin boundary")
    end
    local _, _, lower_glyph = find_plain_line(lines, { "Added scroll A 03" }, add_glyphs)
    if lower_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected addition span crossing the visible origin to keep a lower adjacent glyph")
    end
    if ansi_lines then
      local found_origin_transition_underline = false
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        if stripped:find("Scroll add origin A", 1, true) and stripped:find("Added scroll A 02", 1, true) then
          local glyph_pos = stripped:find("\226\151\162", 1, true)
          if glyph_pos then
            found_origin_transition_underline = ansi_underline_at_plain_byte(line, glyph_pos)
          end
        end
      end
      if not found_origin_transition_underline then
        table.insert(errors, "Expected straddled addition origin underline to reach the right transition cell")
      end
    end
    return errors
  end

  if phase == "target-aligned" then
    local _, _, top_glyph = find_plain_line(lines, { "Added scroll A 01" }, add_glyphs)
    if top_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected addition transition to split as soon as the added row aligns with the origin")
    end
    local _, _, lower_glyph = find_plain_line(lines, { "Added scroll A 02" }, add_glyphs)
    if lower_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected aligned addition transition to keep a lower adjacent glyph")
    end
    if ansi_lines then
      local found_origin_transition_underline = false
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        if stripped:find("Scroll add origin A", 1, true) and stripped:find("Added scroll A 01", 1, true) then
          local glyph_pos = stripped:find("\226\151\162", 1, true)
          if glyph_pos then
            found_origin_transition_underline = ansi_underline_at_plain_byte(line, glyph_pos)
          end
        end
      end
      if not found_origin_transition_underline then
        table.insert(errors, "Expected aligned addition origin underline to reach the upper transition glyph")
      end
    end
    return errors
  end

  if phase == "target-spanning" then
    local _, _, top_glyph = find_plain_line(lines, { "Added scroll A 03" }, add_glyphs)
    if top_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected upper addition transition to stay adjacent to the origin while the block straddles it")
    end
    local _, _, lower_glyph = find_plain_line(lines, { "Added scroll A 04" }, add_glyphs)
    if lower_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected lower addition transition to stay on the origin-aligned row while the block straddles it")
    end
    return errors
  end

  if phase == "lower-target-below" then
    local found_lower_clipped_rail_bottom = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add context 09", 1, true)
          and stripped:find("Scroll add context 04", 1, true)
          and stripped:find("│          │ │ 55", 1, true) then
        found_lower_clipped_rail_bottom = true
        break
      end
    end
    if not found_lower_clipped_rail_bottom then
      table.insert(errors, "Expected lower addition route to continue down to the bottom row while its target is still below")
    end
    return errors
  end

  if phase == "lower-target-approach" then
    local _, _, first_glyph = find_plain_line(lines, { "Added scroll B 01" }, add_glyphs)
    if first_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected lower addition route to show its first visible triangle as soon as B enters")
    end
    if contains_any_glyph(lines, { "Added scroll B 02", "Added scroll B 03" }, add_glyphs) then
      table.insert(errors, "Expected lower addition route to keep a single lower triangle until B straddles its origin")
    end
    local found_lower_clipped_rail = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add context 06", 1, true)
          and stripped:find("Scroll add origin B", 1, true)
          and stripped:find("│          │ │ 57", 1, true) then
        found_lower_clipped_rail = true
        break
      end
    end
    if not found_lower_clipped_rail then
      table.insert(errors, "Expected lower addition approach to keep a continuation rail from origin B to B01")
    end
    if ansi_lines then
      local found_tail_underline = false
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        if stripped:find("Scroll add context 06", 1, true)
            and stripped:find("Scroll add origin B", 1, true)
            and has_ansi_underline(line) then
          found_tail_underline = true
          break
        end
      end
      if not found_tail_underline then
        table.insert(errors, "Expected lower addition first-visible route to underline from the pipe into B01")
      end
    end
    return errors
  end

  if phase == "same-row-upper" then
    local _, _, glyph = find_plain_line(lines, { "Added scroll A 50" }, add_glyphs)
    if glyph ~= "\226\151\162" then
      table.insert(errors, "Expected same-row upper addition transition to render its upper triangle on A50")
    end
    if ansi_lines and add_connector_edge_cell_is_underlined("Added scroll A 49") then
      table.insert(errors, "Expected same-row upper transition not to underline the connector edge on the preceding add row")
    end
    return errors
  end

  if phase == "upper-target-exiting" then
    local _, _, upper_a_glyph = find_plain_line(lines, { "Added scroll A 50" }, add_glyphs)
    if upper_a_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected upper addition route to keep a triangle on A50 while the region exits upward")
    end
    local found_origin_rail = false
    local found_tail_terminal = false
    local found_tail_pipe = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Added scroll A 50", 1, true) then
        if stripped:find("│            │◢53", 1, true) then
          found_tail_terminal = true
        end
        if stripped:find("│          │ │◢53", 1, true) then
          found_tail_pipe = true
        end
      elseif stripped:find("Scroll add origin A", 1, true)
          and stripped:find("│          │ │ 54", 1, true) then
        found_origin_rail = true
      end
    end
    if not found_tail_terminal then
      table.insert(errors, "Expected upper addition route to terminate the pipe on the row below A50")
    end
    if found_tail_pipe then
      table.insert(errors, "Expected upper addition route not to draw a pipe on the A50 tail row")
    end
    if not found_origin_rail then
      table.insert(errors, "Expected upper addition route to keep the origin-side pipe on origin A")
    end
    if ansi_lines and not add_glyph_is_underlined("Added scroll A 50", "\226\151\162") then
      table.insert(errors, "Expected exiting upper addition triangle to carry the connector underline")
    end
    if ansi_lines and not add_connector_tail_reaches_glyph("Added scroll A 50", "\226\151\162") then
      table.insert(errors, "Expected exiting upper addition tail to underline the connector cell before A50")
    end
    return errors
  end

  if phase == "lower-target-entering" then
    local _, _, upper_a_glyph = find_plain_line(lines, { "Added scroll A 50" }, add_glyphs)
    if upper_a_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected upper addition route to keep its final visible upper triangle at the top edge")
    end
    local found_origin_rail = false
    local found_tail_terminal = false
    local found_tail_pipe = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Added scroll A 50", 1, true) then
        if stripped:find("│            │◢53", 1, true) then
          found_tail_terminal = true
        end
        if stripped:find("│          │ │◢53", 1, true) then
          found_tail_pipe = true
        end
      elseif stripped:find("Scroll add origin A", 1, true)
          and stripped:find("│          │ │ 55", 1, true) then
        found_origin_rail = true
      end
    end
    if not found_tail_terminal then
      table.insert(errors, "Expected upper addition route to terminate the pipe on the A50 top-edge tail row")
    end
    if found_tail_pipe then
      table.insert(errors, "Expected upper addition route not to draw a pipe on the A50 top-edge tail row")
    end
    if not found_origin_rail then
      table.insert(errors, "Expected upper addition route to keep the origin-side pipe at the top edge")
    end
    if ansi_lines then
      local found_upper_tail = false
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        if stripped:find("Scroll add context 01", 1, true)
            and stripped:find("Added scroll A 50", 1, true)
            and has_ansi_underline(line) then
          found_upper_tail = true
          break
        end
      end
      if not found_upper_tail then
        table.insert(errors, "Expected upper addition route to keep an underlined tail to its top-edge triangle")
      end
      if not add_glyph_is_underlined("Added scroll A 50", "\226\151\162") then
        table.insert(errors, "Expected top-edge upper addition triangle to carry the connector underline")
      end
      if add_connector_edge_cell_is_underlined("Added scroll B 01") then
        table.insert(errors, "Expected same-row lower transition not to underline the connector edge on B01")
      end
    end
    local _, _, top_glyph = find_plain_line(lines, { "Added scroll B 02" }, add_glyphs)
    if top_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected lower addition upper transition to anchor at origin B when B target enters")
    end
    local _, _, lower_glyph = find_plain_line(lines, { "Added scroll B 03" }, add_glyphs)
    if lower_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected lower addition lower transition to anchor adjacent to origin B when B target enters")
    end
    return errors
  end

  if phase == "upper-target-clipped" then
    local found_a_origin_rail = false
    local found_a_stepped_corner = false
    local found_b_origin_rail = false
    local found_b_tail_terminal = false
    local found_b_tail_pipe = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add origin A", 1, true)
          and stripped:find("│          │ │ 62", 1, true) then
        found_a_origin_rail = true
      elseif stripped:find("Scroll add origin A", 1, true)
          and stripped:find("│        │   │ 62", 1, true) then
        found_a_stepped_corner = true
      elseif stripped:find("Added scroll B 06", 1, true) then
        if stripped:find("│            │◢63", 1, true) then
          found_b_tail_terminal = true
        end
        if stripped:find("│          │ │◢63", 1, true) then
          found_b_tail_pipe = true
        end
      elseif stripped:find("Scroll add origin B", 1, true)
          and stripped:find("│          │ │ 66", 1, true) then
        found_b_origin_rail = true
      end
    end
    if found_a_origin_rail then
      table.insert(errors, "Expected clipped upper addition route to step outward one row before same-cell collision")
    end
    if not found_a_stepped_corner then
      table.insert(errors, "Expected clipped upper addition route to step outward when the lower route reaches the adjacent row")
    end
    if not found_b_tail_terminal then
      table.insert(errors, "Expected visible upper B route to terminate the pipe on the B06 tail row")
    end
    if found_b_tail_pipe then
      table.insert(errors, "Expected visible upper B route not to draw a pipe on the B06 tail row")
    end
    if not found_b_origin_rail then
      table.insert(errors, "Expected visible upper B route to keep the origin-side pipe on origin B")
    end
    if ansi_lines and not add_glyph_is_underlined("Added scroll B 06", "\226\151\162") then
      table.insert(errors, "Expected visible upper B triangle to carry the connector underline")
    end
    return errors
  end

  if phase == "pre-collision-inner" then
    local found_inner_a_origin = false
    local found_early_stepped_a_origin = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add origin A", 1, true) then
        if stripped:find("│          │ │ 61", 1, true) then
          found_inner_a_origin = true
        end
        if stripped:find("│        │   │ 61", 1, true) then
          found_early_stepped_a_origin = true
        end
      end
    end
    if not found_inner_a_origin then
      table.insert(errors, "Expected clipped route to stay inner while one full blank row remains before the lower route")
    end
    if found_early_stepped_a_origin then
      table.insert(errors, "Expected clipped route not to step outward while one full blank row remains")
    end
    return errors
  end

  if phase == "pre-overlap-inner" then
    local found_inner_a_origin = false
    local found_early_stepped_a_origin = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add origin A", 1, true) then
        if stripped:find("│          │ │ 56", 1, true) then
          found_inner_a_origin = true
        end
        if stripped:find("│        │   │ 56", 1, true) then
          found_early_stepped_a_origin = true
        end
      end
    end
    if not found_inner_a_origin then
      table.insert(errors, "Expected pre-overlap clipped route to stay on the inner lane")
    end
    if found_early_stepped_a_origin then
      table.insert(errors, "Expected pre-overlap clipped route not to step outward before collision")
    end
    return errors
  end

  if phase == "overlap-stepped" then
    local found_stepped_clipped_upper = false
    local found_inner_triangle = false
    local found_inner_origin_rail = false
    local found_lower_stepped_triangle = false
    local found_inner_triangle_pipe = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add context 01", 1, true)
          and stripped:find("Added scroll B 04", 1, true)
          and stripped:find("│        │   │ 61", 1, true) then
        found_stepped_clipped_upper = true
      elseif stripped:find("Scroll add origin A", 1, true)
          and stripped:find("Added scroll B 06", 1, true) then
        if stripped:find("│        │   │◢63", 1, true) then
          found_inner_triangle = true
        end
        if stripped:find("│        │ │ │◢63", 1, true) then
          found_inner_triangle_pipe = true
        end
        if stripped:find("│      │     │◢63", 1, true) then
          found_lower_stepped_triangle = true
        end
      elseif stripped:find("Scroll add origin B", 1, true)
          and stripped:find("Scroll add context 09", 1, true)
          and stripped:find("│          │ │ 67", 1, true) then
        found_inner_origin_rail = true
      end
    end
    if not found_stepped_clipped_upper then
      table.insert(errors, "Expected clipped upper route to step outward before the lower route overlap")
    end
    if not found_inner_triangle then
      table.insert(errors, "Expected lower route triangle to keep the inner lane while the upper continuation steps around it")
    end
    if found_inner_triangle_pipe then
      table.insert(errors, "Expected lower route not to draw a pipe on the B06 tail row")
    end
    if not found_inner_origin_rail then
      table.insert(errors, "Expected lower route to keep the origin-side pipe on origin B")
    end
    if found_lower_stepped_triangle then
      table.insert(errors, "Expected lower visible route not to be displaced by the clipped upper route")
    end
    return errors
  end

  if phase == "hidden-overlap-inner" then
    local found_lower_inner_origin = false
    local found_lower_outer_origin = false
    local found_shared_overlap = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add context 01", 1, true)
          and stripped:find("Scroll add context 06", 1, true)
          and stripped:find("│        │ │ │ 64", 1, true) then
        found_shared_overlap = true
      elseif stripped:find("Scroll add origin B", 1, true) then
        if stripped:find("│          │ │ 70", 1, true) then
          found_lower_inner_origin = true
        end
        if stripped:find("│        │   │ 70", 1, true) then
          found_lower_outer_origin = true
        end
      end
    end
    if not found_shared_overlap then
      table.insert(errors, "Expected overlapping clipped upward routes to occupy separate lanes near the top edge")
    end
    if not found_lower_inner_origin then
      table.insert(errors, "Expected lower clipped upward route to keep the inner lane at origin B")
    end
    if found_lower_outer_origin then
      table.insert(errors, "Expected lower clipped upward route not to connect to the upper route's outer lane")
    end
    return errors
  end

  if phase == "right-j-scroll" then
    if not find_plain_line(lines, { "Scroll add context 01" }) then
      table.insert(errors, "Right-pane scroll should leave left pane stationary at the top context")
    end
    local _, _, top_glyph = find_plain_line(lines, { "Added scroll A 15" }, add_glyphs)
    if top_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected right-pane natural scroll to keep the upper flipped addition transition")
    end
    local _, _, lower_glyph = find_plain_line(lines, { "Added scroll A 16" }, add_glyphs)
    if lower_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected right-pane natural scroll to keep the lower addition transition on the origin-aligned row")
    end
    return errors
  end

  if phase == "right-j-scroll-line39" or phase == "right-j-scroll-line41" then
    if not find_plain_line(lines, { "Scroll add context 01" }) then
      table.insert(errors, "Deep right-pane scroll should leave left pane stationary at the top context")
    end
    local _, _, top_glyph = find_plain_line(lines, { "Scroll add origin A" }, add_glyphs)
    if top_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected deep right-pane scroll to keep the upper transition docked to origin A")
    end
    local _, _, lower_glyph = find_plain_line(lines, { "Scroll add context 03" }, add_glyphs)
    if lower_glyph ~= "\226\151\165" then
      table.insert(errors, "Expected deep right-pane scroll to keep the lower transition docked below origin A")
    end

    local found_lower_origin = false
    local found_lower_rail = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add origin B", 1, true)
          and stripped:find("│  7 │", 1, true) then
        found_lower_origin = true
      elseif stripped:find("Scroll add context 06", 1, true)
          and stripped:find("│          │ │", 1, true) then
        found_lower_rail = true
      end
    end
    if not found_lower_origin then
      table.insert(errors, "Expected deep right-pane scroll to keep lower route origin on left row 7")
    end
    if not found_lower_rail then
      table.insert(errors, "Expected deep right-pane scroll to keep lower continuation rail below origin B")
    end
    return errors
  end

  if phase == "initial" then
    local found_lower_clipped_rail = false
    local found_lower_clipped_rail_bottom = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add context 06", 1, true)
          and stripped:find("Added scroll A 05", 1, true)
          and stripped:find("│          │ │ 8", 1, true) then
        found_lower_clipped_rail = true
      elseif stripped:find("Scroll add context 09", 1, true)
          and stripped:find("Added scroll A 08", 1, true)
          and stripped:find("│          │ │ 11", 1, true) then
        found_lower_clipped_rail_bottom = true
      end
    end
    if not found_lower_clipped_rail then
      table.insert(errors, "Expected offscreen lower addition target to leave a vertical continuation rail below its origin")
    end
    if not found_lower_clipped_rail_bottom then
      table.insert(errors, "Expected offscreen lower addition continuation rail to reach the bottom visible row")
    end
  end

  local _, _, glyph = find_plain_line(lines, { "Added scroll" }, add_glyphs)
  if not glyph then
    table.insert(errors, "Expected initial scroll addition viewport to show the real transition glyph")
  end

  if ansi_lines and glyph then
    local found_transition = false
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Added scroll", 1, true) and stripped:find(glyph, 1, true) then
        local transition = ansi_glyph_transition_bgs(line, glyph)
        found_transition = transition and transition.after and transition.glyph ~= transition.after
        break
      end
    end
    if not found_transition then
      table.insert(errors, "Expected scroll addition background to start after the transition glyph")
    end
  end

  return errors
end

local function verify_scroll_deletions(lines, ansi_lines, phase)
  local errors = {}
  if phase == "clamped-end" then
    if not find_plain_line(lines, { "Scroll delete context 18" }) then
      table.insert(errors, "Expected deletions clamped-end capture to include final context")
    end
    return errors
  end

  local delete_glyphs = { "\226\151\164", "\226\151\163", "\226\151\165" } -- ◤, ◣, ◥
  local function require_plain_fragment(fragment, description)
    for _, line in ipairs(lines) do
      if strip_ansi(line):find(fragment, 1, true) then
        return
      end
    end
    table.insert(errors, description)
  end

  local function forbid_plain_fragment(fragment, description)
    for _, line in ipairs(lines) do
      if strip_ansi(line):find(fragment, 1, true) then
        table.insert(errors, description)
        return
      end
    end
  end

  local function delete_connector_tail_reaches_glyph(label, glyph)
    if not ansi_lines then
      return false
    end
    local separator_width = #"\226\148\130" -- │
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) and stripped:find(glyph, 1, true) then
        local glyph_pos = stripped:find(glyph, 1, true)
        local tail_pos = glyph_pos and (glyph_pos + #glyph + separator_width) or nil
        if tail_pos and ansi_underline_at_plain_byte(line, tail_pos) then
          return true
        end
      end
    end
    return false
  end

  if phase == "origin-offscreen" then
    if not find_plain_line(lines, { "Deleted scroll" }) then
      table.insert(errors, "Expected scroll deletion viewport to include deleted content")
    end
    if contains_any_glyph(lines, { "Deleted scroll" }, delete_glyphs) then
      table.insert(errors, "Offscreen-origin deletion rows should show rails/background, not synthetic triangles")
    end
    return errors
  end

  if phase == "left-j-scroll" or phase == "left-j-scroll-line39" or phase == "left-j-scroll-line41" then
    if not find_plain_line(lines, { "Deleted scroll" }) then
      table.insert(errors, "Expected left key-scroll deletion viewport to include deleted content")
    end
    if not find_plain_line(lines, { "Scroll delete context 01" }) then
      table.insert(errors, "Left-pane scroll should leave right pane stationary at the top context")
    end
    if phase == "left-j-scroll" then
      require_plain_fragment("18◣│", "Expected key-scroll deletion split to keep the upper triangle on the projected origin row")
      require_plain_fragment("19◤│", "Expected key-scroll deletion split to keep the lower triangle adjacent to the projected origin row")
    end
    return errors
  end

  if phase == "initial" then
    require_plain_fragment("Deleted scroll A 01                             │  4◤│", "Expected initial deletion target below the origin to use a down-route triangle")
  elseif phase == "target-aligned" then
    require_plain_fragment("Deleted scroll A 01                             │  4◣│", "Expected deletion split upper triangle on the projected origin row")
    require_plain_fragment("Deleted scroll A 02                             │  5◤│", "Expected deletion split lower triangle adjacent to the projected origin row")
  elseif phase == "target-flipped" then
    require_plain_fragment("Deleted scroll A 02                             │  5◣│", "Expected scrolled deletion upper triangle to track the projected origin row")
    require_plain_fragment("Deleted scroll A 03                             │  6◤│", "Expected scrolled deletion lower triangle to stay adjacent to the upper triangle")
  elseif phase == "target-spanning" then
    require_plain_fragment("Deleted scroll A 03                             │  6◣│", "Expected spanning deletion upper triangle to stay anchored to the projected origin")
    require_plain_fragment("Deleted scroll A 04                             │  7◤│", "Expected spanning deletion lower triangle to stay adjacent to the upper triangle")
  elseif phase == "lower-target-below" then
    require_plain_fragment("Deleted scroll A 49                             │ 52◣│", "Expected upper deletion split to remain visible while lower target approaches")
    require_plain_fragment("Deleted scroll A 50                             │ 53◤│", "Expected upper deletion lower split to remain adjacent")
    require_plain_fragment("Deleted scroll B 01                             │ 58◤│", "Expected lower deletion target below origin to use the down-route triangle")
  elseif phase == "lower-target-approach" then
    require_plain_fragment("Deleted scroll B 01                             │ 58◣│", "Expected lower deletion upper split triangle as its block crosses the projected origin")
    require_plain_fragment("Deleted scroll B 02                             │ 59◤│", "Expected lower deletion lower split triangle adjacent to the upper split")
  elseif phase == "same-row-upper" then
    require_plain_fragment("Deleted scroll B 02                             │ 59◣│", "Expected same-row deletion upper split to anchor at the projected origin")
    require_plain_fragment("Deleted scroll B 03                             │ 60◤│", "Expected same-row deletion lower split to stay adjacent")
  elseif phase == "upper-target-exiting" then
    require_plain_fragment("Deleted scroll B 03                             │ 60◣│", "Expected exiting deletion upper split to anchor at the projected origin")
    require_plain_fragment("Deleted scroll B 04                             │ 61◤│", "Expected exiting deletion lower split to stay adjacent")
  elseif phase == "lower-target-entering" then
    require_plain_fragment("Deleted scroll B 04                             │ 61◣│", "Expected entering deletion upper split to anchor at the projected origin")
    require_plain_fragment("Deleted scroll B 05                             │ 62◤│", "Expected entering deletion lower split to stay adjacent")
  elseif phase == "pre-overlap-inner" then
    require_plain_fragment("Deleted scroll B 05                             │ 62◣│", "Expected pre-overlap deletion upper split to anchor at the projected origin")
    require_plain_fragment("Deleted scroll B 06                             │ 63◤│", "Expected pre-overlap deletion lower split to stay adjacent")
  elseif phase == "pre-collision-inner" then
    require_plain_fragment("Deleted scroll B 06                             │ 63◣│            │ 7", "Expected adjacent upward deletion route to terminate at the triangle row without an inner pipe")
    forbid_plain_fragment("Deleted scroll B 06                             │ 63◣│ │", "Adjacent upward deletion route should not draw an inner pipe through the triangle row")
  elseif phase == "target-above" then
    require_plain_fragment("Deleted scroll B 06                             │ 63◣│            │ 6", "Expected deletion target above its origin to connect with an upward triangle and no inner pipe")
    forbid_plain_fragment("Deleted scroll B 06                             │ 63◣│ │", "Upward deletion target should not draw an inner pipe through the triangle row")
    if ansi_lines and not delete_connector_tail_reaches_glyph("Deleted scroll B 06", "\226\151\163") then
      table.insert(errors, "Expected upward deletion tail underline to reach the connector cell beside B06")
    end
  elseif phase == "upper-target-clipped" then
    require_plain_fragment("Deleted scroll B 06                             │ 63◣│            │ 5", "Expected clipped deletion target to keep the real triangle while visible")
    forbid_plain_fragment("Deleted scroll B 06                             │ 63◣│ │", "Clipped deletion target should not draw an inner pipe through the visible triangle")
    if ansi_lines and not delete_connector_tail_reaches_glyph("Deleted scroll B 06", "\226\151\163") then
      table.insert(errors, "Expected clipped upward deletion tail underline to reach the connector cell beside B06")
    end
  elseif phase == "overlap-stepped" then
    require_plain_fragment("Deleted scroll B 06                             │ 63◣│            │ 4", "Expected overlap transition row to avoid an inner visible-route pipe")
    require_plain_fragment("Scroll delete context 06                        │ 64 │ │", "Expected visible deletion route to continue from the origin row")
    if ansi_lines and not delete_connector_tail_reaches_glyph("Deleted scroll B 06", "\226\151\163") then
      table.insert(errors, "Expected overlap deletion tail underline to reach the connector cell beside B06")
    end
  elseif phase == "hidden-overlap-inner" then
    require_plain_fragment("Deleted scroll B 06                             │ 63◣│   │", "Expected hidden upper deletion route to step outward beside the visible triangle")
    forbid_plain_fragment("Deleted scroll B 06                             │ 63◣│ │ │", "Hidden overlap should not collide with the visible route lane on the triangle row")
    if ansi_lines and not delete_connector_tail_reaches_glyph("Deleted scroll B 06", "\226\151\163") then
      table.insert(errors, "Expected hidden-overlap deletion tail underline to reach the connector cell beside B06")
    end
  end

  local _, _, glyph = find_plain_line(lines, { "Deleted scroll" }, delete_glyphs)
  if not glyph then
    table.insert(errors, "Expected scroll deletion viewport to show a real directional transition glyph")
    return errors
  end

  if ansi_lines and glyph then
    local found_transition = false
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Deleted scroll", 1, true) and stripped:find(glyph, 1, true) then
        local transition = ansi_glyph_transition_bgs(line, glyph)
        found_transition = transition and transition.before
          and transition.glyph ~= transition.before
          and transition.after ~= transition.before
        break
      end
    end
    if not found_transition then
      table.insert(errors, "Expected scroll deletion background to stop before the transition glyph")
    end
  end

  return errors
end

local function verify_scroll_mixed(lines, ansi_lines, phase)
  local errors = {}
  if phase == "clamped-end" then
    if not find_plain_line(lines, { "Scroll mixed context 15" }) then
      table.insert(errors, "Expected mixed clamped-end capture to include final context")
    end
    return errors
  end

  if phase == "initial" then
    if not find_plain_line(lines, { "Old scroll value A" }) then
      table.insert(errors, "Expected initial mixed scroll capture to include changed text")
    end
    return errors
  else
    if not find_plain_line(lines, { "Added mixed scroll", "Modified scroll header" }) then
      table.insert(errors, "Expected clipped mixed scroll capture to include the mixed envelope")
    end
  end

  local wedge_glyphs = { "\226\151\162", "\226\151\165" } -- ◢, ◥
  if phase == "origin-offscreen" or phase == "right-diverged" or phase == "right-j-scroll" then
    if contains_any_glyph(lines, { "Added mixed scroll", "Modified scroll header" }, wedge_glyphs) then
      table.insert(errors, "Offscreen-origin mixed rows should not invent synthetic wedges")
    end
    if phase == "right-j-scroll" and not find_plain_line(lines, { "Scroll mixed context 01" }) then
      table.insert(errors, "Right-pane mixed scroll should leave left pane stationary at the top context")
    end
    return errors
  end

  local _, stripped, glyph = find_plain_line(lines, { "Modified scroll header", "Added mixed scroll" }, wedge_glyphs)
  if not glyph then
    table.insert(errors, "Expected scroll mixed viewport to show a real mixed wedge near the connection row")
  elseif not glyph_docked_to_right_number(stripped, glyph) then
    table.insert(errors, "Expected scroll mixed wedge to dock directly against the right line number")
  end

  if ansi_lines and glyph then
    local found_transition = false
    for _, line in ipairs(ansi_lines) do
      local stripped_line = strip_ansi(line)
      if (stripped_line:find("Modified scroll header", 1, true)
          or stripped_line:find("Added mixed scroll", 1, true))
          and stripped_line:find(glyph, 1, true) then
        local transition = ansi_glyph_transition_bgs(line, glyph)
        found_transition = transition and transition.after and transition.glyph ~= transition.after
        break
      end
    end
    if not found_transition then
      table.insert(errors, "Expected scroll mixed background to start after the wedge")
    end
  end

  return errors
end

local function verify_scroll_changes(lines, ansi_lines, phase)
  local errors = {}
  if phase == "clamped-end" then
    if not find_plain_line(lines, { "Scroll change context 22" }) then
      table.insert(errors, "Expected changes clamped-end capture to include final context")
    end
    return errors
  end

  if phase == "initial" then
    if not find_plain_line(lines, { "Old routed change A" }) then
      table.insert(errors, "Expected initial change capture to include old changed text")
    end
    if not find_plain_line(lines, { "New routed change A" }) then
      table.insert(errors, "Expected initial change capture to include new changed text")
    end
    return errors
  end

  local change_glyphs = { "\226\151\164", "\226\151\165", "\226\151\162" } -- ◤, ◥, ◢
  if not find_plain_line(lines, { "Old routed change", "New routed change" }) then
    table.insert(errors, "Expected diverged change capture to include changed content")
  end
  if not contains_any_glyph(lines, { "Old routed change", "New routed change" }, change_glyphs) then
    table.insert(errors, "Expected diverged changed rows to use routed transition glyphs")
  end
  if phase == "right-j-scroll" and not find_plain_line(lines, { "Scroll change context 01" }) then
    table.insert(errors, "Right-pane change scroll should leave left pane stationary at the top context")
  end
  if phase == "left-j-scroll" and not find_plain_line(lines, { "Scroll change context 01" }) then
    table.insert(errors, "Left-pane change scroll should leave right pane stationary at the top context")
  end

  if ansi_lines and not contains_any_glyph(lines, { "Old routed change", "New routed change" }, change_glyphs) then
    table.insert(errors, "Expected ANSI-backed change route to include a transition glyph")
  end

  return errors
end

-- Main
local capture_file = arg[1]
local test_name = arg[2] or "extreme"
local ansi_capture_file = arg[3]

if not capture_file then
  io.stderr:write("Usage: lua verify.lua <capture_file> [test_name]\n")
  io.stderr:write("  test_name: 'extreme' or 'pure' (default: extreme)\n")
  os.exit(1)
end

local lines = read_capture(capture_file)
local ansi_lines = ansi_capture_file and read_capture(ansi_capture_file) or nil

if #lines == 0 then
  io.stderr:write("ERROR: Capture file is empty\n")
  os.exit(1)
end

local errors
local scroll_base, scroll_phase = test_name:match("^([^:]+):(.+)$")
if scroll_base == "scroll-additions" then
  errors = verify_scroll_additions(lines, ansi_lines, scroll_phase)
elseif scroll_base == "scroll-deletions" then
  errors = verify_scroll_deletions(lines, ansi_lines, scroll_phase)
elseif scroll_base == "scroll-mixed" then
  errors = verify_scroll_mixed(lines, ansi_lines, scroll_phase)
elseif scroll_base == "scroll-changes" then
  errors = verify_scroll_changes(lines, ansi_lines, scroll_phase)
elseif test_name == "pure" then
  errors = verify_pure_additions(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "New line 1", "New line 6" })) do
    table.insert(errors, err)
  end
elseif test_name == "deletions" then
  errors = verify_deletions(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "Line to delete 1", "Line to delete 4" })) do
    table.insert(errors, err)
  end
elseif test_name == "mixed" then
  errors = verify_mixed(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "Old value A", "Delete this line", "Added line 1" })) do
    table.insert(errors, err)
  end
elseif test_name == "comprehensive" then
  errors = verify_comprehensive(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "\"time\"", "This section will", "Added performance check" })) do
    table.insert(errors, err)
  end
else
  errors = verify_extreme_additions(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "New after Foxtrot 1", "New after Hotel 1" })) do
    table.insert(errors, err)
  end
end

if #errors > 0 then
  io.stderr:write("Integration test FAILED:\n")
  for _, err in ipairs(errors) do
    io.stderr:write("  - " .. err .. "\n")
  end
  os.exit(1)
end

print("Integration test passed!")
os.exit(0)
