-- Text shape + syntax colours for the code-shape overview image.
--
-- build() turns a pane's source lines into per-line runs of display columns
-- with a colour each: { [line] = { { c0, c1, rgb }, ... } } (c1 exclusive,
-- whitespace skipped). Colours come from treesitter highlight captures when
-- a parser is available, from legacy syntax for short files otherwise, and
-- from Normal's foreground as a last resort. line_runs() is pure.
local M = {}

local byte = string.byte

local function hl_rgb(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  local v = ok and hl and hl.fg or nil
  if type(v) ~= "number" then
    return nil
  end
  return { math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256 }
end

--- Display-column runs of one line. `colors` maps 1-based byte index to an
--- rgb table (nil = default). Tabs expand to `tabstop`; a UTF-8 sequence
--- takes one column. Columns past `max_cols` are dropped.
function M.line_runs(text, colors, default, tabstop, max_cols)
  local runs = {}
  local col = 0
  local cur
  tabstop = math.max(1, tabstop or 8)
  local n = #text
  local i = 1
  while i <= n and col < max_cols do
    local b = byte(text, i)
    local len = 1
    if b >= 0xF0 then
      len = 4
    elseif b >= 0xE0 then
      len = 3
    elseif b >= 0xC0 then
      len = 2
    end
    if b == 9 then
      col = (math.floor(col / tabstop) + 1) * tabstop
      cur = nil
    elseif b == 32 then
      col = col + 1
      cur = nil
    else
      local rgb = (colors and colors[i]) or default
      if cur and cur[3] == rgb and cur[2] == col then
        cur[2] = col + 1
      else
        cur = { col, col + 1, rgb }
        runs[#runs + 1] = cur
      end
      col = col + 1
    end
    i = i + len
  end
  return runs
end

-- Capture name -> rgb (or false), most specific group first.
local function capture_color(cache, name, lang)
  local key = name .. "." .. lang
  local v = cache[key]
  if v ~= nil then
    return v or nil
  end
  local rgb = hl_rgb("@" .. key)
  local parts = name
  while not rgb and parts do
    rgb = hl_rgb("@" .. parts)
    parts = parts:match("^(.*)%.[^.]*$")
  end
  cache[key] = rgb or false
  return rgb
end

-- Treesitter: { [line] = { [byte] = rgb } } or nil when unavailable.
local function treesitter_colors(buf, lines, encode)
  local line_count = #lines
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local ft = vim.bo[buf].filetype
  if not ft or ft == "" then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
  if not ok or not parser then
    return nil
  end
  local okq, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not okq or not query then
    return nil
  end
  local okp, trees = pcall(function()
    return parser:parse()
  end)
  if not okp or not trees or not trees[1] then
    return nil
  end
  local root = trees[1]:root()
  local out, cache = {}, {}
  local encoded = {}
  for id, node in query:iter_captures(root, buf, 0, line_count) do
    local name = query.captures[id]
    if name and name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
      local rgb = capture_color(cache, name, lang)
      if rgb then
        local enc = encoded[rgb]
        if not enc then
          enc = encode(rgb)
          encoded[rgb] = enc
        end
        local sr, sc, er, ec = node:range()
        for row = sr, math.min(er, line_count - 1) do
          local line = out[row + 1]
          if not line then
            line = {}
            out[row + 1] = line
          end
          local from = row == sr and sc or 0
          local to = math.min(row == er and ec or math.huge, #(lines[row + 1] or ""))
          for b = from + 1, to do
            line[b] = enc
          end
        end
      end
    end
  end
  return out
end

-- Legacy syntax: colour each run of non-blank bytes by the syntax group at
-- its first byte. Only for short files (synID is per call).
local function syntax_colors(buf, lines, encode, max_lines)
  if #lines > max_lines then
    return nil
  end
  local ok, has = pcall(function()
    return vim.b[buf].current_syntax ~= nil
  end)
  if not ok or not has then
    return nil
  end
  local out = {}
  local by_id = {}
  pcall(vim.api.nvim_buf_call, buf, function()
    for l, text in ipairs(lines) do
      local line
      local s = 1
      while true do
        local a, b = text:find("%S+", s)
        if not a then
          break
        end
        local id = vim.fn.synIDtrans(vim.fn.synID(l, a, 1))
        if id ~= 0 then
          local rgb = by_id[id]
          if rgb == nil then
            local hex = vim.fn.synIDattr(id, "fg#")
            rgb = false
            if type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") then
              rgb = encode({ tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16) })
            end
            by_id[id] = rgb
          end
          if rgb then
            line = line or {}
            for i = a, b do
              line[i] = rgb
            end
          end
        end
        s = b + 1
      end
      out[l] = line
    end
  end)
  return out
end

--- opts = { buf?, max_cols, tabstop?, encode? (rgb -> rgb, colour space),
---          syntax_max_lines? }. Returns { runs = { [line] = runs }, source =
---          "treesitter" | "syntax" | "plain" }.
function M.build(lines, opts)
  opts = opts or {}
  local encode = opts.encode or function(rgb)
    return rgb
  end
  local default = encode(hl_rgb("Normal") or { 200, 200, 200 })
  local colors = treesitter_colors(opts.buf, lines, encode)
  local source = "treesitter"
  if not colors and opts.buf then
    colors = syntax_colors(opts.buf, lines, encode, opts.syntax_max_lines or 3000)
    source = "syntax"
  end
  if not colors then
    colors = {}
    source = "plain"
  end
  local runs = {}
  local max_cols = math.max(1, opts.max_cols or 120)
  for l, text in ipairs(lines) do
    runs[l] = M.line_runs(text, colors[l], default, opts.tabstop, max_cols)
  end
  return { runs = runs, source = source }
end

return M
