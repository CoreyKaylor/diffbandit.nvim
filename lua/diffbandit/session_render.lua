-- The session render pipeline: builds display/number-pane text, applies
-- pane and connector backgrounds, intra-line change emphasis, origin
-- underlines, and connector route glyphs. Extracted from session.lua; every
-- stage takes the session as its first argument and renders into the
-- session's buffers and namespaces.
local nvim = require("diffbandit.nvim")
local paths_mod = require("diffbandit.connector_routes")
local diff_mod = require("diffbandit.diff")
local connector_width = require("diffbandit.connector_width")

local set_buffer_options = nvim.set_buffer_options
local get_win_view_topline = nvim.get_win_view_topline

local M = {}

local function format_line_number(num, width)
  if not num then
    return string.rep(" ", width)
  end
  local fmt = string.format("%%%dd", width)
  return string.format(fmt, num)
end

local function format_line_number_left(num, width)
  if not num then
    return string.rep(" ", width)
  end
  -- Left-align number (pad on right) so numbers expand rightward toward center
  local fmt = string.format("%%-%dd", width)
  return string.format(fmt, num)
end

local function source_display_number(source, line_num)
  if not line_num then
    return nil
  end
  local display_numbers = source and source.display_numbers
  if display_numbers and display_numbers[line_num] then
    return display_numbers[line_num]
  end
  return line_num
end

local function format_display_number(value, width, align_left)
  if not value then
    return string.rep(" ", width)
  end
  if type(value) == "number" then
    if align_left then
      return format_line_number_left(value, width)
    end
    return format_line_number(value, width)
  end
  value = tostring(value)
  local display = vim.fn.strdisplaywidth(value)
  if display >= width then
    return value
  end
  local padding = string.rep(" ", width - display)
  if align_left then
    return value .. padding
  end
  return padding .. value
end

local function build_display_lines(session)
  -- View arrays have different lengths; copy them so render-time scroll
  -- padding does not mutate the canonical diff view.
  local left_lines = vim.list_extend({}, session.view.left)
  local right_lines = vim.list_extend({}, session.view.right)
  local padding = session:get_scroll_padding()
  for _ = 1, padding do
    left_lines[#left_lines + 1] = ""
    right_lines[#right_lines + 1] = ""
  end
  return left_lines, right_lines
end

local function render_empty_source_notice(buf, namespace, source)
  if not source or not source.empty_reason or #(source.lines or {}) > 0 then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
    virt_text = { { "  " .. source.empty_reason, "DiffBanditEmptyNotice" } },
    virt_text_pos = "overlay",
    priority = 20,
  })
end

-- Highlight lookup tables for left/right/connector panes
local HIGHLIGHT_LEFT = {
  context = "DiffBanditContext",
  add = "DiffBanditAddLeft",
  delete = "DiffBanditDelete",
  change = { default = "DiffBanditChangeLeft", filler = "DiffBanditGap" },
}

local HIGHLIGHT_RIGHT = {
  context = "DiffBanditContext",
  add = { default = "DiffBanditAdd", filler = "DiffBanditGap" },
  delete = { default = "DiffBanditChangeRight", filler = "DiffBanditGap" },
  change = { default = "DiffBanditChangeRight", filler = "DiffBanditGap" },
}

local function get_highlight(tbl, meta, filler_key)
  local entry = tbl[meta.kind]
  if type(entry) == "table" then
    return meta[filler_key] and entry.filler or entry.default
  end
  return entry
end

local function highlight_for_left(meta)
  return get_highlight(HIGHLIGHT_LEFT, meta, "filler_left")
end

local function highlight_for_right(meta)
  return get_highlight(HIGHLIGHT_RIGHT, meta, "filler_right")
end

