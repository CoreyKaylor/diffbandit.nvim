-- Mouse for minimaps, without mappings in the user's buffers.
--
-- A click on a minimap window enters it (Neovim focuses even unfocusable
-- windows on click) and getmousepos() names it: WinEnter jumps the target to
-- the clicked row and keeps focus there for a drag. While the minimap holds
-- focus, its own buffer's maps handle <LeftDrag> (keep jumping),
-- <LeftRelease> (focus back to the target). The wheel is observed in
-- vim.on_key: over a minimap it scrolls the target. Whatever the wheel does
-- to the strip window itself (a split scrolls) is undone on WinScrolled.
-- Entering a minimap by keyboard (<C-w>w, :wincmd) bounces to the target,
-- or to wherever the minimap's on_keyboard_enter sends it (the diff view
-- continues the window cycle).
local M = {}

local by_win = {}
local mapped_bufs = {}
local group
local last_left_press = 0
local LEFT_MOUSE
local button_down = false
local after_release = {}
local install_observer

local function now()
  local uv = vim.uv or vim.loop
  return uv.now()
end

local function wheel_lines()
  local v = tostring(vim.o.mousescroll or ""):match("ver:(%d+)")
  return tonumber(v) or 3
end

-- Strip row (1-based) under the mouse for minimap window `win`.
local function mouse_row(win)
  local pos = vim.fn.getmousepos()
  if pos.winid == win then
    return pos.winrow
  end
  local top = vim.api.nvim_win_get_position(win)[1]
  return pos.screenrow - top
end

--- Entering minimap window `win`; `by_mouse` = a left click caused it.
function M.on_enter(win, by_mouse, row)
  local mm = by_win[win]
  if not mm or mm.disposed then
    return
  end
  if by_mouse then
    mm.dragging = true
    mm:jump_to_row(row or mouse_row(win))
  else
    vim.schedule(function()
      if not mm.disposed and vim.api.nvim_get_current_win() == win then
        if mm.on_keyboard_enter then
          mm.on_keyboard_enter(mm)
        else
          mm:focus_target()
        end
      end
    end)
  end
end

--- Whether the latest left click (within a second) entered window `win`.
function M.clicked(win)
  return vim.fn.getmousepos().winid == win and (now() - last_left_press) < 1000
end

local function flush_after_release()
  local pending = after_release
  after_release = {}
  for _, fn in ipairs(pending) do
    vim.schedule(fn)
  end
end

--- Run `fn` now, or once the left button is released when a click or drag
--- is in progress (layout changes mid-drag would shift the selection).
function M.when_released(fn)
  install_observer()
  if not button_down then
    fn()
    return
  end
  after_release[#after_release + 1] = fn
end

--- Minimap window `win` scrolled: the strip stays at its top (line r is
--- strip row r). The target scroll comes from the wheel observer.
function M.on_scrolled(win)
  local mm = by_win[win]
  if not mm or mm.disposed or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.fn.line("w0", win) ~= 1 then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
  end
end

--- A wheel step over minimap window `win` (+1 down, -1 up).
function M.on_wheel(win, direction)
  local mm = by_win[win]
  if not mm or mm.disposed then
    return
  end
  mm:scroll(direction * wheel_lines())
end

local observer_installed = false

install_observer = function()
  if observer_installed then
    return
  end
  observer_installed = true
  local function code(k)
    return vim.keycode and vim.keycode(k) or vim.api.nvim_replace_termcodes(k, true, true, true)
  end
  LEFT_MOUSE = code("<LeftMouse>")
  local LEFT_DRAG = code("<LeftDrag>")
  local WHEEL = { [code("<ScrollWheelDown>")] = 1, [code("<ScrollWheelUp>")] = -1 }
  -- Observe (never consume) keys: a WinEnter right after a <LeftMouse> is
  -- a click; any other entry is the keyboard. The button state defers
  -- layout changes (when_released) until a click or drag ends; any other
  -- key also ends it, in case the release happened outside Neovim.
  vim.on_key(function(key, typed)
    local k = (typed ~= nil and typed ~= "") and typed or key
    if k == LEFT_MOUSE then
      last_left_press = now()
      button_down = true
      return
    end
    if k == LEFT_DRAG then
      return
    end
    if button_down then
      button_down = false
      flush_after_release()
    end
    if WHEEL[k] then
      local win = vim.fn.getmousepos().winid
      if by_win[win] then
        local dir = WHEEL[k]
        vim.schedule(function()
          M.on_wheel(win, dir)
        end)
      end
    end
  end, vim.api.nvim_create_namespace("DiffBanditMinimapMouse"))
end

local function install()
  if group then
    return
  end
  install_observer()
  group = vim.api.nvim_create_augroup("DiffBanditMinimapMouse", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if not by_win[win] then
        return
      end
      M.on_enter(win, M.clicked(win))
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      -- One WinScrolled names only the first scrolled window; v:event
      -- lists them all.
      for id in pairs(vim.v.event or {}) do
        local win = tonumber(id)
        if win and by_win[win] then
          M.on_scrolled(win)
        end
      end
    end,
  })
end

local function map_buffer(buf)
  if mapped_bufs[buf] then
    return
  end
  mapped_bufs[buf] = true
  local function current()
    return by_win[vim.api.nvim_get_current_win()]
  end
  local function map(lhs, fn)
    vim.keymap.set({ "n", "x" }, lhs, function()
      local mm = current()
      if mm and not mm.disposed then
        fn(mm, vim.api.nvim_get_current_win())
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "DiffBandit minimap" })
  end
  map("<LeftMouse>", function(mm, win)
    mm.dragging = true
    mm:jump_to_row(mouse_row(win))
  end)
  map("<LeftDrag>", function(mm, win)
    mm:jump_to_row(mouse_row(win))
  end)
  map("<LeftRelease>", function(mm)
    mm.dragging = false
    mm:focus_target()
  end)
  -- The wheel is handled by the key observer; keep it from scrolling the
  -- strip while it has focus.
  map("<ScrollWheelDown>", function() end)
  map("<ScrollWheelUp>", function() end)
  -- Leaving by keyboard after a click (no release seen) still returns.
  for _, lhs in ipairs({ "<Esc>", "q", "i", "a", "<CR>" }) do
    map(lhs, function(mm)
      mm.dragging = false
      mm:focus_target()
    end)
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      mapped_bufs[buf] = nil
    end,
  })
end

--- Route mouse events of minimap window `win` (buffer `buf`) to `mm`.
function M.register(win, buf, mm)
  install()
  for w, other in pairs(by_win) do
    if other == mm and w ~= win then
      by_win[w] = nil
    end
  end
  by_win[win] = mm
  map_buffer(buf)
end

function M.unregister(mm)
  for w, other in pairs(by_win) do
    if other == mm then
      by_win[w] = nil
    end
  end
end

--- Minimap registered for window `win` (tests).
function M.minimap_for(win)
  return by_win[win]
end

return M
