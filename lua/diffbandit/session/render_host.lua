-- Shared methods for objects painted by session.render.
-- Used by Session (full host) and merge pair_renderer (minimal render context).
-- Keep this free of layout/nav/panel orchestration so pair renderers do not
-- inherit the full Session class.

local connector = require("diffbandit.connector")
local connector_width = require("diffbandit.connector.width")
local nvim = require("diffbandit.util.nvim")
local session_render = require("diffbandit.session.render")

local M = {}

local get_win_view_topline = nvim.get_win_view_topline

function M.invalidate_render_caches(self)
  self.base_paths_cache = nil
  self.overview_marks_cache = nil
  self.changed_spans_cache = nil
  self.display_lines_cache = nil
  self.route_plan_cache = nil
end

function M.base_paths(self)
  if not self.base_paths_cache then
    self.base_paths_cache = connector.compute_paths(self.view.chunks, self.view.line_meta)
  end
  return self.base_paths_cache
end

function M.get_scroll_padding(self)
  if self.scroll_padding ~= nil then
    return self.scroll_padding
  end
  return 0
end

function M.display_lines(self)
  local padding = self:get_scroll_padding()
  if not self.display_lines_cache or self.display_lines_cache.padding ~= padding then
    local left_lines, right_lines = session_render.build_display_lines(self)
    self.display_lines_cache = {
      left = left_lines,
      right = right_lines,
      padding = padding,
    }
  end
  return self.display_lines_cache.left, self.display_lines_cache.right
end

function M.left_triangle_col(self)
  if self.mirror_connector_sides then
    return 0
  end
  return self.left_number_pane_width - 1
end

function M.left_number_text_start_col(self)
  return self.mirror_connector_sides and 1 or 0
end

function M.left_number_text_end_col(self)
  if self.mirror_connector_sides then
    return -1
  end
  return self:left_triangle_col()
end

function M.right_triangle_col(self)
  if self.mirror_connector_sides then
    return self.right_number_pane_width - 1
  end
  return 0
end

function M.right_number_text_start_col(self)
  return self.mirror_connector_sides and 0 or 1
end

function M.right_number_text_end_col(self)
  if self.mirror_connector_sides then
    return self:right_triangle_col()
  end
  return -1
end

function M.display_glyph(self, glyph)
  if not self.mirror_connector_sides then
    return glyph
  end
  local mirrored = {
    ["◤"] = "◥",
    ["◥"] = "◤",
    ["◢"] = "◣",
    ["◣"] = "◢",
  }
  return mirrored[glyph] or glyph
end

function M.project_paths_for_toplines(self, paths, left_topline, right_topline, left_height, right_height)
  return connector.project_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function M.project_paths_for_viewport(self, paths)
  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 1
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 1
  return self:project_paths_for_toplines(paths, left_topline, right_topline, left_height, right_height)
end

function M.precompute_connector_core_width(self)
  local viewport_rows = vim.api.nvim_win_is_valid(self.left_win)
      and vim.api.nvim_win_get_height(self.left_win) or nil
  local required_core = connector.pressure_core_width(
    self:base_paths(),
    connector_width.base(self.view, self.config),
    connector_width.maximum(self.config),
    viewport_rows)
  if required_core ~= self.connector_core_width then
    self.connector_core_width = required_core
    if type(self.resize_layout) == "function" then
      self:resize_layout()
    end
  end
  return required_core
end

function M.render(self)
  self.last_viewport_render_key = nil
  session_render.render(self)
end

function M.rerender_for_viewport(self)
  if self.disposed or self.rendering_viewport then
    return
  end

  local left_topline = get_win_view_topline(self.left_win)
  local right_topline = get_win_view_topline(self.right_win)
  local left_cursor = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_cursor(self.left_win) or nil
  local right_cursor = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_cursor(self.right_win) or nil

  -- Skip repaints whose inputs are identical; M.render clears the key so
  -- direct renders always repaint and re-arm the next viewport render.
  local left_height = vim.api.nvim_win_is_valid(self.left_win) and vim.api.nvim_win_get_height(self.left_win) or 0
  local right_height = vim.api.nvim_win_is_valid(self.right_win) and vim.api.nvim_win_get_height(self.right_win) or 0
  local key = string.format("%s:%s:%d:%d:%d",
    tostring(left_topline), tostring(right_topline), left_height, right_height, self.current_chunk or 0)
  if key == self.last_viewport_render_key then
    return
  end

  local set_win_view_topline = nvim.set_win_view_topline
  self.rendering_viewport = true
  self:render()
  self.last_viewport_render_key = key
  set_win_view_topline(self.left_win, left_topline)
  set_win_view_topline(self.left_num_win, left_topline)
  set_win_view_topline(self.connector_win, left_topline)
  set_win_view_topline(self.right_win, right_topline)
  set_win_view_topline(self.right_num_win, right_topline)
  if left_cursor and vim.api.nvim_win_is_valid(self.left_win) then
    pcall(vim.api.nvim_win_set_cursor, self.left_win, left_cursor)
  end
  if right_cursor and vim.api.nvim_win_is_valid(self.right_win) then
    pcall(vim.api.nvim_win_set_cursor, self.right_win, right_cursor)
  end
  self.rendering_viewport = false
end

--- Install shared render methods onto a host class table (e.g. Session).
function M.install(class)
  for name, fn in pairs(M) do
    if name ~= "install" and type(fn) == "function" then
      class[name] = fn
    end
  end
end

return M
