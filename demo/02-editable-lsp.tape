# The right pane is a real, editable document -- LSP completion, diagnostics,
# and undo, with the diff recomputing live underneath the edit.
Output docs/demo/02-editable-lsp.gif

Require nvim

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1240
Set Height 580
Set Padding 20
Set Framerate 24
Set TypingSpeed 75ms
Set WaitTimeout 30s
Set Theme { "background": "#1F1F28", "foreground": "#DCD7BA", "cursor": "#C8C093", "selection": "#2D4F67" }

# --- launch ------------------------------------------------------------------
Hide
Type "cd /tmp/diffbandit-demo/pair && clear"
Enter
# cell_wedges + xterm-vhs terminfo: see demo/README.md.
Type "TERMINFO=/tmp/diffbandit-demo/terminfo TERM=xterm-vhs nvim --cmd 'lua vim.g.diffbandit_have_nerd_font = true; vim.g.diffbandit_cell_wedges = true'"
Enter
Sleep 4s
Type ":set showtabline=0 laststatus=3 shortmess+=F"
Enter
Sleep 1s
Type ":DiffBandit before.lua after.lua"
Enter
# The statusline renders "[lua_ls]" once the server attaches to the right pane.
Wait+Screen@30s /lua_ls/
Sleep 1s
Show

Sleep 2s

# --- jump into the right pane's TTL helper -----------------------------------
# Line 43 is `local age = ...`; opening below keeps the new statements ahead of
# the function's `return`, so the only diagnostic is the intended one.
Type ":43"
Enter
Sleep 1500ms

# --- completion: this is a real buffer with a real language server -----------
Type "o"
Sleep 600ms
Type "local slack = self."
Sleep 2500ms
Screenshot docs/demo/.frames/02-a-completion.png
Type "ttl"
Sleep 1200ms
Escape
Sleep 400ms
Escape
# The diff recomputes under the edit: a new add row and route appear.
Sleep 2500ms
Screenshot docs/demo/.frames/02-b-live-diff.png

# --- diagnostics land inside the diff pane -----------------------------------
Type "o"
Sleep 500ms
Type "undefined_helper()"
Sleep 800ms
Escape
Sleep 2500ms
Screenshot docs/demo/.frames/02-c-diagnostic.png
Sleep 1500ms

# --- undo: the diff snaps back immediately -----------------------------------
Type "u"
Sleep 1500ms
Type "u"
Sleep 2500ms
Screenshot docs/demo/.frames/02-d-undone.png

# Rest on the final state: gives the loop a readable last frame, and VHS
# can drop a Screenshot that is the very last command in a tape.
Sleep 1500ms
