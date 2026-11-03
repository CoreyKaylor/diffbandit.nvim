-- Three-way merge where the two sides change the same regions differently, so
-- the left (local) and right (remote) ribbons take different shapes: expand
-- vs shrink, add wedges, a delete wedge, and same-point inserts of different
-- heights. Exercises the Kitty connector geometry on both sides of the result.
-- cwd: /tmp/diffbandit-demo/merge
-- size: 150x30
return function(t)
  -- In merge views ]c walks every hunk (conflicts and plain changes alike),
  -- so conflicts are targeted directly, as the conflict panel does.
  local function conflict(i)
    t.run(function() t.session():goto_conflict(i) end)
  end

  t.hide()
  t.keys(":set showtabline=0 laststatus=3 shortmess+=F<CR>")
  t.sleep(800)
  t.show()
  t.hold(500)

  -- --- open: every ribbon measured against base -------------------------------
  t.type(":DiffBanditMerge queue.lua")
  t.hold(700)
  t.keys("<CR>")
  t.wait(function()
    return t.screen_has("merge result") and t.kitty_ready(2)()
  end, 20000, "merge view")
  t.hold(3000)
  t.still("06-a-open")

  -- --- walk hunks: the three panes drift apart by different amounts ----------
  for _ = 1, 4 do
    t.keys("]c")
    t.hold(1400)
  end
  t.still("06-b-walk")

  -- --- resolve each conflict a different way ---------------------------------
  conflict(1)
  t.hold(1200)
  t.keys(">>", { settle = 300 })
  t.hold(2000)
  t.still("06-c-local")

  conflict(2)
  t.hold(1200)
  t.keys("<lt><lt>", { settle = 300 })
  t.hold(2000)
  t.still("06-d-remote")

  conflict(3)
  t.hold(1200)
  t.keys("gb", { settle = 300 })
  t.hold(2500)
  t.still("06-e-both")

  -- --- take the remaining non-conflicting changes ------------------------------
  t.keys("gA", { settle = 400 })
  t.hold(2500)
  t.keys("[d")
  t.hold(3000)
  t.still("06-f-resolved")
  t.hold(1000)
  -- Keep the resolved text next to the frames for checking.
  vim.fn.writefile(vim.api.nvim_buf_get_lines(t.session().result_buf, 0, -1, false),
    vim.env.DEMO_OUT .. "/result.lua")
end