-- Gather everything the render stages need in one pass: display lines,
-- viewport toplines, projected routes with their plan, and the per-row index
-- sets that steer number-pane and background styling.
local function build_render_context(self)
  local left_lines, right_lines = self:display_lines()
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_text_hl_mode = self.right.editable and "combine" or "replace"

  -- Compute connector routing lanes using extracted paths module
  local paths = self:base_paths()
  local route_paths = self:project_paths_for_viewport(paths)
  local plan_layout = {
    connector_core_width = self.connector_core_width,
    viewport_topline = left_topline,
    viewport_height = left_height,
    max_route_backtrack_steps = 500,
    -- The navigated chunk's connector is the one the user is looking at;
    -- overflow pruning hides it only when no other candidate remains.
    active_chunk_index = (self.current_chunk or 0) > 0 and self.current_chunk or nil,
  }
  local route_plan = paths_mod.plan_routes(route_paths, plan_layout)
  if not route_plan.success then
    -- Wide cores can make the fixed-width search tree thrash on viewports
    -- that a narrower working width solves immediately. Routes must not
    -- disappear before the core is genuinely saturated, so retry as an
    -- upward width search and stretch the edge-docked horizontals of the
    -- narrower solution out to the real core edge. The gutter width itself
    -- never changes here.
    local solved_width, retry_plan = paths_mod.required_connector_core_width_for_paths(
      route_paths,
      connector_width.minimum(self.config),
      self.connector_core_width,
      plan_layout)
    if retry_plan.success then
      route_plan = paths_mod.stretch_plan_to_core(retry_plan, solved_width, self.connector_core_width)
    end
  end

  -- Compute underline data using extracted helper
  local underline_layout = {
    left_number_width = 0,
    connector_core_width = self.connector_core_width,
    rail_spacing = 1,
    sidecar_numbers = true,
  }
  local underline_data = paths_mod.compute_underlines(route_paths, paths_mod.compute_active_bars(route_paths), underline_layout)
  local delete_origin_right_lines = underline_data.delete_origin_right_lines or {}
  local add_origin_row_has_transition = {}
  for _, p in ipairs(route_paths) do
    if p.kind == "add"
        and not p.embedded_in_change
        and not p.hide_triangle
        and not p.overflow_hidden
        and p.origin_display_row
        and (p.triangle_display_row or p.display_start_row) == p.origin_display_row then
      add_origin_row_has_transition[p.origin_display_row] = true
    end
  end
  local embedded_add_terminal_right_indexes = {}
  local embedded_add_origin_left_indexes = {}
  local change_number_left_indexes = {}
  local change_number_right_indexes = {}
  local solid_change_number_left_indexes = {}
  local solid_change_number_right_indexes = {}
  local function display_row_to_left_index(display_row)
    local meta = self.view.line_meta[display_row]
    if meta and meta.left_index then
      return meta.left_index
    end
    if display_row and display_row >= 1 and display_row <= #left_lines then
      return display_row
    end
    return nil
  end
  local function display_row_to_right_index(display_row)
    local meta = self.view.line_meta[display_row]
    if meta and meta.right_index then
      return meta.right_index
    end
    local right_index = right_topline + ((display_row or left_topline) - left_topline)
    if right_index >= 1 and right_index <= #right_lines then
      return right_index
    end
    return nil
  end
  for _, p in ipairs(paths) do
    if p.kind == "add" and p.embedded_in_change then
      if p.origin_left_index then
        embedded_add_origin_left_indexes[p.origin_left_index] = true
      end
      if p.target_start_index and p.target_end_index then
        embedded_add_terminal_right_indexes[p.target_end_index] = true
      end
    elseif p.kind == "change" then
      if p.start_left_index and p.end_left_index then
        for row = p.start_left_index, p.end_left_index do
          change_number_left_indexes[row] = true
        end
      end
      if p.start_right_index and p.end_right_index then
        for row = p.start_right_index, p.end_right_index do
          change_number_right_indexes[row] = true
        end
      end
    end
  end
  for _, p in ipairs(route_paths) do
    if p.kind == "change" and p.viewport_solid_start and p.viewport_solid_end then
      for row = p.viewport_solid_start, p.viewport_solid_end do
        local left_index = display_row_to_left_index(row)
        if left_index then
          solid_change_number_left_indexes[left_index] = true
        end
        local right_index = display_row_to_right_index(row)
        if right_index then
          solid_change_number_right_indexes[right_index] = true
        end
      end
    end
  end

  -- The connector buffer owns the aligned display model and must include the
  -- same scroll padding as the source panes so routes can remain visible while
  -- either side is scrolled past real EOF.
  local connector_height = math.max(#self.view.line_meta, #left_lines, #right_lines)
  local connector_lines = {}
  for i = 1, connector_height do
    -- Initialize with spaces for the full gutter width
    connector_lines[i] = string.rep(" ", self.connector_core_width)
  end

  local right_stage_markers = {}
  if (self.right_stage_marker_width or 0) > 0 then
    local indicator = ((self.config.actions or {}).staged_indicator or {})
    local staged_glyph = indicator.staged or "▣"
    local unstaged_glyph = indicator.unstaged or "□"
    local staged_states = self.staged_chunk_states or {}

    local function marker_for_chunk(chunk_index)
      return staged_states[chunk_index] and staged_glyph or unstaged_glyph
    end

    local function mark_right(row, chunk_index)
      if row and row >= 1 and row <= #right_lines then
        right_stage_markers[row] = marker_for_chunk(chunk_index)
      end
    end

    local function right_index_for_connector_row(row)
      return display_row_to_right_index(row)
    end

    local function mark_right_connector_row(row, chunk_index)
      mark_right(right_index_for_connector_row(row), chunk_index)
    end

    for _, p in ipairs(route_paths) do
      if p.kind == "add" and not p.embedded_in_change and not p.hide_triangle and not p.overflow_hidden then
        mark_right(p.target_start_index, p.chunk)
      elseif p.kind == "delete" and not p.hide_triangle and not p.overflow_hidden then
        mark_right(p.origin_right_index, p.chunk)
        mark_right_connector_row(p.origin_display_row or p.target_start_index, p.chunk)
      elseif p.kind == "change" then
        for _, edge in ipairs(p.viewport_change_edges or {}) do
          if edge.side == "right" then
            mark_right(right_index_for_connector_row(edge.row), p.chunk)
          end
        end
        for _, link in ipairs(p.viewport_change_links or {}) do
          if not link.overflow_hidden and link.from_visible then
            if link.from_side == "right" then
              mark_right(right_index_for_connector_row(link.from_row), p.chunk)
            end
          end
          if not link.overflow_hidden and link.to_visible then
            if link.to_side == "right" then
              mark_right(right_index_for_connector_row(link.to_row), p.chunk)
            end
          end
        end
        if p.viewport_solid_start and p.viewport_solid_end then
          mark_right(right_index_for_connector_row(p.viewport_solid_start), p.chunk)
          mark_right(right_index_for_connector_row(p.viewport_solid_end), p.chunk)
        end
      end
    end
  end

  return {
    left_lines = left_lines,
    right_lines = right_lines,
    left_topline = left_topline,
    right_topline = right_topline,
    left_height = left_height,
    right_text_hl_mode = right_text_hl_mode,
    paths = paths,
    route_paths = route_paths,
    route_plan = route_plan,
    delete_origin_right_lines = delete_origin_right_lines,
    add_origin_row_has_transition = add_origin_row_has_transition,
    embedded_add_terminal_right_indexes = embedded_add_terminal_right_indexes,
    embedded_add_origin_left_indexes = embedded_add_origin_left_indexes,
    change_number_left_indexes = change_number_left_indexes,
    change_number_right_indexes = change_number_right_indexes,
    solid_change_number_left_indexes = solid_change_number_left_indexes,
    solid_change_number_right_indexes = solid_change_number_right_indexes,
    connector_height = connector_height,
    connector_lines = connector_lines,
    right_stage_markers = right_stage_markers,
    display_row_to_left_index = display_row_to_left_index,
    display_row_to_right_index = display_row_to_right_index,
  }
end

-- Build the fixed-width number-pane text for both sides, including stage
-- markers when enabled.
local function render_number_panes(self, ctx)
  -- Left and right buffers now have different line counts
  ctx.left_num_lines = {}
  for i = 1, #ctx.left_lines do
    ctx.left_num_lines[i] = string.rep(" ", self.left_number_pane_width)
  end
  ctx.right_num_lines = {}
  for i = 1, #ctx.right_lines do
    ctx.right_num_lines[i] = string.rep(" ", self.right_number_pane_width)
  end
  for _, meta in ipairs(self.view.line_meta) do
    if meta.left_index then
      if (self.left_stage_marker_width or 0) > 0 then
        ctx.left_num_lines[meta.left_index] = " "
          .. format_display_number(source_display_number(self.left, meta.left_line), self.left_number_width, false)
          .. " "
      else
        ctx.left_num_lines[meta.left_index] = format_display_number(source_display_number(self.left, meta.left_line), self.left_number_width, false) .. " "
      end
    end
    if meta.right_index then
      if self.mirror_connector_sides then
        ctx.right_num_lines[meta.right_index] = format_display_number(source_display_number(self.right, meta.right_line), self.right_number_width, false) .. " "
      elseif (self.right_stage_marker_width or 0) > 0 then
        ctx.right_num_lines[meta.right_index] = " "
          .. format_display_number(source_display_number(self.right, meta.right_line), self.right_number_width, true)
          .. (ctx.right_stage_markers[meta.right_index] or " ")
      else
        ctx.right_num_lines[meta.right_index] = " " .. format_display_number(source_display_number(self.right, meta.right_line), self.right_number_width, true)
      end
    end
  end
end

-- Write display lines into all five buffers and restore modifiable state.
local function apply_buffer_lines(self, ctx)
  if not self.preserve_left_buffer_lines then
    vim.api.nvim_buf_set_lines(self.left_buf, 0, -1, false, ctx.left_lines)
  end
  vim.api.nvim_buf_set_lines(self.left_num_buf, 0, -1, false, ctx.left_num_lines)
  if not self.preserve_right_buffer_lines then
    vim.api.nvim_buf_set_lines(self.right_buf, 0, -1, false, ctx.right_lines)
  end
  vim.api.nvim_buf_set_lines(self.right_num_buf, 0, -1, false, ctx.right_num_lines)
  vim.api.nvim_buf_set_lines(self.connector_buf, 0, -1, false, ctx.connector_lines)

  set_buffer_options(self.left_buf, { modifiable = false })
  set_buffer_options(self.left_num_buf, { modifiable = false })
  set_buffer_options(self.right_buf, { modifiable = self.right.editable ~= nil })
  set_buffer_options(self.right_num_buf, { modifiable = false })
  set_buffer_options(self.connector_buf, { modifiable = false })
end

-- Reset every render namespace and re-add empty-source notices.
local function clear_render_namespaces(self)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.ns, 0, -1)

  -- Clear extmark namespace for full-width backgrounds
  self.extmark_ns = self.extmark_ns or vim.api.nvim_create_namespace("DiffBanditExtmarks" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.left_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.extmark_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.extmark_ns, 0, -1)

  -- Clear namespace for line number virtual text
  self.linenum_ns = self.linenum_ns or vim.api.nvim_create_namespace("DiffBanditLineNums" .. self.id)
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.linenum_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.linenum_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.linenum_ns, 0, -1)

  render_empty_source_notice(self.left_buf, self.extmark_ns, self.left)
  render_empty_source_notice(self.right_buf, self.extmark_ns, self.right)
