-- Test Suite 16: Snap-to-cursor line mapping and viewport alignment

-- Suite 16a: counterpart_row maps aligned rows across the compact buffers
do
  local function build_view(left, right)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert(hunks, err)
    return view.build(left, right, hunks, config)
  end

  -- Add hunk: context rows map exactly, added rows anchor to the line above.
  local v = build_view({ "a", "b", "c", "d" }, { "a", "b", "X", "c", "d" })
  local row, exact = view.counterpart_row(v.line_meta, "left", 4)
  assert_eq(row, 5, "Trailing context after an add should map left 4 to right 5")
  assert_eq(exact, true, "Context rows should map exactly")
  row, exact = view.counterpart_row(v.line_meta, "right", 5)
  assert_eq(row, 4, "Trailing context should map right 5 back to left 4")
  assert_eq(exact, true, "Context rows should map exactly in both directions")
  row, exact = view.counterpart_row(v.line_meta, "right", 3)
  assert_eq(row, 2, "An added row should anchor to the nearest left row above")
  assert_eq(exact, false, "Filler-facing rows should report a non-exact mapping")

  -- Delete hunk: every deleted row anchors to the context line above it.
  v = build_view({ "a", "b", "c", "d" }, { "a", "d" })
  assert_eq((view.counterpart_row(v.line_meta, "left", 2)), 1,
    "First deleted row should anchor to the context row above")
  assert_eq((view.counterpart_row(v.line_meta, "left", 3)), 1,
    "Whole delete blocks should anchor to one target row")

  -- Uneven change: no words match between x/y/z and q, so rows pair
  -- positionally (IntelliJ-style): q pairs with x, and the surplus left
  -- rows y/z face filler and anchor to the paired row above.
  v = build_view({ "a", "x", "y", "z", "b" }, { "a", "q", "b" })
  row, exact = view.counterpart_row(v.line_meta, "left", 2)
  assert_eq(row, 2, "The paired change row should map to its counterpart")
  assert_eq(exact, true, "Paired change rows should map exactly")
  assert_eq((view.counterpart_row(v.line_meta, "left", 3)), 2,
    "Left surplus change rows should anchor to the nearest right row above")
  assert_eq((view.counterpart_row(v.line_meta, "left", 4)), 2,
    "All surplus rows in one block should share the same anchor")

  -- Add at the very top of the file: no row above, fall back to nearest below.
  v = build_view({ "m" }, { "X", "m" })
  row, exact = view.counterpart_row(v.line_meta, "right", 1)
  assert_eq(row, 1, "A top-of-file add should fall back to the nearest row below")
  assert_eq(exact, false, "The top-of-file fallback should report non-exact")

  -- Degenerate and out-of-range input never errors.
  assert_eq((view.counterpart_row({}, "left", 3)), 3,
    "Empty aligned views should return the input row unchanged")
  local far = (view.counterpart_row(v.line_meta, "right", 999))
  assert_eq(far >= 1, true, "Out-of-range rows should clamp to a valid target row")
end

