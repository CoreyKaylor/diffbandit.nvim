-- Tape runner for Ghostty recordings. Loaded inside the recorded nvim with
-- `-c "luafile runner.lua"`; drives the editor from the inside (nvim_input +
-- timers) instead of injecting keystrokes into the terminal.
--
-- Environment (set by demo/ghostty/record.sh):
--   DEMO_TAPE   path to a tape: a Lua file returning function(t)
--   DEMO_MODE   "keyframe" | "realtime"
--   DEMO_OUT    scratch dir for this run (frames, markers)
--   DEMO_STILLS dir for per-beat stills (docs/demo/.frames)
--
-- Modes:
--   keyframe  every visible change is captured as one PNG of the Ghostty
--             window (screencapture -l), with an explicit display duration.
--             hold() costs no wall-clock time; wait() time never shows.
--   realtime  record.sh films the window with ScreenCaptureKit; hold() and
--             type() really sleep, and the runner never captures frames.
--
-- Handshake with record.sh, all via files in DEMO_OUT:
--   winid      (record.sh -> runner) Ghostty window id, once it is on screen
--   show       (runner -> record.sh) realtime: start filming now
--   recording  (record.sh -> runner) realtime: the recorder is running
--   frames.txt (runner) keyframe: ffconcat manifest
--   done/error (runner) finished; error holds the message

local uv = vim.uv or vim.loop
local env = vim.env
local MODE = env.DEMO_MODE or "keyframe"
local OUT = assert(env.DEMO_OUT, "DEMO_OUT not set")
local STILLS = env.DEMO_STILLS
local KEYFRAME = MODE == "keyframe"

-- Settling: after an action, wait SETTLE_MIN, then capture until two
-- consecutive captures are byte-identical (SETTLE_STEP apart).
local SETTLE_MIN = 90
local SETTLE_STEP = 45
local SETTLE_TRIES = 12
local MIN_FRAME_MS = 40

local co
local function write_file(path, data)
  local fh = assert(io.open(path, "wb"))
  fh:write(data)
  fh:close()
end
local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local data = fh:read("*a")
  fh:close()
  return data
end
local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function finish(err)
  if err then
    write_file(OUT .. "/error", tostring(err))
  end
  write_file(OUT .. "/done", "")
  vim.cmd("qa!")
end

local function resume(...)
  if coroutine.status(co) ~= "suspended" then
    return
  end
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    finish(debug.traceback(co, err))
  elseif coroutine.status(co) == "dead" then
    finish()
  end
end

local function sleep(ms)
  vim.defer_fn(resume, ms)
  coroutine.yield()
end

local function run(cmd)
  vim.system(cmd, {}, function(r)
    vim.schedule(function()
      resume(r)
    end)
  end)
  return coroutine.yield()
end

local function wait_until(fn, timeout_ms, what)
  local deadline = uv.now() + (timeout_ms or 20000)
  while not fn() do
    if uv.now() > deadline then
      error("timed out waiting for " .. (what or "condition"), 2)
    end
    sleep(50)
  end
end

-- --- capture ----------------------------------------------------------------

local winid
local frames = {} -- { path, ms, bytes }
local shown = false
local seq = 0

local function capture(path)
  local r = run({ "screencapture", "-x", "-o", "-l" .. winid, path })
  if r.code ~= 0 then
    error("screencapture failed: " .. (r.stderr or ""))
  end
  return read_file(path)
end

local function settled_capture(min_ms)
  sleep(min_ms or SETTLE_MIN)
  local tmp = OUT .. "/settle.png"
  local prev = capture(tmp)
  for _ = 1, SETTLE_TRIES do
    sleep(SETTLE_STEP)
    local cur = capture(tmp)
    if cur == prev then
      return cur
    end
    prev = cur
  end
  return prev
end

