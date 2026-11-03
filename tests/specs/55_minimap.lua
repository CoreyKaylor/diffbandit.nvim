-- Editor minimap: the shared minimap component on ordinary editor windows
-- (float placement, git-hunk and diagnostics providers, window-event mouse,
-- buffer switches, DiffBandit-tab exclusion). Wrapped in one block so its
-- locals stay out of the shared runner chunk's top-level scope.
do
  local minimap_editor = require("diffbandit.minimap.editor")
  local minimap_mouse = require("diffbandit.minimap.mouse")
  local providers = require("diffbandit.minimap.providers")
  local placement = require("diffbandit.minimap.placement")
  local mm_state = require("diffbandit.state")

  local function wait(pred, ms)
    return vim.wait(ms or 2000, pred, 10)
  end

  local function git(args, cwd)
    local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
    if result.code ~= 0 then
      error("git " .. table.concat(args, " ") .. ": " .. tostring(result.stderr))
    end
  end

  -- Pure: hunks of a buffer against its index text.
  local h = providers.line_hunks({ "a", "b", "c" }, { "a", "B", "c", "d" })
  assert_eq(#h, 2, "change + add: " .. vim.inspect(h))
  assert_eq(h[1].kind == "change" and h[1].start == 2 and h[1].count == 1, true, "line 2 changed")
  assert_eq(h[2].kind == "add" and h[2].start == 4 and h[2].count == 1, true, "line 4 added")
  h = providers.line_hunks({ "a", "b", "c" }, { "a", "c" })
  assert_eq(#h == 1 and h[1].kind == "delete" and h[1].start == 1 and h[1].count == 0, true,
    "a deletion marks the line it follows: " .. vim.inspect(h))
  h = providers.line_hunks({ "a", "b" }, { "b" })
  assert_eq(h[1].kind == "delete" and h[1].start == 1, true, "a deletion at the top marks line 1")
  local marks = providers.hunk_marks({ { start = 3, count = 2, kind = "add" }, { start = 9, count = 0, kind = "delete" } }, 4)
  assert_eq(#marks, 3, "two added lines + one deletion mark")
  assert_eq(marks[1].current and marks[2].current and not marks[3].current, true, "the hunk under the cursor is current")

  -- Setup: a repo with a committed file, opened in a wide window.
  local saved_config = vim.deepcopy(mm_state.get_config())
  local cfg = vim.deepcopy(saved_config)
  cfg.minimap.git_debounce_ms = 20
  cfg.minimap.debounce_ms = 1
  cfg.minimap.diagnostics = { enabled = true, min_severity = "warn" }
  mm_state.set_config(cfg)
  local saved_columns = vim.o.columns
  vim.o.columns = 120
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  git({ "init", "-q" }, repo)
  git({ "config", "user.email", "diffbandit@example.test" }, repo)
  git({ "config", "user.name", "DiffBandit Test" }, repo)
  local lines = {}
  for i = 1, 200 do
    lines[i] = "line " .. i
  end
  vim.fn.writefile(lines, repo .. "/file.txt")
  vim.fn.writefile({ "other" }, repo .. "/other.txt")
  git({ "add", "." }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  providers.reset_roots()

  vim.cmd("tabnew")
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/file.txt"))
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  assert_eq(minimap_editor.eligible(win), true, "a file window is eligible")

  local mm = assert(minimap_editor.open(win))
  assert_eq(minimap_editor.get(win), mm, "one minimap per window")
  assert_eq(minimap_editor.open(win), mm, "opening again reuses it")
  local fwin = mm.win
  assert_eq(fwin ~= nil and vim.api.nvim_win_is_valid(fwin), true, "minimap float opened")
  local fcfg = vim.api.nvim_win_get_config(fwin)
  local area = placement.text_area(win)
  assert_eq(fcfg.relative ~= "" and fcfg.focusable == false, true, "an unfocusable float")
  local fpos = vim.api.nvim_win_get_position(fwin)
  assert_eq(fpos[2], area.col + area.width - 1, "float sits on the window's last text column (cells: 1 wide)")
  assert_eq(vim.api.nvim_win_get_height(fwin), area.height, "float spans the text height")
  assert_eq(#vim.api.nvim_buf_get_lines(mm.buf, 0, -1, false), area.height, "one strip line per row")
  assert_eq(#mm:state().marks, 0, "clean file: no hunks")

  -- Edits: re-diffed against the index after the debounce.
  vim.api.nvim_buf_set_lines(buf, 99, 100, false, { "changed 100" })
  vim.api.nvim_buf_set_lines(buf, 150, 150, false, { "added a", "added b" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  assert_eq(wait(function()
    return #mm:state().marks == 3
  end), true, "edits produce hunks against the index: " .. vim.inspect(mm:state().marks))
  local kinds = {}
  for _, m in ipairs(mm:state().marks) do
    kinds[m.line] = m.kind
  end
  assert_eq(kinds[100] == "change" and kinds[151] == "add" and kinds[152] == "add", true, "kinds per line")
  mm:render()
  local rows = {}
  for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(mm.buf, mm.ns, 0, -1, { details = true })) do
    if mk[4].hl_group == "DiffBanditOverviewChange" or mk[4].hl_group == "DiffBanditOverviewAdd" then
      rows[#rows + 1] = mk[2]
    end
  end
  assert_eq(#rows >= 1, true, "cell strip paints the hunks")

  -- Diagnostics: warn and up by default.
  local dns = vim.api.nvim_create_namespace("diffbandit_minimap_test")
  vim.diagnostic.set(dns, buf, {
    { lnum = 9, col = 0, severity = vim.diagnostic.severity.ERROR, message = "e" },
    { lnum = 19, col = 0, severity = vim.diagnostic.severity.HINT, message = "h" },
  })
  local diags = mm:state().diagnostics
  assert_eq(#diags == 1 and diags[1].line == 10 and diags[1].severity == 1, true,
    "errors shown, hints filtered: " .. vim.inspect(diags))
  mm:render()
  local saw_diag = false
  for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(mm.buf, mm.ns, 0, -1, { details = true })) do
    local vt = mk[4].virt_text
    saw_diag = saw_diag or (vt and vt[1][2] == "DiffBanditOverviewDiagError")
  end
  assert_eq(saw_diag, true, "diagnostic drawn on the strip")
  vim.diagnostic.reset(dns, buf)

  -- Mouse: a click on the float jumps the window; keyboard entry bounces.
  assert_eq(minimap_mouse.minimap_for(fwin), mm, "float routed to its minimap")
  minimap_mouse.on_enter(fwin, true, area.height)
  assert_eq(vim.api.nvim_win_get_cursor(win)[1] > 150, true, "click on the last row jumps near the end")
  vim.api.nvim_set_current_win(fwin)
  assert_eq(wait(function()
    return vim.api.nvim_get_current_win() == win
  end), true, "keyboard entry bounces to the window")

  -- Writing and staging refreshes the index side.
  vim.cmd("silent write")
  git({ "add", "file.txt" }, repo)
  vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
  assert_eq(wait(function()
    return #mm:state().marks == 0
  end), true, "staged edits leave no hunks")

  -- Switching buffers in the window rebinds the minimap.
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/other.txt"))
  local other = vim.api.nvim_get_current_buf()
  assert_eq(wait(function()
    return mm.editor_provider.bufnr == other
  end), true, "minimap follows the window's new buffer")
  assert_eq(mm:state().line_count, 1, "the line count comes from the new buffer")
  vim.cmd("help help")
  local help_win = vim.api.nvim_get_current_win()
  assert_eq(minimap_editor.eligible(help_win), false, "help windows are excluded")
  vim.cmd("close")

  -- Narrow windows hide the strip; it returns when the window widens.
  vim.cmd("vsplit")
  vim.cmd("vertical resize 30")
  local narrow = vim.api.nvim_get_current_win()
  vim.wait(50)
  local placed = mm.placement.ensure(mm, 1)
  assert_eq(placed ~= nil, true, "the original window is still wide enough")
  local nmm = minimap_editor.open(narrow)
  assert_eq(nmm ~= nil and (nmm.placement.ensure(nmm, 1)) == nil, true, "a narrow window hides its strip")
  vim.cmd("close")
  assert_eq(wait(function()
    return minimap_editor.get(narrow) == nil
  end), true, "closing a window closes its minimap")

  -- Toggle closes; the float goes away.
  minimap_editor.toggle(win)
  assert_eq(minimap_editor.get(win), nil, "toggle closes")
  assert_eq(vim.api.nvim_win_is_valid(fwin), false, "float closed")
  assert_eq(minimap_mouse.minimap_for(fwin), nil, "mouse routing dropped")
  vim.cmd("tabclose")

  -- DiffBandit's own tabs keep their overview gutters, never a minimap.
  local session = assert(require("diffbandit").buffers(vim.api.nvim_create_buf(true, false), vim.api.nvim_create_buf(true, false)))
  assert_eq(minimap_editor.eligible(session.right_win), false, "diff windows are not eligible")
  session:close()

  -- Image renderer: the code shape, 12 cells wide.
  local detect = require("diffbandit.kitty.detect")
  detect._reset()
  detect._set_sink(function() end)
  local kcfg = vim.deepcopy(cfg)
  kcfg.ui.connector_renderer = "kitty"
  kcfg.ui.kitty.cell_px = { 10, 20 }
  mm_state.set_config(kcfg)
  vim.cmd("tabnew")
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/file.txt"))
  local kwin = vim.api.nvim_get_current_win()
  local kmm = assert(minimap_editor.open(kwin))
  assert_eq(kmm:renderer(), "kitty", "editor minimap follows the image renderer")
  assert_eq(vim.api.nvim_win_get_width(kmm.win), 12, "code-shape width")
  local st = kmm:image_state()
  assert_eq(st ~= nil and st.transmits >= 1, true, "image transmitted")
  assert_eq(kmm.code_cache ~= nil and #kmm.code_cache.runs, 202, "code shape built from the saved buffer (two lines added above)")
  local built = kmm.code_cache
  vim.bo[vim.api.nvim_win_get_buf(kwin)].filetype = "lua"
  kmm:render()
  assert_eq(kmm.code_cache ~= built and kmm.code_cache.ft == "lua", true,
    "a filetype set after the first build rebuilds the code shape at once")
  local first = vim.api.nvim_buf_get_lines(kmm.buf, 0, 1, false)[1]
  assert_eq(first, require("diffbandit.kitty.protocol").placeholder_run(0, 0, 12), "placeholders fill the float")
  local id = st.id
  local deleted = false
  detect._set_sink(function(data)
    deleted = deleted or data == require("diffbandit.kitty.protocol").delete(id)
  end)
  vim.cmd("tabclose")
  assert_eq(wait(function()
    return deleted
  end), true, "closing the window deletes the minimap image")
  detect._set_sink(nil)
  detect._reset()

  mm_state.set_config(saved_config)
  vim.o.columns = saved_columns
end
