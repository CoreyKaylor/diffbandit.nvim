local git = require("diffbandit.git")

local M = {}

local plain_icons = {
  modified = "M",
  added = "A",
  deleted = "D",
  renamed = "R",
  copied = "C",
  untracked = "?",
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
  staged = "󰄬",
  partial = "󰡖",
}

local function panel_config(session)
  return ((((session or {}).config or {}).git or {}).panel or {})
end

local function set_modifiable(buf, value)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", value, { buf = buf })
  end
end

local function trim_width(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local result = ""
  local marker = "..."
  local char_count = vim.fn.strchars(text)
  for index = 0, char_count - 1 do
    local next_text = result .. vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(next_text .. marker) > width then
      break
    end
    result = next_text
  end
  return result .. marker
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
  local prefix = string.format("  %s %s ", stage_symbol(session, state), status_icon(session, entry))
  local base = prefix .. name
  local parent_width = math.max(0, width - vim.fn.strdisplaywidth(base) - 1)
  local text
  if parent ~= "" and parent_width > 3 then
    text = base .. " " .. trim_width(parent, parent_width)
  else
    text = trim_width(base, width)
  end
  return {
    text = text,
    name_col = #prefix,
    name_end_col = math.min(#text, #prefix + #name),
  }
end

local function row_group(entry)
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
    { name = "Changes", entries = {} },
    { name = "Unversioned Files", entries = {} },
  }
  for index, entry in ipairs(entries) do
    local group_name = row_group(entry)
    local target = group_name == "Unversioned Files" and groups[2] or groups[1]
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

function M.refresh_stage_states(session)
  local panel = session.panel
  if not panel then
    return {}
  end
  local queue = session.file_queue or {}
  panel.stage_states = git.file_stage_states(queue.root, queue.entries, queue.opts or {})
  return panel.stage_states
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
  set_modifiable(panel.nav_buf, true)
  vim.api.nvim_buf_set_lines(panel.nav_buf, 0, -1, false, lines)
  set_modifiable(panel.nav_buf, false)
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
  set_modifiable(panel.commit_buf, true)
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
  set_modifiable(panel.commit_buf, true)
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
    session:goto_queue_file(row.index, { navigate_change = direction })
  end
end

function M.toggle_stage(session)
  local row, row_index = selected_row(session)
  if not row or row.type ~= "file" then
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
      vim.notify("DiffBandit: " .. tostring(err), vim.log.levels.INFO)
      return
    end
    if type(session.refresh_git_queue) == "function" then
      session:refresh_git_queue(row.entry.path, { preserve_panel_selection = row.index })
    end
  end)
end

function M.toggle_amend(session)
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
  local panel = session.panel or {}
  panel.validation_message = nil
  local ok, err = git.commit((session.file_queue or {}).root, commit_message(session), { amend = panel.amend })
  if not ok then
    panel.validation_message = tostring(err or "commit failed")
    M.render_commit(session)
    vim.notify("DiffBandit: " .. panel.validation_message, vim.log.levels.WARN)
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
  vim.notify("DiffBandit: committed changes", vim.log.levels.INFO)
  return true, nil
end

function M.close(session)
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
  local opts = { buffer = panel.nav_buf, nowait = true, noremap = true, silent = true }
  vim.keymap.set("n", "j", function()
    M.move(session, 1)
  end, opts)
  vim.keymap.set("n", "k", function()
    M.move(session, -1)
  end, opts)
  if keys.toggle_stage then
    vim.keymap.set("n", keys.toggle_stage, function()
      M.toggle_stage(session)
    end, opts)
  end
  if keys.focus_diff then
    vim.keymap.set("n", keys.focus_diff, function()
      M.focus_diff(session)
    end, opts)
  end
  if keys.focus_commit then
    vim.keymap.set("n", keys.focus_commit, function()
      M.focus_commit(session)
    end, opts)
  end
  vim.keymap.set("n", "]c", function()
    M.navigate_change(session, "next")
  end, opts)
  vim.keymap.set("n", "[c", function()
    M.navigate_change(session, "prev")
  end, opts)
  if keys.commit then
    vim.keymap.set("n", keys.commit, function()
      M.commit(session)
    end, opts)
  end
  if keys.toggle_amend and keys.toggle_amend ~= keys.toggle_stage then
    vim.keymap.set("n", keys.toggle_amend, function()
      M.toggle_amend(session)
    end, opts)
  end
  if keys.refresh then
    vim.keymap.set("n", keys.refresh, function()
      session:refresh_git_queue()
    end, opts)
  end
  if keys.close then
    vim.keymap.set("n", keys.close, function()
      M.close(session)
    end, opts)
  end

  if panel.commit_buf and vim.api.nvim_buf_is_valid(panel.commit_buf) then
    setup_commit_write_command(session)
    local commit_opts = { buffer = panel.commit_buf, nowait = true, noremap = true, silent = true }
    if keys.commit then
      vim.keymap.set("n", keys.commit, function()
        M.commit(session)
      end, commit_opts)
    end
    if keys.toggle_amend then
      vim.keymap.set("n", keys.toggle_amend, function()
        M.toggle_amend(session)
      end, commit_opts)
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
  row_for_entry = row_for_entry,
  row_group = row_group,
}

return M
