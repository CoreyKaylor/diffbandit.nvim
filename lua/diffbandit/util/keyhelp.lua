-- In-view key help (the help key, g? by default).
--
-- Every DiffBandit mapping carries a `desc` ("DiffBandit: <action>") so the
-- mappings explain themselves in :map, which-key, and keymap pickers. The help
-- window lists the *live* mappings of the buffer it opens from, so remapped,
-- disabled, or context-dependent keys always match what pressing them does.
-- A per-buffer registry only adds the section each description belongs to.
local M = {}

M.PREFIX = "DiffBandit: "

-- Section order in the help window; unknown sections sort after these.
M.SECTIONS = {
  "General",
  "Navigation",
  "Hunks",
  "Files",
  "Commits",
  "Staging and actions",
  "Merge",
  "Layout",
  "Panel",
  "Commit",
  "Folder",
  "Log",
}

local section_rank = {}
for index, name in ipairs(M.SECTIONS) do
  section_rank[name] = index
end

-- tags[buf][desc] = { section = string, order = integer }
local tags = {}
local order_seq = 0
local cleanup_group

local function ensure_cleanup()
  if cleanup_group then
    return
  end
  cleanup_group = vim.api.nvim_create_augroup("DiffBanditKeyHelp", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = cleanup_group,
    callback = function(args)
      tags[args.buf] = nil
    end,
  })
end

-- Returns `opts` extended with a DiffBandit description, and records which
-- help section the mapping belongs to. Use for every DiffBandit mapping:
--   vim.keymap.set("n", lhs, rhs, keyhelp.opts(buf, "Hunks", "Next hunk", base))
function M.opts(buf, section, desc, base)
  local opts = vim.tbl_extend("force", {}, base or {})
  if desc and desc ~= "" then
    opts.desc = M.PREFIX .. desc
    if buf and buf ~= 0 then
      ensure_cleanup()
      tags[buf] = tags[buf] or {}
      if not tags[buf][desc] then
        order_seq = order_seq + 1
        tags[buf][desc] = { section = section or "General", order = order_seq }
      end
    end
  end
  return opts
end

-- nvim_buf_get_keymap reports a space as " " and "<" as "<lt>".
local function display_lhs(lhs)
  return (lhs:gsub(" ", "<Space>"):gsub("<lt>", "<"))
end

