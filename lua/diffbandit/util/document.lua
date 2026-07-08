local source_mod = require("diffbandit.util.source")
local text = require("diffbandit.util.text")

local M = {}

local function realpath(path)
  if not path or path == "" then
    return nil
  end
  local uv = vim.uv or vim.loop
  return uv.fs_realpath(path)
end

function M.normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return realpath(path) or vim.fn.fnamemodify(path, ":p")
end

function M.find_loaded_buffer(path)
  local normalized = M.normalize_path(path)
  if not normalized then
    return nil
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
      local buffer_path = M.normalize_path(name)
      if buftype == "" and name ~= "" and buffer_path == normalized then
        return bufnr
      end
    end
  end
  return nil
end

--- Buffer lines with the empty-buffer convention: a single empty string
--- (nvim's empty buffer) is treated as zero lines.
function M.buffer_lines(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    return {}
  end
  return lines
end

function M.source_from_buffer(bufnr, label, metadata)
  local lines = M.buffer_lines(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  local source = source_mod.from_lines(lines, path ~= "" and path or nil,
    label or (path ~= "" and path or string.format("buffer:%d", bufnr)), metadata)
  source.filetype = filetype ~= "" and filetype or source.filetype
  return source
end

function M.source_from_file_or_buffer(path, label, metadata, fallback_reader)
  local bufnr = M.find_loaded_buffer(path)
  if bufnr then
    local source = M.source_from_buffer(bufnr, label, metadata)
    source.editable = vim.tbl_extend("force", {}, source.editable or {}, {
      target = ((metadata or {}).editable or {}).target or "file",
      bufnr = bufnr,
      path = M.normalize_path(path) or path,
    })
    return source, nil
  end
  if fallback_reader then
    local source, err = fallback_reader()
    if source and not (source.binary_hidden or source.binary_hex or source.git_binary_hidden or source.git_binary_hex) then
      source.editable = vim.tbl_extend("force", {}, source.editable or {}, {
        target = ((metadata or {}).editable or {}).target or "file",
        path = M.normalize_path(path) or path,
      })
    end
    return source, err
  end
  return nil, "no source reader for " .. tostring(path)
end

function M.acquire_buffer(editable)
  if not editable then
    return nil, nil
  end

  if editable.bufnr and vim.api.nvim_buf_is_valid(editable.bufnr) then
    return editable.bufnr, false
  end

  local path = editable.path
  if not path or path == "" then
    return nil, "editable source has no path"
  end

  local existing = M.find_loaded_buffer(path)
  if existing then
    editable.bufnr = existing
    return existing, false
  end

  local bufnr = vim.fn.bufadd(path)
  if not bufnr or bufnr == 0 then
    return nil, "unable to create buffer for " .. tostring(path)
  end
  pcall(vim.api.nvim_set_option_value, "swapfile", false, { buf = bufnr })
  -- Loading the buffer emits the ':edit'-style file-info message
  -- ("path" [noeol] N lines, M bytes); long paths wrap the cmdline and
  -- block the queue advance behind a hit-enter prompt. Silence it.
  vim.cmd(string.format("silent call bufload(%d)", bufnr))
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, "unable to load buffer for " .. tostring(path)
  end
  pcall(vim.api.nvim_set_option_value, "buflisted", true, { buf = bufnr })
  editable.bufnr = bufnr
  editable.created_by_diffbandit = true
  return bufnr, true
end

function M.refresh_source_from_editable(source)
  local editable = source and source.editable
  local bufnr = editable and editable.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return source
  end
  source.lines = M.buffer_lines(bufnr)
  source.text = text.to_text(source.lines)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if filetype and filetype ~= "" then
    source.filetype = filetype
  end
  return source
end

local function config_matches_filetype(config, filetype)
  local filetypes = config and config.filetypes
  if type(filetypes) ~= "table" then
    return true
  end
  return vim.tbl_contains(filetypes, filetype)
end

local function start_builtin_lsp_configs(bufnr, filetype)
  if not (vim.lsp and type(vim.lsp.get_configs) == "function" and type(vim.lsp.start) == "function") then
    return
  end
  local ok, configs = pcall(vim.lsp.get_configs)
  if not ok or type(configs) ~= "table" then
    return
  end
  for _, config in pairs(configs) do
    if type(config) == "table"
        and config.name
        and config_matches_filetype(config, filetype)
        and (type(vim.lsp.is_enabled) ~= "function" or vim.lsp.is_enabled(config.name)) then
      local copy = vim.deepcopy(config)
      local function start_config()
        pcall(vim.lsp.start, copy, {
          bufnr = bufnr,
          reuse_client = copy.reuse_client,
          silent = true,
          _root_markers = copy.root_markers,
        })
      end
      if type(copy.root_dir) == "function" then
        local root_fn = copy.root_dir
        copy.root_dir = nil
        local ok_root, root_dir = pcall(root_fn, bufnr, function(resolved_root_dir)
          copy.root_dir = resolved_root_dir
          vim.schedule(start_config)
        end)
        if ok_root and type(root_dir) == "string" then
          copy.root_dir = root_dir
          start_config()
        end
      else
        start_config()
      end
    end
  end
end

local function set_filetype_if_needed(bufnr, filetype)
  local current = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if (not current or current == "") and filetype and filetype ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", filetype, { buf = bufnr })
    current = filetype
  end
  return current
end

local function disable_buffer_diagnostics(bufnr)
  if not (vim.diagnostic and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if type(vim.diagnostic.enable) == "function" then
    pcall(vim.diagnostic.enable, false, { bufnr = bufnr })
  elseif type(vim.diagnostic.disable) == "function" then
    pcall(vim.diagnostic.disable, bufnr)
  end
  if type(vim.diagnostic.reset) == "function" then
    pcall(vim.diagnostic.reset, nil, bufnr)
  end
end

function M.ensure_syntax_features(bufnr, filetype)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  set_filetype_if_needed(bufnr, filetype)
  disable_buffer_diagnostics(bufnr)
end

function M.ensure_language_features(bufnr, filetype)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
    return
  end

  local current = set_filetype_if_needed(bufnr, filetype)
  if not current or current == "" then
    return
  end

  start_builtin_lsp_configs(bufnr, current)

  if vim.fn.exists(":LspStart") == 2 then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      pcall(vim.cmd, "LspStart")
    end)
  end
end

function M.cleanup_created_buffer(editable, opts)
  opts = opts or {}
  local bufnr = editable and editable.bufnr
  if not (editable and editable.created_by_diffbandit and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    if opts.discard_if_unchanged
        and editable.initial_changedtick
        and vim.api.nvim_buf_get_changedtick(bufnr) == editable.initial_changedtick then
      pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
    else
      pcall(vim.api.nvim_set_option_value, "bufhidden", "hide", { buf = bufnr })
      return
    end
  end
  if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    pcall(vim.api.nvim_set_option_value, "bufhidden", "hide", { buf = bufnr })
    return
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
end

return M
