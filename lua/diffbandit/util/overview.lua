-- Overview strip helpers shared by every minimap (diff view gutters and
-- editor-buffer minimaps): projection, overlays and the cell renderer.
-- Option arguments (`opts`) are an overview options table — the diff view
-- passes config.ui.overview, editor minimaps pass config.minimap.
local M = {}

local KIND_PRIORITY = {
  delete = 1,
  add = 2,
  change = 3,
}

local SIDE_KINDS = {
  left = {
    delete = true,
    change = true,
  },
  right = {
    add = true,
    change = true,
  },
}

local KIND_HIGHLIGHTS = {
  add = "DiffBanditOverviewAdd",
  delete = "DiffBanditOverviewDelete",
  change = "DiffBanditOverviewChange",
}

local function overview_config(opts)
  return opts or {}
end

function M.enabled(opts)
  return overview_config(opts).enabled ~= false
end

--- Overview width in cells. The code-shape image (ui.overview.code_shape)
--- is wider; it applies only when the overview is drawn as an image.
function M.width(opts, renderer)
  local cfg = overview_config(opts)
  if renderer == "kitty" and cfg.code_shape == true then
    return math.max(2, tonumber(cfg.code_width) or 12)
  end
  return math.max(1, tonumber(cfg.width) or 1)
end

local function cursor_enabled(opts)
  return overview_config(opts).cursor ~= false
end
M.cursor_enabled = cursor_enabled

function M.viewport_enabled(opts)
  return overview_config(opts).viewport ~= false
end

function M.search_enabled(opts)
  return overview_config(opts).search ~= false
end

function M.selection_enabled(opts)
  return overview_config(opts).selection ~= false
end

function M.mouse_enabled(opts)
  return overview_config(opts).mouse ~= false
end

--- Whether the code-shape image is active for this renderer.
function M.code_shape(opts, renderer)
  return renderer == "kitty" and overview_config(opts).code_shape == true
end

--- "kitty" when the overview should be drawn as an image for a host whose
--- connector renderer is `connector_renderer`, else "cells".
--- ui.overview.renderer = "auto" (follow the connector) | "cells".
function M.renderer(opts, connector_renderer)
  if overview_config(opts).renderer == "cells" then
    return "cells"
  end
  return connector_renderer == "kitty" and "kitty" or "cells"
end

