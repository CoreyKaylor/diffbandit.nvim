local state = require("diffbandit.state")
local folder_model = require("diffbandit.folder_model")
local nvim = require("diffbandit.nvim")
local process = require("diffbandit.process")
local ui = require("diffbandit.ui")
local layout = require("diffbandit.layout")
local config_mod = require("diffbandit.config")

local Folder = {}
Folder.__index = Folder

local uv = vim.uv or vim.loop

local status_marker = {
  same = "=",
  pending = "…",
  different = "≠",
  type_mismatch = "!",
  left_only = "←",
  right_only = "→",
  error = "!",
}

local filter_labels = {
  all = "All",
  differences = "Differences",
  same = "Same",
  left_only = "Left Only",
  right_only = "Right Only",
  different = "Different Files",
  errors = "Errors",
}

local filter_order = {
  "all",
  "differences",
  "same",
  "left_only",
  "right_only",
  "different",
  "errors",
}

local set_buffer_options = nvim.set_buffer_options
local set_window_options = nvim.set_window_options
local set_window_width = nvim.set_window_width

local function normalize_root(path)
  if not path or path == "" then
    return nil
  end
  local expanded = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  expanded = expanded:gsub("/$", "")
  local stat = uv.fs_stat(expanded)
  if not stat or stat.type ~= "directory" then
    return nil, string.format("not a directory: %s", path)
  end
  return expanded, nil
end

local parent_rel = folder_model.parent_rel
local is_difference_status = folder_model.is_difference_status

local function path_has_ancestor(rel, predicate)
  local parent = parent_rel(rel)
  while parent do
    if predicate(parent) then
      return true
    end
    parent = parent_rel(parent)
  end
  return false
end

local function mtime_key(stat)
  local mt = stat and stat.mtime
  if type(mt) == "table" then
    return tostring(mt.sec or 0) .. "." .. tostring(mt.nsec or 0)
  end
  return tostring(mt or 0)
end

local function display_mtime(stat)
  local mt = stat and stat.mtime
  local sec = type(mt) == "table" and mt.sec or mt
  if not sec or sec <= 0 then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M", sec)
end

local function display_size(stat)
  local size = tonumber(stat and stat.size) or 0
  if size < 1024 then
    return tostring(size) .. " B"
  elseif size < 1024 * 1024 then
    return string.format("%.1f KB", size / 1024)
  elseif size < 1024 * 1024 * 1024 then
    return string.format("%.1f MB", size / (1024 * 1024))
  end
  return string.format("%.1f GB", size / (1024 * 1024 * 1024))
end

local function center_text(text, width)
  text = tostring(text or "")
  width = math.max(1, tonumber(width) or 1)
  local text_width = vim.fn.strdisplaywidth(text)
  if text_width > width then
    return ui.truncate_display(text, width)
  end
  local left = math.floor((width - text_width) / 2)
  local right = width - text_width - left
  return string.rep(" ", left) .. text .. string.rep(" ", right)
end

local function cache_key(meta)
  if not meta or not meta.path or not meta.stat then
    return nil
  end
  local stat = meta.stat
  return table.concat({
    meta.path,
    tostring(stat.size or 0),
    mtime_key(stat),
    tostring(stat.dev or ""),
    tostring(stat.ino or ""),
  }, "\0")
end

local function detect_backend(config)
  local compare = config_mod.section(config, "folder", "compare")
  local requested = compare.backend or "auto"
  local function executable(name)
    return vim.fn.executable(name) == 1
  end
  if requested == "cmp" then
    return executable("cmp") and { name = "cmp", command = "cmp" } or nil
  end
  if requested == "md5sum" or requested == "auto" then
    if executable("md5sum") then
      return { name = "md5sum", command = "md5sum", args = { "-z" }, parser = "md5sum_z" }
    end
    if requested == "md5sum" then
      return nil
    end
  end
  if requested == "md5" or requested == "auto" then
    if executable("md5") then
      return { name = "md5", command = "md5", args = { "-q" }, parser = "line_order" }
    end
    if requested == "md5" then
      return nil
    end
  end
  if requested == "shasum" or requested == "auto" then
    if executable("shasum") then
      return { name = "shasum", command = "shasum", args = { "-a", "256" }, parser = "digest_lines" }
    end
    if requested == "shasum" then
      return nil
    end
  end
  if executable("cmp") then
    return { name = "cmp", command = "cmp" }
  end
  return nil
