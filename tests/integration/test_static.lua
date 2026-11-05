-- Static fixtures: open a 2-way diff at 120x48 and check the whole screen.
local child_mod = require("helpers.child")
local verify = require("helpers.verify")
local files = child_mod.files

local child = child_mod.new({ lines = 48, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
    post_once = function()
      child:stop()
    end,
  },
})

local FIXTURES = {
  { "extreme", "left_extreme.txt", "right_extreme.txt" },
  { "pure", "left_additions.txt", "right_additions.txt" },
  { "deletions", "left_deletions.txt", "right_deletions.txt" },
  { "mixed", "left_mixed.txt", "right_mixed.txt" },
  { "dense-mixed", "left_dense_mixed.txt", "right_dense_mixed.txt" },
  { "theme-default", "left_mixed.txt", "right_mixed.txt" },
  { "comprehensive", "left_comprehensive.txt", "right_comprehensive.txt" },
}

T["fixture"] = MiniTest.new_set({
  parametrize = vim.tbl_map(function(f)
    return { f[1], f[2], f[3] }
  end, FIXTURES),
})

T["fixture"]["renders"] = function(name, left, right)
  local dir = child_mod.case_dir(name)
  child:start()
  child:cmd("DiffBandit " .. files .. "/" .. left .. " " .. files .. "/" .. right)
  child:settle()
  local plain, ansi = child:capture(dir)
  local errors = verify.check(name, plain, ansi)
  if #errors > 0 then
    error(name .. " failed (capture: " .. dir .. "):\n  - " .. table.concat(errors, "\n  - "), 0)
  end
end

return T
