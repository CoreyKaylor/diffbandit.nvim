#!/bin/sh
# Runs INSIDE the recorded Ghostty window (record.sh passes the environment).
# Bare nvim on purpose: like the VHS tapes, this records the user's real config.
cd "$DEMO_CWD" || exit 1
exec nvim \
  --cmd "lua vim.g.diffbandit_have_nerd_font = true; vim.g.diffbandit_connector_renderer = 'kitty'" \
  -c "luafile $DEMO_RUNNER"
