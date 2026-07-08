local text = require("diffbandit.util.text")
local hex = require("diffbandit.util.hex")
local diff_mod = require("diffbandit.diff")
local config_mod = require("diffbandit.config")

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

  local lines, text, err = diff_mod.read_file(path)
  if not lines then
    return nil, err
  end

  return {
    path = path,
    label = label or path,
    lines = lines,
    text = text,
    filetype = M.detect_filetype(path),
  }
end

function M.from_buffer(bufnr, label)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local value = text.to_text(lines)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  return {
    path = path ~= "" and path or nil,
    label = label or path or string.format("buffer:%d", bufnr),
    lines = lines,
    text = value,
    filetype = filetype ~= "" and filetype or M.detect_filetype(path),
  }
end

return M
