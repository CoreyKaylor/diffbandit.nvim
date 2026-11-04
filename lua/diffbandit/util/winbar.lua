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
  if valid(win) and local_value(win) ~= value then
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

-- The local winbar values that would make the spec's windows uniform, as
-- a list of { win, value } (empty when already aligned). Reads only, so it
-- is safe to call from a decoration provider during redraw.
local function plan(spec)
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

  local global = vim.go.winbar ~= ""
  local any = global
  for _, win in ipairs(content) do
    any = any or foreign_bar(win)
  end

  local changes = {}
  local function want(win, blank)
    local value = local_value(win)
    if blank and value ~= M.BLANK then
      changes[#changes + 1] = { win, M.BLANK }
    elseif not blank and value == M.BLANK then
      changes[#changes + 1] = { win, "" }
    end
  end
  -- A global bar already fills every pane; only blank the panes that would
  -- otherwise have none, and drop a stale blank so the global bar shows.
  for _, win in ipairs(content) do
    want(win, any and not global and not foreign_bar(win))
  end
  for _, win in ipairs(gutters) do
    want(win, any)
  end
  for _, win in ipairs(headers) do
    want(win, global)
  end
  return changes
end

--- Make the winbar row uniform across a host's aligned windows.
--- spec.content: panes whose text the gutters follow (may carry a user bar)
--- spec.gutters: number/connector/overview windows (only ever blank bars)
--- spec.headers: one-row status windows above the panes; they share a row
---   with each other, not with the panes, so they only need a bar when the
---   global winbar forces one on some of them anyway.
--- Returns true when any window's bar changed (its text height changed).
function M.align(spec)
  local changed = false
  for _, change in ipairs(plan(spec)) do
    changed = set_local(change[1], change[2]) or changed
  end
  return changed
end

--- True when the spec's windows already share one bar row.
function M.aligned(spec)
  return #plan(spec) == 0
end

-- Hosts being watched: host -> { get_spec, on_change, pending }.
local watched = {}
local provider_ns

local function sync(host, entry)
  if entry.pending then
    return
  end
  entry.pending = true
  vim.schedule(function()
    entry.pending = false
    if host.disposed or watched[host] ~= entry then
      return
    end
    local spec = entry.get_spec()
    if spec and M.align(spec) and entry.on_change then
      entry.on_change()
    end
  end)
end

local function spec_has(spec, win)
  for _, field in ipairs({ "content", "gutters" }) do
    for _, w in ipairs(spec[field] or {}) do
      if w == win then
        return true
      end
    end
  end
  return false
end

-- Plugins set winbars from inside their own autocmds (LspSaga renders on
-- CursorMoved, BufEnter and its symbol-update event), where OptionSet does
-- not fire (autocmds are not nested), and a bar appearing fires neither
-- WinResized nor WinScrolled. Showing it always redraws the window, so the
-- check rides on the redraw: on_win compares (read-only) and a mismatch
-- schedules the realign, since options cannot change mid-redraw.
local function ensure_provider()
  if provider_ns then
    return
  end
  provider_ns = vim.api.nvim_create_namespace("DiffBanditWinbar")
  local checked = {}
  vim.api.nvim_set_decoration_provider(provider_ns, {
    on_start = function()
      checked = {}
      for host in pairs(watched) do
        if host.disposed then
          watched[host] = nil
        end
      end
      return next(watched) ~= nil
    end,
    on_win = function(_, win)
      for host, entry in pairs(watched) do
        if not checked[host] and not entry.pending then
          local ok, spec = pcall(entry.get_spec)
          if ok and spec and spec_has(spec, win) then
            checked[host] = true
            local ok_plan, aligned = pcall(M.aligned, spec)
            if ok_plan and not aligned then
              sync(host, entry)
            end
          end
        end
      end
      return false
    end,
  })
end

--- Keep a host aligned for its lifetime: whenever one of its windows is
--- redrawn with bar rows out of step (a bar added, changed to/from empty,
--- a global bar toggled, a buffer swap resetting window-local options),
--- realign and call `on_change()`. `get_spec()` returns the align spec.
--- The host stops being watched once `host.disposed` is set.
function M.watch(host, get_spec, on_change)
  watched[host] = { get_spec = get_spec, on_change = on_change }
  ensure_provider()
end

return M
