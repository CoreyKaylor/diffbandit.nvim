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
  for code in codes:gmatch("%d+") do
    if code == wanted then
      return true
    end
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
      if stripped:find("6%s+│%s+6%s+│Sixth line") then
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
    table.insert(errors, "Pure deletion continuation rail should stay immediately after the left line number")
  end
  add_ansi_underline_check(errors, ansi_lines, 2, "deletion origins")
  if not delete_origin_underline_reaches_edge then
    table.insert(errors, "Pure deletion origin underline should reach the right edge of the gutter")
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
  local delete_origin_underline_reaches_edge, delete_origin_underline_at_triangle
  local delete_origin_underline_after_triangle
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
        local left_num_pos = stripped:find("5", 1, true)
        if left_num_pos then
          local delete_wedge_col = left_num_pos + 1
          delete_origin_underline_at_triangle = ansi_underline_at_plain_byte(line, delete_wedge_col)
          delete_origin_underline_after_triangle = ansi_underline_at_plain_byte(line, delete_wedge_col + 1)
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
  if delete_origin_underline_at_triangle then
    table.insert(errors, "Delete origin underline should start after the delete triangle cell")
  end
  if not delete_origin_underline_after_triangle then
    table.insert(errors, "Delete origin underline should begin immediately after the delete triangle")
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
    "This section will be deleted",
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

  local add_glyphs = { "\226\151\165", "\226\151\162" } -- ◥, ◢
  if phase == "origin-offscreen" or phase == "right-j-scroll" then
    if not find_plain_line(lines, { "Added scroll" }) then
      table.insert(errors, "Expected scroll addition viewport to include added content")
    end
    if contains_any_glyph(lines, { "Added scroll" }, add_glyphs) then
      table.insert(errors, "Offscreen-origin addition rows should show rails/background, not synthetic triangles")
    end
    if phase == "right-j-scroll" and not find_plain_line(lines, { "Scroll add context 01" }) then
      table.insert(errors, "Right-pane scroll should leave left pane stationary at the top context")
    end
    return errors
  end

  if phase == "target-above" or phase == "target-spanning" then
    local _, _, glyph = find_plain_line(lines, { "Added scroll" }, add_glyphs)
    if not glyph then
      table.insert(errors, "Expected independent addition viewport to show a directional transition glyph")
    end
    return errors
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

  local delete_glyphs = { "\226\151\164", "\226\151\165" } -- ◤, ◥
  if phase == "origin-offscreen" or phase == "left-j-scroll" then
    if not find_plain_line(lines, { "Deleted scroll" }) then
      table.insert(errors, "Expected scroll deletion viewport to include deleted content")
    end
    if contains_any_glyph(lines, { "Deleted scroll" }, delete_glyphs) then
      table.insert(errors, "Offscreen-origin deletion rows should show rails/background, not synthetic triangles")
    end
    if phase == "left-j-scroll" and not find_plain_line(lines, { "Scroll delete context 01" }) then
      table.insert(errors, "Left-pane scroll should leave right pane stationary at the top context")
    end
    return errors
  end

  if phase == "target-above" or phase == "target-spanning" then
    local _, _, glyph = find_plain_line(lines, { "Deleted scroll" }, delete_glyphs)
    if not glyph then
      table.insert(errors, "Expected independent deletion viewport to show a directional transition glyph")
    end
    return errors
  end

  local _, _, glyph = find_plain_line(lines, { "Deleted scroll" }, delete_glyphs)
  if not glyph then
    table.insert(errors, "Expected initial scroll deletion viewport to show the real transition glyph")
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
  if phase == "origin-offscreen" or phase == "right-j-scroll" then
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
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "\"time\"", "This section will be deleted", "Added performance check" })) do
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
