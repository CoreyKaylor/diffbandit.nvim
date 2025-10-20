local diffbandit = require("diffbandit")

vim.api.nvim_create_user_command("DiffBandit", function(opts)
  local args = opts.fargs
  if #args < 2 then
    vim.notify("DiffBandit: provide two file paths", vim.log.levels.ERROR)
    return
  end

  local left = vim.fn.expand(args[1])
  local right = vim.fn.expand(args[2])

  local session, err = diffbandit.files(left, right)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
end, {
  nargs = "+",
  complete = "file",
  desc = "Open DiffBandit diff view for two files",
})

vim.api.nvim_create_user_command("DiffBanditBuffers", function(opts)
  local args = opts.fargs
  if #args < 2 then
    vim.notify("DiffBanditBuffers: provide two buffer numbers", vim.log.levels.ERROR)
    return
  end

  local bufnr_a = tonumber(args[1])
  local bufnr_b = tonumber(args[2])
  if not bufnr_a or not vim.api.nvim_buf_is_valid(bufnr_a) then
    vim.notify("DiffBanditBuffers: invalid first buffer", vim.log.levels.ERROR)
    return
  end
  if not bufnr_b or not vim.api.nvim_buf_is_valid(bufnr_b) then
    vim.notify("DiffBanditBuffers: invalid second buffer", vim.log.levels.ERROR)
    return
  end

  local session, err = diffbandit.buffers(bufnr_a, bufnr_b)
  if not session and err then
    vim.notify("DiffBandit: " .. err, vim.log.levels.ERROR)
  end
end, {
  nargs = "+",
  complete = function()
    local items = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        table.insert(items, tostring(buf))
      end
    end
    return items
  end,
  desc = "Open DiffBandit diff view for two buffers",
})
