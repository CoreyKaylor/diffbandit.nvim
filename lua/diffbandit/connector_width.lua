local config_mod = require("diffbandit.config")
local M = {}

local ABSOLUTE_MIN_WIDTH = 3
local DEFAULT_MAX_WIDTH = 24

local function ui_config(config)
  return config_mod.section(config, "ui")
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

-- Base width for a view's connector pane. view.connectors only ever holds
-- blank strings of exactly minimum width (view.build fills them; glyphs are
-- extmark overlays, never buffer text), so this is minimum(config) today.
-- The view parameter stays for API stability with callers and tests.
function M.base(view, config)
  local _ = view
  return M.minimum(config)
end

return M