--- Minimum reduction factor: source lines per overview row. Files shorter
--- than rows x factor are not stretched to fill the strip; they take the top
--- of it at that scale. ui.overview.min_reduction = number, or nil ("auto":
--- 0 = always fill for the hunk overview; for code shape, the factor that
--- draws characters twice as tall as wide, like VS Code's minimap).
--- cell = { w, h } pixels and char_px are only used for code shape.
function M.min_reduction(opts, code_shape, cell, char_px)
  local value = tonumber(overview_config(opts).min_reduction)
  if value then
    return math.max(0, value)
  end
  if code_shape and cell then
    return (cell.h or cell[2] or 20) / (2 * math.max(1, char_px or 1))
  end
  return 0
end

--- Lines the full strip height represents: the line count, or more when
--- the minimum reduction keeps a short file from stretching.
function M.map_lines(line_count, height, min_reduction)
  line_count = math.max(1, tonumber(line_count) or 1)
  return math.max(line_count, math.max(1, height or 1) * (min_reduction or 0))
end

-- `map_lines` is the number of lines the full strip represents (the line
-- count, unless a minimum reduction applies).
local function row_for_line(line, map_lines, height)
  map_lines = math.max(1, tonumber(map_lines) or 1)
  height = math.max(1, tonumber(height) or 1)
  line = math.max(1, math.min(map_lines, tonumber(line) or 1))
  return math.max(1, math.min(height, math.floor(((line - 1) * height) / map_lines) + 1))
end
M.row_for_line = row_for_line

--- Source line under overview row `row` (1-based): the line at the row's
--- middle, clamped to the document.
function M.line_for_row(row, line_count, map_lines, height)
  line_count = math.max(1, tonumber(line_count) or 1)
  map_lines = math.max(line_count, tonumber(map_lines) or line_count)
  height = math.max(1, tonumber(height) or 1)
  row = math.max(1, math.min(height, row))
  local line = math.floor((row - 0.5) * map_lines / height) + 1
  return math.max(1, math.min(line_count, line))
end

--- Overview rows [first, last] covered by the source line range
--- range = { first, last }, or nil.
function M.viewport_rows(range, line_count, height, map_lines)
  if not range or not range.first or not range.last then
    return nil
  end
  line_count = math.max(1, tonumber(line_count) or 1)
  map_lines = map_lines or line_count
  local first = math.max(1, math.min(line_count, math.min(range.first, range.last)))
  local last = math.max(first, math.min(line_count, math.max(range.first, range.last)))
  return row_for_line(first, map_lines, height), row_for_line(last, map_lines, height)
end

--- The active search pattern when its matches are highlighted ('hlsearch'
--- on and not suspended by :nohlsearch), else nil.
function M.active_search()
  if not vim.o.hlsearch or vim.v.hlsearch ~= 1 then
    return nil
  end
  local pattern = vim.fn.getreg("/")
  if type(pattern) ~= "string" or pattern == "" then
    return nil
  end
  return pattern
end

--- Lines (1-based) of `lines` matching the Vim regex `pattern`, honouring
--- 'ignorecase' and 'smartcase' like / does. Invalid patterns match nothing.
function M.search_lines(lines, pattern)
  local out = {}
  if not pattern or pattern == "" then
    return out
  end
  -- vim.regex ignores 'ignorecase': pick the case mode explicitly, as /
  -- would, unless the pattern carries its own \c / \C.
  local pat = pattern
  if not pat:find("\\[cC]") then
    local ignore = vim.o.ignorecase
    if ignore and vim.o.smartcase then
      -- Uppercase outside an escape makes the search case-sensitive.
      local stripped = pat:gsub("\\.", "")
      ignore = not stripped:find("%u")
    end
    pat = (ignore and "\\c" or "\\C") .. pat
  end
  local ok, re = pcall(vim.regex, pat)
  if not ok or not re then
    return out
  end
  for i, line in ipairs(lines or {}) do
    local okm, s = pcall(re.match_str, re, line)
    if okm and s then
      out[#out + 1] = i
    end
  end
  return out
end

local function mark_for_meta(meta, side)
  if not meta or not SIDE_KINDS[side] or not SIDE_KINDS[side][meta.kind] then
    return nil
  end
  if side == "left" then
    if meta.left_index and not meta.filler_left then
      return meta.left_index
    end
  elseif side == "right" then
    if meta.right_index and not meta.filler_right then
      return meta.right_index
    end
  end
  return nil
end

function M.build_marks(view, side, current_chunk)
  local marks = {}
  for _, meta in ipairs((view or {}).line_meta or {}) do
    local line = mark_for_meta(meta, side)
    if line then
      marks[#marks + 1] = {
        line = line,
        kind = meta.kind,
        current = current_chunk and meta.chunk == current_chunk or false,
      }
    end
  end
  return marks
end

local function should_replace(existing, next_mark)
  if not existing then
    return true
  end
  if next_mark.current and not existing.current then
    return true
  end
  if existing.current and not next_mark.current then
    return false
  end
  return (KIND_PRIORITY[next_mark.kind] or 0) > (KIND_PRIORITY[existing.kind] or 0)
end

function M.project_marks(marks, map_lines, height)
  local rows = {}
  for _, mark in ipairs(marks or {}) do
    local row = row_for_line(mark.line, map_lines, height)
    if should_replace(rows[row], mark) then
      rows[row] = {
        kind = mark.kind,
        current = mark.current,
      }
    end
  end
  return rows
end

local function set_lines(buf, height, width)
  local lines = {}
  local text = string.rep(" ", math.max(1, width or 1))
  for i = 1, math.max(1, height or 1) do
    lines[i] = text
  end
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
end

--- Row-level overlays shared by the cell and image overviews:
--- { band = {first,last}?, selection = {first,last}?, cursor_row?,
---   search_rows = { [row] = true } }. `state` is render_side's input.
function M.row_overlays(state, opts)
  local height = math.max(1, tonumber(state.height) or 1)
  local map_lines = state.map_lines or M.map_lines(state.line_count, height, 0)
  local out = { search_rows = {} }
  if M.viewport_enabled(opts) then
    local first, last = M.viewport_rows(state.viewport, state.line_count, height, map_lines)
    out.band = first and { first = first, last = last } or nil
  end
  if M.selection_enabled(opts) then
    local first, last = M.viewport_rows(state.selection, state.line_count, height, map_lines)
    out.selection = first and { first = first, last = last } or nil
  end
  if cursor_enabled(opts) and state.cursor_line then
    out.cursor_row = row_for_line(state.cursor_line, map_lines, height)
  end
  for _, line in ipairs(state.search_lines or {}) do
    out.search_rows[row_for_line(line, map_lines, height)] = true
  end
  -- Most severe diagnostic per row (1 = error .. 4 = hint).
  out.diagnostic_rows = {}
  for _, d in ipairs(state.diagnostics or {}) do
    local row = row_for_line(d.line, map_lines, height)
    local cur = out.diagnostic_rows[row]
    if not cur or d.severity < cur then
      out.diagnostic_rows[row] = d.severity
    end
  end
  return out
end

M.DIAGNOSTIC_HIGHLIGHTS = {
  "DiffBanditOverviewDiagError",
  "DiffBanditOverviewDiagWarn",
  "DiffBanditOverviewDiagInfo",
  "DiffBanditOverviewDiagHint",
}

--- Diagnostics of `buf` as { line, severity } (1-based lines), at least as
--- severe as `min_severity` (vim.diagnostic.severity value or name).
function M.buffer_diagnostics(buf, min_severity)
  local sev = min_severity
  if type(sev) == "string" then
    sev = vim.diagnostic.severity[sev:upper()]
  end
  sev = tonumber(sev) or vim.diagnostic.severity.HINT
  local ok, items = pcall(vim.diagnostic.get, buf, { severity = { min = sev } })
  local out = {}
  if not ok then
    return out
  end
  for _, d in ipairs(items) do
    out[#out + 1] = { line = (d.lnum or 0) + 1, severity = d.severity or 1 }
  end
  table.sort(out, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.severity < b.severity
  end)
  return out
end

local function in_range(range, row)
  return range ~= nil and row >= range.first and row <= range.last
end
M.in_range = in_range

--- Paint the cell overview. state = { marks, line_count, height,
--- map_lines?, cursor_line?, viewport = {first,last}?,
--- selection = {first,last}?, search_lines?, diagnostics? }.
--- Marks win a row's background; elsewhere the visual selection, then the
--- viewport band, show. Search matches are a right-half block over
--- whatever sits on the row; the cursor row is underlined.
function M.render_side(buf, namespace, state, opts)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local width = M.width(opts)
  local height = math.max(1, tonumber(state.height) or 1)
  local map_lines = state.map_lines or M.map_lines(state.line_count, height, 0)
  set_lines(buf, height, width)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  local overlays = M.row_overlays(vim.tbl_extend("force", state, { height = height, map_lines = map_lines }), opts)
  for row = 1, height do
    local hl = "DiffBanditOverviewContext"
    if in_range(overlays.selection, row) then
      hl = "DiffBanditOverviewSelection"
    elseif in_range(overlays.band, row) then
      hl = "DiffBanditOverviewViewport"
    end
    vim.api.nvim_buf_add_highlight(buf, namespace, hl, row - 1, 0, -1)
  end

  local rows = M.project_marks(state.marks, map_lines, height)
  for row, mark in pairs(rows) do
    local hl = KIND_HIGHLIGHTS[mark.kind]
    if hl then
      vim.api.nvim_buf_add_highlight(buf, namespace, hl, row - 1, 0, -1)
    end
  end

  -- One cell per row: a diagnostic (left-half block, severity colour) wins
  -- over a search match (right-half block) on the same row.
  for row in pairs(overlays.search_rows) do
    if not overlays.diagnostic_rows[row] then
      vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, width - 1, {
        virt_text = { { "▐", "DiffBanditOverviewSearch" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 8000,
      })
    end
  end
  for row, sev in pairs(overlays.diagnostic_rows) do
    vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
      virt_text = { { "▌", M.DIAGNOSTIC_HIGHLIGHTS[sev] or M.DIAGNOSTIC_HIGHLIGHTS[1] } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 8100,
    })
  end

  if overlays.cursor_row then
    vim.api.nvim_buf_set_extmark(buf, namespace, overlays.cursor_row - 1, 0, {
      end_row = overlays.cursor_row - 1,
      end_col = math.max(1, width),
      hl_group = "DiffBanditOverviewCursor",
      hl_mode = "combine",
      priority = 9000,
    })
  end
end

return M
