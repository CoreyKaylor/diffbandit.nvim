local M = {}

M.defaults = {
  attempts = 10,
  backoff = "jitter",
  timeout = 15,
}

local function clamp(n)
  return math.max(0, n)
end

function M.delay(attempt)
  local n = clamp(attempt)
  return (2 ^ n) * 50
end

function M.retry_ok(status)
  return status >= 500
end

return M
