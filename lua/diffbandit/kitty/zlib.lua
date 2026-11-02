-- Optional zlib (RFC 1950) compression for Kitty image payloads (o=z), via
-- LuaJIT ffi + the system libz. Connector images are mostly transparent, so
-- compression shrinks direct (base64) transmissions by an order of magnitude.
-- Returns nil whenever ffi or libz is unavailable; callers send uncompressed.
local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
local lib = nil

if ok_ffi then
  pcall(ffi.cdef, [[
    unsigned long compressBound(unsigned long sourceLen);
    int compress2(uint8_t *dest, unsigned long *destLen,
                  const uint8_t *source, unsigned long sourceLen, int level);
    int uncompress(uint8_t *dest, unsigned long *destLen,
                   const uint8_t *source, unsigned long sourceLen);
  ]])
  for _, name in ipairs({ "z", "libz.so.1", "libz.dylib" }) do
    local ok, handle = pcall(ffi.load, name)
    if ok and handle then
      lib = handle
      break
    end
  end
end

function M.available()
  return lib ~= nil
end

local out_buf, out_cap = nil, 0
local len_box = ok_ffi and ffi.new("unsigned long[1]") or nil

--- Compress `data` (string) at `level` (default 1: fastest). nil on failure.
function M.compress(data, level)
  if not lib then
    return nil
  end
  local ok, result = pcall(function()
    local n = #data
    local bound = tonumber(lib.compressBound(n))
    if bound > out_cap then
      out_buf = ffi.new("uint8_t[?]", bound)
      out_cap = bound
    end
    len_box[0] = bound
    local rc = lib.compress2(out_buf, len_box, ffi.cast("const uint8_t *", data), n, level or 1)
    if rc ~= 0 then
      return nil
    end
    return ffi.string(out_buf, tonumber(len_box[0]))
  end)
  if ok then
    return result
  end
  return nil
end

--- Inverse of compress for a known decompressed size (tests / diagnostics).
function M.uncompress(data, size)
  if not lib then
    return nil
  end
  local ok, result = pcall(function()
    local dest = ffi.new("uint8_t[?]", size)
    local len = ffi.new("unsigned long[1]", size)
    local rc = lib.uncompress(dest, len, ffi.cast("const uint8_t *", data), #data)
    if rc ~= 0 then
      return nil
    end
    return ffi.string(dest, tonumber(len[0]))
  end)
  return ok and result or nil
end

return M