end

local parse_md5sum_z = folder_model.parse_md5sum_z
local parse_digest_lines = folder_model.parse_digest_lines
local parse_line_order = folder_model.parse_line_order

local run_async = process.run_raw_async

local function row_status_hl(status)
  if status == "left_only" or status == "error" then
    return "DiffBanditDelete"
  elseif status == "right_only" then
    return "DiffBanditAdd"
  elseif status == "different" or status == "type_mismatch" or status == "pending" then
    return "DiffBanditChangeLeft"
  end
  return nil
end

local function row_side_hl(row, side)
  if not row then
    return nil
  end
  if row.status == "left_only" then
    return side == "left" and "DiffBanditDelete" or "DiffBanditPlaceholder"
  elseif row.status == "right_only" then
    return side == "right" and "DiffBanditAdd" or "DiffBanditPlaceholder"
  elseif row.status == "error" then
    return "DiffBanditDelete"
  elseif row.status == "different" or row.status == "type_mismatch" or row.status == "pending" then
    return "DiffBanditChangeLeft"
  end
  return nil
end

local function row_matches_filter(row, filter)
  filter = filter or "all"
  if filter == "all" then
    return true
  elseif filter == "differences" then
    return is_difference_status(row.status) or (row.diff_count or 0) > 0
  elseif filter == "same" then
    return row.status == "same" and (row.diff_count or 0) == 0 and (row.pending_count or 0) == 0
  elseif filter == "left_only" then
    return row.direct_status == "left_only" or (row.status == "left_only" and row.kind == "directory")
  elseif filter == "right_only" then
    return row.direct_status == "right_only" or (row.status == "right_only" and row.kind == "directory")
  elseif filter == "different" then
    return row.direct_status == "different" or row.direct_status == "type_mismatch"
  elseif filter == "errors" then
    return row.direct_status == "error" or row.status == "error"
  end
  return true
end

local function compare_config(self)
  return config_mod.section(self.config, "folder", "compare")
end

local function folder_config(self)
  return config_mod.section(self.config, "folder")
end

local function is_dir_row(row)
  return row and row.kind == "directory"
end

local function create_buffer(name)
  return nvim.make_buffer(name, nil, { modifiable = false })
end

