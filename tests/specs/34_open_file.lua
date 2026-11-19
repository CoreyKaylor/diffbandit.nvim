-- navigation.open_file_key (gf): open the diffed file in a tab of its own.

-- map_line carries a line across hunks from the shown text to the file.
do
  local open_file = require("diffbandit.session.open_file")
  local function ml(h, line)
    local mapped, exact = open_file.map_line(h, line)
    return mapped .. "," .. tostring(exact)
  end
  local function hunks(left, right)
    return (diff.compute_hunks(to_text(left), to_text(right), config.diff))
  end
  -- Two lines inserted at the top shift everything below them.
  local h = hunks({ "a", "b", "c" }, { "x", "y", "a", "b", "c" })
  assert_eq(ml(h, 1), "3,true", "lines below an insertion shift down")
  assert_eq(ml(h, 3), "5,true", "every later line shifts the same")
  -- A deleted line lands on the line that follows it.
  h = hunks({ "a", "b", "c", "d" }, { "a", "d" })
  assert_eq(ml(h, 2), "2,false", "a deleted line lands on the next line")
  assert_eq(ml(h, 4), "2,true", "lines below a deletion shift up")
  -- A changed line lands at the same offset into its replacement.
  h = hunks({ "a", "b", "c", "z" }, { "a", "B", "z" })
  assert_eq(ml(h, 3), "2,false", "a changed line clamps into its replacement")
  assert_eq(ml(h, 4), "3,true", "lines below a shrinking change shift up")
  assert_eq(ml({}, 7), "7,true", "no hunks keeps the line")
end

