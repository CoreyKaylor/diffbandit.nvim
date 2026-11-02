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
end

--- opts = { on_change = fn(mode), refresh = fn() }
function M.attach(host, opts)
  opts = opts or {}
  host.connector_renderer = effective(host.config)
  local entry = { refresh = opts.refresh }
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
