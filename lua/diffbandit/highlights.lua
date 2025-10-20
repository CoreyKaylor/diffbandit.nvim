local M = {}

local base_defaults = {
  DiffBanditContext = {},  -- Will be set dynamically with sp color
  DiffBanditLineNumberLeft = { link = "LineNr" },
  DiffBanditLineNumberRight = { link = "LineNr" },
  DiffBanditActiveChunk = {},
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
  local delete_base = adopt_diff_colors("DiffDelete")
  local normal_base = adopt_diff_colors("Normal")

  -- Extract or use fallback colors for backgrounds
  local add_bg = get_background_color("DiffAdd", "#C8E6C9")
  local delete_bg = get_background_color("DiffDelete", "#F5E6E6")
  local change_bg = get_background_color("DiffChange", "#E3F2FD")
  local text_bg = get_background_color("DiffText", "#D6EBFF")

  -- Get foreground colors
  local delete_fg = delete_base.fg or normal_base.fg
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
    bg = ensure_contrast(add_bg, "#C8E6C9"),
    fg = "NONE",
  })

  apply_group("DiffBanditDelete", {
    bg = delete_bg,
    fg = delete_fg,
  })

  apply_group("DiffBanditChangeLeft", {
    bg = ensure_contrast(change_bg, "#E3F2FD"),
    fg = "NONE",
    underline = false,
  })

  apply_group("DiffBanditChangeRight", {
    bg = ensure_contrast(change_bg, "#E3F2FD"),
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

  -- Context highlight with sp set so underlines combine properly
  apply_group("DiffBanditContext", {
    bg = normal_base.bg,
    fg = normal_base.fg,
    sp = add_bg,  -- Default sp for underline combining
  })

  -- Separator line highlights for text buffers (use underline attribute)
  apply_group("DiffBanditAddLeftSeparator", {
    underline = true,
    sp = add_bg,
  })

  apply_group("DiffBanditDeleteRightSeparator", {
    underline = true,
    sp = delete_bg,
  })

  -- Separator line highlights for connector buffer (use fg for overlay)
  apply_group("DiffBanditAddLeftSeparatorConnector", {
    fg = add_bg,
  })

  apply_group("DiffBanditDeleteLeftSeparatorConnector", {
    fg = delete_bg,
  })

  apply_group("DiffBanditDeleteRightSeparatorConnector", {
    fg = delete_bg,
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

  -- Stroke colors for connector routing (use background colors for visual continuity with diff regions)
  apply_group("DiffBanditConnectorAddLine", { fg = add_bg })
  apply_group("DiffBanditConnectorDeleteLine", { fg = delete_bg })
  apply_group("DiffBanditConnectorChangeLine", { fg = change_bg })

  -- Expansion glyphs: foreground matches the background color for seamless visual bridging
  -- The ◥/◤ triangles appear with fg color matching the add/delete background, creating
  -- a visual connection from the underline to the colored background region
  apply_group("DiffBanditConnectorExpansionAdd", { fg = add_bg })
  apply_group("DiffBanditConnectorExpansionDelete", { fg = delete_bg })

  apply_group("DiffBanditConnectorContext", {
    bg = normal_base.bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  -- Variants for line numbers with diff backgrounds (for visual text overlay)
  apply_group("DiffBanditLineNumberRightAdd", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = add_bg,
  })

  apply_group("DiffBanditLineNumberLeftDelete", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = delete_bg,
  })

  -- Underlined variant for origin rows
  apply_group("DiffBanditLineNumberLeftUnderline", {
    fg = get_foreground_color("LineNr", "#808080"),
    underline = true,
    sp = add_bg,
  })
end

function M.apply()
  for group, opts in pairs(base_defaults) do
    apply_group(group, opts)
  end
  apply_diff_variants()
end

return M
