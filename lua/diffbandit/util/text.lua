local M = {}

function M.to_text(lines)
  if not lines or #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.split_lines(value)
  if not value or value == "" then
    return {}
  end
  local lines = vim.split(value, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

-- Text as it is stored (a file, a blob) versus the lines DiffBandit diffs and
-- shows: decode() splits raw text into lines plus the format needed to write
-- them back byte for byte, and encode() is its inverse.
--
-- format = { eol = <last line ends in a newline>, line_ending = "lf" | "crlf"
-- | "mixed" | nil (no line was terminated), bom = <starts with a UTF-8 byte
-- order mark> }. Like Vim ('bomb'), the BOM is kept out of the lines. CRs
-- are stripped only when every terminated line ends in CRLF -- Vim's own
-- rule for 'fileformat' dos -- so decoded lines match what a loaded buffer
-- of the same file holds; a file that mixes endings keeps its CRs in the
-- lines, as Vim shows them (^M).

local BOM = "\239\187\191"

local function default_format()
  return { eol = true, line_ending = nil, bom = false }
end

function M.decode(value)
  if not value or value == "" then
    return {}, default_format()
  end
  local bom = value:sub(1, 3) == BOM
  if bom then
    value = value:sub(4)
    if value == "" then
      return {}, { eol = true, line_ending = nil, bom = true }
    end
  end
  local lines = vim.split(value, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then
    table.remove(lines, #lines)
  end
  local terminated = eol and #lines or #lines - 1
  local crlf = 0
  for index = 1, terminated do
    if lines[index]:sub(-1) == "\r" then
      crlf = crlf + 1
    end
  end
  local line_ending
  if terminated == 0 then
    line_ending = nil
  elseif crlf == terminated then
    line_ending = "crlf"
    for index = 1, terminated do
      lines[index] = lines[index]:sub(1, -2)
    end
  elseif crlf == 0 then
    line_ending = "lf"
  else
    line_ending = "mixed"
  end
  return lines, { eol = eol, line_ending = line_ending, bom = bom }
end

function M.encode(lines, format)
  format = format or {}
  local prefix = format.bom and BOM or ""
  if not lines or #lines == 0 then
    return prefix
  end
  local sep = format.line_ending == "crlf" and "\r\n" or "\n"
  local value = prefix .. table.concat(lines, sep)
  if format.eol ~= false then
    value = value .. sep
  end
  return value
end

-- The format a buffer writes with ('endofline', 'fileformat', 'bomb'). A unix
-- buffer whose lines still carry CRs came from a file with mixed endings.
function M.buffer_format(bufnr, lines)
  local get = function(name)
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { buf = bufnr })
    if not ok then
      return nil
    end
    return value
  end
  local line_ending = "lf"
  if get("fileformat") == "dos" then
    line_ending = "crlf"
  elseif lines then
    for _, line in ipairs(lines) do
      if line:sub(-1) == "\r" then
        line_ending = "mixed"
        break
      end
    end
  end
  return { eol = get("endofline") ~= false, line_ending = line_ending, bom = get("bomb") == true }
end

-- Whether a 1-based hunk range { start, count } runs to the end of a side
-- with `total` lines (an empty range sits in the gap after line `start`).
function M.reaches_end(start, count, total)
  if count > 0 then
    return start + count - 1 >= total
  end
  return start >= total
end

function M.copy_range(lines, start, count)
  local result = {}
  if not lines or count <= 0 then
    return result
  end
  for index = start, start + count - 1 do
    result[#result + 1] = lines[index] or ""
  end
  return result
end

function M.replace_range(lines, start, count, replacement)
  local result = {}
  local insert_at = count == 0 and (start + 1) or start
  if insert_at < 1 then
    insert_at = 1
  end

  for index = 1, insert_at - 1 do
    result[#result + 1] = lines[index]
  end
  for _, line in ipairs(replacement or {}) do
    result[#result + 1] = line
  end
  local resume_at = count == 0 and insert_at or (start + count)
  if resume_at < 1 then
    resume_at = 1
  end
  for index = resume_at, #(lines or {}) do
    result[#result + 1] = lines[index]
  end
  return result
end

return M
