local M = {}

local base_defaults = {
  DiffBanditContext = {},  -- Will be set dynamically with sp color
  DiffBanditLineNumberLeft = { link = "LineNr" },
  DiffBanditLineNumberRight = { link = "LineNr" },
  DiffBanditActiveChunk = {},
  DiffBanditConnectorText = { link = "Normal" },
  DiffBanditSplit = { link = "WinSeparator" },
  DiffBanditHiddenSplit = {},
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

local function color_to_rgb(color)
  if type(color) == "number" then
    return math.floor(color / 65536) % 256, math.floor(color / 256) % 256, color % 256
  end
  if type(color) == "string" and color:match("^#%x%x%x%x%x%x$") then
    return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
  end
  return nil
end

local function blend_color(base, target, amount)
  amount = math.max(0, math.min(1, tonumber(amount) or 0))
  local br, bg, bb = color_to_rgb(base)
  local tr, tg, tb = color_to_rgb(target)
  if not br or not tr then
    return target
  end
  local function mix(a, b)
    return math.floor(a + ((b - a) * amount) + 0.5)
  end
  return (mix(br, tr) * 65536) + (mix(bg, tg) * 256) + mix(bb, tb)
end

local function apply_diff_variants(config)
  local delete_base = adopt_diff_colors("DiffDelete")
  local normal_base = adopt_diff_colors("Normal")
  local ui = (config and config.ui) or {}

  -- Extract or use fallback colors for backgrounds
  local add_bg = get_background_color("DiffAdd", "#C8E6C9")
  local delete_bg = get_background_color("DiffDelete", "#D3D3D3")  -- light gray
  local change_bg = get_background_color("DiffChange", "#E3F2FD")
  local text_bg = get_background_color("DiffText", "#D6EBFF")

  -- Get foreground colors - connector uses normal text
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

  -- Delete background with normal text color (not red)
  apply_group("DiffBanditDelete", {
    bg = ensure_contrast(delete_bg, "#F5F5DC"),
    fg = "NONE",
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

  -- Context highlight - no sp set to avoid conflicts with separator underlines
  apply_group("DiffBanditContext", {
    bg = normal_base.bg,
    fg = normal_base.fg,
  })

  local soft_split_fg = blend_color(normal_base.bg or "#000000", get_foreground_color("LineNr", "#808080"), ui.split_blend or 0.3)
  apply_group("DiffBanditSplit", {
    fg = soft_split_fg,
    bg = normal_base.bg,
  })

  apply_group("DiffBanditHiddenSplit", {
    fg = soft_split_fg,
    bg = normal_base.bg,
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
    underline = true,
    sp = add_bg,
  })

  apply_group("DiffBanditDeleteLeftSeparatorConnector", {
    fg = delete_bg,
    underline = true,
    sp = delete_bg,
  })

  apply_group("DiffBanditDeleteRightSeparatorConnector", {
    fg = delete_bg,
    underline = true,
    sp = delete_bg,
  })

  apply_group("DiffBanditChangeSeparatorConnector", {
    fg = change_bg,
    underline = true,
    sp = change_bg,
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
  apply_group("DiffBanditConnectorExpansionAdd", {
    fg = add_bg,
    bg = normal_base.bg,
  })
  apply_group("DiffBanditConnectorExpansionAddUnderline", {
    fg = add_bg,
    bg = normal_base.bg,
    underline = true,
    sp = add_bg,
  })
  apply_group("DiffBanditConnectorExpansionDelete", {
    fg = delete_bg,
    bg = normal_base.bg,
  })
  apply_group("DiffBanditConnectorExpansionChange", {
    fg = change_bg,
    bg = normal_base.bg,
  })
  apply_group("DiffBanditConnectorDeleteCutout", {
    fg = normal_base.bg,
    bg = delete_bg,
  })

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

  apply_group("DiffBanditLineNumberLeftChange", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = change_bg,
  })

  apply_group("DiffBanditLineNumberRightChange", {
    fg = get_foreground_color("LineNr", "#808080"),
    bg = change_bg,
  })

  -- Underlined variant for origin rows (additions - left pane)
  apply_group("DiffBanditLineNumberLeftUnderline", {
    fg = get_foreground_color("LineNr", "#808080"),
    underline = true,
    sp = add_bg,
  })

  -- Underlined variant for origin rows (deletions - right pane)
  apply_group("DiffBanditLineNumberRightUnderline", {
    fg = get_foreground_color("LineNr", "#808080"),
    underline = true,
    sp = delete_bg,
  })
end

function M.apply(config)
  for group, opts in pairs(base_defaults) do
    apply_group(group, opts)
  end
  apply_diff_variants(config)
end

return M
