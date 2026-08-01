--- Bounded LRU cache.
local Cache = {}
Cache.__index = Cache

local MAX_ENTRIES = 128

local function now()
  return os.time()
end

function Cache.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Cache)
  self.max = opts.max or MAX_ENTRIES
  self.entries = {}
  self.keys = {}
  self.hits = 0
  self.misses = 0
  return self
end

local function detach(self, key)
  for i, other in ipairs(self.keys) do
    if other == key then
      table.remove(self.keys, i)
      return i
    end
  end
end

local function promote(self, key)
  detach(self, key)
  table.insert(self.keys, key)
end

function Cache:get(key)
  local entry = self.entries[key]
  if not entry then
    self.misses = self.misses + 1
    return nil
  end
  promote(self, key)
  self.hits = self.hits + 1
  return entry.value
end

function Cache:set(key, value)
  local entry = self.entries[key]
  if entry then
    entry.value = value
    promote(self, key)
    return
  end
  self.entries[key] = {
    value = value,
    stored_at = now(),
  }
  table.insert(self.keys, key)
  self:evict()
end

function Cache:evict()
  while #self.keys > self.max do
    local old = self.keys[1]
    table.remove(self.keys, 1)
    self.entries[old] = nil
  end
end

function Cache:delete(key)
  if not self.entries[key] then
    return false
  end
  self.entries[key] = nil
  detach(self, key)
  return true
end

function Cache:dump()
  local lines = {}
  for i, key in ipairs(self.keys) do
    lines[#lines + 1] = i .. "  " .. key
  end
  return table.concat(lines, "\n")
end

function Cache:clear()
  self.entries = {}
  self.keys = {}
end

function Cache:stats()
  local seen = self.hits + self.misses
  local ratio = 0
  if seen > 0 then
    ratio = self.hits / seen
  end
  return {
    size = #self.keys,
    hits = self.hits,
    misses = self.misses,
    ratio = ratio,
  }
end

return Cache
