local M = {}

local base_defaults = {
  DiffBanditContext = {},  -- Will be set dynamically with sp color
  DiffBanditLineNumberLeft = { link = "LineNr" },
  DiffBanditLineNumberRight = { link = "LineNr" },
  DiffBanditActiveChunk = {},
  DiffBanditConnectorText = { link = "Normal" },
  DiffBanditSplit = { link = "WinSeparator" },
  DiffBanditHiddenSplit = {},
  DiffBanditStatus = { link = "StatusLine" },
  DiffBanditStatusLine = { link = "StatusLine" },
  DiffBanditStatusAccent = { link = "StatusLine" },
  DiffBanditStatusMuted = { link = "StatusLineNC" },
  DiffBanditMutedText = { link = "Comment" },
  DiffBanditAccentText = { link = "Identifier" },
  DiffBanditOverviewContext = { link = "Normal" },
  DiffBanditOverviewCursor = { link = "CursorLineNr" },
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

local function color_to_number(color)
  if type(color) == "number" then
    return color
  end
  local r, g, b = color_to_rgb(color)
  if not r then
    return nil
  end
  return (r * 65536) + (g * 256) + b
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

local function luminance(color)
  local r, g, b = color_to_rgb(color)
  if not r then
    return 0
  end
  return ((0.2126 * r) + (0.7152 * g) + (0.0722 * b)) / 255
end

local function color_delta(a, b)
  local ar, ag, ab = color_to_rgb(a)
  local br, bg, bb = color_to_rgb(b)
  if not ar or not br then
    return 1
  end
  local dr = (ar - br) / 255
  local dg = (ag - bg) / 255
  local db = (ab - bb) / 255
  return math.sqrt((dr * dr) + (dg * dg) + (db * db)) / math.sqrt(3)
end

local function readable_background(bg, normal_bg, min_delta)
  if not bg then
    return nil
  end
  bg = color_to_number(bg)
  if not bg then
    return nil
  end
  if normal_bg and color_delta(bg, normal_bg) < min_delta then
    return nil
  end
  return bg
end

local function default_background(kind, normal_bg)
  local dark = luminance(normal_bg) < 0.5
  if kind == "add" then
    return dark and 0x123D2B or 0xDDF4E6
  elseif kind == "delete" then
    return dark and 0x4A2426 or 0xF8D7DA
  end
  return dark and 0x253344 or 0xDDEBFF
end

local function semantic_background(kind, hl_group, normal_bg, theme)
  local overrides = (theme.colors or {})
  local override = readable_background(overrides[kind], normal_bg, 0)
  if override then
    return override
  end

  local min_delta = tonumber(theme.min_background_delta) or 0.08
  local colors = adopt_diff_colors(hl_group)
  local bg = readable_background(colors.bg, normal_bg, min_delta)
  if bg then
    return bg
  end

  local fg = color_to_number(colors.fg)
  if fg then
    local blended = blend_color(normal_bg, fg, theme.semantic_blend or 0.3)
    bg = readable_background(blended, normal_bg, min_delta)
    if bg then
      return bg
    end
  end

  return default_background(kind, normal_bg)
end

local function change_emphasis_background(change_bg, normal_bg, normal_fg, theme)
  local overrides = theme.colors or {}
  local override = color_to_number(overrides.change_emphasis)
  if override then
    return override
  end

  local dark = luminance(normal_bg) < 0.5
  local target = dark and normal_fg or 0x000000
  local amount = tonumber(theme.change_emphasis_strength) or 0.16
  local emphasis = blend_color(change_bg, target, amount)
  local min_delta = (tonumber(theme.min_background_delta) or 0.08) * 0.45
  if color_delta(emphasis, change_bg) < min_delta then
    emphasis = blend_color(change_bg, target, math.min(1, amount + 0.06))
  end
  return emphasis
end

local function apply_theme_overrides(theme)
  for group, opts in pairs(theme.highlights or {}) do
    if type(group) == "string" and type(opts) == "table" then
      apply_group(group, opts)
    end
  end
end

local function apply_diff_variants(config)
  local normal_base = adopt_diff_colors("Normal")
  local ui = (config and config.ui) or {}
  local theme = ui.theme or {}

  local normal_bg = color_to_number(normal_base.bg) or 0x000000
  local normal_fg = color_to_number(normal_base.fg) or 0xFFFFFF
  local add_bg = semantic_background("add", "DiffAdd", normal_bg, theme)
  local delete_bg = semantic_background("delete", "DiffDelete", normal_bg, theme)
  local change_bg = semantic_background("change", "DiffChange", normal_bg, theme)
  local text_bg = change_emphasis_background(change_bg, normal_bg, normal_fg, theme)

  -- Get foreground colors - connector uses normal text
  local connector_fg = normal_fg

  -- Add background only; keep foreground as NONE so default text color is preserved
  apply_group("DiffBanditAdd", {
    bg = add_bg,
    fg = "NONE",
  })

  -- Delete background with normal text color (not red)
  apply_group("DiffBanditDelete", {
    bg = delete_bg,
    fg = "NONE",
  })

  apply_group("DiffBanditChangeLeft", {
    bg = change_bg,
    fg = "NONE",
    underline = false,
  })

  apply_group("DiffBanditChangeRight", {
    bg = change_bg,
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
    bg = normal_bg,
    fg = "NONE",
  })

  local soft_split_fg = blend_color(normal_base.bg or "#000000", get_foreground_color("LineNr", "#808080"), ui.split_blend or 0.3)
  apply_group("DiffBanditSplit", {
    fg = soft_split_fg,
    bg = normal_bg,
  })

  apply_group("DiffBanditHiddenSplit", {
    fg = normal_bg,
    bg = normal_bg,
  })

  local status_bg = blend_color(normal_bg, get_foreground_color("LineNr", "#808080"), 0.08)
  local status_muted = get_foreground_color("Comment", "#808080")
  local status_accent = get_foreground_color("Identifier", normal_fg)
  apply_group("DiffBanditStatus", {
    bg = status_bg,
    fg = normal_fg,
  })
  apply_group("DiffBanditStatusLine", {
    bg = status_bg,
    fg = status_muted,
  })
  apply_group("DiffBanditStatusAccent", {
    bg = status_bg,
    fg = status_accent,
    bold = true,
  })
  apply_group("DiffBanditStatusMuted", {
    bg = status_bg,
    fg = status_muted,
  })
  apply_group("DiffBanditMutedText", {
    bg = "NONE",
    fg = status_muted,
  })
  apply_group("DiffBanditAccentText", {
    bg = "NONE",
    fg = status_accent,
    bold = true,
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
    bg = normal_bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  apply_group("DiffBanditPlaceholder", {
    bg = normal_bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  apply_group("DiffBanditEmptyNotice", {
    bg = normal_bg,
    fg = get_foreground_color("Comment", "#808080"),
    italic = true,
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
  apply_group("DiffBanditConnectorAddLine", { fg = add_bg, bold = true })
  apply_group("DiffBanditConnectorDeleteLine", { fg = delete_bg, bold = true })
  apply_group("DiffBanditConnectorChangeLine", { fg = change_bg, bold = true })

  -- Expansion glyphs: foreground matches the background color for seamless visual bridging
  -- The ◥/◤ triangles appear with fg color matching the add/delete background, creating
  -- a visual connection from the underline to the colored background region
  apply_group("DiffBanditConnectorExpansionAdd", {
    fg = add_bg,
    bg = normal_bg,
    bold = true,
  })
  apply_group("DiffBanditConnectorExpansionAddUnderline", {
    fg = add_bg,
    bg = normal_bg,
    underline = true,
    sp = add_bg,
    bold = true,
  })
  apply_group("DiffBanditConnectorExpansionDelete", {
    fg = delete_bg,
    bg = normal_bg,
    bold = true,
  })
  apply_group("DiffBanditConnectorExpansionChange", {
    fg = change_bg,
    bg = normal_bg,
    bold = true,
  })

  apply_group("DiffBanditConnectorContext", {
    bg = normal_bg,
    fg = get_foreground_color("Comment", "#808080"),
  })

  apply_group("DiffBanditOverviewContext", {
    bg = normal_bg,
    fg = normal_bg,
  })
  apply_group("DiffBanditOverviewAdd", {
    bg = add_bg,
    fg = add_bg,
  })
  apply_group("DiffBanditOverviewDelete", {
    bg = delete_bg,
    fg = delete_bg,
  })
  apply_group("DiffBanditOverviewChange", {
    bg = change_bg,
    fg = change_bg,
  })
  apply_group("DiffBanditOverviewCursor", {
    fg = normal_fg,
    underline = true,
    sp = normal_fg,
    bold = true,
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

  apply_theme_overrides(theme)
end

function M.apply(config)
  for group, opts in pairs(base_defaults) do
    apply_group(group, opts)
  end
  apply_diff_variants(config)
end

return M
