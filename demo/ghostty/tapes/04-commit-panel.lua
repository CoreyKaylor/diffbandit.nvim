-- Commit panel: browse changed files with live preview, stage hunks, commit.
-- Same beats as demo/04-commit-panel.tape.
-- cwd: /tmp/diffbandit-demo/repo
-- size: 147x24
return function(t)
  t.hide()
  t.keys(":set showtabline=0 laststatus=3 shortmess+=F<CR>")
  t.sleep(800)
  t.show()
  t.hold(500)

  -- --- open the panel -----------------------------------------------------------
  t.type(":DiffBanditCommitPanel")
  t.hold(700)
  t.keys("<CR>")
  -- The panel opens with an empty preview; no connector until a file is chosen.
  t.wait(function() return t.screen_has("router%.lua") end, 20000, "commit panel")
  t.hold(3000)
  t.still("04-a-open")

  -- --- walk the changed files; the diff preview follows the cursor ------------
  -- Previews load from git asynchronously; settle long enough to catch them.
  t.keys("j", { settle = 700 })
  t.hold(2000)
  t.still("04-b-preview")
  t.keys("j", { settle = 700 })
  t.hold(2000)

  -- --- stage two files ------------------------------------------------------------
  t.keys("<Space>", { settle = 700 })
  t.hold(2000)
  t.still("04-c-staged")
  t.keys("k", { settle = 700 })
  t.hold(1200)
  t.keys("<Space>", { settle = 700 })
  t.hold(2000)

  -- --- write a message and commit ------------------------------------------------
  t.keys("cc", { settle = 400 })
  t.hold(1200)
  t.keys("i")
  t.hold(400)
  t.type("Add middleware hooks and trace-level logging")
  t.hold(1200)
  t.keys("<Esc>")
  t.hold(800)
  t.still("04-d-message")
  t.type(":w")
  t.hold(600)
  t.keys("<CR>", { settle = 1200 })
  t.hold(3000)
  t.still("04-e-committed")
  t.hold(1000)
end
