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
    scroll_debounce_ms = 16,
    split_blend = 0.3,
    status = {
      enabled = true,
      icons = "auto",
      icon_overrides = {},
    },
    overview = {
      enabled = true,
      width = 1,
      cursor = true,
    },
    hex = {
      enabled = true,
      bytes_per_row = 16,
      max_bytes = 65536,
      show_ascii = true,
      show_offsets = true,
    },
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
  git = {
    default_mode = "all",
    default_scope = "repo",
    binary_view = "hex",
    use_buffer = true,
    include_untracked = true,
    find_renames = true,
    find_copies = false,
    file_keys = {
      next = "]f",
      prev = "[f",
    },
    panel = {
      width = 42,
      commit_height = 10,
      preview_on_cursor = true,
      preview_debounce_ms = 50,
      focus_on_open = "panel",
      icons = "auto",
      staged_indicator = {
        unstaged = "□",
        partial = "◧",
        staged = "▣",
      },
      keys = {
        toggle_stage = "<Space>",
        focus_diff = "<CR>",
        focus_panel = "C",
        focus_commit = "cc",
        toggle_amend = "<Space>",
        refresh = "R",
        close = "q",
      },
    },
  },
  actions = {
    keys = {
      toggle_stage = "<Space>",
      apply_left = ">>",
      apply_right = "<<",
      undo = "u",
    },
    staged_indicator = {
      unstaged = "□",
      staged = "▣",
    },
  },
  merge = {
    result_initial_content = "base",
    auto_apply_non_conflicting = false,
    resolve_on_write = true,
    line_endings = {
      warn = true,
    },
    keys = {
      next_conflict = "]c",
      prev_conflict = "[c",
      accept_local = ">>",
      accept_remote = "<<",
      accept_both = "gb",
      apply_non_conflicting = "gA",
      focus_panel = "C",
      close = "q",
    },
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
