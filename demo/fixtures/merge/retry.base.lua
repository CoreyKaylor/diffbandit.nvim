local M = {}

M.defaults = {
  attempts = 3,
  backoff = "linear",
  timeout = 5,
}

local function clamp(n)
  return math.max(0, n)
end

function M.delay(attempt)
  local n = clamp(attempt)
  return n * 100
end

function M.retry_ok(status)
  return status >= 500
end

return M
