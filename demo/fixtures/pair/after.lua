--- Bounded LRU cache with TTL.
local Cache = {}
Cache.__index = Cache

local MAX_ENTRIES = 256
local TTL_SECONDS = 300

local function now()
  return os.time()
end

function Cache.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Cache)
  self.max = opts.max or MAX_ENTRIES
  self.ttl = opts.ttl or TTL_SECONDS
  self.entries = {}
  self.keys = {}
  self.hits = 0
  self.misses = 0
  self.evictions = 0
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

function Cache:expired(entry)
  if self.ttl <= 0 then
    return false
  end
  local age = now() - entry.stored_at
  return age >= self.ttl
end

function Cache:get(key)
  local entry = self.entries[key]
  if not entry then
    self.misses = self.misses + 1
    return nil
  end
  if self:expired(entry) then
    self:delete(key)
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
    entry.stored_at = now()
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
    self.evictions = self.evictions + 1
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
    evictions = self.evictions,
    ratio = ratio,
  }
end

return Cache
