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
