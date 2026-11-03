local Q = {}

Q.limits = {
  max = 32,
}

function Q.new()
  return setmetatable({
    xs = {},
    head = 1,
  }, { __index = Q })
end

function Q:push(item)
  local n = #self.xs
  if n >= Q.limits.max then
    return false
  end
  self.xs[n + 1] = item
  return true
end

function Q:pop()
  local h = self.head
  if h > #self.xs then
    return nil
  end
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

function Q:clear()
  self.xs = {}
  self.head = 1
end

return Q
