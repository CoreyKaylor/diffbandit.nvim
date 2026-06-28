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
      return { left = loaded.left, right = loaded.right }, current, nil
    end
    vim.notify("DiffBandit: skipping " .. tostring(err or "unreadable git file"), vim.log.levels.WARN)
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

function M.current_entry(host)
  local queue = host and host.file_queue
  if not queue then
    return nil
  end
  return queue.entries and queue.entries[host.file_queue_index or queue.index or 1]
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
    local center = index or host.file_queue_index or 1
    for _, neighbor in ipairs({ center - 1, center + 1 }) do
      if neighbor >= 1 and neighbor <= #(queue.entries or {}) then
        pcall(queue.load, neighbor)
      end
    end
  end, delay or 20)
end

return M
