local text = require("diffbandit.util.text")
local hex = require("diffbandit.util.hex")
local config_mod = require("diffbandit.config")

local M = {}

function M.detect_filetype(path)
  if not path or path == "" then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

-- `format` ({ eol, line_ending }, see util/text) says how the lines are
-- stored; `text` is then the exact stored bytes.
function M.from_lines(lines, path, label, metadata, format)
  format = format or {}
  local source = {
    path = path,
    label = label or path,
    lines = lines or {},
    text = text.encode(lines or {}, format),
    eol = format.eol ~= false,
    line_ending = format.line_ending,
    bom = format.bom == true,
    filetype = M.detect_filetype(path),
  }
  for key, value in pairs(metadata or {}) do
    source[key] = value
  end
  return source
end

function M.from_text(value, path, label, metadata)
  local lines, format = text.decode(value or "")
  local source = M.from_lines(lines, path, label, metadata, format)
  source.text = value or ""
  return source
end

local function read_file_raw(path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(path)
  if not stat then
    return nil, string.format("Unable to read file: %s", path)
  end
  local fd, open_err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, tostring(open_err or ("Unable to open file: " .. path))
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if data == nil then
    return nil, tostring(read_err or ("Unable to read file: " .. path))
  end
  return data, nil
end

local function from_hex_file(path, label, text, config)
  local dump = hex.dump(text or "", config_mod.section(config, "ui", "hex"))
  return {
    path = path,
    label = label or path,
    lines = dump.lines,
    text = dump.text,
    filetype = "diffbandit-hex",
    display_numbers = dump.display_numbers,
    display_number_width = dump.display_number_width,
    binary_hex = true,
    hex_total_bytes = dump.total_bytes,
    hex_visible_bytes = dump.visible_bytes,
    hex_truncated = dump.truncated,
  }
end

function M.from_file(path, label, config)
  local raw, raw_err = read_file_raw(path)
  if not raw then
    return nil, raw_err
  end
  local hex_config = config_mod.section(config, "ui", "hex")
  if hex.is_binary(raw) then
    if hex_config.enabled ~= false then
      return from_hex_file(path, label, raw, config)
    end
    return {
      path = path,
      label = label or path,
      lines = { "[DiffBandit: binary file hidden]" },
      text = "[DiffBandit: binary file hidden]\n",
      filetype = nil,
      binary_hidden = true,
    }
  end

  return M.from_text(raw, path, label), nil
end

function M.from_buffer(bufnr, label)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  local source = M.from_lines(lines, path ~= "" and path or nil,
    label or path or string.format("buffer:%d", bufnr), nil, text.buffer_format(bufnr, lines))
  source.filetype = filetype ~= "" and filetype or M.detect_filetype(path)
  return source
end

return M
