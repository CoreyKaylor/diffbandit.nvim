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

local function verify_extreme_additions(lines)
  local errors = {}

  -- UTF-8 byte sequences for special characters
  local triangle = "\226\151\165"  -- ◥
  local vertical_bar = "\226\148\130"  -- │
  local underline = "\226\150\129"  -- ▁

  -- Count triangles (should have at least 6 for the extreme test)
  local triangle_count = 0
  for _, line in ipairs(lines) do
    if line:find(triangle, 1, true) then
      triangle_count = triangle_count + 1
    end
  end
  if triangle_count < 6 then
    table.insert(errors, string.format("Expected at least 6 triangles, found %d", triangle_count))
  end

  -- Count vertical bars (should have many rows with bars)
  local bar_row_count = 0
  for _, line in ipairs(lines) do
    if line:find(vertical_bar, 1, true) then
      bar_row_count = bar_row_count + 1
    end
  end
  if bar_row_count < 10 then
    table.insert(errors, string.format("Expected at least 10 rows with vertical bars, found %d", bar_row_count))
  end

  -- Check that left line numbers 1-12 appear
  -- Pattern matches: whitespace + number + (whitespace, digit, or underline)
  local underline_byte = "\226\150\129"  -- ▁
  for i = 1, 12 do
    local found = false
    local num_str = tostring(i)
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      -- Match pattern: whitespace before number, then number, then whitespace/digit/underline
      local pattern = "%s" .. num_str .. "[%s%d]"
      local pattern_underline = "%s" .. num_str .. underline_byte
      if stripped:match(pattern) or stripped:match(pattern_underline) or stripped:match("^%s*" .. num_str .. "%s") then
        found = true
        break
      end
    end
    if not found then
      table.insert(errors, "Left line number " .. i .. " not found")
    end
  end

  -- Verify underlines exist (on origin rows)
  local underline_count = 0
  for _, line in ipairs(lines) do
    if line:find(underline, 1, true) then
      underline_count = underline_count + 1
    end
  end
  if underline_count < 3 then
    table.insert(errors, string.format("Expected at least 3 rows with underlines, found %d", underline_count))
  end

  return errors
end

local function verify_pure_additions(lines)
  local errors = {}

  local triangle = "\226\151\165"  -- ◥
  local vertical_bar = "\226\148\130"  -- │
  local underline = "\226\150\129"  -- ▁

  -- Count triangles (should have at least 3 for pure additions)
  local triangle_count = 0
  for _, line in ipairs(lines) do
    if line:find(triangle, 1, true) then
      triangle_count = triangle_count + 1
    end
  end
  if triangle_count < 3 then
    table.insert(errors, string.format("Expected at least 3 triangles, found %d", triangle_count))
  end

  -- Check left line numbers 1-6 (left file has 6 lines)
  local underline_byte = "\226\150\129"  -- ▁
  for i = 1, 6 do
    local found = false
    local num_str = tostring(i)
    for _, line in ipairs(lines) do
      local stripped = strip_ansi(line)
      local pattern = "%s" .. num_str .. "[%s%d]"
      local pattern_underline = "%s" .. num_str .. underline_byte
      if stripped:match(pattern) or stripped:match(pattern_underline) or stripped:match("^%s*" .. num_str .. "%s") then
        found = true
        break
      end
    end
    if not found then
      table.insert(errors, "Left line number " .. i .. " not found")
    end
  end

  return errors
end

-- Main
local capture_file = arg[1]
local test_name = arg[2] or "extreme"

if not capture_file then
  io.stderr:write("Usage: lua verify.lua <capture_file> [test_name]\n")
  io.stderr:write("  test_name: 'extreme' or 'pure' (default: extreme)\n")
  os.exit(1)
end

local lines = read_capture(capture_file)

if #lines == 0 then
  io.stderr:write("ERROR: Capture file is empty\n")
  os.exit(1)
end

local errors
if test_name == "pure" then
  errors = verify_pure_additions(lines)
else
  errors = verify_extreme_additions(lines)
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
