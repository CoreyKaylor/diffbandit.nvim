-- Kitty graphics capability detection for the image connector renderer.
--
-- Mode: ui.connector_renderer = "auto" | "kitty" | "cells", overridable by
-- vim.g.diffbandit_connector_renderer or DIFFBANDIT_CONNECTOR_RENDERER.
--
-- "auto" never trusts terminal names: it sends a graphics query (a=q) plus a
-- temp-file query (t=t) followed by a DA1 sentinel through nvim_ui_send and
-- listens on TermResponse. A graphics OK that arrives before the DA1 reply
-- means supported; DA1 first (or a timeout) means not — e.g. a multiplexer
-- that does not pass APC through. Until the probe resolves, sessions render
-- with cells and flip once on success. The result is cached per Neovim
-- process (reset on UIEnter) and any later error reply for one of our image
-- ids downgrades every session back to cells.
--
-- Inside tmux (see kitty/tmux.lua) every command is wrapped for DCS
-- passthrough and, because tmux swallows the outer terminal's replies, "auto"
-- asks tmux itself (allow-passthrough, client terminal, RGB) instead of
-- probing in band. Later tmux queries follow client changes (detach /
-- reattach) and pane visibility so images can be re-sent or the renderer
-- flipped to match the terminal now attached.
local protocol = require("diffbandit.kitty.protocol")
local tmux = require("diffbandit.kitty.tmux")

local M = {}

local QUERY_ID = 0xDB0F01

local state = {
  status = "unknown", -- unknown | probing | kitty | cells
  reason = nil,
  generation = 0,
  transmission = nil, -- file | direct (from the probe)
  cell = nil, -- { w, h } px when measured
}
local listeners = {}
local retransmit_listeners = {}
local cell_listeners = {}
local owned_ids = {}
local sink_override = nil
local env_override = nil
local measure_override = nil
local response_group = nil
local passthrough_cfg = "auto"

local function notify(status)
  for _, fn in ipairs(vim.list_extend({}, listeners)) do
    pcall(fn, status)
  end
end

local own_tty_override = nil

local function inside_tmux()
  if state.tmux_foreign then
    return false
  end
  if env_override then
    return env_override.tmux == true
  end
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
end

--- Path of the terminal Neovim is attached to (its standard fds; the
--- --embed server inherits them from the TUI), or nil when unknown.
local own_tty_cache = nil
local function own_tty()
  if own_tty_override then
    return own_tty_override()
  end
  if own_tty_cache ~= nil then
    return own_tty_cache or nil
  end
  own_tty_cache = false
  local ok_ffi, ffi = pcall(require, "ffi")
  if ok_ffi then
    pcall(ffi.cdef, "int isatty(int fd);")
    pcall(ffi.cdef, "char *ttyname(int fd);")
    pcall(function()
      for fd = 0, 2 do
        if ffi.C.isatty(fd) == 1 then
          local name = ffi.C.ttyname(fd)
          if name ~= nil then
            own_tty_cache = ffi.string(name)
            return
          end
        end
      end
    end)
  end
  return own_tty_cache or nil
end

--- $TMUX can be inherited by a program that is not running in that tmux
--- pane at all (Zellij, a terminal emulator or ssh started from inside
--- tmux). Trust it only when tmux's pane tty is Neovim's own tty; when either
--- is unknown, keep trusting $TMUX.
local function foreign_tmux(info)
  local mine = own_tty()
  local theirs = info and info.pane_tty
  return mine ~= nil and theirs ~= nil and theirs ~= "" and mine ~= theirs
end

--- Graphics transport: "tmux" (DCS passthrough) or "none". Config
--- ui.kitty.passthrough = "auto" (tmux when $TMUX is set) | "tmux" | "none".
function M.passthrough()
  if passthrough_cfg == "tmux" or passthrough_cfg == "none" then
    return passthrough_cfg
  end
  return inside_tmux() and "tmux" or "none"
end

