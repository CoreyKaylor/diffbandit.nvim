-- Outstanding deferred work: armed timers and in-flight async processes.
--
-- Every site that arms a timer or spawns an async process takes a token with
-- begin() and releases it with done() when the callback runs (or when the work
-- is cancelled). idle() is true when nothing is outstanding. Tests wait on it
-- instead of sleeping; the plugin itself never reads it.
--
-- done() is idempotent per token, so a cancel path and a late callback can both
-- release the same token safely.
local M = {}

local outstanding = {}
local count = 0
local next_token = 0

---@param label string|nil what the token is for (shown by M.list())
---@return integer token
function M.begin(label)
  next_token = next_token + 1
  outstanding[next_token] = label or true
  count = count + 1
  return next_token
end

---@param token integer|nil
function M.done(token)
  if token and outstanding[token] ~= nil then
    outstanding[token] = nil
    count = count - 1
  end
end

--- Wrap fn so calling it releases token first (errors in fn still release).
function M.wrap(token, fn)
  return function(...)
    M.done(token)
    return fn(...)
  end
end

function M.idle()
  return count == 0
end

function M.count()
  return count
end

--- Labels of outstanding work, for diagnosing a settle timeout.
function M.list()
  local labels = {}
  for _, label in pairs(outstanding) do
    labels[#labels + 1] = label == true and "?" or tostring(label)
  end
  table.sort(labels)
  return labels
end

return M
