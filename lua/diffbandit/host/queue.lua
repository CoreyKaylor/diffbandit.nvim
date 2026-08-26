-- Shared file-queue helpers for Session, Merge, and CommitPanel hosts.
local nvim = require("diffbandit.util.nvim")
local diff_document = require("diffbandit.diff.document")
local M = {}

function M.load_sources(host, index, step)
  local queue = host and host.file_queue
  if not queue or type(queue.load) ~= "function" then
    return nil, nil, "no file queue configured"
  end

  local count = #(queue.entries or {})
  local current = index
  while current >= 1 and current <= count do
    local loaded, err = queue.load(current)
    if loaded and loaded.left and loaded.right then
      -- Return the cache entry as-is so a document model on it survives.
      return loaded, current, nil
    end
    nvim.notify_warn("skipping " .. tostring(err or "unreadable git file"))
    current = current + step
  end

  return nil, nil, "no readable changed file"
end

function M.set_index(host, index)
  if not host then
    return
  end
  host.file_queue_index = index
  if host.file_queue then
    host.file_queue.index = index
  end
end

function M.current_index(host)
  local queue = host and host.file_queue
  if not queue then
    return nil
  end
  return host.file_queue_index or queue.index or 1
end

function M.current_entry(host)
  local queue = host and host.file_queue
  if not queue then
    return nil
  end
  return queue.entries and queue.entries[M.current_index(host)]
end

function M.prefetch_neighbors(host, index, delay)
  local queue = host and host.file_queue
  if not queue or type(queue.load) ~= "function" then
    return
  end
  host.prefetch_token = (host.prefetch_token or 0) + 1
  local token = host.prefetch_token
  vim.defer_fn(function()
    if host.disposed or host.prefetch_token ~= token then
      return
    end
    local center = index or M.current_index(host) or 1
    local neighbors = {}
    for _, neighbor in ipairs({ center - 1, center + 1 }) do
      if neighbor >= 1 and neighbor <= #(queue.entries or {}) then
        neighbors[#neighbors + 1] = neighbor
      end
    end
    local i = 1
    local function prefetch_one()
      if host.disposed or host.prefetch_token ~= token then
        return
      end
      local neighbor = neighbors[i]
      if not neighbor then
        return
      end
      i = i + 1
      pcall(queue.load, neighbor)
      local loaded = queue.source_cache and queue.source_cache[neighbor]
      if loaded and loaded.left and loaded.right then
        pcall(diff_document.get_or_build, loaded, host.config, { store = loaded })
      end
      if neighbors[i] then
        vim.schedule(prefetch_one)
      end
    end
    prefetch_one()
  end, delay or 20)
end

return M
