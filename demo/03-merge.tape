# Three-way merge resolver: local | result | remote, taking a side per conflict.
Output docs/demo/03-merge.gif

Require nvim
Require git

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1560
Set Height 580
Set Padding 20
Set Framerate 24
Set TypingSpeed 55ms
Set WaitTimeout 20s
Set Theme { "background": "#1F1F28", "foreground": "#DCD7BA", "cursor": "#C8C093", "selection": "#2D4F67" }

# --- launch ------------------------------------------------------------------
Hide
Type "cd /tmp/diffbandit-demo/merge && clear"
Enter
# cell_wedges + xterm-vhs terminfo: see demo/README.md.
Type "TERMINFO=/tmp/diffbandit-demo/terminfo TERM=xterm-vhs nvim --cmd 'lua vim.g.diffbandit_have_nerd_font = true; vim.g.diffbandit_cell_wedges = true'"
Enter
Sleep 4s
Type ":set showtabline=0 laststatus=3 shortmess+=F"
Enter
Sleep 1s
Show

# --- open the conflicted file ------------------------------------------------
Type ":DiffBanditMerge retry.lua"
Sleep 700ms
Enter
Wait+Screen@20s /merge result/
Sleep 3s
Screenshot docs/demo/.frames/03-a-open.png

# --- conflict 1: take our side ----------------------------------------------
# The cursor opens at line 1, which is not inside a conflict, so >>/<< would be
# a no-op there. Jump to the first conflict before accepting anything.
Type "]c"
Sleep 1500ms
Type ">>"
Sleep 2500ms
Screenshot docs/demo/.frames/03-b-local.png

# --- conflict 2: take theirs -------------------------------------------------
Type "]c"
Sleep 1800ms
Type "<<"
Sleep 2500ms
Screenshot docs/demo/.frames/03-c-remote.png

# --- write: resolves the file and stages it ----------------------------------
Type ":w"
Sleep 600ms
Enter
Sleep 3s
# Back to the top so the resting frame shows the whole resolved file rather
# than the tail end of the last conflict.
Type "[d"
Sleep 2500ms
Screenshot docs/demo/.frames/03-d-resolved.png

# Rest on the final state: gives the loop a readable last frame, and VHS
# can drop a Screenshot that is the very last command in a tape.
Sleep 1500ms
