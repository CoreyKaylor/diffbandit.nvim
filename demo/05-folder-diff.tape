# Recursive folder diff: compare two trees, drill into a file, return.
Output docs/demo/05-folder-diff.gif

Require nvim

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1240
Set Height 520
Set Padding 20
Set Framerate 24
Set TypingSpeed 55ms
Set WaitTimeout 20s
Set Theme { "background": "#1F1F28", "foreground": "#DCD7BA", "cursor": "#C8C093", "selection": "#2D4F67" }

# --- launch ------------------------------------------------------------------
Hide
Type "cd /tmp/diffbandit-demo && clear"
Enter
# cell_wedges + xterm-vhs terminfo: see demo/README.md.
Type "TERMINFO=/tmp/diffbandit-demo/terminfo TERM=xterm-vhs nvim --cmd 'lua vim.g.diffbandit_have_nerd_font = true; vim.g.diffbandit_cell_wedges = true'"
Enter
Sleep 4s
Type ":set showtabline=0 laststatus=3 shortmess+=F"
Enter
Sleep 1s
Show

# --- compare the two trees ---------------------------------------------------
Type ":DiffBanditFolderDiff folder-left folder-right"
Sleep 700ms
Enter
# Comparison is async and fills statuses in progressively; let it settle.
Wait+Screen@20s /config\.lua/
Sleep 3s
Screenshot docs/demo/.frames/05-a-tree.png

# --- expand the whole tree ---------------------------------------------------
Type "zR"
Sleep 2500ms
Screenshot docs/demo/.frames/05-b-expanded.png

# --- walk to changed files by status, not by counting rows -------------------
# Two presses land on store/cache.lua, the nested file with a two-sided diff.
# (A third would move past it and open the trailing right-only file.)
Type "]c"
Sleep 1600ms
Screenshot docs/demo/.frames/05-c1.png
Type "]c"
Sleep 1800ms
Screenshot docs/demo/.frames/05-c2.png

# --- drill into the selected file, then come back ---------------------------
Enter
Sleep 3s
Screenshot docs/demo/.frames/05-d-child.png
Type "]c"
Sleep 2s
Type "q"
Sleep 2500ms
Screenshot docs/demo/.frames/05-e-back.png

# Rest on the final state: gives the loop a readable last frame, and VHS
# can drop a Screenshot that is the very last command in a tape.
Sleep 1500ms
