-- Follow the quickfix list from a view that owns several panes.
--
-- Neovim has no event for :cnext and friends, and a jump within one file does
-- not even change buffers, so compare the list position whenever Neovim goes
-- idle. A jump replaces the focused pane's buffer with the entry's file; the
-- host puts its panes back and brings that file into its own view. A pane taken
-- over by anything else (:edit) is left alone.
--
-- handlers: { panes = function() -> { { win, buf }, ... } end,
--             follow = function(entry, items, idx, context) end }
-- Hosts need .disposed and .tabpage.
local M = {}

local function foreign_buffers(panes)
  local foreign = {}
  for _, pane in ipairs(panes) do
    if pane[1] and vim.api.nvim_win_is_valid(pane[1]) and vim.api.nvim_win_get_buf(pane[1]) ~= pane[2] then
      foreign[vim.api.nvim_win_get_buf(pane[1])] = true
    end
  end
  return foreign
end

local function sync(host, handlers)
  if host.disposed then
    return
  end
  local position = vim.fn.getqflist({ id = 0, idx = 0 })
  local moved = position.id == host.quickfix_id and position.idx ~= host.quickfix_idx
  host.quickfix_id = position.id
  host.quickfix_idx = position.idx
  -- Moving the list from another tab must not move this view.
  if vim.api.nvim_get_current_tabpage() ~= host.tabpage or position.idx == 0 then
    return
  end
  local foreign = foreign_buffers(handlers.panes())
  if not moved and next(foreign) == nil then
    return
  end
  local list = vim.fn.getqflist({ id = position.id, items = 0, context = 0 })
  local items = list.items
  local entry = items[position.idx]
  if not entry or entry.bufnr == 0 or not (moved or foreign[entry.bufnr]) then
    return
  end
  handlers.follow(entry, items, position.idx, list.context)
end

function M.watch(host, group, handlers)
  local position = vim.fn.getqflist({ id = 0, idx = 0 })
  host.quickfix_id = position.id
  host.quickfix_idx = position.idx
  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      sync(host, handlers)
    end,
  })
end

-- Put each pane's own buffer back. Returns true when any pane changed.
function M.restore_panes(panes)
  local restored = false
  for _, pane in ipairs(panes) do
    if pane[1] and vim.api.nvim_win_is_valid(pane[1]) and vim.api.nvim_win_get_buf(pane[1]) ~= pane[2] then
      vim.api.nvim_win_set_buf(pane[1], pane[2])
      restored = true
    end
  end
  return restored
end

return M
