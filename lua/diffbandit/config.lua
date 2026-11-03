local M = {}

local defaults = {
  diff = {
    ignore_whitespace = false,
  },
  ui = {
    -- Fixed core by default: min == max. Raise connector_max_width to allow
    -- once-per-document pressure expansion (legacy behaviour).
    connector_width = 9,
    connector_max_width = 9,
    -- When true, paint wedges as Powerline extra symbols (U+E0B8–E0BE) so
    -- xterm.js/VHS fills the cell. Demo/recording only — normal use keeps
    -- Unicode geometric wedges (U+25E2–25E5). Also: vim.g.diffbandit_cell_wedges
    -- or DIFFBANDIT_CELL_WEDGES=1.
    cell_wedges = false,
    right_number_padding = 2,
    scroll_debounce_ms = 16,
    -- Full re-diff after editable right-pane edits (separate from scroll).
    edit_refresh_debounce_ms = 150,
    -- Wall-clock budget for the connector rail solver per repaint; on expiry
    -- it degrades to the bounded plan (routes hidden with recorded reasons)
    -- instead of hanging on pathological dense projections. 0 disables.
    -- One shared deadline covers the initial plan plus width retries.
    route_plan_budget_ms = 25,
    -- Connector renderer. "auto" probes the terminal for the Kitty graphics
    -- protocol (Ghostty, Kitty, Rex, …) and draws smooth bezier ribbons as an
    -- image when supported, falling back to cell glyphs otherwise. "kitty"
    -- forces the image renderer; "cells" always uses glyphs. Also:
    -- vim.g.diffbandit_connector_renderer or DIFFBANDIT_CONNECTOR_RENDERER.
    connector_renderer = "auto",
    kitty = {
      -- "auto" uses temp files when the terminal can read them (local),
      -- else chunked direct transmission (SSH / remote multiplexers).
      transmission = "auto",
      -- zlib-compress direct transmissions (o=z) when libz is available.
      compress = true,
      probe_timeout_ms = 300,
      -- Pixel cap per connector image; larger viewports render at reduced
      -- resolution and the terminal scales them up.
      max_image_px = 4000000,
      -- { w, h } cell size override in pixels (default: measured).
      cell_px = nil,
      -- Curve width in line heights (IntelliJ's 24px divider ≈ 1.45 lines).
      -- The connector core shrinks to the fewest cells that hold it.
      divider_width = 1.45,
      -- Insertion line (add/delete taper end) in line-height fractions,
      -- matched to the terminal underline it continues: thickness, and the
      -- gap between its bottom and the row boundary. Tune per font.
      insertion_line = { thickness = 1 / 18, offset = 1 / 18 },
      -- Colour space of image pixels: "auto" (Display P3 for Ghostty on
      -- macOS, which shows image pixels unconverted but converts text from
      -- sRGB), "srgb", or "display-p3".
      image_colorspace = "auto",
    },
    -- Optional render stage timing (also enabled by DIFFBANDIT_PERF=1).
    -- When log is true (or env set), paints slower than budget_warn_ms are
    -- reported via vim.notify; values live on session._last_render_perf.
    perf = {
      enabled = false,
      log = false,
      budget_warn_ms = 8,
    },
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
      -- Shade the rows covering the visible range of the pane.
      viewport = true,
      -- "auto" draws the overview as a pixel-resolution image whenever the
      -- connector uses the Kitty image renderer (every hunk gets its own
      -- mark instead of sharing a cell row); "cells" always uses cells.
      renderer = "auto",
      -- Lines per overview row below which a short file stops stretching
      -- and takes only the top of the strip. nil = auto: always fill for
      -- the hunk overview; for code shape, characters twice as tall as wide.
      min_reduction = nil,
      -- Show search matches ('hlsearch' active) and the visual selection.
      search = true,
      selection = true,
      -- Click/drag in the overview to jump, mouse wheel to scroll the pane.
      mouse = true,
      -- Image renderer only: draw each line's text shape in syntax colours
      -- (treesitter, else legacy syntax), code_width cells wide. Set false
      -- for the one-column hunk strip (the cell renderer always uses it).
      code_shape = true,
      code_width = 12,
      -- Code shape: only the focused pane's strip is code_width wide; the
      -- other pane's is compact_width (the same shape, squeezed). Focus
      -- moving to a pane swaps them. false: both full width.
      focus_follow = true,
      compact_width = 4,
      -- Edits rebuild the code shape once typing pauses this long.
      code_debounce_ms = 400,
      -- CursorMoved overview repaint (marks already cached; cursor glyph moves).
      debounce_ms = 32,
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
    snap_key = "]s",
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
        file_actions = "a",
        toggle_amend = "<Space>",
        refresh = "R",
        close = "q",
      },
    },
  },
  folder = {
    gutter_width = 7,
    columns = {
      size = true,
      modified = true,
    },
    compare = {
      mode = "digest",
      backend = "auto",
      batch_size = 64,
      max_concurrency = 2,
      debounce_ms = 50,
    },
    filters = {
      include = {},
      exclude = {},
    },
    keys = {
      open = "<CR>",
      alternate_open = "o",
      toggle_expand = "<Space>",
      alternate_toggle_expand = "za",
      expand_all = "zR",
      collapse_all = "zM",
      next_diff = "]c",
      prev_diff = "[c",
      refresh = "R",
      filter = "s",
      close = "q",
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
      snap = "]s",
      toggle_panel = "gzp",
      toggle_local = "gzh",
      toggle_remote = "gzl",
      show_all = "gza",
      close = "q",
    },
  },
  -- Minimap for ordinary editor windows (:DiffBanditMinimap). A float on
  -- the window's right edge; same rendering as the diff view's overview
  -- (ui.overview), with git hunks against the index and diagnostics.
  minimap = {
    -- Open for every eligible window automatically (else per command).
    auto = false,
    -- "auto": a pixel image when the terminal supports Kitty graphics (as
    -- resolved for ui.connector_renderer); "cells": a cell strip.
    renderer = "auto",
    -- Cell-strip width; the image draws the code's shape code_width wide.
    width = 1,
    code_shape = true,
    code_width = 12,
    min_reduction = nil,
    viewport = true,
    cursor = true,
    search = true,
    selection = true,
    mouse = true,
    debounce_ms = 32,
    code_debounce_ms = 400,
    -- Hunks against the git index, refreshed this long after edits.
    git = true,
    git_debounce_ms = 300,
    -- Diagnostics at least this severe ("error" | "warn" | "info" | "hint").
    diagnostics = { enabled = true, min_severity = "warn" },
    -- Windows narrower than this get no minimap.
    min_window_width = 60,
    exclude_filetypes = { "help", "qf", "netrw", "gitcommit", "gitrebase" },
    zindex = 20,
  },
}

function M.defaults()
  return vim.deepcopy(defaults)
end

-- Walk nested config keys, tolerating nil tables along the way:
-- config.section(cfg, "ui", "status") == (((cfg or {}).ui or {}).status or {})
function M.section(cfg, ...)
  local node = cfg
  for _, key in ipairs({ ... }) do
    node = (node or {})[key]
  end
  return node or {}
end

function M.apply(user)
  if not user then
    return M.defaults()
  end
  return vim.tbl_deep_extend("force", M.defaults(), user)
end

return M
