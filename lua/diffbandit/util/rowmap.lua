-- Buffer line <-> screen row mapping for a source pane.
--
-- DiffBandit's gutters (number panes, connector core) are separate windows
-- that must stay row-for-row with their source pane. With 'wrap' (or
-- virtual lines) a buffer line can occupy several screen rows, so the gutters
-- work in "row space": row r is the r-th screen row the pane would show if it
-- were scrolled to the top. A RowMap converts between the two. Without
-- wrapping it is the identity (row == line), and every caller keeps the exact
-- line-space behaviour.
--
-- Representation is sparse: only lines taller than one row are stored, with
-- prefix sums of their extra rows, so a 500k-line file that wraps a handful
-- of lines costs a handful of entries. Lines past the buffer's end (gutters
-- carry scroll padding) are one row each.

local M = {}

local Map = {}
Map.__index = Map

local function new_map(n, tall_lines, tall_extra, version)
  local cum = {}
  local heights = {}
  local acc = 0
  for k = 1, #tall_lines do
    acc = acc + tall_extra[k]
    cum[k] = acc
    heights[tall_lines[k]] = tall_extra[k] + 1
  end
  return setmetatable({
    n = n,
    identity = #tall_lines == 0,
    lines = tall_lines,
    extra = tall_extra,
    cum = cum,
    heights = heights,
    extra_total = acc,
    version = version,
  }, Map)
end

local version_counter = 0
local function next_version()
  version_counter = version_counter + 1
  return version_counter
end

-- Shared identity instance for callers without a window.
local IDENTITY = new_map(0, {}, {}, 0)

function M.identity()
  return IDENTITY
end

-- Extra rows contributed by tall lines strictly above `line`.
function Map:extra_before(line)
  if self.identity then
    return 0
  end
  local lines = self.lines
  local lo, hi, ans = 1, #lines, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if lines[mid] < line then
      ans = self.cum[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return ans
end

function Map:height(line)
  if self.identity then
    return 1
  end
  return self.heights[line] or 1
end

function Map:first_row(line)
  if self.identity then
    return line
  end
  return line + self:extra_before(line)
end

function Map:last_row(line)
  if self.identity then
    return line
  end
  return self:first_row(line) + self:height(line) - 1
end

--- Rows covered by lines 1..`line_count`.
function Map:total_rows(line_count)
  return self:last_row(line_count)
end

--- The line shown on `row`, and the 0-based sub-row within it.
function Map:line_at_row(row)
  if self.identity or row < 1 then
    return row, 0
  end
  -- first_row is strictly increasing in line; bisect lines.
  local lo, hi = 1, math.max(1, row)
  local ans = 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self:first_row(mid) <= row then
      ans = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return ans, row - self:first_row(ans)
end

-- Options that change how many rows a line wraps into. Part of the cache
-- key, so `:set linebreak` and friends rebuild the map.
local WIN_OPTS = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak", "list", "listchars",
  "conceallevel", "concealcursor", "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn",
  "statuscolumn", "cursorlineopt" }
local BUF_OPTS = { "tabstop", "vartabstop" }

