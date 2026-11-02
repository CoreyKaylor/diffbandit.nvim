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
local protocol = require("diffbandit.kitty.protocol")

local M = {}

local QUERY_ID = 0xDB0F01

local state = {
  status = "unknown", -- unknown | probing | kitty | cells
  reason = nil,
  transmission = nil, -- file | direct (from the probe)
  cell = nil, -- { w, h } px when measured
}
local listeners = {}
local retransmit_listeners = {}
local owned_ids = {}
local sink_override = nil
local env_override = nil
local response_group = nil

local function notify(status)
  for _, fn in ipairs(vim.list_extend({}, listeners)) do
    pcall(fn, status)
  end
end

--- Write raw bytes to the host terminal (tests inject a capture sink).
function M.send(data)
  if sink_override then
    sink_override(data)
    return true
  end
  local send = vim.api.nvim_ui_send
  if not send then
    return false
  end
  return pcall(send, data)
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
    tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= "",
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
  notify(state.status)
end

local function start_probe(config)
  state.status = "probing"
  local got = { direct = false, file = false }
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
          finish({ ok = got.direct, file = got.file, reason = got.direct and nil or "no graphics reply before DA1" })
        end, 60)
      end
    end,
  })

  local timeout = tonumber(kitty_config(config).probe_timeout_ms) or 300
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  state.probe_timer = timer
  timer:start(timeout, 0, vim.schedule_wrap(function()
    finish({ ok = got.direct, file = got.file, reason = got.direct and nil or "probe timed out" })
  end))

  local payload = protocol.query(QUERY_ID, "d")
  if file then
    payload = payload .. protocol.query(QUERY_ID + 1, "t", file)
  end
  if not M.send(payload .. protocol.DA1) then
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
  install_response_watch()
  if mode == "kitty" then
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
  elseif e.tmux then
    reason = "inside tmux"
  end
  if reason then
    state.status = "cells"
    state.reason = reason
    return "cells"
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
    for _, fn in ipairs(vim.list_extend({}, retransmit_listeners)) do
      pcall(fn, reason)
    end
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
  local request = ffi.os == "OSX" and 0x40087468 or 0x5413
  local ok, size = pcall(function()
    local fd = ffi.C.open("/dev/tty", 0)
    if fd < 0 then
      return nil
    end
    local ws = ffi.new("struct diffbandit_winsize")
    local rc = ffi.C.ioctl(fd, request, ws)
    ffi.C.close(fd)
    if rc ~= 0 or ws.ws_col == 0 or ws.ws_row == 0 or ws.ws_xpixel == 0 or ws.ws_ypixel == 0 then
      return nil
    end
    return { w = math.floor(ws.ws_xpixel / ws.ws_col), h = math.floor(ws.ws_ypixel / ws.ws_row) }
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
function M.cell_size(config)
  local cfg = kitty_config(config).cell_px
  if type(cfg) == "table" and tonumber(cfg[1]) and tonumber(cfg[2]) then
    return { w = math.floor(cfg[1]), h = math.floor(cfg[2]) }
  end
  if not state.cell then
    state.cell = (not env_override and measure_cell()) or { w = 20, h = 40, estimated = true }
  end
  return state.cell
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
  state = { status = "unknown" }
  listeners = {}
  owned_ids = {}
end

function M._set_sink(fn)
  sink_override = fn
end

function M._set_env(e)
  env_override = e
end

M.QUERY_ID = QUERY_ID

return M
