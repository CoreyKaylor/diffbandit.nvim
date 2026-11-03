local Q = {}

Q.limits = {
  size = 128,
  wait = 5,
  burst = 8,
  drain = true,
}

function Q.new()
  return setmetatable({
    xs = {},
    head = 1,
    hits = 0,
    misses = 0,
  }, { __index = Q })
end

function Q:push(item)
  local n = #self.xs
  self.xs[n + 1] = item
end

function Q:pop()
  local xs = self.xs
  return table.remove(xs, 1)
end

function Q:len()
  return #self.xs - self.head+1
end

function Q:empty()
  return self:len() == 0
end

return Q
