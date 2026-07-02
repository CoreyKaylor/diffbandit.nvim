local git = require("diffbandit.git")
local nvim = require("diffbandit.nvim")
local ui = require("diffbandit.ui")
local config_mod = require("diffbandit.config")
local layout = require("diffbandit.layout")

local M = {}

local plain_icons = {
  modified = "M",
  added = "A",
  deleted = "D",
  renamed = "R",
  copied = "C",
  untracked = "?",
  unmerged = "U",
  staged = "S",
  partial = "P",
}

local nerd_icons = {
  modified = "󰏫",
  added = "󰐕",
  deleted = "󰍵",
  renamed = "󰑕",
  copied = "󰆏",
  untracked = "󰋗",
  unmerged = "",
  staged = "󰄬",
  partial = "󰡖",
}

local function panel_config(session)
  return config_mod.section((session or {}).config, "git", "panel")
end

local function icons_for(session)
  local config = panel_config(session)
  local mode = config.icons or "auto"
  local use_nerd = mode == "nerd"
    or (mode == "auto" and (vim.g.diffbandit_have_nerd_font == true or vim.g.have_nerd_font == true))
  return use_nerd and nerd_icons or plain_icons
end

local function stage_symbol(session, state)
  local indicator = panel_config(session).staged_indicator or {}
  return indicator[state] or indicator.unstaged or "□"
end

local function is_review_panel(session)
  return ((session or {}).panel or {}).mode == "review"
    or (((session or {}).file_queue or {}).opts or {}).read_only == true
end

local function next_stage_state(state)
  if state == "staged" or state == "partial" then
    return "unstaged"
  end
  return "staged"
end

local function filename(path)
  return vim.fn.fnamemodify(path or "", ":t")
end

local function dirname(path)
  local dir = vim.fn.fnamemodify(path or "", ":h")
  if dir == "." then
    return ""
  end
  return dir
end

local function entry_kind(entry)
  if entry.kind and entry.kind ~= "" then
    return entry.kind
  end
  if entry.untracked then
    return "untracked"
  end
  local status = entry.status
  if status == "A" then
    return "added"
  elseif status == "D" then
    return "deleted"
  elseif status == "R" then
    return "renamed"
  elseif status == "C" then
    return "copied"
  elseif status == "U" then
    return "unmerged"
  end
  return "modified"
end

local function status_icon(session, entry)
  return icons_for(session)[entry_kind(entry)] or "M"
end

