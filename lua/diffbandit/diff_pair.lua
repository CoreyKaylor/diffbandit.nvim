local diff = require("diffbandit.diff")
local text = require("diffbandit.text")
local ui = require("diffbandit.ui")
local view_builder = require("diffbandit.view")

local M = {}

function M.build(left_lines, right_lines, config)
  local hunks, err = diff.compute_hunks(text.to_text(left_lines or {}), text.to_text(right_lines or {}), (config or {}).diff or {})
  if err then
    return nil, err
  end
  if type(hunks) ~= "table" then
    hunks = {}
  end
  local view = view_builder.build(left_lines or {}, right_lines or {}, hunks, config or {})
  return {
    left_lines = left_lines or {},
    right_lines = right_lines or {},
    hunks = hunks,
    view = view,
    number_width = {
      left = ui.digits_of(#(left_lines or {})),
      right = ui.digits_of(#(right_lines or {})),
    },
    connector_width = math.max((((config or {}).ui or {}).connector_width or 0), 1),
  }, nil
end

return M
