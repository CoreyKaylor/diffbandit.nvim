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
  local backup = host.keymap_backups[key]
  backup.rhs = rhs
  backup.opts = opts
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts or {}, { buffer = buf }))
end

local function map_matches_rhs(map, rhs)
  if not map then
    return false
  end
  if type(rhs) == "function" then
    return map.callback == rhs
  end
  return map.rhs == rhs
end

-- Re-install the host's mappings on `buf` when something set buffer-local
-- maps over them after setup — LSP configs commonly bind [d/]d and friends
-- from LspAttach handlers, which fire after the session claims a real file
-- buffer. A foreign map that shadowed ours becomes the new restore target so
-- it survives clear() once the session closes.
function M.reassert(host, buf)
  if not (host.keymap_backups and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  for _, backup in pairs(host.keymap_backups) do
    if backup.buf == buf and backup.rhs ~= nil then
      local current = existing_buffer_keymap(backup.mode, buf, backup.lhs)
      if not map_matches_rhs(current, backup.rhs) then
        if current then
          backup.previous = current
        end
        vim.keymap.set(backup.mode, backup.lhs, backup.rhs,
          vim.tbl_extend("force", backup.opts or {}, { buffer = buf }))
      end
    end
  end
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
