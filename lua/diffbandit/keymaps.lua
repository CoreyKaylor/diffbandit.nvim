-- Buffer-local keymaps with backup/restore of any pre-existing mappings.
-- Backups live on the host object (host.keymap_backups) so each session,
-- merge, or panel restores exactly what it shadowed.
local M = {}

local function backup_key(mode, buf, lhs)
  return table.concat({ tostring(mode), tostring(buf), tostring(lhs) }, "\31")
end

local function existing_buffer_keymap(mode, buf, lhs)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if map.lhs == lhs then
      return map
    end
  end
  return nil
end

function M.set(host, mode, buf, lhs, rhs, opts)
  if not (buf and vim.api.nvim_buf_is_valid(buf) and lhs and lhs ~= "") then
    return
  end
  host.keymap_backups = host.keymap_backups or {}
  local key = backup_key(mode, buf, lhs)
  if host.keymap_backups[key] == nil then
    host.keymap_backups[key] = {
      mode = mode,
      buf = buf,
      lhs = lhs,
      previous = existing_buffer_keymap(mode, buf, lhs) or false,
    }
  end
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts or {}, { buffer = buf }))
end

function M.clear(host)
  if not host.keymap_backups then
    return
  end
  for _, backup in pairs(host.keymap_backups) do
    local buf = backup.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.del, backup.mode, backup.lhs, { buffer = buf })
      local previous = backup.previous
      if previous and previous ~= false then
        local rhs = previous.callback or previous.rhs
        if rhs and rhs ~= "" then
          pcall(vim.keymap.set, backup.mode, backup.lhs, rhs, {
            buffer = buf,
            noremap = previous.noremap == 1,
            silent = previous.silent == 1,
            expr = previous.expr == 1,
            nowait = previous.nowait == 1,
            script = previous.script == 1,
            desc = previous.desc,
          })
        end
      end
    end
  end
  host.keymap_backups = nil
end

return M
