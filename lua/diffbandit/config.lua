local M = {}

local defaults = {
  diff = {
    algorithm = "myers",
    linematch = 60,
    ignore_whitespace = false,
    result_type = "indices",
  },
  ui = {
    connector_width = 12,
    right_number_padding = 2,
    connectors = {
      context = "   ",
      change = {
        single = "──",
        start = "╭─",
        mid = "│ ",
        finish = "╰─",
      },
    },
  },
  navigation = {
    prompt_message = "Reached final change in this diff. Open next file with changes?",
    on_request_next_file = nil,
  },
}

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.apply(user)
  if not user then
    return M.defaults()
  end
  return vim.tbl_deep_extend("force", M.defaults(), user)
end

return M
