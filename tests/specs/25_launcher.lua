-- Suite: standalone launcher (bin/diffbandit) argument parsing and views

do
  local launcher = require("diffbandit.launcher")
  local known_revs = { HEAD = true, main = true, ["v1.0"] = true }
  local function is_rev(arg)
    return known_revs[arg] == true
  end
  local function parse(args)
    return launcher.parse(args, is_rev)
  end

  local plan = assert(parse({}))
  assert_eq(plan.kind, "status", "No args opens working-tree status")
  assert_eq(plan.opts.mode, nil, "No args keeps the configured default mode")
  assert_eq(#plan.opts.pathspecs, 0, "No args has no pathspecs")

  plan = assert(parse({ "--cached" }))
  assert_eq(plan.opts.mode, "staged", "--cached selects staged mode")
  plan = assert(parse({ "--staged", "--no-untracked" }))
  assert_eq(plan.opts.mode, "staged", "--staged is an alias of --cached")
  assert_eq(plan.opts.include_untracked, false, "--no-untracked is forwarded")

  plan = assert(parse({ "main" }))
  assert_eq(plan.kind, "status", "One revision compares against the working tree")
  assert_eq(plan.opts.mode, "all", "One revision uses all mode")
  assert_eq(plan.opts.base, "main", "One revision becomes the base")

  plan = assert(parse({ "main", "HEAD" }))
  assert_eq(plan.kind, "compare", "Two revisions open a review")
  assert_eq(plan.base, "main", "Two revisions: base")
  assert_eq(plan.target, "HEAD", "Two revisions: target")
  assert_eq(plan.opts.direct, true, "Two revisions compare directly")

  plan = assert(parse({ "main..v1.0" }))
  assert_eq(plan.kind, "compare", "A..B opens a review")
  assert_eq(plan.base, "main", "A..B base")
  assert_eq(plan.target, "v1.0", "A..B target")
  assert_eq(plan.opts.direct, true, "A..B compares directly")

  plan = assert(parse({ "main...v1.0" }))
  assert_eq(plan.base, "main", "A...B base is not mangled by the third dot")
  assert_eq(plan.target, "v1.0", "A...B target is not mangled by the third dot")
  assert_eq(plan.opts.direct, false, "A...B uses the merge base")

  plan = assert(parse({ "main..." }))
  assert_eq(plan.target, "HEAD", "Empty range side defaults to HEAD")

  plan = assert(parse({ "main", "src/a.lua", "docs" }))
  assert_eq(plan.opts.base, "main", "Revision before paths")
  assert_eq(table.concat(plan.opts.pathspecs, ","), "src/a.lua,docs", "Non-revisions become pathspecs")

  plan = assert(parse({ "--", "main" }))
  assert_eq(plan.opts.mode, nil, "Args after -- are never revisions")
  assert_eq(plan.opts.pathspecs[1], "main", "Args after -- are pathspecs")

  plan = assert(parse({ "show", "HEAD", "--", "lua" }))
  assert_eq(plan.kind, "commit", "show opens a commit review")
  assert_eq(plan.rev, "HEAD", "show revision")
  assert_eq(plan.opts.pathspecs[1], "lua", "show forwards pathspecs")

  plan = assert(parse({ "../other/file.lua" }))
  assert_eq(plan.kind, "status", "A path containing .. is not a range")
  assert_eq(plan.opts.pathspecs[1], "../other/file.lua", "A path containing .. stays a pathspec")

  assert_eq(parse({ "show" }), nil, "show without a revision is rejected")
  assert_eq(parse({ "--cached", "main" }), nil, "--cached with a revision is rejected")
  assert_eq(parse({ "main", "HEAD..v1.0" }), nil, "Range plus revision is rejected")
  assert_eq(parse({ "--bogus" }), nil, "Unknown options are rejected")
end

do
  local launcher = require("diffbandit.launcher")
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "one", "two" })
  write_repo_file(repo, "sub/b.txt", { "alpha" })
  commit_baseline(repo)
  write_repo_file(repo, "a.txt", { "one", "TWO" })
  write_repo_file(repo, "sub/b.txt", { "ALPHA" })

  assert_eq(launcher.has_live_view(), false, "No live view before launching")

  local session = assert((launcher.launch({}, { cwd = repo })))
  assert_eq(session.panel ~= nil, true, "Status launch opens the commit panel")
  assert_eq(#session.file_queue.entries, 2, "Status launch lists every changed file")
  assert_eq(session.file_queue_index, 1, "Status launch opens the first file")
  assert_eq(launcher.has_live_view(), true, "Launched session is a live view")
  session:close()
  assert_eq(launcher.has_live_view(), false, "Closing the session leaves no live view")

  -- Launcher mode: the panel's q quits nvim; otherwise it closes the view.
  do
    local state = require("diffbandit.state")
    local panel_q = function(launched)
      local callback = buffer_keymap_callback(launched.panel.nav_buf, "n", "q")
      assert_eq(type(callback), "function", "Panel nav buffer maps q")
      local commands = {}
      local real_cmd = vim.cmd
      vim.cmd = function(command)
        commands[#commands + 1] = command
      end
      local ok, err = pcall(callback)
      vim.cmd = real_cmd
      assert(ok, err)
      return commands
    end

    local launched = assert((launcher.launch({}, { cwd = repo })))
    local commands = panel_q(launched)
    assert_eq(commands[1], "tabclose", "Without launcher mode, panel q closes the view's tab")
    assert_eq(vim.tbl_contains(commands, "confirm qall"), false, "Without launcher mode, panel q does not quit")
    launched:close()

    launched = assert((launcher.launch({}, { cwd = repo })))
    state.quit_on_close = true
    commands = panel_q(launched)
    state.quit_on_close = false
    assert_eq(commands[1], "confirm qall", "In launcher mode, panel q quits nvim")
    assert_eq(launched.panel.visible, true, "In launcher mode, panel q leaves the panel alone")
    launched:close()
  end

  session = assert((launcher.launch({}, { cwd = repo .. "/sub" })))
  assert_eq(#session.file_queue.entries, 2, "No args from a subdirectory still lists the whole repo")
  session:close()

  session = assert((launcher.launch({ "../a.txt" }, { cwd = repo .. "/sub" })))
  assert_eq(session.file_queue.entries[1].path, "a.txt", "A ../ pathspec resolves from the launch cwd")
  assert_eq(#session.file_queue.entries, 1, "A ../ pathspec limits the queue")
  session:close()

  session = assert((launcher.launch({ "b.txt" }, { cwd = repo .. "/sub" })))
  assert_eq(#session.file_queue.entries, 1, "Pathspecs are rebased from the launch cwd")
  assert_eq(session.file_queue.entries[1].path, "sub/b.txt", "Rebased pathspec keeps the repo-relative path")
  session:close()

  git_test_command({ "commit", "-am", "second" }, repo)
  session = assert((launcher.launch({ "HEAD~1..HEAD" }, { cwd = repo })))
  local review = session.file_queue.opts.review
  assert_eq(review.kind, "compare", "Range launch opens a compare review")
  assert_eq(session.file_queue.opts.read_only, true, "Range review is read-only")
  session:close()

  session = assert((launcher.launch({ "HEAD~1...HEAD" }, { cwd = repo })))
  assert_eq(#session.file_queue.entries, 2, "Merge-base range resolves and lists the commit's files")
  session:close()

  session = assert((launcher.launch({ "show", "HEAD" }, { cwd = repo })))
  assert_eq(session.file_queue.opts.review.kind, "commit", "show launch opens a commit review")
  session:close()

  local _, err = launcher.launch({}, { cwd = repo })
  assert_eq(err, "no git changes", "Clean worktree reports no changes")
  assert_eq(launcher.has_live_view(), false, "Failed launch leaves no live view")

  local git_mod = require("diffbandit.git")
  assert_eq(git_mod.is_revision(repo, "HEAD~1"), true, "is_revision accepts commit-ish")
  assert_eq(git_mod.is_revision(repo, "a.txt"), false, "is_revision rejects paths")
  assert_eq(git_mod.is_revision(repo, "--all"), false, "is_revision rejects options")

  -- :DiffBanditGit --rev A...B resolves the merge base instead of mangling B.
  local queue = assert((git_mod.queue({ root = repo, mode = "rev", base = "HEAD~1", target = "HEAD", merge_base = true }, {})))
  assert_eq(queue.opts.base, vim.trim(git_test_command({ "rev-parse", "HEAD~1" }, repo)),
    "merge_base rev queue swaps the base for the merge base")
  assert_eq(queue.opts.merge_base, nil, "merge_base flag is consumed once resolved")
end

-- plugin/diffbandit.lua only defines commands: loading the plugin waits for
-- the first command, so it costs nothing on every other nvim start.
do
  local plugin_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
  local cmd = { vim.v.progpath, "--headless", "--clean" }
  for _, command in ipairs({
    "lua vim.opt.rtp:prepend(" .. vim.inspect(plugin_root) .. ")",
    "runtime plugin/diffbandit.lua",
    "lua io.stdout:write(package.loaded['diffbandit'] and 'eager' or 'lazy', ' ')",
    "lua io.stdout:write(vim.fn.exists(':DiffBanditGit') == 2 and 'commands' or 'missing', ' ')",
    "silent! DiffBanditClose",
    "lua io.stdout:write(package.loaded['diffbandit'] and 'loaded' or 'unloaded')",
    "qall!",
  }) do
    cmd[#cmd + 1] = "-c"
    cmd[#cmd + 1] = command
  end
  local result = vim.system(cmd, { text = true }):wait(10000)
  assert_eq(vim.trim(result.stdout or ""), "lazy commands loaded",
    "the plugin file defines commands without requiring diffbandit; the first command loads it")
end

-- Subcommands: compare, log, stash.
do
  local launcher = require("diffbandit.launcher")
  local known_revs = { HEAD = true, main = true, feature = true }
  local function parse(args)
    return launcher.parse(args, function(arg)
      return known_revs[arg] == true
    end)
  end

  local plan = assert(parse({ "compare" }))
  assert_eq(plan.kind, "compare_worktree", "compare alone compares the working tree with the default branch")
  assert_eq(plan.base, nil, "compare alone leaves the base to the default branch")
  plan = assert(parse({ "compare", "main", "--", "lua" }))
  assert_eq(plan.base, "main", "compare <base> names the base")
  assert_eq(plan.opts.pathspecs[1], "lua", "compare forwards pathspecs")
  plan = assert(parse({ "compare", "--direct", "main" }))
  assert_eq(plan.direct, true, "--direct compares with the base itself")
  plan = assert(parse({ "compare", "--unpushed" }))
  assert_eq(plan.unpushed, true, "--unpushed compares with the upstream")
  assert_eq(parse({ "compare", "--unpushed", "main" }), nil, "--unpushed takes no revision")
  plan = assert(parse({ "compare", "main", "feature" }))
  assert_eq(plan.kind, "compare", "compare <base> <target> is the read-only review")
  assert_eq(plan.opts.direct, nil, "the two-ref review uses the merge base by default")
  plan = assert(parse({ "compare", "main...feature" }))
  assert_eq(plan.kind .. " " .. plan.base .. " " .. plan.target, "compare main feature", "compare accepts a...b")
  assert_eq(plan.opts.direct, nil, "a...b is the merge-base review")
  plan = assert(parse({ "compare", "main..feature" }))
  assert_eq(plan.opts.direct, true, "a..b is the direct review")
  assert_eq(parse({ "compare", "--bogus" }), nil, "compare rejects unknown options")

  plan = assert(parse({ "log" }))
  assert_eq(plan.kind, "log", "log opens the log browser")
  plan = assert(parse({ "log", "--all", "-n", "5" }))
  assert_eq(plan.opts.all and plan.opts.max_count, 5, "log --all -n 5")
  assert_eq(assert(parse({ "log", "-n7" })).opts.max_count, 7, "-n<count> form")
  assert_eq(assert(parse({ "log", "--max-count=9" })).opts.max_count, 9, "--max-count=<count> form")
  plan = assert(parse({ "log", "main", "lua" }))
  assert_eq(plan.opts.rev .. " " .. plan.opts.pathspecs[1], "main lua", "log <rev> <path>")
  assert_eq(assert(parse({ "log", "main..feature" })).opts.rev, "main..feature", "log takes a range")
  assert_eq(parse({ "log", "-n" }), nil, "-n needs a count")
  assert_eq(parse({ "log", "--all", "main" }), nil, "log --all takes no revision")

  assert_eq(assert(parse({ "stash" })).rev, "stash@{0}", "stash reviews the latest entry")
  assert_eq(assert(parse({ "stash", "2" })).rev, "stash@{2}", "stash <n>")
  assert_eq(assert(parse({ "stash", "stash@{1}" })).rev, "stash@{1}", "stash stash@{n}")
  assert_eq(parse({ "stash", "nope" }), nil, "stash rejects other arguments")

  plan = assert(parse({ "--", "log" }))
  assert_eq(plan.kind .. " " .. plan.opts.pathspecs[1], "status log", "-- log means the path, not the subcommand")
end

do
  local launcher = require("diffbandit.launcher")
  local state = require("diffbandit.state")
  local remote = vim.fn.tempname()
  vim.fn.mkdir(remote, "p")
  git_test_command({ "init", "-q", "--bare" }, remote)
  local repo = make_git_repo()
  git_test_command({ "checkout", "-q", "-b", "main" }, repo)
  write_repo_file(repo, "shared.txt", { "base" })
  write_repo_file(repo, "pending.txt", { "one" })
  commit_baseline(repo)
  git_test_command({ "remote", "add", "origin", remote }, repo)
  git_test_command({ "push", "-q", "origin", "main" }, repo)
  git_test_command({ "remote", "set-head", "origin", "main" }, repo)
  git_test_command({ "switch", "-q", "-c", "topic" }, repo)
  write_repo_file(repo, "shared.txt", { "base", "committed on topic" })
  git_test_command({ "commit", "-q", "-am", "topic work" }, repo)
  write_repo_file(repo, "pending.txt", { "one", "pending" })
  local merge_base = vim.trim(git_test_command({ "merge-base", "origin/main", "HEAD" }, repo))

  assert_eq(require("diffbandit.git").default_branch(repo), "origin/main", "the default branch comes from origin/HEAD")
  local session = assert((launcher.launch({ "compare" }, { cwd = repo })))
  local opts = session.file_queue.opts
  assert_eq(opts.base, merge_base, "compare diffs against the merge base with origin/main")
  assert_eq(opts.base_label, "merge-base origin/main", "the base is labelled for display")
  local paths = {}
  for _, entry in ipairs(session.file_queue.entries) do
    paths[#paths + 1] = entry.path
  end
  assert_eq(table.concat(paths, ","), "pending.txt,shared.txt", "committed and pending changes both appear")
  assert_eq(session.left.label:find("merge-base origin/main", 1, true) ~= nil, true, "the left pane names the base")
  assert_eq(session.panel ~= nil, true, "compare keeps the commit panel")
  session:close()

  session = assert((launcher.launch({ "compare", "--direct", "main" }, { cwd = repo })))
  assert_eq(session.file_queue.opts.base, "main", "--direct compares with the base itself")
  session:close()
  local _, err = launcher.launch({ "compare", "--unpushed" }, { cwd = repo })
  assert_eq(err, "the current branch has no upstream", "--unpushed explains a missing upstream")
  git_test_command({ "push", "-q", "-u", "origin", "topic" }, repo)
  session = assert((launcher.launch({ "compare", "--unpushed" }, { cwd = repo })))
  assert_eq(#session.file_queue.entries, 1, "--unpushed shows only what the upstream lacks")
  session:close()

  -- log: the browser counts as a live view, so closing a review opened from
  -- it returns to the log instead of quitting the launcher.
  vim.cmd("tabnew")
  local log_tab = vim.api.nvim_get_current_tabpage()
  local browser = assert((launcher.launch({ "log", "-n", "1" }, { cwd = repo })))
  assert_eq(#browser.commits, 1, "-n limits the log")
  assert_eq(vim.api.nvim_get_current_win(), browser.win, "the launcher's log fills the current window")
  assert_eq(launcher.has_live_view(), true, "the log is a live view")
  state.quit_on_close = true
  assert_eq(launcher.should_quit_on_close(log_tab), true, "closing the only view quits")
  local review = assert((require("diffbandit").git_commit("HEAD", { root = repo })))
  assert_eq(launcher.should_quit_on_close(review.tabpage), false, "closing a review opened from the log does not quit")
  state.quit_on_close = false
  review:close()
  assert_eq(launcher.has_live_view(), true, "the log stays open after the review closes")
  browser = assert((launcher.launch({ "log" }, { cwd = repo })))
  assert_eq(#browser.commits, 2, "without -n the log lists the history (up to the default cap)")
  state.unregister_view(browser)
  vim.cmd("tabclose")

  -- stash: a read-only review of the stash entry against its parent.
  git_test_command({ "stash", "-q" }, repo)
  session = assert((launcher.launch({ "stash" }, { cwd = repo })))
  assert_eq(session.file_queue.opts.read_only, true, "a stash review is read-only")
  assert_eq(session.file_queue.entries[1].path, "pending.txt", "the stash review shows the stashed change")
  session:close()
  _, err = launcher.launch({ "stash", "3" }, { cwd = repo })
  assert_eq(err, "no stash entry stash@{3}", "a missing stash entry is reported")
end

-- External-tool subcommands: jj merge-tools / git mergetool contract.
do
  local launcher = require("diffbandit.launcher")
  local plan = assert(launcher.parse_tool({ "merge", "b", "l", "r", "o", "--path", "src/x.lua" }))
  assert_eq(plan.kind, "merge", "merge subcommand parses")
  assert_eq(table.concat({ plan.base, plan.left, plan.right, plan.output }, ","), "b,l,r,o",
    "merge takes base left right output in order")
  assert_eq(plan.path, "src/x.lua", "merge --path is the display path")
  assert_eq(launcher.parse_tool({ "status" }), nil, "Non-tool args fall through to the git parser")
  local _, err = launcher.parse_tool({ "merge", "b", "l", "r" })
  assert_eq(err ~= nil, true, "merge needs four paths")
  plan = assert(launcher.parse_tool({ "edit", "L", "R" }))
  assert_eq(plan.kind .. plan.left .. plan.right, "editLR", "edit takes two paths")
  _, err = launcher.parse_tool({ "diff", "L", "R", "--bogus" })
  assert_eq(err, "unknown option: --bogus", "Tool subcommands reject unknown options")

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "one", "base", "three" }, dir .. "/base")
  vim.fn.writefile({ "one", "left", "three" }, dir .. "/left")
  vim.fn.writefile({ "one", "right", "three" }, dir .. "/right")
  local resolved_value
  local merge_mod = require("diffbandit.merge")
  local session = assert((merge_mod.start_files({
    base = dir .. "/base",
    left = dir .. "/left",
    right = dir .. "/right",
    output = dir .. "/output",
    path = "src/x.txt",
    labels = { left = "rwoumtly", right = "nqswmmuv" },
    on_resolve = function(value)
      resolved_value = value
    end,
  }, config)))
  assert_eq(#session.conflicts, 1, "File merge finds the overlapping conflict")
  assert_eq(session.path, "src/x.txt", "File merge shows the --path display path")
  assert_eq(session.result_editable, nil, "File merge edits a scratch result, not the output file")
  assert_eq(session:build_status_lines().left:find("rwoumtly", 1, true) ~= nil, true,
    "File merge header uses the provided left label")
  vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, { "one", "merged", "three" })
  assert_eq(session:resolve(), true, "File merge resolves")
  assert_eq(table.concat(read_file(dir .. "/output"), "|"), "one|merged|three", "Resolve writes the output file")
  assert_eq(resolved_value, "one\nmerged\nthree\n", "on_resolve receives the written text")
  assert_eq(session.resolved, true, "Session records the resolution")
  session.delete_result = true
  assert_eq(session:resolve(), false, "File merge refuses to delete the result")
  session:close()

  -- Missing side (add/add or delete): an absent file is an absent side.
  session = assert((merge_mod.start_files({
    base = dir .. "/nope",
    left = dir .. "/left",
    right = dir .. "/right",
    output = dir .. "/output2",
  }, config)))
  assert_eq(session.has_local, true, "Present left side is kept")
  assert_eq(#session.base_lines, 0, "Missing base is empty")
  session:close()

  -- Diff-editor mode: the right folder is edited in place.
  local left_dir, right_dir = dir .. "/L", dir .. "/R"
  vim.fn.mkdir(left_dir .. "/sub", "p")
  vim.fn.mkdir(right_dir, "p")
  vim.fn.writefile({ "a", "b" }, left_dir .. "/same.txt")
  vim.fn.writefile({ "a", "B" }, right_dir .. "/same.txt")
  vim.fn.writefile({ "gone" }, left_dir .. "/sub/deleted.txt")
  vim.fn.writefile({ "ignore me" }, right_dir .. "/JJ-INSTRUCTIONS")
  local diffbandit = require("diffbandit")
  local folder = assert(diffbandit.folder_diff(left_dir, right_dir, {
    editable_right = true,
    hide = { "^JJ%-INSTRUCTIONS$" },
  }))
  assert_eq(folder.rows_by_rel["JJ-INSTRUCTIONS"], nil, "Hidden patterns are not listed")
  local child = assert((folder.open_file_diff(folder, folder.rows_by_rel["same.txt"], { tabpage = folder.tabpage })))
  assert_eq(child.right.editable ~= nil, true, "Editable folder diff makes the right file editable")
  vim.api.nvim_set_current_win(child.right_win)
  vim.api.nvim_buf_set_lines(child.right_buf, 0, -1, false, { "a", "b" })
  vim.cmd("write")
  assert_eq(table.concat(read_file(right_dir .. "/same.txt"), "|"), "a|b", "Writing the child edits the right folder")
  child:close()
  child = assert((folder.open_file_diff(folder, folder.rows_by_rel["sub/deleted.txt"], { tabpage = folder.tabpage })))
  vim.api.nvim_set_current_win(child.right_win)
  vim.api.nvim_buf_set_lines(child.right_buf, 0, -1, false, { "gone" })
  vim.cmd("write")
  assert_eq(read_file(right_dir .. "/sub/deleted.txt")[1], "gone", "A file missing on the right is created on write")
  child:close()
  folder:close()

  local readonly = assert(diffbandit.folder_diff(left_dir, right_dir, {}))
  child = assert((readonly.open_file_diff(readonly, readonly.rows_by_rel["same.txt"], { tabpage = readonly.tabpage })))
  assert_eq(child.right.editable, nil, "Plain folder diff stays read-only")
  child:close()
  readonly:close()
end

-- Log walk: a review opened from the log steps to the older/newer commit in
-- place, staying on the same file and keeping the log cursor in sync.
do
  local diffbandit = require("diffbandit")
  local state = require("diffbandit.state")
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "a1" })
  write_repo_file(repo, "b.txt", { "b1" })
  commit_baseline(repo)
  write_repo_file(repo, "a.txt", { "a1", "a2" })
  write_repo_file(repo, "b.txt", { "b1", "b2" })
  git_test_command({ "commit", "-q", "-am", "second" }, repo)
  git_test_command({ "commit", "-q", "--allow-empty", "-m", "empty" }, repo)
  write_repo_file(repo, "b.txt", { "b1", "b2", "b3" })
  git_test_command({ "commit", "-q", "-am", "third" }, repo)

  vim.cmd("tabnew")
  local browser = assert((diffbandit.git_log({ root = repo })))
  assert_eq(#browser.commits, 4, "the log lists every commit")
  vim.api.nvim_win_set_cursor(browser.win, { 2, 0 })
  buffer_keymap_callback(browser.buf, "n", "<CR>")()
  local review = state.sessions[vim.api.nvim_get_current_tabpage()]
  assert_eq(review.file_queue.log_walk.index, 1, "the review knows its log position")
  assert_eq(review.file_queue.entries[1].path, "b.txt", "the newest commit changes only b.txt")
  assert_eq(review.panel_details.subtitle, "Commit 1 of 4 in the log", "the panel shows the log position")
  assert_eq(type(buffer_keymap_callback(review.right_buf, "n", "]r")), "function", "the diff maps the log keys")
  assert_eq(type(buffer_keymap_callback(review.panel.nav_buf, "n", "[r")), "function", "the panel maps the log keys")

  assert_eq(diffbandit.git_log_step(review, -1), false, "there is nothing newer than the first commit")
  assert_eq(diffbandit.git_log_step(review, 1), true, "]r steps to the older commit")
  assert_eq(review.disposed, true, "the old review is replaced, not stacked")
  local older = state.sessions[vim.api.nvim_get_current_tabpage()]
  assert_eq(older.file_queue.log_walk.index, 3, "the walk steps over the empty commit")
  assert_eq(#older.file_queue.entries, 2, "the second commit changes both files")
  assert_eq(older.file_queue_index, 2, "the walk stays on b.txt")
  assert_eq(vim.api.nvim_win_get_cursor(browser.win)[1], 4, "the log cursor follows the review")

  assert_eq(diffbandit.git_log_step(older, 1), true, "]r reaches the root commit")
  local root_review = state.sessions[vim.api.nvim_get_current_tabpage()]
  assert_eq(root_review.file_queue.entries[root_review.file_queue_index].path, "b.txt", "the root commit opens on b.txt too")
  assert_eq(diffbandit.git_log_step(root_review, 1), false, "there is nothing older than the root commit")
  assert_eq(diffbandit.git_log_step(root_review, -1), true, "[r steps back to the newer commit")
  local back = state.sessions[vim.api.nvim_get_current_tabpage()]
  assert_eq(back.file_queue.log_walk.index, 3, "[r walks back up the log")
  back:close()

  -- A plain commit review has no log to walk.
  local plain = assert((diffbandit.git_commit("HEAD", { root = repo })))
  assert_eq(buffer_keymap_callback(plain.right_buf, "n", "]r"), nil, "no log keys without a log")
  plain:close()
  state.unregister_view(browser)
  vim.cmd("tabclose")
end

-- Log rows: compact ages, refs, and change counts that load after the list.
do
  local log_view = require("diffbandit.util.log_view")
  assert_eq(log_view.age(1000, 1030), "now", "under a minute is now")
  assert_eq(log_view.age(0, 47 * 60), "47m", "minutes")
  assert_eq(log_view.age(0, 3 * 3600), "3h", "hours")
  assert_eq(log_view.age(0, 4 * 86400), "4d", "days")
  assert_eq(log_view.age(0, 21 * 86400), "3w", "weeks")
  assert_eq(log_view.age(0, 90 * 86400), "3mo", "months")
  assert_eq(log_view.age(0, 800 * 86400), "2y", "years")
end

-- The detail pane follows the log cursor and opens a review on a file.
do
  local diffbandit = require("diffbandit")
  local state = require("diffbandit.state")
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "a1" })
  commit_baseline(repo)
  write_repo_file(repo, "a.txt", { "a1", "a2", "a3" })
  write_repo_file(repo, "b.txt", { "b1" })
  git_test_command({ "add", "-A" }, repo)
  git_test_command({ "commit", "-q", "-m", "grow a", "-m", "with a body line" }, repo)
  git_test_command({ "commit", "-q", "--allow-empty", "-m", "nothing" }, repo)
  git_test_command({ "update-ref", "refs/tags/v1", "HEAD" }, repo)

  vim.cmd("tabnew")
  local browser = assert((diffbandit.git_log({ root = repo })))
  assert_eq(browser.commits[1].refs[1]:match("^HEAD") ~= nil, true, "the newest commit carries HEAD")
  assert_eq(vim.tbl_contains(browser.commits[1].refs, "tag: v1"), true, "tags are listed")
  vim.wait(5000, function() return not browser.stats_loading end)
  assert_eq(vim.deep_equal(browser.stats[browser.commits[2].hash], { files = 2, added = 3, removed = 0 }), true,
    "stats count files and lines")
  assert_eq(browser.stats[browser.commits[1].hash].files, 0, "an empty commit changes nothing")
  local row = vim.api.nvim_buf_get_lines(browser.buf, 2, 3, false)[1]
  assert_eq(row:find("+3 -0", 1, true) ~= nil, true, "the row shows the counts")
  assert_eq(row:find("grow a", 1, true) ~= nil, true, "the row shows the subject")

  -- 80 columns is under details_min_columns, so the pane starts closed.
  assert_eq(browser.details_win, nil, "a narrow log opens without the pane")
  buffer_keymap_callback(browser.buf, "n", "p")()
  assert_eq(vim.api.nvim_win_is_valid(browser.details_win), true, "p opens the pane")
  vim.api.nvim_win_set_cursor(browser.win, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = browser.buf })
  local hash = browser.commits[2].hash
  vim.wait(5000, function()
    return browser.details_cache[hash] ~= nil and browser.details_hash == hash
  end)
  local lines = vim.api.nvim_buf_get_lines(browser.details_buf, 0, -1, false)
  assert_eq(lines[1], hash, "the pane leads with the full hash")
  assert_eq(vim.tbl_contains(lines, "with a body line"), true, "the pane shows the message body")
  assert_eq(vim.tbl_contains(lines, "2 files changed  +3 -0"), true, "the pane sums the changes")
  local b_row
  for line, file in pairs(browser.details_file_rows) do
    if file.path == "b.txt" then
      b_row = line
    end
  end
  assert_eq(lines[b_row]:match("^A") ~= nil, true, "added files are marked A")

  vim.api.nvim_set_current_win(browser.details_win)
  vim.api.nvim_win_set_cursor(browser.details_win, { b_row, 0 })
  buffer_keymap_callback(browser.details_buf, "n", "<CR>")()
  local review = state.sessions[vim.api.nvim_get_current_tabpage()]
  assert_eq(review.file_queue.entries[review.file_queue_index].path, "b.txt", "Enter on a file opens the review there")
  assert_eq(review.file_queue.log_walk.index, 2, "the review can still walk the log")
  review:close()

  buffer_keymap_callback(browser.buf, "n", "p")()
  assert_eq(browser.details_win, nil, "p closes the pane")

  -- A file history's pane lists only the files its review would open.
  local scoped
  require("diffbandit.git").commit_details_async(repo, hash, { "b.txt" }, function(details)
    scoped = details
  end)
  vim.wait(5000, function() return scoped ~= nil end)
  assert_eq(#scoped.files, 1, "pathspecs limit the pane's files")
  assert_eq(scoped.files[1].path, "b.txt", "the pane keeps the matching file")
  state.unregister_view(browser)
  vim.cmd("tabclose")
end
