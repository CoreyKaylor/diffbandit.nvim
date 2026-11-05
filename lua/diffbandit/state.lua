local config_mod = require("diffbandit.config")

local State = {
  _config = config_mod.defaults(),
  sessions = {},
  panels = {},
  _session_seq = 0,
  -- Highlight bootstrap state owned by init.lua: whether highlight groups
  -- have been applied, and the ColorScheme-refresh augroup id.
  highlights_ready = false,
  theme_augroup = nil,
  -- Set by the standalone launcher (bin/diffbandit): the panel's close key
  -- quits nvim instead of only hiding the panel.
  quit_on_close = false,
  -- Unfinished commit messages by repository root, saved when a view with a
  -- commit panel closes and restored the next time a panel opens there.
  commit_drafts = {},
  -- Other DiffBandit windows the launcher counts as open views (the git log
  -- browser): view -> true, each with an is_open() method.
  views = {},
}

function State.set_config(user)
  State._config = config_mod.apply(user)
  return State._config
end

function State.get_config()
  return State._config
end

function State.next_session_id()
  State._session_seq = State._session_seq + 1
  return State._session_seq
end

function State.register(session)
  State.sessions[session.tabpage] = session
end

function State.unregister(tabpage)
  State.sessions[tabpage] = nil
end

function State.register_panel(panel)
  State.panels[panel.tabpage] = panel
end

function State.unregister_panel(tabpage)
  State.panels[tabpage] = nil
end

function State.register_view(view)
  State.views[view] = true
end

function State.unregister_view(view)
  State.views[view] = nil
end

return State
