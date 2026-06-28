local diff = require("diffbandit.diff")
local diff_pair = require("diffbandit.diff_pair")
local git = require("diffbandit.git")
local panel_mod = require("diffbandit.panel")
local Session = require("diffbandit.session")
local state = require("diffbandit.state")
local ui = require("diffbandit.ui")

local Merge = {}
Merge.__index = Merge

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function to_text(lines)
  if not lines or #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function logical_buffer_lines(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    return {}
  end
  return lines
end

local function detect_filetype(path)
  if not path or path == "" then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

local function make_buffer(name, lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  if name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.api.nvim_set_option_value("buftype", opts.buftype or "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", opts.bufhidden or "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", opts.modifiable ~= false, { buf = buf })
  if opts.filetype and opts.filetype ~= "" then
    vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
  end
  return buf
end

local function set_win_width(win, width)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_width, win, math.max(1, width))
  end
end

local function set_win_height(win, height)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_height, win, math.max(1, height))
  end
end

local function set_win_view_topline(win, topline)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  topline = math.max(1, topline or 1)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))
  local cursor_line = math.min(topline, line_count)
  pcall(vim.api.nvim_win_call, win, function()
    pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    local view = vim.fn.winsaveview()
    view.topline = topline
    pcall(vim.fn.winrestview, view)
  end)
end