-- The DiffBandit mappings currently active in `buf`, grouped into sections:
--   { { name = "Hunks", rows = { { keys = "]c", desc = "Next hunk" }, ... } }, ... }
-- Keys sharing a description collapse into one row ("<CR>, o"). `order`
-- optionally lists section names to put first (e.g. "Files" in the panel).
function M.sections(buf, order)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return {}
  end
  local buf_tags = tags[buf] or {}
  local rows_by_desc = {}
  local rows = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    local desc = map.desc
    if desc and desc:sub(1, #M.PREFIX) == M.PREFIX then
      desc = desc:sub(#M.PREFIX + 1)
      local row = rows_by_desc[desc]
      if row then
        row.keys[#row.keys + 1] = display_lhs(map.lhs)
      else
        local tag = buf_tags[desc] or {}
        row = {
          desc = desc,
          keys = { display_lhs(map.lhs) },
          section = tag.section or "General",
          order = tag.order or math.huge,
        }
        rows_by_desc[desc] = row
        rows[#rows + 1] = row
      end
    end
  end
  local rank = vim.tbl_extend("force", {}, section_rank)
  for index, name in ipairs(order or {}) do
    rank[name] = index - #(order or {}) - 1
  end
  table.sort(rows, function(a, b)
    local ra = rank[a.section] or math.huge
    local rb = rank[b.section] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    if a.section ~= b.section then
      return a.section < b.section
    end
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.desc < b.desc
  end)
  local sections = {}
  local current
  for _, row in ipairs(rows) do
    if not current or current.name ~= row.section then
      current = { name = row.section, rows = {} }
      sections[#sections + 1] = current
    end
    table.sort(row.keys)
    current.rows[#current.rows + 1] = { keys = table.concat(row.keys, ", "), desc = row.desc }
  end
  return sections
end

-- "g? help": the short, muted hint DiffBandit headers show.
function M.hint(help_key)
  if not help_key or help_key == "" then
    return nil
  end
  return help_key .. " help"
end

-- Right-aligned hint text on `row` of `buf`, for header rows that are real
-- buffer lines (panel, folder diff, log) rather than header windows. `hl`
-- defaults to Comment; pass the header group for rows drawn as a bar.
function M.place_hint(buf, ns, row, text, hl)
  if not (text and text ~= "" and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row or 0, 0, {
    virt_text = { { text, hl or "Comment" } },
    virt_text_pos = "right_align",
    hl_mode = "combine",
  })
end

local help_ns = vim.api.nvim_create_namespace("DiffBanditKeyHelpWindow")
local open_help

local function close_help()
  local help = open_help
  open_help = nil
  if help and help.win and vim.api.nvim_win_is_valid(help.win) then
    pcall(vim.api.nvim_win_close, help.win, true)
  end
end

local function build_lines(sections, notes, footer)
  local key_width = 0
  for _, section in ipairs(sections) do
    for _, row in ipairs(section.rows) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(row.keys))
    end
  end
  for _, note in ipairs(notes or {}) do
    for _, row in ipairs(note.rows or {}) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(row.keys))
    end
  end
  key_width = math.min(key_width, 24)

  local lines, marks = {}, {}
  local function add_heading(text)
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = " " .. text
    marks[#marks + 1] = { row = #lines - 1, col = 1, end_col = #lines[#lines], hl = "Title" }
  end
  local function add_row(keys, desc)
    local pad = string.rep(" ", math.max(1, key_width - vim.fn.strdisplaywidth(keys) + 2))
    local line = "   " .. keys .. pad .. desc .. " "
    lines[#lines + 1] = line
    marks[#marks + 1] = { row = #lines - 1, col = 3, end_col = 3 + #keys, hl = "Special" }
  end

  for _, section in ipairs(sections) do
    add_heading(section.name)
    for _, row in ipairs(section.rows) do
      add_row(row.keys, row.desc)
    end
  end
  for _, note in ipairs(notes or {}) do
    add_heading(note.title)
    for _, row in ipairs(note.rows or {}) do
      add_row(row.keys, row.desc)
    end
  end
  if #sections == 0 and #(notes or {}) == 0 then
    lines[#lines + 1] = " No DiffBandit keys in this window."
  end
  for _, text in ipairs(footer or {}) do
    if text == footer[1] then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = " " .. text
    marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], hl = "Comment" }
  end
  return lines, marks
end

-- Open the help window for `buf` (default: the current buffer).
--   opts.title   context shown in the border ("Diff", "Commit panel", ...)
--   opts.notes   extra sections: { { title = "Header", rows = { { keys, desc } } } }
--   opts.help_key the key that opened the window (also closes it)
--   opts.order   section names to list first (see M.sections)
-- Pressing the help key while the window is open closes it.
function M.open(buf, opts)
  opts = opts or {}
  buf = buf or vim.api.nvim_get_current_buf()
  if open_help and open_help.win and vim.api.nvim_win_is_valid(open_help.win) then
    close_help()
    return nil
  end

  local footer = {
    "Commands: :DiffBanditClose closes this view, :help diffbandit for everything.",
    "q or <Esc> closes this window.",
  }
  -- A note titled like a key section joins it (":w" under "Commit").
  local sections = M.sections(buf, opts.order)
  local by_name = {}
  for _, section in ipairs(sections) do
    by_name[section.name] = section
  end
  local notes = {}
  for _, note in ipairs(opts.notes or {}) do
    local section = by_name[note.title]
    if section then
      vim.list_extend(section.rows, note.rows or {})
    else
      notes[#notes + 1] = note
    end
  end
  local lines, marks = build_lines(sections, notes, footer)

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(30, math.min(width + 1, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))

  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, help_buf, help_ns, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
    })
  end
  for name, value in pairs({ modifiable = false, bufhidden = "wipe", filetype = "diffbandit-help" }) do
    pcall(vim.api.nvim_set_option_value, name, value, { buf = help_buf })
  end

  local title = " DiffBandit keys" .. (opts.title and (": " .. opts.title) or "") .. " "
  local win = vim.api.nvim_open_win(help_buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    zindex = 250,
  })
  pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })
  pcall(vim.api.nvim_set_option_value, "wrap", false, { win = win })
  open_help = { win = win, buf = help_buf }

  local map_opts = { buffer = help_buf, nowait = true, noremap = true, silent = true }
  for _, lhs in ipairs({ "q", "<Esc>", opts.help_key }) do
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, close_help, map_opts)
    end
  end
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = help_buf,
    once = true,
    callback = function()
      vim.schedule(close_help)
    end,
  })
  return win
end

function M.is_open()
  return open_help ~= nil and open_help.win ~= nil and vim.api.nvim_win_is_valid(open_help.win)
end

M.close = close_help

return M
