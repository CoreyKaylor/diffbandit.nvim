local git = require("diffbandit.git")
local panel_mod = require("diffbandit.panel")
local state = require("diffbandit.state")

local CommitPanel = {}
CommitPanel.__index = CommitPanel

local function set_buffer_options(buf, opts)
  for key, value in pairs(opts) do
    if value ~= nil then
      vim.api.nvim_buf_set_option(buf, key, value)
    end
  end
end

local function set_window_options(win, opts)
  for key, value in pairs(opts) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = win })
  end
end

local function set_window_width(win, width)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_width, win, math.max(1, width))
  end
end

local function set_window_height(win, height)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_height, win, math.max(1, height))
  end
end

local function panel_config(self)
  return (((self.config or {}).git or {}).panel or {})
end

local function capture_message_lines(self)
  local panel = self.panel or {}
  if panel.commit_buf and vim.api.nvim_buf_is_valid(panel.commit_buf) then
    panel.message_lines = vim.api.nvim_buf_get_lines(panel.commit_buf, 2, -1, false)
  end
  return panel.message_lines or { "" }
end

local function clear_amend_opts(opts)
  local clean = vim.tbl_extend("force", {}, opts or {})
  clean.stage_base = nil
  clean.amend_mode = nil
  return clean
end

local function lines_equal(left, right)
  left = left or {}
  right = right or {}
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if line ~= right[index] then
      return false
    end
  end
  return true
end

local function create_buffer(buftype, name)
  local buf = vim.api.nvim_create_buf(false, true)
  if name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  set_buffer_options(buf, {
    buftype = buftype or "nofile",
    swapfile = false,
    modifiable = false,
    bufhidden = "hide",
  })
  return buf
end

function CommitPanel.start(config, queue, opts)
  opts = opts or {}
  local self = setmetatable({}, CommitPanel)
  self.config = config
  self.file_queue = queue
  self.file_queue_index = 0
  self.disposed = false
  self.tabpage = vim.api.nvim_get_current_tabpage()
  self.source_win = vim.api.nvim_get_current_win()
  self.id = state.next_session_id()
  self.ns = vim.api.nvim_create_namespace("DiffBanditCommitPanel" .. tostring(self.id))
  self.start_diff = opts.start_diff
  self.panel = {
    nav_buf = create_buffer("nofile"),
    commit_buf = create_buffer("acwrite", "diffbandit-commit-" .. tostring(self.id)),
    message_lines = { "" },
    amend = false,
    visible = false,
  }

  self:show_commit_panel()
  state.register_panel(self)
  return self
end

function CommitPanel:show_commit_panel()
  if self.disposed then
    return false
  end
  if self.panel.visible
      and self.panel.nav_win and vim.api.nvim_win_is_valid(self.panel.nav_win)
      and self.panel.commit_win and vim.api.nvim_win_is_valid(self.panel.commit_win) then
    panel_mod.focus_nav(self)
    return true
  end

  local config = panel_config(self)
  local anchor = self.source_win
  if not (anchor and vim.api.nvim_win_is_valid(anchor)) then
    anchor = vim.api.nvim_get_current_win()
    self.source_win = anchor
  end

  local nav_win = vim.api.nvim_open_win(self.panel.nav_buf, false, {
    split = "left",
    win = anchor,
    width = config.width or 42,
  })
  local commit_win = vim.api.nvim_open_win(self.panel.commit_buf, false, {
    split = "below",
    win = nav_win,
    height = config.commit_height or 10,
  })
  self.panel.nav_win = nav_win
  self.panel.commit_win = commit_win
  self.panel.visible = true

  local panel_winhl = "VertSplit:DiffBanditSplit,WinSeparator:DiffBanditSplit,"
    .. "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,CursorLine:DiffBanditCursorLine"
  for _, win in ipairs({ nav_win, commit_win }) do
    set_window_options(win, {
      number = false,
      relativenumber = false,
      cursorline = true,
      wrap = false,
      signcolumn = "no",
      foldcolumn = "0",
      winfixwidth = true,
      winhl = panel_winhl,
    })
    set_window_width(win, config.width or 42)
  end
  set_window_height(commit_win, config.commit_height or 10)
  panel_mod.attach(self)
  panel_mod.focus_nav(self)
  return true
end

function CommitPanel:hide_commit_panel()
  panel_mod.close(self)
  return true
end

function CommitPanel:toggle_commit_panel()
  if self.panel
      and self.panel.visible
      and self.panel.nav_win
      and vim.api.nvim_win_is_valid(self.panel.nav_win) then
    return self:hide_commit_panel()
  end
  return self:show_commit_panel()
end

function CommitPanel:close()
  if self.disposed then
    return
  end
  self:hide_commit_panel()
  self.disposed = true
  state.unregister_panel(self.tabpage)
end