--- Write graphics commands to the host terminal: one escape sequence (a
--- string) or a list of them, each wrapped for the active transport. Tests
--- inject a capture sink that sees the exact wire bytes.
function M.send(data)
  local commands = type(data) == "table" and data or { data }
  local wire
  if M.passthrough() == "tmux" then
    wire = tmux.wrap_all(commands)
  else
    wire = table.concat(commands)
  end
  if sink_override then
    sink_override(wire)
    return true
  end
  local send = vim.api.nvim_ui_send
  if not send then
    return false
  end
  return pcall(send, wire)
end

local function env()
  if env_override then
    return env_override
  end
  local has_tty_ui = false
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.stdout_tty then
      has_tty_ui = true
    end
  end
  return {
    has_ui_send = vim.api.nvim_ui_send ~= nil,
    has_tty_ui = has_tty_ui,
    termguicolors = vim.o.termguicolors == true,
    tmux = inside_tmux(),
  }
end

--- Requested mode after overrides: "auto" | "kitty" | "cells".
function M.requested_mode(config)
  local g = vim.g.diffbandit_connector_renderer
  local e = vim.env.DIFFBANDIT_CONNECTOR_RENDERER
  local mode = (type(g) == "string" and g ~= "" and g)
    or (type(e) == "string" and e ~= "" and e)
    or (((config or {}).ui or {}).connector_renderer)
    or "auto"
  if mode ~= "kitty" and mode ~= "cells" then
    mode = "auto"
  end
  return mode
end

local function kitty_config(config)
  return (((config or {}).ui or {}).kitty) or {}
end

local function temp_dir()
  local dir = vim.env.TMPDIR
  if not dir or dir == "" then
    dir = "/tmp"
  end
  return (dir:gsub("/+$", ""))
end

local temp_seq = 0
--- Unique temp-file path the terminal accepts for t=t (it must live in a
--- temp directory and contain "tty-graphics-protocol"; the terminal deletes
--- it after reading).
function M.temp_path(tag)
  temp_seq = temp_seq + 1
  return string.format("%s/diffbandit-tty-graphics-protocol-%d-%s-%d.rgba",
    temp_dir(), vim.fn.getpid(), tag or "x", temp_seq)
end

local function finish(result)
  if state.status ~= "probing" then
    return
  end
  if state.probe_timer then
    pcall(function()
      state.probe_timer:stop()
      state.probe_timer:close()
    end)
    state.probe_timer = nil
  end
  if state.probe_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.probe_group)
    state.probe_group = nil
  end
  if state.probe_file then
    pcall(os.remove, state.probe_file)
    state.probe_file = nil
  end
  state.status = result.ok and "kitty" or "cells"
  state.reason = result.reason
  state.transmission = result.file and "file" or "direct"
  state.source = result.source
  notify(state.status)
end

local function probe_timeout(config)
  return tonumber(kitty_config(config).probe_timeout_ms) or 300
end

-- tmux spawns a process: give it a little more room than an in-band reply.
local function tmux_timeout(config)
  return math.max(probe_timeout(config), 500)
end

-- ui.kitty.tmux_passthrough_all (default true): raise this pane's
-- allow-passthrough from "on" to "all" so images written while the pane is
-- hidden are not dropped (see tmux.raise_passthrough). cb() runs when done.
local function maybe_raise(info, config, cb)
  if kitty_config(config).tmux_passthrough_all == false or not info or info.passthrough ~= "on"
      or state.tmux_raise_failed then
    cb()
    return
  end
  local generation = state.generation
  tmux.raise_passthrough(tmux_timeout(config), function(ok)
    if generation ~= state.generation then
      return
    end
    if ok then
      if state.tmux_info then
        state.tmux_info.passthrough = "all"
      end
    else
      state.tmux_raise_failed = true
    end
    cb()
  end)
end

-- The terminal behind tmux answers nothing, so temp-file support can never be
-- confirmed and a t=t failure would go unnoticed: always transmit directly.
local start_probe

