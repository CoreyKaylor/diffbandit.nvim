-- Repaint cost of the image (Kitty) connector vs the cell connector.
--
-- Run:  timeout 120 nvim --headless -l tools/bench_kitty.lua
-- Env:  DB_LINES=<n> (default 6000)  DB_STEPS=<n> (default 200)
--       DB_ROWS=<terminal rows> (default 60)  DB_COLS (default 200)
--
-- Drives real 2-way sessions through the same scroll script — alternating
-- left-only, right-only, and joint scrolls so the panes diverge — and prints
-- per-paint stage timings (ms) from the existing perf instrumentation. The
-- kitty run swaps the terminal sink for a byte counter (no TTY in headless
-- mode), so "transmit" covers encoding + temp-file write, not terminal I/O.

local root = vim.fn.fnamemodify(vim.fn.fnamemodify(arg[0], ":p:h"), ":h")
vim.opt.rtp:prepend(root)

local lines_n = tonumber(vim.env.DB_LINES) or 6000
local steps = tonumber(vim.env.DB_STEPS) or 200
vim.o.lines = tonumber(vim.env.DB_ROWS) or 60
vim.o.columns = tonumber(vim.env.DB_COLS) or 200

local Session = require("diffbandit.session")
local source = require("diffbandit.util.source")
local nvim_util = require("diffbandit.util.nvim")
local detect = require("diffbandit.kitty.detect")

local left, right = {}, {}
for i = 1, lines_n do
  left[#left + 1] = "line " .. i
  if i % 37 == 0 then
    right[#right + 1] = "changed " .. i
  elseif i % 53 == 0 then
    right[#right + 1] = "line " .. i
    right[#right + 1] = "added after " .. i
    right[#right + 1] = "added again " .. i
  elseif i % 71 ~= 0 then
    right[#right + 1] = "line " .. i
  end
end

local function percentile(sorted, p)
  if #sorted == 0 then
    return 0
  end
  return sorted[math.max(1, math.ceil(#sorted * p))]
end

local function run(mode, transmission)
  detect._reset()
  local bytes = 0
  detect._set_sink(function(d)
    bytes = bytes + #d
  end)
  local cfg = require("diffbandit.config").defaults()
  cfg.ui.connector_renderer = mode
  cfg.ui.kitty.cell_px = { tonumber(vim.env.DB_CW) or 10, tonumber(vim.env.DB_CH) or 20 }
  cfg.ui.kitty.transmission = transmission or "direct"
  cfg.ui.perf = { enabled = true, log = false, budget_warn_ms = 1e9 }
  local s = assert(Session.start({
    left = source.from_lines(left, nil, "left"),
    right = source.from_lines(right, nil, "right"),
  }, cfg, {}))
  s:render()
  local samples = {}
  local lt, rt = 1, 1
  for i = 1, steps do
    local phase = i % 3
    if phase == 0 then
      lt = lt + 7
    elseif phase == 1 then
      rt = rt + 11
    else
      lt, rt = lt + 3, rt + 3
    end
    nvim_util.set_win_view_topline(s.left_win, lt)
    nvim_util.set_win_view_topline(s.left_num_win, lt)
    nvim_util.set_win_view_topline(s.connector_win, lt)
    nvim_util.set_win_view_topline(s.right_win, rt)
    nvim_util.set_win_view_topline(s.right_num_win, rt)
    s:rerender_for_viewport()
    local perf = s._last_render_perf or {}
    samples[#samples + 1] = perf
  end
  local fields = { "total", "context", "paint_bg", "paint_routes", "kitty_raster", "kitty_transmit" }
  local out = {}
  for _, f in ipairs(fields) do
    local vals = {}
    for _, p in ipairs(samples) do
      if p[f] then
        vals[#vals + 1] = p[f]
      end
    end
    table.sort(vals)
    if #vals > 0 then
      out[#out + 1] = string.format("%s p50=%.2f p95=%.2f", f, percentile(vals, 0.5), percentile(vals, 0.95))
    end
  end
  local label = mode .. (mode == "kitty" and ("/" .. (transmission or "direct")) or "")
  io.stdout:write(string.format("%-13s %s", label, table.concat(out, "  ")))
  if mode == "kitty" then
    io.stdout:write(string.format("  bytes/paint=%.0f", bytes / steps))
  end
  io.stdout:write("\n")
  s.disposed = true
  detect._reset()
end

io.stdout:write(string.format("lines=%d steps=%d window=%dx%d\n", lines_n, steps, vim.o.columns, vim.o.lines))
run("cells")
run("kitty", "direct")
run("kitty", "file")
detect._set_sink(nil)
vim.cmd("qa!")
