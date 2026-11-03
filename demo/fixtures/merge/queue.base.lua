local Q = {}

Q.limits = {
  size = 64,
  wait = 10,
}

function Q.new()
  return setmetatable({
    xs = {},
    head = 1,
  }, { __index = Q })
end

function Q:push(item)
  local n = #self.xs
  self.xs[n + 1] = item
end

function Q:pop()
  local h = self.head
  local it = self.xs[h]
  self.xs[h] = nil
  self.head = h + 1
  return it
end

function Q:peek()
  return self.xs[self.head]
end

function Q:len()
  return #self.xs - self.head+1
end

return Q
