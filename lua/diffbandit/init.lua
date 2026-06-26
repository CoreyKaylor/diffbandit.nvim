local state = require("diffbandit.state")
local diff_mod = require("diffbandit.diff")
local Session = require("diffbandit.session")
local highlights = require("diffbandit.highlights")
local git_mod = require("diffbandit.git")
local hex = require("diffbandit.hex")
local CommitPanel = require("diffbandit.commit_panel")
local Merge = require("diffbandit.merge")
local Folder = require("diffbandit.folder")

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

local function source_from_hex_file(path, label, text, config)
  local dump = hex.dump(text or "", ((config or {}).ui or {}).hex or {})
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

local function source_from_text(text, path, label, metadata)
  local lines = {}
  text = text or ""
  if text ~= "" then
    lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines, #lines)
    end
  end
  local source = {
    path = path,
    label = label or path,
    lines = lines,
    text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or "",
    filetype = detect_filetype(path),
  }
  for key, value in pairs(metadata or {}) do
    source[key] = value
  end
  return source
end

local function make_source_from_file(path, label, config)
  local raw, raw_err = read_file_raw(path)
  if not raw then
    return nil, raw_err
  end
  local hex_config = ((config or {}).ui or {}).hex or {}
  if hex.is_binary(raw) then
    if hex_config.enabled ~= false then
      return source_from_hex_file(path, label, raw, config)
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

local function current_panel()
  return state.panels[vim.api.nvim_get_current_tabpage()]
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
  local config = state.get_config()
  local left_source, left_err = make_source_from_file(left_path, opts.left_label, config)
  if not left_source then
    return nil, left_err
  end

  local right_source, right_err = make_source_from_file(right_path, opts.right_label, config)
  if not right_source then
    return nil, right_err
  end

  return start_session(left_source, right_source, opts)
end

function M.buffers(bufnr_a, bufnr_b, opts)
  opts = opts or {}
  local left_source = make_source_from_buffer(bufnr_a, opts.left_label)
  local right_source = make_source_from_buffer(bufnr_b, opts.right_label)
  return start_session(left_source, right_source, opts)
end

function M.git(opts)
  local config = state.get_config()
  ensure_highlights(config)
  local git_config = vim.tbl_extend("force", {}, config.git or {}, {
    hex = (config.ui or {}).hex or {},
  })
  local queue, err = git_mod.queue(opts or {}, git_config)
  if not queue then
    return nil, err
  end

  local loaded, load_err = load_queue_entry(queue, queue.index or 1, 1)
  if not loaded then
    return nil, load_err
  end

  return start_session(loaded.left, loaded.right, { queue = queue, chunk_position = "top" })
end

local function start_merge_for_entry(queue, entry, opts)
  opts = opts or {}
  if not queue or not entry then
    return nil, "no conflict entry selected"
  end
  local config = state.get_config()
  ensure_highlights(config)
  local data, err = Merge.load(queue.root, entry.path, config)
  if not data then
    return nil, err
  end
  return Merge.start(data, config, vim.tbl_extend("force", opts, {
    queue = queue,
    queue_index = opts.queue_index or queue.index,
  }))
end

function M.merge(path, opts)
  local config = state.get_config()
  ensure_highlights(config)
  return Merge.start_for_path(path, opts or {}, config)
end

local function start_folder_file_diff(folder_session, row, context)
  if not row then
    return nil, "no folder row selected"
  end
  local config = state.get_config()
  local left_source
  local right_source
  if row.left then
    left_source = make_source_from_file(row.left.path, row.rel, config)
  else
    left_source = source_from_text("", row.rel, row.rel .. " (missing left)", {
      empty_reason = "missing from left folder",
    })
  end
  if not left_source then
    return nil, "unable to read left file"
  end
  if row.right then
    right_source = make_source_from_file(row.right.path, row.rel, config)
  else
    right_source = source_from_text("", row.rel, row.rel .. " (missing right)", {
      empty_reason = "missing from right folder",
    })
  end
  if not right_source then
    return nil, "unable to read right file"
  end

  local session, err = start_session(left_source, right_source, {
    return_to = {
      session = folder_session,
      tabpage = context and context.tabpage,
      context = context,
    },
  })
  if not session then
    vim.notify("DiffBandit: " .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end
  return session, nil
end

function M.folder_diff(left_path, right_path, opts)
  opts = opts or {}
  local config = state.get_config()
  ensure_highlights(config)
  return Folder.start(left_path, right_path, config, vim.tbl_extend("force", opts, {
    open_file_diff = opts.open_file_diff or start_folder_file_diff,
  }))
end

function M.commit_panel(opts)
  local existing_panel = current_panel()
  if existing_panel and not existing_panel.disposed then
    return existing_panel:toggle_commit_panel()
  end

  local existing = current_session()
  if existing and existing.file_queue and existing.file_queue.kind == "git" and type(existing.toggle_commit_panel) == "function" then
    return existing:toggle_commit_panel()
  end

  local config = state.get_config()
  ensure_highlights(config)
  local git_config = vim.tbl_extend("force", {}, config.git or {}, {
    hex = (config.ui or {}).hex or {},
  })
  local queue, err = git_mod.queue(opts or {}, git_config)
  if not queue then
    return nil, err
  end
  queue.index = 0

  return CommitPanel.start(config, queue, {
    start_diff = function(left, right, start_opts)
      return start_session(left, right, start_opts)
    end,
    start_merge = function(entry, merge_queue, start_opts)
      return start_merge_for_entry(merge_queue or queue, entry, start_opts)
    end,
  })
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