end

local function render_pane_backgrounds(self, ctx)
  -- Apply highlights to left and right buffers (pane-wide backgrounds)
  for _, meta in ipairs(self.view.line_meta) do
    local left_hl = highlight_for_left(meta)
    local right_hl = highlight_for_right(meta)
    local final_left_hl = left_hl
    local final_right_hl = right_hl

    if meta.filler_left and meta.kind ~= "context" then
      final_left_hl = "DiffBanditPlaceholder"
    end

    if meta.filler_right and meta.kind ~= "context" then
      final_right_hl = "DiffBanditPlaceholder"
    end

    -- IMPORTANT: do NOT apply a full-line background on change lines.
    -- Range extmarks below own those rows so intra-line emphasis can override
    -- the base change background on both panes.
    local skip_left_line_hl = (meta.kind == "change" and not meta.filler_left)
    if final_left_hl and meta.left_index and not skip_left_line_hl then
      local left_row = meta.left_index - 1
      vim.api.nvim_buf_set_extmark(self.left_buf, self.extmark_ns, left_row, 0, {
        line_hl_group = final_left_hl,
        hl_mode = "combine",
      })
    end
    local skip_right_line_hl = (meta.kind == "change" and not meta.filler_right)
      -- Shared merge result: line highlights beat range highlights regardless
      -- of priority, so an add line_hl would override the other pair's change
      -- band. Add rows there rely on the low-priority range mark instead.
      or (self.shared_result_right and meta.kind == "add" and not meta.filler_right)
    local skip_right_context_hl = self.suppress_right_context_highlights == true and meta.kind == "context"
    if final_right_hl and meta.right_index and not skip_right_line_hl and not skip_right_context_hl then
      local right_row = meta.right_index - 1
      vim.api.nvim_buf_set_extmark(self.right_buf, self.extmark_ns, right_row, 0, {
        line_hl_group = final_right_hl,
        hl_mode = "combine",
      })
    end
  end
