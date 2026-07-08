#!/usr/bin/env lua
-- Verify tmux capture output for expected visual elements
-- Usage: lua verify.lua <capture_file> [test_name]

local function strip_ansi(s)
  return s:gsub("\27%[[%d;:]*m", "")
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

local function sgr_background(codes)
  if sgr_has(codes, "0") or sgr_has(codes, "49") then
    return false
  end

  local parts = {}
  for code in codes:gmatch("%d+") do
    parts[#parts + 1] = code
  end

  local i = 1
  while i <= #parts do
    local code = tonumber(parts[i])
    if code == 48 then
      local mode = parts[i + 1]
      if mode == "2" then
        local r, g, b = parts[i + 2], parts[i + 3], parts[i + 4]
        if r and g and b then
          return table.concat({ r, g, b }, ";")
        end
        i = i + 5
      elseif mode == "5" then
        local color = parts[i + 2]
        if color then
          return "idx:" .. color
        end
        i = i + 3
      else
        i = i + 1
      end
    elseif code and ((code >= 40 and code <= 47) or (code >= 100 and code <= 107)) then
      return "ansi:" .. tostring(code)
    else
      i = i + 1
    end
  end

  return nil
end

local function has_ansi_background(line)
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
    if not esc_start then
      return false
    end
    if type(sgr_background(codes)) == "string" then
      return true
    end
    pos = esc_end + 1
  end
  return false
end

local function has_ansi_underline(line)
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
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
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
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

    local bg = sgr_background(codes)
    if bg == false then
      current_bg = nil
    elseif bg then
      current_bg = bg
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
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
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

    local bg = sgr_background(codes)
    if bg == false then
      current_bg = nil
    elseif bg then
      current_bg = bg
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
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
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

    local bg = sgr_background(codes)
    if bg == false then
      current_bg = nil
    elseif bg then
      current_bg = bg
    end
    pos = esc_end + 1
  end
  return nil
end

local function ansi_final_bg(line)
  local current_bg = nil
  local pos = 1
  while pos <= #line do
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
    if not esc_start then
      break
    end
    local bg = sgr_background(codes)
    if bg == false then
      current_bg = nil
    elseif bg then
      current_bg = bg
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
    local esc_start, esc_end, codes = line:find("\27%[([%d;:]*)m", pos)
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

local function ansi_rgb_luminance(bg)
  if not bg then
    return nil
  end
  local r, g, b = bg:match("^(%d+);(%d+);(%d+)$")
  if not r then
    return nil
  end
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  return ((0.2126 * r) + (0.7152 * g) + (0.0722 * b)) / 255
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
      local pattern = "%s" .. num_str .. "[%s%d│]"
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
      local pattern = "%s" .. num_str .. "[%s%d│]"
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
      if stripped:find("6%s+││%s+│%s*6%s+│Sixth line")
          or stripped:find("6%s+│%s│%s+│%s*6%s+│Sixth line") then
        pure_delete_rail_after_left_number = true
      end
    end
  end

  if ansi_lines then
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Second line", 1, true) then
        local start = 1
        while true do
          local right_sep_pos = stripped:find("│Second line", start, true)
          if not right_sep_pos then
            break
          end
          delete_origin_underline_reaches_edge =
            delete_origin_underline_reaches_edge or ansi_underline_at_plain_byte(line, right_sep_pos - 1)
          start = right_sep_pos + 1
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
    table.insert(errors, "Pure deletion continuation rail should stay docked after the left number pane")
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
  local modified_word_bg, modified_tail_bg, added_suffix_bg
  local delete_before_bg, delete_glyph_bg, delete_after_bg
  local saw_delete_transition_glyph = false
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
        local start = 1
        while true do
          local right_sep_pos = stripped:find("│Context line 3", start, true)
          if not right_sep_pos then
            break
          end
          delete_origin_underline_reaches_edge =
            delete_origin_underline_reaches_edge or ansi_underline_at_plain_byte(line, right_sep_pos - 1)
          start = right_sep_pos + 1
        end
      elseif stripped:find("Delete this line", 1, true) and stripped:find("\226\151\164", 1, true) then
        -- Sample the delete-origin triangle transition only on the deleted
        -- row itself: adjacent add chunks route independently now, so other
        -- rows (e.g. "Original text here") can carry a left-family wedge too.
        saw_delete_transition_glyph = true
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
        local wedge_pos = stripped:find(change_wedge_top, 1, true)
        if wedge_pos then
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
  if not top_wedge_docked_to_right_number then
    table.insert(errors, "Mixed replacement wedge should dock directly against the right line number")
  end
  if not delete_origin_underline_reaches_edge then
    table.insert(errors, "Delete origin underline should reach the right edge of the gutter")
  end
  if saw_delete_transition_glyph and not delete_before_bg then
    table.insert(errors, "Expected mixed delete gutter background before the triangle")
  elseif saw_delete_transition_glyph and delete_glyph_bg == delete_before_bg then
    table.insert(errors, "Mixed delete triangle cell should not share the left delete gutter background")
  elseif saw_delete_transition_glyph and delete_after_bg == delete_before_bg then
    table.insert(errors, "Mixed delete gutter background should not continue broadly after the triangle")
  end
  -- Added rows adjacent to the change are absorbed into the merged chunk
  -- (word-driven blocks fuse abutting adds into the change region). The
  -- terminal absorbed add row keeps its add background over the text and
  -- closes with the change envelope after it.
  if not added_line2_bg or not added_line2_after_bg then
    table.insert(errors, "Expected ANSI backgrounds for terminal added row")
  elseif added_line2_bg == added_line2_after_bg then
    table.insert(errors, "Terminal absorbed add row should close with the change envelope after its text")
  else
    if modified_tail_bg and added_line2_bg == modified_tail_bg then
      table.insert(errors, "Terminal added row text should stay add-colored, not the change envelope")
    end
    if modified_tail_bg and added_line2_after_bg ~= modified_tail_bg then
      table.insert(errors, "Terminal added row tail should continue the change envelope")
    end
  end

  return errors
end

local function verify_theme_default(lines, ansi_lines)
  local errors = verify_mixed(lines, ansi_lines)
  if not ansi_lines then
    table.insert(errors, "ANSI capture missing; cannot verify default theme delete background")
    return errors
  end

  local delete_bg
  for _, line in ipairs(ansi_lines) do
    local stripped = strip_ansi(line)
    if stripped:find("Delete this line", 1, true) then
      local transition = ansi_glyph_transition_bgs(line, "\226\151\164")
      delete_bg = transition and transition.before or ansi_bg_for_text(line, "Delete this line")
      break
    end
  end

  local lum = ansi_rgb_luminance(delete_bg)
  if not lum then
    table.insert(errors, "Expected ANSI RGB delete background for default theme")
  elseif lum > 0.65 then
    table.insert(errors, "Default theme delete background should not use a light fallback")
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
    "Added performance",
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

local function find_plain_line_all(lines, labels, glyphs)
  for _, line in ipairs(lines) do
    local stripped = strip_ansi(line)
    local ok = true
    for _, label in ipairs(labels) do
      if not stripped:find(label, 1, true) then
        ok = false
        break
      end
    end
    if ok then
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

local function plain_fragment_requirements(errors, lines)
  -- Like require_plain_fragment but with a Lua pattern, so expectations can
  -- stay agnostic to the computed connector core width (%s+ runs).
  local function require_pattern_fragment(pattern, description)
    for _, line in ipairs(lines) do
      if strip_ansi(line):find(pattern) then
        return
      end
    end
    table.insert(errors, description)
  end

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

  return require_plain_fragment, forbid_plain_fragment, require_pattern_fragment
end

local function verify_git(lines, ansi_lines, phase)
  local errors = {}
  local require_plain_fragment, forbid_plain_fragment = plain_fragment_requirements(errors, lines)

  if phase == "untracked" then
    require_plain_fragment("New untracked file",
      "Expected untracked Git file capture to show a helpful missing-base notice")
    require_plain_fragment("brand new content one",
      "Expected untracked Git file capture to show working tree content")
    forbid_plain_fragment("git add",
      "Untracked Git file capture should not show raw Git advice text")
    for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "brand new content one" })) do
      table.insert(errors, err)
    end
  elseif phase == "deleted" then
    require_plain_fragment("Deleted file",
      "Expected deleted Git file capture to show a helpful missing-current notice")
    require_plain_fragment("deleted line one",
      "Expected deleted Git file capture to show deleted source content")
    for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "deleted line one" })) do
      table.insert(errors, err)
    end
  elseif phase == "staged-added" then
    require_plain_fragment("New file",
      "Expected staged added Git file capture to show a helpful missing-base notice")
    require_plain_fragment("staged added line one",
      "Expected staged added Git file capture to show index content")
    for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "staged added line one" })) do
      table.insert(errors, err)
    end
  elseif phase == "binary" then
    require_plain_fragment("binary.bin",
      "Expected binary Git capture to show the binary file name")
    require_plain_fragment("00000000",
      "Expected binary Git capture to show byte offsets")
    require_plain_fragment("00 01 02 03",
      "Expected binary Git capture to show left-side hex bytes")
    require_plain_fragment("00 01 02 04",
      "Expected binary Git capture to show right-side changed hex bytes")
    forbid_plain_fragment("binary file skipped",
      "Binary Git capture should render a hex comparison instead of skipping")
    forbid_plain_fragment("□",
      "Binary Git capture should not show mutable hunk markers")
    forbid_plain_fragment("▣",
      "Binary Git capture should not show staged hunk markers")
  elseif phase == "binary-truncated" then
    require_plain_fragment("[DiffBandit: hex view truncated at 8",
      "Expected large binary Git capture to show a truncation notice")
    require_plain_fragment("00000000",
      "Expected large binary Git capture to show offsets")
  elseif phase == "symlink" then
    require_plain_fragment("symlink -> old-target.txt",
      "Expected symlink Git capture to show old symlink target")
    require_plain_fragment("symlink -> new-target.txt",
      "Expected symlink Git capture to show new symlink target")
    forbid_plain_fragment("□",
      "Symlink Git capture should not show mutable hunk markers")
  elseif phase == "mode-only" then
    require_plain_fragment("mode change 100644 => 100755",
      "Expected mode-only Git capture to show executable-bit metadata")
    forbid_plain_fragment("□",
      "Mode-only Git capture should not show mutable hunk markers")
  elseif phase == "unmerged" then
    require_plain_fragment("Unmerged file: resolve conflicts outside",
      "Expected unmerged Git capture to explain conflict state")
    forbid_plain_fragment("□",
      "Unmerged Git capture should not show mutable hunk markers")
  elseif phase == "submodule" then
    require_plain_fragment("Submodule",
      "Expected submodule Git capture to show submodule metadata")
    forbid_plain_fragment("□",
      "Submodule Git capture should not show mutable hunk markers")
  elseif phase == "live-buffer" then
    require_plain_fragment("saved buffer line",
      "Expected live-buffer Git capture to show the saved index/base text")
    require_plain_fragment("unsaved buffer line",
      "Expected live-buffer Git capture to show unsaved buffer text")
    require_plain_fragment("□",
      "Expected live-buffer Git capture to show unstaged hunk marker")
    for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "unsaved buffer line" })) do
      table.insert(errors, err)
    end
  elseif phase == "action-unstaged-marker" then
    require_plain_fragment("action changed line",
      "Expected action Git capture to show unstaged changed content")
    require_plain_fragment("□",
      "Expected action Git capture to show unstaged hunk marker")
    if count_occurrences(lines, "□") ~= 1 then
      table.insert(errors, "Expected unstaged hunk marker to render once on the mutable side")
    end
  elseif phase == "action-staged-marker" then
    require_plain_fragment("action changed line",
      "Expected staged action Git capture to show staged changed content")
    require_plain_fragment("▣",
      "Expected staged action Git capture to show staged hunk marker")
    if count_occurrences(lines, "▣") ~= 1 then
      table.insert(errors, "Expected staged hunk marker to render once on the mutable side")
    end
  else
    table.insert(errors, "Unknown Git integration phase: " .. tostring(phase))
  end

  return errors