-- Append a frame unless it is identical to the last one.
local function push_frame(bytes)
  local last = frames[#frames]
  if last and last.bytes == bytes then
    return
  end
  seq = seq + 1
  local path = string.format("%s/f%04d.png", OUT, seq)
  write_file(path, bytes)
  frames[#frames + 1] = { path = path, ms = 0, bytes = bytes }
end

local function snap(min_ms)
  if KEYFRAME and shown then
    push_frame(settled_capture(min_ms))
  end
end

local function write_manifest()
  local lines = { "ffconcat version 1.0" }
  for _, f in ipairs(frames) do
    lines[#lines + 1] = "file '" .. f.path .. "'"
    lines[#lines + 1] = string.format("duration %.3f", math.max(f.ms, MIN_FRAME_MS) / 1000)
  end
  -- concat demuxer ignores the final duration unless the file repeats.
  if #frames > 0 then
    lines[#lines + 1] = "file '" .. frames[#frames].path .. "'"
  end
  write_file(OUT .. "/frames.txt", table.concat(lines, "\n") .. "\n")
end

-- --- tape API -----------------------------------------------------------------

local t = { mode = MODE }

--- Stop producing visible output (setup beats).
function t.hide()
  shown = false
end

--- Start the visible part of the clip.
function t.show()
  if shown then
    return
  end
  if KEYFRAME then
    shown = true
    snap()
  else
    write_file(OUT .. "/show", "")
    wait_until(function()
      return exists(OUT .. "/recording")
    end, 15000, "recorder start")
    shown = true
  end
end

--- Keep the current screen for ms.
function t.hold(ms)
  if KEYFRAME then
    if shown and #frames > 0 then
      frames[#frames].ms = frames[#frames].ms + ms
    end
  else
    sleep(ms)
  end
end

--- Send keys (nvim_input notation) and capture the result. A literal `<`
--- must be written `<lt>` — `t.keys("<<")` is swallowed as a broken key
--- code and never reaches the mapping.
function t.keys(keys, opts)
  vim.api.nvim_input(keys)
  snap(opts and opts.settle)
end

--- Type literal text one character at a time.
function t.type(text, opts)
  local speed = (opts and opts.speed) or 55
  for ch in text:gmatch(".") do
    vim.api.nvim_input(ch == "<" and "<lt>" or ch)
    if KEYFRAME then
      snap(25)
      t.hold(speed)
    else
      sleep(speed)
    end
  end
end

--- Capture continuously for ms (animations nvim drives on its own).
function t.burst(ms, interval)
  if not KEYFRAME then
    return sleep(ms)
  end
  interval = interval or 33
  local stop = uv.now() + ms
  local last = uv.now()
  while uv.now() < stop do
    sleep(interval)
    local tmp = OUT .. "/burst.png"
    -- Time since the previous sample belongs to the frame that was showing.
    local now = uv.now()
    if #frames > 0 then
      frames[#frames].ms = frames[#frames].ms + (now - last)
    end
    last = now
    push_frame(capture(tmp))
  end
end

--- Block until fn() is true. In keyframe mode the wait never shows; the
--- settled result is captured once it is true.
function t.wait(fn, timeout_ms, what)
  wait_until(fn, timeout_ms, what)
  snap()
end

--- Capture the screen now (after settling). For use after t.sleep() when a
--- change arrives asynchronously with nothing to wait on.
function t.snap(min_ms)
  snap(min_ms)
end

--- Run fn (direct editor/plugin calls, nothing typed) and capture.
function t.run(fn, opts)
  fn()
  snap(opts and opts.settle)
end

--- The DiffBandit session/merge host for the current tab, if any.
function t.session()
  local state = package.loaded["diffbandit.state"]
  return state and state.sessions[vim.api.nvim_get_current_tabpage()]
end

--- Plain sleep (wall clock), visible in realtime mode only.
function t.sleep(ms)
  sleep(ms)
end

--- Save a still of the current screen for review.
function t.still(name)
  if not STILLS then
    return
  end
  vim.fn.mkdir(STILLS, "p")
  local path = string.format("%s/ghostty-%s-%s.png", STILLS, MODE, name)
  if KEYFRAME and shown and #frames > 0 then
    write_file(path, frames[#frames].bytes)
  else
    capture(path)
  end
end

--- True when the pattern (Lua pattern) appears anywhere on nvim's screen
--- grid — the in-editor equivalent of VHS's Wait+Screen.
function t.screen_has(pattern)
  local rows, cols = vim.o.lines, vim.o.columns
  for r = 1, rows do
    local parts = {}
    for c = 1, cols do
      parts[c] = vim.fn.screenstring(r, c)
    end
    if table.concat(parts):find(pattern) then
      return true
    end
  end
  return false
end

--- Returns a predicate: at least n Kitty connector canvases in the current
--- tab have transmitted an image and placed their float.
function t.kitty_ready(n)
  return function()
    local canvas = package.loaded["diffbandit.kitty.canvas"]
    if not canvas then
      return false
    end
    local tab, count = vim.api.nvim_get_current_tabpage(), 0
    for _, st in ipairs(canvas.live_states()) do
      local w = st.float_win
      if (st.transmits or 0) > 0 and w and vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_tabpage(w) == tab then
        count = count + 1
      end
    end
    return count >= (n or 1)
  end
end

--- Returns a predicate: an LSP client with this name is attached to a buffer.
function t.lsp_attached(name)
  return function()
    for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
      if next(c.attached_buffers or {}) then
        return true
      end
    end
    return false
  end
end

--- True while a completion menu (nvim-cmp or the native pum) is open.
function t.completion_visible()
  local ok, cmp = pcall(require, "cmp")
  if ok and cmp.visible() then
    return true
  end
  return vim.fn.pumvisible() == 1
end

--- Returns a predicate over the current buffer's count of errors and
--- warnings (hints and info are ignored).
function t.problems(pred)
  return function()
    local sev = vim.diagnostic.severity
    return pred(#vim.diagnostic.get(0, { severity = { min = sev.WARN } }))
  end
end

-- --- main -----------------------------------------------------------------------

co = coroutine.create(function()
  wait_until(function()
    return exists(OUT .. "/winid")
  end, 20000, "window id from record.sh")
  winid = vim.trim(read_file(OUT .. "/winid"))
  local tape = assert(loadfile(assert(env.DEMO_TAPE, "DEMO_TAPE not set")))()
  tape(t)
  if KEYFRAME then
    write_manifest()
  end
end)
vim.schedule(resume)
