local Router = {}
Router.__index = Router

function Router.new()
  return setmetatable({
    routes = {},
    middleware = {},
  }, Router)
end

function Router:use(fn)
  table.insert(self.middleware, fn)
end

function Router:add(verb, path, fn)
  table.insert(self.routes, {
    verb = verb:upper(),
    path = path,
    fn = fn,
  })
end

function Router:match(verb, path)
  for _, r in ipairs(self.routes) do
    if r.verb == verb:upper()
      and r.path == path then
      return r.fn
    end
  end
  return nil
end

return Router