-- Suite 16b: Session snap_to_cursor aligns the opposite pane to the cursor's
-- screen offset without moving the focused pane.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local left_lines = {}
  for i = 1, 60 do
    left_lines[i] = "line " .. i
  end
  local right_lines = {}
  for i = 1, 10 do
    right_lines[i] = "line " .. i
  end
  for i = 1, 5 do
    right_lines[10 + i] = "inserted " .. i
  end
  for i = 11, 60 do
    right_lines[i + 5] = "line " .. i
  end

  local session = assert((Session.start({
    left = source_mod.from_lines(left_lines, nil, "left"),
    right = source_mod.from_lines(right_lines, nil, "right"),
  }, config, {})))

  assert_eq(type(buffer_keymap_callback(session.left_buf, "n", config.navigation.snap_key)), "function",
    "Session should map the snap key on the left buffer")
  assert_eq(type(buffer_keymap_callback(session.connector_buf, "n", config.navigation.snap_key)), "function",
    "Session should map the snap key on the connector buffer")

  -- Left cursor on line 40 with topline 30 (screen offset 10); right pane at top.
  vim.api.nvim_set_current_win(session.left_win)
  vim.api.nvim_win_set_cursor(session.left_win, { 30, 0 })
  vim.api.nvim_win_call(session.left_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_win_set_cursor(session.left_win, { 40, 3 })
  assert_eq(win_topline(session.left_win), 30, "Test setup should leave the left topline at 30")

  session:snap_to_cursor()

  assert_eq(vim.api.nvim_win_get_cursor(session.right_win)[1], 45,
    "Snap should move the right cursor to the row facing the left cursor")
  assert_eq(win_topline(session.right_win), 35,
    "Snap should preserve the cursor's screen offset in the right pane")
  assert_eq(win_topline(session.left_win), 30,
    "Snap should not scroll the focused pane")
  assert_eq(vim.api.nvim_win_get_cursor(session.left_win)[1], 40,
    "Snap should not move the focused pane's cursor row")
  assert_eq(vim.api.nvim_win_get_cursor(session.left_win)[2], 3,
    "Snap should not move the focused pane's cursor column")
  assert_eq(win_topline(session.right_num_win), 35,
    "Snap should carry the right number gutter along")

  -- Snapping from the right pane maps back through the same alignment.
  vim.api.nvim_set_current_win(session.right_win)
  session:snap_to_cursor()
  assert_eq(vim.api.nvim_win_get_cursor(session.left_win)[1], 40,
    "Snap from the right pane should map the cursor back to the left row")

  session:close()
end

-- Suite 16c: Merge snap_to_cursor aligns both other panes, pivoting
-- local<->remote through the shared result pane.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local base = {}
  for i = 1, 80 do
    base[i] = "line " .. i
  end
  local local_lines = {}
  for i = 1, 20 do
    local_lines[i] = "line " .. i
  end
  for i = 1, 3 do
    local_lines[20 + i] = "local extra " .. i
  end
  for i = 21, 80 do
    local_lines[i + 3] = "line " .. i
  end
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local merge_session = assert((merge_mod.start({
    root = repo,
    path = "merge-snap.txt",
    base_lines = base,
    local_lines = local_lines,
    remote_lines = base,
    result_lines = base,
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))

  assert_eq(type(buffer_keymap_callback(merge_session.result_buf, "n", config.merge.keys.snap)), "function",
    "Merge should map the snap key on the result buffer")

  -- Result cursor on line 50 with topline 40 (screen offset 10).
  vim.api.nvim_set_current_win(merge_session.result_win)
  vim.api.nvim_win_set_cursor(merge_session.result_win, { 40, 0 })
  vim.api.nvim_win_call(merge_session.result_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_win_set_cursor(merge_session.result_win, { 50, 4 })
  assert_eq(win_topline(merge_session.result_win), 40, "Test setup should leave the result topline at 40")

  merge_session:snap_to_cursor()

  assert_eq(vim.api.nvim_win_get_cursor(merge_session.result_win)[1], 50,
    "Snap should not move the focused result pane's cursor row")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.result_win)[2], 4,
    "Snap should not move the focused result pane's cursor column")

  assert_eq(vim.api.nvim_win_get_cursor(merge_session.local_win)[1], 53,
    "Snap should offset the local cursor past the local-only insertion")
  assert_eq(win_topline(merge_session.local_win), 43,
    "Snap should preserve the screen offset in the local pane")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.remote_win)[1], 50,
    "Snap should mirror the result row into the identical remote pane")
  assert_eq(win_topline(merge_session.remote_win), 40,
    "Snap should preserve the screen offset in the remote pane")
  assert_eq(win_topline(merge_session.result_win), 40,
    "Snap should not scroll the focused result pane")
  assert_eq(win_topline(merge_session.local_num_win), 43,
    "Snap should carry the local number gutter along")

  -- Snapping from the local pane pivots through result to reach remote.
  vim.api.nvim_set_current_win(merge_session.local_win)
  vim.api.nvim_win_set_cursor(merge_session.local_win, { 60, 2 })
  merge_session:snap_to_cursor()
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.result_win)[1], 57,
    "Snap from local should map the cursor back through the insertion offset")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.remote_win)[1], 57,
    "Snap from local should pivot through result to position remote")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.local_win)[1], 60,
    "Snap from local should not move the focused pane's cursor row")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.local_win)[2], 2,
    "Snap from local should not move the focused pane's cursor column")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()
end

