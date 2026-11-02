-- Pure ribbon geometry for the image (Kitty graphics) connector renderer.
--
-- Models IntelliJ's diff divider (intellij-community
-- platform/diff-impl/.../util/DiffDividerDrawUtil.java + DiffDrawUtil.java):
-- every chunk is a polygon between the left range [start1, end1) and the right
-- range [start2, end2), drawn as two cubic curves (top edge, bottom edge)
-- filled between. Unlike the cell renderer there are no lanes or rails, so this
-- needs only document-stable base paths plus the two toplines.
--
-- Coordinates are SCREEN ROWS (0-based, fractional): a left buffer row `i`
-- starts at `i - left_topline`, a right row `j` at `j - right_topline`.
-- Offscreen extents keep their true (negative / beyond-height) values on
-- purpose — clamping would bend the curves; the rasterizer clips pixels.
--
-- Output sides are SCREEN sides: `l*` is the edge nearest the screen-left
-- number pane. Mirrored pairs (merge RemoteResult) swap the pair's sides.
local M = {}

-- DiffDrawUtil.CTRL_PROXIMITY_X: control points sit at 30% / 70% of the
-- divider width at the start / end heights.
M.CTRL_PROXIMITY_X = 0.3

local KIND_RANK = { change = 1, delete = 2, add = 3 }

-- Insertion boundary under an origin row. `origin` is the buffer row the
-- block attaches below (nil / 0 = top of file), so the boundary is the top
-- of the following row.
local function boundary_row(origin, topline)
  return (origin or 0) + 1 - topline
end

--- Build ribbons for the current viewport.
--- view = { left_topline, right_topline, rows, active_chunk, mirror }
--- Returns a list of { kind, chunk, active, lt, lb, rt, rb } in paint order
--- (inactive first, active last so its emphasis sits on top).
function M.ribbons(paths, view)
  local left_topline = view.left_topline or 1
  local right_topline = view.right_topline or 1
  local rows = view.rows or 0
  local active = view.active_chunk
  local out = {}

  local function push(kind, chunk, l_top, l_bot, r_top, r_bot)
    -- IntelliJ's culling: skip only when BOTH ranges sit entirely above or
    -- entirely below the painted interval. A chunk with one visible end and
    -- one far offscreen end still draws (it slopes off the edge).
    if l_bot <= 0 and r_bot <= 0 then
      return
    end
    if l_top >= rows and r_top >= rows then
      return
    end
    local ribbon = {
      kind = kind,
      chunk = chunk,
      active = active ~= nil and active > 0 and chunk == active or false,
    }
    if view.mirror then
      ribbon.lt, ribbon.lb, ribbon.rt, ribbon.rb = r_top, r_bot, l_top, l_bot
    else
      ribbon.lt, ribbon.lb, ribbon.rt, ribbon.rb = l_top, l_bot, r_top, r_bot
    end
    out[#out + 1] = ribbon
  end

  for _, p in ipairs(paths or {}) do
    if p.kind == "change" then
      if p.start_left_index and p.end_left_index and p.start_right_index and p.end_right_index then
        push("change", p.chunk,
          p.start_left_index - left_topline, p.end_left_index + 1 - left_topline,
          p.start_right_index - right_topline, p.end_right_index + 1 - right_topline)
      end
    elseif p.kind == "add" and not p.embedded_in_change then
      if p.target_start_index and p.target_end_index then
        local y = boundary_row(p.origin_left_index, left_topline)
        push("add", p.chunk, y, y,
          p.target_start_index - right_topline, p.target_end_index + 1 - right_topline)
      end
    elseif p.kind == "delete" and not p.embedded_in_change then
      if p.target_start_index and p.target_end_index then
        local y = boundary_row(p.origin_right_index, right_topline)
        push("delete", p.chunk,
          p.target_start_index - left_topline, p.target_end_index + 1 - left_topline,
          y, y)
      end
    end
  end

  table.sort(out, function(a, b)
    if a.active ~= b.active then
      return not a.active
    end
    if (a.chunk or 0) ~= (b.chunk or 0) then
      return (a.chunk or 0) < (b.chunk or 0)
    end
    return (KIND_RANK[a.kind] or 9) < (KIND_RANK[b.kind] or 9)
  end)
  return out
end

--- Stable dedupe key for a ribbon list quantized to device pixels.
function M.geometry_key(ribbons, cell_h)
  local parts = {}
  local q = cell_h or 1
  for i, r in ipairs(ribbons) do
    parts[i] = string.format("%s%d:%d,%d,%d,%d%s",
      r.kind:sub(1, 1), r.chunk or 0,
      math.floor(r.lt * q + 0.5), math.floor(r.lb * q + 0.5),
      math.floor(r.rt * q + 0.5), math.floor(r.rb * q + 0.5),
      r.active and "*" or "")
  end
  return table.concat(parts, ";")
end

return M
