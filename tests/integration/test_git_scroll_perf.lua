-- Rapid <C-e> bursts over a 5000-line git file: the debounced viewport
-- rerender must keep paint counts well below the scroll event count.
--
-- Each <C-e> is typed separately and followed by a round-trip request, so the
-- child processes it (scroll, redraw, WinScrolled) before the next one: every
-- key is its own scroll event, like a held key or a fast wheel. render_count
-- counts paints on every path (tests/integration/init.lua wraps
-- session.render.render), including debounced viewport repaints.
local child_mod = require("helpers.child")
local state = require("helpers.state")

local child = child_mod.new({ lines = 24, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local CHANGED = { [250] = true, [750] = true, [1250] = true, [1750] = true, [2250] = true,
  [2750] = true, [3250] = true, [3750] = true, [4250] = true, [4750] = true }

-- Port of write_large_scroll_repo (run.sh).
local function write_large_scroll_repo(repo, line_count)
  line_count = line_count or 5000
  state.init_repo(repo)
  local base, changed = {}, {}
  for i = 1, line_count do
    base[i] = string.format("local value_%04d = %04d", i, i)
    if CHANGED[i] then
      changed[i] = string.format("local value_%04d = %04d -- changed", i, i + 10000)
    else
      changed[i] = base[i]
    end
  end
  state.write(repo .. "/big.lua", base)
  state.git(repo, { "add", "big.lua" })
  state.git(repo, { "commit", "-m", "baseline" })
  state.write(repo .. "/big.lua", changed)
end

T["rapid scroll bursts"] = function()
  local dir = child_mod.case_dir("git-scroll-perf")
  local repo = dir .. "/repo"
  write_large_scroll_repo(repo, 5000)

  child:start({ lines = 24, cwd = repo })
  child:cmd("lua require('diffbandit').setup({ ui = { scroll_debounce_ms = 25 } })")
  child:cmd("edit big.lua")
  child:settle()
  child:cmd("DiffBanditGitCurrent")
  child:settle()
  child:state("DBWritePerfState", dir, "initial")
  child:cmd("DBResetPerf")
  child:cmd("DBFocus right")
  child:settle()

  local function burst(label, scroll_events, min_top)
    child:cmd("DBResetPerf")
    for _ = 1, scroll_events do
      child:keys("<C-e>")
      child:lua("return 0") -- wait until the key has been processed
    end
    child:settle()
    local lines, path = child:state("DBWritePerfState", dir, label)
    local dump = table.concat(lines, "\n")
    local render_count = tonumber(state.value(lines, "render_count"))
    local request_count = tonumber(state.value(lines, "viewport_request_count"))
    local right_top = tonumber(state.value(lines, "right_top"))
    local right_lines = tonumber(state.value(lines, "right_lines"))

    if not render_count or not request_count or not right_top then
      error("Git scroll perf state missing expected values (" .. label .. ") " .. path .. "\n" .. dump, 0)
    end
    if (right_lines or 0) < 5000 then
      error("Git scroll perf fixture did not load the large current file (" .. label .. ") " .. path .. "\n" .. dump, 0)
    end
    if right_top < min_top then
      error(string.format("Git scroll perf failed: rapid scroll did not reach expected depth (%s)\nevents=%d min_top=%d\n%s",
        label, scroll_events, min_top, dump), 0)
    end
    if request_count <= 0 then
      error("Git scroll perf failed: rapid scroll did not hit viewport rerender scheduling (" .. label .. ")\n" .. dump, 0)
    end
    -- If the scrolls reach DiffBandit as a few coalesced events, the render
    -- check below passes no matter what the debounce does.
    if request_count < math.floor(scroll_events / 2) then
      error(string.format("Git scroll perf failed: scroll events were coalesced before DiffBandit saw them (%s)\nevents=%d requests=%d\n%s",
        label, scroll_events, request_count, dump), 0)
    end
    -- bash: (( render_count >= scroll_events / 2 )) with integer division
    if render_count >= math.floor(scroll_events / 2) then
      error(string.format("Git scroll perf failed: render count too high for debounced scroll (%s)\nevents=%d renders=%d requests=%d\n%s",
        label, scroll_events, render_count, request_count, dump), 0)
    end
  end

  burst("burst-1", 80, 70)
  burst("burst-2", 420, 480)
  burst("burst-3", 900, 1350)
  burst("burst-4", 1800, 3100)
end

return T
