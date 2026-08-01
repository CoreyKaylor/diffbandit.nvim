# Core two-way diff: the connector gutter, chunk navigation, independent scroll.
Output docs/demo/01-diff.gif

Require nvim

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1240
Set Height 580
Set Padding 20
Set Framerate 24
Set TypingSpeed 55ms
Set WaitTimeout 20s
Set Theme { "background": "#1F1F28", "foreground": "#DCD7BA", "cursor": "#C8C093", "selection": "#2D4F67" }

# --- launch (hidden: no shell prompt or boot frames in the GIF) ---------------
Hide
Type "cd /tmp/diffbandit-demo/pair && clear"
Enter
# Launch bare -- opening a file first would leave a "N lines" message parked in
# the message line for the whole recording.
# cell_wedges + xterm-vhs terminfo: see demo/README.md (VHS wedges and
# colored underlines). TERMINFO is compiled by fixtures.sh.
Type "TERMINFO=/tmp/diffbandit-demo/terminfo TERM=xterm-vhs nvim --cmd 'lua vim.g.diffbandit_have_nerd_font = true; vim.g.diffbandit_cell_wedges = true'"
Enter
Sleep 4s
# Drop the bufferline tabline (unrelated plugin chrome), use a single global
# statusline, and silence the "N lines" file-read message that DiffBandit's own
# buffer loads would otherwise park in the message line. Also clears the intro.
Type ":set showtabline=0 laststatus=3 shortmess+=F"
Enter
Sleep 1s
Screenshot docs/demo/.frames/01-a-boot.png
Show

# --- open the diff -----------------------------------------------------------
Type ":DiffBandit before.lua after.lua"
Sleep 700ms
Enter
Wait+Screen@20s /before\.lua/
Sleep 2s
Screenshot docs/demo/.frames/01-b-open.png
Sleep 500ms

# --- walk the chunks ---------------------------------------------------------
Type "]c"
Sleep 1800ms
Type "]c"
Sleep 1800ms
Screenshot docs/demo/.frames/01-c-chunks.png
Type "]c"
Sleep 1800ms

# --- scroll ONE pane: routes re-project while the other side holds still ------
Ctrl+w
Type "h"
Sleep 900ms
Screenshot docs/demo/.frames/01-d-left.png
Ctrl+d
Sleep 1600ms
Ctrl+d
Sleep 1800ms
Screenshot docs/demo/.frames/01-e-scrolled.png
Ctrl+u
Sleep 1600ms

# Back to the right pane so the resting frame reads as the editable side.
Ctrl+w
Type "l"
Sleep 2500ms
Screenshot docs/demo/.frames/01-f-rest.png

# Rest on the final state: gives the loop a readable last frame, and VHS
# can drop a Screenshot that is the very last command in a tape.
Sleep 1500ms
