local Metrics = {}

Metrics.counters = {}

function Metrics.incr(name, by)
  local current = Metrics.counters[name] or 0
  Metrics.counters[name] = current + (by or 1)
end

function Metrics.snapshot()
  local out = {}
  for name, value in pairs(Metrics.counters) do
    out[name] = value
  end
  return out
end

return Metrics
