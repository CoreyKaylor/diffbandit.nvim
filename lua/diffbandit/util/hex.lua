local M = {}

local function byte_at(text, index)
  return string.byte(text, index, index)
end

local function printable(byte)
  if byte and byte >= 32 and byte <= 126 then
    return string.char(byte)
  end
  return "."
end

local function is_control_byte(byte)
  return byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 12 and byte ~= 13
end

function M.is_binary(text)
  if not text or text == "" then
    return false
  end
  if text:find("%z") then
    return true
  end

  local limit = math.min(#text, 8192)
  local control = 0
  for i = 1, limit do
    local byte = byte_at(text, i)
    if byte and is_control_byte(byte) then
      control = control + 1
    end
  end
  return limit > 0 and (control / limit) > 0.30
end

local function offset_width(total_bytes)
  local highest = math.max(0, total_bytes - 1)
  local width = #string.format("%X", highest)
  return math.max(8, width)
end

function M.dump(text, opts)
  opts = opts or {}
  text = text or ""
  local bytes_per_row = tonumber(opts.bytes_per_row) or 16
  if bytes_per_row < 1 then
    bytes_per_row = 16
  end

  local max_bytes = tonumber(opts.max_bytes)
  local total = #text
  local visible = total
  local truncated = false
  if max_bytes and max_bytes > 0 and total > max_bytes then
    visible = max_bytes
    truncated = true
  end

  local lines = {}
  local display_numbers = {}
  local width = offset_width(total)
  local row = 1
  local offset = 0

  while offset < visible do
    local hex_parts = {}
    local ascii_parts = {}
    local row_len = math.min(bytes_per_row, visible - offset)
    for i = 1, bytes_per_row do
      if i <= row_len then
        local byte = byte_at(text, offset + i) or 0
        hex_parts[#hex_parts + 1] = string.format("%02X", byte)
        ascii_parts[#ascii_parts + 1] = printable(byte)
      else
        hex_parts[#hex_parts + 1] = "  "
        ascii_parts[#ascii_parts + 1] = " "
      end
    end

    local left = table.concat(hex_parts, " ")
    if opts.show_ascii == false then
      lines[row] = left
    else
      lines[row] = left .. "  |" .. table.concat(ascii_parts, "") .. "|"
    end
    if opts.show_offsets ~= false then
      display_numbers[row] = string.format("%0" .. tostring(width) .. "X", offset)
    end

    row = row + 1
    offset = offset + bytes_per_row
  end

  if total == 0 then
    lines[1] = ""
    if opts.show_offsets ~= false then
      display_numbers[1] = string.rep(" ", width)
    end
  end

  if truncated then
    lines[#lines + 1] = string.format(
      "[DiffBandit: hex view truncated at %d of %d bytes]",
      visible,
      total
    )
    if opts.show_offsets ~= false then
      display_numbers[#display_numbers + 1] = string.rep(" ", width)
    end
  end

  local result = {
    lines = lines,
    text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or "",
    total_bytes = total,
    visible_bytes = visible,
    truncated = truncated,
  }
  if opts.show_offsets ~= false then
    result.display_numbers = display_numbers
    result.display_number_width = width
  end
  return result
end

return M
