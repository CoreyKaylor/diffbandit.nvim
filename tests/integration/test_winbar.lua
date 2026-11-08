-- Statusline plugins rewrite winbars (issue #35). lualine's refresh timer
-- sets its own bar, often an empty one, on every window in the tab,
-- DiffBandit's gutters included. The gutters' blank bar has to be back
-- before the next redraw, or their numbers jump a row up for a frame on
-- every refresh.
--
-- This runs in a child Neovim because OptionSet, which catches those
-- writes, does not fire during startup, and tests/run.lua runs entirely
-- inside startup.
local child_mod = require("helpers.child")
local state = require("helpers.state")
local files = child_mod.files

local child = child_mod.new({ lines = 30, columns = 160 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

T["foreign bar writes are undone before the next redraw"] = function()
  child:start()
  child:cmd("DiffBandit " .. files .. "/left_wrap.txt " .. files .. "/right_wrap.txt")
  child:settle()
  local result = child:lua([[
    local winbar = require("diffbandit.util.winbar")
    local session_layout = require("diffbandit.session.layout")
    local s = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    local function spec() return session_layout.winbar_spec(s) end
    vim.wo[s.right_win].winbar = "crumbs"
    vim.wait(1000, function()
      vim.cmd("redraw")
      return winbar.aligned(spec())
    end, 10)
    local out = { gutter_blank = vim.wo[s.connector_win].winbar == winbar.BLANK, checks = {} }
    for _, foreign in ipairs({ "", "%f" }) do
      for _, win in ipairs({ s.connector_win, s.left_num_win, s.right_num_win, s.left_win }) do
        vim.api.nvim_set_option_value("winbar", foreign, { scope = "local", win = win })
        -- No redraw and no event-loop turn in between: the screen never sees it.
        out.checks[#out.checks + 1] = { foreign = foreign, win = win, aligned = winbar.aligned(spec()) }
      end
    end
    -- The same write from a timer callback, the way lualine refreshes.
    local done = false
    vim.defer_fn(function()
      vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = s.connector_win })
      out.timer_aligned = winbar.aligned(spec())
      done = true
    end, 10)
    vim.wait(1000, function() return done end, 5)
    return out
  ]])
  state.truthy(result.gutter_blank, "a pane bar gives the gutters a blank bar")
  for _, check in ipairs(result.checks) do
    state.truthy(check.aligned, ("a foreign %q bar on win %d is undone at once"):format(check.foreign, check.win))
  end
  state.truthy(result.timer_aligned, "a bar written from a timer is undone at once")
end

return T