end

local function nth_plain_pos(line, needle, n)
  local from = 1
  local pos
  for _ = 1, n do
    pos = line:find(needle, from, true)
    if not pos then
      return nil
    end
    from = pos + #needle
  end
  return pos
end

local function connector_core_bounds(stripped)
  local separators = {}
  local from = 1
  while true do
    local pos = stripped:find("│", from, true)
    if not pos then
      break
    end
    separators[#separators + 1] = pos
    from = pos + #"│"
  end

  local has_overview_pane = (separators[1] or 999) <= 3
  if has_overview_pane then
    return separators[3], separators[#separators - 2]
  end
  return separators[2], separators[#separators - 2]
end

local function connector_core_pipe_count(stripped)
  local core_start, core_end = connector_core_bounds(stripped)
  if not core_start or not core_end then
    return 0
  end

  local count = 0
  local from = core_start + #"│"
  while true do
    local pos = stripped:find("│", from, true)
    if not pos or pos >= core_end then
      break
    end
    count = count + 1
    from = pos + #"│"
  end
  return count
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
      elseif first_content and stripped:find("│%s+│%s+│%s+│") then
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
  local function internal_connector_pipe_count(stripped)
    return connector_core_pipe_count(stripped)
  end
  local function row_has_internal_connector_pipe(stripped)
    return internal_connector_pipe_count(stripped) > 0
  end

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
          and row_has_internal_connector_pipe(stripped) then
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
          and row_has_internal_connector_pipe(stripped) then
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
        if stripped:find("│%s+│◢53") then
          found_tail_terminal = true
        end
        if row_has_internal_connector_pipe(stripped) then
          found_tail_pipe = true
        end
      elseif stripped:find("Scroll add origin A", 1, true)
          and row_has_internal_connector_pipe(stripped) then
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
        if stripped:find("│%s+│◢53") then
          found_tail_terminal = true
        end
        if row_has_internal_connector_pipe(stripped) then
          found_tail_pipe = true
        end
      elseif stripped:find("Scroll add origin A", 1, true)
          and row_has_internal_connector_pipe(stripped) then
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
    local found_b_origin_rail = false
    local found_b_tail_terminal = false
    local found_b_tail_pipe = false
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      if stripped:find("Scroll add origin A", 1, true)
          and row_has_internal_connector_pipe(stripped) then
        found_a_origin_rail = true
      elseif stripped:find("Added scroll B 06", 1, true) then
        if stripped:find("│%s+│◢63") then
          found_b_tail_terminal = true
        end
        if row_has_internal_connector_pipe(stripped) then
          found_b_tail_pipe = true
        end
      elseif stripped:find("Scroll add origin B", 1, true)
          and row_has_internal_connector_pipe(stripped) then
        found_b_origin_rail = true
      end
    end
    if not found_a_origin_rail then
      table.insert(errors, "Expected clipped upper addition route to keep a continuation rail at origin A")
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
        if row_has_internal_connector_pipe(stripped) then
          found_inner_a_origin = true
        end
        if internal_connector_pipe_count(stripped) > 1 then
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
        if row_has_internal_connector_pipe(stripped) then
          found_inner_a_origin = true
        end
        if internal_connector_pipe_count(stripped) > 1 then
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
          and row_has_internal_connector_pipe(stripped) then
        found_stepped_clipped_upper = true
      elseif stripped:find("Scroll add origin A", 1, true)
          and stripped:find("Added scroll B 06", 1, true) then
        found_inner_triangle = true
        if internal_connector_pipe_count(stripped) > 1 then
          found_inner_triangle_pipe = true
          found_lower_stepped_triangle = true
        end
      elseif stripped:find("Scroll add origin B", 1, true)
          and stripped:find("Scroll add context 09", 1, true)
          and row_has_internal_connector_pipe(stripped) then
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
      table.insert(errors, "Expected lower route triangle row not to carry multiple connector pipes")
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
          and internal_connector_pipe_count(stripped) > 1 then
        found_shared_overlap = true
      elseif stripped:find("Scroll add origin B", 1, true) then
        if row_has_internal_connector_pipe(stripped) then
          found_lower_inner_origin = true
        end
        if internal_connector_pipe_count(stripped) > 1 then
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
          and row_has_internal_connector_pipe(stripped) then
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
          and row_has_internal_connector_pipe(stripped) then
        found_lower_clipped_rail = true
      elseif stripped:find("Scroll add context 09", 1, true)
          and stripped:find("Added scroll A 08", 1, true)
          and row_has_internal_connector_pipe(stripped) then
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
  local require_plain_fragment, forbid_plain_fragment = plain_fragment_requirements(errors, lines)
  local function require_plain_fragments(fragments, description)
    if find_plain_line_all(lines, fragments) then
      return
    end
    table.insert(errors, description)
  end
  local function require_deleted_b06_target(right_number, description)
    local _, stripped = find_plain_line_all(lines, {
      "Deleted scroll B 06",
      "│ 63◣│",
      "│ " .. tostring(right_number),
    })
    if not stripped then
      table.insert(errors, description)
    end
    return stripped
  end

  if phase == "origin-offscreen" then
    if not find_plain_line(lines, { "Deleted scroll" }) then
      table.insert(errors, "Expected scroll deletion viewport to include deleted content")
    end
    if not contains_any_glyph(lines, { "Deleted scroll" }, delete_glyphs) then
      table.insert(errors, "Offscreen-origin deletion target should keep its real visible transition triangle")
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
    require_plain_fragments({ "Deleted scroll A 01", "│  4◤│" },
      "Expected initial deletion target below the origin to use a down-route triangle")
  elseif phase == "target-aligned" then
    require_plain_fragments({ "Deleted scroll A 01", "│  4◣│" },
      "Expected deletion split upper triangle on the projected origin row")
    require_plain_fragments({ "Deleted scroll A 02", "│  5◤│" },
      "Expected deletion split lower triangle adjacent to the projected origin row")
  elseif phase == "target-flipped" then
    require_plain_fragments({ "Deleted scroll A 02", "│  5◣│" },
      "Expected scrolled deletion upper triangle to track the projected origin row")
    require_plain_fragments({ "Deleted scroll A 03", "│  6◤│" },
      "Expected scrolled deletion lower triangle to stay adjacent to the upper triangle")
  elseif phase == "target-spanning" then
    require_plain_fragments({ "Deleted scroll A 03", "│  6◣│" },
      "Expected spanning deletion upper triangle to stay anchored to the projected origin")
    require_plain_fragments({ "Deleted scroll A 04", "│  7◤│" },
      "Expected spanning deletion lower triangle to stay adjacent to the upper triangle")
  elseif phase == "lower-target-below" then
    require_plain_fragments({ "Deleted scroll A 49", "│ 52◣│" },
      "Expected upper deletion split to remain visible while lower target approaches")
    require_plain_fragments({ "Deleted scroll A 50", "│ 53◤│" },
      "Expected upper deletion lower split to remain adjacent")
    require_plain_fragments({ "Deleted scroll B 01", "│ 58◤│" },
      "Expected lower deletion target below origin to use the down-route triangle")
  elseif phase == "lower-target-approach" then
    require_plain_fragments({ "Deleted scroll B 01", "│ 58◣│" },
      "Expected lower deletion upper split triangle as its block crosses the projected origin")
    require_plain_fragments({ "Deleted scroll B 02", "│ 59◤│" },
      "Expected lower deletion lower split triangle adjacent to the upper split")
  elseif phase == "same-row-upper" then
    require_plain_fragments({ "Deleted scroll B 02", "│ 59◣│" },
      "Expected same-row deletion upper split to anchor at the projected origin")
    require_plain_fragments({ "Deleted scroll B 03", "│ 60◤│" },
      "Expected same-row deletion lower split to stay adjacent")
  elseif phase == "upper-target-exiting" then
    require_plain_fragments({ "Deleted scroll B 03", "│ 60◣│" },
      "Expected exiting deletion upper split to anchor at the projected origin")
    require_plain_fragments({ "Deleted scroll B 04", "│ 61◤│" },
      "Expected exiting deletion lower split to stay adjacent")
  elseif phase == "lower-target-entering" then
    require_plain_fragments({ "Deleted scroll B 04", "│ 61◣│" },
      "Expected entering deletion upper split to anchor at the projected origin")
    require_plain_fragments({ "Deleted scroll B 05", "│ 62◤│" },
      "Expected entering deletion lower split to stay adjacent")
  elseif phase == "pre-overlap-inner" then
    require_plain_fragments({ "Deleted scroll B 05", "│ 62◣│" },
      "Expected pre-overlap deletion upper split to anchor at the projected origin")
    require_plain_fragments({ "Deleted scroll B 06", "│ 63◤│" },
      "Expected pre-overlap deletion lower split to stay adjacent")
  elseif phase == "pre-collision-inner" then
    local stripped = require_deleted_b06_target(7,
      "Expected adjacent upward deletion route to terminate at the triangle row without an inner pipe")
    if stripped and connector_core_pipe_count(stripped) > 0 then
      table.insert(errors, "Adjacent upward deletion route should not draw an inner pipe through the triangle row")
    end
  elseif phase == "target-above" then
    local stripped = require_deleted_b06_target(6,
      "Expected deletion target above its origin to connect with an upward triangle and no inner pipe")
    if stripped and connector_core_pipe_count(stripped) > 0 then
      table.insert(errors, "Upward deletion target should not draw an inner pipe through the triangle row")
    end
  elseif phase == "upper-target-clipped" then
    local stripped = require_deleted_b06_target(5,
      "Expected clipped deletion target to keep the real triangle while visible")
    if stripped and connector_core_pipe_count(stripped) > 0 then
      table.insert(errors, "Clipped deletion target should not draw an inner pipe through the visible triangle")
    end
  elseif phase == "overlap-stepped" then
    local stripped = require_deleted_b06_target(4,
      "Expected overlap transition row to avoid an inner visible-route pipe")
    if stripped and connector_core_pipe_count(stripped) > 0 then
      table.insert(errors, "Expected overlap transition row to avoid an inner visible-route pipe")
    end
    local _, context = find_plain_line_all(lines, { "Scroll delete context 06", "│ 64 │" })
    if not context or connector_core_pipe_count(context) == 0 then
      table.insert(errors, "Expected visible deletion route to continue from the origin row")
    end
  elseif phase == "hidden-overlap-inner" then
    local _, stripped = find_plain_line_all(lines, { "Deleted scroll B 06", "│ 63◣│" })
    if not stripped then
      table.insert(errors, "Expected hidden upper deletion route to step outward beside the visible triangle")
    end
    if stripped and connector_core_pipe_count(stripped) == 0 then
      table.insert(errors, "Expected hidden upper deletion route to step outward beside the visible triangle")
    end
    if stripped and connector_core_pipe_count(stripped) > 1 then
      table.insert(errors, "Hidden overlap should not collide with the visible route lane on the triangle row")
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
  local function plain_bar_positions(line)
    local positions = {}
    local from = 1
    while true do
      local pos = line:find("│", from, true)
      if not pos then
        break
      end
      positions[#positions + 1] = pos
      from = pos + #"│"
    end
    return positions
  end
  local function require_plain_line_all(labels, description)
    local _, stripped = find_plain_line_all(lines, labels)
    if not stripped then
      table.insert(errors, description)
      return nil
    end
    return stripped
  end
  local function require_no_core_route(labels, description)
    local stripped = require_plain_line_all(labels, description)
    if not stripped then
      return
    end
    if connector_core_pipe_count(stripped) ~= 0 then
      table.insert(errors, description)
    end
  end
  local function number_pane_bounds(stripped, side)
    local bars = plain_bar_positions(stripped)
    local has_overview_pane = (bars[1] or 999) <= 3
    if side == "left" then
      if has_overview_pane then
        if #bars < 3 then
          return nil, nil
        end
        return bars[2] + #"│", bars[3] - 1
      end
      if #bars < 2 then
        return nil, nil
      end
      return bars[1] + #"│", bars[2] - 1
    end
    if has_overview_pane then
      if #bars < 5 then
        return nil, nil
      end
      return bars[#bars - 2] + #"│", bars[#bars - 1] - 1
    end
    if #bars < 4 then
      return nil, nil
    end
    return bars[#bars - 1] + #"│", bars[#bars] - 1
  end
  local function first_number_pane_ascii_bg(label, side)
    if not ansi_lines then
      return nil
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) then
        local start_pos, end_pos = number_pane_bounds(stripped, side)
        if start_pos and end_pos then
          for pos = start_pos, end_pos do
            local byte = stripped:sub(pos, pos)
            if byte:match("[%d ]") then
              return ansi_bg_at_plain_byte(line, pos)
            end
          end
        end
      end
    end
    return nil
  end
  -- Digits-only sampler: number panes keep a default-background spacer cell
  -- before the number, so sampling [%d ] cells would return the spacer bg.
  local function first_number_pane_digit_bg(label, side)
    if not ansi_lines then
      return nil
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) then
        local start_pos, end_pos = number_pane_bounds(stripped, side)
        if start_pos and end_pos then
          for pos = start_pos, end_pos do
            if stripped:sub(pos, pos):match("%d") then
              return ansi_bg_at_plain_byte(line, pos)
            end
          end
        end
      end
    end
    return nil
  end
  local function require_number_pane_bg(label, side, expected_bg, description, also_label)
    if not ansi_lines then
      table.insert(errors, "ANSI capture missing; cannot verify number pane background")
      return
    end
    local saw_line = false
    local checked = false
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) and (not also_label or stripped:find(also_label, 1, true)) then
        saw_line = true
        local start_pos, end_pos = number_pane_bounds(stripped, side)
        if not start_pos or not end_pos then
          table.insert(errors, "Expected number pane bounds for: " .. label)
          return
        end
        for pos = start_pos, end_pos do
          local byte = stripped:sub(pos, pos)
          if byte:match("[%d ]") then
            checked = true
            local bg = ansi_bg_at_plain_byte(line, pos)
            if not bg or (expected_bg and bg ~= expected_bg) then
              table.insert(errors, description)
              return
            end
          end
        end
        break
      end
    end
    if not saw_line then
      table.insert(errors, "Expected mixed row for number pane background check: " .. label)
    elseif not checked then
      table.insert(errors, "Expected ASCII number cells for number pane background check: " .. label)
    end
  end
  local function require_number_text_bg(label, side, expected_bg, description, also_label)
    if not ansi_lines then
      table.insert(errors, "ANSI capture missing; cannot verify number text background")
      return
    end
    local saw_line = false
    local checked = false
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) and (not also_label or stripped:find(also_label, 1, true)) then
        saw_line = true
        local start_pos, end_pos = number_pane_bounds(stripped, side)
        if not start_pos or not end_pos then
          table.insert(errors, "Expected number pane bounds for: " .. label)
          return
        end
        for pos = start_pos, end_pos do
          local byte = stripped:sub(pos, pos)
          if byte:match("%d") then
            checked = true
            local bg = ansi_bg_at_plain_byte(line, pos)
            if not bg or (expected_bg and bg ~= expected_bg) then
              table.insert(errors, description)
              return
            end
          end
        end
        break
      end
    end
    if not saw_line then
      table.insert(errors, "Expected mixed row for number text background check: " .. label)
    elseif not checked then
      table.insert(errors, "Expected number text for number background check: " .. label)
    end
  end
  local function require_number_pane_gap(label, side, description, also_label, forbidden_bg)
    if not ansi_lines then
      table.insert(errors, "ANSI capture missing; cannot verify number pane gap")
      return
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) and (not also_label or stripped:find(also_label, 1, true)) then
        local start_pos, end_pos = number_pane_bounds(stripped, side)
        if not start_pos or not end_pos then
          table.insert(errors, "Expected number pane bounds for: " .. label)
          return
        end
        local gap_pos = (side == "left") and end_pos or start_pos
        local gap_bg = ansi_bg_at_plain_byte(line, gap_pos)
        if (forbidden_bg and gap_bg == forbidden_bg) or (not forbidden_bg and gap_bg) then
          table.insert(errors, description)
        end
        return
      end
    end
    table.insert(errors, "Expected mixed row for number pane gap check: " .. label)
  end
  local function mixed_connector_core_bg(label)
    if not ansi_lines then
      return nil, "ANSI capture missing; cannot verify mixed connector core row", nil
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) then
        local core_start, core_end = connector_core_bounds(stripped)
        if not core_start or not core_end then
          return nil, "Expected ANSI separator data for mixed connector row: " .. label, nil
        end
        local core_pos = core_start + #"│" + math.floor((core_end - core_start - #"│") / 2)
        local center_bg = ansi_bg_at_plain_byte(line, core_pos)
        -- Solid means the WHOLE core interior carries one background; a
        -- partial route horizontal crossing the center cell is line-only.
        local uniform = true
        for pos = core_start + #"│", core_end - 1 do
          if ansi_bg_at_plain_byte(line, pos) ~= center_bg then
            uniform = false
            break
          end
        end
        return center_bg, nil, uniform
      end
    end
    return nil, "Expected mixed row for connector core check: " .. label, nil
  end
  local function require_non_solid_mixed_connector(label, overlap_label, overlap_base_label)
    local row_bg, row_err, row_uniform = mixed_connector_core_bg(label)
    local overlap_bg, overlap_err = nil, nil
    if ansi_lines then
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        if stripped:find(overlap_label, 1, true) then
          overlap_bg = ansi_bg_for_text(line, overlap_base_label or overlap_label)
          break
        end
      end
    end
    if row_err then
      table.insert(errors, row_err)
    elseif overlap_err then
      table.insert(errors, overlap_err)
    elseif overlap_bg and row_bg == overlap_bg and row_uniform then
      table.insert(errors, "Expected mixed transition row connector core to stay line-only, not solid background")
    end
  end

  if phase == "clamped-end" then
    if not find_plain_line(lines, { "Scroll mixed context 15" }) then
      table.insert(errors, "Expected mixed clamped-end capture to include final context")
    end
    return errors
  end

  if phase == "initial" then
    local wedge_glyphs = { "\226\151\162", "\226\151\165" } -- ◢, ◥
    if not find_plain_line(lines, { "Old scroll value A" }) then
      table.insert(errors, "Expected initial mixed scroll capture to include changed text")
    end
    local change_number_bg = first_number_pane_ascii_bg("Old scroll value A", "right")
      or first_number_pane_ascii_bg("Original scroll header", "left")
    require_number_pane_bg("Old scroll value A", "left", change_number_bg,
      "Expected initial changed left line number pane to stay solid change background")
    require_number_pane_bg("Old scroll value A", "right", change_number_bg,
      "Expected initial changed right line number pane to stay solid change background")
    require_number_pane_bg("Old scroll value B", "right", change_number_bg,
      "Expected second initial changed right line number pane to stay solid change background")
    local _, top_wedge_line, top_wedge = find_plain_line_all(lines,
      { "Scroll mixed context 04", "Modified scroll header" }, wedge_glyphs)
    if not top_wedge_line
        or top_wedge ~= "\226\151\162"
        or not glyph_docked_to_right_number(top_wedge_line, top_wedge) then
      table.insert(errors, "Expected initial mixed top wedge to stay on the real right envelope edge")
    end
    require_number_pane_bg("Scroll mixed context 04", "right", change_number_bg,
      "Expected initial mixed top transition right line number pane to keep change background after the wedge",
      "Modified scroll header")
    require_non_solid_mixed_connector("Scroll mixed context 04", "Original scroll header", "scroll header")
    require_no_core_route({ "Original scroll header", "Added mixed scroll 01" },
      "Expected initial mixed overlap row to remain a solid connector background row without route lines")
    -- The added block is absorbed into the merged change chunk: the right
    -- number pane carries the change band across the absorbed rows, and the
    -- overlap row's connector core is a solid change band (the change hunk
    -- shares this screen row with the right side).
    local add_number_bg = first_number_pane_digit_bg("Added mixed scroll 01", "right")
    require_number_pane_bg("Original scroll header", "left", change_number_bg,
      "Expected initial mixed overlap left line number pane to stay solid change background")
    require_number_text_bg("Original scroll header", "right", add_number_bg,
      "Expected initial mixed overlap right line number pane to share the absorbed band background")
    local _, lower_wedge_line, lower_wedge = find_plain_line_all(lines,
      { "Scroll mixed context 05", "Added mixed scroll 02" }, wedge_glyphs)
    if not lower_wedge_line
        or lower_wedge ~= "\226\151\165"
        or not glyph_docked_to_right_number(lower_wedge_line, lower_wedge) then
      table.insert(errors, "Expected initial mixed lower wedge to dock on the right number pane below the overlap row")
    end
    require_number_pane_bg("Scroll mixed context 05", "right", add_number_bg,
      "Expected initial mixed lower transition right line number pane to keep the add background after the wedge",
      "Added mixed scroll 02")
    require_non_solid_mixed_connector("Scroll mixed context 05", "Original scroll header", "scroll header")
    require_no_core_route({ "Scroll mixed context 06", "Added mixed scroll 03" },
      "Expected initial mixed continuation to avoid an orphan connector rail while overlap is visible")
    require_number_text_bg("Scroll mixed context 06", "right", add_number_bg,
      "Expected initial mixed continuation right line number text to keep the add background",
      "Added mixed scroll 03")
    require_number_pane_gap("Scroll mixed context 06", "right",
      "Expected initial mixed continuation to leave a clear spacer before the right line number",
      "Added mixed scroll 03", add_number_bg)
    return errors
  else
    if not find_plain_line(lines, { "Added mixed scroll", "Modified scroll header" }) then
      table.insert(errors, "Expected clipped mixed scroll capture to include the mixed envelope")
    end
  end

  local wedge_glyphs = { "\226\151\162", "\226\151\165" } -- ◢, ◥
  if phase == "origin-offscreen" then
    -- The band is an independent add chunk: adds hide their wedge once the
    -- origin scrolls offscreen, and no synthetic triangle appears at the
    -- viewport edge — scrolled-through rows show background continuity only.
    local _, _, glyph = find_plain_line_all(lines, { "Scroll mixed context 07", "Added mixed scroll 17" }, wedge_glyphs)
    if glyph then
      table.insert(errors, "Expected offscreen-origin add band to hide transition triangles at the viewport edge")
    end
    return errors
  end
  if phase == "right-j-scroll" and not find_plain_line(lines, { "Scroll mixed context 01" }) then
    table.insert(errors, "Right-pane mixed scroll should leave left pane stationary at the top context")
  end
  if phase == "right-diverged" or phase == "right-j-scroll" then
    local change_number_bg = first_number_pane_ascii_bg("Old scroll value A", "left")
      or first_number_pane_ascii_bg("Original scroll header", "left")
    require_number_text_bg("Old scroll value A", "left", change_number_bg,
      "Expected scrolled changed left line number text to keep change background")
    require_number_pane_gap("Old scroll value A", "left",
      "Expected scrolled changed left line number pane to leave a clear spacer by the route",
      nil, change_number_bg)
    require_number_text_bg("Old scroll value B", "left", change_number_bg,
      "Expected second scrolled changed left line number text to keep change background")
    require_number_pane_gap("Old scroll value B", "left",
      "Expected second scrolled changed left line number pane to leave a clear spacer by the route",
      nil, change_number_bg)
    -- Wedges paint the transitions at the projected overlap's edges: the
    -- top wedge sits on the row above the overlap row.
    local _, _, top_wedge = find_plain_line_all(lines, { "Scroll mixed context 04", "Added mixed scroll" }, wedge_glyphs)
    if top_wedge ~= "\226\151\162" then
      table.insert(errors, "Expected right-diverged mixed top wedge to dock on the overlap's upper edge row")
    end
    -- The added block is absorbed into the merged change chunk: its right
    -- number pane shares the band background across the absorbed rows.
    local add_number_bg = first_number_pane_digit_bg("Added mixed scroll", "right")
    require_number_text_bg("Scroll mixed context 04", "right", add_number_bg,
      "Expected right-diverged mixed top transition right line number text to keep the band background",
      "Added mixed scroll")
    require_non_solid_mixed_connector("Scroll mixed context 04", "Original scroll header", "scroll header")
    if not find_plain_line(lines, { "Original scroll header", "Added mixed scroll" }) then
      table.insert(errors, "Expected right-diverged mixed overlap row to keep the added block alongside the header")
    end
    require_number_text_bg("Original scroll header", "right", add_number_bg,
      "Expected right-diverged mixed overlap right line number pane to share the absorbed band background")
    local _, _, lower_wedge = find_plain_line_all(lines, { "Scroll mixed context 05", "Added mixed scroll" }, wedge_glyphs)
    if lower_wedge ~= "\226\151\165" then
      table.insert(errors, "Expected right-diverged mixed lower wedge to stay adjacent to the projected overlap row")
    end
    require_number_pane_bg("Scroll mixed context 05", "right", add_number_bg,
      "Expected right-diverged mixed lower transition right line number pane to keep the add background after the wedge",
      "Added mixed scroll")
    if not contains_any_glyph(lines, { "Deleted mixed scroll line" }, { "\226\151\164" }) then
      table.insert(errors, "Expected scrolled mixed deletion target to keep its visible triangle")
    end
    require_non_solid_mixed_connector("Scroll mixed context 05", "Original scroll header", "scroll header")
  end
  if phase == "right-overlap-clipped" then
    local _, stripped = find_plain_line(lines, { "Old scroll value B" })
    if not stripped or not (stripped:find("│   │", 1, true) or stripped:find("│    │", 1, true)) then
      table.insert(errors,
        "Expected clipped mixed change/delete routes to remain separated instead of stacking adjacent pipes")
    end
  end
  if phase == "right-overlap-middle" then
    require_no_core_route({ "Original scroll header", "Added mixed scroll 10" },
      "Expected mid-overlap mixed row to remain solid/clear without an orphan connector rail")
    require_no_core_route({ "Scroll mixed context 05", "Added mixed scroll 11" },
      "Expected mid-overlap lower transition to terminate at the wedge without an orphan connector rail below it")
    require_no_core_route({ "Scroll mixed context 06", "Added mixed scroll 12" },
      "Expected mid-overlap continuation to stay clear after the lower transition wedge")
  end
  if phase == "right-overlap-exit" then
    local _, _, top_glyph = find_plain_line_all(lines, { "Scroll mixed context 02", "New scroll value B" }, wedge_glyphs)
    if top_glyph ~= "\226\151\162" then
      table.insert(errors, "Expected first non-overlapping mixed change route to stay on the shared boundary row")
    end
    if not contains_any_glyph(lines, { "Old scroll value A" }, { "\226\151\164" }) then
      table.insert(errors, "Expected first non-overlapping mixed change route to keep the lower left transition triangle without a vertical step")
    end
  end
  if phase == "right-tail-approach" or phase == "right-tail-aligned" then
    local _, upper = find_plain_line(lines, { "Old scroll value A" })
    if not upper or not upper:find("\226\151\164", 1, true) or #plain_bar_positions(upper) <= 4 then
      table.insert(errors,
        "Expected deep mixed scroll to keep the upper visible change triangle while avoiding add/delete rails")
    end
    local _, lower = find_plain_line(lines, { "Scroll mixed context 04" })
    if not lower or #plain_bar_positions(lower) <= 4 then
      table.insert(errors,
        "Expected deep mixed scroll to connect the lower change transition from the top of its visible triangle")
    end
  end

  local _, stripped, glyph = find_plain_line(lines, { "Modified scroll header", "Added mixed scroll" }, wedge_glyphs)
  if not glyph then
    table.insert(errors, "Expected scroll mixed viewport to show a real mixed wedge near the connection row")
  elseif not glyph_docked_to_right_number(stripped, glyph) then
    table.insert(errors, "Expected scroll mixed wedge to dock directly against the right line number")
  end

  return errors
