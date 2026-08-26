-- Cached hunks/view/paths. Store hits still compare content identity because
-- git source_cache tables are mutated in place by refresh_source_from_editable.

local diff = require("diffbandit.diff")
local view_builder = require("diffbandit.diff.view")
local connector = require("diffbandit.connector")

local M = {}

local LRU_CAP = 8

local function diff_key(diff_opts)
  diff_opts = diff_opts or {}
  return diff_opts.ignore_whitespace and "iw" or "w"
end

local function source_tick(source)
  local editable = source and source.editable
  local bufnr = editable and editable.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return vim.api.nvim_buf_get_changedtick(bufnr)
  end
  return 0
end

local function digest_text(value)
  value = value or ""
  return tostring(#value) .. ":" .. vim.fn.sha256(value)
end

function M.identity_key(sources, config)
  local left = sources and sources.left or {}
  local right = sources and sources.right or {}
  return table.concat({
    diff_key((config or {}).diff),
    tostring(source_tick(left)),
    digest_text(left.text),
    tostring(source_tick(right)),
    digest_text(right.text),
  }, "|")
end

function M.new_lru(cap)
  return {
    cap = cap or LRU_CAP,
    keys = {},
    map = {},
  }
end

local function lru_touch(lru, key)
  local keys = lru.keys
  for i = 1, #keys do
    if keys[i] == key then
      table.remove(keys, i)
      break
    end
  end
  keys[#keys + 1] = key
end

function M.lru_get(lru, key)
  if not lru or not key then
    return nil
  end
  local model = lru.map[key]
  if model then
    lru_touch(lru, key)
  end
  return model
end

function M.lru_put(lru, key, model)
  if not lru or not key or not model then
    return
  end
  if lru.map[key] then
    lru_touch(lru, key)
  else
    while #lru.keys >= lru.cap do
      local old = table.remove(lru.keys, 1)
      lru.map[old] = nil
    end
    lru.keys[#lru.keys + 1] = key
  end
  lru.map[key] = model
end

local function model_valid(model, dkey)
  return model
    and model.diff_key == dkey
    and type(model.hunks) == "table"
    and type(model.view) == "table"
end

local function ensure_base_paths(model)
  if model and not model.base_paths and model.view then
    model.base_paths = connector.compute_paths(model.view.chunks, model.view.line_meta)
  end
  return model
end

local function hit(model)
  ensure_base_paths(model)
  model.cache_hit = true
  return model, nil
end

-- Session.start often gets a {left, right} wrapper; find the cache entry by
-- source-table pointer so .document is not dropped.
function M.resolve_store(host, sources)
  if not sources then
    return nil
  end
  if sources.document then
    return sources
  end
  local queue = host and host.file_queue
  local cache = queue and queue.source_cache
  if not cache then
    return sources
  end
  local index = host.file_queue_index or queue.index or 1
  local cached = cache[index]
  if cached and cached.left == sources.left and cached.right == sources.right then
    return cached
  end
  for _, entry in pairs(cache) do
    if entry and entry.left == sources.left and entry.right == sources.right then
      return entry
    end
  end
  return sources
end

function M.same_identity(host, sources, config)
  if not host or not host.document_identity or not sources then
    return false
  end
  return host.document_identity == M.identity_key(sources, config or host.config)
end

function M.get_or_build(sources, config, opts)
  opts = opts or {}
  if not sources or not sources.left or not sources.right then
    return nil, "missing sources"
  end
  config = config or {}
  local dkey = diff_key(config.diff)
  local store = opts.store or sources
  local lru = opts.lru
  local identity = M.identity_key(sources, config)

  local attached = store.document
  if attached and (not model_valid(attached, dkey) or attached.identity ~= identity) then
    store.document = nil
    attached = nil
  end
  if attached then
    return hit(attached)
  end

  if lru then
    local cached = M.lru_get(lru, identity)
    if model_valid(cached, dkey) then
      store.document = cached
      return hit(cached)
    end
  end

  local left_lines = sources.left.lines or {}
  local right_lines = sources.right.lines or {}
  local hunks, err = diff.compute_hunks_from_lines(left_lines, right_lines, config.diff or {})
  if err then
    return nil, err
  end
  if type(hunks) ~= "table" then
    hunks = {}
  end
  local view = view_builder.build(left_lines, right_lines, hunks, config)
  local model = {
    hunks = hunks,
    view = view,
    diff_key = dkey,
    identity = identity,
    cache_hit = false,
  }
  ensure_base_paths(model)
  store.document = model
  if lru then
    M.lru_put(lru, identity, model)
  end
  return model, nil
end

return M