local function row_for_entry(session, entry, index, width)
  local state = (session.panel and session.panel.stage_states or {})[index] or "unstaged"
  local name = filename(entry.path)
  local parent = dirname(entry.path)
  local prefix
  if entry_kind(entry) == "unmerged" then
    prefix = string.format("  ! %s ", status_icon(session, entry))
  elseif is_review_panel(session) then
    prefix = string.format("  %s ", status_icon(session, entry))
  else
    prefix = string.format("  %s %s ", stage_symbol(session, state), status_icon(session, entry))
  end
  local base = prefix .. name
  local parent_width = math.max(0, width - vim.fn.strdisplaywidth(base) - 1)
  local text
  if parent ~= "" and parent_width > 3 then
    text = base .. " " .. ui.truncate_dotted(parent, parent_width)
  else
    text = ui.truncate_dotted(base, width)
  end
  return {
    text = text,
    name_col = #prefix,
    name_end_col = math.min(#text, #prefix + #name),
  }
end

local function row_group(entry)
  if entry_kind(entry) == "unmerged" then
    return "Merge Conflicts"
  end
  if entry.untracked then
    return "Unversioned Files"
  end
  return "Changes"
end

function M.build_rows(session)
  local queue = session.file_queue or {}
  local entries = queue.entries or {}
  local rows = {}
  local width = math.max(20, tonumber(panel_config(session).width) or 42)
  local groups = {
    { name = "Merge Conflicts", entries = {} },
    { name = "Changes", entries = {} },
    { name = "Unversioned Files", entries = {} },
  }
  for index, entry in ipairs(entries) do
    local group_name = row_group(entry)
    local target
    if group_name == "Merge Conflicts" then
      target = groups[1]
    elseif group_name == "Unversioned Files" then
      target = groups[3]
    else
      target = groups[2]
    end
    target.entries[#target.entries + 1] = { entry = entry, index = index }
  end

  for _, group in ipairs(groups) do
    if #group.entries > 0 then
      rows[#rows + 1] = {
        type = "section",
        text = string.format("▾ %s  %d files", group.name, #group.entries),
        name_col = 0,
      }
      for _, item in ipairs(group.entries) do
        local row = row_for_entry(session, item.entry, item.index, width)
        rows[#rows + 1] = {
          type = "file",
          entry = item.entry,
          index = item.index,
          text = row.text,
          name_col = row.name_col,
          name_end_col = row.name_end_col,
        }
      end
    end
  end

  if #rows == 0 then
    rows[#rows + 1] = { type = "empty", text = "No Git changes" }
  end
  return rows
end

local function selected_row(session)
  local panel = session.panel
  if not panel or not panel.nav_win or not vim.api.nvim_win_is_valid(panel.nav_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(panel.nav_win)[1]
  return (panel.rows or {})[row], row
end

local function first_file_row(rows)
  for index, row in ipairs(rows or {}) do
    if row.type == "file" then
      return index
    end
  end
  return 1
end

local function clamp_file_index(entries, index)
  local count = #(entries or {})
  if count == 0 then
    return 0
  end
  return math.max(1, math.min(index or 1, count))
end

local function find_file_row(rows, entry_index)
  for row_index, row in ipairs(rows or {}) do
    if row.type == "file" and row.index == entry_index then
      return row_index
    end
  end
  return nil
end

local function first_non_file_row(rows)
  if rows and rows[1] and rows[1].type ~= "file" then
    return 1
  end
  return first_file_row(rows)
end

local function set_nav_cursor(session, row)
  local panel = session.panel
  if not panel or not panel.nav_win or not vim.api.nvim_win_is_valid(panel.nav_win) then
    return
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(panel.nav_buf))
  row = math.max(1, math.min(row or 1, line_count))
  local model = panel.rows and panel.rows[row]
  pcall(vim.api.nvim_win_set_cursor, panel.nav_win, { row, model and model.name_col or 0 })
end

local function row_highlight(entry)
  local kind = entry_kind(entry or {})
  if kind == "unmerged" then
    return "DiffBanditDelete"
  end
  if kind == "added" or kind == "untracked" then
    return "DiffBanditAdd"
  elseif kind == "deleted" then
    return "DiffBanditDelete"
  end
  return "DiffBanditChangeLeft"
end

local function apply_nav_highlights(session)
  local panel = session.panel
  if not panel or not panel.nav_buf or not vim.api.nvim_buf_is_valid(panel.nav_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(panel.nav_buf, session.ns, 0, -1)
  for line, row in ipairs(panel.rows or {}) do
    if row.type == "section" then
      vim.api.nvim_buf_add_highlight(panel.nav_buf, session.ns, "DiffBanditStatusAccent", line - 1, 0, -1)
    elseif row.type == "file" then
      local start_col = row.name_col or 0
      local end_col = row.name_end_col or -1
      vim.api.nvim_buf_add_highlight(panel.nav_buf, session.ns, row_highlight(row.entry), line - 1, start_col, end_col)
    end
  end
end

local function commit_message_lines_from_buffer(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return vim.api.nvim_buf_get_lines(buf, 2, -1, false)
  end
  return { "" }
end

function M.capture_message_lines(session)
  local panel = session.panel or {}
  if panel.commit_buf and vim.api.nvim_buf_is_valid(panel.commit_buf) then
    panel.message_lines = commit_message_lines_from_buffer(panel.commit_buf)
  end
  return panel.message_lines or { "" }
end

function M.clear_amend_opts(opts)
  local clean = vim.tbl_extend("force", {}, opts or {})
  clean.stage_base = nil
  clean.amend_mode = nil
  return clean
end

function M.lines_equal(left, right)
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

function M.refresh_stage_states(session)
  local panel = session.panel
  if not panel then
    return {}
  end
  if is_review_panel(session) then
    panel.stage_states = {}
    return panel.stage_states
  end
  local queue = session.file_queue or {}
  panel.stage_states = git.file_stage_states(queue.root, queue.entries, queue.opts or {})
  return panel.stage_states
end

function M.refresh_git_queue(session, opts)
  opts = opts or {}
  local queue = session.file_queue
  if not queue or queue.kind ~= "git" then
    return false, "no Git file queue configured"
  end

  if opts.capture_message ~= false then
    M.capture_message_lines(session)
  end

  local current_entry = queue.entries and queue.entries[session.file_queue_index or queue.index or 1]
  local preferred_path = opts.preferred_path or (current_entry and (current_entry.path or current_entry.old_path))
  local queue_opts = vim.tbl_extend("force", {}, queue.opts or {})
  queue_opts.pathspecs = queue_opts.pathspecs or {}
  local git_config = vim.tbl_extend("force", {}, (session.config or {}).git or {}, {
    hex = config_mod.section(session.config, "ui", "hex"),
  })
  local next_queue, err = git.queue(queue_opts, git_config)
  if not next_queue then
    if err ~= "no git changes" then
      nvim.notify_info(tostring(err))
      return false, err
    end
    queue.entries = {}
    queue.index = opts.empty_index or 0
    session.file_queue = queue
    session.file_queue_index = queue.index
    if opts.on_no_changes then
      opts.on_no_changes(session, queue)
    elseif session.panel and opts.render_panel ~= false then
      M.render(session, nil, { no_initial_selection = true, refresh_stage_states = true })
    end
    return true, nil
  end

  local target_index = opts.default_index
  if target_index == nil then
    target_index = next_queue.index or 1
  end
  local found_preferred = false
  if preferred_path then
    for index, entry in ipairs(next_queue.entries or {}) do
      if entry.path == preferred_path or entry.old_path == preferred_path then
        target_index = index
        found_preferred = true
        break
      end
    end
  end
  if preferred_path and not found_preferred and opts.fallback_index then
    target_index = clamp_file_index(next_queue.entries, opts.fallback_index)
  end
  next_queue.index = target_index
  session.file_queue = next_queue
  session.file_queue_index = target_index
  if opts.on_queue then
    opts.on_queue(session, next_queue, target_index)
  elseif session.panel and opts.render_panel ~= false then
    M.render(session, target_index > 0 and target_index or nil, {
      no_initial_selection = target_index == 0,
      refresh_stage_states = true,
    })
  end
  return true, nil
end

local function escape_gitignore_path(path)
  path = tostring(path or ""):gsub("\\", "/")
  path = path:gsub("([%*%?%[%]])", "\\%1")
  if path:sub(1, 1) == "#" or path:sub(1, 1) == "!" then
    path = "\\" .. path
  end
  return path
end

local function ignore_patterns_for(entry)
  local path = entry and entry.path or ""
  if path == "" then
    return {}
  end
  local patterns = {
    { kind = "ignore", pattern = "/" .. escape_gitignore_path(path), label = "Ignore exact path" },
  }
  local name = filename(path)
  local extension = name:match("^.+(%.[^%.%/]+)$")
  if extension and extension ~= "" then
    patterns[#patterns + 1] = {
      kind = "ignore",
      pattern = "*" .. escape_gitignore_path(extension),
      label = "Ignore *" .. extension,
    }
  end
  local parent = dirname(path)
  if parent ~= "" then
    patterns[#patterns + 1] = {
      kind = "ignore",
      pattern = "/" .. escape_gitignore_path(parent) .. "/",
      label = "Ignore " .. parent .. "/",
    }
  end
  return patterns
end

local function file_actions_for_entry(session, entry, state)
  if is_review_panel(session) then
    return {}
  end
  if not entry or not entry.path then
    return {}
  end
  local actions = {}
  local kind = entry_kind(entry)
  local can_stage = kind ~= "unmerged"
  if can_stage then
    if state == "staged" or state == "partial" then
      actions[#actions + 1] = { id = "unstage", label = "Unstage file", action = "unstage" }
    else
      actions[#actions + 1] = { id = "stage", label = "Stage file", action = "stage" }
    end
  end
  if entry.untracked then
    actions[#actions + 1] = {
      id = "delete_untracked",
      label = "Delete untracked file",
      action = "delete_untracked",
      confirm = "Delete untracked file " .. tostring(entry.path) .. "?",
    }
    for _, pattern in ipairs(ignore_patterns_for(entry)) do
      actions[#actions + 1] = {
        id = "ignore:" .. pattern.pattern,
        label = pattern.label,
        action = "ignore",
        pattern = pattern.pattern,
      }
    end
    return actions
  end
  if (state == "unstaged" or state == "partial")
      and kind ~= "unmerged"
      and kind ~= "renamed"
      and kind ~= "copied"
      and kind ~= "typechange"
      and entry.actions_enabled ~= false then
    local label = kind == "deleted" and "Restore deleted file" or "Discard unstaged changes"
    actions[#actions + 1] = {
      id = "discard_worktree",
      label = label,
      action = "discard_worktree",
      confirm = label .. " for " .. tostring(entry.path) .. "?",
    }
  end
  return actions
end

function M.file_actions_for_entry(session, entry, state)
  state = state or git.file_stage_state(((session or {}).file_queue or {}).root, entry, ((session or {}).file_queue or {}).opts or {})
  return file_actions_for_entry(session, entry, state)
end

local function find_action(actions, action_id)
  if type(action_id) == "table" then
    return action_id
  end
  for _, action in ipairs(actions or {}) do
    if action.id == action_id or action.action == action_id then
      return action
    end
  end
  return nil
end

local function confirm_file_action(action, opts)
  if opts and opts.confirm == false then
    return true
  end
  if not action or not action.confirm then
    return true
  end
  return vim.fn.confirm("DiffBandit: " .. action.confirm, "&Yes\n&No", 2) == 1
end

local function refresh_after_file_action(session, entry, row_index)
  if type(session.refresh_git_queue) ~= "function" then
    return
  end
  session:refresh_git_queue(entry and entry.path, {
    fallback_index = row_index,
    preserve_panel_selection = row_index,
  })
  M.focus_nav(session)
end

local function execute_file_action(session, row, action, opts)
  opts = opts or {}
  if not row or row.type ~= "file" or not row.entry then
    return false, "no file selected"
  end
  local queue = session.file_queue or {}
  local entry = row.entry
  local ok, err
  if action.action == "stage" then
    ok, err = git.stage_file(queue.root, entry)
  elseif action.action == "unstage" then
    ok, err = git.unstage_file(queue.root, entry, queue.opts or {})
  elseif action.action == "discard_worktree" then
    if not confirm_file_action(action, opts) then
      return false, "cancelled"
    end
    ok, err = git.discard_worktree_file(queue.root, entry)
  elseif action.action == "delete_untracked" then
    if not confirm_file_action(action, opts) then
      return false, "cancelled"
    end
    ok, err = git.delete_untracked_file(queue.root, entry)
  elseif action.action == "ignore" then
    ok, err = git.append_gitignore(queue.root, action.pattern)
  else
    return false, "unsupported file action"
  end
  if not ok then
    nvim.notify_info(tostring(err))
    return false, err
  end
  refresh_after_file_action(session, entry, row.index)
  return true, nil
end

function M.run_file_action(session, action_id, opts)
  local row = selected_row(session)
  if not row or row.type ~= "file" then
    nvim.notify_info("no file selected")
    return false, "no file selected"
  end
  local panel = session.panel or {}
  local state = (panel.stage_states or {})[row.index]
    or git.file_stage_state((session.file_queue or {}).root, row.entry, (session.file_queue or {}).opts or {})
  local actions = file_actions_for_entry(session, row.entry, state)
  local action = find_action(actions, action_id)
  if not action then
    nvim.notify_info("file action is not available for " .. tostring(row.entry.path))
    return false, "file action is not available"
  end
  return execute_file_action(session, row, action, opts)
end

function M.open_file_actions(session)
  local row = selected_row(session)
  if not row or row.type ~= "file" then
    nvim.notify_info("no file selected")
    return
  end
  local panel = session.panel or {}
  local state = (panel.stage_states or {})[row.index]
    or git.file_stage_state((session.file_queue or {}).root, row.entry, (session.file_queue or {}).opts or {})
  local actions = file_actions_for_entry(session, row.entry, state)
  if #actions == 0 then
    nvim.notify_info("no file actions available for " .. tostring(row.entry.path))
    return
  end
  vim.ui.select(actions, {
    prompt = "DiffBandit file action",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
      execute_file_action(session, row, action, {})
    end
  end)
end

function M.render_nav(session, preferred_entry_index, opts)
  opts = opts or {}
  local panel = session.panel
  if not panel or not panel.nav_buf or not vim.api.nvim_buf_is_valid(panel.nav_buf) then
    return
  end

  panel.stage_states = panel.stage_states or {}
  panel.rows = M.build_rows(session)
  local lines = {}
  for _, row in ipairs(panel.rows) do
    lines[#lines + 1] = row.text
  end
  nvim.set_buffer_options(panel.nav_buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(panel.nav_buf, 0, -1, false, lines)
  nvim.set_buffer_options(panel.nav_buf, { modifiable = false })
  apply_nav_highlights(session)

  local target_row
  if opts.no_initial_selection then
    target_row = first_non_file_row(panel.rows)
  else
    target_row = preferred_entry_index and find_file_row(panel.rows, preferred_entry_index)
      or find_file_row(panel.rows, session.file_queue_index)
      or first_file_row(panel.rows)
  end
  set_nav_cursor(session, target_row)
end

function M.render_commit(session)
  local panel = session.panel
  if not panel or not panel.commit_buf or not vim.api.nvim_buf_is_valid(panel.commit_buf) then
    return
  end
  if is_review_panel(session) then
    local details = panel.details or {}
    local lines = {}
    if details.title and details.title ~= "" then
      lines[#lines + 1] = details.title
    else
      lines[#lines + 1] = "Git review"
    end
    if details.subtitle and details.subtitle ~= "" then
      lines[#lines + 1] = details.subtitle
    end
    if details.base and details.target then
      lines[#lines + 1] = "Range: " .. tostring(details.base) .. " -> " .. tostring(details.target)
    end
    if details.author and details.author ~= "" then
      lines[#lines + 1] = "Author: " .. tostring(details.author)
    end
    if details.date and details.date ~= "" then
      lines[#lines + 1] = "Date: " .. tostring(details.date)
    end
    if details.help and details.help ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = details.help
    end
    nvim.set_buffer_options(panel.commit_buf, { modifiable = true })
    vim.api.nvim_buf_set_lines(panel.commit_buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(panel.commit_buf, session.ns, 0, -1)
    vim.api.nvim_buf_add_highlight(panel.commit_buf, session.ns, "DiffBanditStatusAccent", 0, 0, -1)
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = panel.commit_buf })
    nvim.set_buffer_options(panel.commit_buf, { modifiable = false })
    return
  end
  local staged_count = 0
  for _, state in pairs(panel.stage_states or {}) do
    if state == "staged" or state == "partial" then
      staged_count = staged_count + 1
    end
  end
  local amend = panel.amend and "on" or "off"
  local status_line = string.format("Amend: %s    Staged files: %d", amend, staged_count)
  local message_label_chunks = { { "Commit message:", "DiffBanditStatus" } }
  if panel.validation_message and panel.validation_message ~= "" then
    message_label_chunks[#message_label_chunks + 1] = {
      "  " .. panel.validation_message,
      "DiffBanditDelete",
    }
  end
  if not panel.message_initialized then
    panel.message_initialized = true
    if #(panel.message_lines or {}) == 0 then
      panel.message_lines = { "" }
    end
  else
    panel.message_lines = commit_message_lines_from_buffer(panel.commit_buf)
  end
  local lines = panel.message_lines or { "" }
  if #lines == 0 then
    lines = { "" }
  end
  local buffer_lines = { "", "" }
  vim.list_extend(buffer_lines, lines)
  nvim.set_buffer_options(panel.commit_buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(panel.commit_buf, 0, -1, false, buffer_lines)
  vim.api.nvim_buf_clear_namespace(panel.commit_buf, session.ns, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, panel.commit_buf, session.ns, 0, 0, {
    virt_text = { { status_line, "DiffBanditStatusAccent" } },
    virt_text_pos = "overlay",
    priority = 50,
  })
  pcall(vim.api.nvim_buf_set_extmark, panel.commit_buf, session.ns, 1, 0, {
    virt_text = message_label_chunks,
    virt_text_pos = "overlay",
    priority = 50,
  })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = panel.commit_buf })
  nvim.set_buffer_options(panel.commit_buf, { modifiable = true })
end

function M.render(session, preferred_entry_index, opts)
  opts = opts or {}
  if opts.refresh_stage_states then
    M.refresh_stage_states(session)
  end
  M.render_nav(session, preferred_entry_index, opts)
  M.render_commit(session)
end

local function preview_selected(session)
  local row = selected_row(session)
  if not row or row.type ~= "file" then
    return
  end
  if entry_kind(row.entry) == "unmerged" and type(session.open_merge_file) == "function" then
    session:open_merge_file(row.index, { preserve_focus = true })
    return
  end
  if row.index == session.file_queue_index then
    return
  end
  session:goto_queue_file(row.index, "top", { preserve_focus = true })
end

function M.preview_selected(session)
  local config = panel_config(session)
  if config.preview_on_cursor == false then
    return
  end
  local delay = tonumber(config.preview_debounce_ms) or 0
  local panel = session.panel
  if not panel then
    return
  end
  panel.preview_token = (panel.preview_token or 0) + 1
  local token = panel.preview_token
  vim.defer_fn(function()
    if session.disposed or not session.panel or session.panel.preview_token ~= token then
      return
    end
    preview_selected(session)
  end, math.max(0, delay))
end

function M.move(session, delta)
  local panel = session.panel
  if not panel or not panel.rows then
    return
  end
  local row, current = selected_row(session)
  current = current or 1
  local next_row = row and row.type == "file" and (current + delta) or current
  while next_row >= 1 and next_row <= #panel.rows do
    if panel.rows[next_row].type == "file" then
      set_nav_cursor(session, next_row)
      M.preview_selected(session)
      return
    end
    next_row = next_row + delta
  end
end

function M.focus_diff(session)
  if session.right_win and vim.api.nvim_win_is_valid(session.right_win) then
    vim.api.nvim_set_current_win(session.right_win)
  end
end

function M.focus_nav(session)
  local panel = session.panel
  if panel and panel.nav_win and vim.api.nvim_win_is_valid(panel.nav_win) then
    vim.api.nvim_set_current_win(panel.nav_win)
  end
end

-- True when the host's panel is visible with both windows intact.
function M.is_open(host)
  local panel = host and host.panel
  return (panel
    and panel.visible
    and panel.nav_win and vim.api.nvim_win_is_valid(panel.nav_win)
    and panel.commit_win and vim.api.nvim_win_is_valid(panel.commit_win)) and true or false
end

-- Open the nav/commit window pair to the left of anchor and apply the shared
-- panel window options. The host provides panel.nav_buf/commit_buf.
function M.open_windows(host, anchor)
  local config = panel_config(host)
  local width = config.width or 42
  local height = config.commit_height or 10
  local nav_win = vim.api.nvim_open_win(host.panel.nav_buf, false, {
    split = "left",
    win = anchor,
    width = width,
  })
  local commit_win = vim.api.nvim_open_win(host.panel.commit_buf, false, {
    split = "below",
    win = nav_win,
    height = height,
  })
  host.panel.nav_win = nav_win
  host.panel.commit_win = commit_win
  host.panel.visible = true
  for _, win in ipairs({ nav_win, commit_win }) do
    nvim.set_window_options(win, layout.win_opts.panel())
    nvim.set_window_width(win, width)
  end
  nvim.set_window_height(commit_win, height)
  return nav_win, commit_win
end

function M.focus_commit(session)
  local panel = session.panel
  if panel and panel.commit_win and vim.api.nvim_win_is_valid(panel.commit_win) then
    vim.api.nvim_set_current_win(panel.commit_win)
    pcall(vim.api.nvim_win_set_cursor, panel.commit_win, { math.min(3, vim.api.nvim_buf_line_count(panel.commit_buf)), 0 })
  end
end

function M.navigate_change(session, direction)
  if type(session.goto_next_chunk) == "function" then
    if direction == "prev" then
      session:goto_prev_chunk()
    else
      session:goto_next_chunk()
    end
    M.focus_nav(session)
    return
  end

  local row = selected_row(session)
  if not row or row.type ~= "file" then
    M.move(session, direction == "prev" and -1 or 1)
    row = selected_row(session)
  end
  if row and row.type == "file" and type(session.goto_queue_file) == "function" then
    if entry_kind(row.entry) == "unmerged" and type(session.open_merge_file) == "function" then
      session:open_merge_file(row.index, { navigate_change = direction })
      return
    end
    session:goto_queue_file(row.index, { navigate_change = direction })
  end
end

function M.navigate_file(session, direction)
  local queue = session and session.file_queue
  if not queue or type(session.goto_queue_file) ~= "function" then
    return
  end
  local current = session.file_queue_index or queue.index or 1
  local delta = direction == "prev" and -1 or 1
  session:goto_queue_file(current + delta, "top", { preserve_focus = true })
end

function M.toggle_stage(session)
  if is_review_panel(session) then
    nvim.notify_info("staging is disabled in read-only Git review views")
    return
  end
  local row, row_index = selected_row(session)
  if not row or row.type ~= "file" then
    return
  end
  if entry_kind(row.entry) == "unmerged" then
    nvim.notify_info("resolve merge conflicts before staging " .. tostring(row.entry.path))
    return
  end
  local queue = session.file_queue or {}
  local panel = session.panel or {}
  panel.stage_states = panel.stage_states or {}
  local previous = panel.stage_states[row.index] or "unstaged"
  panel.stage_states[row.index] = next_stage_state(previous)
  M.render(session, row.index)
  if row_index then
    set_nav_cursor(session, row_index)
  end

  git.toggle_file_stage_async(queue.root, row.entry, queue.opts or {}, previous, function(ok, err)
    if session.disposed then
      return
    end
    if not ok then
      panel.stage_states[row.index] = previous
      M.render(session, row.index)
      nvim.notify_info(tostring(err))
      return
    end
    if type(session.refresh_git_queue) == "function" then
      session:refresh_git_queue(row.entry.path, { preserve_panel_selection = row.index })
    end
  end)
end

function M.toggle_amend(session)
  if is_review_panel(session) then
    return
  end
  local panel = session.panel
  if not panel then
    return
  end
  if type(session.set_amend_mode) == "function" then
    session:set_amend_mode(not panel.amend)
    return
  end
end

local function commit_message(session)
  local panel = session.panel or {}
  local lines = commit_message_lines_from_buffer(panel.commit_buf)
  if panel.commit_buf and vim.api.nvim_buf_is_valid(panel.commit_buf) then
    return table.concat(lines, "\n")
  end
  return table.concat(panel.message_lines or {}, "\n")
end

function M.commit(session)
  if is_review_panel(session) then
    nvim.notify_info("commits are disabled in read-only Git review views")
    return false, "read-only Git review view"
  end
  local panel = session.panel or {}
  panel.validation_message = nil
  local ok, err = git.commit((session.file_queue or {}).root, commit_message(session), { amend = panel.amend })
  if not ok then
    panel.validation_message = tostring(err or "commit failed")
    M.render_commit(session)
    nvim.notify_warn(panel.validation_message)
    return false, err
  end
  panel.message_lines = { "" }
  panel.message_initialized = false
  panel.validation_message = nil
  if type(session.clear_amend_mode) == "function" then
    session:clear_amend_mode()
  else
    panel.amend = false
    panel.amend_loaded = false
  end
  session:refresh_git_queue()
  nvim.notify_info("committed changes")
  return true, nil
end

function M.close(session)
  if is_review_panel(session) and type(session.close) == "function" then
    session:close()
    return
  end
  local panel = session.panel
  if not panel then
    return
  end
  for _, win in ipairs({ panel.nav_win, panel.commit_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  panel.visible = false
end

local function setup_commit_write_command(session)
  local panel = session.panel
  if not panel or not panel.commit_buf or not vim.api.nvim_buf_is_valid(panel.commit_buf) then
    return
  end
  if panel.commit_write_autocmd then
    pcall(vim.api.nvim_del_autocmd, panel.commit_write_autocmd)
    panel.commit_write_autocmd = nil
  end
  panel.commit_write_autocmd = vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = panel.commit_buf,
    callback = function()
      M.commit(session)
    end,
  })
end

function M.setup_keymaps(session)
  local panel = session.panel
  if not panel or not panel.nav_buf then
    return
  end
  local keys = panel_config(session).keys or {}
  local file_keys = config_mod.section((session or {}).config, "git", "file_keys")
  local review = is_review_panel(session)
  local has_queue = session.file_queue ~= nil

  local function navigate_change(direction)
    return function()
      M.navigate_change(session, direction)
    end
  end
  local function navigate_file(direction)
    return function()
      M.navigate_file(session, direction)
    end
  end
  local focus_diff = function()
    M.focus_diff(session)
  end
  local commit = function()
    M.commit(session)
  end
  local toggle_amend = function()
    M.toggle_amend(session)
  end
  local close = function()
    M.close(session)
  end

  -- lhs = nil/false skips the map (unset config key or failed condition);
  -- when = false skips it explicitly.
  local specs = {
    { buf = "nav", lhs = "j", fn = function() M.move(session, 1) end },
    { buf = "nav", lhs = "k", fn = function() M.move(session, -1) end },
    { buf = "nav", lhs = keys.toggle_stage, fn = function() M.toggle_stage(session) end },
    { buf = "nav", lhs = keys.focus_diff, fn = focus_diff },
    { buf = "nav", lhs = keys.focus_commit, fn = function() M.focus_commit(session) end },
    { buf = "nav", lhs = keys.file_actions, fn = function() M.open_file_actions(session) end, when = not review },
    { buf = "nav", lhs = "]c", fn = navigate_change("next") },
    { buf = "nav", lhs = "[c", fn = navigate_change("prev") },
    { buf = "nav", lhs = file_keys.next, fn = navigate_file("next"), when = has_queue },
    { buf = "nav", lhs = file_keys.prev, fn = navigate_file("prev"), when = has_queue },
    { buf = "nav", lhs = keys.commit, fn = commit, when = not review },
    { buf = "nav", lhs = keys.toggle_amend, fn = toggle_amend, when = keys.toggle_amend ~= keys.toggle_stage and not review },
    { buf = "nav", lhs = keys.refresh, fn = function() session:refresh_git_queue() end },
    { buf = "nav", lhs = keys.close, fn = close },

    { buf = "commit", lhs = keys.focus_diff, fn = focus_diff, when = review },
    { buf = "commit", lhs = "]c", fn = navigate_change("next"), when = review },
    { buf = "commit", lhs = "[c", fn = navigate_change("prev"), when = review },
    { buf = "commit", lhs = file_keys.next, fn = navigate_file("next"), when = review and has_queue },
    { buf = "commit", lhs = file_keys.prev, fn = navigate_file("prev"), when = review and has_queue },
    { buf = "commit", lhs = keys.close, fn = close, when = review },

    { buf = "commit", lhs = keys.commit, fn = commit, when = not review },
    { buf = "commit", lhs = keys.toggle_amend, fn = toggle_amend, when = not review },
  }

  local buffers = { nav = panel.nav_buf }
  if panel.commit_buf and vim.api.nvim_buf_is_valid(panel.commit_buf) then
    buffers.commit = panel.commit_buf
    if not review then
      setup_commit_write_command(session)
    end
  end

  for _, spec in ipairs(specs) do
    local buf = buffers[spec.buf]
    if buf and spec.lhs and spec.when ~= false then
      vim.keymap.set("n", spec.lhs, spec.fn, { buffer = buf, nowait = true, noremap = true, silent = true })
    end
  end
end

function M.attach(session, opts)
  opts = opts or {}
  if not session.panel then
    return
  end
  session.panel.visible = true
  session.panel.stage_states = {}
  session.panel.rows = {}
  session.panel.message_lines = session.panel.message_lines or { "" }
  M.refresh_stage_states(session)
  M.render(session, opts.initial_selection, { no_initial_selection = opts.no_initial_selection ~= false })
  M.setup_keymaps(session)
end

M._private = {
  build_rows = M.build_rows,
}

return M
