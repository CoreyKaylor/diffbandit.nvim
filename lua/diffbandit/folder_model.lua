local text = require("diffbandit.text")

local M = {}

function M.parse_md5sum_z(output)
  local digests = {}
  local start = 1
  while start <= #(output or "") do
    local stop = output:find("\0", start, true)
    if not stop then
      break
    end
    local record = output:sub(start, stop - 1)
    local digest, path = record:match("^([%da-fA-F]+)%s+(.+)$")
    if digest and path then
      digests[path] = digest
    end
    start = stop + 1
  end
  return digests
end

function M.parse_digest_lines(output)
  local digests = {}
  for _, line in ipairs(text.split_lines(output)) do
    local digest, path = line:match("^([%da-fA-F]+)%s+(.+)$")
    if digest and path then
      path = path:gsub("^%*", "")
      digests[path] = digest
    end
  end
  return digests
end

function M.parse_line_order(output, paths)
  local digests = {}
  local lines = text.split_lines(output)
  for index, path in ipairs(paths or {}) do
    if lines[index] and lines[index] ~= "" then
      digests[path] = vim.trim(lines[index])
    end
  end
  return digests
end

function M.is_difference_status(status)
  return status == "different"
    or status == "type_mismatch"
    or status == "left_only"
    or status == "right_only"
    or status == "error"
end

return M
