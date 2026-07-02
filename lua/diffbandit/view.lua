local connector_width = require("diffbandit.connector_width")

local M = {}

function M.build(left_lines, right_lines, hunks, config)
  local connector_core_width = connector_width.minimum(config)
  local blank_connector = string.rep(" ", connector_core_width)

  local left_view, right_view, connector_view, line_meta = {}, {}, {}, {}
  local chunks = {}

  local prev_a_end = 0
  local prev_b_end = 0

  local function add_line(left_text, right_text, meta)
    -- Only add actual content lines to each buffer
    -- Filler rows exist only in connector view for alignment
    local left_index = nil
    local right_index = nil

    -- Add to left buffer if not a filler (empty lines are valid content)
    if not meta.filler_left then
      left_view[#left_view + 1] = left_text or ""
      left_index = #left_view
    end

    -- Add to right buffer if not a filler (empty lines are valid content)
    if not meta.filler_right then
      right_view[#right_view + 1] = right_text or ""
      right_index = #right_view
    end

    -- Connector always has full aligned view
    connector_view[#connector_view + 1] = blank_connector
    line_meta[#line_meta + 1] = meta

    meta.left_index = left_index
    meta.right_index = right_index
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

      add_line(left_text, right_text, {
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
      local left_text
      local right_text
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

      -- Reclassify extra rows inside change hunks as add/delete so
      -- right-only rows get proper green backgrounds and left-only rows get delete.
      local kind = h.type
      if h.type == "change" then
        if i > h.left.count and i <= h.right.count then
          kind = "add"
        elseif i > h.right.count and i <= h.left.count then
          kind = "delete"
        end
      end

      -- Keep change classification at the line level; intra-line coloring decides blue/green mix.
      -- Connector glyphs are rendered from route paths in session.lua.
      add_line(left_text, right_text, {
        kind = kind,
        chunk = h.index,
        left_line = left_line_num,
        right_line = right_line_num,
        filler_left = filler_left,
        filler_right = filler_right,
      })
    end

    chunk.display_end = #line_meta

    -- Mark origin rows for session.lua to render underlines.
    -- For mixed hunks (change hunks that contain add/delete rows), mark origins
    -- for each contiguous add/delete segment.
    if chunk.display_start > 1 then
      local i = chunk.display_start
      while i <= chunk.display_end do
        local m = line_meta[i]
        local k = m and m.kind
        if k == "add" or k == "delete" then
          if i > 1 then
            local origin_meta = line_meta[i - 1]
            if origin_meta and not origin_meta.origin then
              origin_meta.origin = k
            end
          end
          local j = i + 1
          while j <= chunk.display_end and line_meta[j] and line_meta[j].kind == k do
            j = j + 1
          end
          i = j
        else
          i = i + 1
        end
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

    add_line(left_text, right_text, {
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
