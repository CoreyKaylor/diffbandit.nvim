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

  -- Launcher mode: the panel's q quits nvim instead of only hiding the panel.
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
    assert_eq(commands[1], nil, "Without launcher mode, panel q does not quit")
    assert_eq(launched.panel.visible, false, "Without launcher mode, panel q hides the panel")
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
