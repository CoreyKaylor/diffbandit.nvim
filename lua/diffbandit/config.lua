local M = {}

local defaults = {
  diff = {
    algorithm = "myers",
    linematch = 60,
    ignore_whitespace = false,
    result_type = "indices",
    word_diff = false,
  },
  ui = {
    connector_width = 3,
    placeholder_char = " ",
    connectors = {
      context = "   ",
      origin_add = "──",
      origin_delete = "──",
      change = {
        single = "──",
        start = "╭─",
        mid = "│ ",
        finish = "╰─",
      },
      add = {
        single = "──",
        start = "╭ ",
        mid = "│ ",
        finish = "╰ ",
      },
      delete = {
        single = "──",
        start = " ╮",
        mid = " │",
        finish = " ╯",
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
