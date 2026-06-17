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
    split_blend = 0.3,
    theme = {
      auto_refresh = true,
      semantic_blend = 0.3,
      change_emphasis_strength = 0.16,
      min_background_delta = 0.08,
      colors = {
        add = nil,
        delete = nil,
        change = nil,
        change_emphasis = nil,
      },
      highlights = {},
    },
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
    align_on_jump = true,
    jump_context = 0,
    align_strategy = "change_top",
    initial_focus = "right",
    document_keys = {
      top = "[d",
      bottom = "]d",
    },
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
