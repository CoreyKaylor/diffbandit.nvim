-- Optional Kitty graphics connector integration (Ghostty, Kitty, Rex, …).
--
-- Hosts (2-way sessions, merge views) call attach() before their first
-- render. It sets host.connector_renderer to "kitty" or "cells" and keeps it
-- current: an "auto" probe that resolves later flips hosts to kitty, and a
-- runtime terminal error flips them back to cells. Hosts supply on_change
-- (re-render after a flip) and refresh (repaint after a theme change).
local canvas = require("diffbandit.kitty.canvas")
local connector_width = require("diffbandit.connector.width")
local detect = require("diffbandit.kitty.detect")

local M = {}

-- Minimum interval between activity-driven tmux client checks.
M.TMUX_ACTIVITY_CHECK_MS = 1000

local hosts = setmetatable({}, { __mode = "k" })
local theme_group = nil

local function effective(config)
  if detect.failed() then
    return "cells"
  end
  return detect.resolve(config)
end

-- Re-send every live image (theme change, transmission fallback).
local function refresh_all()
  for host, entry in pairs(hosts) do
    if not host.disposed and host.connector_renderer == "kitty" then
      M.invalidate(host)
      if entry.refresh then
        pcall(entry.refresh)
      end
    end
  end
end

local function install_theme_refresh()
  if theme_group then
    return
  end
  theme_group = vim.api.nvim_create_augroup("DiffBanditKittyTheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = theme_group,
    callback = function()
      -- Run after highlights.apply (registered earlier) re-derived the
      -- connector groups; palette changes re-raster on the next paint.
      vim.schedule(refresh_all)
    end,
  })
  detect.on_retransmit(function()
    vim.schedule(refresh_all)
  end)
  -- tmux: the outer terminal never reports back, so follow the client from
  -- tmux itself. Gaining focus (tmux focus-events) re-sends images, which
  -- covers switching back to the window and reattaching; editor activity
  -- runs a throttled check that catches a reattach (new client, perhaps a
  -- different terminal) even without focus events.
  local last_check = 0
  local function any_host()
    for host in pairs(hosts) do
      if not host.disposed then
        return host
      end
    end
    return nil
  end
  vim.api.nvim_create_autocmd("FocusGained", {
    group = theme_group,
    callback = function()
      local host = any_host()
      if host and detect.passthrough() == "tmux" then
        detect.note_visible()
        last_check = (vim.uv or vim.loop).now()
        detect.tmux_check(host.config, { retransmit = true })
      end
    end,
  })
  local function activity()
    if detect.passthrough() ~= "tmux" then
      return
    end
    local now = (vim.uv or vim.loop).now()
    if now - last_check < M.TMUX_ACTIVITY_CHECK_MS then
      return
    end
    local host = any_host()
    if host then
      last_check = now
      detect.tmux_check(host.config)
    end
  end
  M._tmux_activity = activity
  -- Any typed key or mouse event means someone is looking at this pane
  -- (whatever window has focus, even one where the cursor cannot move).
  -- Keys from :normal, feedkeys or timers (typed == "") prove nothing.
  vim.on_key(function(_, typed)
    if typed == nil or typed == "" then
      return
    end
    -- Stamp now: the key's mapping runs before any scheduled callback and
    -- may render (and transmit) synchronously; a stale stamp would mark that
    -- transmission unconfirmed and re-send every image right after it.
    if detect.passthrough() == "tmux" then
      detect.note_visible()
    end
    vim.schedule(function()
      if detect.passthrough() == "tmux" then
        detect.note_key()
      end
      activity()
    end)
  end, vim.api.nvim_create_namespace("DiffBanditKittyTmuxActivity"))
  vim.api.nvim_create_autocmd("VimResized", { group = theme_group, callback = activity })
  -- Font size changes (and a terminal reporting its real pixel size after
  -- startup) arrive as resizes: re-measure the cell and, when it changed,
  -- re-size the IntelliJ-width core and re-raster through on_change.
  local function rerender_for_cell()
    vim.schedule(function()
      for host, entry in pairs(hosts) do
        if not host.disposed and host.connector_renderer == "kitty" then
          M.invalidate(host)
          if entry.on_change then
            pcall(entry.on_change, "kitty")
          end
        end
      end
    end)
  end
  vim.api.nvim_create_autocmd("VimResized", {
    group = theme_group,
    callback = function()
      local any = false
      for host in pairs(hosts) do
        any = any or (not host.disposed and host.connector_renderer == "kitty")
      end
      if not any then
        return
      end
      local first
      for host in pairs(hosts) do
        first = first or host
      end
      if detect.remeasure(first and first.config) then
        rerender_for_cell()
      end
    end,
  })
  -- tmux reported a different cell size (new client, font change measured
  -- only by tmux): detect already re-measured, re-size and re-raster.
  detect.on_cell_change(rerender_for_cell)
end

--- opts = { on_change = fn(mode), refresh = fn() }
function M.attach(host, opts)
  opts = opts or {}
  host.connector_renderer = effective(host.config)
  local entry = { refresh = opts.refresh, on_change = opts.on_change }
  entry.unsubscribe = detect.on_change(function()
    if host.disposed then
      return
    end
    local mode = effective(host.config)
    if mode == host.connector_renderer then
      return
    end
    host.connector_renderer = mode
    if mode ~= "kitty" then
      M.release(host)
    end
    if opts.on_change then
      opts.on_change(mode)
    end
  end)
  hosts[host] = entry
  install_theme_refresh()
  return host.connector_renderer
end

--- Drop the terminal images a host owns (single canvas or merge pair slots).
function M.release(host)
  canvas.destroy(host)
  for slot, st in pairs(host.kitty_states or {}) do
    canvas.destroy_state(st)
    host.kitty_states[slot] = nil
  end
end

function M.invalidate(host)
  canvas.invalidate(host)
  for _, st in pairs(host.kitty_states or {}) do
    st.last_key = nil
  end
end

function M.detach(host)
  local entry = hosts[host]
  if entry and entry.unsubscribe then
    entry.unsubscribe()
  end
  hosts[host] = nil
  M.release(host)
end

--- Connector core width (cells) for an image connector: IntelliJ-sized.
function M.core_width(config)
  return connector_width.kitty_core(config, detect.cell_size(config))
end

--- Core width for a host's current renderer (cells: configured minimum).
function M.min_core_width(host)
  if host.connector_renderer == "kitty" then
    return M.core_width(host.config)
  end
  return connector_width.minimum(host.config)
end

function M.enabled(host)
  return host ~= nil and host.connector_renderer == "kitty"
end

return M