local function start_tmux_probe(config)
  state.status = "probing"
  tmux.query(tmux_timeout(config), function(info, err)
    if info and foreign_tmux(info) then
      -- Inherited $TMUX: the terminal in front of us is something else.
      -- Never wrap or touch that tmux; probe our own terminal in band.
      state.tmux_foreign = true
      start_probe(config)
      return
    end
    if info then
      state.tmux_info = info
      state.tmux_client = info.client
    end
    local ok, reason = false, err
    if info then
      ok, reason = tmux.evaluate(info, config)
    end
    local function done()
      finish({ ok = ok, file = false, reason = reason, source = "tmux" })
    end
    if ok then
      -- Before the first image goes out, so none can be dropped.
      maybe_raise(info, config, done)
    else
      done()
    end
  end)
end

function start_probe(config)
  state.status = "probing"
  local got = { direct = false, file = false, error = nil }
  local file = M.temp_path("probe")
  local fh = io.open(file, "wb")
  if fh then
    fh:write("\0\0\0")
    fh:close()
    state.probe_file = file
  else
    file = nil
  end

  state.probe_group = vim.api.nvim_create_augroup("DiffBanditKittyProbe", { clear = true })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = state.probe_group,
    callback = function(ev)
      local seq = (ev.data or {}).sequence or vim.v.termresponse
      local reply = protocol.parse_response(seq)
      if reply then
        if reply.id == QUERY_ID and reply.ok then
          got.direct = true
        elseif reply.id == QUERY_ID and not reply.ok then
          got.error = reply.message
        elseif reply.id == QUERY_ID + 1 and reply.ok then
          got.file = true
        end
        return
      end
      if protocol.is_da1(seq) then
        if got.direct then
          vim.schedule(function()
            finish({ ok = true, file = got.file })
          end)
          return
        end
        -- A DA1 reply with no graphics OK yet is usually ours (the terminal
        -- ignored the query), but it may be a stray answer to one of Neovim's
        -- own startup queries. Give our graphics reply a short grace window.
        vim.defer_fn(function()
          local reason = nil
          if not got.direct then
            reason = got.error and ("terminal rejected the graphics query: " .. got.error)
              or "no graphics reply before DA1"
          end
          finish({ ok = got.direct, file = got.file, reason = reason })
        end, 60)
      end
    end,
  })

  local timeout = probe_timeout(config)
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  state.probe_timer = timer
  timer:start(timeout, 0, vim.schedule_wrap(function()
    finish({ ok = got.direct, file = got.file, reason = got.direct and nil or "probe timed out" })
  end))

  local payload = { protocol.query(QUERY_ID, "d") }
  if file then
    payload[#payload + 1] = protocol.query(QUERY_ID + 1, "t", file)
  end
  payload[#payload + 1] = protocol.DA1
  if not M.send(payload) then
    finish({ ok = false, reason = "nvim_ui_send failed" })
  end
end

local function install_response_watch()
  if response_group then
    return
  end
  response_group = vim.api.nvim_create_augroup("DiffBanditKittyResponses", { clear = true })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = response_group,
    callback = function(ev)
      local reply = protocol.parse_response((ev.data or {}).sequence or vim.v.termresponse)
      if reply and reply.id and owned_ids[reply.id] and not reply.ok then
        vim.schedule(function()
          M.reject("terminal rejected image: " .. tostring(reply.message))
        end)
      end
    end,
  })
  -- A UI attaching (the launcher opens diffs before the TUI is up), a
  -- different terminal attaching, or Neovim enabling termguicolors after its
  -- own capability detection all invalidate the cached answer: re-resolve
  -- for the live hosts, which flip through on_change once the probe answers.
  local function reprobe()
    if state.status == "probing" or state.failed then
      return
    end
    state.status = "unknown"
    state.cell = nil
    vim.schedule(function()
      if #listeners > 0 and state.last_config and state.status == "unknown" then
        M.resolve(state.last_config)
      end
    end)
  end
  vim.api.nvim_create_autocmd("UIEnter", { group = response_group, callback = reprobe })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = response_group,
    pattern = "termguicolors",
    callback = function()
      if vim.o.termguicolors and state.status == "cells" and state.reason == "termguicolors is off" then
        reprobe()
      end
    end,
  })
