# Commit panel: browse changed files with live preview, stage hunks, commit.
Output docs/demo/04-commit-panel.gif

Require nvim
Require git

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1620
Set Height 580
Set Padding 20
Set Framerate 24
Set TypingSpeed 55ms
Set WaitTimeout 20s
Set Theme { "background": "#1F1F28", "foreground": "#DCD7BA", "cursor": "#C8C093", "selection": "#2D4F67" }

# --- launch ------------------------------------------------------------------
Hide
Type "cd /tmp/diffbandit-demo/repo && clear"
Enter
# cell_wedges + xterm-vhs terminfo: see demo/README.md.
Type "TERMINFO=/tmp/diffbandit-demo/terminfo TERM=xterm-vhs nvim --cmd 'lua vim.g.diffbandit_have_nerd_font = true; vim.g.diffbandit_cell_wedges = true'"
Enter
Sleep 4s
Type ":set showtabline=0 laststatus=3 shortmess+=F"
Enter
Sleep 1s
Show

# --- open the panel ----------------------------------------------------------
Type ":DiffBanditCommitPanel"
Sleep 700ms
Enter
Wait+Screen@20s /router\.lua/
Sleep 3s
Screenshot docs/demo/.frames/04-a-open.png

# --- walk the changed files; the diff preview follows the cursor -------------
Type "j"
Sleep 2s
Screenshot docs/demo/.frames/04-b-preview.png
Type "j"
Sleep 2s

# --- stage two files ---------------------------------------------------------
Space
Sleep 2s
Screenshot docs/demo/.frames/04-c-staged.png
Type "k"
Sleep 1200ms
Space
Sleep 2s

# --- write a message and commit ---------------------------------------------
Type "cc"
Sleep 1200ms
Type "i"
Sleep 400ms
Type "Add middleware hooks and trace-level logging"
Sleep 1200ms
Escape
Sleep 800ms
Screenshot docs/demo/.frames/04-d-message.png
Type ":w"
Sleep 600ms
Enter
Sleep 3s
Screenshot docs/demo/.frames/04-e-committed.png
Sleep 1s
