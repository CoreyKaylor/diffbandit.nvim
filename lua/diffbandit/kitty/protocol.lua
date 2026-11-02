-- Kitty graphics protocol encoders (pure: no Neovim window/buffer API).
--
-- Reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/
--
-- DiffBandit draws connector images through Unicode placeholders: the image
-- is transmitted with a *virtual* placement (U=1) and the terminal paints it
-- wherever a cell holds U+10EEEE whose foreground color encodes the image id
-- and whose combining diacritics encode the image row/column. Neovim treats
-- those cells as ordinary text, so clipping, floats, tab switches and pane
-- hiding all work without absolute cursor positioning.
local M = {}

M.PLACEHOLDER = 0x10EEEE

-- gen/rowcolumn-diacritics.txt from kitty (297 entries). Index i (0-based
-- row/column number) maps to DIACRITICS[i + 1].
local DIACRITICS = {
  0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
  0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
  0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
  0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
  0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
  0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
  0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB,
  0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
  0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
  0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
  0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954,
  0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
  0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
  0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
  0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
  0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
  0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
  0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
  0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE,
  0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
  0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
  0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
  0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1,
  0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
  0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
}

M.DIACRITICS = DIACRITICS
-- Largest image row/column index a placeholder can address.
M.MAX_INDEX = #DIACRITICS - 1

-- Base64 payload chunk limit for direct transmission (spec: <= 4096).
M.CHUNK_SIZE = 4096

local ESC_G = "\27_G"
local ST = "\27\\"

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40)
end
M.utf8_char = utf8_char

local PLACEHOLDER_UTF8 = utf8_char(M.PLACEHOLDER)
local DIACRITIC_UTF8 = {}
for i, cp in ipairs(DIACRITICS) do
  DIACRITIC_UTF8[i - 1] = utf8_char(cp)
end

--- One placeholder cell addressing image (row, col), both 0-based. Every
--- cell carries both diacritics so the terminal never has to infer them from
--- a left neighbour (Neovim may redraw partial lines).
function M.placeholder(row, col)
  local r = DIACRITIC_UTF8[row]
  local c = DIACRITIC_UTF8[col]
  if not r or not c then
    return nil
  end
  return PLACEHOLDER_UTF8 .. r .. c
end

--- `count` consecutive placeholder cells on image row `row` starting at
--- image column `col_start`. Returns nil when any index is out of range.
function M.placeholder_run(row, col_start, count)
  local parts = {}
  for i = 0, count - 1 do
    local cell = M.placeholder(row, col_start + i)
    if not cell then
      return nil
    end
    parts[#parts + 1] = cell
  end
  return table.concat(parts)
end

--- 24-bit image id as the "#rrggbb" foreground that selects it.
function M.id_to_hex(id)
  return string.format("#%06x", id % 0x1000000)
end

function M.hex_to_id(hex)
  return tonumber((hex or ""):gsub("^#", ""), 16)
end

-- --- base64 -------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_fallback(data)
  local out = {}
  local n = #data
  for i = 1, n, 3 do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(v / 262144) % 64
    local c2 = math.floor(v / 4096) % 64
    local c3 = math.floor(v / 64) % 64
    local c4 = v % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
      .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end
M._base64_fallback = base64_fallback

function M.base64(data)
  if vim and vim.base64 and vim.base64.encode then
    return vim.base64.encode(data)
  end
  return base64_fallback(data)
end

-- --- commands ------------------------------------------------------------

local function control(keys)
  local parts = {}
  for _, kv in ipairs(keys) do
    if kv[2] ~= nil then
      parts[#parts + 1] = kv[1] .. "=" .. tostring(kv[2])
    end
  end
  return table.concat(parts, ",")
end

--- Transmit RGBA (f=32) pixels and create a virtual placement in one command.
--- opts: id, width, height (px), cols, rows (placement cells), quiet (0..2),
---       medium "d" (direct, chunked base64) or "t" (temp file path),
---       data (raw bytes for "d") or path (for "t"),
---       compressed (true when the payload / file is zlib data: o=z).
--- Returns a list of escape-sequence strings (chunks) in send order.
function M.transmit(opts)
  local keys = {
    { "a", "T" },
    { "U", 1 },
    { "f", 32 },
    { "o", opts.compressed and "z" or nil },
    { "i", opts.id },
    { "s", opts.width },
    { "v", opts.height },
    { "c", opts.cols },
    { "r", opts.rows },
    { "t", opts.medium == "t" and "t" or nil },
    { "q", opts.quiet or 2 },
  }
  if opts.medium == "t" then
    return { ESC_G .. control(keys) .. ";" .. M.base64(opts.path) .. ST }
  end
  local payload = M.base64(opts.data or "")
  local size = opts.chunk_size or M.CHUNK_SIZE
  local total = #payload
  if total <= size then
    return { ESC_G .. control(keys) .. ";" .. payload .. ST }
  end
  local out = {}
  local pos = 1
  local first = true
  while pos <= total do
    local piece = payload:sub(pos, pos + size - 1)
    pos = pos + size
    local more = pos <= total and 1 or 0
    if first then
      keys[#keys + 1] = { "m", more }
      out[#out + 1] = ESC_G .. control(keys) .. ";" .. piece .. ST
      first = false
    else
      out[#out + 1] = ESC_G .. control({ { "m", more }, { "q", opts.quiet or 2 } }) .. ";" .. piece .. ST
    end
  end
  return out
end

--- Capability query: a 1x1 RGB image the terminal validates but never stores.
--- medium "t" probes temp-file transmission (the file must exist).
function M.query(id, medium, path)
  local keys = {
    { "i", id },
    { "s", 1 },
    { "v", 1 },
    { "a", "q" },
    { "t", medium or "d" },
    { "f", 24 },
  }
  local payload = medium == "t" and M.base64(path or "") or "AAAA"
  return ESC_G .. control(keys) .. ";" .. payload .. ST
end

--- Delete an image and free its data (uppercase I).
function M.delete(id)
  return ESC_G .. control({ { "a", "d" }, { "d", "I" }, { "i", id }, { "q", 2 } }) .. ST
end

--- Primary device attributes request: every terminal answers, so it is the
--- probe sentinel (a graphics reply that arrives after it never will).
M.DA1 = "\27[c"

--- Parse a graphics reply ("\27_Gi=31;OK\27\\", with or without the
--- framing). Returns { id = n, ok = bool, message = str } or nil.
function M.parse_response(seq)
  if type(seq) ~= "string" then
    return nil
  end
  local body = seq:match("_G([^\27]*)")
  if not body then
    return nil
  end
  local keys, message = body:match("^([^;]*);(.*)$")
  if not keys then
    return nil
  end
  local id = tonumber(keys:match("i=(%d+)"))
  return { id = id, ok = message == "OK", message = message }
end

--- True when `seq` is a primary device attributes reply (CSI ? ... c).
function M.is_da1(seq)
  return type(seq) == "string" and seq:match("%[%?[%d;]*c") ~= nil
end

return M
