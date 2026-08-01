local M = {}

M.defaults = {
  attempts = 5,
  backoff = "exponential",
  timeout = 30,
}

local function clamp(n)
  return math.max(0, n)
end

function M.delay(attempt)
  local n = clamp(attempt)
  return n * 250
end

function M.retry_ok(status)
  return status >= 500
end

return M