function CommitPanel:refresh_git_queue(preferred_path)
  local opts = vim.tbl_extend("force", {}, (self.file_queue or {}).opts or {})
  opts.pathspecs = opts.pathspecs or {}
  local git_config = vim.tbl_extend("force", {}, (self.config or {}).git or {}, {
    hex = ((self.config or {}).ui or {}).hex or {},
  })
  local queue, err = git.queue(opts, git_config)
  if not queue then
    if err ~= "no git changes" then
      vim.notify("DiffBandit: " .. tostring(err), vim.log.levels.INFO)
      return false, err
    end
    self.file_queue.entries = {}
    self.file_queue.index = 0
    self.file_queue_index = 0
    panel_mod.render(self, nil, { no_initial_selection = true, refresh_stage_states = true })
    return true, nil
  end

  local target_index = 0
  if preferred_path then
    for index, entry in ipairs(queue.entries or {}) do
      if entry.path == preferred_path or entry.old_path == preferred_path then
        target_index = index
        break
      end
    end
  end
  queue.index = target_index
  self.file_queue = queue
  self.file_queue_index = target_index
  panel_mod.render(self, target_index > 0 and target_index or nil, {
    no_initial_selection = target_index == 0,
    refresh_stage_states = true,
  })
  return true, nil
end

function CommitPanel:set_amend_mode(enabled)
  if not self.file_queue or not self.file_queue.root then
    return false, "no Git file queue configured"
  end

  capture_message_lines(self)
  local current_entry = self.file_queue.entries and self.file_queue.entries[self.file_queue_index or self.file_queue.index or 1]
  local preferred_path = current_entry and (current_entry.path or current_entry.old_path)

  if enabled then
    local base, err = git.amend_base(self.file_queue.root)
    if not base then
      vim.notify("DiffBandit: " .. tostring(err), vim.log.levels.INFO)
      return false, err
    end
    if not self.normal_queue_opts then
      self.normal_queue_opts = clear_amend_opts((self.file_queue or {}).opts or {})
    end
    local opts = vim.tbl_extend("force", {}, self.normal_queue_opts, {
      mode = "all",
      base = base,
      stage_base = base,
      amend_mode = true,
    })
    self.file_queue.opts = opts
    self.panel.amend = true
    if not self.panel.amend_loaded and vim.trim(table.concat(self.panel.message_lines or {}, "\n")) == "" then
      local message = git.last_commit_message(self.file_queue.root)
      if message then
        local loaded_lines = vim.split(message, "\n", { plain = true })
        self.panel.pre_amend_message_lines = vim.deepcopy(self.panel.message_lines or { "" })
        self.panel.amend_loaded_message_lines = loaded_lines
        self.panel.message_lines = loaded_lines
        self.panel.message_initialized = false
      end
      self.panel.amend_loaded = true
    end
  else
    if self.panel.amend_loaded_message_lines
        and lines_equal(self.panel.message_lines, self.panel.amend_loaded_message_lines) then
      self.panel.message_lines = self.panel.pre_amend_message_lines or { "" }
      self.panel.message_initialized = false
    end
    self.panel.pre_amend_message_lines = nil
    self.panel.amend_loaded_message_lines = nil
    self.file_queue.opts = clear_amend_opts(self.normal_queue_opts or (self.file_queue or {}).opts or {})
    self.normal_queue_opts = nil
    self.panel.amend = false
  end

  return self:refresh_git_queue(preferred_path)
end

function CommitPanel:clear_amend_mode()
  if self.file_queue and self.normal_queue_opts then
    self.file_queue.opts = clear_amend_opts(self.normal_queue_opts)
  elseif self.file_queue then
    self.file_queue.opts = clear_amend_opts(self.file_queue.opts or {})
  end
  self.normal_queue_opts = nil
  if self.panel then
    self.panel.amend = false
    self.panel.amend_loaded = false
    self.panel.pre_amend_message_lines = nil
    self.panel.amend_loaded_message_lines = nil
  end
end

function CommitPanel:goto_queue_file(index, opts)
  opts = opts or {}
  local queue = self.file_queue
  if not queue or type(queue.load) ~= "function" then
    return false
  end
  local loaded, err = queue.load(index)
  if not loaded then
    vim.notify("DiffBandit: " .. tostring(err or "unable to load changed file"), vim.log.levels.INFO)
    return false
  end

  queue.index = index
  self.file_queue_index = index
  local message_lines = capture_message_lines(self)
  local amend = self.panel.amend == true
  queue.normal_opts = self.normal_queue_opts
  self:close()

  if type(self.start_diff) ~= "function" then
    return false
  end
  local session, start_err = self.start_diff(loaded.left, loaded.right, {
    queue = queue,
    chunk_position = "top",
    panel = true,
    panel_initial_selection = index,
    panel_message_lines = message_lines,
    panel_amend = amend,
    panel_normal_queue_opts = self.normal_queue_opts,
  })
  if not session then
    vim.notify("DiffBandit: " .. tostring(start_err), vim.log.levels.ERROR)
    return false
  end
  if opts.navigate_change == "prev" then
    session:goto_prev_chunk()
    panel_mod.focus_nav(session)
  elseif opts.navigate_change == "next" then
    session:goto_next_chunk()
    panel_mod.focus_nav(session)
  end
  return true
end

return CommitPanel