end

--- Test hook: run the UIEnter / termguicolors re-probe path.
function M._reprobe_for_test()
  vim.api.nvim_exec_autocmds("UIEnter", { group = response_group })
end

--- Resolve the renderer for a new host: returns "kitty" or "cells" now.
--- In "auto" mode the first call may start the probe and return "cells";
--- subscribe with on_change to flip once it resolves.
function M.resolve(config)
  local mode = M.requested_mode(config)
  if mode == "cells" then
    return "cells"
  end
  local pt = kitty_config(config).passthrough
  passthrough_cfg = (pt == "tmux" or pt == "none") and pt or "auto"
  state.last_config = config
  install_response_watch()
  if mode == "kitty" then
    -- Forced: still learn the tmux client (cell size, colour space,
    -- visibility) so the transport can re-send images when needed.
    if M.passthrough() == "tmux" and not state.tmux_info then
      M.tmux_check(config)
    end
    return "kitty"
  end
  if state.status == "kitty" or state.status == "cells" then
    return state.status
  end
  if state.status == "probing" then
    return "cells"
  end
  state.last_config = config
  local e = env()
  local reason = nil
  if not e.has_ui_send then
    reason = "nvim_ui_send unavailable (Neovim < 0.12)"
  elseif not e.has_tty_ui then
    -- Not cached: a TUI may attach later (UIEnter re-probes). Headless
    -- instances simply never attach one.
    state.reason = "no terminal UI attached"
    return "cells"
  elseif not e.termguicolors then
    reason = "termguicolors is off"
  end
  if reason then
    state.status = "cells"
    state.reason = reason
    return "cells"
  end
  if M.passthrough() == "tmux" then
    start_tmux_probe(config)
    return state.status == "kitty" and "kitty" or "cells"
  end
  start_probe(config)
  -- Synchronous terminals may already have answered.
  if state.status == "kitty" then
    return "kitty"
  end
  return "cells"
end