--- Option names whose change can move wrapped heights (OptionSet pattern).
M.HEIGHT_OPTIONS = {}
for _, name in ipairs(WIN_OPTS) do
  M.HEIGHT_OPTIONS[#M.HEIGHT_OPTIONS + 1] = name
end
for _, name in ipairs(BUF_OPTS) do
  M.HEIGHT_OPTIONS[#M.HEIGHT_OPTIONS + 1] = name
end
M.HEIGHT_OPTIONS[#M.HEIGHT_OPTIONS + 1] = "ambiwidth"
M.HEIGHT_OPTIONS[#M.HEIGHT_OPTIONS + 1] = "display"

--- Short identity of a window's current map (changes when it is rebuilt).
function M.version_of(win)
  local map = M.get(win)
  return map.identity and "id" or tostring(map.version)
end

local function text_area_width(win)
  local info = vim.fn.getwininfo(win)[1]
  local width = vim.api.nvim_win_get_width(win)
  if info and info.textoff then
    width = width - info.textoff
  end
  return math.max(1, width)
end

-- Without 'wrap' only virtual lines add rows, and those are independent of
-- width and options: the key is just the buffer state (cheap — it is
-- computed on every scroll sync).
local function cache_key(win, buf)
  local head = tostring(buf) .. "\31" .. tostring(vim.api.nvim_buf_get_changedtick(buf))
    .. "\31" .. tostring(vim.api.nvim_buf_line_count(buf))
  if not vim.api.nvim_get_option_value("wrap", { win = win }) then
    return head .. "\31nowrap"
  end
  local parts = {
    head,
    tostring(text_area_width(win)),
    vim.o.ambiwidth,
    vim.o.display,
  }
  for _, name in ipairs(WIN_OPTS) do
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = win })
    parts[#parts + 1] = ok and tostring(value) or ""
  end
  for _, name in ipairs(BUF_OPTS) do
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { buf = buf })
    parts[#parts + 1] = ok and tostring(value) or ""
  end
  return table.concat(parts, "\31")
end

local function text_height(win, start_row, end_row, start_vcol)
  local ok, res = pcall(vim.api.nvim_win_text_height, win, {
    start_row = start_row,
    end_row = end_row,
    start_vcol = start_vcol,
  })
  if ok and res then
    return res.all
  end
  return nil
end

-- Lines carrying inline virtual text or virtual lines can be taller than
-- their text suggests (inlay hints wrap, diagnostics add rows).
local function decorated_lines(buf)
  local set = {}
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, 0, -1, { details = true, type = "virt_lines" })
  for _, mark in ipairs(ok and marks or {}) do
    set[mark[2] + 1] = true
  end
  ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, 0, -1, { details = true, type = "virt_text" })
  for _, mark in ipairs(ok and marks or {}) do
    local details = mark[4] or {}
    if details.virt_text_pos == "inline" then
      set[mark[2] + 1] = true
    end
  end
  return set
end

local function measure(win, buf)
  local n = vim.api.nvim_buf_line_count(buf)
  local tall_lines, tall_extra = {}, {}
  local function probe(line)
    local h = text_height(win, line - 1, line - 1)
    if h and h > 1 then
      tall_lines[#tall_lines + 1] = line
      tall_extra[#tall_extra + 1] = h - 1
    end
  end

  local wrap = vim.api.nvim_get_option_value("wrap", { win = win })
  if not wrap then
    -- Only virtual lines can add rows; no whole-buffer scan.
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, 0, -1, { type = "virt_lines" })
    local seen = {}
    for _, mark in ipairs(ok and marks or {}) do
      local line = mark[2] + 1
      if not seen[line] and line <= n then
        seen[line] = true
      end
    end
    local sorted = vim.tbl_keys(seen)
    table.sort(sorted)
    for _, line in ipairs(sorted) do
      probe(line)
    end
    return new_map(n, tall_lines, tall_extra, next_version())
  end

  local total = text_height(win, 0, -1)
  if not total or total == n then
    return new_map(n, {}, {}, next_version())
  end

  -- Only some lines can be taller than one row. A line whose bytes are all
  -- printable occupies at most one cell per byte, so it cannot wrap while it
  -- is narrower than the text area; tabs and other control bytes can expand
  -- (up to 'tabstop' / 4 cells), and decorated lines can grow regardless.
  local width = text_area_width(win)
  local tabstop = vim.api.nvim_get_option_value("tabstop", { buf = buf })
  local max_cell = math.max(4, tonumber(tabstop) or 8)
  local decorated = decorated_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for line = 1, n do
    local candidate = decorated[line]
    if not candidate and lines then
      local text = lines[line]
      local len = #text
      if len >= width then
        candidate = true
      elseif len * max_cell >= width and text:find("[%c\128-\255]") then
        candidate = true
      end
    end
    if candidate then
      probe(line)
    end
  end

  -- The filter is a heuristic; the window's own total is the truth. When
  -- they disagree (an option the filter does not model), measure every line.
  local extra = 0
  for k = 1, #tall_extra do
    extra = extra + tall_extra[k]
  end
  if n + extra ~= total then
    tall_lines, tall_extra = {}, {}
    for line = 1, n do
      probe(line)
    end
  end
  return new_map(n, tall_lines, tall_extra, next_version())
end

-- Per-window cache: { key = cache_key, map = Map }.
local by_win = {}

--- Row map for the window's current buffer, rebuilt when the buffer text,
--- the text-area width, or a wrap-relevant option changes.
---
--- `opts.stale_ok` returns the last map for the same buffer without
--- re-measuring: scroll/cursor sync runs on every keystroke, and a wrapped
--- large file costs a full scan per text change. The next paint (which asks
--- for a fresh map) brings the gutters back in line with the edit.
function M.get(win, opts)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    by_win[win or 0] = nil
    return IDENTITY
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local entry = by_win[win]
  if entry and opts and opts.stale_ok and entry.buf == buf then
    return entry.map
  end
  local key = cache_key(win, buf)
  if entry and entry.key == key then
    return entry.map
  end
  local map = measure(win, buf)
  local wrap = vim.api.nvim_get_option_value("wrap", { win = win })
  by_win[win] = { key = key, map = map, buf = buf, width = wrap and text_area_width(win) or nil }
  return map
end

--- After a paint: true when a wrapped window's text area is no longer the
--- width its map was measured at. The paint's own band signs open a
--- 'signcolumn=auto' column, and Neovim only sizes that column when it
--- redraws the window, so it is validated here first; without that the
--- pane re-wraps on the next redraw under gutters already painted.
function M.width_changed_by_paint(win)
  local entry = win and by_win[win]
  if not (entry and entry.width and vim.api.nvim_win_is_valid(win))
      or vim.api.nvim_win_get_buf(win) ~= entry.buf then
    return false
  end
  local signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = win })
  if signcolumn:sub(1, 4) == "auto" and vim.api.nvim__redraw then
    pcall(vim.api.nvim__redraw, { win = win, valid = true })
  end
  return text_area_width(win) ~= entry.width
