-- Explicit host contract for the commit/nav panel.
-- Session, Merge, and CommitPanel implement these capabilities; the panel
-- calls through this module instead of probing type(session.X) == "function".

local M = {}

local function call(host, name, ...)
  local fn = host and host[name]
  if type(fn) == "function" then
    return true, fn(host, ...)
  end
  return false, nil
end

function M.goto_queue_file(host, index, chunk_position, opts)
  return call(host, "goto_queue_file", index, chunk_position, opts)
end

function M.open_merge_file(host, index, opts)
  return call(host, "open_merge_file", index, opts)
end

function M.refresh_git_queue(host, preferred_path, refresh_opts)
  return call(host, "refresh_git_queue", preferred_path, refresh_opts)
end

function M.set_amend_mode(host, enabled)
  return call(host, "set_amend_mode", enabled)
end

function M.clear_amend_mode(host)
  return call(host, "clear_amend_mode")
end

function M.close(host, ...)
  return call(host, "close", ...)
end

function M.goto_next_chunk(host)
  return call(host, "goto_next_chunk")
end

function M.goto_prev_chunk(host)
  return call(host, "goto_prev_chunk")
end

function M.has(host, name)
  return type(host and host[name]) == "function"
end

return M
