-- Core two-way diff in Ghostty: Kitty-graphics bezier connectors, chunk
-- navigation, independent scroll. Same beats as demo/01-diff.tape.
-- cwd: /tmp/diffbandit-demo/pair
return function(t)
  t.hide()
  -- Drop unrelated plugin chrome and the "N lines" message; also clears the intro.
  t.keys(":set showtabline=0 laststatus=3 shortmess+=F<CR>")
  t.sleep(800)
  t.show()
  t.hold(500)
  t.still("01-a-boot")

  -- --- open the diff ---------------------------------------------------------
  t.type(":DiffBandit before.lua after.lua")
  t.hold(700)
  t.keys("<CR>")
  t.wait(t.kitty_ready(1), 20000, "kitty connector")
  t.hold(2000)
  t.still("01-b-open")
  t.hold(500)

  -- --- walk the chunks -------------------------------------------------------
  t.keys("]c")
  t.hold(1800)
  t.keys("]c")
  t.hold(1800)
  t.still("01-c-chunks")
  t.keys("]c")
  t.hold(1800)

  -- --- scroll ONE pane: ribbons re-project while the other side holds still --
  t.keys("<C-w>h")
  t.hold(900)
  t.still("01-d-left")
  t.keys("<C-d>")
  t.hold(1600)
  t.keys("<C-d>")
  t.hold(1800)
  t.still("01-e-scrolled")
  t.keys("<C-u>")
  t.hold(1600)

  -- Back to the right pane so the resting frame reads as the editable side.
  t.keys("<C-w>l")
  t.hold(2500)
  t.still("01-f-rest")
  t.hold(1500)
end
