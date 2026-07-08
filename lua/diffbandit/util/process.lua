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