-- Merge visibility toggles: the commit panel and the local/remote panes can
-- each be hidden and re-shown; show_all restores everything. Buffers, pair
-- models, and navigation survive while windows are closed.
do
  assert_eq(config.merge.keys.toggle_panel, "gzp", "Merge panel toggle should default to gzp")
  assert_eq(config.merge.keys.toggle_local, "gzh", "Merge local-pane toggle should default to gzh")
  assert_eq(config.merge.keys.toggle_remote, "gzl", "Merge remote-pane toggle should default to gzl")
  assert_eq(config.merge.keys.show_all, "gza", "Merge show-all should default to gza")

  local original_columns = vim.o.columns
  vim.o.columns = 220
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local merge_session = assert((merge_mod.start({
    root = repo,
    path = "merge-toggles.txt",
    base_lines = { "one", "two", "three" },
    local_lines = { "one", "TWO", "three" },
    remote_lines = { "one", "two", "THREE" },
    result_lines = { "one", "two", "three" },
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {
    panel = true,
    queue = { entries = {} },
  })))

  local function win_valid(win)
    return win ~= nil and vim.api.nvim_win_is_valid(win)
  end
  local function win_col(win)
    return vim.api.nvim_win_get_position(win)[2]
  end

  -- Panel toggle: closes only the two panel windows and returns their width
  -- to the content panes; toggling back reopens a full-height left column.
  assert_eq(panel_mod.is_open(merge_session), true, "Merge should start with the commit panel open")
  local result_width_with_panel = vim.api.nvim_win_get_width(merge_session.result_win)
  local startup_nav_row = vim.api.nvim_win_get_position(merge_session.panel.nav_win)[1]
  local startup_nav_height = vim.api.nvim_win_get_height(merge_session.panel.nav_win)
  local startup_commit_height = vim.api.nvim_win_get_height(merge_session.panel.commit_win)
  merge_session:toggle_panel_visibility()
  assert_eq(panel_mod.is_open(merge_session), false, "Panel toggle should close the panel windows")
  assert_eq(merge_session.hidden.panel, true, "Panel toggle should record the hidden state")
  assert_eq(win_valid(merge_session.local_win) and win_valid(merge_session.result_win) and win_valid(merge_session.remote_win),
    true, "Hiding the panel should keep all three content panes")
  assert_eq(vim.api.nvim_win_get_width(merge_session.result_win) > result_width_with_panel, true,
    "Hiding the panel should widen the content panes")
  merge_session:toggle_panel_visibility()
  assert_eq(panel_mod.is_open(merge_session), true, "Panel toggle should reopen the panel windows")
  assert_eq(merge_session.hidden.panel, false, "Reopening the panel should clear the hidden state")
  assert_eq(win_col(merge_session.panel.nav_win), 0, "Reopened panel should be the leftmost column")
  assert_eq(vim.api.nvim_win_get_position(merge_session.panel.nav_win)[1], startup_nav_row,
    "Reopened panel nav should start at the same row as at startup (above the header row)")
  assert_eq(vim.api.nvim_win_get_height(merge_session.panel.nav_win), startup_nav_height,
    "Reopened panel nav should restore its startup height")
  assert_eq(vim.api.nvim_win_get_height(merge_session.panel.commit_win), startup_commit_height,
    "Reopened panel commit window should restore its startup height")

  -- Local pane toggle: the pane and its gutters close, the pair model and
  -- buffer survive, and re-showing restores the column order.
  local local_buf = merge_session.local_buf
  merge_session:toggle_pane("local")
  assert_eq(merge_session.hidden.local_pane, true, "Local toggle should record the hidden state")
  assert_eq(merge_session.local_win, nil, "Hiding local should drop the pane window")
  assert_eq(merge_session.local_num_win, nil, "Hiding local should drop its number gutter")
  assert_eq(merge_session.local_result_connector_win, nil, "Hiding local should drop its connector")
  assert_eq(merge_session.result_left_num_win, nil, "Hiding local should drop the result-left number gutter")
  assert_eq(merge_session.local_result_session, nil, "Hiding local should drop its renderer session")
  assert_eq(merge_session.local_result_pair ~= nil, true, "Hiding local should keep the diff pair model")
  assert_eq(vim.api.nvim_buf_is_valid(local_buf), true, "Hiding local should keep the local buffer alive")
  merge_session:toggle_pane("local")
  assert_eq(merge_session.hidden.local_pane, false, "Local toggle should re-show the pane")
  assert_eq(win_valid(merge_session.local_win), true, "Re-shown local pane should have a window")
  assert_eq(merge_session.local_result_session ~= nil, true, "Re-shown local pane should rebuild its renderer")
  assert_eq(win_col(merge_session.local_win) < win_col(merge_session.local_num_win)
      and win_col(merge_session.local_num_win) < win_col(merge_session.local_result_connector_win)
      and win_col(merge_session.local_result_connector_win) < win_col(merge_session.result_left_num_win)
      and win_col(merge_session.result_left_num_win) < win_col(merge_session.result_win),
    true, "Re-shown local group should restore the left-to-right column order")

  -- Hiding a focused pane must bounce focus to the result pane.
  vim.api.nvim_set_current_win(merge_session.local_win)
  merge_session:toggle_pane("local")
  assert_eq(vim.api.nvim_get_current_win(), merge_session.result_win,
    "Hiding the focused pane should move focus to the result pane")

  -- Remote toggle plus everything hidden: result keeps working alone.
  merge_session:toggle_pane("remote")
  merge_session:toggle_panel_visibility()
  assert_eq(merge_session.hidden.remote_pane, true, "Remote toggle should record the hidden state")
  assert_eq(merge_session.remote_win, nil, "Hiding remote should drop the pane window")
  assert_eq(merge_session.result_remote_session, nil, "Hiding remote should drop its renderer session")
  assert_eq(win_valid(merge_session.result_win), true, "Result pane must survive all toggles")
  merge_session:render({ force_pair_rebuild = true })
  assert_eq(win_valid(merge_session.result_win), true, "Render with everything hidden should keep the result pane")

  -- show_all restores the panel and both panes in one step, idempotently.
  merge_session:show_all()
  assert_eq(panel_mod.is_open(merge_session), true, "show_all should reopen the commit panel")
  assert_eq(merge_session.hidden.local_pane, false, "show_all should re-show the local pane")
  assert_eq(merge_session.hidden.remote_pane, false, "show_all should re-show the remote pane")
  for _, win in ipairs({
    merge_session.panel.nav_win,
    merge_session.local_win,
    merge_session.local_num_win,
    merge_session.local_result_connector_win,
    merge_session.result_left_num_win,
    merge_session.result_win,
    merge_session.result_right_num_win,
    merge_session.result_remote_connector_win,
    merge_session.remote_num_win,
    merge_session.remote_win,
  }) do
    assert_eq(win_valid(win), true, "show_all should leave every window valid")
  end
  local restored_order = {
    merge_session.panel.nav_win,
    merge_session.local_win,
    merge_session.local_num_win,
    merge_session.local_result_connector_win,
    merge_session.result_left_num_win,
    merge_session.result_win,
    merge_session.result_right_num_win,
    merge_session.result_remote_connector_win,
    merge_session.remote_num_win,
    merge_session.remote_win,
  }
  for index = 2, #restored_order do
    assert_eq(win_col(restored_order[index - 1]) < win_col(restored_order[index]), true,
      "show_all should restore the full left-to-right column order")
  end
  local window_count = #vim.api.nvim_tabpage_list_wins(merge_session.tabpage)
  merge_session:show_all()
  assert_eq(#vim.api.nvim_tabpage_list_wins(merge_session.tabpage), window_count,
    "show_all with nothing hidden should be a no-op")

  -- Navigation and accept still work against the pair models while hidden.
  merge_session:toggle_pane("local")
  vim.api.nvim_set_current_win(merge_session.result_win)
  merge_session:goto_next_chunk()
  merge_session:accept("local")
  assert_eq(vim.api.nvim_buf_get_lines(merge_session.result_buf, 0, -1, false)[2], "TWO",
    "Accept local should edit the result while the local pane is hidden")
  merge_session:show_pane("local")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()
  vim.o.columns = original_columns
end

-- Suite 16d: viewport repaints reuse number/connector buffer text (document
-- model); only content/metrics changes rewrite those buffers.
do
  local left_lines, right_lines = {}, {}
  for i = 1, 40 do
    left_lines[i] = "L" .. i
    right_lines[i] = (i == 10 or i == 20) and ("R" .. i .. " changed") or ("L" .. i)
  end
  local session = assert((Session.start({
    left = source_mod.from_lines(left_lines, nil, "left"),
    right = source_mod.from_lines(right_lines, nil, "right"),
  }, config)))
  assert(session.structural_buffer_key, "first render should set a structural buffer key")

  local num_tick = vim.api.nvim_buf_get_changedtick(session.left_num_buf)
  local conn_tick = vim.api.nvim_buf_get_changedtick(session.connector_buf)
  local struct_key = session.structural_buffer_key

  session:set_viewport_toplines(5, 5)
  assert_eq(session.structural_buffer_key, struct_key,
    "scroll should keep the same structural buffer key")
  assert_eq(vim.api.nvim_buf_get_changedtick(session.left_num_buf), num_tick,
    "scroll should not rewrite left number buffer text")
  assert_eq(vim.api.nvim_buf_get_changedtick(session.connector_buf), conn_tick,
    "scroll should not rewrite connector buffer text")

  session:invalidate_render_caches()
  session:render()
  assert_eq(vim.api.nvim_buf_get_changedtick(session.left_num_buf) > num_tick, true,
    "invalidate + render should rewrite number buffer text")
  assert_eq(vim.api.nvim_buf_get_changedtick(session.connector_buf) > conn_tick, true,
    "invalidate + render should rewrite connector buffer text")

  session:close()
end