end

local function render_connector_backgrounds(self, ctx)
  -- Apply connector backgrounds and number-pane styling on the same compact
  -- rows as their owner buffers.
  local ctx_hl = "DiffBanditConnectorContext"

  for row = 0, ctx.connector_height - 1 do
    vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, ctx_hl, row, 0, -1)
  end

  local function add_origin_core_underline(origin_row, row, meta)
    if meta.origin == "add" then
      if row < 0 or row >= ctx.connector_height then
        return
      end
      vim.api.nvim_buf_set_extmark(self.left_num_buf, self.linenum_ns, row, self:left_triangle_col(), {
        virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
      local right_index_at_row = ctx.right_topline + ((row + 1) - ctx.left_topline)
      if ctx.add_origin_row_has_transition[origin_row]
          and right_index_at_row >= 1
          and right_index_at_row <= #ctx.right_lines then
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.linenum_ns, right_index_at_row - 1, self:right_triangle_col(), {
          virt_text = { { " ", "DiffBanditAddLeftSeparatorConnector" } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end
    end
  end

  for _, meta in ipairs(self.view.line_meta) do
    if meta.left_index then
      local row = meta.left_index - 1

      local left_num_hl
      if meta.origin == "add" and not ctx.embedded_add_origin_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftUnderline"
      elseif meta.kind == "delete" then
        left_num_hl = "DiffBanditLineNumberLeftDelete"
      elseif ctx.change_number_left_indexes[meta.left_index] then
        left_num_hl = "DiffBanditLineNumberLeftChange"
      else
        left_num_hl = "DiffBanditLineNumberLeft"
      end

      vim.api.nvim_buf_add_highlight(self.left_num_buf, self.linenum_ns, left_num_hl, row,
        self:left_number_text_start_col(), self:left_number_text_end_col())
      if meta.kind == "delete" then
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorDelete", row,
          self:left_number_text_start_col(), self:left_number_text_end_col())
      elseif ctx.change_number_left_indexes[meta.left_index] then
        local start_col = ctx.solid_change_number_left_indexes[meta.left_index] and 0 or self:left_number_text_start_col()
        local end_col = ctx.solid_change_number_left_indexes[meta.left_index] and -1 or self:left_number_text_end_col()
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorChange", row, start_col, end_col)
      end
      if not ctx.embedded_add_origin_left_indexes[meta.left_index] then
        add_origin_core_underline(meta.left_index, row, meta)
      end
    end

    if meta.right_index then
      local row = meta.right_index - 1

      local is_delete_origin = meta.right_line and ctx.delete_origin_right_lines[meta.right_line] ~= nil
      local right_num_hl
      if is_delete_origin then
        right_num_hl = "DiffBanditLineNumberRightUnderline"
      elseif ctx.change_number_right_indexes[meta.right_index] then
        right_num_hl = "DiffBanditLineNumberRightChange"
      elseif meta.kind == "add" then
        right_num_hl = "DiffBanditLineNumberRightAdd"
      else
        right_num_hl = "DiffBanditLineNumberRight"
      end

      if is_delete_origin then
        -- "combine" keeps the number pane's own background (e.g. a change
        -- band) under the underline spacer so the origin underline decorates
        -- the row instead of punching a dark cell into it.
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.linenum_ns, row, self:right_triangle_col(), {
          virt_text = { { " ", "DiffBanditDeleteRightSeparatorConnector" } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end

      vim.api.nvim_buf_add_highlight(self.right_num_buf, self.linenum_ns, right_num_hl, row,
        self:right_number_text_start_col(), self:right_number_text_end_col())
      if ctx.change_number_right_indexes[meta.right_index] then
        -- Delete-origin rows inside a change band fill from the pane edge:
        -- the underline spacer cell combines on top, so the band flows
        -- through it instead of leaving a bare default cell in the corridor.
        local full_fill = ctx.solid_change_number_right_indexes[meta.right_index] or is_delete_origin
        local start_col = full_fill and 0 or self:right_number_text_start_col()
        local end_col = full_fill and -1 or self:right_number_text_end_col()
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorChange", row, start_col, end_col)
      elseif meta.kind == "add" then
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorAdd", row,
          self:right_number_text_start_col(), self:right_number_text_end_col())
      end
    end
  end
end

local function render_route_backgrounds(self, ctx)
  -- Apply route-owned backgrounds. Add/delete fill now belongs to the
  -- sidecar number panes; the connector core is reserved for routes.
  for _, p in ipairs(ctx.paths) do
    if p.kind == "add" and not p.embedded_in_change then
      for right_index = p.target_start_index or p.display_start_row, p.target_end_index or p.display_end_row do
        vim.api.nvim_buf_add_highlight(self.right_num_buf, self.ns, "DiffBanditConnectorAdd", right_index - 1,
          self:right_number_text_start_col(), self:right_number_text_end_col())
      end
    elseif p.kind == "delete" then
      for left_index = p.target_start_index or p.display_start_row, p.target_end_index or p.display_end_row do
        vim.api.nvim_buf_add_highlight(self.left_num_buf, self.ns, "DiffBanditConnectorDelete", left_index - 1,
          self:left_number_text_start_col(), self:left_number_text_end_col())
      end
    end
  end
  for _, p in ipairs(ctx.route_paths) do
    if p.kind == "change" and p.viewport_solid_start and p.viewport_solid_end then
      for row = p.viewport_solid_start, p.viewport_solid_end do
        if row >= 1 and row <= ctx.connector_height then
          vim.api.nvim_buf_add_highlight(self.connector_buf, self.ns, "DiffBanditConnectorChange", row - 1, 0, -1)
        end
      end
    end
  end
end

local function render_intraline_spans(self, ctx)
  -- Apply change/add-specific highlighting with intra-line spans
  self.changed_spans_cache = self.changed_spans_cache or {}
  for meta_idx, meta in ipairs(self.view.line_meta) do
    local is_change = meta.kind == "change" and meta.left_index and meta.right_index
    local not_filler = not meta.filler_left and not meta.filler_right
    if is_change and not_filler then
      local left_line = self.left.lines and self.left.lines[meta.left_line] or nil
      local right_line = self.right.lines and self.right.lines[meta.right_line] or nil
      if left_line and right_line then
        local spans = self.changed_spans_cache[meta_idx]
        if not spans then
          spans = diff_mod.changed_spans(left_line, right_line)
          self.changed_spans_cache[meta_idx] = spans
        end
        local row_l = meta.left_index - 1
        local row_r = meta.right_index - 1

        pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, 0, {
          hl_group = "DiffBanditChangeLeft",
          end_row = row_l,
          end_col = #left_line,
          hl_mode = "combine",
          priority = 2500,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, #left_line, {
          hl_group = "DiffBanditChangeLeft",
          end_row = row_l + 1,
          end_col = 0,
          hl_eol = true,
          hl_mode = "combine",
          priority = 2500,
        })
        for _, sp in ipairs(spans.left or {}) do
          local s, e = sp[1] - 1, sp[2]
          pcall(vim.api.nvim_buf_set_extmark, self.left_buf, self.extmark_ns, row_l, s, {
            end_row = row_l,
            end_col = e,
            hl_group = "DiffBanditChangeEmphasis",
            hl_mode = "combine",
            priority = 8000,
          })
        end

        local right_line_len = spans.right_len or #right_line
        local has_change = spans.right_changes and #spans.right_changes > 0

        do
          -- Change (blue) part followed by added suffix (green)
          local add_start = spans.add_start and (spans.add_start - 1) or right_line_len
          add_start = math.max(0, math.min(add_start, right_line_len))

          local blue_end = math.min(add_start, right_line_len)
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
            end_row = row_r,
            end_col = right_line_len,
            hl_group = "DiffBanditChangeRight",
            hl_mode = "combine",
            priority = 2500,
          })
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, right_line_len, {
            end_row = row_r + 1,
            end_col = 0,
            hl_group = "DiffBanditChangeRight",
            hl_eol = true,
            hl_mode = "combine",
            priority = 2500,
          })
          if has_change then
            -- Word emphasis only within the blue change span
            local emph_hl = "DiffBanditChangeEmphasis"
            for _, sp in ipairs(spans.right_changes or {}) do
              local s = sp[1] - 1
              local e = math.min(sp[2], blue_end)
              if s < e then
                pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, s, {
                  end_row = row_r,
                  end_col = e,
                  hl_group = emph_hl,
                  hl_mode = ctx.right_text_hl_mode,
                  priority = 8000,
                })
              end
            end
          end

          -- Added suffix (green): from add_start to end-of-line, extend to window edge
          if spans.add_start and add_start < right_line_len then
            if self.shared_result_right then
              -- The shared merge result pane reads as change + inner-change
              -- emphasis: appended text is emphasized instead of add-colored
              -- so green marks never fight the other pair's change diff.
              pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, add_start, {
                end_row = row_r,
                end_col = right_line_len,
                hl_group = "DiffBanditChangeEmphasis",
                hl_mode = ctx.right_text_hl_mode,
                priority = 8000,
              })
            else
              local add_hl = "DiffBanditAdd"
              pcall(vim.api.nvim_buf_add_highlight, self.right_buf, self.ns, add_hl, row_r, add_start, right_line_len)
              pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, right_line_len, {
                end_row = row_r + 1,
                end_col = 0,
                hl_group = "DiffBanditAdd",
                hl_eol = true,
                hl_mode = "combine",
                priority = 3000,
              })
            end
          end
        end
      end
    elseif meta.kind == "add" and meta.right_index and not meta.filler_right then
      local row_r = meta.right_index - 1
      local line_content = self.right.lines and self.right.lines[meta.right_line] or ""
      local line_len = #line_content
      local is_embedded_terminal = ctx.embedded_add_terminal_right_indexes[meta.right_index] == true
      if is_embedded_terminal then
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          line_hl_group = "DiffBanditChangeRight",
          hl_mode = "combine",
          priority = 2400,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          end_row = row_r,
          end_col = line_len,
          hl_group = "DiffBanditAdd",
          hl_mode = ctx.right_text_hl_mode,
          priority = 7000,
        })
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, line_len, {
          end_row = row_r + 1,
          end_col = 0,
          hl_group = "DiffBanditChangeRight",
          hl_eol = true,
          hl_mode = "combine",
          priority = 6500,
        })
        local win_width = vim.api.nvim_win_get_width(self.right_win)
        local text_width = vim.fn.strdisplaywidth(line_content)
        local padding_len = math.max(0, win_width - text_width)
        if padding_len > 0 then
          pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, line_len, {
            virt_text = { { string.rep(" ", padding_len), "DiffBanditChangeRight" } },
            virt_text_pos = "inline",
            priority = 6500,
          })
        end
      elseif self.shared_result_right then
        -- Plain add rows are normally painted by the base line highlight, but
        -- in the shared merge result the add band must sit just below the
        -- change band (2500) so the other pair's change diff plus inner
        -- emphasis owns contested rows. That contest needs a range mark —
        -- line highlights win over range highlights regardless of priority.
        pcall(vim.api.nvim_buf_set_extmark, self.right_buf, self.extmark_ns, row_r, 0, {
          end_row = row_r + 1,
          end_col = 0,
          hl_group = "DiffBanditAdd",
          hl_eol = true,
          hl_mode = ctx.right_text_hl_mode,
          priority = 2450,
        })
      end
    end
  end
