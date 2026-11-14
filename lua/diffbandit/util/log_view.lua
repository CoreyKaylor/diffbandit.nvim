-- Git log browser: a bottom split listing commits, with a detail pane beside
-- it for the commit under the cursor. Extracted from git_workflows.lua,
-- which keeps only workflow orchestration.
--
-- Row N + 1 of the list is commits[N] (row 1 is the header); the log walk
-- (diffbandit.git_log_step) relies on that to keep the cursor in sync.
local git = require("diffbandit.vcs")
local nvim = require("diffbandit.util.nvim")
local ui = require("diffbandit.util.ui")
local keyhelp = require("diffbandit.util.keyhelp")
local config_mod = require("diffbandit.config")
local state = require("diffbandit.state")

local M = {}

local WINHL = "Normal:DiffBanditStatus,NormalNC:DiffBanditStatus,CursorLine:DiffBanditCursorLine"
local DETAILS_DEBOUNCE_MS = 40

local function log_config(config)
  return (config_mod.section(config, "git") or {}).log or {}
end

-- Compact age of a unix timestamp: "now", "47m", "3h", "4d", "2w", "5mo", "2y".
function M.age(time, now)
  if not time then
    return ""
  end
  local seconds = math.max(0, (now or os.time()) - time)
  if seconds < 60 then
    return "now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  elseif seconds < 14 * 86400 then
    return math.floor(seconds / 86400) .. "d"
  elseif seconds < 60 * 86400 then
    return math.floor(seconds / (7 * 86400)) .. "w"
  elseif seconds < 365 * 86400 then
    return math.floor(seconds / (30 * 86400)) .. "mo"
  end
  return math.floor(seconds / (365 * 86400)) .. "y"
end

local function ref_highlight(ref)
  if ref == "HEAD" or ref:match("^HEAD %-> ") then
    return "DiffBanditLogHead"
  elseif ref:match("^tag: ") then
    return "DiffBanditLogTag"
  end
  return "DiffBanditLogRef"
end

local function display_ref(ref)
  return (ref:gsub("^HEAD %-> ", "HEAD → "))
end

-- A line assembled from highlighted pieces; tracks byte columns as it goes.
local function line_builder()
  local self = { parts = {}, marks = {}, col = 0 }
  function self.add(text, hl)
    if text == nil or text == "" then
      return
    end
    if hl then
      self.marks[#self.marks + 1] = { self.col, self.col + #text, hl }
    end
    self.parts[#self.parts + 1] = text
    self.col = self.col + #text
  end
  function self.text()
    return table.concat(self.parts)
  end
  return self
end

local function pad_right(text, width)
  return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

local function pad_left(text, width)
  return string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text))) .. text
end

