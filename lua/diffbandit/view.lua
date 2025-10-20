local M = {}

local function pad_connector(str, width)
  local display = vim.fn.strdisplaywidth(str)
  if display >= width then
    return str
  end
  return str .. string.rep(" ", width - display)
end

local function placeholder_line(char)
  if not char or char == "" then
    return ""
  end
  return string.rep(char, 3)
end

local function connector_for(chunk_type, position, total, cfg, width)
  local shapes = cfg[chunk_type] or cfg.change
  if not shapes then
    return pad_connector(cfg.context or "", width)
  end

  local key
  if total <= 1 then
    key = "single"
  elseif position == 1 then
    key = "start"
  elseif position == total then
    key = "finish"
  else
    key = "mid"
  end

  local value = shapes[key] or cfg.context or ""
  return pad_connector(value, width)
end

function M.build(left_lines, right_lines, hunks, config)
  local connector_width = config.ui.connector_width or 3
  local connectors_cfg = config.ui.connectors or {}

  local left_view, right_view, connector_view, line_meta = {}, {}, {}, {}
  local chunks = {}

  local prev_a_end = 0
  local prev_b_end = 0

  local function add_line(left_text, right_text, connector_text, meta)
    local skip_left = meta.filler_left and meta.kind == "add"
    local skip_right = meta.filler_right and meta.kind == "delete"

    local left_index
    if skip_left then
      left_index = (#left_view > 0) and #left_view or nil
    else
      left_view[#left_view + 1] = left_text
      left_index = #left_view
    end

    local right_index
    if skip_right then
      right_index = (#right_view > 0) and #right_view or nil
    else
      right_view[#right_view + 1] = right_text
      right_index = #right_view
    end

    connector_view[#connector_view + 1] = pad_connector(connector_text or connectors_cfg.context or "", connector_width)
    line_meta[#line_meta + 1] = meta

    meta.left_index = left_index
    meta.right_index = right_index
  end

  local function next_placeholder()
    return placeholder_line(config.ui.placeholder_char)
  end

  for _, h in ipairs(hunks) do
    local context_a_start = prev_a_end + 1
    local context_a_end = h.left.start - 1
    if h.type == "add" then
      context_a_end = h.left.start
    end

    local context_b_start = prev_b_end + 1
    local context_b_end = h.right.start - 1
    if h.type == "delete" then
      context_b_end = h.right.start
    end

    if context_a_end < context_a_start then
      context_a_end = context_a_start - 1
    end
    if context_b_end < context_b_start then
      context_b_end = context_b_start - 1
    end

    local a_idx = context_a_start
    local b_idx = context_b_start

    while a_idx <= context_a_end or b_idx <= context_b_end do
      local left_text = a_idx <= context_a_end and (left_lines[a_idx] or "") or ""
      local right_text = b_idx <= context_b_end and (right_lines[b_idx] or "") or ""
      local left_line_num = a_idx <= context_a_end and a_idx or nil
      local right_line_num = b_idx <= context_b_end and b_idx or nil

      if a_idx <= context_a_end then
        a_idx = a_idx + 1
      end
      if b_idx <= context_b_end then
        b_idx = b_idx + 1
      end

      add_line(left_text, right_text, connectors_cfg.context or "", {
        kind = "context",
        chunk = nil,
        left_line = left_line_num,
        right_line = right_line_num,
        filler_left = false,
        filler_right = false,
      })
    end

    local chunk = {
      index = h.index,
      type = h.type,
      display_start = #line_meta + 1,
      left = {
        start = h.left.start,
        finish = h.left.start + h.left.count - 1,
      },
      right = {
        start = h.right.start,
        finish = h.right.start + h.right.count - 1,
      },
    }

    local max_lines = math.max(h.left.count, h.right.count)
    if max_lines == 0 then
      max_lines = 1
    end

    local left_line_idx = h.left.start
    local right_line_idx = h.right.start

    for i = 1, max_lines do
      -- Start with empty strings - only add placeholder for specific positions
      local left_text = ""
      local right_text = ""
      local left_line_num
      local right_line_num
      local filler_left = true
      local filler_right = true

      if i <= h.left.count then
        left_text = left_lines[left_line_idx] or ""
        left_line_num = left_line_idx
        left_line_idx = left_line_idx + 1
        filler_left = false
      else
        left_text = ""
      end

      if i <= h.right.count then
        right_text = right_lines[right_line_idx] or ""
        right_line_num = right_line_idx
        right_line_idx = right_line_idx + 1
        filler_right = false
      else
        right_text = ""
      end

      local connector_text = connector_for(h.type, i, max_lines, connectors_cfg, connector_width)

      add_line(left_text, right_text, connector_text, {
        kind = h.type,
        chunk = h.index,
        left_line = left_line_num,
        right_line = right_line_num,
        filler_left = filler_left,
        filler_right = filler_right,
        position = i,
        total = max_lines,
      })
    end

    chunk.display_end = #line_meta

    if chunk.type == "add" and chunk.display_start > 1 then
      connector_view[chunk.display_start - 1] = pad_connector(connectors_cfg.origin_add or connectors_cfg.context or "", connector_width)
      local meta = line_meta[chunk.display_start - 1]
      if meta then
        meta.origin = "add"
      end
    elseif chunk.type == "delete" and chunk.display_start > 1 then
      connector_view[chunk.display_start - 1] = pad_connector(connectors_cfg.origin_delete or connectors_cfg.context or "", connector_width)
      local meta = line_meta[chunk.display_start - 1]
      if meta then
        meta.origin = "delete"
      end
    end

    chunks[#chunks + 1] = chunk

    if h.left.count > 0 then
      prev_a_end = h.left.start + h.left.count - 1
    else
      prev_a_end = h.left.start
    end

    if h.right.count > 0 then
      prev_b_end = h.right.start + h.right.count - 1
    else
      prev_b_end = h.right.start
    end
  end

  local a_idx = prev_a_end + 1
  local b_idx = prev_b_end + 1

  while a_idx <= #left_lines or b_idx <= #right_lines do
    local left_text = a_idx <= #left_lines and left_lines[a_idx] or ""
    local right_text = b_idx <= #right_lines and right_lines[b_idx] or ""
    local left_line_num = a_idx <= #left_lines and a_idx or nil
    local right_line_num = b_idx <= #right_lines and b_idx or nil

    if a_idx <= #left_lines then
      a_idx = a_idx + 1
    end

    if b_idx <= #right_lines then
      b_idx = b_idx + 1
    end

    add_line(left_text, right_text, connectors_cfg.context or "", {
      kind = "context",
      chunk = nil,
      left_line = left_line_num,
      right_line = right_line_num,
      filler_left = false,
      filler_right = false,
    })
  end

  return {
    left = left_view,
    right = right_view,
    connectors = connector_view,
    line_meta = line_meta,
    chunks = chunks,
  }
end

return M
