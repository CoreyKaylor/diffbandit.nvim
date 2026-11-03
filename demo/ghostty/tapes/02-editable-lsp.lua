-- The right pane is a real, editable document -- LSP completion, diagnostics,
-- and undo, with the diff recomputing live underneath the edit.
-- Same beats as demo/02-editable-lsp.tape.
-- cwd: /tmp/diffbandit-demo/pair
return function(t)
  t.hide()
  t.keys(":set showtabline=0 laststatus=3 shortmess+=F<CR>")
  t.keys(":DiffBandit before.lua after.lua<CR>")
  t.wait(t.kitty_ready(1), 20000, "kitty connector")
  t.wait(t.lsp_attached("lua_ls"), 30000, "lua_ls")
  t.sleep(1000)
  t.show()
  t.hold(2000)

  -- --- jump into the right pane's TTL helper ---------------------------------
  -- Line 43 is `local age = ...`; opening below keeps the new statements ahead
  -- of the function's `return`, so the only diagnostic is the intended one.
  t.type(":43")
  t.keys("<CR>")
  t.hold(1500)

  -- --- completion: a real buffer with a real language server -----------------
  t.keys("o")
  t.hold(600)
  t.type("local slack = self.")
  t.wait(t.completion_visible, 10000, "completion menu")
  t.hold(2500)
  t.still("02-a-completion")
  t.type("ttl")
  t.hold(1200)
  t.keys("<Esc>")
  t.hold(400)
  -- The diff recomputes under the edit (debounced): a new add row and route.
  t.keys("<Esc>", { settle = 600 })
  t.hold(2500)
  t.still("02-b-live-diff")

  -- --- diagnostics land inside the diff pane ---------------------------------
  t.keys("o")
  t.hold(500)
  t.type("undefined_helper()")
  t.hold(800)
  t.keys("<Esc>", { settle = 600 })
  t.wait(t.problems(function(n) return n > 0 end), 15000, "diagnostic")
  t.hold(2500)
  t.still("02-c-diagnostic")
  t.hold(1500)

  -- --- undo: the diff snaps back immediately ---------------------------------
  t.keys("u", { settle = 300 })
  t.hold(1500)
  t.keys("u", { settle = 300 })
  -- lua_ls briefly reports an error for the half-undone state; wait it out.
  t.wait(t.problems(function(n) return n == 0 end), 15000, "diagnostics cleared")
  t.hold(2500)
  t.still("02-d-undone")
  t.hold(1500)
end
