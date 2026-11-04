-- Colour-space handling for image pixels.
--
-- Ghostty on macOS renders into Display P3. Text colours are interpreted as
-- sRGB and converted (load_color in its Metal shader, with the default
-- window-colorspace = srgb), but Kitty image pixels are shown as-is
-- (image_fragment), i.e. as if they were already Display P3. The same
-- #RRGGBB therefore looks more saturated in an image than in a cell
-- background, and a 1px image line next to an underline reads heavier.
-- Converting the palette to Display P3 before rasterizing makes ribbons,
-- bands and underlines render identically.
local M = {}

-- Linear sRGB -> linear Display P3 (both D65), as used by Ghostty.
local SRGB_TO_P3 = {
  { 0.8224621, 0.1775380, 0.0000000 },
  { 0.0331941, 0.9668058, 0.0000000 },
  { 0.0170827, 0.0723974, 0.9105199 },
}

local function linearize(v)
  v = v / 255
  if v <= 0.04045 then
    return v / 12.92
  end
  return ((v + 0.055) / 1.055) ^ 2.4
end

local function unlinearize(v)
  v = math.max(0, math.min(1, v))
  if v <= 0.0031308 then
    v = v * 12.92
  else
    v = 1.055 * v ^ (1 / 2.4) - 0.055
  end
  return math.floor(v * 255 + 0.5)
end

--- { r, g, b } (0-255, sRGB) -> { r, g, b } (0-255, Display P3).
function M.srgb_to_display_p3(rgb)
  local lin = { linearize(rgb[1]), linearize(rgb[2]), linearize(rgb[3]) }
  local out = {}
  for i = 1, 3 do
    local m = SRGB_TO_P3[i]
    out[i] = unlinearize(m[1] * lin[1] + m[2] * lin[2] + m[3] * lin[3])
  end
  return out
end

--- Colour space image pixels must be encoded in for this terminal:
--- ui.kitty.image_colorspace = "srgb" | "display-p3" | "auto". "auto" picks
--- display-p3 for Ghostty on macOS (detected through GHOSTTY_RESOURCES_DIR,
--- which Ghostty exports and multiplexers such as herdr inherit) and srgb
--- everywhere else. Set "srgb" if Ghostty runs with window-colorspace =
--- display-p3 (then text is not converted either).
function M.image_colorspace(config, env)
  local cfg = ((((config or {}).ui or {}).kitty) or {}).image_colorspace
  if cfg == "srgb" or cfg == "display-p3" then
    return cfg
  end
  local outer = nil
  if not env then
    local ok, detect = pcall(require, "diffbandit.kitty.detect")
    outer = ok and detect.outer_terminal() or nil
  end
  env = env or {
    -- Inside tmux the client terminal is known exactly; outside it, Ghostty
    -- exports GHOSTTY_RESOURCES_DIR (also inherited by multiplexers).
    ghostty = (outer and outer:lower():find("ghostty", 1, true) ~= nil)
      or (outer == nil and vim.env.GHOSTTY_RESOURCES_DIR ~= nil and vim.env.GHOSTTY_RESOURCES_DIR ~= ""),
    mac = vim.fn.has("mac") == 1,
    ssh = vim.env.SSH_CONNECTION ~= nil and vim.env.SSH_CONNECTION ~= "",
  }
  if env.ghostty and env.mac and not env.ssh then
    return "display-p3"
  end
  return "srgb"
end

return M