end

--- Drop the window's cached map (e.g. an extmark changed a line's height).
function M.invalidate(win)
  if win then
    by_win[win] = nil
  end
end

--- Check the visible lines against the map (decorations such as inlay hints
--- and virtual lines change heights without touching the text). Rebuilds and
--- returns the fresh map when they disagree.
function M.verified(win)
  local map = M.get(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return map
  end
  local ok, bounds = pcall(vim.api.nvim_win_call, win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  if not ok or not bounds then
    return map
  end
  local top, bot = bounds[1], bounds[2]
  if top < 1 or bot < top then
    return map
  end
  local actual = text_height(win, top - 1, bot - 1)
  local expected = map:last_row(bot) - map:first_row(top) + 1
  if actual and actual ~= expected then
    by_win[win] = nil
    return M.get(win)
  end
  return map
end

--- Screen-row topline of `win` under `map`: the first row of its topline,
--- plus rows a 'smoothscroll' skipcol hides of that line.
function M.topline_row(win, map)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return 1
  end
  map = map or M.get(win)
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if not ok or not view then
    return 1
  end
  local topline = math.max(1, view.topline or 1)
  local row = map:first_row(topline)
  local skipcol = view.skipcol or 0
  if skipcol > 0 and not map.identity then
    local rest = text_height(win, topline - 1, topline - 1, skipcol)
    if rest then
      row = row + math.max(0, map:height(topline) - rest)
    end
  end
  return row
end

--- Signature that changes whenever either map changes.
function M.signature(left_map, right_map)
  if left_map.identity and right_map.identity then
    return "id"
  end
  return tostring(left_map.version) .. ":" .. tostring(right_map.version)
end

--- Row-space copy of an aligned view (chunks + line_meta) for path building.
--- Each display row expands to as many rows as its taller side; the shorter
--- side repeats its last row so origin lookups (the row above a block) land
--- on the bottom row of the origin line. Returns the view itself when both
--- maps are identities.
function M.expand_view(view, left_map, right_map)
  if left_map.identity and right_map.identity then
    return view
  end
  local out_meta = {}
  local index_of = {}
  for i, meta in ipairs(view.line_meta or {}) do
    local lh = meta.left_index and left_map:height(meta.left_index) or 1
    local rh = meta.right_index and right_map:height(meta.right_index) or 1
    local lfirst = meta.left_index and left_map:first_row(meta.left_index)
    local rfirst = meta.right_index and right_map:first_row(meta.right_index)
    local rows = math.max(lh, rh)
    index_of[i] = { first = #out_meta + 1, last = #out_meta + rows }
    for j = 0, rows - 1 do
      local row_meta = {}
      for k, v in pairs(meta) do
        row_meta[k] = v
      end
      row_meta.left_index = lfirst and (lfirst + math.min(j, lh - 1)) or nil
      row_meta.right_index = rfirst and (rfirst + math.min(j, rh - 1)) or nil
      out_meta[#out_meta + 1] = row_meta
    end
  end
  local out_chunks = {}
  for k, chunk in ipairs(view.chunks or {}) do
    local copy = {}
    for key, v in pairs(chunk) do
      copy[key] = v
    end
    local s = index_of[chunk.display_start]
    local e = index_of[chunk.display_end]
    copy.display_start = s and s.first or chunk.display_start
    copy.display_end = e and e.last or chunk.display_end
    out_chunks[k] = copy
  end
  return { chunks = out_chunks, line_meta = out_meta }
end

M._private = { new_map = new_map }

return M
