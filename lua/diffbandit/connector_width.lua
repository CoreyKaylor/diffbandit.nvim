local M = {}

local ABSOLUTE_MIN_WIDTH = 3
local DEFAULT_MAX_WIDTH = 24

local function ui_config(config)
  return (config or {}).ui or {}
end

function M.minimum(config)
  local width = tonumber(ui_config(config).connector_width)
  if not width then
    width = ABSOLUTE_MIN_WIDTH
  end
  return math.max(ABSOLUTE_MIN_WIDTH, math.floor(width))
end

function M.maximum(config)
  local width = tonumber(ui_config(config).connector_max_width)
  if not width then
    width = DEFAULT_MAX_WIDTH
  end
  return math.max(M.minimum(config), math.floor(width))
end

function M.base(view, config)
  local width = M.minimum(config)
  for _, value in ipairs(((view or {}).connectors) or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(value))
  end
  return math.min(M.maximum(config), width)
end

return M
