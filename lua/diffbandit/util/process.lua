local M = {}

function M.run(cmd)
  if vim.system then
    local result = vim.system(cmd, { text = false }):wait()
    if result.code ~= 0 then
      return nil, vim.trim(result.stderr or result.stdout or "")
    end
    return result.stdout or "", nil
  end

  local output = vim.fn.system(cmd)
  local code = vim.v.shell_error
  if code ~= 0 then
    return nil, vim.trim(output or "")
  end
  return output or "", nil
end

-- Runs independent commands concurrently and waits for all of them, so the
-- wall time is the slowest command instead of the sum. Results line up with
-- cmds: { output, err } with run()'s convention (output nil on failure). A
-- false/nil entry in cmds yields an empty result slot.
function M.run_many(cmds)
  local results = {}
  local count = table.maxn(cmds)
  if not vim.system then
    for index = 1, count do
      if cmds[index] then
        local output, err = M.run(cmds[index])
        results[index] = { output, err }
      else
        results[index] = {}
      end
    end
    return results
  end
  local handles = {}
  for index = 1, count do
    if cmds[index] then
      local ok, handle = pcall(vim.system, cmds[index], { text = false })
      handles[index] = ok and handle or { spawn_error = tostring(handle) }
    end
  end
  for index = 1, count do
    local handle = handles[index]
    if not handle then
      results[index] = {}
    elseif handle.spawn_error then
      results[index] = { nil, handle.spawn_error }
    else
      local result = handle:wait()
      if result.code ~= 0 then
        results[index] = { nil, vim.trim(result.stderr or result.stdout or "") }
      else
        results[index] = { result.stdout or "", nil }
      end
    end
  end
  return results
end

function M.run_async(cmd, callback)
  if vim.system then
    vim.system(cmd, { text = false }, function(result)
      local err
      if result.code ~= 0 then
        err = vim.trim(result.stderr or result.stdout or "")
      end
      vim.schedule(function()
        callback(result.code == 0, err, result.stdout or "")
      end)
    end)
    return true
  end
  return false
end

function M.run_exit_code(cmd)
  if vim.system then
    local result = vim.system(cmd, { text = true }):wait()
    return result.code, result.stdout or "", result.stderr or ""
  end

  local output = vim.fn.system(cmd)
  return vim.v.shell_error, output or "", ""
end

function M.run_raw_async(cmd, callback)
  if vim.system then
    vim.system(cmd, { text = false }, function(result)
      vim.schedule(function()
        callback(result.code or 0, result.stdout or "", result.stderr or "")
      end)
    end)
    return
  end
  local output = vim.fn.system(cmd)
  local code = vim.v.shell_error
  vim.schedule(function()
    callback(code, output or "", "")
  end)
end

return M
