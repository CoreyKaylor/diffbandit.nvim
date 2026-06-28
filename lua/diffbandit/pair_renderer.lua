local Session = require("diffbandit.session")

local M = {}

local function connector_base_width(pair, config)
  local width = math.max((((config or {}).ui or {}).connector_width or 0), 0)
  for _, value in ipairs(((pair or {}).view or {}).connectors or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(value))
  end
  return math.max(1, width)
end

function M.from_pair(owner, id_suffix, pair, left_source, right_source, buffers, windows, opts)
  opts = opts or {}
  local number_width = owner.number_width or 3
  local width = connector_base_width(pair, owner.config)
  local renderer = setmetatable({
    id = tostring(owner.id) .. "-" .. id_suffix,
    config = owner.config,
    left = left_source,
    right = right_source,
    hunks = pair.hunks or {},
    view = pair.view,
    current_chunk = 0,
    file_queue = nil,
    file_queue_index = nil,
    pending_file_boundary = nil,
    left_number_width = number_width,
    right_number_width = number_width,
    right_number_padding = ((owner.config or {}).ui or {}).right_number_padding or 2,
    stage_marker_width = 0,
    left_stage_marker_width = 0,
    right_stage_marker_width = 0,
    left_number_pane_width = number_width + 1,
    right_number_pane_width = number_width + 1,
    connector_core_width = width,
    gutter_width = width,
    connector_width_cache = {},
    overview_enabled = false,
    overview_width = 0,
    status_enabled = false,
    staged_chunk_states = {},
    disposed = false,
    ns = vim.api.nvim_create_namespace("DiffBanditPairRenderer" .. tostring(owner.id) .. id_suffix),
    active_ns = vim.api.nvim_create_namespace("DiffBanditPairRendererActive" .. tostring(owner.id) .. id_suffix),
    path_ns = vim.api.nvim_create_namespace("DiffBanditPairRendererPaths" .. tostring(owner.id) .. id_suffix),
    overview_ns = vim.api.nvim_create_namespace("DiffBanditPairRendererOverview" .. tostring(owner.id) .. id_suffix),
    left_buf = buffers.left,
    left_num_buf = buffers.left_num,
    connector_buf = buffers.connector,
    right_num_buf = buffers.right_num,
    right_buf = buffers.right,
    left_win = windows.left,
    left_num_win = windows.left_num,
    connector_win = windows.connector,
    right_num_win = windows.right_num,
    right_win = windows.right,
    preserve_left_buffer_lines = opts.preserve_left_buffer_lines == true,
    preserve_right_buffer_lines = opts.preserve_right_buffer_lines == true,
    suppress_right_context_highlights = opts.suppress_right_context_highlights == true,
    mirror_connector_sides = opts.mirror_connector_sides == true,
  }, { __index = Session })

  function renderer:resize_layout() end
  function renderer:render_status_headers() end
  function renderer:render_overviews() end
  function renderer:get_scroll_padding()
    return 0
  end

  renderer:invalidate_render_caches()
  renderer:precompute_connector_core_width()
  return renderer
end

M._private = {
  connector_base_width = connector_base_width,
}

return M