-- Column widths shared by every row, so the list reads as a table.
local function measure(browser, width)
  local widths = { hash = 0, age = 0, added = 0, removed = 0 }
  local now = os.time()
  for _, commit in ipairs(browser.commits) do
    widths.hash = math.max(widths.hash, #(commit.short_hash or ""))
    widths.age = math.max(widths.age, #M.age(commit.time, now))
    local stat = browser.stats and browser.stats[commit.hash]
    if stat and stat.files > 0 then
      widths.added = math.max(widths.added, #tostring(stat.added) + 1)
      widths.removed = math.max(widths.removed, #tostring(stat.removed) + 1)
    end
  end
  widths.author = math.min(18, math.max(8, math.floor(width / 6)))
  widths.now = now
  return widths
end

local function build_row(browser, commit, widths, width)
  local line = line_builder()
  line.add(pad_right(commit.short_hash or "", widths.hash), "DiffBanditLogHash")
  line.add("  ")
  line.add(pad_left(M.age(commit.time, widths.now), widths.age), "DiffBanditMutedText")
  line.add("  ")
  line.add(pad_right(ui.truncate_dotted(commit.author or "", widths.author), widths.author), "DiffBanditMutedText")
  line.add("  ")
  if widths.added > 0 then
    local stat = browser.stats[commit.hash]
    if stat and stat.files > 0 then
      line.add(pad_left("+" .. stat.added, widths.added), "DiffBanditLogAdded")
      line.add(" ")
      line.add(pad_right("-" .. stat.removed, widths.removed), "DiffBanditLogRemoved")
    else
      line.add(string.rep(" ", widths.added + 1 + widths.removed))
    end
    line.add("  ")
  end

  local remaining = math.max(10, width - vim.fn.strdisplaywidth(line.text()))
  local refs = commit.refs or {}
  if #refs > 0 then
    -- Refs never take more than ~40% of what is left, so the subject shows.
    local budget = math.max(12, math.floor(remaining * 0.4))
    local used = 1
    line.add("(", "DiffBanditMutedText")
    for index, ref in ipairs(refs) do
      local text = display_ref(ref)
      local sep = index < #refs and ", " or ""
      local room = budget - used - 1
      if vim.fn.strdisplaywidth(text .. sep) > room then
        line.add(ui.truncate_display(text, math.max(1, room)), ref_highlight(ref))
        used = budget - 1
        break
      end
      line.add(text, ref_highlight(ref))
      line.add(sep, "DiffBanditMutedText")
      used = used + vim.fn.strdisplaywidth(text .. sep)
    end
    line.add(") ", "DiffBanditMutedText")
    remaining = math.max(10, remaining - used - 2)
  end
  line.add(ui.truncate_dotted(commit.subject or "", remaining))
  return line
end

local function list_width(browser)
  if browser.win and vim.api.nvim_win_is_valid(browser.win) then
    return math.max(40, vim.api.nvim_win_get_width(browser.win))
  end
  return 80
end

local function render_log(browser)
  local width = list_width(browser)
  local widths = measure(browser, width)
  local header = string.format("Git Log (%d)", #browser.commits)
  if browser.stats_loading then
    header = header .. " · counting changes…"
  end
  local lines = { header }
  local marks = { { 0, 0, #header, "DiffBanditStatusAccent" } }
  for index, commit in ipairs(browser.commits) do
    local line = build_row(browser, commit, widths, width)
    lines[#lines + 1] = line.text()
    for _, mark in ipairs(line.marks) do
      marks[#marks + 1] = { index, mark[1], mark[2], mark[3] }
    end
  end
  if #browser.commits == 0 then
    lines[#lines + 1] = "No commits"
  end
  nvim.set_buffer_options(browser.buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(browser.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(browser.buf, browser.ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(browser.buf, browser.ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  keyhelp.place_hint(browser.buf, browser.ns, 0,
    keyhelp.hint(config_mod.section(browser.config, "navigation").help_key))
  nvim.set_buffer_options(browser.buf, { modifiable = false })
end

-- Counting every commit's changes is a second, slower walk, so the list
-- shows first and the counts fill in when git finishes.
local function load_stats(browser)
  browser.stats_seq = (browser.stats_seq or 0) + 1
  local seq = browser.stats_seq
  browser.stats_loading = #browser.commits > 0
  if not browser.stats_loading then
    return
  end
  git.log_stats_async(browser.root, browser.opts, function(stats)
    if seq ~= browser.stats_seq or not vim.api.nvim_buf_is_valid(browser.buf) then
      return
    end
    browser.stats_loading = false
    -- A failed count leaves the list as it was rather than erroring.
    browser.stats = stats or browser.stats or {}
    render_log(browser)
  end)
end

local function commit_at_cursor(browser)
  if not browser:is_open() then
    return nil, nil
  end
  local index = vim.api.nvim_win_get_cursor(browser.win)[1] - 1
  return browser.commits[index], index
end

-- Detail pane ---------------------------------------------------------------

local function details_open(browser)
  return browser.details_win ~= nil and vim.api.nvim_win_is_valid(browser.details_win)
    and vim.api.nvim_win_get_buf(browser.details_win) == browser.details_buf
end

local function status_highlight(status)
  if status == "A" then
    return "DiffBanditLogAdded"
  elseif status == "D" then
    return "DiffBanditLogRemoved"
  end
  return "DiffBanditLogChanged"
end

local function person(name, email)
  if email and email ~= "" then
    return string.format("%s <%s>", name or "", email)
  end
  return name or ""
end

-- Lines, highlights and the row -> { path, old_path } map for one commit's
-- details (the shape git_commit's preferred_path takes).
function M.details_lines(commit, details)
  local lines, marks, file_rows = {}, {}, {}
  local function push(line)
    lines[#lines + 1] = line.text()
    for _, mark in ipairs(line.marks) do
      marks[#marks + 1] = { #lines - 1, mark[1], mark[2], mark[3] }
    end
  end

  local head = line_builder()
  head.add(details.hash or commit.hash or "", "DiffBanditLogHash")
  push(head)
  if #(details.refs or {}) > 0 then
    local refs = line_builder()
    for index, ref in ipairs(details.refs) do
      refs.add(display_ref(ref), ref_highlight(ref))
      if index < #details.refs then
        refs.add(", ", "DiffBanditMutedText")
      end
    end
    push(refs)
  end

  local function field(label, value)
    local line = line_builder()
    line.add(pad_right(label, 8), "DiffBanditMutedText")
    line.add(value)
    push(line)
  end
  field("Author", person(details.author, details.author_email))
  field("Date", details.author_date or "")
  -- Rebases and cherry-picks keep the author but change the committer.
  local other = {}
  if details.committer ~= details.author or details.committer_email ~= details.author_email then
    other[#other + 1] = person(details.committer, details.committer_email)
  end
  if details.committer_date and details.committer_date ~= details.author_date then
    other[#other + 1] = details.committer_date
  end
  if #other > 0 then
    field("Commit", table.concat(other, "  "))
  end
  local parents = details.parents or {}
  if #parents > 1 then
    local short = {}
    for _, parent in ipairs(parents) do
      short[#short + 1] = parent:sub(1, 8)
    end
    field("Merge", table.concat(short, " ") .. " (files vs first parent)")
  end

  lines[#lines + 1] = ""
  for index, text in ipairs(details.message or {}) do
    local line = line_builder()
    line.add(text, index == 1 and "DiffBanditAccentText" or nil)
    push(line)
  end
  lines[#lines + 1] = ""

  local files = details.files or {}
  local added, removed = 0, 0
  for _, file in ipairs(files) do
    added = added + (file.added or 0)
    removed = removed + (file.removed or 0)
  end
  local summary = line_builder()
  summary.add(string.format("%d %s changed", #files, #files == 1 and "file" or "files"), "DiffBanditStatusAccent")
  if #files > 0 then
    summary.add("  ")
    summary.add("+" .. added, "DiffBanditLogAdded")
    summary.add(" ")
    summary.add("-" .. removed, "DiffBanditLogRemoved")
  end
  push(summary)

  local added_width, removed_width = 0, 0
  for _, file in ipairs(files) do
    if not file.binary then
      added_width = math.max(added_width, #tostring(file.added or 0) + 1)
      removed_width = math.max(removed_width, #tostring(file.removed or 0) + 1)
    end
  end
  for _, file in ipairs(files) do
    local line = line_builder()
    line.add(file.status or "?", status_highlight(file.status))
    line.add("  ")
    if file.binary then
      line.add(pad_right("bin", added_width + 1 + removed_width), "DiffBanditMutedText")
    else
      line.add(pad_left("+" .. (file.added or 0), added_width), "DiffBanditLogAdded")
      line.add(" ")
      line.add(pad_right("-" .. (file.removed or 0), removed_width), "DiffBanditLogRemoved")
    end
    line.add("  ")
    if file.old_path then
      line.add(file.old_path .. " → ", "DiffBanditMutedText")
    end
    line.add(file.path or "")
    push(line)
    file_rows[#lines] = { path = file.path, old_path = file.old_path }
  end
  return lines, marks, file_rows
end

local function set_details_content(browser, lines, marks, file_rows)
  local buf = browser.details_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  browser.details_file_rows = file_rows or {}
  nvim.set_buffer_options(buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, browser.ns, 0, -1)
  for _, mark in ipairs(marks or {}) do
    vim.api.nvim_buf_set_extmark(buf, browser.ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  nvim.set_buffer_options(buf, { modifiable = false })
  if details_open(browser) then
    pcall(vim.api.nvim_win_set_cursor, browser.details_win, { 1, 0 })
  end
end

local function show_details(browser)
  if not details_open(browser) then
    return
  end
  local commit = commit_at_cursor(browser)
  if not commit then
    browser.details_hash = nil
    set_details_content(browser, { "No commit" }, {}, {})
    return
  end
  if browser.details_hash == commit.hash then
    return
  end
  browser.details_hash = commit.hash
  local cached = browser.details_cache[commit.hash]
  if cached then
    set_details_content(browser, M.details_lines(commit, cached))
    return
  end
  git.commit_details_async(browser.root, commit.hash, browser.opts.pathspecs, function(details, err)
    if not vim.api.nvim_buf_is_valid(browser.buf) then
      return
    end
    if not details then
      if browser.details_hash == commit.hash then
        set_details_content(browser, { "Cannot read commit: " .. tostring(err) }, {}, {})
      end
      return
    end
    browser.details_cache[commit.hash] = details
    if browser.details_hash == commit.hash then
      set_details_content(browser, M.details_lines(commit, details))
    end
  end)
end

local function schedule_details(browser)
  if details_open(browser) then
    ui.reschedule_once(browser, "details_pending", function()
      show_details(browser)
    end, DETAILS_DEBOUNCE_MS)
  end
end

local function close_details(browser)
  if details_open(browser) then
    pcall(vim.api.nvim_win_close, browser.details_win, true)
  end
  browser.details_win = nil
  browser.details_hash = nil
end

local function open_details(browser)
  if details_open(browser) or not browser:is_open() then
    return
  end
  if not browser.details_buf or not vim.api.nvim_buf_is_valid(browser.details_buf) then
    browser.details_buf = nvim.make_buffer("diffbandit-git-log-details", nil, { modifiable = false })
    browser.map_details(browser.details_buf)
  end
  local total = vim.api.nvim_win_get_width(browser.win)
  local fraction = tonumber(log_config(browser.config).details_width) or 0.4
  local width = math.max(30, math.floor(total * fraction))
  browser.details_win = vim.api.nvim_open_win(browser.details_buf, false, {
    split = "right",
    win = browser.win,
    width = width,
  })
  nvim.set_window_options(browser.details_win, {
    number = false,
    relativenumber = false,
    cursorline = false,
    wrap = true,
    linebreak = true,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
    winhl = WINHL,
  })
  browser.details_hash = nil
  show_details(browser)
end

local function toggle_details(browser)
  if details_open(browser) then
    close_details(browser)
  else
    open_details(browser)
  end
  render_log(browser)
end

-- Opening -------------------------------------------------------------------

function M.open(config, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local root, root_err = git.root(opts)
  if not root then
    return nil, root_err
  end
  local commits, err = git.log(root, opts)
  if not commits then
    return nil, err
  end

  local log_opts = log_config(config)
  local keys = log_opts.keys or {}
  local browser = {
    root = root,
    opts = opts,
    config = config,
    commits = commits,
    stats = {},
    details_cache = {},
    callbacks = callbacks,
    ns = vim.api.nvim_create_namespace("DiffBanditGitLog"),
  }
  browser.buf = nvim.make_buffer("diffbandit-git-log", nil, { modifiable = false })
  if opts.fill then
    -- The launcher's log takes the whole (empty) startup window.
    browser.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(browser.win, browser.buf)
  else
    browser.win = vim.api.nvim_open_win(browser.buf, true, {
      split = "below",
      height = opts.height or 15,
    })
  end
  function browser.is_open(self)
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_buf(self.win) == self.buf
  end
  function browser.tabpage(self)
    return self:is_open() and vim.api.nvim_win_get_tabpage(self.win) or nil
  end
  state.register_view(browser)
  local group = vim.api.nvim_create_augroup("DiffBanditGitLog" .. browser.buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufHidden" }, {
    group = group,
    buffer = browser.buf,
    once = true,
    callback = function()
      state.unregister_view(browser)
      browser.disposed = true
      close_details(browser)
      if browser.details_buf and vim.api.nvim_buf_is_valid(browser.details_buf) then
        pcall(vim.api.nvim_buf_delete, browser.details_buf, { force = true })
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- BufEnter: a review walked with ]r moves this cursor from another tab.
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    buffer = browser.buf,
    callback = function()
      schedule_details(browser)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if browser:is_open() and vim.tbl_contains(vim.v.event.windows or {}, browser.win) then
        render_log(browser)
      end
    end,
  })
  nvim.set_window_options(browser.win, {
    number = false,
    relativenumber = false,
    cursorline = true,
    wrap = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixheight = true,
    winhl = WINHL,
  })

  local base_opts = { nowait = true, noremap = true, silent = true }
  local function map_opts(buf, section, desc)
    return keyhelp.opts(buf, section, desc, vim.tbl_extend("force", base_opts, { buffer = buf }))
  end
  local help_key = config_mod.section(config, "navigation").help_key

  local function close_log()
    if require("diffbandit.launcher").should_quit_on_close(browser:tabpage()) then
      pcall(vim.cmd, "confirm qall")
      return
    end
    state.unregister_view(browser)
    close_details(browser)
    if browser.win and vim.api.nvim_win_is_valid(browser.win) then
      if not pcall(vim.api.nvim_win_close, browser.win, true) then
        -- The last window of the last tab cannot close; leave an empty one.
        pcall(vim.api.nvim_win_set_buf, browser.win, vim.api.nvim_create_buf(true, true))
      end
    end
  end

  local function open_commit(index, preferred_path)
    local commit = browser.commits[index]
    if commit and callbacks.open_commit then
      callbacks.open_commit(commit.hash, {
        root = root,
        browser = browser,
        log_index = index,
        preferred_path = preferred_path,
      })
    end
  end

  local function refresh()
    local next_commits, refresh_err = git.log(root, opts)
    if not next_commits then
      nvim.notify_error(tostring(refresh_err))
      return
    end
    browser.commits = next_commits
    browser.details_cache = {}
    browser.details_hash = nil
    load_stats(browser)
    render_log(browser)
    show_details(browser)
  end

  -- Keys shared by the list and the detail pane.
  local function map_common(buf, title)
    if help_key then
      vim.keymap.set("n", help_key, function()
        keyhelp.open(buf, { title = title, help_key = help_key })
      end, map_opts(buf, "General", "Show this key help"))
    end
    vim.keymap.set("n", "q", close_log, map_opts(buf, "General", "Close the log"))
    if keys.toggle_details then
      vim.keymap.set("n", keys.toggle_details, function()
        toggle_details(browser)
      end, map_opts(buf, "Log", "Toggle the commit detail pane"))
    end
    if keys.refresh then
      vim.keymap.set("n", keys.refresh, refresh, map_opts(buf, "Log", "Refresh the log"))
    end
  end

  map_common(browser.buf, "Git log")
  vim.keymap.set("n", "<CR>", function()
    local _, index = commit_at_cursor(browser)
    if index then
      open_commit(index)
    end
  end, map_opts(browser.buf, "Log", "Review the commit under the cursor"))

  function browser.map_details(buf)
    map_common(buf, "Git log details")
    vim.keymap.set("n", "<CR>", function()
      -- The commit the pane shows, which can trail the list cursor while
      -- the pane's debounce is pending.
      for index, commit in ipairs(browser.commits) do
        if commit.hash == browser.details_hash then
          local row = vim.api.nvim_win_get_cursor(0)[1]
          open_commit(index, (browser.details_file_rows or {})[row])
          return
        end
      end
    end, map_opts(buf, "Log", "Review the commit, opening the file under the cursor"))
  end

  render_log(browser)
  if #commits > 0 then
    pcall(vim.api.nvim_win_set_cursor, browser.win, { 2, 0 })
  end
  load_stats(browser)
  local show = log_opts.details
  if show and list_width(browser) >= (tonumber(log_opts.details_min_columns) or 0) then
    open_details(browser)
    render_log(browser)
  end
  return browser, nil
end

return M
