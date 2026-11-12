-- Builds a scroll scenario test set: each phase starts a fresh child, opens
-- the diff, sets both viewports (or focuses a side and presses j N times),
-- then checks the screen with verify "<scenario>:<phase>".
local child_mod = require("helpers.child")
local verify = require("helpers.verify")

local M = {}

local function check(scenario, phase, dir, child)
  local plain, ansi = child:capture(dir, phase)
  local errors = verify.check(scenario .. ":" .. phase, plain, ansi)
  if #errors > 0 then
    error(string.format("%s:%s failed (capture: %s/%s.ansi):\n  - %s",
      scenario, phase, dir, phase, table.concat(errors, "\n  - ")), 0)
  end
end

--- spec = { scenario, left, right, phases = { {name, left_top, right_top, tall?} },
---          keys = { {name, side, count} } }
function M.set(spec)
  local child = child_mod.new({ columns = 120 })
  local dir
  local open = "DiffBandit " .. child_mod.files .. "/" .. spec.left .. " " .. child_mod.files .. "/" .. spec.right

  local T = MiniTest.new_set({
    hooks = {
      pre_once = function()
        dir = child_mod.case_dir(spec.scenario)
      end,
      post_case = function()
        child:stop()
      end,
    },
  })

  T["viewport"] = MiniTest.new_set({ parametrize = spec.phases })
  T["viewport"]["phase"] = function(phase, left_top, right_top, tall)
    child:start({ lines = tall and 40 or 16 })
    child:cmd(open):settle()
    child:keys("<Esc>")
    child:cmd(string.format("DBViewport %d %d", left_top, right_top)):settle()
    check(spec.scenario, phase, dir, child)
  end

  if spec.keys and #spec.keys > 0 then
    T["keys"] = MiniTest.new_set({ parametrize = spec.keys })
    T["keys"]["phase"] = function(phase, side, count)
      child:start({ lines = 16 })
      -- These phases scroll one pane apart from the other on purpose.
      child:lua("require('diffbandit').setup({ ui = { scroll_lock = false } })")
      child:cmd(open):settle()
      child:keys("<Esc>")
      child:cmd("DBViewport 1 1")
      child:cmd("DBFocus " .. side):settle()
      child:keys(string.rep("j", count))
      child:settle()
      check(spec.scenario, phase, dir, child)
    end
  end

  return T
end

return M
