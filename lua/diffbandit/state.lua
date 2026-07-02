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

return State