--- Subscribe to status changes ("kitty" | "cells"). Returns an unsubscribe fn.
function M.on_change(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, f in ipairs(listeners) do
      if f == fn then
        table.remove(listeners, i)
        return
      end
    end
  end
end

local function retransmit(reason)
  for _, fn in ipairs(vim.list_extend({}, retransmit_listeners)) do
    pcall(fn, reason)
  end
end

local function apply_tmux_info(info, config, opts)
  if foreign_tmux(info) then
    -- Forced "kitty" with an inherited $TMUX: stop wrapping and re-send
    -- anything already written for the wrong transport.
    state.tmux_foreign = true
    state.tmux_info = nil
    retransmit("inherited $TMUX ignored")
    return
  end
  local prev = state.tmux_info
  state.tmux_info = info
  local client_changed = state.tmux_client ~= nil and info.client ~= state.tmux_client
  -- A client attached or switched back to this session (same client pid):
  -- images sent while nobody showed the session were dropped, even with
  -- allow-passthrough "all". tmux reports this in whole seconds, so leaving
  -- and returning within the same second can go unnoticed.
  local reattached = prev ~= nil and info.last_attached ~= nil and info.last_attached ~= ""
    and info.last_attached ~= prev.last_attached
  state.tmux_client = info.client
  -- A new client (reattach from another terminal or font) or a changed
  -- client cell size invalidates any cached measurement, including one that
  -- came from tmux itself; VimResized may have re-measured before this
  -- asynchronous answer arrived, so the re-render is triggered here.
  local prev_cell = prev and prev.cell
  local cell_moved = info.cell ~= nil
    and not (prev_cell and prev_cell.w == info.cell.w and prev_cell.h == info.cell.h)
  local cell_changed = false
  if state.cell and (client_changed or cell_moved) then
    cell_changed = M.remeasure(config)
  end
  -- Re-evaluate only a verdict that came from tmux (never one caused by
  -- termguicolors, a missing TUI, or a runtime rejection), so a client from
  -- another terminal flips the renderer and returning flips it back.
  if M.requested_mode(config) == "auto" and state.source == "tmux" and not state.failed
      and (state.status == "kitty" or state.status == "cells") then
    local ok, reason = tmux.evaluate(info, config)
    local status = ok and "kitty" or "cells"
    if status ~= state.status or (not ok and reason ~= state.reason) then
      local flipped = status ~= state.status
      state.status = status
      state.reason = reason
      if flipped then
        state.tmux_stale = false
        state.tmux_unconfirmed = false
        if status == "kitty" then
          maybe_raise(info, config, function()
            notify(status)
          end)
        else
          notify(status)
        end
        return
      end
    end
  end
  local kitty_active = state.status == "kitty" or M.requested_mode(config) == "kitty"
  if kitty_active and info.passthrough == "on" then
    -- Forced mode, or the option was reset since: raise again; anything sent
    -- meanwhile is re-sent once delivery is guaranteed.
    maybe_raise(info, config, function()
      if tmux.raised() and state.tmux_unconfirmed then
        state.tmux_unconfirmed = false
        retransmit("passthrough raised to all")
      end
    end)
  end
  if cell_changed and kitty_active then
    -- Hosts re-size and re-raster (which re-sends every image).
    state.tmux_stale = not info.visible and info.passthrough ~= "all"
    for _, fn in ipairs(vim.list_extend({}, cell_listeners)) do
      pcall(fn)
    end
    return
  end
  local became_visible = info.visible and (state.tmux_stale or (prev ~= nil and not prev.visible))
  if not info.visible and info.passthrough ~= "all" then
    -- With allow-passthrough "on", tmux drops passthrough from hidden panes:
    -- anything transmitted now must be sent again once the pane shows.
    state.tmux_stale = true
  elseif info.visible then
    state.tmux_stale = false
  end
  if (client_changed or reattached or became_visible or (opts or {}).retransmit)
      and info.visible and kitty_active then
    state.tmux_unconfirmed = false
    retransmit((client_changed and "tmux client changed") or (reattached and "tmux session reattached")
      or "tmux pane shown")
  end
end

--- Ask tmux about the pane and client (async, bounded) and react: flip the
--- renderer when the attached terminal changed support, re-send images after
--- a reattach or once a pane that was hidden during a transmission shows.
--- opts.retransmit re-sends whenever the pane is visible (FocusGained).
function M.tmux_check(config, opts)
  if M.passthrough() ~= "tmux" or M.requested_mode(config or state.last_config) == "cells" then
    return false
  end
  config = config or state.last_config
  if state.tmux_checking then
    state.tmux_pending = state.tmux_pending or {}
    state.tmux_pending.retransmit = state.tmux_pending.retransmit or (opts or {}).retransmit
    return true
  end
  state.tmux_checking = true
  local generation = state.generation
  tmux.query(tmux_timeout(config), function(info)
    if generation ~= state.generation then
      return
    end
    state.tmux_checking = false
    if info then
      apply_tmux_info(info, config, opts)
    end
    local pending = state.tmux_pending
    state.tmux_pending = nil
    if pending then
      M.tmux_check(config, pending)
    end
  end)
  return true
end

-- A transmission counts as delivered only if a key reached Neovim or focus
-- was gained this recently before it (a tmux query is only a sample and
-- proves nothing about the moments around it). tmux drops passthrough from hidden panes when
-- allow-passthrough is "on", and a pane can be hidden and shown again
-- between any two samples, so anything else is re-sent on the next key.
M.TMUX_CONFIRM_NS = 250 * 1e6

--- A client shows this pane right now (key input, FocusGained).
function M.note_visible()
  state.tmux_visible_at = (vim.uv or vim.loop).hrtime()
end

--- A key or mouse event reached Neovim: the pane is visible. Re-send images
--- whose delivery was uncertain.
function M.note_key()
  M.note_visible()
  if state.tmux_unconfirmed then
    state.tmux_unconfirmed = false
    retransmit("unconfirmed transmission")
  end
end

--- Called after each transmission: under tmux, remember it if nothing shows
--- the pane was visible when it was sent.
--- Also with allow-passthrough "all": tmux still drops passthrough while no
--- client shows the session (switched to another one), and tmux's own
--- snapshot (client pid, visibility, a whole-second attach time) can look
--- identical before and after a quick switch away and back. Only a key or a
--- focus event proves a client is on this session, so anything sent without
--- one just before it is re-sent on the next.
function M.note_transmit()
  if M.passthrough() ~= "tmux" then
    return
  end
  local seen = state.tmux_visible_at
  if not seen or (vim.uv or vim.loop).hrtime() - seen > M.TMUX_CONFIRM_NS then
    state.tmux_unconfirmed = true
  end
end

--- True while some transmission still awaits proof of delivery.
function M.tmux_unconfirmed()
  return state.tmux_unconfirmed == true
end

--- Subscribe to cell-size changes learned from tmux (client change).
function M.on_cell_change(fn)
  cell_listeners[#cell_listeners + 1] = fn
end

--- Outer terminal name behind tmux (client_termtype or termname), if known.
function M.outer_terminal()
  local info = state.tmux_info
  if not info then
    return nil
  end
  if info.termtype and info.termtype ~= "" then
    return info.termtype
  end
  return info.termname
end

--- Runtime failure: downgrade to cells for the rest of the process.
function M.fail(reason)
  if state.status == "cells" and state.reason == reason then
    return
  end
  state.status = "cells"
  state.reason = reason
  state.failed = true
  notify("cells")
end

-- How long error replies for transmissions already in flight are ignored
-- after falling back from temp-file to direct transmission.
local FALLBACK_GRACE_NS = 500 * 1e6

--- An error reply for one of our images. Temp-file transmission passed the
--- probe but can still fail later (tmp cleaned, a remote client attached to
--- a multiplexer): fall back to direct transmission once and ask hosts to
--- re-send. Any other rejection downgrades to cells.
function M.reject(reason)
  local uv = vim.uv or vim.loop
  local now = uv.hrtime()
  if state.file_fallback_at and now - state.file_fallback_at < FALLBACK_GRACE_NS then
    return
  end
  if state.transmission == "file" and not state.file_fallback_at then
    state.transmission = "direct"
    state.file_fallback_at = now
    retransmit(reason)
    return
  end
  M.fail(reason)
end

--- Subscribe to "re-send every image" requests (transmission fallback).
function M.on_retransmit(fn)
  retransmit_listeners[#retransmit_listeners + 1] = fn
end

--- True once a runtime failure downgraded the renderer (forced "kitty"
--- sessions honour it too).
function M.failed()
  return state.failed == true
end

function M.register_id(id)
  owned_ids[id] = true
end

function M.unregister_id(id)
  owned_ids[id] = nil
end

--- Transmission medium: config "file" | "direct" | "auto" (probe result,
--- defaulting to direct, which works over SSH and remote multiplexers).
function M.transmission(config)
  local t = kitty_config(config).transmission
  if t == "file" or t == "direct" then
    return t
  end
  if M.passthrough() == "tmux" then
    return "direct"
  end
  return state.transmission or "direct"
end

local function measure_cell()
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi then
    return nil
  end
  pcall(ffi.cdef, "struct diffbandit_winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };")
  pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
  pcall(ffi.cdef, "int open(const char *path, int flags, ...);")
  pcall(ffi.cdef, "int close(int fd);")
  pcall(ffi.cdef, "int isatty(int fd);")
  local request = ffi.os == "OSX" and 0x40087468 or 0x5413
  local function query(fd)
    local ws = ffi.new("struct diffbandit_winsize")
    if ffi.C.ioctl(fd, request, ws) ~= 0 or ws.ws_col == 0 or ws.ws_row == 0
        or ws.ws_xpixel == 0 or ws.ws_ypixel == 0 then
      return nil
    end
    return { w = math.floor(ws.ws_xpixel / ws.ws_col), h = math.floor(ws.ws_ypixel / ws.ws_row) }
  end
  local ok, size = pcall(function()
    -- Since Neovim 0.10 the editor runs as an `--embed` server under the TUI
    -- process. It has no controlling terminal (open("/dev/tty") fails) but
    -- inherits the terminal on its standard fds, so ask those first.
    for fd = 0, 2 do
      if ffi.C.isatty(fd) == 1 then
        local found = query(fd)
        if found then
          return found
        end
      end
    end
    local fd = ffi.C.open("/dev/tty", 0)
    if fd < 0 then
      return nil
    end
    local found = query(fd)
    ffi.C.close(fd)
    return found
  end)
  if ok and size and size.w > 0 and size.h > 0 then
    return size
  end
  return nil
end

--- Cell size in pixels: ui.kitty.cell_px override, else TIOCGWINSZ pixel
--- size of the controlling terminal, else a 1:2 estimate. Multiplexers and
--- ssh often report no pixel size, and Neovim does not forward CSI 16t
--- replies, so the estimate is HiDPI-sized: terminals downscale it cleanly,
--- while an undersized image upscaled on a Retina display looks blocky.
---
--- Only a real measurement is cached. Ghostty, for one, spawns the shell
--- with a 1x1 px placeholder size and sends the real size a moment later; an
--- estimate taken in that window must not stick, because terminals fit
--- placeholder images preserving aspect ratio — a wrong cell aspect shrinks
--- and centres the whole image, misaligning it worst at the top and bottom.
function M.cell_size(config)
  local cfg = kitty_config(config).cell_px
  if type(cfg) == "table" and tonumber(cfg[1]) and tonumber(cfg[2]) then
    return { w = math.floor(cfg[1]), h = math.floor(cfg[2]) }
  end
  if not state.cell or state.cell.estimated then
    local measured = nil
    if measure_override then
      measured = measure_override()
    elseif not env_override then
      measured = measure_cell()
    end
    -- Older tmux leaves the pane's pixel size at 0; the client's cell size
    -- (tmux 3.4+ formats) is the next best measurement.
    if not measured and state.tmux_info and state.tmux_info.cell then
      measured = { w = state.tmux_info.cell.w, h = state.tmux_info.cell.h }
    end
    state.cell = measured or { w = 20, h = 40, estimated = true }
  end
  return state.cell
end

--- Re-read the cell size (terminal resize / font size change). Returns true
--- when the measured size changed.
function M.remeasure(config)
  local cfg = kitty_config(config).cell_px
  if type(cfg) == "table" and tonumber(cfg[1]) and tonumber(cfg[2]) then
    return false
  end
  local before = state.cell
  state.cell = nil
  local after = M.cell_size(config)
  return not before or before.w ~= after.w or before.h ~= after.h
end

--- Test hook: replace the tty measurement (fn returns { w, h } or nil).
function M._set_measure(fn)
  measure_override = fn
  state.cell = nil
end

function M.status()
  return state.status, state.reason
end

-- --- test hooks ----------------------------------------------------------

function M._reset()
  if state.probe_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.probe_group)
  end
  if state.probe_timer then
    pcall(function()
      state.probe_timer:stop()
      state.probe_timer:close()
    end)
  end
  if state.probe_file then
    pcall(os.remove, state.probe_file)
  end
  state = { status = "unknown", generation = (state.generation or 0) + 1 }
  listeners = {}
  owned_ids = {}
  passthrough_cfg = "auto"
  own_tty_override = nil
  tmux._set_runner(nil)
  tmux._reset()
end

function M._set_sink(fn)
  sink_override = fn
end

function M._set_env(e)
  env_override = e
end

--- Test hook: fn() -> tty path | nil replaces Neovim's own tty lookup.
function M._set_own_tty(fn)
  own_tty_override = fn
end

M.QUERY_ID = QUERY_ID

return M