end

-- Native underline on an origin row's text, with virtual-text padding
-- extending the underline to the window edge.
local function underline_origin_row(self, buf, win, row, hl_group, hl_mode, priority)
  local line_content = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local text_len = #line_content
  if text_len > 0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, self.extmark_ns, row, 0, {
      end_col = text_len,
      hl_group = hl_group,
      hl_mode = hl_mode,
      priority = priority,
    })
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local win_width = vim.api.nvim_win_get_width(win)
  local text_width = vim.fn.strdisplaywidth(line_content)
  local padding_len = math.max(0, win_width - text_width)
  if padding_len > 0 then
    -- "combine" keeps the row's own trailing background (e.g. a change band's
    -- eol fill) underneath the underline padding instead of cutting it off.
    pcall(vim.api.nvim_buf_set_extmark, buf, self.extmark_ns, row, 0, {
      virt_text = { { string.rep(" ", padding_len), hl_group } },
      virt_text_win_col = text_width,
      hl_mode = "combine",
      priority = priority,
    })
  end
end

-- Separator lines on ORIGIN rows: add origins underline their left-pane row;
-- delete origins underline the right-pane row mapped through
-- delete_origin_right_lines. The connector-side underline is handled during
-- line-number rendering.
local function render_origin_underlines(self, ctx)
  for _, meta in ipairs(self.view.line_meta) do
    if meta.origin == "add" and not ctx.embedded_add_origin_left_indexes[meta.left_index] and meta.left_index then
      underline_origin_row(self, self.left_buf, self.left_win, meta.left_index - 1,
        "DiffBanditAddLeftSeparator", "combine", 100)
    end
  end
  for right_line_num in pairs(ctx.delete_origin_right_lines) do
    local origin_row = right_line_num - 1
    if origin_row >= 0 and origin_row < #ctx.right_lines then
      underline_origin_row(self, self.right_buf, self.right_win, origin_row,
        "DiffBanditDeleteRightSeparator", ctx.right_text_hl_mode, 150)
    end
  end
