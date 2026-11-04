-- tmux transport for the Kitty graphics renderer.
--
-- Inside tmux every graphics command (transmit, delete, query) must reach
-- the OUTER terminal through tmux's DCS passthrough:
--
--   ESC P tmux ; <command with every ESC doubled> ESC \
--
-- tmux (checked up to 3.8) does not forward the outer terminal's replies
-- back to the pane: a graphics OK, a passthrough-wrapped DA1 and XTVERSION
-- answers are all swallowed, while an unwrapped DA1 / XTVERSION is answered
-- by tmux itself. The in-band probe therefore cannot work here; detection
-- instead asks tmux, out of band, about the pane and the attached client:
--
--   * allow-passthrough must be "on" or "all" for this pane;
--   * the client terminal must be one known to implement Kitty graphics with
--     Unicode placeholders (client_termtype / client_termname: Ghostty,
--     Kitty, … — extend with ui.kitty.tmux_terminals);
--   * the client must have the RGB feature, because the placeholder
--     foreground colour carries the image id and tmux would otherwise
--     quantize it to the 256-colour palette.
--
-- The query runs asynchronously (vim.system) under a hard timeout. The same
-- query later tells the renderer when another client attached (detach /
-- reattach, possibly from a different terminal) and whether the pane was
-- visible, so images sent while it was hidden can be re-sent.
local M = {}

-- Passthrough was added (and made opt-in) in tmux 3.3.
M.MIN_VERSION = { 3, 3 }

-- Outer terminals known to support Kitty graphics + Unicode placeholders.
-- Matched (case-insensitive, plain substring) against client_termtype
-- (XTVERSION, e.g. "ghostty 1.4.0") and client_termname (e.g.
-- "xterm-ghostty", "xterm-kitty").
M.DEFAULT_TERMINALS = { "ghostty", "kitty" }

local FIELDS = {
  "version",
  "allow-passthrough",
  "client_termname",
  "client_termtype",
  "client_termfeatures",
  "client_pid",
  "client_cell_width",
  "client_cell_height",
  "session_attached",
  "window_active",
  "window_zoomed_flag",
  "pane_active",
  "pane_tty",
  "session_last_attached",
}

M.FORMAT = (function()
  local parts = {}
  for i, f in ipairs(FIELDS) do
    parts[i] = "#{" .. f .. "}"
  end
  return table.concat(parts, "\t")
end)()

--- Wrap one escape sequence for tmux passthrough.
function M.wrap(data)
  return "\27Ptmux;" .. (data:gsub("\27", "\27\27")) .. "\27\\"
end

--- Wrap each command separately (chunked transmissions stay well below any
--- tmux input-buffer limit, and one bad chunk cannot swallow the rest).
function M.wrap_all(commands)
  local out = {}
  for i, c in ipairs(commands) do
    out[i] = M.wrap(c)
  end
  return table.concat(out)
end

