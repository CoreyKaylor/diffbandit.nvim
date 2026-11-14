-- Version-control backend routing. Consumers require this module in place of
-- `diffbandit.git`: it exposes the same function names and forwards each call
-- to the backend that owns the repository (git or jj), chosen from the call's
-- root/path/queue argument.
--
-- Backends share one contract (see lua/diffbandit/git/init.lua for the
-- reference implementation). A queue from either backend keeps
-- `kind = "git"` — it means "repository-backed queue" to hosts, panel, and
-- status code — and carries `vcs = "git" | "jj"` to say which backend built it.

local M = {}

local backend_modules = {
  git = "diffbandit.git",
  jj = "diffbandit.jj",
}

local uv = vim.uv or vim.loop

local function prefer()
  local ok, state = pcall(require, "diffbandit.state")
  local config = ok and state.get_config and state.get_config() or nil
  local section = config and config.vcs or {}
  return section.prefer or "auto"
end

local function start_dir(path)
  if not path or path == "" then
    return uv.cwd()
  end
  local expanded = vim.fn.fnamemodify(path, ":p")
  if vim.fn.isdirectory(expanded) == 1 then
    return (expanded:gsub("/$", ""))
  end
  return vim.fn.fnamemodify(expanded, ":h")
end

-- Returns "jj" plus the workspace root when the nearest repository marker is
-- a jj workspace (colocated repos have both .jj and .git; jj wins unless
-- vcs.prefer = "git"), otherwise "git" (root resolved later by git itself).
function M.detect(path)
  local mode = prefer()
  if mode == "git" then
    return "git", nil
  end
  local dir = start_dir(path)
  while dir and dir ~= "" do
    if vim.fn.isdirectory(dir .. "/.jj") == 1 then
      if mode == "jj" or vim.fn.executable("jj") == 1 then
        return "jj", dir
      end
      return "git", nil
    end
    if mode ~= "jj" and uv.fs_stat(dir .. "/.git") then
      return "git", nil
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  if mode == "jj" then
    return "jj", nil
  end
  return "git", nil
end

function M.backend(kind)
  return require(backend_modules[kind] or backend_modules.git)
end

function M.kind_for_path(path)
  return (M.detect(path))
end

function M.for_path(path)
  return M.backend(M.kind_for_path(path))
end

function M.for_root(root)
  return M.for_path(root)
end

function M.for_queue(queue)
  return M.backend(queue and queue.vcs or "git")
end

-- The "nothing to review" sentinel each backend's queue() returns.
function M.is_no_changes(err)
  return err == "no git changes" or err == "no jj changes"
end

-- True for queues built by any backend (git or jj).
function M.is_vcs_queue(queue)
  return queue ~= nil and queue.kind == "git"
end

local function current_buffer_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    return name
  end
  return nil
end

-- Where an opts-table call (queue/root) will look for its repository.
local function opts_start(opts)
  opts = opts or {}
  return opts.root
    or opts.path
    or (opts.scope == "current" and opts.pathspecs and opts.pathspecs[1])
    or current_buffer_path()
    or uv.cwd()
end

local opts_first = { queue = true, root = true }
local queue_first = {
  sources_for_entry = true,
  snapshot_has_staged_changes = true,
  queue_stage_states = true,
}

local function route(name, first)
  if queue_first[name] then
    return M.for_queue(first)
  end
  if opts_first[name] then
    return M.for_path(opts_start(first))
  end
  -- Everything else takes a root (or, for find_root, a start path) first.
  if type(first) == "string" then
    return M.for_path(first)
  end
  return M.backend("git")
end

local proxy_cache = {}

setmetatable(M, {
  __index = function(_, name)
    local fn = proxy_cache[name]
    if fn then
      return fn
    end
    fn = function(first, ...)
      local backend = route(name, first)
      local impl = backend[name]
      if type(impl) ~= "function" then
        local err = string.format("%s is not supported in this repository", name)
        -- An async caller waits on its callback, not the return value.
        local args = { ... }
        local callback = args[select("#", ...)]
        if type(callback) == "function" then
          vim.schedule(function()
            callback(nil, err)
          end)
        end
        return nil, err
      end
      return impl(first, ...)
    end
    proxy_cache[name] = fn
    return fn
  end,
})

return M