end

local function utf8_chars(s)
  local chars = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
  end
  return chars
end

local function connector_core_segment(stripped)
  local separators = {}
  local from = 1
  while true do
    local pos = stripped:find("│", from, true)
    if not pos then
      break
    end
    separators[#separators + 1] = pos
    from = pos + #"│"
  end

  local has_overview_panes = (separators[1] or 999) <= 3
  local core_left_sep = has_overview_panes and separators[3] or separators[2]
  local core_right_sep = has_overview_panes and separators[#separators - 2] or separators[#separators - 1]
  if not core_left_sep or not core_right_sep then
    return nil
  end
  return stripped:sub(core_left_sep + #"│", core_right_sep - 1)
end

local function dense_number_pane_bounds(stripped, side)
  local separators = {}
  local from = 1
  while true do
    local pos = stripped:find("│", from, true)
    if not pos then
      break
    end
    separators[#separators + 1] = pos
    from = pos + #"│"
  end
  if side == "left" then
    local has_overview_panes = (separators[1] or 999) <= 3
    if has_overview_panes then
      return separators[2] + #"│", separators[3] - 1
    end
    if #separators < 2 then
      return nil, nil
    end
    return separators[1] + #"│", separators[2] - 1
  end
  local has_overview_panes = (separators[1] or 999) <= 3
  if has_overview_panes then
    return separators[#separators - 2] + #"│", separators[#separators - 1] - 1
  end
  if #separators < 4 then
    return nil, nil
  end
  return separators[#separators - 1] + #"│", separators[#separators] - 1
end

local function first_digit_pos_in_bounds(stripped, start_pos, end_pos, number_text)
  if not start_pos or not end_pos then
    return nil
  end
  local found = stripped:find(number_text, start_pos, true)
  if found and found <= end_pos then
    return found
  end
  return nil
end

local function verify_dense_mixed(lines, ansi_lines, phase)
  local errors = {}
  local saw_dense_row = false
  local saw_core_width = false

  local function require_no_left_number_underline(label, message)
    if not ansi_lines then
      return
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) then
        local start_pos, end_pos = dense_number_pane_bounds(stripped, "left")
        for pos = start_pos or 1, end_pos or 0 do
          if ansi_underline_at_plain_byte(line, pos) then
            table.insert(errors, message)
            return
          end
        end
        return
      end
    end
  end

  local function require_no_underlined_core_pipes(label, message)
    if not ansi_lines then
      return
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) then
        local separators = {}
        local from = 1
        while true do
          local pos = stripped:find("│", from, true)
          if not pos then
            break
          end
          separators[#separators + 1] = pos
          from = pos + #"│"
        end
        local core_start = separators[2]
        local core_end = separators[#separators - 1]
        if core_start and core_end then
          for _, pos in ipairs(separators) do
            if pos > core_start and pos < core_end and ansi_underline_at_plain_byte(line, pos) then
              table.insert(errors, message)
              return
            end
          end
        end
        return
      end
    end
  end

  local minimum_width = 3
  -- Scroll-pressure sizing widens the core up front so routes never hide
  -- before genuine eight-rail saturation: at most minimum (3) plus two
  -- columns per rail at the eight-rail cap. The dense fixture sizes to 17.
  local maximum_width = 19
  for _, line in ipairs(lines) do
    local stripped = strip_ansi(line)
    if stripped:find("Dense ", 1, true) or stripped:find("Added dense", 1, true) then
      saw_dense_row = true
      local core = connector_core_segment(stripped)
      if core then
        local chars = utf8_chars(core)
        saw_core_width = true
        if #chars < minimum_width then
          table.insert(errors, string.format(
            "Expected dense mixed connector core width at least %d, found %d",
            minimum_width,
            #chars
          ))
          break
        end
        if #chars > maximum_width then
          table.insert(errors, string.format(
            "Expected dense mixed connector core width no more than %d, found %d",
            maximum_width,
            #chars
          ))
          break
        end
      end
    end
  end

  if not saw_dense_row then
    table.insert(errors, "Expected dense mixed capture to include dense fixture rows")
  elseif not saw_core_width then
    table.insert(errors, "Expected dense mixed capture to expose connector core separators")
  end

  if phase == nil then
    if not find_plain_line(lines, { "New dense value A" }) then
      table.insert(errors, "Expected dense mixed initial capture to include top changed content")
    end
    if not find_plain_line(lines, { "Deleted dense top" }) then
      table.insert(errors, "Expected dense mixed initial capture to include top deleted content")
    end
    if ansi_lines then
      local add_bg
      local wrongly_colored = {}
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        local start_pos, end_pos = dense_number_pane_bounds(stripped, "right")
        if stripped:find("Added dense A 01", 1, true) then
          local pos = first_digit_pos_in_bounds(stripped, start_pos, end_pos, "8")
          add_bg = pos and ansi_bg_at_plain_byte(line, pos) or add_bg
        end
        for _, item in ipairs({
          { label = "Dense context 03", number = "6" },
          { label = "Dense add origin A", number = "7" },
          { label = "Dense context 04", number = "24" },
          { label = "Dense add origin B", number = "25" },
        }) do
          if stripped:find(item.label, 1, true) then
            local pos = first_digit_pos_in_bounds(stripped, start_pos, end_pos, item.number)
            local bg = pos and ansi_bg_at_plain_byte(line, pos) or nil
            wrongly_colored[item.label] = bg
          end
        end
      end
      if add_bg then
        for label, bg in pairs(wrongly_colored) do
          if bg == add_bg then
            table.insert(errors, "Expected dense right number pane row to avoid shifted add background: " .. label)
          end
        end
      end
    end
    return errors
  end

  if phase == "four-lane-conflict" then
    if ansi_lines then
      for _, line in ipairs(ansi_lines) do
        local stripped = strip_ansi(line)
        if stripped:find("Dense context 02", 1, true) then
          local start_pos, end_pos = dense_number_pane_bounds(stripped, "left")
          for pos = start_pos or 1, end_pos or 0 do
            if ansi_underline_at_plain_byte(line, pos) then
              table.insert(errors,
                "Expected clipped dense change underline to start in connector core, not left number pane")
              break
            end
          end
          break
        end
      end
    end
  end

  local function require_delete_triangle_gap(label, message)
    local _, stripped = find_plain_line(lines, { label })
    if not stripped or stripped:find("◤│ │", 1, true) or stripped:find("\226\151\164│ │", 1, true) then
      table.insert(errors, message)
    end
  end
  local function require_change_endpoint_gap(label, message)
    local _, stripped = find_plain_line(lines, { label })
    if not stripped or stripped:find("◤│ │", 1, true) or stripped:find("\226\151\164│ │", 1, true) then
      table.insert(errors, message)
    end
  end

  if phase == "initial-tall" then
    require_delete_triangle_gap("Deleted dense lower 02",
      "Expected initial dense lower deletion triangle to leave a spacer before neighboring routes")
    require_no_underlined_core_pipes("Deleted dense lower 02",
      "Expected initial dense lower deletion underline to avoid connector pipes")
    require_no_underlined_core_pipes("Dense add origin B",
      "Expected initial dense add-origin underline to split around connector pipes")
  elseif phase == "top-route-separation-tall" then
    require_change_endpoint_gap("Old dense value A",
      "Expected top dense change endpoint to leave a spacer before the delete route")
    require_delete_triangle_gap("Deleted dense top 01",
      "Expected top dense deletion triangle to leave a spacer before neighboring routes")
    require_no_left_number_underline("Dense context 02",
      "Expected top dense shifted change underline to stay out of the left number pane")
    require_no_underlined_core_pipes("Dense add origin B",
      "Expected dense add-origin underline to split around connector pipes")
    require_no_underlined_core_pipes("Deleted dense lower 01",
      "Expected dense lower deletion underline to avoid connector pipes")
    require_no_underlined_core_pipes("Deleted dense lower 02",
      "Expected dense lower deletion tail underline to avoid connector pipes")
  elseif phase == "lower-route-separation-tall" then
    require_change_endpoint_gap("Dense lower old header",
      "Expected lower dense change endpoint to leave a spacer before the delete route")
    require_delete_triangle_gap("Deleted dense lower 01",
      "Expected lower dense deletion triangle to leave a spacer before neighboring routes")
    require_no_left_number_underline("Dense context 05",
      "Expected lower dense shifted change underline to stay out of the left number pane")
    require_no_underlined_core_pipes("Dense add origin B",
      "Expected lower dense add-origin underline to split around connector pipes")
    require_no_underlined_core_pipes("Deleted dense top 01",
      "Expected dense top deletion underline to avoid connector pipes")
  elseif phase == "lower-route-entering-tall" then
    require_change_endpoint_gap("Dense lower old header",
      "Expected entering lower dense change endpoint to leave a spacer before the delete route")
    require_delete_triangle_gap("Deleted dense lower 01",
      "Expected entering lower dense deletion triangle to leave a spacer before neighboring routes")
    require_no_left_number_underline("Dense context 05",
      "Expected entering lower dense shifted change underline to stay out of the left number pane")
    require_no_underlined_core_pipes("Dense add origin B",
      "Expected entering lower dense add-origin underline to split around connector pipes")
    require_no_underlined_core_pipes("Deleted dense top 01",
      "Expected entering dense top deletion underline to avoid connector pipes")
  elseif phase == "lower-four-lane-tall" then
    require_no_underlined_core_pipes("Dense add origin A",
      "Expected deep lower dense add-origin underline to split around connector pipes")
    require_no_underlined_core_pipes("Dense add origin B",
      "Expected deep lower dense second add-origin underline to split around connector pipes")
    require_no_underlined_core_pipes("Deleted dense top 01",
      "Expected deep dense top deletion underline to avoid connector pipes")
  end

  return errors
end

local function verify_scroll_changes(lines, ansi_lines, phase)
  local errors = {}
  local require_plain_fragment, _, require_pattern_fragment = plain_fragment_requirements(errors, lines)
  local function require_solid_change_connector(label)
    if not ansi_lines then
      table.insert(errors, "ANSI capture missing; cannot verify solid change connector row")
      return
    end
    for _, line in ipairs(ansi_lines) do
      local stripped = strip_ansi(line)
      if stripped:find(label, 1, true) then
        local text_bg = ansi_bg_for_text(line, "routed change")
        local sep2 = nth_plain_pos(stripped, "│", 2)
        local sep3 = nth_plain_pos(stripped, "│", 3)
        if not text_bg or not sep2 or not sep3 then
          table.insert(errors, "Expected ANSI data for solid change connector row: " .. label)
          return
        end
        local core_pos = sep2 + #"│" + math.floor((sep3 - sep2 - #"│") / 2)
        local core_bg = ansi_bg_at_plain_byte(line, core_pos)
        if core_bg ~= text_bg then
          table.insert(errors, "Expected overlapping changed row connector core to use solid change background")
        end
        return
      end
    end
    table.insert(errors, "Expected changed row for solid connector check: " .. label)
  end

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
    require_solid_change_connector("Old routed change A")
    return errors
  end

  local change_glyphs = { "\226\151\164", "\226\151\165", "\226\151\162" } -- ◤, ◥, ◢
  local function has_internal_connector_pipe(stripped)
    return connector_core_pipe_count(stripped) > 0
  end
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
  if phase == "right-diverged" then
    require_pattern_fragment("│  3 │%s+│◢7",
      "Expected right-diverged change route to dock the upper transition on the right number pane")
    local _, rail_line = find_plain_line(lines, { "Scroll change context 04", "│  4 │" })
    if not rail_line or not has_internal_connector_pipe(rail_line) then
      table.insert(errors, "Expected right-diverged change route to draw a connector rail between shifted regions")
    end
    require_plain_fragment("│  5◤│",
      "Expected right-diverged change route to dock the lower transition on the left number pane")
  elseif phase == "left-diverged" then
    require_plain_fragment("│  7◣│",
      "Expected left-diverged change route to dock the upper transition on the left number pane")
    local _, rail_line = find_plain_line(lines, { "Scroll change context 05", "│  8 │" })
    if not rail_line or not has_internal_connector_pipe(rail_line) then
      table.insert(errors, "Expected left-diverged change route to draw a connector rail between shifted regions")
    end
    require_pattern_fragment("│  9 │%s+│◥5",
      "Expected left-diverged change route to dock the lower transition on the right number pane")
  elseif phase == "both-diverged" then
    require_pattern_fragment("│  4 │%s+│◢6",
      "Expected both-diverged change route to dock the upper right transition beside the overlap")
    require_pattern_fragment("│  5 │%s+│ 7",
      "Expected both-diverged change overlap row to remain solid without route lines")
    require_solid_change_connector("Old routed change A")
    require_pattern_fragment("│  6◤│%s+│ 8",
      "Expected both-diverged change route to dock the lower left transition beside the overlap")
    require_pattern_fragment("│  7 │%s+│ 9",
      "Expected both-diverged change continuation to stay clear after the lower wedge row")
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
elseif scroll_base == "scroll-dense-mixed" then
  errors = verify_dense_mixed(lines, ansi_lines, scroll_phase)
elseif scroll_base == "scroll-changes" then
  errors = verify_scroll_changes(lines, ansi_lines, scroll_phase)
elseif scroll_base == "git" then
  errors = verify_git(lines, ansi_lines, scroll_phase)
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
elseif test_name == "dense-mixed" then
  errors = verify_dense_mixed(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "New dense value A", "Deleted dense top 01", "Added dense A 01" })) do
    table.insert(errors, err)
  end
elseif test_name == "theme-default" then
  errors = verify_theme_default(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "Old value A", "Delete this line", "Added line 1" })) do
    table.insert(errors, err)
  end
elseif test_name == "comprehensive" then
  errors = verify_comprehensive(lines, ansi_lines)
  for _, err in ipairs(verify_ansi_backgrounds(ansi_lines, { "\"time\"", "This section will", "Added performance" })) do
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
