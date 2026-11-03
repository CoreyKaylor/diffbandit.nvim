-- Recursive folder diff: compare two trees, drill into a file, return.
-- Same beats as demo/05-folder-diff.tape.
-- cwd: /tmp/diffbandit-demo
-- size: 112x21
return function(t)
  t.hide()
  t.keys(":set showtabline=0 laststatus=3 shortmess+=F<CR>")
  t.sleep(800)
  t.show()
  t.hold(500)

  -- --- compare the two trees ------------------------------------------------------
  t.type(":DiffBanditFolderDiff folder-left folder-right")
  t.hold(700)
  t.keys("<CR>")
  -- Comparison is async and fills statuses in progressively; let it finish
  -- off-camera, then capture the settled tree.
  t.wait(function() return t.screen_has("config%.lua") end, 20000, "folder tree")
  t.sleep(1500)
  t.snap()
  t.hold(3000)
  t.still("05-a-tree")

  -- --- expand the whole tree -----------------------------------------------------
  t.keys("zR")
  t.hold(2500)
  t.still("05-b-expanded")

  -- --- walk to changed files by status, not by counting rows ------------------
  -- Two presses land on store/cache.lua, the nested file with a two-sided diff.
  -- (A third would move past it and open the trailing right-only file.)
  t.keys("]c")
  t.hold(1600)
  t.keys("]c")
  t.hold(1800)
  t.still("05-c-selected")

  -- --- drill into the selected file, then come back -------------------------
  t.keys("<CR>")
  t.wait(t.kitty_ready(1), 20000, "child diff connector")
  t.hold(3000)
  t.still("05-d-child")
  t.keys("]c")
  t.hold(2000)
  t.keys("q", { settle = 400 })
  t.hold(2500)
  t.still("05-e-back")
  t.hold(1500)
end
