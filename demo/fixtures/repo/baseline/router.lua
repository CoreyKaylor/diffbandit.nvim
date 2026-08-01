local Router = {}
Router.__index = Router

function Router.new()
  return setmetatable({
    routes = {},
  }, Router)
end

function Router:add(verb, path, fn)
  table.insert(self.routes, {
    verb = verb,
    path = path,
    fn = fn,
  })
end

function Router:match(verb, path)
  for _, r in ipairs(self.routes) do
    if r.verb == verb
      and r.path == path then
      return r.fn
    end
  end
  return nil
end

return Router