end

local function render_route_glyphs(self, ctx)
  -- Render planned connector routes. Each planned route is limited to one
  -- source horizontal, one vertical rail, and one destination horizontal.
  vim.api.nvim_buf_clear_namespace(self.left_num_buf, self.path_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.connector_buf, self.path_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.right_num_buf, self.path_ns, 0, -1)

  local function render_core_underline(row, start_col, end_col, hl_group)
    if row < 1 or row > ctx.connector_height or end_col < start_col then
      return
    end
    start_col = math.max(0, start_col)
    end_col = math.min(self.connector_core_width - 1, end_col)
    if self.mirror_connector_sides then
      start_col, end_col = self.connector_core_width - 1 - end_col, self.connector_core_width - 1 - start_col
    end
    if end_col < start_col then
      return
    end
    -- "combine" keeps whatever background the core row already carries (a
    -- solid change band, most notably) underneath the underline run, so a
    -- crossing route decorates the band instead of cutting a gap into it.
    vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, start_col, {
      virt_text = { { string.rep(" ", end_col - start_col + 1), hl_group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end

  local function render_core_vertical(row, col, hl_group)
    if row < 1 or row > ctx.connector_height or col < 0 or col >= self.connector_core_width then
      return
    end
    if self.mirror_connector_sides then
      col = self.connector_core_width - 1 - col
    end
    vim.api.nvim_buf_set_extmark(self.connector_buf, self.path_ns, row - 1, col, {
      virt_text = { { "│", hl_group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end

  local function render_change_wedge(side, row, glyph)
    if row < 1 or row > ctx.connector_height then
      return
    end
    glyph = self:display_glyph(glyph)
    if side == "left" then
      local left_index = row
      if left_index and left_index >= 1 and left_index <= #ctx.left_lines then
        vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, left_index - 1, self:left_triangle_col(), {
          virt_text = { { glyph, "DiffBanditConnectorExpansionChange" } },
          virt_text_pos = "overlay",
        })
      end
    else
      local right_index = ctx.right_topline + (row - ctx.left_topline)
      if right_index >= 1 and right_index <= #ctx.right_lines then
        vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, right_index - 1, self:right_triangle_col(), {
          virt_text = { { glyph, "DiffBanditConnectorExpansionChange" } },
          virt_text_pos = "overlay",
        })
      end
    end
  end

  for _, p in ipairs(ctx.route_paths) do
    if p.kind == "change" and p.viewport_change_edges then
      for _, edge in ipairs(p.viewport_change_edges) do
        render_change_wedge(edge.side, edge.row, edge.glyph)
      end
    end
    if p.kind == "change" and p.viewport_change_links then
      for _, link in ipairs(p.viewport_change_links) do
        if not link.overflow_hidden and link.from_visible then
          render_change_wedge(link.from_side, link.from_row, link.from_glyph)
        end
        if not link.overflow_hidden and link.to_visible then
          render_change_wedge(link.to_side, link.to_row, link.to_glyph)
        end

      end
    end
  end

  for _, p in ipairs(ctx.route_paths) do
    if (p.kind == "add" or p.kind == "delete") and not p.embedded_in_change and not p.overflow_hidden then
      local expansion_hl
      if p.kind == "add" then
        expansion_hl = "DiffBanditConnectorExpansionAdd"
        if (p.triangle_display_row or p.display_start_row) == p.origin_display_row
            or p.connect_tail_on_triangle_row then
          expansion_hl = "DiffBanditConnectorExpansionAddUnderline"
        end
      else
        expansion_hl = "DiffBanditConnectorExpansionDelete"
      end

      local glyph = p.triangle_glyph or ((p.kind == "add") and "◥" or "◤")
      glyph = self:display_glyph(glyph)
      if not p.hide_triangle then
        if p.kind == "add" and p.target_start_index then
          vim.api.nvim_buf_set_extmark(self.right_num_buf, self.path_ns, p.target_start_index - 1, self:right_triangle_col(), {
            virt_text = { { glyph, expansion_hl } },
            virt_text_pos = "overlay",
          })
        elseif p.kind == "delete" and p.target_start_index then
          vim.api.nvim_buf_set_extmark(self.left_num_buf, self.path_ns, p.target_start_index - 1, self:left_triangle_col(), {
            virt_text = { { glyph, expansion_hl } },
            virt_text_pos = "overlay",
          })
        end
      end
    end
  end

  for _, planned_route in ipairs(ctx.route_plan.routes or {}) do
    for _, segment in ipairs(planned_route.segments or {}) do
      if segment.type == "horizontal" then
        render_core_underline(segment.row, segment.start_col, segment.end_col, segment.kind)
      elseif segment.type == "vertical" then
        for row = segment.start_row, segment.end_row do
          render_core_vertical(row, segment.col, segment.kind)
        end
      end
    end
  end
end

function M.build_display_lines(session)
  return build_display_lines(session)
end

function M.render(session)
  set_buffer_options(session.left_buf, { modifiable = true })
  set_buffer_options(session.left_num_buf, { modifiable = true })
  set_buffer_options(session.right_buf, { modifiable = true })
  set_buffer_options(session.right_num_buf, { modifiable = true })
  set_buffer_options(session.connector_buf, { modifiable = true })

  local ctx = build_render_context(session)
  render_number_panes(session, ctx)
  apply_buffer_lines(session, ctx)
  clear_render_namespaces(session)
  render_pane_backgrounds(session, ctx)
  render_connector_backgrounds(session, ctx)
  render_route_backgrounds(session, ctx)
  render_intraline_spans(session, ctx)
  render_origin_underlines(session, ctx)

  if session.current_chunk > 0 then
    local chunk = session.view.chunks[session.current_chunk]
    if chunk then
      session:highlight_active_chunk(chunk)
    end
  end

  render_route_glyphs(session, ctx)

  session:render_status_headers()
  session:render_overviews()
end

return M
