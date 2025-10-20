local M = {}

local base_defaults = {
  DiffBanditContext = { link = "Normal" },
  DiffBanditLineNumberLeft = { link = "LineNr" },
  DiffBanditLineNumberRight = { link = "LineNr" },
  DiffBanditActiveChunk = {},
  DiffBanditConnectorGlyph = { link = "LineNr" },
  DiffBanditConnectorSeparator = { link = "Normal" },
  DiffBanditConnectorText = { link = "Normal" },
  -- Neutral cursorline so it doesn't wash out range backgrounds
  DiffBanditCursorLine = { bg = "NONE" },
}

local function apply_group(group, opts)
  vim.api.nvim_set_hl(0, group, opts)
end

local function adopt_diff_colors(base_name)
  local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = base_name, link = false })
  if not ok then
    return {}
  end
  return base
end

local function get_background_color(hl_group, fallback)
  local colors = adopt_diff_colors(hl_group)
  return colors.bg or fallback
end

local function get_foreground_color(hl_group, fallback)
  local colors = adopt_diff_colors(hl_group)
  return colors.fg or fallback
end

local function apply_diff_variants()
  local add_base = adopt_diff_colors("DiffAdd")
  local delete_base = adopt_diff_colors("DiffDelete")
  local change_base = adopt_diff_colors("DiffChange")
  local text_base = adopt_diff_colors("DiffText")
  local normal_base = adopt_diff_colors("Normal")

  -- Extract or use fallback colors for backgrounds
  -- Use light but visible colors to match IntelliJ's subtle but clear aesthetic
  local add_bg = get_background_color("DiffAdd", "#E7F6EA")
  local delete_bg = get_background_color("DiffDelete", "#FBE9E7")
  local change_bg = get_background_color("DiffChange", "#E3F2FD")
  local text_bg = get_background_color("DiffText", "#D6EBFF")

  -- Get foreground colors
  local add_fg = add_base.fg or normal_base.fg
  local delete_fg = delete_base.fg or normal_base.fg
  local change_fg = change_base.fg or normal_base.fg
  local connector_fg = normal_base.fg

  -- Full-line background highlights for additions (use normal text color, only background is colored)
  local normal_bg = normal_base.bg
  local function ensure_contrast(bg, fallback)
    if not bg or (normal_bg and bg == normal_bg) then
      return fallback
    end
    return bg
  end

  -- Add background only; keep foreground as NONE so default text color is preserved
  apply_group("DiffBanditAdd", {
    bg = ensure_contrast(add_bg, "#2e7d32"),
    fg = "NONE",
  })

  apply_group("DiffBanditDelete", {
    bg = delete_bg,
    fg = delete_fg,
  })

  apply_group("DiffBanditChange", {
    bg = change_bg,
    fg = change_fg,
  })

  -- Unified highlights for changes: both sides show the same blue background (matching IntelliJ)
  apply_group("DiffBanditChangeLeft", {
    bg = ensure_contrast(change_bg, "#1565c0"),
    fg = "NONE",
    underline = false,
  })

  apply_group("DiffBanditChangeRight", {
    bg = ensure_contrast(change_bg, "#1565c0"),
    fg = "NONE",
    underline = false,
  })

  -- Emphasis for intra-line changed tokens (slightly stronger than change_bg)
  apply_group("DiffBanditChangeEmphasis", {
    bg = text_bg,
    fg = "NONE",
    underline = false,
  })

  -- Special highlight for left side of additions (shows underline with normal text color)
  apply_group("DiffBanditAddLeft", {
    bg = add_bg,
    fg = "NONE",
    underline = true,
    sp = add_bg,
  })

  -- Separator line for left filler on additions (only underline, no background)
  -- Use the subtle green background color to match the right side visual flow
  apply_group("DiffBanditAddLeftSeparator", {
    underline = true,
    sp = add_bg,  -- Matches the green background on the right side
  })

  -- Separator line for right filler on deletions (only underline, no background)
  -- Use a visible red/beige color for the underline, not the light background
  apply_group("DiffBanditDeleteRightSeparator", {
    underline = true,
    sp = "#ef4444",  -- Visible red (equivalent to red-500)
  })

  -- Filler/placeholder highlights
  apply_group("DiffBanditGap", {
    bg = normal_base.bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  apply_group("DiffBanditPlaceholder", {
    bg = normal_base.bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  -- Connector backgrounds (full-line) - these will be applied to entire connector lines
  apply_group("DiffBanditConnectorAdd", {
    bg = add_bg,
    fg = connector_fg,
  })

  apply_group("DiffBanditConnectorDelete", {
    bg = delete_bg,
    fg = connector_fg,
  })

  apply_group("DiffBanditConnectorChange", {
    bg = change_bg,
    fg = connector_fg,
  })

  -- Stroke colors for connector routing (use foreground colors for better visibility)
  apply_group("DiffBanditConnectorAddLine", { fg = add_fg })
  apply_group("DiffBanditConnectorDeleteLine", { fg = delete_fg })
  apply_group("DiffBanditConnectorChangeLine", { fg = change_fg })

  apply_group("DiffBanditConnectorContext", {
    bg = normal_base.bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  apply_group("DiffBanditConnectorBackground", {
    bg = normal_base.bg,
  })

  -- Variants for line numbers and glyphs with diff backgrounds (for visual text overlay)
  apply_group("DiffBanditLineNumberRightAdd", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = add_bg,
  })

  apply_group("DiffBanditConnectorGlyphAdd", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = add_bg,
  })

  apply_group("DiffBanditLineNumberLeftDelete", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = delete_bg,
  })

  apply_group("DiffBanditConnectorGlyphDelete", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = delete_bg,
  })
end

function M.apply()
  for group, opts in pairs(base_defaults) do
    apply_group(group, opts)
  end
  apply_diff_variants()
end

return M