--- Parse "3.3a", "3.8", "next-3.6", "openbsd-7.4" -> { major, minor } | nil.
function M.parse_version(v)
  if type(v) ~= "string" then
    return nil
  end
  local major, minor = v:match("(%d+)%.(%d+)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor) }
end

local function version_ok(v)
  local parsed = M.parse_version(v)
  if not parsed then
    return false
  end
  if parsed[1] ~= M.MIN_VERSION[1] then
    return parsed[1] > M.MIN_VERSION[1]
  end
  return parsed[2] >= M.MIN_VERSION[2]
end

--- Parse display-message output into an info table.
function M.parse(output)
  if type(output) ~= "string" then
    return nil
  end
  output = output:gsub("\r?\n$", "")
  local values = vim.split(output, "\t", { plain = true })
  if #values < #FIELDS then
    return nil
  end
  local raw = {}
  for i, f in ipairs(FIELDS) do
    raw[f] = values[i]
  end
  local features = {}
  for feat in (raw.client_termfeatures or ""):gmatch("[^,]+") do
    features[feat] = true
  end
  local cw, chh = tonumber(raw.client_cell_width), tonumber(raw.client_cell_height)
  local attached = (tonumber(raw.session_attached) or 0) > 0
  local visible = attached and raw.window_active == "1"
    and (raw.window_zoomed_flag ~= "1" or raw.pane_active == "1")
  return {
    version = raw.version,
    passthrough = raw["allow-passthrough"],
    termname = raw.client_termname,
    termtype = raw.client_termtype,
    features = features,
    client = (raw.client_pid or "") .. "|" .. (raw.client_termtype or "") .. "|" .. (raw.client_termname or ""),
    cell = (cw and chh and cw > 0 and chh > 0) and { w = cw, h = chh } or nil,
    attached = attached,
    visible = visible,
    pane_tty = raw.pane_tty,
    -- Changes whenever a client attaches or switches (back) to the session.
    -- Passthrough written while no client shows the session is dropped even
    -- with "all", and the client pid stays the same across switch-client.
    last_attached = raw.session_last_attached,
  }
end

--- Terminal patterns: ui.kitty.tmux_terminals replaces the defaults.
function M.terminals(config)
  local list = ((((config or {}).ui or {}).kitty) or {}).tmux_terminals
  if type(list) == "table" and #list > 0 then
    return list
  end
  return M.DEFAULT_TERMINALS
end

--- Decide support from an info table. Returns ok, reason.
function M.evaluate(info, config)
  if not info then
    return false, "tmux query failed"
  end
  if not version_ok(info.version) then
    return false, string.format("tmux %s is too old (needs %d.%d+ for allow-passthrough)",
      tostring(info.version), M.MIN_VERSION[1], M.MIN_VERSION[2])
  end
  if info.passthrough ~= "on" and info.passthrough ~= "all" then
    return false, "tmux allow-passthrough is off (set -g allow-passthrough on)"
  end
  if not info.attached or ((info.termname or "") == "" and (info.termtype or "") == "") then
    return false, "no tmux client attached"
  end
  local hay = ((info.termtype or "") .. " " .. (info.termname or "")):lower()
  local known = false
  for _, pat in ipairs(M.terminals(config)) do
    if type(pat) == "string" and pat ~= "" and hay:find(pat:lower(), 1, true) then
      known = true
      break
    end
  end
  if not known then
    return false, string.format("tmux client terminal %q is not a known Kitty graphics terminal",
      info.termtype ~= "" and info.termtype or info.termname)
  end
  if not info.features.RGB then
    return false, "tmux client lacks the RGB feature (set -as terminal-features ',"
      .. (info.termname ~= "" and info.termname or "TERM") .. ":RGB')"
  end
  return true, nil
end

local runner_override = nil

--- Test hook: fn(args, on_exit(code, stdout)). It may never call on_exit
--- (to exercise the timeout).
function M._set_runner(fn)
  runner_override = fn
end

local function pane_target(args)
  local pane = vim.env.TMUX_PANE
  if pane and pane ~= "" then
    vim.list_extend(args, { "-t", pane })
  end
  return args
end

--- Run a tmux command asynchronously. cb(code|nil, stdout, err) is called
--- exactly once, on the main loop, within timeout_ms (code nil on timeout or
--- spawn failure).
function M.run(args, timeout_ms, cb)
  local done = false
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  local function finish(code, stdout, err)
    if done then
      return
    end
    done = true
    pcall(function()
      timer:stop()
      timer:close()
    end)
    cb(code, stdout, err)
  end
  timeout_ms = math.max(1, tonumber(timeout_ms) or 500)
  -- vim.system kills tmux at timeout_ms; report only after that, so a
  -- finished run means the command can no longer change anything.
  timer:start(timeout_ms + 50, 0, vim.schedule_wrap(function()
    finish(nil, nil, "timed out")
  end))
  local function on_exit(code, stdout, signal)
    vim.schedule(function()
      -- vim.system reports a timeout as exit code 124 (killed by SIGTERM).
      -- tmux itself never exits with 124: treat it, or any killing signal,
      -- as "outcome unknown", like our own timer.
      if code == 124 or (signal and signal ~= 0) then
        finish(nil, stdout, "timed out")
        return
      end
      finish(code, stdout)
    end)
  end
  if runner_override then
    runner_override(args, on_exit)
    return
  end
  local ok = pcall(vim.system, args, { text = true, timeout = timeout_ms }, function(res)
    on_exit(res.code, res.stdout, res.signal)
  end)
  if not ok then
    vim.schedule(function()
      finish(nil, nil, "cannot run tmux")
    end)
  end
end

--- Run `tmux display-message -p` for this pane. cb(info|nil, err) is called
--- exactly once, on the main loop, within timeout_ms.
function M.query(timeout_ms, cb)
  local args = pane_target({ "tmux", "display-message", "-p" })
  args[#args + 1] = M.FORMAT
  M.run(args, timeout_ms, function(code, stdout, err)
    if not code then
      cb(nil, err == "timed out" and "tmux query timed out" or ("tmux query failed: " .. tostring(err)))
      return
    end
    if code ~= 0 then
      cb(nil, "tmux display-message failed")
      return
    end
    local info = M.parse(stdout)
    cb(info, info and nil or "unparseable tmux reply")
  end)
end

-- --- pane-local allow-passthrough "all" -----------------------------------
--
-- With allow-passthrough "on", tmux silently drops passthrough written while
-- the pane is not visible (another window, a zoomed neighbour), and nothing
-- tells the sender. Visibility can change between any two observations, so
-- no amount of sampling makes delivery certain. "all" forwards from hidden
-- panes too; Kitty placeholders only show where their cells are on screen,
-- so that is harmless. DiffBandit therefore raises the option to "all" for
-- its OWN pane only (set-option -p, never the global/window value), keeps
-- whatever pane-local value existed to restore it on exit, and never
-- overrides "off" (that is the user disabling graphics).
-- Restore ownership, separate from the option's current value (which every
-- tmux query reports): set once we first changed the pane, holding the
-- pane-local value we found ("" = inherited).
local raised = nil
-- Callbacks of an in-flight raise. Two overlapping raises would make the
-- second read back our own "all" as the value to restore on exit.
local raising = nil
local raising_timeout = 500
-- Set once the exit restore ran (or Neovim is exiting): no raise may start
-- or be sent after it, or it could land with nothing left to undo it.
local exiting = false

local function is_exiting()
  return exiting or vim.v.exiting ~= vim.NIL
end

--- True once this pane's passthrough was raised to "all" by us.
function M.raised()
  return raised ~= nil
end

--- Raise this pane's allow-passthrough from "on" to "all". cb(ok) after.
--- Callers decide from the current value (a fresh query), so this also
--- re-applies "all" after someone reset the pane to "on"; the value saved
--- for the exit restore stays the one found before our first change.
function M.raise_passthrough(timeout_ms, cb)
  if is_exiting() then
    cb(false)
    return
  end
  if raising then
    raising[#raising + 1] = cb
    return
  end
  raising = { cb }
  raising_timeout = math.max(1, tonumber(timeout_ms) or 500)
  local function done(ok)
    local waiting = raising or {}
    raising = nil
    for _, fn in ipairs(waiting) do
      fn(ok)
    end
  end
  local function set_all(previous)
    -- show-options answered while exiting (another VimLeavePre handler
    -- pumped the loop after our restore returned): never send the change.
    if is_exiting() then
      done(false)
      return
    end
    -- Take restore ownership and install the exit hook BEFORE the change is
    -- sent: tmux may apply it and Neovim exit before the completion runs.
    -- The restore only acts while the pane holds "all", so exiting before
    -- the change lands (or after it failed) leaves the pane untouched.
    local owned_now = false
    if not raised then
      raised = { previous = previous }
      owned_now = true
    end
    M.ensure_exit_restore()
    local set = vim.list_extend(pane_target({ "tmux", "set-option", "-p" }), { "allow-passthrough", "all" })
    M.run(set, timeout_ms, function(set_code)
      -- Give ownership up only on a definite failure. After a timeout tmux
      -- may have applied the change before it was killed; the restore
      -- checks the pane's value anyway.
      if set_code ~= nil and set_code ~= 0 and owned_now then
        raised = nil
      end
      done(set_code == 0)
    end)
  end
  -- Pane-local value only (no -A): "" when the pane inherits.
  local show = vim.list_extend(pane_target({ "tmux", "show-options", "-p", "-q", "-v" }), { "allow-passthrough" })
  M.run(show, timeout_ms, function(code, stdout)
    if code ~= 0 then
      done(false)
      return
    end
    local previous = vim.trim(stdout or "")
    if previous == "off" then
      done(false) -- explicitly disabled for this pane: respect it
      return
    end
    set_all(previous)
  end)
end

--- Undo raise_passthrough (VimLeavePre). Synchronous with a short timeout,
--- since Neovim is exiting.
-- Run a tmux command synchronously (exit path). Returns code, stdout.
local function run_sync(args)
  if runner_override then
    local code, out
    runner_override(args, function(c, o)
      code, out = c, o
    end)
    vim.wait(500, function()
      return code ~= nil
    end, 5)
    return code, out
  end
  local ok, res = pcall(function()
    return vim.system(args, { text = true }):wait(500)
  end)
  if not ok or not res then
    return nil, nil
  end
  return res.code, res.stdout
end

--- Undo raise_passthrough (VimLeavePre), but only while the pane still holds
--- the "all" we set: a change made since (someone set "off", or "on") is
--- the user's and is kept.
function M.restore_passthrough()
  exiting = true
  if not raised then
    return
  end
  -- A set-option "all" may still be running: let it finish (or be killed by
  -- its timeout) first, or it could land after the check below and leave
  -- the pane at "all" once Neovim is gone. Each of the two raise steps is
  -- bounded by the timeout.
  if raising then
    vim.wait(2 * raising_timeout + 100, function()
      return raising == nil
    end, 5)
  end
  if not raised then
    return -- the in-flight raise failed and gave up ownership
  end
  local previous = raised.previous
  raised = nil
  local show = vim.list_extend(pane_target({ "tmux", "show-options", "-p", "-q", "-v" }), { "allow-passthrough" })
  local code, current = run_sync(show)
  if code ~= 0 or vim.trim(current or "") ~= "all" then
    return
  end
  local args
  if previous == "" then
    args = vim.list_extend(pane_target({ "tmux", "set-option", "-p", "-u" }), { "allow-passthrough" })
  else
    args = vim.list_extend(pane_target({ "tmux", "set-option", "-p" }), { "allow-passthrough", previous })
  end
  run_sync(args)
end

local exit_group = nil

--- Restore the pane on VimLeavePre (installed once, before any change).
function M.ensure_exit_restore()
  if exit_group or runner_override then
    return
  end
  exit_group = vim.api.nvim_create_augroup("DiffBanditKittyTmuxRestore", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = exit_group,
    callback = function()
      M.restore_passthrough()
    end,
  })
end

--- Test hook: forget the raised state.
function M._reset()
  raised = nil
  raising = nil
  exiting = false
end

return M
