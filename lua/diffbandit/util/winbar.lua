-- 'winbar' takes the top screen row of a window. DiffBandit lines content
-- panes up row for row with their number/connector gutters, so a winbar on
-- some of those windows and not the others (LspSaga breadcrumbs on the
-- source panes) shifts the code one row against its gutters.
--
-- Removing winbars is not an option: a global 'winbar' cannot be turned off
-- for one window (an empty local value falls back to the global one), and
-- plugins re-apply theirs on every cursor move. Instead the bar row is kept
-- uniform: when any aligned window shows a winbar, every aligned window
-- does — gutters get a blank bar, and content panes keep their own bar or
-- get a blank one. The user's breadcrumbs stay where they put them.
local M = {}

-- The blank bar DiffBandit owns. Recognised by value, so a buffer swap
-- (which resets window-local options) or a plugin overwriting it is seen
-- as "not ours" on the next sync.
M.BLANK = " "

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function local_value(win)
  local ok, value = pcall(vim.api.nvim_get_option_value, "winbar", { scope = "local", win = win })
  return ok and value or ""
end

local function set_local(win, value)
  if local_value(win) ~= value then
    pcall(vim.api.nvim_set_option_value, "winbar", value, { scope = "local", win = win })
    return true
  end
  return false
end

-- A winbar somebody other than DiffBandit wants on this window (the local
-- value, or the global one it falls back to).
local function foreign_bar(win)
  local value = local_value(win)
  if value == "" then
    value = vim.go.winbar
  end
  return value ~= "" and value ~= M.BLANK
end

--- Screen rows the window's winbar occupies above its text (0 or 1).
function M.rows(win)
  if not valid(win) then
    return 0
  end
  local info = vim.fn.getwininfo(win)[1]
  return info and info.winbar or 0
end

--- Make the winbar row uniform across a host's aligned windows.
--- spec.content: panes whose text the gutters follow (may carry a user bar)
--- spec.gutters: number/connector/overview windows (only ever blank bars)
--- spec.headers: one-row status windows above the panes; they share a row
---   with each other, not with the panes, so they only need a bar when the
---   global winbar forces one on some of them anyway.
--- Returns true when any window's bar changed (its text height changed).
function M.align(spec)
  local content, gutters, headers = {}, {}, {}
  for _, win in ipairs(spec.content or {}) do
    if valid(win) then content[#content + 1] = win end
  end
  for _, win in ipairs(spec.gutters or {}) do
    if valid(win) then gutters[#gutters + 1] = win end
  end
  for _, win in ipairs(spec.headers or {}) do
    if valid(win) then headers[#headers + 1] = win end
  end

  local any = vim.go.winbar ~= ""
  for _, win in ipairs(content) do
    any = any or foreign_bar(win)
  end

  local changed = false
  local function blank_or_clear(win, want_blank)
    if want_blank then
      changed = set_local(win, M.BLANK) or changed
    elseif local_value(win) == M.BLANK then
      changed = set_local(win, "") or changed
    end
  end
  -- A global bar already fills every pane; only blank the panes that would
  -- otherwise have none, and drop a stale blank so the global bar shows.
  for _, win in ipairs(content) do
    blank_or_clear(win, any and vim.go.winbar == "" and not foreign_bar(win))
  end
  for _, win in ipairs(gutters) do
    blank_or_clear(win, any)
  end
  for _, win in ipairs(headers) do
    blank_or_clear(win, vim.go.winbar ~= "")
  end
  return changed
end

--- Re-align whenever a winbar changes (plugins set breadcrumbs lazily, on
--- LspAttach or CursorMoved) or a buffer swap resets window-local options.
--- `get_spec()` returns the align spec (nil once the host is gone);
--- `on_change()` runs after an alignment changed window heights.
function M.watch(host, augroup, get_spec, on_change)
  local pending = false
  local function sync()
    if pending then
      return
    end
    pending = true
    vim.schedule(function()
      pending = false
      if host.disposed then
        return
      end
      local spec = get_spec()
      if spec and M.align(spec) and on_change then
        on_change()
      end
    end)
  end
  vim.api.nvim_create_autocmd("OptionSet", { group = augroup, pattern = "winbar", callback = sync })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = augroup, callback = sync })
end

return M
