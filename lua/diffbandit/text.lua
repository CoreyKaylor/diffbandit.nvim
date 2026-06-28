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
