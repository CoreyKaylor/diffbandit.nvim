-- Suite: public session-running predicates (`is_running` and named overloads)

do
  local diffbandit = require("diffbandit")
  local saved_sessions = state_mod.sessions
  local saved_panels = state_mod.panels
  state_mod.sessions = {}
  state_mod.panels = {}

  local tab = vim.api.nvim_get_current_tabpage()
  local other_tab = tab + 1000
  local file_buf = 42
  local merge_buf = 43
  local foreign_buf = 99
  local panel_buf = 77

  assert_eq(diffbandit.is_running(), false, "Empty registry: is_running() is false")
  assert_eq(diffbandit.has_session(), false, "Empty registry: has_session() is false")
  assert_eq(diffbandit.has_any_session(), false, "Empty registry: has_any_session() is false")
  assert_eq(diffbandit.owns_buffer(file_buf), false, "Empty registry: owns_buffer is false")
  assert_eq(diffbandit.is_running({ any = true }), false, "Empty registry: any-tab overload is false")
  assert_eq(diffbandit.is_running({ buf = file_buf }), false, "Empty registry: buf overload is false")
  assert_eq(diffbandit.is_running({ tab = other_tab }), false, "Empty registry: other tab is false")
  assert_eq(diffbandit.is_running(file_buf), false, "Bare number is rejected (tab/buf ambiguity)")
  assert_eq(diffbandit.is_running({}), false, "Empty query table is false")

  state_mod.sessions[other_tab] = {
    disposed = false,
    right_buf = file_buf,
    result_buf = merge_buf,
  }

  assert_eq(diffbandit.is_running(), false, "Session in another tab does not trip current-tab is_running()")
  assert_eq(diffbandit.has_session(), false, "Session in another tab does not trip has_session()")
  assert_eq(diffbandit.has_session(other_tab), true, "has_session(tab) sees the other tab")
  assert_eq(diffbandit.is_running({ tab = other_tab }), true, "{ tab = } overload matches that tab")
  assert_eq(diffbandit.has_any_session(), true, "has_any_session() is true with a live session in any tab")
  assert_eq(diffbandit.is_running({ any = true }), true, "{ any = true } matches a live session in another tab")
  assert_eq(diffbandit.owns_buffer(file_buf), true, "owns_buffer sees a 2-way right_buf")
  assert_eq(diffbandit.owns_buffer(merge_buf), true, "owns_buffer sees a merge result_buf")
  assert_eq(diffbandit.is_running({ buf = file_buf }), true, "{ buf = } overload matches the owned buffer")
  assert_eq(diffbandit.owns_buffer(foreign_buf), false, "owns_buffer ignores an unrelated bufnr")

  state_mod.sessions[other_tab].disposed = true
  assert_eq(diffbandit.has_session(other_tab), false, "Disposed session is not live")
  assert_eq(diffbandit.has_any_session(), false, "Disposed session does not count as any-session")
  assert_eq(diffbandit.owns_buffer(file_buf), false, "Disposed session does not own buffers")

  state_mod.sessions[other_tab] = nil
  state_mod.sessions[tab] = {
    disposed = false,
    left_buf = 8,
    right = { editable = { bufnr = file_buf } },
  }
  assert_eq(diffbandit.is_running(), true, "is_running() is true for a live session in the current tab")
  assert_eq(diffbandit.has_session(), true, "has_session() matches the current tab")
  assert_eq(diffbandit.owns_buffer(file_buf), true, "owns_buffer follows right.editable.bufnr")
  assert_eq(diffbandit.owns_buffer(8), true, "owns_buffer follows left_buf")

  state_mod.sessions[tab] = nil
  state_mod.panels[tab] = {
    disposed = false,
    panel = { nav_buf = panel_buf, commit_buf = 78 },
  }
  assert_eq(diffbandit.is_running(), false, "Standalone commit_panel is not a session")
  assert_eq(diffbandit.has_any_session(), false, "Standalone commit_panel is not has_any_session()")
  assert_eq(diffbandit.is_running({ panel = true }), true, "{ panel = true } includes a live commit_panel in this tab")
  assert_eq(diffbandit.is_running({ any = true, panel = true }), true, "{ any, panel } includes a live commit_panel")
  assert_eq(diffbandit.is_running({ any = true }), false, "{ any = true } still ignores panels unless panel=true")
  assert_eq(diffbandit.owns_buffer(panel_buf), true, "owns_buffer includes standalone panel nav_buf")
  assert_eq(diffbandit.is_running({ buf = panel_buf }), true, "{ buf = } matches a panel buffer")

  state_mod.panels[tab].disposed = true
  assert_eq(diffbandit.is_running({ panel = true }), false, "Disposed panel is not running")
  assert_eq(diffbandit.owns_buffer(panel_buf), false, "Disposed panel does not own buffers")

  state_mod.sessions = saved_sessions
  state_mod.panels = saved_panels
end