do
  local diffbandit = require("diffbandit")
  local open_file = require("diffbandit.session.open_file")
  local open_key = config.navigation.open_file_key
  assert_eq(open_key, "gf", "the open-file key defaults to gf")

  local repo = make_git_repo()
  local base = {}
  for i = 1, 20 do
    base[i] = "line " .. i
  end
  write_repo_file(repo, "a.txt", base)
  write_repo_file(repo, "gone.txt", { "bye" })
  commit_baseline(repo)

  local saved_number = vim.o.number
  vim.o.number = true
  local function opened()
    return {
      name = vim.api.nvim_buf_get_name(0),
      line = vim.api.nvim_win_get_cursor(0)[1],
      col = vim.api.nvim_win_get_cursor(0)[2],
    }
  end
  local real = vim.uv.fs_realpath(repo .. "/a.txt")

  -- Working tree: a line inserted at the top, one changed further down.
  local work = vim.deepcopy(base)
  table.insert(work, 1, "new top")
  work[11] = "changed 10"
  write_repo_file(repo, "a.txt", work)
  os.remove(repo .. "/gone.txt")

  local session = assert(diffbandit.git({ root = repo }))
  local diff_tab = vim.api.nvim_get_current_tabpage()
  while session.right.git_relpath ~= "a.txt" do
    assert(session:goto_next_file() ~= false, "the review reaches a.txt")
  end
  assert(buffer_keymap_callback(session.right_buf, "n", open_key), "gf is mapped in the right pane")
  assert(buffer_keymap_callback(session.left_buf, "n", open_key), "gf is mapped in the left pane")

  -- Right pane: the working tree, so the cursor line opens as is.
  vim.api.nvim_set_current_win(session.right_win)
  vim.api.nvim_win_set_cursor(session.right_win, { 15, 3 })
  assert_eq(session:open_file(), true, "gf opens the file from the right pane")
  local tab = vim.api.nvim_get_current_tabpage()
  assert_ne(tab, diff_tab, "the file opens in a new tab")
  local got = opened()
  assert_eq(vim.uv.fs_realpath(got.name), real, "the working-tree file opens")
  assert_eq(got.line .. ":" .. got.col, "15:3", "the cursor line and column carry over")
  assert_eq(vim.wo.winhighlight:find("DiffBandit", 1, true), nil, "the pane's highlights stay behind")
  assert_eq(vim.wo.number, true, "the user's number setting comes back")
  local opened_buf = vim.api.nvim_get_current_buf()
  vim.cmd("tabclose")

  -- Left pane: the HEAD line maps to its working-tree counterpart.
  vim.api.nvim_set_current_tabpage(diff_tab)
  vim.api.nvim_set_current_win(session.left_win)
  vim.api.nvim_win_set_cursor(session.left_win, { 5, 0 })
  assert_eq(session:open_file(), true, "gf opens the file from the left pane")
  assert_eq(opened().line, 6, "a HEAD line opens at its working-tree line")
  vim.cmd("tabclose")

  -- The pane's buffer belongs to the user once opened: closing the diff
  -- keeps it.
  vim.api.nvim_set_current_tabpage(diff_tab)
  session:close()
  assert_eq(vim.api.nvim_buf_is_valid(opened_buf), true, "closing the diff keeps the opened buffer")
  vim.cmd("bwipeout! " .. opened_buf)

  -- A deleted file has nothing in the working tree to open.
  session = assert(diffbandit.git({ root = repo }))
  while session.right.git_relpath ~= "gone.txt" do
    assert(session:goto_next_file() ~= false, "the review reaches gone.txt")
  end
  local tabs = #vim.api.nvim_list_tabpages()
  local target, err = open_file.resolve(session, "right", 1)
  assert_eq(target, nil, "a deleted file does not resolve")
  assert_eq(err, "gone.txt is not in the working tree", "the reason names the file")
  vim.api.nvim_set_current_win(session.right_win)
  assert_eq(session:open_file(), false, "gf on a deleted file opens nothing")
  assert_eq(#vim.api.nvim_list_tabpages(), tabs, "no tab opens for a deleted file")
  session:close()

  -- A commit review: the commit's lines carry to the working tree, which has
  -- moved on since (two more lines at the top).
  vim.fn.writefile(work, repo .. "/a.txt")
  git_test_command({ "add", "a.txt" }, repo)
  git_test_command({ "commit", "-q", "-m", "second" }, repo)
  local later = vim.deepcopy(work)
  table.insert(later, 1, "newer 2")
  table.insert(later, 1, "newer 1")
  vim.fn.writefile(later, repo .. "/a.txt")

  local review = assert((diffbandit.git_commit("HEAD", { root = repo })))
  while review.right.git_relpath ~= "a.txt" do
    assert(review:goto_next_file() ~= false, "the commit review reaches a.txt")
  end
  vim.api.nvim_set_current_win(review.right_win)
  vim.api.nvim_win_set_cursor(review.right_win, { 5, 2 })
  assert_eq(review:open_file(), true, "gf opens the file from a commit review")
  got = opened()
  assert_eq(vim.uv.fs_realpath(got.name), real, "a commit review opens the working-tree file")
  assert_eq(got.line .. ":" .. got.col, "7:2", "the commit's line carries to the working tree")
  vim.cmd("tabclose")

  -- From the commit panel: the first hunk, then the hunk ]c moved to.
  vim.api.nvim_set_current_tabpage(review.tabpage)
  local panel = review.panel
  assert(panel and panel.nav_win, "the commit review has a panel")
  assert(buffer_keymap_callback(panel.nav_buf, "n", open_key), "gf is mapped in the file list")
  for row, model in ipairs(panel.rows) do
    if model.type == "file" and model.entry.path == "a.txt" then
      vim.api.nvim_win_set_cursor(panel.nav_win, { row, 0 })
    end
  end
  vim.api.nvim_set_current_win(panel.nav_win)
  review.current_chunk = 0
  assert_eq(panel_mod.open_file(review), true, "gf in the panel opens the selected file")
  -- Hunk 1 of HEAD~..HEAD is "new top": commit line 1, working-tree line 3.
  assert_eq(opened().line, 3, "the panel opens at the first hunk")
  vim.cmd("tabclose")

  vim.api.nvim_set_current_tabpage(review.tabpage)
  vim.api.nvim_set_current_win(panel.nav_win)
  review:goto_chunk(2)
  vim.api.nvim_set_current_win(panel.nav_win)
  assert_eq(panel_mod.open_file(review), true, "gf in the panel opens the active hunk")
  -- Hunk 2 is "changed 10": commit line 11, working-tree line 13.
  assert_eq(opened().line, 13, "the panel opens at the hunk ]c moved to")
  vim.cmd("tabclose")

  vim.api.nvim_set_current_tabpage(review.tabpage)
  review:close()
  vim.o.number = saved_number
  vim.fn.delete(repo, "rf")
end
