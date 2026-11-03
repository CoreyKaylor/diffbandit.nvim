-- Three-way merge resolver: local | result | remote, taking a side per conflict.
-- Same beats as demo/03-merge.tape.
-- cwd: /tmp/diffbandit-demo/merge
-- size: 142x24
return function(t)
  t.hide()
  t.keys(":set showtabline=0 laststatus=3 shortmess+=F<CR>")
  t.sleep(800)
  t.show()
  t.hold(500)

  -- --- open the conflicted file ----------------------------------------------
  t.type(":DiffBanditMerge retry.lua")
  t.hold(700)
  t.keys("<CR>")
  t.wait(function()
    return t.screen_has("merge result") and t.kitty_ready(2)()
  end, 20000, "merge view")
  t.hold(3000)
  t.still("03-a-open")

  -- --- conflict 1: take our side ---------------------------------------------
  -- The cursor opens at line 1, outside any conflict, so >>/<< would be a no-op.
  t.keys("]c")
  t.hold(1500)
  t.keys(">>", { settle = 300 })
  t.hold(2500)
  t.still("03-b-local")

  -- --- conflict 2: take theirs ------------------------------------------------
  t.keys("]c")
  t.hold(1800)
  t.keys("<lt><lt>", { settle = 300 })
  t.hold(2500)
  t.still("03-c-remote")

  -- --- write: resolves the file and stages it ----------------------------------
  t.type(":w")
  t.hold(600)
  t.keys("<CR>", { settle = 1000 })
  t.hold(3000)
  -- Back to the top so the resting frame shows the whole resolved file.
  t.keys("[d")
  t.hold(2500)
  t.still("03-d-resolved")
  t.hold(1500)
end