local function tree_prefix(row, by_rel)
  if not row or (row.depth or 0) == 0 then
    return ""
  end
  local ancestors = {}
  local parent = row.parent
  while parent do
    ancestors[#ancestors + 1] = parent
    parent = by_rel[parent] and by_rel[parent].parent or nil
  end
  local parts = {}
  for index = #ancestors, 1, -1 do
    local ancestor = by_rel[ancestors[index]]
    parts[#parts + 1] = ancestor and ancestor.sibling_last and "  " or "│ "
  end
  parts[#parts + 1] = row.sibling_last and "└ " or "├ "
  return table.concat(parts)
end

local function detail_text(row, meta, columns)
  local details = {}
  if row.kind == "directory" then
    if (row.diff_count or 0) > 0 then
      details[#details + 1] = tostring(row.diff_count) .. " diffs"
    elseif (row.pending_count or 0) > 0 then
      details[#details + 1] = tostring(row.pending_count) .. " pending"
    end
  elseif meta then
    if columns.size and meta.kind == "file" then
      details[#details + 1] = display_size(meta.stat)
    end
    if columns.modified and meta.stat then
      local mt = display_mtime(meta.stat)
      if mt ~= "" then
        details[#details + 1] = mt
      end
    end
  end
  return table.concat(details, "  ")
end

local function fit_name_and_detail(name_text, details, width)
  if details == "" then
    return ui.truncate_display(name_text, width), nil
  end
  local detail_width = vim.fn.strdisplaywidth(details)
  if detail_width + 2 >= width then
    return ui.truncate_display(name_text, width), nil
  end
  local name_width = width - detail_width - 2
  local name_part = ui.truncate_display(name_text, name_width)
  local padding = math.max(2, width - vim.fn.strdisplaywidth(name_part) - detail_width)
  return name_part .. string.rep(" ", padding) .. details, #name_part + padding
end

local function format_side(row, side, width, columns, by_rel)
  local meta = row and row[side]
  if not meta then
    return {
      text = string.rep(" ", math.max(0, width)),
    }
  end
  local icon = " "
  if row.kind == "directory" then
    icon = row.expanded and "▾" or "▸"
  elseif row.kind == "link" then
    icon = "@"
  end
  local prefix = tree_prefix(row, by_rel or {})
  local label_prefix
  if row.kind == "directory" or row.kind == "link" then
    label_prefix = prefix .. icon .. " "
  else
    label_prefix = prefix ~= "" and prefix or "  "
  end
  local name_start = #label_prefix
  local name_text = label_prefix .. row.name
  local details = detail_text(row, meta, columns or {})
  local text, detail_start = fit_name_and_detail(name_text, details, width)
  return {
    text = text,
    guide_end = #prefix,
    name_start = name_start,
    name_end = math.min(#text, name_start + #row.name),
    detail_start = detail_start,
  }
end

local function count_kind(entries, kind)
  local count = 0
  for _, entry in pairs(entries or {}) do
    if not kind or entry.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function header_text(label, root, entries, width)
  local file_count = count_kind(entries, "file")
  local prefix = string.format(" %s  %d files", label, file_count)
  local available = math.max(1, width - vim.fn.strdisplaywidth(prefix) - 2)
  return prefix .. "  " .. ui.truncate_display(root or "", available)
end

local function compact_filter_label(filter)
  if filter == "differences" then
    return "Diff"
  elseif filter == "left_only" then
    return "Left"
  elseif filter == "right_only" then
    return "Right"
  elseif filter == "different" then
    return "Files"
  elseif filter == "errors" then
    return "Err"
  elseif filter == "same" then
    return "Same"
  end
  return "All"
end

function Folder.start(left_path, right_path, config, opts)
  opts = opts or {}
  local left_root, left_err = normalize_root(left_path)
  if not left_root then
    return nil, left_err
  end
  local right_root, right_err = normalize_root(right_path)
  if not right_root then
    return nil, right_err
  end

  local self = setmetatable({}, Folder)
  self.id = state.next_session_id()
  self.config = config
  self.left_root = left_root
  self.right_root = right_root
  self.open_file_diff = opts.open_file_diff
  self.disposed = false
  self.expanded = {}
  self.filter = "all"
  self.selected_rel = nil
  self.digest_cache = {}
  self.compare_generation = 0
  self.active_jobs = 0
  self.pending_batches = {}
  self.gutter_width = math.max(3, tonumber(folder_config(self).gutter_width) or 7)
  self.ns = vim.api.nvim_create_namespace("DiffBanditFolder" .. tostring(self.id))
  self:open_layout()
  self:refresh()
  self:setup_autocmds()
  self:setup_keymaps()
  state.register(self)
  return self
end

function Folder:open_layout()
  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()
  self.tabnr = vim.api.nvim_tabpage_get_number(self.tabpage)

  self.left_buf = create_buffer("diffbandit-folder-left-" .. tostring(self.id))
  self.gutter_buf = create_buffer("diffbandit-folder-gutter-" .. tostring(self.id))
  self.right_buf = create_buffer("diffbandit-folder-right-" .. tostring(self.id))

  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, self.left_buf)
  local gutter_win = layout.open_unfocusable_win(self.gutter_buf, left_win, { width = self.gutter_width })
  local right_win = vim.api.nvim_open_win(self.right_buf, false, {
    split = "right",
    win = gutter_win,
  })

  self.left_win = left_win
  self.gutter_win = gutter_win
  self.right_win = right_win
  self.last_tree_win = left_win

  for _, win in ipairs({ left_win, right_win }) do
    set_window_options(win, layout.win_opts.source(nil, { foldcolumn = "0" }))
  end
  set_window_options(gutter_win, layout.win_opts.gutter())
  set_window_width(gutter_win, self.gutter_width)
  self:resize_layout()
  vim.api.nvim_set_current_win(left_win)
  self.title = string.format("DiffBandit Folder: %s ↔ %s", self.left_root, self.right_root)
  vim.api.nvim_tabpage_set_var(self.tabpage, "diffbandit_title", self.title)
end

function Folder:resize_layout()
  if self.resizing_layout then
    return
  end
  if not (self.left_win and self.gutter_win and self.right_win) then
    return
  end
  if not (vim.api.nvim_win_is_valid(self.left_win)
      and vim.api.nvim_win_is_valid(self.gutter_win)
      and vim.api.nvim_win_is_valid(self.right_win)) then
    return
  end

  set_window_width(self.gutter_win, self.gutter_width)
  local total = vim.api.nvim_win_get_width(self.left_win)
    + vim.api.nvim_win_get_width(self.gutter_win)
    + vim.api.nvim_win_get_width(self.right_win)
  local content = total - self.gutter_width
  if content < 2 then
    return
  end
  self.resizing_layout = true
  local left_width = math.floor(content / 2)
  local right_width = content - left_width
  set_window_width(self.left_win, left_width)
  set_window_width(self.gutter_win, self.gutter_width)
  set_window_width(self.right_win, right_width)
  self.resizing_layout = false
end

function Folder:refresh()
  if self.disposed then
    return false
  end
  self.compare_generation = self.compare_generation + 1
  self.active_jobs = 0
  self.pending_batches = {}
  local filters = folder_config(self).filters or {}
  self.left_entries = folder_model.scan_tree(self.left_root, filters)
  self.right_entries = folder_model.scan_tree(self.right_root, filters)
  self.rows, self.rows_by_rel = folder_model.build_rows(self.left_entries, self.right_entries)
  for _, row in ipairs(self.rows or {}) do
    if row.kind == "directory" and self.expanded[row.rel] == nil then
      self.expanded[row.rel] = true
    end
    row.expanded = self.expanded[row.rel] ~= false
  end
  self:apply_cached_comparisons()
  folder_model.recompute_aggregate(self.rows, self.rows_by_rel)
  self:build_visible_rows()
  self:render()
  self:schedule_compare_jobs()
  return true
end

function Folder:apply_cached_comparisons()
  for _, row in ipairs(self.rows or {}) do
    if row.direct_status == "pending" and row.left and row.right then
      local left_key = cache_key(row.left)
      local right_key = cache_key(row.right)
      local left_digest = left_key and self.digest_cache[left_key]
      local right_digest = right_key and self.digest_cache[right_key]
      if left_digest and right_digest then
        row.direct_status = left_digest == right_digest and "same" or "different"
      end
    end
  end
end

function Folder:build_visible_rows()
  self.visible_rows = {}
  for _, row in ipairs(self.rows or {}) do
    local hidden_by_collapse = path_has_ancestor(row.rel, function(parent)
      return self.expanded[parent] == false
    end)
    if not hidden_by_collapse and row_matches_filter(row, self.filter) then
      self.visible_rows[#self.visible_rows + 1] = row
    end
  end
  if self.selected_rel then
    local found = false
    for index, row in ipairs(self.visible_rows) do
      if row.rel == self.selected_rel then
        self.visible_index = index
        found = true
        break
      end
    end
    if not found then
      self.visible_index = math.min(self.visible_index or 1, math.max(1, #self.visible_rows))
      self.selected_rel = self.visible_rows[self.visible_index] and self.visible_rows[self.visible_index].rel or nil
    end
  else
    self.visible_index = math.min(self.visible_index or 1, math.max(1, #self.visible_rows))
    self.selected_rel = self.visible_rows[self.visible_index] and self.visible_rows[self.visible_index].rel or nil
  end
end

function Folder:render()
  if self.disposed then
    return
  end
  if not (vim.api.nvim_buf_is_valid(self.left_buf)
      and vim.api.nvim_buf_is_valid(self.gutter_buf)
      and vim.api.nvim_buf_is_valid(self.right_buf)) then
    return
  end

  local left_width = self.left_win and vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_width(self.left_win) or 40
  local right_width = self.right_win and vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_width(self.right_win) or 40
  local columns = folder_config(self).columns or {}
  local left_lines = { header_text("left", self.left_root, self.left_entries, left_width) }
  local gutter_lines = { center_text(compact_filter_label(self.filter), self.gutter_width) }
  local right_lines = { header_text("right", self.right_root, self.right_entries, right_width) }
  local left_meta = {}
  local right_meta = {}

  for _, row in ipairs(self.visible_rows or {}) do
    local left_render = format_side(row, "left", left_width, columns, self.rows_by_rel)
    local right_render = format_side(row, "right", right_width, columns, self.rows_by_rel)
    left_meta[#left_lines] = { row = row, render = left_render }
    right_meta[#right_lines] = { row = row, render = right_render }
    left_lines[#left_lines + 1] = left_render.text
    gutter_lines[#gutter_lines + 1] = center_text(status_marker[row.status] or "?", self.gutter_width)
    right_lines[#right_lines + 1] = right_render.text
  end
  if #self.visible_rows == 0 then
    left_lines[#left_lines + 1] = " No folder entries"
    gutter_lines[#gutter_lines + 1] = string.rep(" ", self.gutter_width)
    right_lines[#right_lines + 1] = ""
  end

  local max_lines = math.max(#left_lines, #gutter_lines, #right_lines)
  while #left_lines < max_lines do
    left_lines[#left_lines + 1] = ""
  end
  while #gutter_lines < max_lines do
    gutter_lines[#gutter_lines + 1] = string.rep(" ", self.gutter_width)
  end
  while #right_lines < max_lines do
    right_lines[#right_lines + 1] = ""
  end

  for _, buf in ipairs({ self.left_buf, self.gutter_buf, self.right_buf }) do
    set_buffer_options(buf, { modifiable = true })
  end
  vim.api.nvim_buf_set_lines(self.left_buf, 0, -1, false, left_lines)
  vim.api.nvim_buf_set_lines(self.gutter_buf, 0, -1, false, gutter_lines)
  vim.api.nvim_buf_set_lines(self.right_buf, 0, -1, false, right_lines)
  for _, buf in ipairs({ self.left_buf, self.gutter_buf, self.right_buf }) do
    set_buffer_options(buf, { modifiable = false })
    vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, self.ns, "DiffBanditStatus", 0, 0, -1)
  end

  for index, row in ipairs(self.visible_rows or {}) do
    local line = index
    local gutter_hl = row_status_hl(row.status)
    local left_hl = row_side_hl(row, "left")
    local right_hl = row_side_hl(row, "right")
    if left_hl then
      vim.api.nvim_buf_add_highlight(self.left_buf, self.ns, left_hl, line, 0, -1)
    end
    if gutter_hl then
      vim.api.nvim_buf_add_highlight(self.gutter_buf, self.ns, gutter_hl, line, 0, -1)
    end
    if right_hl then
      vim.api.nvim_buf_add_highlight(self.right_buf, self.ns, right_hl, line, 0, -1)
    end
    self:highlight_side_metadata(self.left_buf, line, row, left_meta[line])
    self:highlight_side_metadata(self.right_buf, line, row, right_meta[line])
  end

  self:restore_cursor()
end

function Folder:highlight_side_metadata(buf, line, row, meta)
  if not (buf and vim.api.nvim_buf_is_valid(buf) and meta and meta.render) then
    return
  end
  local render = meta.render
  if render.guide_end and render.guide_end > 0 then
    vim.api.nvim_buf_add_highlight(buf, self.ns, "DiffBanditMutedText", line, 0, render.guide_end)
  end
  if row and row.kind == "directory" and render.name_start and render.name_end and render.name_end > render.name_start then
    vim.api.nvim_buf_add_highlight(buf, self.ns, "DiffBanditAccentText", line, render.name_start, render.name_end)
  end
  if render.detail_start then
    vim.api.nvim_buf_add_highlight(buf, self.ns, "DiffBanditMutedText", line, render.detail_start, -1)
  end
end

function Folder:request_render()
  if self.render_scheduled or self.disposed then
    return
  end
  self.render_scheduled = true
  local delay = tonumber(compare_config(self).debounce_ms) or 50
  vim.defer_fn(function()
    self.render_scheduled = false
    if self.disposed then
      return
    end
    folder_model.recompute_aggregate(self.rows, self.rows_by_rel)
    self:build_visible_rows()
    self:render()
  end, math.max(0, delay))
end

function Folder:restore_cursor()
  local target = (self.visible_index or 1) + 1
  local line_count = math.max(1, vim.api.nvim_buf_line_count(self.left_buf))
  target = math.max(1, math.min(target, line_count))
  for _, win in ipairs({ self.left_win, self.right_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
  end
end

function Folder:row_under_cursor()
  local win = vim.api.nvim_get_current_win()
  if win ~= self.left_win and win ~= self.right_win then
    win = self.left_win
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local index = math.max(1, line - 1)
  local row = (self.visible_rows or {})[index]
  if row then
    self.visible_index = index
    self.selected_rel = row.rel
  end
  return row, index
end

function Folder:redirect_gutter_focus()
  if self.disposed or not (self.gutter_win and vim.api.nvim_win_is_valid(self.gutter_win)) then
    return
  end
  local current = vim.api.nvim_get_current_win()
  if current == self.left_win or current == self.right_win then
    self.last_tree_win = current
    return
  end
  if current ~= self.gutter_win then
    return
  end
  local target
  if self.last_tree_win == self.left_win then
    target = self.right_win
  elseif self.last_tree_win == self.right_win then
    target = self.left_win
  else
    target = self.left_win
  end
  if target and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_set_current_win, target)
  end
end

function Folder:set_selected_index(index)
  local count = #(self.visible_rows or {})
  if count == 0 then
    self.visible_index = 1
    self.selected_rel = nil
    return
  end
  index = math.max(1, math.min(index or 1, count))
  self.visible_index = index
  self.selected_rel = self.visible_rows[index].rel
  self:restore_cursor()
end

function Folder:toggle_expand(row)
  row = row or self:row_under_cursor()
  if not is_dir_row(row) then
    return false
  end
  self.expanded[row.rel] = not (self.expanded[row.rel] ~= false)
  row.expanded = self.expanded[row.rel] ~= false
  self:build_visible_rows()
  self:render()
  return true
end

function Folder:expand_all()
  for _, row in ipairs(self.rows or {}) do
    if is_dir_row(row) then
      self.expanded[row.rel] = true
      row.expanded = true
    end
  end
  self:build_visible_rows()
  self:render()
end

function Folder:collapse_all()
  for _, row in ipairs(self.rows or {}) do
    if is_dir_row(row) then
      self.expanded[row.rel] = false
      row.expanded = false
    end
  end
  self:build_visible_rows()
  self:render()
end

function Folder:goto_diff(step)
  local row = self:row_under_cursor()
  local start = self.visible_index or 1
  if row then
    start = self.visible_index or start
  end
  local count = #(self.visible_rows or {})
  if count == 0 then
    return false
  end
  local index = start + step
  while index >= 1 and index <= count do
    local candidate = self.visible_rows[index]
    if candidate and is_difference_status(candidate.status) and candidate.kind ~= "directory" then
      self:set_selected_index(index)
      return true
    end
    index = index + step
  end
  nvim.notify_info("no " .. (step > 0 and "next" or "previous") .. " folder difference")
  return false
end

function Folder:set_filter(filter)
  if not filter_labels[filter] then
    return false
  end
  self.filter = filter
  self:build_visible_rows()
  self:render()
  return true
end

function Folder:select_filter()
  local items = {}
  for _, id in ipairs(filter_order) do
    items[#items + 1] = { id = id, label = filter_labels[id] }
  end
  vim.ui.select(items, {
    prompt = "DiffBandit folder filter",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      self:set_filter(item.id)
    end
  end)
end

function Folder:open_selected()
  local row = self:row_under_cursor()
  if not row then
    return false
  end
  if is_dir_row(row) then
    return self:toggle_expand(row)
  end
  if type(self.open_file_diff) ~= "function" then
    return false, "file diff opener is not configured"
  end
  local current_win = vim.api.nvim_get_current_win()
  local topline = 1
  if current_win and vim.api.nvim_win_is_valid(current_win) then
    local ok, view = pcall(vim.api.nvim_win_call, current_win, vim.fn.winsaveview)
    if ok and view then
      topline = view.topline or 1
    end
  end
  return self.open_file_diff(self, row, {
    tabpage = self.tabpage,
    selected_rel = row.rel,
    cursor_side = current_win == self.right_win and "right" or "left",
    topline = topline,
    filter = self.filter,
  })
end

function Folder:restore_from_child(context)
  if self.disposed then
    return
  end
  if context and context.filter and filter_labels[context.filter] then
    self.filter = context.filter
  end
  if context and context.selected_rel then
    self.selected_rel = context.selected_rel
  end
  self:build_visible_rows()
  self:render()
  if context and context.topline then
    local win = context.cursor_side == "right" and self.right_win or self.left_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        view.topline = context.topline
        pcall(vim.fn.winrestview, view)
      end)
    end
  end
  local focus = context and context.cursor_side == "right" and self.right_win or self.left_win
  if focus and vim.api.nvim_win_is_valid(focus) then
    pcall(vim.api.nvim_set_current_win, focus)
  end
end

function Folder:schedule_compare_jobs()
  self.backend = detect_backend(self.config)
  if not self.backend then
    for _, row in ipairs(self.rows or {}) do
      if row.direct_status == "pending" then
        row.direct_status = "error"
      end
    end
    self:request_render()
    return
  end

  local visible = {}
  local visible_set = {}
  for _, row in ipairs(self.visible_rows or {}) do
    if row.direct_status == "pending" and row.left and row.right then
      visible[#visible + 1] = row
      visible_set[row.rel] = true
    end
  end
  local rest = {}
  for _, row in ipairs(self.rows or {}) do
    if row.direct_status == "pending" and row.left and row.right and not visible_set[row.rel] then
      rest[#rest + 1] = row
    end
  end

  local candidates = {}
  vim.list_extend(candidates, visible)
  vim.list_extend(candidates, rest)
  local batch_size = math.max(1, tonumber(compare_config(self).batch_size) or 64)
  if self.backend.name == "cmp" then
    batch_size = 1
  end
  self.pending_batches = {}
  local batch = {}
  for _, row in ipairs(candidates) do
    batch[#batch + 1] = row
    if #batch >= batch_size then
      self.pending_batches[#self.pending_batches + 1] = batch
      batch = {}
    end
  end
  if #batch > 0 then
    self.pending_batches[#self.pending_batches + 1] = batch
  end
  self:drain_compare_queue(self.compare_generation)
end

function Folder:drain_compare_queue(generation)
  if self.disposed or generation ~= self.compare_generation then
    return
  end
  local max_concurrency = math.max(1, tonumber(compare_config(self).max_concurrency) or 2)
  while self.active_jobs < max_concurrency and #self.pending_batches > 0 do
    local batch = table.remove(self.pending_batches, 1)
    self.active_jobs = self.active_jobs + 1
    if self.backend.name == "cmp" then
      self:run_cmp_batch(batch, generation)
    else
      self:run_digest_batch(batch, generation)
    end
  end
end

function Folder:finish_compare_job(generation)
  self.active_jobs = math.max(0, (self.active_jobs or 1) - 1)
  if self.disposed or generation ~= self.compare_generation then
    return
  end
  self:request_render()
  self:drain_compare_queue(generation)
end

function Folder:run_cmp_batch(batch, generation)
  local row = batch and batch[1]
  if not row then
    self:finish_compare_job(generation)
    return
  end
  run_async({ "cmp", "-s", row.left.path, row.right.path }, function(code)
    if not self.disposed and generation == self.compare_generation then
      if code == 0 then
        row.direct_status = "same"
      elseif code == 1 then
        row.direct_status = "different"
      else
        row.direct_status = "error"
      end
    end
    self:finish_compare_job(generation)
  end)
end

function Folder:run_digest_batch(batch, generation)
  local paths = {}
  for _, row in ipairs(batch or {}) do
    paths[#paths + 1] = row.left.path
    paths[#paths + 1] = row.right.path
  end
  local cmd = { self.backend.command }
  for _, arg in ipairs(self.backend.args or {}) do
    cmd[#cmd + 1] = arg
  end
  for _, path in ipairs(paths) do
    cmd[#cmd + 1] = path
  end

  run_async(cmd, function(code, stdout, stderr)
    if not self.disposed and generation == self.compare_generation then
      local digests = {}
      if code == 0 then
        if self.backend.parser == "md5sum_z" then
          digests = parse_md5sum_z(stdout)
        elseif self.backend.parser == "line_order" then
          digests = parse_line_order(stdout, paths)
        else
          digests = parse_digest_lines(stdout)
        end
      end
      for _, row in ipairs(batch or {}) do
        local left_digest = digests[row.left.path]
        local right_digest = digests[row.right.path]
        if code ~= 0 or not left_digest or not right_digest then
          row.direct_status = "error"
          row.error = vim.trim(stderr or "") ~= "" and vim.trim(stderr or "") or "digest command failed"
        else
          row.direct_status = left_digest == right_digest and "same" or "different"
          local left_key = cache_key(row.left)
          local right_key = cache_key(row.right)
          if left_key then
            self.digest_cache[left_key] = left_digest
          end
          if right_key then
            self.digest_cache[right_key] = right_digest
          end
        end
      end
    end
    self:finish_compare_job(generation)
  end)
end

function Folder:setup_autocmds()
  local augroup = vim.api.nvim_create_augroup("DiffBanditFolder" .. tostring(self.id), { clear = true })
  self.autocmd_group = augroup
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function(event)
      if tonumber(event.file) == self.tabnr then
        self:dispose()
      end
    end,
  })
  for _, buf in ipairs({ self.left_buf, self.gutter_buf, self.right_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = augroup,
      buffer = buf,
      callback = function()
        self:dispose()
      end,
    })
  end
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = augroup,
    callback = function()
      if not self.disposed then
        self:resize_layout()
        self:render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      if not self.disposed then
        self:redirect_gutter_focus()
      end
    end,
  })
end

function Folder:setup_keymaps()
  local opts = { nowait = true, noremap = true, silent = true }
  local keys = folder_config(self).keys or {}
  local function map(buf, lhs, rhs)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { buffer = buf }))
    end
  end
  local function maps(buf)
    map(buf, keys.open or "<CR>", function()
      self:open_selected()
    end)
    map(buf, keys.alternate_open or "o", function()
      self:open_selected()
    end)
    map(buf, keys.toggle_expand or "<Space>", function()
      self:toggle_expand()
    end)
    map(buf, keys.alternate_toggle_expand or "za", function()
      self:toggle_expand()
    end)
    map(buf, keys.expand_all or "zR", function()
      self:expand_all()
    end)
    map(buf, keys.collapse_all or "zM", function()
      self:collapse_all()
    end)
    map(buf, keys.next_diff or "]c", function()
      self:goto_diff(1)
    end)
    map(buf, keys.prev_diff or "[c", function()
      self:goto_diff(-1)
    end)
    map(buf, keys.refresh or "R", function()
      self:refresh()
    end)
    map(buf, keys.filter or "s", function()
      self:select_filter()
    end)
    map(buf, keys.close or "q", function()
      self:close()
    end)
    map(buf, "<C-w>l", function()
      if self.right_win and vim.api.nvim_win_is_valid(self.right_win) then
        vim.api.nvim_set_current_win(self.right_win)
      end
    end)
    map(buf, "<C-w>h", function()
      if self.left_win and vim.api.nvim_win_is_valid(self.left_win) then
        vim.api.nvim_set_current_win(self.left_win)
      end
    end)
  end
  maps(self.left_buf)
  maps(self.right_buf)
end

function Folder:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.compare_generation = self.compare_generation + 1
  state.unregister(self.tabpage)
  if self.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
    self.autocmd_group = nil
  end
end

function Folder:close()
  if self.disposed then
    return
  end
  if self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
    local current = vim.api.nvim_get_current_tabpage()
    pcall(vim.api.nvim_set_current_tabpage, self.tabpage)
    pcall(vim.cmd, "tabclose")
    if current and vim.api.nvim_tabpage_is_valid(current) then
      pcall(vim.api.nvim_set_current_tabpage, current)
    end
  else
    self:dispose()
  end
end

Folder._private = {
  scan_tree = folder_model.scan_tree,
  build_rows = folder_model.build_rows,
  recompute_aggregate = folder_model.recompute_aggregate,
  detect_backend = detect_backend,
  parse_md5sum_z = parse_md5sum_z,
  parse_digest_lines = parse_digest_lines,
  parse_line_order = parse_line_order,
}

return Folder
