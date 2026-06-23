local state = require("diffbandit.state")
local diff_mod = require("diffbandit.diff")
local Session = require("diffbandit.session")
local highlights = require("diffbandit.highlights")
local git_mod = require("diffbandit.git")

local M = {}

local highlights_ready = false
local theme_augroup = nil

local function configure_theme_refresh(config)
  if theme_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, theme_augroup)
    theme_augroup = nil
  end

  local theme = (((config or {}).ui or {}).theme or {})
  if theme.auto_refresh == false then
    return
  end

  theme_augroup = vim.api.nvim_create_augroup("DiffBanditTheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = theme_augroup,
    callback = function()
      highlights.apply(state.get_config())
      highlights_ready = true
    end,
  })
end

local function ensure_highlights(config)
  if not highlights_ready then
    highlights.apply(config or state.get_config())
    configure_theme_refresh(config or state.get_config())
    highlights_ready = true
  end
end

function M.setup(opts)
  local config = state.set_config(opts)
  highlights.apply(config)
  configure_theme_refresh(config)
  highlights_ready = true
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

local function start_session(left_source, right_source, opts)
  local config = state.get_config()
  ensure_highlights(config)
  local session, err = Session.start({ left = left_source, right = right_source }, config, opts)
  if not session then
    return nil, err
  end
  state.register(session)
  return session
end

local function current_session()
  return state.sessions[vim.api.nvim_get_current_tabpage()]
end

local function call_current_session(method)
  local session = current_session()
  if not session then
    vim.notify("DiffBandit: no active DiffBandit session", vim.log.levels.INFO)
    return nil
  end
  if type(session[method]) ~= "function" then
    vim.notify("DiffBandit: unsupported action " .. method, vim.log.levels.ERROR)
    return nil
  end
  return session[method](session)
end

local function load_queue_entry(queue, start_index, step)
  local index = start_index
  local count = #(queue.entries or {})
  while index >= 1 and index <= count do
    local loaded, err = queue.load(index)
    if loaded and loaded.left and loaded.right then
      queue.index = index
      return loaded, nil
    end
    vim.notify("DiffBandit: skipping " .. tostring(err or "unreadable git file"), vim.log.levels.WARN)
    index = index + step
  end
  return nil, "no readable changed file"
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

function M.git(opts)
  local config = state.get_config()
  ensure_highlights(config)
  local queue, err = git_mod.queue(opts or {}, config.git or {})
  if not queue then
    return nil, err
  end

  local loaded, load_err = load_queue_entry(queue, queue.index or 1, 1)
  if not loaded then
    return nil, load_err
  end

  return start_session(loaded.left, loaded.right, { queue = queue })
end

function M.git_file(path, opts)
  opts = vim.tbl_extend("force", {}, opts or {}, {
    scope = "current",
    path = path,
  })
  return M.git(opts)
end

function M.toggle_stage_hunk()
  return call_current_session("toggle_stage_hunk")
end

function M.stage_hunk()
  return call_current_session("stage_hunk")
end

function M.unstage_hunk()
  return call_current_session("unstage_hunk")
end

function M.discard_hunk()
  return call_current_session("discard_hunk")
end

function M.apply_left_hunk()
  return call_current_session("apply_left_hunk")
end

function M.apply_right_hunk()
  return call_current_session("apply_right_hunk")
end

function M.undo()
  return call_current_session("undo_action")
end

return M
