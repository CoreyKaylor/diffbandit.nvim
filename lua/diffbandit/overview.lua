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

local function overview_config(config)
  return (((config or {}).ui or {}).overview or {})
end

function M.enabled(config)
  return overview_config(config).enabled ~= false
end

function M.width(config)
  return math.max(1, tonumber(overview_config(config).width) or 1)
end

local function cursor_enabled(config)
  return overview_config(config).cursor ~= false
end

local function row_for_line(line, line_count, height)
  line_count = math.max(1, tonumber(line_count) or 1)
  height = math.max(1, tonumber(height) or 1)
  line = math.max(1, math.min(line_count, tonumber(line) or 1))
  return math.max(1, math.min(height, math.floor(((line - 1) * height) / line_count) + 1))
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

function M.project_marks(marks, line_count, height)
  local rows = {}
  for _, mark in ipairs(marks or {}) do
    local row = row_for_line(mark.line, line_count, height)
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
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

function M.render_side_with_marks(buf, namespace, marks, line_count, height, cursor_line, current_chunk, config)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  local width = M.width(config)
  height = math.max(1, tonumber(height) or 1)
  set_lines(buf, height, width)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  for row = 1, height do
    vim.api.nvim_buf_add_highlight(buf, namespace, "DiffBanditOverviewContext", row - 1, 0, -1)
  end

  local rows = M.project_marks(marks, line_count, height)
  for row, mark in pairs(rows) do
    local hl = KIND_HIGHLIGHTS[mark.kind]
    if hl then
      vim.api.nvim_buf_add_highlight(buf, namespace, hl, row - 1, 0, -1)
    end
  end

  if cursor_enabled(config) and cursor_line then
    local cursor_row = row_for_line(cursor_line, line_count, height)
    vim.api.nvim_buf_set_extmark(buf, namespace, cursor_row - 1, 0, {
      end_row = cursor_row - 1,
      end_col = math.max(1, width),
      hl_group = "DiffBanditOverviewCursor",
      hl_mode = "combine",
      priority = 9000,
    })
  end
end

function M.render_side(buf, namespace, view, side, line_count, height, cursor_line, current_chunk, config)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  local marks = M.build_marks(view, side, current_chunk)
  M.render_side_with_marks(buf, namespace, marks, line_count, height, cursor_line, current_chunk, config)
end

M._private = {
  row_for_line = row_for_line,
  mark_for_meta = mark_for_meta,
  should_replace = should_replace,
}

return M
