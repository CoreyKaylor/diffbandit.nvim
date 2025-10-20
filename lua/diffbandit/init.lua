local state = require("diffbandit.state")
local diff_mod = require("diffbandit.diff")
local Session = require("diffbandit.session")
local highlights = require("diffbandit.highlights")

local M = {}

local highlights_ready = false

local function ensure_highlights()
  if not highlights_ready then
    highlights.apply()
    highlights_ready = true
  end
end

function M.setup(opts)
  local config = state.set_config(opts)
  ensure_highlights()
  return config
end

local function detect_filetype(path)
  if not path or path == "" then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

local function make_source_from_file(path, label)
  local lines, text, err = diff_mod.read_file(path)
  if not lines then
    return nil, err
  end

  return {
    path = path,
    label = label or path,
    lines = lines,
    text = text,
    filetype = detect_filetype(path),
  }
end

local function make_source_from_buffer(bufnr, label)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n") .. "\n"
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  return {
    path = path ~= "" and path or nil,
    label = label or path or string.format("buffer:%d", bufnr),
    lines = lines,
    text = text,
    filetype = filetype ~= "" and filetype or detect_filetype(path),
  }
end

local function start_session(left_source, right_source)
  ensure_highlights()
  local config = state.get_config()
  local session, err = Session.start({ left = left_source, right = right_source }, config)
  if not session then
    return nil, err
  end
  state.register(session)
  return session
end

function M.files(left_path, right_path, opts)
  opts = opts or {}
  local left_source, left_err = make_source_from_file(left_path, opts.left_label)
  if not left_source then
    return nil, left_err
  end

  local right_source, right_err = make_source_from_file(right_path, opts.right_label)
  if not right_source then
    return nil, right_err
  end

  return start_session(left_source, right_source)
end

function M.buffers(bufnr_a, bufnr_b, opts)
  opts = opts or {}
  local left_source = make_source_from_buffer(bufnr_a, opts.left_label)
  local right_source = make_source_from_buffer(bufnr_b, opts.right_label)
  return start_session(left_source, right_source)
end

return M