local function get_win_view_topline(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return 1
  end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if ok and view and view.topline then
    return view.topline
  end
  return 1
end

local function get_win_width(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
  return 0
end

local function get_win_height(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_height(win)
  end
  return 0
end

local function set_win_options(win, opts)
  for key, value in pairs(opts) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = win })
  end
end

local function hunk_base_start(hunk)
  return hunk.left.start
end

local function hunk_base_end(hunk)
  if hunk.left.count <= 0 then
    return hunk.left.start
  end
  return hunk.left.start + hunk.left.count - 1
end

local function ranges_overlap(left, right)
  return hunk_base_start(left) <= hunk_base_end(right) and hunk_base_start(right) <= hunk_base_end(left)
end

local function merged_base_count(left, right, start_row, end_row)
  if (not left or left.left.count <= 0) and (not right or right.left.count <= 0) then
    return 0
  end
  return math.max(0, end_row - start_row + 1)
end

local function hunk_replacement(lines, hunk)
  local replacement = {}
  for index = hunk.right.start, hunk.right.start + hunk.right.count - 1 do
    replacement[#replacement + 1] = lines[index] or ""
  end
  return replacement
end

local function source_label(path, suffix)
  return string.format("%s (%s)", path or "[conflict]", suffix)
end

local function line_ending(text)
  if not text or text == "" then
    return "none"
  end
  local crlf = text:find("\r\n", 1, true) ~= nil
  local lf = text:find("[^\r]\n") ~= nil
  if crlf and lf then
    return "mixed"
  elseif crlf then
    return "crlf"
  end
  return "lf"
end

local function line_ending_warning(parts)
  local seen = {}
  for _, text in pairs(parts) do
    local ending = line_ending(text)
    if ending ~= "none" then
      seen[ending] = true
    end
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  if count > 1 then
    return "line endings differ across conflict stages"
  end
  return nil
end

local function replace_range(lines, start, count, replacement)
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
  for index = resume_at, #lines do
    result[#result + 1] = lines[index]
  end
  return result
end

local function build_regions(base_lines, local_lines, remote_lines, config)
  local base_text = to_text(base_lines)
  local local_hunks = diff.compute_hunks(base_text, to_text(local_lines), config.diff or {})
  local remote_hunks = diff.compute_hunks(base_text, to_text(remote_lines), config.diff or {})
  if type(local_hunks) ~= "table" then
    local_hunks = {}
  end
  if type(remote_hunks) ~= "table" then
    remote_hunks = {}
  end

  local local_conflicted = {}
  local remote_conflicted = {}
  local conflicts = {}
  for local_index, local_hunk in ipairs(local_hunks) do
    for remote_index, remote_hunk in ipairs(remote_hunks) do
      if ranges_overlap(local_hunk, remote_hunk) then
        local_conflicted[local_index] = true
        remote_conflicted[remote_index] = true
        local start_row = math.min(hunk_base_start(local_hunk), hunk_base_start(remote_hunk))
        local end_row = math.max(hunk_base_end(local_hunk), hunk_base_end(remote_hunk))
        local base_count = merged_base_count(local_hunk, remote_hunk, start_row, end_row)
        conflicts[#conflicts + 1] = {
          type = "conflict",
          base_start = start_row,
          base_count = base_count,
          result_start = start_row,
          result_count = base_count,
          local_hunk = local_hunk,
          remote_hunk = remote_hunk,
          local_replacement = hunk_replacement(local_lines, local_hunk),
          remote_replacement = hunk_replacement(remote_lines, remote_hunk),
        }
      end
    end
  end

  table.sort(conflicts, function(left, right)
    return left.base_start < right.base_start
  end)

  local non_conflicting = {}
  for index, hunk in ipairs(local_hunks) do
    if not local_conflicted[index] then
      non_conflicting[#non_conflicting + 1] = {
        side = "local",
        base_start = hunk_base_start(hunk),
        base_count = hunk.left.count,
        hunk = hunk,
        replacement = hunk_replacement(local_lines, hunk),
      }
    end
  end
  for index, hunk in ipairs(remote_hunks) do
    if not remote_conflicted[index] then
      non_conflicting[#non_conflicting + 1] = {
        side = "remote",
        base_start = hunk_base_start(hunk),
        base_count = hunk.left.count,
        hunk = hunk,
        replacement = hunk_replacement(remote_lines, hunk),
      }
    end
  end
  table.sort(non_conflicting, function(left, right)
    return left.base_start > right.base_start
  end)

  return conflicts, non_conflicting, local_hunks, remote_hunks
end

function Merge.load(root, path, config)
  local stages, err = git.conflict_stages(root, path)
  if not stages then
    return nil, err
  end
  local base_text = stages.base or ""
  local local_text = stages.local_text or ""
  local remote_text = stages.remote or ""
  local base_lines = split_lines(base_text)
  local local_lines = split_lines(local_text)
  local remote_lines = split_lines(remote_text)
  local conflicts, non_conflicting, local_hunks, remote_hunks = build_regions(base_lines, local_lines, remote_lines, config or {})
  return {
    root = root,
    path = path,
    base_text = base_text,
    local_text = local_text,
    remote_text = remote_text,
    has_local = stages.has_local ~= false,
    has_remote = stages.has_remote ~= false,
    base_lines = base_lines,
    local_lines = local_lines,
    remote_lines = remote_lines,
    result_lines = vim.deepcopy(base_lines),
    conflicts = conflicts,
    non_conflicting = non_conflicting,
    local_hunks = local_hunks,
    remote_hunks = remote_hunks,
    line_ending_warning = line_ending_warning({
      base = base_text,
      local_text = local_text,
      remote = remote_text,
    }),
  }, nil
end

function Merge.start(data, config, opts)
  opts = opts or {}
  local self = setmetatable({}, Merge)
  self.config = config or state.get_config()
  self.id = state.next_session_id()
  self.ns = vim.api.nvim_create_namespace("DiffBanditMerge" .. tostring(self.id))
  self.result_left_ns = vim.api.nvim_create_namespace("DiffBanditMergeResultLeft" .. tostring(self.id))
  self.result_right_ns = vim.api.nvim_create_namespace("DiffBanditMergeResultRight" .. tostring(self.id))
  self.active_ns = vim.api.nvim_create_namespace("DiffBanditMergeActive" .. tostring(self.id))
  self.header_ns = vim.api.nvim_create_namespace("DiffBanditMergeHeader" .. tostring(self.id))
  self.root = data.root
  self.path = data.path
  self.base_lines = data.base_lines or {}
  self.local_lines = data.local_lines or {}
  self.remote_lines = data.remote_lines or {}
  self.has_local = data.has_local ~= false
  self.has_remote = data.has_remote ~= false
  self.delete_result = false
  self.result_lines = data.result_lines or vim.deepcopy(self.base_lines)
  self.conflicts = data.conflicts or {}
  self.non_conflicting = data.non_conflicting or {}
  self.local_hunks = data.local_hunks or {}
  self.remote_hunks = data.remote_hunks or {}
  self.current_conflict = #self.conflicts > 0 and 1 or 0
  self.selected_pair_hunk = nil
  self.line_ending_warning = data.line_ending_warning
  self.file_queue = opts.queue
  self.file_queue_index = opts.queue_index or (opts.queue and opts.queue.index)
  self.right_win = nil
  self.panel_enabled = opts.panel == true
  self.panel_initial_selection = opts.panel_initial_selection
  self.panel_message_lines = opts.panel_message_lines
  self.panel_amend = opts.panel_amend == true
  self.disposed = false
  self.status_enabled = (((self.config or {}).ui or {}).status or {}).enabled ~= false
  self.merge_context = git.merge_context(self.root)
  self.connector_width = math.max((((self.config or {}).ui or {}).connector_width or 12), 1)

  local ft = detect_filetype(self.path)
  self.local_buf = make_buffer(source_label(self.path, "local"), self.local_lines, { modifiable = false, filetype = ft })
  self.result_buf = make_buffer("diffbandit-merge-result-" .. tostring(self.id) .. ":" .. self.path, self.result_lines, {
    buftype = "acwrite",
    modifiable = true,
    filetype = ft,
  })
  self.remote_buf = make_buffer(source_label(self.path, "remote"), self.remote_lines, { modifiable = false, filetype = ft })
  self.local_num_buf = make_buffer(nil, {}, { modifiable = false })
  self.local_result_connector_buf = make_buffer(nil, {}, { modifiable = false })
  self.result_left_num_buf = make_buffer(nil, {}, { modifiable = false })
  self.result_right_num_buf = make_buffer(nil, {}, { modifiable = false })
  self.result_remote_connector_buf = make_buffer(nil, {}, { modifiable = false })
  self.remote_num_buf = make_buffer(nil, {}, { modifiable = false })
  self.local_header_buf = self.status_enabled and make_buffer(nil, {}, { modifiable = false }) or nil
  self.result_header_buf = self.status_enabled and make_buffer(nil, {}, { modifiable = false }) or nil
  self.remote_header_buf = self.status_enabled and make_buffer(nil, {}, { modifiable = false }) or nil

  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()
  if self.panel_enabled then
    self.panel = {
      nav_buf = make_buffer(nil, {}, { modifiable = false, bufhidden = "hide" }),
      commit_buf = make_buffer("diffbandit-commit-" .. tostring(self.id), {}, {
        buftype = "acwrite",
        bufhidden = "hide",
      }),
      message_lines = self.panel_message_lines or { "" },
      amend = self.panel_amend == true,
      visible = true,
    }
    self.panel.nav_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.panel.nav_win, self.panel.nav_buf)
    if self.status_enabled then
      self.local_header_win = vim.api.nvim_open_win(self.local_header_buf, false, {
        split = "right",
        win = self.panel.nav_win,
      })
    else
      self.local_win = vim.api.nvim_open_win(self.local_buf, false, {
        split = "right",
        win = self.panel.nav_win,
      })
    end
  else
    if self.status_enabled then
      self.local_header_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(self.local_header_win, self.local_header_buf)
    else
      self.local_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(self.local_win, self.local_buf)
    end
  end

  if self.status_enabled then
    self.local_win = vim.api.nvim_open_win(self.local_buf, false, {
      split = "below",
      win = self.local_header_win,
    })
    self.result_header_win = vim.api.nvim_open_win(self.result_header_buf, false, {
      split = "right",
      win = self.local_header_win,
    })
    self.remote_header_win = vim.api.nvim_open_win(self.remote_header_buf, false, {
      split = "right",
      win = self.result_header_win,
    })
  end

  self.result_win = vim.api.nvim_open_win(self.result_buf, false, {
    split = "right",
    win = self.local_win,
  })
  self.remote_win = vim.api.nvim_open_win(self.remote_buf, false, {
    split = "right",
    win = self.result_win,
  })

  local function open_gutter(buf, anchor_win, width)
    local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
      split = "right",
      win = anchor_win,
      width = width,
      focusable = false,
      mouse = false,
    })
    if ok then
      return win
    end
    return vim.api.nvim_open_win(buf, false, {
      split = "right",
      win = anchor_win,
      width = width,
    })
  end

  local num_width = math.max(3, ui.digits_of(math.max(#self.local_lines, #self.result_lines, #self.remote_lines)))
  self.number_width = num_width
  self.local_num_win = open_gutter(self.local_num_buf, self.local_win, num_width + 1)
  self.local_result_connector_win = open_gutter(self.local_result_connector_buf, self.local_num_win, self.connector_width)
  self.result_left_num_win = open_gutter(self.result_left_num_buf, self.local_result_connector_win, num_width + 1)
  self.result_right_num_win = open_gutter(self.result_right_num_buf, self.result_win, num_width + 1)
  self.result_remote_connector_win = open_gutter(self.result_remote_connector_buf, self.result_right_num_win, self.connector_width)
  self.remote_num_win = open_gutter(self.remote_num_buf, self.result_remote_connector_win, num_width + 1)

  self.right_win = self.result_win
  if self.panel_enabled then
    local panel_config = (((self.config or {}).git or {}).panel or {})
    self.panel.commit_win = vim.api.nvim_open_win(self.panel.commit_buf, false, {
      split = "below",
      win = self.panel.nav_win,
      height = panel_config.commit_height or 10,
    })
    set_win_width(self.panel.nav_win, panel_config.width or 42)
    set_win_width(self.panel.commit_win, panel_config.width or 42)
  end
  self:configure_windows()
  self:setup_autocmds()
  self:setup_keymaps()
  self:render()
  if self.panel_enabled then
    panel_mod.attach(self, {
      initial_selection = self.panel_initial_selection,
      no_initial_selection = not self.panel_initial_selection,
    })
  end
  if self.panel_enabled and self.panel and self.panel.nav_win then
    vim.api.nvim_set_current_win(self.panel.nav_win)
  else
    vim.api.nvim_set_current_win(self.result_win)
  end
  state.register(self)
  return self, nil
end

function Merge.start_for_path(path, opts, config)
  opts = opts or {}
  config = config or state.get_config()
  local start = path or vim.api.nvim_buf_get_name(0) or vim.loop.cwd()
  local root, root_err = git.find_root(start)
  if not root then
    return nil, root_err
  end
  local rel = path and git.relpath(root, path) or git.relpath(root, vim.api.nvim_buf_get_name(0))
  if not rel or rel == "" then
    return nil, "no conflict path provided"
  end
  local data, data_err = Merge.load(root, rel, config)
  if not data then
    return nil, data_err
  end
  return Merge.start(data, config, opts)
end

function Merge:configure_windows()
  local split_winhl = "WinSeparator:DiffBanditSplit,VertSplit:DiffBanditSplit"
  local winhl = split_winhl .. ",CursorLine:DiffBanditCursorLine"
  local gutter_winhl = "Normal:DiffBanditConnectorContext,NormalNC:DiffBanditConnectorContext,"
    .. split_winhl .. ",CursorLine:DiffBanditCursorLine"
  local status_winhl = "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,"
    .. "StatusLine:DiffBanditStatusLine,StatusLineNC:DiffBanditStatusLine,"
    .. split_winhl .. ",CursorLine:DiffBanditStatus"
  for _, win in ipairs({ self.local_win, self.result_win, self.remote_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      set_win_options(win, {
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = false,
        cursorline = true,
        winhl = winhl,
      })
    end
  end
  for _, win in ipairs({
    self.local_num_win,
    self.local_result_connector_win,
    self.result_left_num_win,
    self.result_right_num_win,
    self.result_remote_connector_win,
    self.remote_num_win,
  }) do
    if win and vim.api.nvim_win_is_valid(win) then
      set_win_options(win, {
        number = false,
        relativenumber = false,
        list = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = false,
        cursorline = false,
        winfixwidth = true,
        winhl = gutter_winhl,
      })
    end
  end
  for _, win in ipairs({ self.local_header_win, self.result_header_win, self.remote_header_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      set_win_options(win, {
        number = false,
        relativenumber = false,
        list = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = false,
        cursorline = false,
        winfixheight = true,
        statusline = " ",
        winhl = status_winhl,
      })
      set_win_height(win, 1)
    end
  end
  set_win_width(self.local_num_win, (self.number_width or 3) + 1)
  set_win_width(self.local_result_connector_win, self.connector_width or 12)
  set_win_width(self.result_left_num_win, (self.number_width or 3) + 1)
  set_win_width(self.result_right_num_win, (self.number_width or 3) + 1)
  set_win_width(self.result_remote_connector_win, self.connector_width or 12)
  set_win_width(self.remote_num_win, (self.number_width or 3) + 1)
  local content_width = math.max(15, math.floor((vim.o.columns
    - ((self.panel and (((self.config.git or {}).panel or {}).width or 42)) or 0)
    - (((self.number_width or 3) + 1) * 4)
    - ((self.connector_width or 12) * 2)) / 3))
  set_win_width(self.local_win, content_width)
  set_win_width(self.result_win, content_width)
  set_win_width(self.remote_win, content_width)
  if self.status_enabled then
    set_win_width(self.local_header_win, content_width)
    set_win_width(self.result_header_win, content_width + (((self.number_width or 3) + 1) * 2) + (self.connector_width or 12))
    set_win_width(self.remote_header_win, content_width + ((self.number_width or 3) + 1) + (self.connector_width or 12))
  end
  for _, win in ipairs({ self.local_win, self.result_win, self.remote_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_option_value, "winbar", "", { scope = "local", win = win })
    end
  end
  if self.panel then
    local panel_config = (((self.config or {}).git or {}).panel or {})
    local panel_winhl = "WinSeparator:DiffBanditSplit,VertSplit:DiffBanditSplit,"
      .. "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,CursorLine:DiffBanditCursorLine"
    for _, win in ipairs({ self.panel.nav_win, self.panel.commit_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        set_win_options(win, {
          number = false,
          relativenumber = false,
          list = false,
          signcolumn = "no",
          foldcolumn = "0",
          wrap = false,
          cursorline = true,
          winfixwidth = true,
          winhl = panel_winhl,
        })
        set_win_width(win, panel_config.width or 42)
      end
    end
    set_win_height(self.panel.commit_win, panel_config.commit_height or 10)
  end
end

function Merge:setup_autocmds()
  self.augroup = vim.api.nvim_create_augroup("DiffBanditMerge" .. tostring(self.id), { clear = true })
  self.last_content_win = self.result_win
  local function semantic_target_for_gutter(win, previous)
    if win == self.local_num_win
        or win == self.local_result_connector_win
        or win == self.result_left_num_win then
      if previous == self.local_win then
        return self.result_win
      end
      if previous == self.result_win then
        return self.local_win
      end
    elseif win == self.result_right_num_win
        or win == self.result_remote_connector_win
        or win == self.remote_num_win then
      if previous == self.result_win then
        return self.remote_win
      end
      if previous == self.remote_win then
        return self.result_win
      end
    end
    return previous
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = self.augroup,
    buffer = self.result_buf,
    callback = function()
      self:resolve()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.result_buf,
    callback = function()
      if self.result_buffer_update_depth and self.result_buffer_update_depth > 0 then
        return
      end
      self:request_render()
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      if self.disposed then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == self.local_win or win == self.result_win or win == self.remote_win then
        self.last_content_win = win
        return
      end
      if win == self.local_num_win
          or win == self.local_result_connector_win
          or win == self.result_left_num_win
          or win == self.result_right_num_win
          or win == self.result_remote_connector_win
          or win == self.remote_num_win
          or win == self.local_header_win
          or win == self.result_header_win
          or win == self.remote_header_win then
        vim.schedule(function()
          if self.disposed then
            return
          end
          local target = semantic_target_for_gutter(win, self.last_content_win)
          if not (target and vim.api.nvim_win_is_valid(target)) then
            target = self.result_win
          end
          if target and vim.api.nvim_win_is_valid(target) then
            pcall(vim.api.nvim_set_current_win, target)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = self.augroup,
    callback = function(args)
      if tonumber(args.file) == self.tabpage then
        self:close(true)
      end
    end,
  })
end

function Merge:request_render()
  if self.render_timer then
    self.render_timer:stop()
    self.render_timer:close()
    self.render_timer = nil
  end
  local delay = tonumber(((self.config or {}).ui or {}).scroll_debounce_ms) or 16
  local timer = vim.uv and vim.uv.new_timer() or vim.loop.new_timer()
  self.render_timer = timer
  timer:start(delay, 0, function()
    timer:stop()
    timer:close()
    vim.schedule(function()
      if not self.disposed then
        self.render_timer = nil
        self:render()
      end
    end)
  end)
end

function Merge:render_view_key(result_tick)
  return table.concat({
    tostring(result_tick or (self.result_buf and vim.api.nvim_buf_get_changedtick(self.result_buf)) or 0),
    tostring(get_win_view_topline(self.local_win)),
    tostring(get_win_view_topline(self.result_win)),
    tostring(get_win_view_topline(self.remote_win)),
    tostring(get_win_width(self.local_win)),
    tostring(get_win_width(self.result_win)),
    tostring(get_win_width(self.remote_win)),
    tostring(get_win_width(self.local_result_connector_win)),
    tostring(get_win_width(self.result_remote_connector_win)),
    tostring(get_win_height(self.local_win)),
    tostring(get_win_height(self.result_win)),
    tostring(get_win_height(self.remote_win)),
    tostring(self.connector_width or 0),
  }, ":")
end

function Merge:set_result_buffer_lines(lines)
  self.result_buffer_update_depth = (self.result_buffer_update_depth or 0) + 1
  local ok, err = pcall(vim.api.nvim_buf_set_lines, self.result_buf, 0, -1, false, lines or {})
  self.result_buffer_update_depth = math.max(0, (self.result_buffer_update_depth or 1) - 1)
  if not ok then
    error(err)
  end
end

function Merge:setup_keymaps()
  local keys = ((self.config or {}).merge or {}).keys or {}
  local document_keys = (((self.config or {}).navigation or {}).document_keys) or {}
  local function map(buf, lhs, rhs)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, noremap = true, silent = true })
    end
  end
  for _, buf in ipairs({ self.local_buf, self.result_buf, self.remote_buf }) do
    map(buf, keys.next_conflict, function() self:goto_next_hunk() end)
    map(buf, keys.prev_conflict, function() self:goto_prev_hunk() end)
    map(buf, keys.accept_local, function() self:accept("local") end)
    map(buf, keys.accept_remote, function() self:accept("remote") end)
    map(buf, keys.accept_both, function() self:accept("both") end)
    map(buf, keys.apply_non_conflicting, function() self:apply_non_conflicting() end)
    map(buf, keys.focus_panel, function() self:focus_commit_panel_for_current_file() end)
    map(buf, document_keys.top, function() self:goto_document_edge("top") end)
    map(buf, document_keys.bottom, function() self:goto_document_edge("bottom") end)
    map(buf, keys.close, function() self:close() end)
  end
end

function Merge:status_text()
  local conflict_text
  if #self.conflicts == 0 then
    conflict_text = "no conflicts"
  elseif self.current_conflict > 0 then
    conflict_text = string.format("conflict %d/%d", self.current_conflict, #self.conflicts)
  else
    conflict_text = string.format("%d conflicts", #self.conflicts)
  end
  if self.line_ending_warning and (((self.config or {}).merge or {}).line_endings or {}).warn ~= false then
    conflict_text = conflict_text .. "  " .. self.line_ending_warning
  end
  return conflict_text
end

local function modified_text(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return "unknown"
  end
  return vim.api.nvim_get_option_value("modified", { buf = buf }) and "modified" or "saved"
end

function Merge:build_status_lines()
  local context = self.merge_context or {}
  local local_label = context.current or "current"
  local remote_label = context.incoming or "incoming"
  local operation = context.operation or "merge"
  local result_parts = {
    "merge result",
    self:status_text(),
    modified_text(self.result_buf),
  }
  return {
    left = table.concat({ "local/current", local_label, self.path or "" }, "  "),
    result = table.concat(result_parts, "  "),
    result_action = self:selection_summary(),
    remote = table.concat({ "remote/incoming", operation .. " " .. remote_label, self.path or "" }, "  "),
  }
end

function Merge:render_headers()
  if not self.status_enabled then
    return
  end
  if not (self.local_header_win and self.result_header_win and self.remote_header_win) then
    return
  end
  if not (vim.api.nvim_win_is_valid(self.local_header_win)
      and vim.api.nvim_win_is_valid(self.result_header_win)
      and vim.api.nvim_win_is_valid(self.remote_header_win)) then
    return
  end
  local lines = self:build_status_lines()
  self.status_lines = {
    left = lines.left,
    center = lines.result,
    right = lines.remote,
  }
  ui.set_header_line(self.local_header_buf, self.header_ns, lines.left, vim.api.nvim_win_get_width(self.local_header_win))
  ui.set_header_line_with_right(
    self.result_header_buf,
    self.header_ns,
    lines.result,
    lines.result_action,
    vim.api.nvim_win_get_width(self.result_header_win)
  )
  ui.set_header_line(self.remote_header_buf, self.header_ns, lines.remote, vim.api.nvim_win_get_width(self.remote_header_win))
end

local function clear_range_hl(buf, ns, start_row, count)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  count = math.max(0, count or 0)
  if count == 0 then
    return
  end
  start_row = math.max(1, start_row or 1)
  local finish_row = math.min(vim.api.nvim_buf_line_count(buf), start_row + count - 1)
  if finish_row >= start_row then
    vim.api.nvim_buf_clear_namespace(buf, ns, start_row - 1, finish_row)
  end
end

local function anchor_row_for_zero_range(buf, start_row)
  local line_count = 1
  if buf and vim.api.nvim_buf_is_valid(buf) then
    line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
  end
  return math.max(0, math.min(line_count - 1, (start_row or 1) - 1))
end

local function set_zero_range_marker(buf, ns, row, col, hl, text)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local opts = {
    virt_text = { { text or " ", hl } },
    priority = 9000,
  }
  if (col or 0) > 0 then
    opts.virt_text_win_col = col
  else
    opts.virt_text_pos = "overlay"
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, opts)
end

local function set_zero_range_top_line(buf, ns, row, width, hl)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  width = math.max(1, width or 1)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    virt_text = { { string.rep("▔", width), hl } },
    virt_text_pos = "overlay",
    priority = 8990,
  })
end

local function result_count_for_render(region, result_lines)
  if #(result_lines or {}) == 0 then
    return 0
  end
  return math.max(0, (region or {}).result_count or 0)
end

local function source_for_pair(lines, path, label, filetype, metadata)
  local source = {
    path = path,
    label = label,
    lines = lines or {},
    text = to_text(lines or {}),
    filetype = filetype,
  }
  for key, value in pairs(metadata or {}) do
    source[key] = value
  end
  return source
end

local function connector_base_width(pair, config)
  local width = math.max((((config or {}).ui or {}).connector_width or 0), 0)
  for _, text in ipairs(((pair or {}).view or {}).connectors or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(text))
  end
  return math.max(1, width)
end

function Merge:build_pair_session(id_suffix, pair, left_source, right_source, buffers, windows, opts)
  opts = opts or {}
  local session = setmetatable({
    id = tostring(self.id) .. "-" .. id_suffix,
    config = self.config,
    left = left_source,
    right = right_source,
    hunks = pair.hunks or {},
    view = pair.view,
    current_chunk = 0,
    file_queue = nil,
    file_queue_index = nil,
    pending_file_boundary = nil,
    left_number_width = self.number_width,
    right_number_width = self.number_width,
    right_number_padding = ((self.config or {}).ui or {}).right_number_padding or 2,
    stage_marker_width = 0,
    left_stage_marker_width = 0,
    right_stage_marker_width = 0,
    left_number_pane_width = self.number_width + 1,
    right_number_pane_width = self.number_width + 1,
    connector_core_width = connector_base_width(pair, self.config),
    gutter_width = connector_base_width(pair, self.config),
    connector_width_cache = {},
    overview_enabled = false,
    overview_width = 0,
    status_enabled = false,
    staged_chunk_states = {},
    disposed = false,
    ns = vim.api.nvim_create_namespace("DiffBanditMergePair" .. tostring(self.id) .. id_suffix),
    active_ns = vim.api.nvim_create_namespace("DiffBanditMergePairActive" .. tostring(self.id) .. id_suffix),
    path_ns = vim.api.nvim_create_namespace("DiffBanditMergePairPaths" .. tostring(self.id) .. id_suffix),
    overview_ns = vim.api.nvim_create_namespace("DiffBanditMergePairOverview" .. tostring(self.id) .. id_suffix),
    left_buf = buffers.left,
    left_num_buf = buffers.left_num,
    connector_buf = buffers.connector,
    right_num_buf = buffers.right_num,
    right_buf = buffers.right,
    left_win = windows.left,
    left_num_win = windows.left_num,
    connector_win = windows.connector,
    right_num_win = windows.right_num,
    right_win = windows.right,
    preserve_left_buffer_lines = opts.preserve_left_buffer_lines == true,
    preserve_right_buffer_lines = opts.preserve_right_buffer_lines == true,
    suppress_right_context_highlights = opts.suppress_right_context_highlights == true,
    mirror_connector_sides = opts.mirror_connector_sides == true,
  }, { __index = Session })

  function session:resize_layout() end
  function session:render_status_headers() end
  function session:render_overviews() end
  function session:get_scroll_padding()
    return 0
  end

  session:invalidate_render_caches()
  session:precompute_connector_core_width()
  return session
end

function Merge:render_zero_range_delete_overlay(row, sides)
  sides = sides or {}
  row = math.max(0, row or 0)
  local number_pane_width = math.max(1, (self.number_width or 3) + 1)
  local connector_width = math.max(1, self.connector_width or 1)
  local result_width = self.result_win and vim.api.nvim_win_is_valid(self.result_win)
    and vim.api.nvim_win_get_width(self.result_win)
    or 1

  set_zero_range_top_line(
    self.result_buf,
    self.active_ns,
    row,
    result_width,
    "DiffBanditConnectorExpansionDelete"
  )

  if sides.left then
    set_zero_range_top_line(
      self.local_result_connector_buf,
      self.active_ns,
      row,
      connector_width,
      "DiffBanditConnectorExpansionDelete"
    )
    set_zero_range_marker(
      self.local_num_buf,
      self.active_ns,
      row,
      number_pane_width - 1,
      "DiffBanditConnectorExpansionDelete",
      "◤"
    )
  end

  if sides.right then
    set_zero_range_top_line(
      self.result_remote_connector_buf,
      self.active_ns,
      row,
      connector_width,
      "DiffBanditConnectorExpansionDelete"
    )
    set_zero_range_marker(
      self.remote_num_buf,
      self.active_ns,
      row,
      0,
      "DiffBanditConnectorExpansionDelete",
      "◥"
    )
  end
end

function Merge:render_pair_zero_delete_overlays()
  for _, hunk in ipairs(((self.local_result_pair or {}).hunks) or {}) do
    if hunk.type == "delete" and hunk.right.count == 0 and hunk.left.count > 0 and hunk.left.start == 1 then
      self:render_zero_range_delete_overlay(anchor_row_for_zero_range(self.result_buf, hunk.right.start), {
        left = true,
      })
    end
  end
  for _, hunk in ipairs(((self.result_remote_pair or {}).hunks) or {}) do
    if hunk.type == "delete" and hunk.right.count == 0 and hunk.left.count > 0 and hunk.left.start == 1 then
      self:render_zero_range_delete_overlay(anchor_row_for_zero_range(self.result_buf, hunk.right.start), {
        right = true,
      })
    end
  end
end

function Merge:clear_merge_overlays()
  for _, buf in ipairs({
    self.result_buf,
    self.local_num_buf,
    self.remote_num_buf,
    self.result_left_num_buf,
    self.result_right_num_buf,
    self.local_result_connector_buf,
    self.result_remote_connector_buf,
  }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, self.active_ns, 0, -1)
    end
  end
end

function Merge:render_merge_overlays()
  self:clear_merge_overlays()
  for _, region in ipairs(self.conflicts or {}) do
    local render_count = result_count_for_render(region, self.result_lines)
    if render_count > 0 then
      clear_range_hl(self.result_buf, self.active_ns, region.result_start, render_count)
    else
      local row = anchor_row_for_zero_range(self.result_buf, region.result_start)
      self:render_zero_range_delete_overlay(row, {
        left = true,
        right = true,
      })
    end
  end
  self:render_pair_zero_delete_overlays()
end

function Merge:render(opts)
  opts = opts or {}
  local result_tick = self.result_buf and vim.api.nvim_buf_get_changedtick(self.result_buf) or 0
  local next_result_lines = logical_buffer_lines(self.result_buf)
  local can_reuse_pairs = not opts.force_pair_rebuild
    and self.local_result_session
    and self.result_remote_session
    and self.local_result_pair
    and self.result_remote_pair
    and self.rendered_result_tick == result_tick

  if can_reuse_pairs then
    local view_key = self:render_view_key(result_tick)
    if self.rendered_view_key ~= view_key or opts.force_viewport == true then
      self.result_lines = next_result_lines
      self:rerender_pair_viewports()
      self:render_merge_overlays()
      self.rendered_view_key = self:render_view_key(result_tick)
    end
    self:render_headers()
    return true
  end

  self.result_lines = next_result_lines
  self.number_width = math.max(3, ui.digits_of(math.max(#self.local_lines, #self.result_lines, #self.remote_lines)))
  local left_pair, left_err = diff_pair.build(self.local_lines, self.result_lines, self.config)
  local right_pair, right_err = diff_pair.build(self.remote_lines, self.result_lines, self.config)
  if not left_pair or not right_pair then
    vim.notify("DiffBandit: " .. tostring(left_err or right_err or "unable to render merge"), vim.log.levels.ERROR)
    return
  end
  self.local_result_pair = left_pair
  self.result_remote_pair = right_pair

  local ft = detect_filetype(self.path)
  local local_source = source_for_pair(self.local_lines, self.path, source_label(self.path, "local"), ft, {
    display_number_width = self.number_width,
    empty_reason = self.has_local and nil or "Deleted file",
    git_state = self.has_local and "present" or "deleted",
    git_target = self.has_local and "merge-local" or "absent",
    git_ref = "local/current",
    git_relpath = self.path,
  })
  local result_source_left = source_for_pair(self.result_lines, self.path, source_label(self.path, "result"), ft, {
    display_number_width = self.number_width,
    git_target = "merge-result",
    git_ref = "merge result",
    git_relpath = self.path,
  })
  local result_source_right = source_for_pair(self.result_lines, self.path, source_label(self.path, "result"), ft, {
    display_number_width = self.number_width,
    git_target = "merge-result",
    git_ref = "merge result",
    git_relpath = self.path,
  })
  local remote_source = source_for_pair(self.remote_lines, self.path, source_label(self.path, "remote"), ft, {
    display_number_width = self.number_width,
    empty_reason = self.has_remote and nil or "Deleted file",
    git_state = self.has_remote and "present" or "deleted",
    git_target = self.has_remote and "merge-remote" or "absent",
    git_ref = "remote/incoming",
    git_relpath = self.path,
  })

  local local_result = self:build_pair_session("LocalResult", left_pair, local_source, result_source_left, {
    left = self.local_buf,
    left_num = self.local_num_buf,
    connector = self.local_result_connector_buf,
    right_num = self.result_left_num_buf,
    right = self.result_buf,
  }, {
    left = self.local_win,
    left_num = self.local_num_win,
    connector = self.local_result_connector_win,
    right_num = self.result_left_num_win,
    right = self.result_win,
  }, {
    preserve_right_buffer_lines = true,
    suppress_right_context_highlights = true,
  })

  local result_remote = self:build_pair_session("RemoteResult", right_pair, remote_source, result_source_right, {
    left = self.remote_buf,
    left_num = self.remote_num_buf,
    connector = self.result_remote_connector_buf,
    right_num = self.result_right_num_buf,
    right = self.result_buf,
  }, {
    left = self.remote_win,
    left_num = self.remote_num_win,
    connector = self.result_remote_connector_win,
    right_num = self.result_right_num_win,
    right = self.result_win,
  }, {
    preserve_right_buffer_lines = true,
    suppress_right_context_highlights = true,
    mirror_connector_sides = true,
  })

  self.local_result_session = local_result
  self.result_remote_session = result_remote
  self.connector_width = math.max(local_result.connector_core_width, result_remote.connector_core_width)
  local_result.connector_core_width = self.connector_width
  local_result.gutter_width = self.connector_width
  result_remote.connector_core_width = self.connector_width
  result_remote.gutter_width = self.connector_width
  self:configure_windows()

  result_remote:render()
  local_result:render()
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = self.result_buf })

  self:render_merge_overlays()
  self.rendered_result_tick = result_tick
  self.rendered_view_key = self:render_view_key(result_tick)
  self:render_headers()
  return true
end

function Merge:goto_conflict(index)
  if #self.conflicts == 0 then
    vim.notify("DiffBandit: no merge conflicts in this file", vim.log.levels.INFO)
    return false
  end
  index = math.max(1, math.min(index, #self.conflicts))
  self.current_conflict = index
  local region = self.conflicts[index]
  local row = math.max(1, region.result_start or 1)
  if self.result_win and vim.api.nvim_win_is_valid(self.result_win) then
    vim.api.nvim_set_current_win(self.result_win)
    pcall(vim.api.nvim_win_set_cursor, self.result_win, { row, 0 })
    pcall(vim.api.nvim_win_call, self.result_win, function()
      vim.cmd("normal! zt")
    end)
  end
  self:render()
  return true
end

function Merge:goto_next_conflict()
  if self.current_conflict <= 0 then
    return self:goto_conflict(1)
  end
  return self:goto_conflict(math.min(#self.conflicts, self.current_conflict + 1))
end

function Merge:goto_prev_conflict()
  if self.current_conflict <= 0 then
    return self:goto_conflict(1)
  end
  return self:goto_conflict(math.max(1, self.current_conflict - 1))
end

local function hunk_range_for_side(hunk, side)
  local range = side == "right" and hunk.right or hunk.left
  local start = math.max(1, range.start or 1)
  local count = math.max(0, range.count or 0)
  local finish = count > 0 and (start + count - 1) or start
  return start, finish, count
end

local function hunk_lines(lines, range)
  local result = {}
  local start = range and range.start or 1
  local count = range and range.count or 0
  for index = start, start + count - 1 do
    result[#result + 1] = lines[index] or ""
  end
  return result
end

local function range_text(hunk, side)
  local start, finish, count = hunk_range_for_side(hunk, side)
  if count == 0 then
    return "@" .. tostring(start)
  end
  if start == finish then
    return tostring(start)
  end
  return tostring(start) .. "-" .. tostring(finish)
end

function Merge:pair_context_for_side(side)
  if side == "remote" then
    return {
      side = "remote",
      pair = self.result_remote_pair,
      source_lines = self.remote_lines,
      source_win = self.remote_win,
      source_buf = self.remote_buf,
    }
  end
  return {
    side = "local",
    pair = self.local_result_pair,
    source_lines = self.local_lines,
    source_win = self.local_win,
    source_buf = self.local_buf,
  }
end

function Merge:cursor_row_for_pair(ctx)
  local win = vim.api.nvim_get_current_win()
  if win == self.result_win then
    return vim.api.nvim_win_get_cursor(self.result_win)[1], "right"
  end
  if win == ctx.source_win then
    return vim.api.nvim_win_get_cursor(ctx.source_win)[1], "left"
  end
  if self.last_content_win == self.result_win and self.result_win and vim.api.nvim_win_is_valid(self.result_win) then
    return vim.api.nvim_win_get_cursor(self.result_win)[1], "right"
  end
  if ctx.source_win and vim.api.nvim_win_is_valid(ctx.source_win) then
    return vim.api.nvim_win_get_cursor(ctx.source_win)[1], "left"
  end
  return 1, "left"
end

function Merge:all_pair_hunks()
  local grouped = {}
  local order = {}
  for _, side in ipairs({ "local", "remote" }) do
    local ctx = self:pair_context_for_side(side)
    for index, hunk in ipairs((ctx.pair and ctx.pair.hunks) or {}) do
      local result_start, _, result_count = hunk_range_for_side(hunk, "right")
      local source_start = hunk_range_for_side(hunk, "left")
      local key = tostring(result_start) .. ":" .. tostring(result_count)
      local item = grouped[key]
      if not item then
        item = {
          key = key,
          result_start = result_start,
          result_count = result_count,
          source_start = source_start,
        }
        grouped[key] = item
        order[#order + 1] = item
      else
        item.source_start = math.min(item.source_start or source_start, source_start)
      end
      item[side .. "_index"] = index
      item[side .. "_hunk"] = hunk
    end
  end
  for _, item in ipairs(order) do
    if item.local_hunk and item.remote_hunk then
      item.side = "both"
      item.index = item.local_index
      item.hunk = item.local_hunk
    elseif item.remote_hunk then
      item.side = "remote"
      item.index = item.remote_index
      item.hunk = item.remote_hunk
    else
      item.side = "local"
      item.index = item.local_index
      item.hunk = item.local_hunk
    end
  end
  table.sort(order, function(left, right)
    if left.result_start ~= right.result_start then
      return left.result_start < right.result_start
    end
    if left.source_start ~= right.source_start then
      return left.source_start < right.source_start
    end
    return (left.index or 0) < (right.index or 0)
  end)
  return order
end

function Merge:selected_item()
  local selected = self.selected_pair_hunk
  if not selected then
    return nil
  end
  if selected.key then
    for _, item in ipairs(self:all_pair_hunks()) do
      if item.key == selected.key then
        return item
      end
    end
  end
  return nil
end

function Merge:selection_summary()
  local item = self:selected_item()
  if not item then
    return ""
  end
  local result = "R" .. range_text(item.hunk, "right")
  if item.local_hunk and item.remote_hunk then
    return string.format(">> L%s  << I%s  -> %s", range_text(item.local_hunk, "left"),
      range_text(item.remote_hunk, "left"), result)
  end
  if item.remote_hunk then
    return string.format("<< I%s -> %s", range_text(item.remote_hunk, "left"), result)
  end
  return string.format(">> L%s -> %s", range_text(item.local_hunk, "left"), result)
end

function Merge:hunk_index_at_row(ctx, row, range_side)
  local hunks = (ctx.pair and ctx.pair.hunks) or {}
  for index, hunk in ipairs(hunks) do
    local start, finish = hunk_range_for_side(hunk, range_side)
    if row >= start and row <= finish then
      return index
    end
  end
  return nil
end

function Merge:source_row_for_result_row(side, result_row)
  local ctx = self:pair_context_for_side(side)
  local view = ctx.pair and ctx.pair.view
  result_row = math.max(1, result_row or 1)
  local prior_source
  local next_source
  for _, meta in ipairs((view and view.line_meta) or {}) do
    if meta.left_index then
      if meta.right_index and meta.right_index <= result_row then
        prior_source = meta.left_index
      elseif meta.right_index and meta.right_index > result_row then
        next_source = next_source or meta.left_index
      elseif not meta.right_index and not next_source then
        next_source = meta.left_index
      end
    end
  end
  return prior_source or next_source or result_row
end

function Merge:set_viewports(local_topline, result_topline, remote_topline)
  set_win_view_topline(self.local_win, local_topline)
  set_win_view_topline(self.local_num_win, local_topline)
  set_win_view_topline(self.local_result_connector_win, local_topline)
  set_win_view_topline(self.result_win, result_topline)
  set_win_view_topline(self.result_left_num_win, result_topline)
  set_win_view_topline(self.result_right_num_win, result_topline)
  set_win_view_topline(self.remote_win, remote_topline)
  set_win_view_topline(self.remote_num_win, remote_topline)
  set_win_view_topline(self.result_remote_connector_win, remote_topline)
end

function Merge:rerender_pair_viewports()
  if self.result_remote_session then
    self.result_remote_session:rerender_for_viewport()
  end
  if self.local_result_session then
    self.local_result_session:rerender_for_viewport()
  end
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = self.result_buf })
end

function Merge:align_hunk_item_viewports(item)
  local result_row = math.max(1, item.result_start or hunk_range_for_side(item.hunk, "right"))
  local local_anchor = item.local_hunk and hunk_range_for_side(item.local_hunk, "left")
    or self:source_row_for_result_row("local", result_row)
  local remote_anchor = item.remote_hunk and hunk_range_for_side(item.remote_hunk, "left")
    or self:source_row_for_result_row("remote", result_row)
  local navigation = self.config.navigation or {}
  local context = math.max(0, tonumber(navigation.jump_context) or 0)

  local local_cursor = math.min(math.max(1, local_anchor or 1), math.max(1, vim.api.nvim_buf_line_count(self.local_buf)))
  local result_cursor = math.min(result_row, math.max(1, vim.api.nvim_buf_line_count(self.result_buf)))
  local remote_cursor = math.min(math.max(1, remote_anchor or 1), math.max(1, vim.api.nvim_buf_line_count(self.remote_buf)))
  local local_topline = math.max(1, (local_anchor or 1) - context)
  local result_topline = math.max(1, result_row - context)
  local remote_topline = math.max(1, (remote_anchor or 1) - context)

  self:set_viewports(local_topline, result_topline, remote_topline)
  pcall(vim.api.nvim_win_set_cursor, self.local_win, { local_cursor, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.result_win, { result_cursor, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.remote_win, { remote_cursor, 0 })
  self:rerender_pair_viewports()
end

function Merge:goto_pair_hunk_item(item)
  if not item then
    return false
  end
  self.selected_pair_hunk = {
    key = item.key,
  }
  local target
  if vim.api.nvim_get_current_win() == self.result_win then
    target = self.result_win
  elseif item.remote_hunk and self.last_content_win == self.remote_win then
    target = self.remote_win
  elseif item.local_hunk then
    target = self.local_win
  elseif item.remote_hunk then
    target = self.remote_win
  end
  self:align_hunk_item_viewports(item)
  if target and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_set_current_win, target)
  end
  self:render_headers()
  return true
end

function Merge:goto_document_edge(edge)
  local local_count = math.max(1, vim.api.nvim_buf_line_count(self.local_buf))
  local result_count = math.max(1, vim.api.nvim_buf_line_count(self.result_buf))
  local remote_count = math.max(1, vim.api.nvim_buf_line_count(self.remote_buf))
  local local_height = self.local_win and vim.api.nvim_win_is_valid(self.local_win) and vim.api.nvim_win_get_height(self.local_win) or 1
  local result_height = self.result_win and vim.api.nvim_win_is_valid(self.result_win) and vim.api.nvim_win_get_height(self.result_win) or 1
  local remote_height = self.remote_win and vim.api.nvim_win_is_valid(self.remote_win) and vim.api.nvim_win_get_height(self.remote_win) or 1

  local local_line = edge == "bottom" and local_count or 1
  local result_line = edge == "bottom" and result_count or 1
  local remote_line = edge == "bottom" and remote_count or 1
  local local_topline = edge == "bottom" and math.max(1, local_count - local_height + 1) or 1
  local result_topline = edge == "bottom" and math.max(1, result_count - result_height + 1) or 1
  local remote_topline = edge == "bottom" and math.max(1, remote_count - remote_height + 1) or 1

  self.selected_pair_hunk = {
    boundary = edge == "bottom" and "bottom" or "top",
  }
  self.current_conflict = edge == "bottom" and (#self.conflicts + 1) or 0
  pcall(vim.api.nvim_win_set_cursor, self.local_win, { local_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.result_win, { result_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.remote_win, { remote_line, 0 })
  self:set_viewports(local_topline, result_topline, remote_topline)
  pcall(vim.api.nvim_win_set_cursor, self.local_win, { local_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.result_win, { result_line, 0 })
  pcall(vim.api.nvim_win_set_cursor, self.remote_win, { remote_line, 0 })
  self:rerender_pair_viewports()
  self:render_headers()
end

function Merge:goto_pair_hunk_by_direction(direction)
  local items = self:all_pair_hunks()
  if #items == 0 then
    if #self.conflicts > 0 then
      return direction > 0 and self:goto_next_conflict() or self:goto_prev_conflict()
    end
    vim.notify("DiffBandit: no merge changes in this file", vim.log.levels.INFO)
    return false
  end

  local selected = self.selected_pair_hunk
  local selected_rank
  if selected then
    for rank, item in ipairs(items) do
      if selected.key and item.key == selected.key then
        selected_rank = rank
        break
      end
    end
  end

  local target_rank
  if selected and selected.boundary == "top" then
    target_rank = 1
  elseif selected and selected.boundary == "bottom" then
    target_rank = #items
  elseif selected_rank then
    target_rank = math.max(1, math.min(#items, selected_rank + direction))
  else
    local row = self.result_win and vim.api.nvim_win_is_valid(self.result_win) and vim.api.nvim_win_get_cursor(self.result_win)[1] or 1
    if direction > 0 then
      target_rank = #items
      for rank, item in ipairs(items) do
        if item.result_start >= row then
          target_rank = rank
          break
        end
      end
    else
      target_rank = 1
      for rank = #items, 1, -1 do
        if items[rank].result_start <= row then
          target_rank = rank
          break
        end
      end
    end
  end

  local item = items[target_rank]
  return self:goto_pair_hunk_item(item)
end

function Merge:goto_next_chunk()
  return self:goto_pair_hunk_by_direction(1)
end

function Merge:goto_prev_chunk()
  return self:goto_pair_hunk_by_direction(-1)
end

function Merge:goto_next_hunk()
  return self:goto_next_chunk()
end

function Merge:goto_prev_hunk()
  return self:goto_prev_chunk()
end

function Merge:open_merge_file(index, opts)
  opts = opts or {}
  local queue = self.file_queue
  local entry = queue and queue.entries and queue.entries[index]
  if not entry then
    return false
  end
  if entry.status ~= "U" and entry.kind ~= "unmerged" then
    return self:goto_queue_file(index, "top", opts)
  end
  local data, err = Merge.load(queue.root, entry.path, self.config)
  if not data then
    vim.notify("DiffBandit: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  queue.index = index
  self.file_queue_index = index
  self.root = data.root
  self.path = data.path
  self.base_lines = data.base_lines or {}
  self.local_lines = data.local_lines or {}
  self.remote_lines = data.remote_lines or {}
  self.has_local = data.has_local ~= false
  self.has_remote = data.has_remote ~= false
  self.delete_result = false
  self.result_lines = data.result_lines or vim.deepcopy(self.base_lines)
  self.conflicts = data.conflicts or {}
  self.non_conflicting = data.non_conflicting or {}
  self.local_hunks = data.local_hunks or {}
  self.remote_hunks = data.remote_hunks or {}
  self.current_conflict = #self.conflicts > 0 and 1 or 0
  self.line_ending_warning = data.line_ending_warning
  self.merge_context = git.merge_context(self.root)

  local ft = detect_filetype(self.path)
  vim.api.nvim_set_option_value("modifiable", true, { buf = self.local_buf })
  vim.api.nvim_buf_set_lines(self.local_buf, 0, -1, false, self.local_lines)
  vim.api.nvim_set_option_value("modified", false, { buf = self.local_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = self.local_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = self.result_buf })
  self:set_result_buffer_lines(self.result_lines)
  vim.api.nvim_set_option_value("modified", false, { buf = self.result_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = self.result_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = self.remote_buf })
  vim.api.nvim_buf_set_lines(self.remote_buf, 0, -1, false, self.remote_lines)
  vim.api.nvim_set_option_value("modified", false, { buf = self.remote_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = self.remote_buf })
  for _, buf in ipairs({ self.local_buf, self.result_buf, self.remote_buf }) do
    if ft and ft ~= "" then
      pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
    end
  end
  self:configure_windows()
  self:render()
  if self.panel then
    panel_mod.render(self, index)
  end
  if opts.navigate_change == "prev" then
    self:goto_prev_conflict()
  elseif opts.navigate_change == "next" then
    self:goto_next_conflict()
  end
  if opts.preserve_focus and self.panel and self.panel.nav_win and vim.api.nvim_win_is_valid(self.panel.nav_win) then
    vim.api.nvim_set_current_win(self.panel.nav_win)
  end
  return true
end

function Merge:goto_queue_file(index, chunk_position, opts)
  opts = opts or {}
  local queue = self.file_queue
  local entry = queue and queue.entries and queue.entries[index]
  if not entry then
    return false
  end
  if entry.status == "U" or entry.kind == "unmerged" then
    return self:open_merge_file(index, opts)
  end
  local loaded, err = queue.load(index)
  if not loaded then
    vim.notify("DiffBandit: " .. tostring(err or "unable to load changed file"), vim.log.levels.INFO)
    return false
  end
  queue.index = index
  local Session = require("diffbandit.session")
  local session, start_err = Session.start({ left = loaded.left, right = loaded.right }, self.config, {
    queue = queue,
    chunk_position = chunk_position or "top",
    panel = true,
    panel_initial_selection = index,
    panel_message_lines = self.panel and self.panel.message_lines,
    panel_amend = self.panel and self.panel.amend == true,
  })
  if not session then
    vim.notify("DiffBandit: " .. tostring(start_err or "unable to open changed file"), vim.log.levels.ERROR)
    return false
  end
  state.register(session)
  return true
end

function Merge:refresh_git_queue(preferred_path, refresh_opts)
  refresh_opts = refresh_opts or {}
  return panel_mod.refresh_git_queue(self, {
    preferred_path = preferred_path,
    default_index = refresh_opts.default_index or 1,
    fallback_index = refresh_opts.fallback_index,
    empty_index = 0,
    on_queue = function(session, _, target_index)
      if session.panel then
        panel_mod.render(session, refresh_opts.preserve_panel_selection or target_index, { refresh_stage_states = true })
      end
    end,
  })
end

function Merge:update_region_offsets(start_index, delta)
  if delta == 0 then
    return
  end
  for index = start_index + 1, #self.conflicts do
    self.conflicts[index].result_start = (self.conflicts[index].result_start or 1) + delta
  end
end

function Merge:replace_result_range(start_row, count, replacement)
  local current = logical_buffer_lines(self.result_buf)
  local next_lines = replace_range(current, start_row, count, replacement)
  self:set_result_buffer_lines(next_lines)
  self:render()
  return true
end

function Merge:replace_result_region(region_index, replacement)
  local region = self.conflicts[region_index]
  if not region then
    return false
  end
  local current = logical_buffer_lines(self.result_buf)
  local next_lines = replace_range(current, region.result_start, region.result_count, replacement)
  self:set_result_buffer_lines(next_lines)
  local delta = #(replacement or {}) - (region.result_count or 0)
  region.result_count = #(replacement or {})
  self:update_region_offsets(region_index, delta)
  self:render()
  return true
end

function Merge:update_current_conflict_from_pair_hunk(hunk, replacement)
  if self.current_conflict <= 0 then
    return
  end
  local region = self.conflicts[self.current_conflict]
  if not region then
    return
  end
  local old_count = region.result_count or 0
  if old_count ~= (hunk.right.count or 0) and not (old_count == 0 and (hunk.right.count or 0) == 0) then
    return
  end
  region.result_start = hunk.right.start
  region.result_count = #(replacement or {})
  self:update_region_offsets(self.current_conflict, region.result_count - old_count)
end

function Merge:focused_hunk_for_side(side)
  local selected = self:selected_item()
  if selected and selected[side .. "_hunk"] then
    return self:pair_context_for_side(side), selected[side .. "_hunk"], selected[side .. "_index"]
  end
  local ctx = self:pair_context_for_side(side)
  local row, range_side = self:cursor_row_for_pair(ctx)
  local index = self:hunk_index_at_row(ctx, row, range_side)
  local hunk = index and ctx.pair and ctx.pair.hunks and ctx.pair.hunks[index] or nil
  if not hunk then
    return nil
  end
  return ctx, hunk, index
end

function Merge:accept_pair_hunk(side)
  if side == "both" then
    local selected = self:selected_item()
    if not (selected and selected.local_hunk and selected.remote_hunk) then
      return false
    end
    local replacement = hunk_lines(self.local_lines, selected.local_hunk.left)
    vim.list_extend(replacement, hunk_lines(self.remote_lines, selected.remote_hunk.left))
    self.delete_result = false
    self:update_current_conflict_from_pair_hunk(selected.local_hunk, replacement)
    return self:replace_result_range(selected.result_start, selected.result_count or 0, replacement)
  end

  local ctx, hunk = self:focused_hunk_for_side(side)
  if not (ctx and hunk) then
    return false
  end
  local replacement = hunk_lines(ctx.source_lines, hunk.left)
  self.delete_result = false
  self:update_current_conflict_from_pair_hunk(hunk, replacement)
  return self:replace_result_range(hunk.right.start, hunk.right.count, replacement)
end

function Merge:accept(side)
  if side == "local" and not self.has_local then
    self.delete_result = true
    self:set_result_buffer_lines({})
    self:render()
    return true
  elseif side == "remote" and not self.has_remote then
    self.delete_result = true
    self:set_result_buffer_lines({})
    self:render()
    return true
  end

  if side == "local" or side == "remote" or side == "both" then
    if self:accept_pair_hunk(side) then
      return true
    end
  end

  if self.current_conflict <= 0 then
    vim.notify("DiffBandit: no active conflict", vim.log.levels.INFO)
    return false
  end
  local region = self.conflicts[self.current_conflict]
  local replacement
  if side == "local" then
    self.delete_result = false
    replacement = region.local_replacement or {}
  elseif side == "remote" then
    self.delete_result = false
    replacement = region.remote_replacement or {}
  elseif side == "both" then
    self.delete_result = false
    replacement = vim.deepcopy(region.local_replacement or {})
    vim.list_extend(replacement, region.remote_replacement or {})
  else
    return false
  end
  return self:replace_result_region(self.current_conflict, replacement)
end

function Merge:apply_non_conflicting()
  local lines = logical_buffer_lines(self.result_buf)
  for _, item in ipairs(self.non_conflicting or {}) do
    lines = replace_range(lines, item.base_start, item.base_count, item.replacement)
  end
  self:set_result_buffer_lines(lines)
  vim.notify("DiffBandit: applied non-conflicting changes", vim.log.levels.INFO)
  self:render()
  return true
end

function Merge:resolve()
  if self.delete_result then
    local ok, write_err = git.write_worktree(self.root, self.path, nil, false)
    if not ok then
      vim.notify("DiffBandit: " .. tostring(write_err), vim.log.levels.ERROR)
      return false
    end
    local _, add_err = git.git_output(self.root, { "add", "-A", "--", self.path })
    if add_err then
      vim.notify("DiffBandit: " .. tostring(add_err), vim.log.levels.ERROR)
      return false
    end
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = self.result_buf })
    self:refresh_git_queue(self.path)
    vim.notify("DiffBandit: resolved " .. tostring(self.path), vim.log.levels.INFO)
    return true
  end
  local text = to_text(logical_buffer_lines(self.result_buf))
  local ok, write_err = git.write_worktree(self.root, self.path, text, false)
  if not ok then
    vim.notify("DiffBandit: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end
  local _, add_err = git.git_output(self.root, { "add", "--", self.path })
  if add_err then
    vim.notify("DiffBandit: " .. tostring(add_err), vim.log.levels.ERROR)
    return false
  end
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = self.result_buf })
  self:refresh_git_queue(self.path)
  vim.notify("DiffBandit: resolved " .. tostring(self.path), vim.log.levels.INFO)
  return true
end

function Merge:focus_commit_panel_for_current_file()
  if self.panel
      and self.panel.visible
      and self.panel.nav_win
      and vim.api.nvim_win_is_valid(self.panel.nav_win) then
    panel_mod.render(self, self.file_queue_index)
    panel_mod.focus_nav(self)
    return true
  end
  local init = require("diffbandit")
  return init.commit_panel({ pathspecs = { self.path } })
end

function Merge:close(from_autocmd)
  if self.disposed then
    return
  end
  self.disposed = true
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if self.render_timer then
    self.render_timer:stop()
    self.render_timer:close()
    self.render_timer = nil
  end
  state.unregister(self.tabpage)
  if not from_autocmd and self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, self.tabpage)
    pcall(vim.cmd, "tabclose")
  end
end

return Merge
