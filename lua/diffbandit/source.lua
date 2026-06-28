local text = require("diffbandit.text")

local M = {}

function M.detect_filetype(path)
  if not path or path == "" then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

function M.from_lines(lines, path, label, metadata)
  local source = {
    path = path,
    label = label or path,
    lines = lines or {},
    text = text.to_text(lines or {}),
    filetype = M.detect_filetype(path),
  }
  for key, value in pairs(metadata or {}) do
    source[key] = value
  end
  return source
end

function M.from_text(value, path, label, metadata)
  return M.from_lines(text.split_lines(value or ""), path, label, metadata)
end

return M
