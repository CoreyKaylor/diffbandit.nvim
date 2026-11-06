-- GIT PROVIDER TESTS
-- ==============================================================================

do
  local left = vim.fn.tempname()
  local right = vim.fn.tempname()
  vim.fn.mkdir(left .. "/nested", "p")
  vim.fn.mkdir(right .. "/nested", "p")
  write_repo_file(left, "same.txt", { "same" })
  write_repo_file(right, "same.txt", { "same" })
  write_repo_file(left, "size.txt", { "short" })
  write_repo_file(right, "size.txt", { "longer" })
  write_repo_file(left, "left-only.txt", { "left" })
  write_repo_file(right, "right-only.txt", { "right" })
  write_repo_file(left, "nested/pending.bin", { "aa" })
  write_repo_file(right, "nested/pending.bin", { "bb" })

  local private = folder_mod._private
  local left_entries = private.scan_tree(left, {})
  local right_entries = private.scan_tree(right, {})
  local rows, by_rel = private.build_rows(left_entries, right_entries)
  private.recompute_aggregate(rows, by_rel)

  assert_eq(by_rel["left-only.txt"].direct_status, "left_only",
    "Folder model should mark left-only files")
  assert_eq(by_rel["right-only.txt"].direct_status, "right_only",
    "Folder model should mark right-only files")
  assert_eq(by_rel["size.txt"].direct_status, "different",
    "Folder model should mark size mismatches as different without digesting")
  assert_eq(by_rel["nested/pending.bin"].direct_status, "pending",
    "Folder model should defer same-size regular files to digest comparison")
  assert_eq(by_rel["nested"].status, "pending",
    "Folder model should aggregate pending descendants into parent folders")

  by_rel["nested/pending.bin"].direct_status = "different"
  private.recompute_aggregate(rows, by_rel)
  assert_eq(by_rel["nested"].status, "different",
    "Folder model should aggregate differing descendants into parent folders")
end

do
  local private = folder_mod._private
  local nul_output = "abc123  /tmp/space name.txt\0def456  /tmp/new\nline.bin\0"
  local parsed_nul = private.parse_md5sum_z(nul_output)
  assert_eq(parsed_nul["/tmp/space name.txt"], "abc123",
    "Folder digest parser should preserve spaces in md5sum -z paths")
  assert_eq(parsed_nul["/tmp/new\nline.bin"], "def456",
    "Folder digest parser should preserve newline paths in md5sum -z output")

  local parsed_order = private.parse_line_order("aaa\nbbb\n", { "/left", "/right" })
  assert_eq(parsed_order["/left"], "aaa",
    "macOS md5 -q parser should associate digests by input order")
  assert_eq(parsed_order["/right"], "bbb",
    "macOS md5 -q parser should parse the second digest by input order")

  local parsed_lines = private.parse_digest_lines("ccc  /tmp/file one\n")
  assert_eq(parsed_lines["/tmp/file one"], "ccc",
    "shasum parser should preserve paths with spaces")

  local backend = private.detect_backend(config)
  assert_ne(backend, nil, "Folder diff should detect an external digest or cmp backend")
end

do
  local replaced = actions_mod._private.replace_range({ "a", "c" }, 1, 0, { "b" })
  assert_eq(to_text(replaced), "a\nb\nc\n", "Zero-count replacement should insert after the anchor line")
  replaced = actions_mod._private.replace_range({ "a", "b", "c" }, 2, 1, { "B" })
  assert_eq(to_text(replaced), "a\nB\nc\n", "Positive-count replacement should replace the target range")
end

do
  local entries = git_mod._private.parse_raw(table.concat({
    ":100644 100644 1111111 0000000 M", "space name.txt",
    ":100644 100644 2222222 2222222 R100", "old path.txt", "new path.txt",
    ":100644 000000 3333333 0000000 D", "gone.txt",
    ":100644 100755 4444444 0000000 M", "mode.sh",
  }, "\0") .. "\0")
  assert_eq(#entries, 4, "NUL raw parser should read modified, renamed, and deleted entries")
  assert_eq(entries[1].path, "space name.txt", "Parser should preserve spaces in paths")
  assert_eq(entries[1].raw_status, "M", "Parser should keep the status letter")
  assert_eq(entries[2].old_path, "old path.txt", "Parser should capture rename old path")
  assert_eq(entries[2].path, "new path.txt", "Parser should capture rename new path")
  assert_eq(entries[2].raw_status, "R100", "Parser should keep the rename score")
  assert_eq(entries[1].modes.left .. " " .. entries[1].modes.right, "100644 100644", "Raw modes ride along")
  assert_eq(entries[3].modes, nil, "A side the diff cannot see (000000) keeps the lazy mode lookup")
  assert_eq(entries[4].modes.right, "100755", "Mode changes come from the raw listing")
end

do
  local session = {
    config = config,
    left = { path = "/tmp/left.txt", label = "left.txt" },
    right = { path = "/tmp/right.txt", label = "right.txt" },
    current_chunk = 1,
    view = { chunks = { {} } },
  }
  local lines = status_mod.build(session)
  assert_eq(lines.left, "file  left.txt", "Plain status should identify left file")
  assert_eq(lines.center, "DiffBandit  hunk 1/1", "Plain status should summarize non-git hunk state")
  assert_eq(lines.right, "file  right.txt", "Plain status should identify right file")
end

do
  local old_have_nerd = vim.g.have_nerd_font
  local old_diffbandit_have_nerd = vim.g.diffbandit_have_nerd_font
  vim.g.have_nerd_font = true
  vim.g.diffbandit_have_nerd_font = nil
  local nerd_config = config_mod.apply({
    ui = {
      status = {
        icons = "auto",
      },
    },
  })
  local icons = status_mod._private.icons_for(nerd_config)
  assert_eq(icons.git ~= "Git", true, "Auto icon mode should use Nerd Font glyphs when advertised")
  vim.g.have_nerd_font = old_have_nerd
  vim.g.diffbandit_have_nerd_font = old_diffbandit_have_nerd
end

do
  local dump = hex_mod.dump(string.char(0, 1, 2, 65, 66, 255), {
    bytes_per_row = 4,
    max_bytes = 4,
    show_ascii = true,
  })
  assert_eq(dump.display_numbers[1], "00000000", "Hex dump should label the first row by byte offset")
  assert_eq(dump.lines[1], "00 01 02 41  |...A|", "Hex dump should include grouped bytes and ASCII preview")
  assert_eq(dump.truncated, true, "Hex dump should report truncation when max_bytes is exceeded")
  assert_eq(dump.lines[2], "[DiffBandit: hex view truncated at 4 of 6 bytes]",
    "Hex dump should add a truncation notice row")
  assert_eq(hex_mod.is_binary("plain text\n"), false, "Plain text should not be detected as binary")
  assert_eq(hex_mod.is_binary("a\000b"), true, "NUL-containing text should be detected as binary")
  local no_offsets = hex_mod.dump("abcd", { show_offsets = false })
  assert_eq(no_offsets.display_numbers, nil, "Hex dump should honor disabled offset labels")
end

if vim.fn.executable("git") == 1 then
  do
    local repo = make_git_repo()
    write_repo_file(repo, "alpha.txt", { "one" })
    commit_baseline(repo)
    write_repo_file(repo, "alpha.txt", { "one changed" })
    write_repo_file(repo, "new file.txt", { "new content" })

    local queue, err = git_mod.queue({
      root = repo,
      mode = "unstaged",
      include_untracked = true,
    }, config.git)
    assert_eq(err, nil, "Unstaged queue should load")
    assert_eq(#queue.entries, 2, "Unstaged queue should include modified and untracked files")

    local alpha
    local alpha_index
    local untracked
    for index, entry in ipairs(queue.entries) do
      if entry.path == "alpha.txt" then
        alpha = select(1, queue.load(index))
        alpha_index = index
      elseif entry.path == "new file.txt" then
        untracked = select(1, queue.load(index))
      end
    end

    assert_eq(alpha.left.text, "one\n", "Unstaged left source should read index content")
    assert_eq(alpha.right.text, "one changed\n", "Unstaged right source should read working tree content")
    do
      queue.index = alpha_index
      local status_session = {
        config = config,
        left = alpha.left,
        right = alpha.right,
        file_queue = queue,
        file_queue_index = alpha_index,
        current_chunk = 1,
        view = { chunks = { {}, {} } },
        staged_chunk_states = { [1] = true },
      }
      local lines = status_mod.build(status_session)
      assert_eq(lines.left, "index  alpha.txt", "Git status should identify left index side")
      assert_eq(lines.center, "DiffBandit  Git:unstaged  file " .. tostring(alpha_index) .. "/2  hunk 1/2  M  staged 1/2", "Git status should summarize queue and staged chunks")
      assert_eq(lines.center_compact, "unstg " .. tostring(alpha_index) .. "/2 h1/2 M 1/2", "Git status should provide a compact center summary")
      assert_eq(lines.right, "working tree  alpha.txt", "Git status should identify right working tree side")
    end
    assert_eq(untracked.left.text, "", "Untracked left source should be empty")
    assert_eq(untracked.left.label, "new file.txt (not tracked)", "Untracked left source should explain missing base")
    assert_eq(untracked.left.git_state, "untracked", "Untracked left source should carry git state")
    assert_eq(untracked.left.empty_reason, "New untracked file", "Untracked left source should carry empty notice text")
    assert_eq(untracked.right.text, "new content\n", "Untracked right source should read working tree content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "staged.txt", { "old" })
    commit_baseline(repo)
    write_repo_file(repo, "staged.txt", { "new" })
    git_test_command({ "add", "staged.txt" }, repo)

    local queue, err = git_mod.queue({
      root = repo,
      mode = "staged",
    }, config.git)
    assert_eq(err, nil, "Staged queue should load")
    assert_eq(#queue.entries, 1, "Staged queue should include staged file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "old\n", "Staged left source should read HEAD content")
    assert_eq(loaded.right.text, "new\n", "Staged right source should read index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "history.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "history.txt", { "base", "second" })
    git_test_command({ "commit", "-am", "second commit" }, repo)
    local rev = vim.trim(git_test_command({ "rev-parse", "HEAD" }, repo))

    local commits, log_err = git_mod.log(repo, { max_count = 2 })
    assert_eq(log_err, nil, "Git log helper should not error")
    assert_eq(#commits, 2, "Git log helper should return requested commits")
    assert_eq(commits[1].subject, "second commit", "Git log helper should parse commit subject")

    local queue, queue_err = git_mod.commit_queue(repo, rev, {}, config.git)
    assert_eq(queue_err, nil, "Commit queue should load for a normal commit")
    assert_eq(queue.opts.read_only, true, "Commit queue should be marked read-only")
    assert_eq(queue.opts.review.kind, "commit", "Commit queue should carry review metadata")
    assert_eq(#queue.entries, 1, "Commit queue should include changed files")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "base\n", "Commit queue left side should read the parent")
    assert_eq(loaded.right.text, "base\nsecond\n", "Commit queue right side should read the commit")
    assert_eq(loaded.entry.actions_enabled, false, "Commit queue entries should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "root.txt", { "root" })
    git_test_command({ "add", "root.txt" }, repo)
    git_test_command({ "commit", "-m", "root commit" }, repo)
    local rev = vim.trim(git_test_command({ "rev-parse", "HEAD" }, repo))

    local queue, queue_err = git_mod.commit_queue(repo, rev, {}, config.git)
    assert_eq(queue_err, nil, "Root commit queue should load")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "", "Root commit queue should compare against the empty tree")
    assert_eq(loaded.right.text, "root\n", "Root commit queue should read root commit content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "branch.txt", { "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "branch.txt", { "base", "feature" })
    git_test_command({ "commit", "-am", "feature commit" }, repo)
    git_test_command({ "checkout", main_branch }, repo)

    local branches, branch_err = git_mod.list_branches(repo)
    assert_eq(branch_err, nil, "Branch listing should not error")
    local saw_feature = false
    for _, branch in ipairs(branches) do
      if branch.name == "feature" then
        saw_feature = true
      end
    end
    assert_eq(saw_feature, true, "Branch listing should include local branches")

    local queue, queue_err = git_mod.compare_queue(repo, main_branch, "feature", {}, config.git)
    assert_eq(queue_err, nil, "Branch compare queue should load")
    assert_eq(queue.opts.read_only, true, "Branch compare queue should be read-only")
    assert_eq(queue.opts.review.kind, "compare", "Branch compare queue should carry review metadata")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.right.text, "base\nfeature\n", "Branch compare should read target branch content")

    write_repo_file(repo, "dirty.txt", { "dirty" })
    local ok, checkout_err = git_mod.checkout_branch(repo, "feature")
    assert_eq(ok, false, "Checkout helper should refuse dirty worktrees by default")
    assert_eq(checkout_err, "worktree has uncommitted changes", "Checkout helper should report dirty worktree")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "panel.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "panel.txt", { "one", "TWO", "three" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "panel.txt" } }, config.git)))
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "unstaged",
      "Panel file state should start unstaged for worktree-only changes")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { mode = "all" }), "unstaged",
      "Panel file state should not treat all-mode opts as a staged base")

    local ok, err = git_mod.stage_file(repo, queue.entries[1])
    assert_eq(err, nil, "Panel file stage should not error")
    assert_eq(ok, true, "Panel file stage should succeed")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "staged",
      "Panel file state should become staged after file stage")

    write_repo_file(repo, "panel.txt", { "one", "TWO", "THREE" })
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "partial",
      "Panel file state should detect staged and unstaged changes for the same file")

    ok, err = git_mod.unstage_file(repo, queue.entries[1])
    assert_eq(err, nil, "Panel file unstage should not error")
    assert_eq(ok, true, "Panel file unstage should succeed")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "unstaged",
      "Panel file state should return to unstaged after whole-file unstage")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "tracked.txt", { "staged" })
    git_test_command({ "add", "tracked.txt" }, repo)
    write_repo_file(repo, "tracked.txt", { "worktree" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "tracked.txt" } }, config.git)))
    local ok, err = git_mod.discard_worktree_file(repo, queue.entries[1])
    assert_eq(ok, true, "Panel discard file action should succeed")
    assert_eq(err, nil, "Panel discard file action should not error")
    assert_eq(table.concat(read_file(repo .. "/tracked.txt"), "\n") .. "\n", "staged\n",
      "Panel discard should restore the worktree to the staged index content")
    assert_eq(git_mod.read_index(repo, "tracked.txt"), "staged\n",
      "Panel discard should preserve staged content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "restore_me.txt", { "base" })
    commit_baseline(repo)
    assert(os.remove(repo .. "/restore_me.txt"))

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "restore_me.txt" } }, config.git)))
    local ok, err = git_mod.discard_worktree_file(repo, queue.entries[1])
    assert_eq(ok, true, "Panel restore deleted file action should succeed")
    assert_eq(err, nil, "Panel restore deleted file action should not error")
    assert_eq(table.concat(read_file(repo .. "/restore_me.txt"), "\n") .. "\n", "base\n",
      "Panel restore deleted file action should restore index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "keep.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "scratch.log", { "temporary" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "scratch.log" } }, config.git)))
    assert_eq(queue.entries[1].untracked, true, "Panel delete test should load an untracked file")
    local ok, err = git_mod.delete_untracked_file(repo, queue.entries[1])
    assert_eq(ok, true, "Panel delete untracked action should succeed")
    assert_eq(err, nil, "Panel delete untracked action should not error")
    assert_eq(vim.fn.filereadable(repo .. "/scratch.log"), 0,
      "Panel delete untracked action should remove the file")

    ok, err = git_mod.delete_untracked_file(repo, { path = "keep.txt" })
    assert_eq(ok, false, "Panel delete untracked action should refuse tracked files")
    assert_eq(err, "refusing to delete a tracked file",
      "Panel delete untracked action should explain tracked file refusal")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "base" })
    commit_baseline(repo)

    local ok, err = git_mod.append_gitignore(repo, "/logs/*.log")
    assert_eq(ok, true, "Panel ignore action should create .gitignore")
    assert_eq(err, nil, "Panel ignore action should not error")
    ok, err = git_mod.append_gitignore(repo, "/logs/*.log")
    assert_eq(ok, true, "Panel ignore action should allow an existing pattern")
    assert_eq(err, nil, "Panel ignore duplicate action should not error")
    local lines = read_file(repo .. "/.gitignore")
    assert_eq(#lines, 1, "Panel ignore action should avoid duplicate .gitignore entries")
    assert_eq(lines[1], "/logs/*.log", "Panel ignore action should write the requested pattern")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "logs/app.log", { "temporary" })
    write_repo_file(repo, "tracked.txt", { "changed" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    local by_path = {}
    for index, entry in ipairs(queue.entries) do
      by_path[entry.path] = { entry = entry, index = index }
    end
    local session = {
      file_queue = queue,
      panel = { stage_states = git_mod.file_stage_states(repo, queue.entries, queue.opts) },
    }
    local untracked_actions = panel_mod.file_actions_for_entry(session, by_path["logs/app.log"].entry,
      session.panel.stage_states[by_path["logs/app.log"].index])
    local action_ids = {}
    for _, action in ipairs(untracked_actions) do
      action_ids[action.id] = true
    end
    assert_eq(action_ids.stage, true, "Panel untracked action list should include stage")
    assert_eq(action_ids.delete_untracked, true, "Panel untracked action list should include delete")
    assert_eq(action_ids["ignore:/logs/app.log"], true, "Panel untracked action list should include exact ignore")
    assert_eq(action_ids["ignore:*.log"], true, "Panel untracked action list should include extension ignore")
    assert_eq(action_ids["ignore:/logs/"], true, "Panel untracked action list should include parent directory ignore")

    local tracked_actions = panel_mod.file_actions_for_entry(session, by_path["tracked.txt"].entry,
      session.panel.stage_states[by_path["tracked.txt"].index])
    action_ids = {}
    for _, action in ipairs(tracked_actions) do
      action_ids[action.id] = true
    end
    assert_eq(action_ids.stage, true, "Panel tracked action list should include stage")
    assert_eq(action_ids.discard_worktree, true, "Panel tracked action list should include discard")
    assert_eq(action_ids.delete_untracked, nil, "Panel tracked action list should not include delete untracked")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "alpha.txt", { "one" })
    write_repo_file(repo, "beta.txt", { "one" })
    commit_baseline(repo)
    write_repo_file(repo, "alpha.txt", { "two" })
    write_repo_file(repo, "beta.txt", { "two" })
    git_test_command({ "add", "alpha.txt" }, repo)
    write_repo_file(repo, "alpha.txt", { "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    local states = git_mod.file_stage_states(repo, queue.entries, queue.opts)
    local by_path = {}
    for index, entry in ipairs(queue.entries) do
      by_path[entry.path] = states[index]
    end
    assert_eq(by_path["alpha.txt"], "partial", "Batched panel state should detect partial files")
    assert_eq(by_path["beta.txt"], "unstaged", "Batched panel state should detect unstaged files")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "amend.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "amend.txt", { "committed" })
    git_test_command({ "add", "amend.txt" }, repo)
    git_test_command({ "commit", "-m", "second" }, repo)

    local base, err = git_mod.amend_base(repo)
    assert_eq(err, nil, "Amend base should resolve for a normal repository")
    assert_eq(base, "HEAD^", "Amend base should compare against the parent commit")

    local queue = assert((git_mod.queue({ root = repo, mode = "all", base = base, pathspecs = { "amend.txt" } }, config.git)))
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { stage_base = base }), "staged",
      "Amend panel state should treat current HEAD content as staged against the amend base")

    write_repo_file(repo, "amend.txt", { "committed", "working tree" })
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { stage_base = base }), "partial",
      "Amend panel state should show partial when the commit content and worktree both differ from the amend base")
    local ok, unstage_err = git_mod.unstage_file(repo, queue.entries[1], { stage_base = base })
    assert_eq(ok, true, "Amend unstage should restore the index from the amend base")
    assert_eq(unstage_err, nil, "Amend unstage should not error")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { stage_base = base }), "unstaged",
      "Amend unstage should clear the staged state against the amend base")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "root.txt", { "first" })
    commit_baseline(repo)
    local base, err = git_mod.amend_base(repo)
    assert_eq(err, nil, "Amend base should resolve for the root commit")
    assert_ne(base, "HEAD^", "Root amend base should not use a missing parent ref")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "commit.txt", { "base" })
    commit_baseline(repo)
    local ok, err = git_mod.commit(repo, "   ", {})
    assert_eq(ok, false, "Panel commit should reject an empty message")
    assert_eq(err, "commit message cannot be empty", "Panel commit should explain empty message validation")
    ok, err = git_mod.commit(repo, "no staged changes", {})
    assert_eq(ok, false, "Panel commit should reject committing without staged changes")
    assert_eq(err, "no staged changes to commit", "Panel commit should explain missing staged changes")

    write_repo_file(repo, "commit.txt", { "changed" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "commit.txt" } }, config.git)))
    ok, err = git_mod.stage_file(repo, queue.entries[1])
    assert_eq(ok, true, "Commit test stage should succeed")
    assert_eq(err, nil, "Commit test stage should not error")
    ok, err = git_mod.commit(repo, "panel commit", {})
    assert_eq(ok, true, "Panel commit should succeed with staged changes")
    assert_eq(err, nil, "Panel commit should not error")
    local message = git_test_command({ "log", "-1", "--pretty=%B" }, repo)
    assert_eq(vim.trim(message), "panel commit", "Panel commit should write the requested message")

    ok, err = git_mod.commit(repo, "panel amend", { amend = true })
    assert_eq(ok, true, "Panel amend should allow message-only amend")
    assert_eq(err, nil, "Panel amend should not error")
    message = git_test_command({ "log", "-1", "--pretty=%B" }, repo)
    assert_eq(vim.trim(message), "panel amend", "Panel amend should update the latest commit message")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "merge_no_diff.txt", { "one", "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "merge_no_diff.txt", { "one", "incoming" })
    git_test_command({ "commit", "-am", "incoming merge side" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "merge_no_diff.txt", { "one", "local" })
    git_test_command({ "commit", "-am", "local merge side" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "No-diff merge commit fixture should conflict")
    write_repo_file(repo, "merge_no_diff.txt", { "one", "local" })
    git_test_command({ "add", "merge_no_diff.txt" }, repo)
    assert_eq(git_mod.has_any_staged_changes(repo), false,
      "Resolving a conflict to HEAD should leave no cached diff")
    assert_eq(git_mod.has_pending_merge_commit(repo), true,
      "Resolved no-diff merge should still have a pending merge commit")
    local ok, err = git_mod.commit(repo, "merge no diff", {})
    assert_eq(ok, true, "Panel commit should allow a resolved merge with no staged diff")
    assert_eq(err, nil, "Resolved no-diff merge commit should not error")
    local message = git_test_command({ "log", "-1", "--pretty=%B" }, repo)
    assert_eq(vim.trim(message), "merge no diff", "Resolved no-diff merge should create a merge commit")
  end

  do
    local session = {
      config = config_mod.apply({
        git = {
          panel = {
            icons = "plain",
          },
        },
      }),
      file_queue = {
        root = "/tmp/repo",
        entries = {
          { status = "U", raw_status = "U", path = "lua/diffbandit/merge.lua" },
          { status = "M", path = "lua/diffbandit/git.lua", kind = "modified" },
          { status = "A", raw_status = "??", path = "tests/files/new.txt", untracked = true, kind = "untracked" },
        },
      },
      panel = {
        stage_states = {
          [2] = "partial",
          [3] = "unstaged",
        },
      },
    }
    local rows = panel_mod._private.build_rows(session)
    assert_eq(rows[1].text, "▾ Merge Conflicts  1 files", "Panel rows should group conflicts first")
    assert_eq(rows[2].text:find("! U merge.lua", 1, true) ~= nil, true,
      "Panel conflict row should use conflict status instead of staged state")
    assert_eq(rows[3].text, "▾ Changes  1 files", "Panel rows should group tracked changes")
    assert_eq(rows[4].type, "file", "Panel rows should include tracked file row")
    assert_eq(rows[5].text, "▾ Unversioned Files  1 files", "Panel rows should group unversioned files")
    assert_eq(rows[6].type, "file", "Panel rows should include unversioned file row")
    assert_eq(rows[4].text:find("◧ M git.lua", 1, true) ~= nil, true,
      "Panel file row should include staged state, status, and basename")
  end

  do
    local nav_buf = vim.api.nvim_create_buf(false, true)
    local original_file_stage_states = git_mod.file_stage_states
    local called = false
    git_mod.file_stage_states = function()
      called = true
      return {}
    end
    local session = {
      ns = vim.api.nvim_create_namespace("DiffBanditPanelRenderNoGit"),
      config = config,
      file_queue = {
        root = "/tmp/repo",
        entries = {
          { status = "M", path = "one.txt", kind = "modified" },
        },
      },
      panel = {
        nav_buf = nav_buf,
        stage_states = { [1] = "unstaged" },
      },
      file_queue_index = 1,
    }
    panel_mod.render_nav(session, 1)
    git_mod.file_stage_states = original_file_stage_states
    assert_eq(called, false, "Panel nav render should not refresh Git stage states implicitly")
    vim.api.nvim_buf_delete(nav_buf, { force = true })
  end

  do
    local buf = vim.api.nvim_create_buf(false, true)
    local session = {
      ns = vim.api.nvim_create_namespace("DiffBanditPanelCommitTest"),
      config = config,
      panel = {
        commit_buf = buf,
        stage_states = { [1] = "staged" },
        amend = true,
        message_lines = { "commit body" },
        validation_message = "commit message cannot be empty",
      },
    }
    panel_mod.render_commit(session)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_eq(#lines, 3, "Commit pane should reserve two virtual header rows before the message")
    assert_eq(lines[1], "", "Commit pane amend status row should be virtual text")
    assert_eq(lines[2], "", "Commit pane message label row should be virtual text")
    assert_eq(lines[3], "commit body", "Commit pane message body should remain real buffer text")
    local marks = vim.api.nvim_buf_get_extmarks(buf, session.ns, 0, -1, { details = true })
    assert_eq(#marks >= 2, true, "Commit pane should render virtual header overlays")
    local found_validation = false
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      for _, chunk in ipairs(details.virt_text or {}) do
        if chunk[1] and chunk[1]:find("commit message cannot be empty", 1, true) then
          found_validation = true
        end
      end
    end
    assert_eq(found_validation, true, "Commit pane should render validation text in the virtual header")
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "baseline.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "added.txt", { "new" })
    git_test_command({ "add", "added.txt" }, repo)

    local queue, err = git_mod.queue({
      root = repo,
      mode = "staged",
      pathspecs = { "added.txt" },
    }, config.git)
    assert_eq(err, nil, "Staged added-file queue should load")
    assert_eq(#queue.entries, 1, "Staged added-file queue should include one file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "", "Staged added left source should be empty")
    assert_eq(loaded.left.label, "added.txt (HEAD: absent)", "Staged added left source should explain missing HEAD version")
    assert_eq(loaded.left.git_state, "absent", "Staged added left source should carry absent git state")
    assert_eq(loaded.left.empty_reason, "New file", "Staged added left source should carry empty notice text")
    assert_eq(loaded.right.text, "new\n", "Staged added right source should read index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "gone.txt", { "old" })
    commit_baseline(repo)
    git_test_command({ "rm", "gone.txt" }, repo)

    local queue, err = git_mod.queue({
      root = repo,
      mode = "staged",
    }, config.git)
    assert_eq(err, nil, "Staged deleted-file queue should load")
    assert_eq(#queue.entries, 1, "Staged deleted-file queue should include one file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "old\n", "Staged deleted left source should read HEAD content")
    assert_eq(loaded.right.text, "", "Staged deleted right source should be empty")
    assert_eq(loaded.right.label, "gone.txt (index: deleted)", "Staged deleted right source should explain missing index version")
    assert_eq(loaded.right.git_state, "deleted", "Staged deleted right source should carry deleted git state")
    assert_eq(loaded.right.empty_reason, "Deleted file", "Staged deleted right source should carry empty notice text")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "buffer.txt", { "saved" })
    commit_baseline(repo)

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
    vim.api.nvim_buf_set_name(bufnr, repo .. "/buffer.txt")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved" })

    local queue, err = git_mod.queue({
      root = repo,
      mode = "unstaged",
      scope = "current",
      path = repo .. "/buffer.txt",
      use_buffer = true,
    }, config.git)
    assert_eq(err, nil, "Current-file queue should include unsaved buffer changes")
    assert_eq(#queue.entries, 1, "Current-file queue should synthesize one buffer-only entry")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "saved\n", "Buffer diff left source should read index content")
    assert_eq(loaded.right.text, "unsaved\n", "Buffer diff right source should read live buffer content")
    assert_eq(loaded.right.editable and loaded.right.editable.bufnr, bufnr,
      "Git worktree right source should carry the reusable live buffer identity")
    assert_eq(loaded.right.editable and loaded.right.editable.target, "git-worktree",
      "Git worktree right source should be marked as an editable worktree target")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mapped-undo.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "mapped-undo.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({
      root = repo,
      mode = "unstaged",
      pathspecs = { "mapped-undo.txt" },
    }, config.git)))
    local loaded = select(1, queue.load(1))
    local session = assert((Session.start({
      left = loaded.left,
      right = loaded.right,
    }, config, {
      queue = queue,
    })))

    session:stage_hunk()
    assert_eq(git_mod.read_index(repo, "mapped-undo.txt"), "one\nTWO\nthree\n",
      "Mapped undo setup should stage the hunk first")

    vim.api.nvim_set_current_win(session.right_win)
    local undo_callback = buffer_keymap_callback(session.right_buf, "n", config.actions.keys.undo)
    assert_eq(type(undo_callback), "function",
      "Editable Git right buffer should have a callable undo mapping")
    undo_callback()
    assert_eq(git_mod.read_index(repo, "mapped-undo.txt"), "one\ntwo\nthree\n",
      "Undo in an editable Git right buffer with no native edit should pop the DiffBandit action stack")

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mapped-undo-after-edit.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "mapped-undo-after-edit.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({
      root = repo,
      mode = "unstaged",
      pathspecs = { "mapped-undo-after-edit.txt" },
    }, config.git)))
    local loaded = select(1, queue.load(1))
    local session = assert((Session.start({
      left = loaded.left,
      right = loaded.right,
    }, config, {
      queue = queue,
    })))

    vim.api.nvim_set_current_win(session.right_win)
    vim.api.nvim_buf_set_lines(session.right_buf, 0, -1, false, { "one", "THREE", "three" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.right_buf })
    vim.wait(400, function()
      return session.right.text == "one\nTHREE\nthree\n"
    end, 10)

    session:stage_hunk()
    assert_eq(git_mod.read_index(repo, "mapped-undo-after-edit.txt"), "one\nTHREE\nthree\n",
      "Mapped undo after edit setup should stage the edited right-buffer content")

    local undo_callback = buffer_keymap_callback(session.right_buf, "n", config.actions.keys.undo)
    undo_callback()
    assert_eq(git_mod.read_index(repo, "mapped-undo-after-edit.txt"), "one\ntwo\nthree\n",
      "Undo after edit then stage should undo the newer stage action first")
    assert_eq(vim.api.nvim_buf_get_lines(session.right_buf, 0, -1, false)[2], "THREE",
      "Undoing the stage action first should leave the right-buffer edit intact")

    undo_callback()
    -- Native buffer undo path refreshes immediately (refresh_editable_right).
    assert_eq(session.right.text, "one\nTWO\nthree\n",
      "Second undo should refresh the right source text immediately")
    assert_eq(vim.api.nvim_buf_get_lines(session.right_buf, 0, -1, false)[2], "TWO",
      "A second undo should then use native buffer undo")

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local binary_path = repo .. "/binary.bin"
    write_binary_file(binary_path, string.char(0, 1, 2, 3, 65, 66, 67, 68))
    git_test_command({ "add", "binary.bin" }, repo)
    commit_baseline(repo)
    write_binary_file(binary_path, string.char(0, 1, 2, 4, 65, 66, 67, 69))

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "binary.bin" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.git_binary_hex, true, "Binary left source should render as hex")
    assert_eq(loaded.right.git_binary_hex, true, "Binary right source should render as hex")
    assert_eq(loaded.left.display_numbers[1], "00000000", "Binary hex source should expose byte offsets")
    assert_eq(loaded.left.lines[1]:find("00 01 02 03", 1, true) ~= nil, true,
      "Binary left source should include baseline bytes")
    assert_eq(loaded.right.lines[1]:find("00 01 02 04", 1, true) ~= nil, true,
      "Binary right source should include changed bytes")
    assert_eq(queue.entries[1].content_kind, "binary", "Binary queue entry should be classified as binary")
    assert_eq(queue.entries[1].actions_enabled, false, "Binary queue entry should disable hunk actions")
  end

  do
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git_test_command({ "init" }, repo)
    write_repo_file(repo, "first.txt", { "first content" })

    local queue, err = git_mod.queue({ root = repo, mode = "all" }, config.git)
    assert_eq(err, nil, "Unborn repository queue should diff against the empty tree")
    assert_eq(#queue.entries, 1, "Unborn repository queue should include the untracked file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.git_ref, "not tracked", "Unborn untracked left side should still identify not-tracked state")
    assert_eq(loaded.right.text, "first content\n", "Unborn untracked right side should read worktree content")
  end

  do
    local repo = make_git_repo()
    local queue = {
      kind = "git",
      root = repo,
      opts = { mode = "all" },
      entries = {
        { status = "U", raw_status = "U", path = "conflict.txt" },
        { status = "T", raw_status = "T", path = "typechange.txt" },
      },
    }
    local unmerged = select(1, git_mod.sources_for_entry(queue, 1))
    assert_eq(unmerged.left.empty_reason, "Git metadata entry", "Unmerged left side should render a metadata placeholder")
    assert_eq(unmerged.right.text, "Unmerged file: resolve conflicts outside DiffBandit\n",
      "Unmerged right side should explain the conflict state")
    assert_eq(queue.entries[1].actions_enabled, false, "Unmerged entries should disable hunk actions")

    local typechange = select(1, git_mod.sources_for_entry(queue, 2))
    assert_eq(typechange.right.text, "File type changed\n",
      "Typechange right side should explain metadata-only changes")
    assert_eq(queue.entries[2].actions_enabled, false, "Typechange entries should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "conflict.txt", { "one", "base", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "conflict.txt", { "one", "remote", "three" })
    git_test_command({ "commit", "-am", "remote change" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "conflict.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local change" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Test merge should produce a conflict")

    local entries = assert(git_mod.unmerged_entries(repo, {}))
    assert_eq(#entries, 1, "Unmerged entry scan should find the conflicted file")
    assert_eq(entries[1].path, "conflict.txt", "Unmerged entry should carry the conflicted path")

    local stages = assert((git_mod.conflict_stages(repo, "conflict.txt")))
    assert_eq(stages.base, "one\nbase\nthree\n", "Conflict base stage should read :1:")
    assert_eq(stages.local_text, "one\nlocal\nthree\n", "Conflict local stage should read :2:")
    assert_eq(stages.remote, "one\nremote\nthree\n", "Conflict remote stage should read :3:")

    local data = assert((merge_mod.load(repo, "conflict.txt", config)))
    assert_eq(#data.conflicts, 1, "Merge model should identify the overlapping edit conflict")
    assert_eq(to_text(data.result_lines), stages.base, "Merge result should initialize from base lines")

    local context = git_mod.merge_context(repo)
    assert_eq(context.operation, "merge", "Merge context should detect MERGE_HEAD")
    assert_eq(context.current, main_branch, "Merge context should detect the current branch")
    assert_eq(context.incoming:find("feature", 1, true) ~= nil, true,
      "Merge context should prefer a friendly incoming branch name")

    local result_buf = vim.api.nvim_create_buf(false, true)
    local fake_merge = setmetatable({
      config = config,
      path = "conflict.txt",
      conflicts = data.conflicts,
      current_conflict = 1,
      line_ending_warning = data.line_ending_warning,
      merge_context = context,
      result_buf = result_buf,
    }, { __index = merge_mod })
    local status_lines = fake_merge:build_status_lines()
    assert_eq(status_lines.left:find("local/current", 1, true) ~= nil, true,
      "Merge local status header should identify the current side")
    assert_eq(status_lines.result:find("merge result", 1, true) ~= nil, true,
      "Merge result status header should identify the editable result")
    assert_eq(status_lines.result:find("conflict 1/1", 1, true) ~= nil, true,
      "Merge result status header should include conflict position")
    assert_eq(status_lines.remote:find("remote/incoming", 1, true) ~= nil, true,
      "Merge remote status header should identify the incoming side")
    fake_merge.status_lines = {
      left = status_lines.left,
      center = status_lines.result,
      right = status_lines.remote,
    }
    status_lines = fake_merge:build_status_lines()
    assert_eq(status_lines.result:find("merge result", 1, true) ~= nil, true,
      "Merge status builder should not be shadowed by rendered status state")
    pcall(vim.api.nvim_buf_delete, result_buf, { force = true })

    local ok, commit_err = git_mod.commit(repo, "should fail", {})
    assert_eq(ok, false, "Commit should fail while unmerged entries remain")
    assert_eq(commit_err, "merge conflicts must be resolved before committing",
      "Commit failure should explain unresolved conflicts")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "pick.txt", { "one", "base", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "pick.txt", { "one", "remote", "three" })
    git_test_command({ "commit", "-am", "picked change" }, repo)
    local picked = vim.trim(git_test_command({ "rev-parse", "HEAD" }, repo))
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "pick.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local change" }, repo)
    local pick_code = git_status_command({ "cherry-pick", picked }, repo)
    assert_eq(pick_code ~= 0, true, "Cherry-pick fixture should conflict")
    local context = git_mod.merge_context(repo)
    assert_eq(context.operation, "cherry-pick", "Merge context should detect CHERRY_PICK_HEAD")
    assert_eq(context.incoming ~= nil and context.incoming ~= "", true,
      "Cherry-pick context should provide an incoming commit label")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "detached.txt", { "base" })
    commit_baseline(repo)
    git_test_command({ "checkout", "--detach" }, repo)
    local context = git_mod.merge_context(repo)
    assert_eq(context.current:find("detached", 1, true) == 1, true,
      "Merge context should describe detached HEAD")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "add.txt", { "one", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "add.txt", { "one", "remote", "three" })
    git_test_command({ "commit", "-am", "remote insertion" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "add.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local insertion" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Add/add fixture should conflict")
    local data = assert((merge_mod.load(repo, "add.txt", config)))
    assert_eq(data.conflicts[1].result_count, 0, "Add/add conflict should preserve a zero-count base range")
  end

  do
    local repo = make_git_repo()
    git_test_command({ "commit", "--allow-empty", "-m", "baseline" }, repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "add_add.txt", { "remote one", "remote two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "remote add/add" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "add_add.txt", { "local one", "local two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "local add/add" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Empty-base add/add fixture should conflict")
    local data = assert((merge_mod.load(repo, "add_add.txt", config)))
    assert_eq(#data.result_lines, 0, "Empty-base add/add result should start with no logical lines")
    assert_eq(data.conflicts[1].result_count, 0,
      "Empty-base add/add conflict should preserve a zero-count result range")

    local session = assert((merge_mod.start(data, config, {})))
    assert_eq(#session.result_lines, 0,
      "Empty editable result buffer should render as zero logical result lines")
    local result_marks = vim.api.nvim_buf_get_extmarks(session.result_buf, session.active_ns, 0, -1, { details = true })
    local has_delete_background = false
    local has_result_top_edge = false
    for _, mark in ipairs(result_marks) do
      local details = mark[4] or {}
      if mark[2] == 0 and details.line_hl_group == "DiffBanditDelete" then
        has_delete_background = true
      end
      local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
      if virt_text:find("▔", 1, true) then
        has_result_top_edge = true
      end
    end
    assert_eq(has_delete_background, false,
      "Zero-line merge result conflict should not paint a full center document row")
    assert_eq(has_result_top_edge, true,
      "Zero-line merge result conflict should render a top-edge marker across the center document")

    local function has_marker(buf, glyph)
      local marks = vim.api.nvim_buf_get_extmarks(buf, session.active_ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if virt_text == glyph then
          return true
        end
      end
      return false
    end

    assert_eq(has_marker(session.local_num_buf, "◤"), true,
      "Zero-line merge result conflict should mark the local/source gutter edge")
    assert_eq(has_marker(session.remote_num_buf, "◥"), true,
      "Zero-line merge result conflict should mark the remote/source gutter edge with a mirrored triangle")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_left_num_buf, session.active_ns, 0, -1, {}) == 0, true,
      "Zero-line merge result conflict should not cover the left result line-number pane")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_right_num_buf, session.active_ns, 0, -1, {}) == 0, true,
      "Zero-line merge result conflict should not cover the right result line-number pane")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.local_result_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Zero-line merge result conflict should render the local/result connector top edge")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_remote_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Zero-line merge result conflict should render the result/remote connector top edge")
    assert_eq(session:accept("local"), true, "Accepting the local side should update the merge result")
    assert_eq(#session.result_lines, 2, "Accepting local should render accepted result lines")
    assert_eq(has_marker(session.local_num_buf, "◤"), false,
      "Accepted local result should remove the zero-line local/source triangle")
    vim.api.nvim_win_call(session.result_win, function()
      vim.cmd("silent! undo")
    end)
    session:render()
    assert_eq(#session.result_lines, 0, "Undo after accept should restore an empty logical result")
    assert_eq(has_marker(session.local_num_buf, "◤"), true,
      "Undo after accept should restore the zero-line local/source triangle")
    assert_eq(has_marker(session.remote_num_buf, "◥"), true,
      "Undo after accept should restore the zero-line remote/source triangle")
    assert_eq(session:accept("remote"), true, "Accepting the remote side should update the merge result")
    assert_eq(#session.result_lines, 2, "Accepting remote should render accepted result lines")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_buf, session.active_ns, 0, -1, {}) == 0, true,
      "Accepted remote result should not receive merge active-row overlays")

    local function has_hl(buf, ns, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if details.hl_group == hl or details.line_hl_group == hl then
          return true
        end
      end
      return false
    end

    local function has_hl_on_row(buf, ns, row, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row and (details.hl_group == hl or details.line_hl_group == hl) then
          return true
        end
      end
      return false
    end

    local function has_hl_span(buf, ns, row, hl, start_col, end_col)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row
            and mark[3] == start_col
            and details.end_col == end_col
            and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    assert_eq(has_hl(session.result_buf, session.local_result_session.extmark_ns, "DiffBanditChangeRight"), true,
      "Accepted remote result should keep the local/result change background")
    assert_eq(has_hl(session.result_buf, session.local_result_session.extmark_ns, "DiffBanditChangeEmphasis"), true,
      "Accepted remote result should keep word-level change emphasis")
    assert_eq(has_hl(session.result_buf, session.local_result_session.extmark_ns, "DiffBanditAdd"), false,
      "Accepted remote replacement word should not split into an added suffix")
    assert_eq(has_hl_on_row(session.result_buf, session.local_result_session.extmark_ns, 0, "DiffBanditChangeEmphasis"), true,
      "Accepted remote first result row should keep word-level change emphasis")
    assert_eq(has_hl_on_row(session.result_buf, session.local_result_session.extmark_ns, 1, "DiffBanditChangeEmphasis"), true,
      "Accepted remote second result row should keep word-level change emphasis")
    assert_eq(has_hl_span(session.result_buf, session.local_result_session.extmark_ns, 0, "DiffBanditChangeEmphasis", 0, 6), true,
      "Accepted remote first result row should emphasize the full replacement word")
    assert_eq(has_hl_span(session.result_buf, session.local_result_session.extmark_ns, 1, "DiffBanditChangeEmphasis", 0, 6), true,
      "Accepted remote second result row should emphasize the full replacement word")
    assert_eq(has_hl(session.result_buf, session.result_remote_session.extmark_ns, "DiffBanditContext"), false,
      "Accepted remote result should not get context background from the matching remote/result pair")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    -- Mid-document zero-range conflict: both sides insert different lines at
    -- the same interior point, so the conflict region has zero result lines
    -- while the result document itself is non-empty. The ▔ overlay is
    -- reserved for the empty result document — here it would cover (and hide)
    -- a real content row; the pair renderers' delete routes mark the spot.
    local repo = make_git_repo()
    write_repo_file(repo, "mid_add.txt", { "top", "alpha = 1", "bottom" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "mid_add.txt", { "top", "alpha = 1", "remote extra", "bottom" })
    git_test_command({ "commit", "-am", "remote mid insertion" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "mid_add.txt", { "top", "alpha = 1", "local extra", "bottom" })
    git_test_command({ "commit", "-am", "local mid insertion" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Mid-document add/add fixture should conflict")
    local session = assert((merge_mod.start(assert((merge_mod.load(repo, "mid_add.txt", config))), config, {})))
    assert_eq(#session.result_lines > 0, true, "Mid-document conflict should keep a non-empty result document")
    local function overlay_glyphs(buf)
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, session.active_ns, 0, -1, { details = true })) do
        local details = mark[4] or {}
        local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if virt_text:find("▔", 1, true) or virt_text == "◤" or virt_text == "◥" then
          found[#found + 1] = virt_text
        end
      end
      return found
    end
    assert_eq(#overlay_glyphs(session.result_buf), 0,
      "Non-empty result must not draw the zero-range ▔ overlay over a real content row")
    assert_eq(#overlay_glyphs(session.local_num_buf), 0,
      "Non-empty result must not draw the zero-range local gutter marker")
    assert_eq(#overlay_glyphs(session.remote_num_buf), 0,
      "Non-empty result must not draw the zero-range remote gutter marker")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    -- Delete/modify conflict: the shared result content pane must prefer the
    -- surviving side's change diff (band + inner emphasis) over the deleted
    -- side's add band, which stays available below it as a range mark.
    local repo = make_git_repo()
    write_repo_file(repo, "delete_vs_edit.txt", { "shared header line", "shared body line" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "delete_vs_edit.txt", { "shared header line", "incoming body line" })
    git_test_command({ "commit", "-am", "incoming edits file" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    git_test_command({ "rm", "delete_vs_edit.txt" }, repo)
    git_test_command({ "commit", "-m", "local deletes file" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Delete-vs-edit fixture should conflict")
    local session = assert((merge_mod.start(assert((merge_mod.load(repo, "delete_vs_edit.txt", config))), config, {})))
    local local_add_range, local_add_line_hl, local_add_priority
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.result_buf,
      session.local_result_session.extmark_ns, 0, -1, { details = true })) do
      local details = mark[4] or {}
      if details.hl_group == "DiffBanditAdd" then
        local_add_range = true
        local_add_priority = details.priority
      end
      if details.line_hl_group == "DiffBanditAdd" then
        local_add_line_hl = true
      end
    end
    assert_eq(local_add_range, true,
      "Deleted-side pair should paint the shared result add band as a range mark")
    assert_eq(local_add_line_hl or false, false,
      "Deleted-side pair must not paint an add line highlight in the shared result (line highlights beat range priorities)")
    local remote_change_priority
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.result_buf,
      session.result_remote_session.extmark_ns, 0, -1, { details = true })) do
      local details = mark[4] or {}
      if details.hl_group == "DiffBanditChangeRight" then
        remote_change_priority = details.priority
      end
    end
    assert_eq(type(local_add_priority) == "number" and type(remote_change_priority) == "number"
      and local_add_priority < remote_change_priority, true,
      "Shared result change band must outrank the other pair's add band on contested rows")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    git_test_command({ "commit", "--allow-empty", "-m", "baseline" }, repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "add_add.txt", { "remote one", "remote two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "remote add/add" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "add_add.txt", { "local one", "local two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "local add/add" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Panel resolve add/add fixture should conflict")
    local worktree_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value("swapfile", false, { buf = worktree_buf })
    vim.api.nvim_buf_set_name(worktree_buf, repo .. "/add_add.txt")
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "add_add.txt" } }, config.git)))
    local data = assert((merge_mod.load(repo, "add_add.txt", config)))
    local session = assert((merge_mod.start(data, config, {
      panel = true,
      queue = queue,
      queue_index = 1,
      panel_initial_selection = 1,
    })))

    assert_eq(session.panel.rows[1].text, "▾ Merge Conflicts  1 files",
      "Merge panel should initially list the unresolved add/add conflict")
    assert_eq(session:accept("remote"), true, "Accepting incoming add/add content should update the result")
    assert_eq(session:resolve(), true, "Resolving add/add should write and stage the result")
    assert_eq(vim.trim(git_test_command({ "ls-files", "-u", "--", "add_add.txt" }, repo)), "",
      "Resolved add/add file should no longer have unmerged index stages")
    local cached = git_test_command({ "diff", "--cached", "--", "add_add.txt" }, repo)
    assert_eq(cached:find("+remote one", 1, true) ~= nil, true,
      "Resolved add/add file should stage the accepted incoming content")
    assert_eq(session.panel.rows[1].text, "▾ Changes  1 files",
      "Merge panel should remove resolved conflicts and show the staged changed file")
    assert_eq(session.panel.rows[2].entry.path, "add_add.txt",
      "Merge panel should keep the resolved file selected in the refreshed queue")
    assert_eq(session.panel.stage_states[session.file_queue_index], "staged",
      "Merge panel should mark the resolved changed file as staged")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
    pcall(vim.api.nvim_buf_delete, worktree_buf, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "delete_vs_modify.txt", { "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "delete_vs_modify.txt", { "incoming modified" })
    git_test_command({ "commit", "-am", "incoming modifies file" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    git_test_command({ "rm", "delete_vs_modify.txt" }, repo)
    git_test_command({ "commit", "-m", "local deletes file" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Delete-vs-modify fixture should conflict")
    local data = assert((merge_mod.load(repo, "delete_vs_modify.txt", config)))
    assert_eq(data.has_local, false, "Delete-vs-modify fixture should mark local side as deleted")
    local session = assert((merge_mod.start(data, config, {})))
    assert_eq(session:accept("local"), true, "Accepting the local deleted side should succeed")
    assert_eq(session.delete_result, true, "Accepting local deletion should mark the merge result as file deletion")
    assert_eq(session:resolve(), true, "Resolving local deletion should write the deleted result")
    assert_eq(vim.fn.filereadable(repo .. "/delete_vs_modify.txt"), 0,
      "Resolving local deletion should remove the worktree file")
    assert_eq(vim.trim(git_test_command({ "ls-files", "-u", "--", "delete_vs_modify.txt" }, repo)), "",
      "Resolving local deletion should clear unmerged stages")
    assert_eq(vim.trim(git_test_command({ "ls-files", "--", "delete_vs_modify.txt" }, repo)), "",
      "Resolving local deletion should remove the file from the index")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "modify_vs_delete.txt", { "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    git_test_command({ "rm", "modify_vs_delete.txt" }, repo)
    git_test_command({ "commit", "-m", "incoming deletes file" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "modify_vs_delete.txt", { "local modified" })
    git_test_command({ "commit", "-am", "local modifies file" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Modify-vs-delete fixture should conflict")
    local data = assert((merge_mod.load(repo, "modify_vs_delete.txt", config)))
    assert_eq(data.has_remote, false, "Modify-vs-delete fixture should mark remote side as deleted")
    local session = assert((merge_mod.start(data, config, {})))
    assert_eq(session:accept("remote"), true, "Accepting the remote deleted side should succeed")
    assert_eq(session.delete_result, true, "Accepting remote deletion should mark the merge result as file deletion")
    assert_eq(session:resolve(), true, "Resolving remote deletion should write the deleted result")
    assert_eq(vim.fn.filereadable(repo .. "/modify_vs_delete.txt"), 0,
      "Resolving remote deletion should remove the worktree file")
    assert_eq(vim.trim(git_test_command({ "ls-files", "-u", "--", "modify_vs_delete.txt" }, repo)), "",
      "Resolving remote deletion should clear unmerged stages")
    local cached_status = vim.trim(git_test_command({ "diff", "--cached", "--name-status", "--", "modify_vs_delete.txt" }, repo))
    assert_eq(cached_status, "D\tmodify_vs_delete.txt",
      "Resolving remote deletion should stage the deletion against HEAD")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "mixed_non_conflicting.txt",
      base_lines = {},
      local_lines = { "local non-conflicting source" },
      remote_lines = { "remote non-conflicting source" },
      result_lines = {},
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function has_marker(buf, glyph)
      local marks = vim.api.nvim_buf_get_extmarks(buf, session.active_ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if virt_text == glyph then
          return true
        end
      end
      return false
    end

    assert_eq(has_marker(session.local_num_buf, "◤"), true,
      "Pair-level zero delete should mark the local/source gutter edge")
    assert_eq(has_marker(session.remote_num_buf, "◥"), true,
      "Pair-level zero delete should mark the remote/source gutter edge with a mirrored triangle")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.local_result_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Pair-level zero delete should render the local/result connector top edge")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_remote_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Pair-level zero delete should render the result/remote connector top edge")
    vim.api.nvim_set_current_win(session.local_win)
    vim.api.nvim_win_set_cursor(session.local_win, { 1, 0 })
    assert_eq(session:accept("local"), true, "Accepting a local pair hunk should update the merge result")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "local non-conflicting source", "Local pair hunk accept should copy the local source into the result")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, {})
    session:render()
    vim.api.nvim_set_current_win(session.remote_win)
    vim.api.nvim_win_set_cursor(session.remote_win, { 1, 0 })
    assert_eq(session:accept("remote"), true, "Accepting a remote pair hunk should update the merge result")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "remote non-conflicting source", "Remote pair hunk accept should copy the remote source into the result")
	    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
	    session:close()
	  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "a_changed.txt", { "base changed" })
    write_repo_file(repo, "b_conflict.txt", { "one", "base", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "b_conflict.txt", { "one", "incoming", "three" })
    git_test_command({ "commit", "-am", "incoming conflict" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "b_conflict.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local conflict" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Panel preview fixture should conflict")
    write_repo_file(repo, "a_changed.txt", { "worktree changed" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    assert_eq(queue.entries[1].path, "a_changed.txt", "Panel preview fixture should sort the changed file first")
    assert_eq(queue.entries[2].path, "b_conflict.txt", "Panel preview fixture should sort the conflict second")
    local loaded = assert((queue.load(1)))
    queue.index = 1
    local session = assert((Session.start({ left = loaded.left, right = loaded.right }, config, {
      queue = queue,
      panel = true,
      panel_initial_selection = 1,
      panel_message_lines = { "draft merge commit" },
    })))
    state_mod.register(session)
    vim.api.nvim_set_current_win(session.panel.nav_win)
    assert_eq(session:open_merge_file(2, { preserve_focus = true }), true,
      "Panel preview should open a conflict entry from a normal changed-file diff")
    local merge_session = state_mod.sessions[vim.api.nvim_get_current_tabpage()]
    assert_eq(merge_session ~= nil and merge_session.path, "b_conflict.txt",
      "Panel preview should switch to the requested merge conflict")
    assert_eq(merge_session.panel ~= nil and merge_session.panel.visible, true,
      "Panel preview should keep the commit panel visible in the merge resolver")
    assert_eq(vim.api.nvim_get_current_win(), merge_session.panel.nav_win,
      "Panel preview should keep focus in the panel navigation window")
    assert_eq(merge_session.panel.message_lines[1], "draft merge commit",
      "Panel preview should carry commit message text into the merge resolver")
    assert_eq(session.disposed, true,
      "Switching to a conflict should close the changed-file view instead of keeping its tab (issue #20)")
    local tab_count = #vim.api.nvim_list_tabpages()

    assert_eq(merge_session:goto_queue_file(1, "top"), true,
      "Panel preview should switch from a conflict back to a changed file")
    local back = state_mod.sessions[vim.api.nvim_get_current_tabpage()]
    assert_eq(back ~= nil and back ~= merge_session and back.left_buf ~= nil, true,
      "Switching back should land on the new changed-file view")
    assert_eq(merge_session.disposed, true,
      "Switching away from a conflict should close the merge view (issue #20)")
    assert_eq(#vim.api.nvim_list_tabpages(), tab_count,
      "Switching between conflicts and changes should reuse one tab, not stack them (issue #20)")

    -- gzp hides and re-shows the panel without closing the diff.
    vim.api.nvim_set_current_win(back.right_win)
    buffer_keymap_callback(back.right_buf, "n", "gzp")()
    assert_eq(back.panel.visible, false, "gzp in a diff pane should hide the commit panel")
    assert_eq(back.disposed, false, "Hiding the panel should keep the diff open")
    buffer_keymap_callback(back.right_buf, "n", "gzp")()
    assert_eq(back.panel.visible, true, "gzp should show the commit panel again")
    buffer_keymap_callback(back.panel.nav_buf, "n", "gzp")()
    assert_eq(back.panel.visible, false, "gzp in the panel should hide the panel")
    local focused = vim.api.nvim_get_current_win()
    assert_eq(focused == back.left_win or focused == back.right_win, true,
      "Hiding the focused panel should return focus to a diff pane")
    back:show_commit_panel()

    -- q in the panel closes the whole view and keeps the unfinished message.
    assert_eq(vim.api.nvim_buf_get_lines(back.panel.commit_buf, 2, 3, false)[1], "draft merge commit",
      "The message should survive both view switches")
    local back_tab = back.tabpage
    buffer_keymap_callback(back.panel.nav_buf, "n", "q")()
    assert_eq(back.disposed, true, "q in the commit panel should close the whole diff view")
    assert_eq(vim.api.nvim_tabpage_is_valid(back_tab), false, "q in the commit panel should close the view's tab")
    assert_eq((state_mod.commit_drafts[queue.root] or {})[1], "draft merge commit",
      "Closing a view should save the unfinished commit message for the repository")

    local reloaded = assert((queue.load(1)))
    local reopened = assert((Session.start({ left = reloaded.left, right = reloaded.right }, config, {
      queue = queue,
      panel = true,
      panel_initial_selection = 1,
    })))
    state_mod.register(reopened)
    assert_eq(vim.api.nvim_buf_get_lines(reopened.panel.commit_buf, 2, 3, false)[1], "draft merge commit",
      "The next panel for the repository should restore the saved draft")
    vim.api.nvim_buf_set_lines(reopened.panel.commit_buf, 2, -1, false, { "" })
    reopened:close()
    assert_eq(state_mod.commit_drafts[queue.root], nil,
      "Closing with a cleared message should drop the saved draft")
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "panel_conflict.txt",
      base_lines = { "base" },
      local_lines = { "local" },
      remote_lines = { "remote" },
      result_lines = { "base" },
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local queue = {
      kind = "git",
      root = repo,
      index = 1,
      entries = {
        { status = "U", raw_status = "U", kind = "unmerged", path = "panel_conflict.txt" },
      },
    }
    local session = assert((merge_mod.start(data, config, {
      panel = true,
      queue = queue,
      panel_initial_selection = 1,
    })))
    local original_nav_win = session.panel and session.panel.nav_win
    vim.api.nvim_set_current_win(session.result_win)
    assert_eq(session:focus_commit_panel_for_current_file(), true,
      "Merge focus-panel action should focus the attached panel")
    assert_eq(vim.api.nvim_get_current_win(), original_nav_win,
      "Merge focus-panel action should return to the existing panel window")

    local function enter_and_wait(target_win)
      vim.api.nvim_set_current_win(target_win)
      vim.wait(100, function()
        return vim.api.nvim_get_current_win() ~= target_win
      end, 5)
      return vim.api.nvim_get_current_win()
    end

    vim.api.nvim_set_current_win(session.result_win)
    assert_eq(enter_and_wait(session.result_left_num_win), session.local_win,
      "Merge focus guard should move left through result gutters to the local pane")
    assert_eq(enter_and_wait(session.local_num_win), session.result_win,
      "Merge focus guard should move right through local gutters to the result pane")
    assert_eq(enter_and_wait(session.result_right_num_win), session.remote_win,
      "Merge focus guard should move right through result gutters to the remote pane")
    assert_eq(enter_and_wait(session.remote_num_win), session.result_win,
      "Merge focus guard should move left through remote gutters to the result pane")

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "mixed_non_conflicting.txt",
      base_lines = { "kept" },
      local_lines = { "kept", "local only" },
      remote_lines = { "kept", "remote only" },
      result_lines = { "kept" },
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))
    local local_marks = vim.api.nvim_buf_get_extmarks(session.local_num_buf, session.active_ns, 0, -1, { details = true })
    local remote_marks = vim.api.nvim_buf_get_extmarks(session.remote_num_buf, session.active_ns, 0, -1, { details = true })
    assert_eq(#local_marks, 0, "Pair-level non-top zero delete should not synthesize a local/source triangle")
    assert_eq(#remote_marks, 0, "Pair-level non-top zero delete should not synthesize a remote/source triangle")
    vim.api.nvim_set_current_win(session.local_win)
    vim.api.nvim_win_set_cursor(session.local_win, { 1, 0 })
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should visit non-conflicting local pair hunks")
    assert_eq(vim.api.nvim_win_get_cursor(session.local_win)[1], 2,
      "Merge navigation should move to the next local pair hunk")
    local selected = session:selected_item()
    assert_eq(selected and selected.local_hunk ~= nil, true,
      "Merge navigation should include the local pair hunk in the grouped stop")
    assert_eq(selected and selected.remote_hunk ~= nil, true,
      "Merge navigation should include the remote pair hunk in the grouped stop")
    local status_lines = session:build_status_lines()
    assert_eq(status_lines.result_action:find(">> L", 1, true) ~= nil, true,
      "Merge result header should describe the grouped local action compactly")
    assert_eq(status_lines.result_action:find("<< I", 1, true) ~= nil, true,
      "Merge result header should describe the grouped incoming action compactly")
    assert_eq(session:goto_next_hunk(), true, "Merge navigation at the final grouped hunk should stay on the grouped hunk")
    assert_eq(session:selected_item() and session:selected_item().key, selected and selected.key,
      "Merge navigation should not create a second stop for the same result range")
    assert_eq(session:accept("remote"), true, "Accepting the remote side of the grouped hunk should succeed")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "kept\nremote only", "Grouped remote pair hunk accept should insert the remote line into result")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, { "kept" })
    session.selected_pair_hunk = nil
    session:render()
    vim.api.nvim_set_current_win(session.local_win)
    vim.api.nvim_win_set_cursor(session.local_win, { 1, 0 })
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should return to the local pair hunk")
    assert_eq(session:accept("local"), true, "Accepting the navigated non-conflicting local hunk should succeed")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "kept\nlocal only", "Grouped local pair hunk accept should insert the local line into result")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, { "kept" })
    session.selected_pair_hunk = nil
    session:render()
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should return to the grouped pair hunk")
    assert_eq(session:accept("both"), true, "Accepting both sides of the grouped non-conflicting hunk should succeed")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "kept\nlocal only\nremote only", "Grouped both-side accept should insert local and remote lines into result")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local left = read_file(root .. "/tests/files/left_mixed.txt")
    local right = read_file(root .. "/tests/files/right_mixed.txt")
    local data = {
      root = repo,
      path = "mixed_non_conflicting.txt",
      base_lines = {},
      local_lines = left,
      remote_lines = left,
      result_lines = right,
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function has_glyph_at(buf, ns, row, glyph)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        local text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if mark[2] == row - 1 and text == glyph then
          return true
        end
      end
      return false
    end

    local function has_semantic_bg_from_col_zero(buf, ns, row, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row - 1 and mark[3] == 0 and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    local function has_semantic_bg_span(buf, ns, row, hl, col, end_col)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row - 1
            and mark[3] == col
            and details.end_col == end_col
            and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    assert_eq(has_glyph_at(session.result_left_num_buf, session.local_result_session.path_ns, 7, "◢"), true,
      "Mixed result left gutter should draw the lower change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_left_num_buf, session.local_result_session.path_ns, 9, "◥"), true,
      "Mixed result left gutter should draw the upper change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_left_num_buf, session.local_result_session.path_ns, 6, "◢"), false,
      "Mixed result left gutter change wedge should not shift one row up")
    assert_eq(has_glyph_at(session.result_right_num_buf, session.result_remote_session.path_ns, 7, "◣"), true,
      "Mixed result right gutter should draw the mirrored lower change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_right_num_buf, session.result_remote_session.path_ns, 9, "◤"), true,
      "Mixed result right gutter should draw the mirrored upper change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_right_num_buf, session.result_remote_session.path_ns, 8, "◤"), false,
      "Mixed result right gutter change wedge should not shift one row up")
    assert_eq(has_semantic_bg_from_col_zero(session.result_right_num_buf, session.result_remote_session.ns, 7,
      "DiffBanditConnectorChange"), true,
      "Mixed result right number gutter should color through the connector-side spacer on overlap rows")
    -- The change and the following add abut, so they merge into one chunk:
    -- the change band extends over the absorbed add rows for continuous
    -- band coloring through the gutter.
    assert_eq(has_semantic_bg_from_col_zero(session.result_right_num_buf, session.result_remote_session.ns, 8,
      "DiffBanditConnectorChange"), true,
      "Mixed result right number gutter should extend the change band over the absorbed add rows")
    -- Band fills now cover the full pane width (including the wedge/spacer
    -- column) so the band flows core -> gutter -> pane without a dark strip.
    do
      local marks = vim.api.nvim_buf_get_extmarks(session.result_right_num_buf, session.result_remote_session.ns,
        0, -1, { details = true })
      local full_width = false
      for _, mark in ipairs(marks) do
        local d = mark[4] or {}
        if mark[2] == 7 and mark[3] == 0 and d.hl_group == "DiffBanditConnectorChange"
            and ((d.end_row or 0) > 7 or (d.end_col or 0) > session.result_remote_session:right_triangle_col()) then
          full_width = true
          break
        end
      end
      assert_eq(full_width, true,
        "Mixed result right number gutter should color the absorbed add rows with a full-width change band")
    end
    assert_eq(has_semantic_bg_from_col_zero(session.remote_num_buf, session.result_remote_session.ns, 8,
      "DiffBanditConnectorChange"), true,
      "Mixed remote number gutter should color through the spacer on absorbed add rows")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local function numbered_lines(changed)
      local lines = {}
      for index = 1, 80 do
        lines[index] = changed and changed[index] or ("line " .. tostring(index))
      end
      return lines
    end
    local data = {
      root = repo,
      path = "lower_merge_hunk.txt",
      base_lines = numbered_lines(),
      local_lines = numbered_lines({ [20] = "local line 20", [60] = "local line 60" }),
      remote_lines = numbered_lines(),
      result_lines = numbered_lines(),
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function topline(win)
      local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
      return ok and view and view.topline or 1
    end

    vim.api.nvim_set_current_win(session.result_win)
    vim.api.nvim_win_set_cursor(session.result_win, { 1, 0 })
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should jump to the lower pair hunk")
    assert_eq(session:selected_item() and session:selected_item().local_index, 1,
      "Merge hunk navigation should start at the first pair hunk")
    assert_eq(topline(session.local_win) > 1, true,
      "Merge hunk navigation should scroll the local source pane")
    assert_eq(topline(session.result_win) > 1, true,
      "Merge hunk navigation should scroll the center result pane")
    assert_eq(topline(session.remote_win) > 1, true,
      "Merge hunk navigation should scroll the remote source pane")
    assert_eq(topline(session.local_num_win), topline(session.local_win),
      "Merge local line-number pane should follow the local source viewport")
    assert_eq(topline(session.result_left_num_win), topline(session.result_win),
      "Merge result left line-number pane should follow the result viewport")
    assert_eq(topline(session.result_right_num_win), topline(session.result_win),
      "Merge result right line-number pane should follow the result viewport")
    assert_eq(topline(session.remote_num_win), topline(session.remote_win),
      "Merge remote line-number pane should follow the remote source viewport")
    assert_eq(topline(session.local_result_connector_win), topline(session.local_win),
      "Merge local/result connector should follow the local source viewport")
    assert_eq(topline(session.result_remote_connector_win), topline(session.remote_win),
      "Merge result/remote connector should follow the remote source viewport")
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should move to the second pair hunk")
    assert_eq(session:selected_item() and session:selected_item().local_index, 2,
      "Merge hunk navigation should select the second pair hunk before document-top reset")
    session:goto_document_edge("bottom")
    assert_eq(vim.api.nvim_win_get_cursor(session.local_win)[1], 80,
      "Merge document-bottom navigation should move the local cursor to EOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.result_win)[1], 80,
      "Merge document-bottom navigation should move the result cursor to EOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.remote_win)[1], 80,
      "Merge document-bottom navigation should move the remote cursor to EOF")
    assert_eq(topline(session.local_result_connector_win), topline(session.local_win),
      "Merge document-bottom navigation should keep the local/result connector viewport synced")
    assert_eq(topline(session.result_remote_connector_win), topline(session.remote_win),
      "Merge document-bottom navigation should keep the result/remote connector viewport synced")
    session:goto_document_edge("top")
    assert_eq(vim.api.nvim_win_get_cursor(session.local_win)[1], 1,
      "Merge document-top navigation should move the local cursor to BOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.result_win)[1], 1,
      "Merge document-top navigation should move the result cursor to BOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.remote_win)[1], 1,
      "Merge document-top navigation should move the remote cursor to BOF")
    assert_eq(session:goto_next_hunk(), true,
      "Merge hunk navigation after document-top should restart at the first pair hunk")
    assert_eq(session:selected_item() and session:selected_item().local_index, 1,
      "Merge document-top navigation should reset the selected hunk boundary")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local function large_lines(overrides)
      local lines = {}
      for index = 1, 2000 do
        lines[index] = overrides and overrides[index] or ("large merge line " .. tostring(index))
      end
      return lines
    end
    local data = {
      root = repo,
      path = "large_merge.txt",
      base_lines = large_lines(),
      local_lines = large_lines({
        [750] = "large local line 750",
        [1500] = "large local line 1500",
      }),
      remote_lines = large_lines({
        [1500] = "large incoming line 1500",
      }),
      result_lines = large_lines(),
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }

    local original_build = diff_pair_mod.build
    local build_count = 0
    diff_pair_mod.build = function(...)
      build_count = build_count + 1
      return original_build(...)
    end

    local ok, err = pcall(function()
      local session = assert((merge_mod.start(data, config, {})))
      assert_eq(build_count, 2, "Large merge initial render should build the two source/result pairs")
      session:render()
      assert_eq(build_count, 2, "Large merge unchanged render should reuse existing pair models")
      vim.api.nvim_win_call(session.result_win, function()
        vim.api.nvim_win_set_cursor(session.result_win, { 1000, 0 })
        vim.cmd("normal! zt")
      end)
      session:render()
      assert_eq(build_count, 2, "Large merge viewport-only render should not rebuild pair diffs")
      vim.api.nvim_buf_set_lines(session.result_buf, 999, 1000, false, { "large edited result line 1000" })
      session:render()
      assert_eq(build_count, 4, "Large merge content edit should rebuild both pair models once")
      session:render()
      assert_eq(build_count, 4, "Large merge stale follow-up render should not rebuild pair models")
      assert_eq(vim.api.nvim_buf_get_lines(session.local_buf, 999, 1000, false)[1],
        "large merge line 1000", "Large merge result edits should not mutate the local source")
      assert_eq(vim.api.nvim_buf_get_lines(session.remote_buf, 999, 1000, false)[1],
        "large merge line 1000", "Large merge result edits should not mutate the remote source")
      pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
      session:close()
    end)
    diff_pair_mod.build = original_build
    if not ok then
      error(err)
    end
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "accepted_remote_with_insert.txt",
      base_lines = {},
      local_lines = { "one", "two", "three", "four" },
      remote_lines = { "one", "insert", "two", "THREE", "four" },
      result_lines = { "one", "insert", "two", "THREE", "four" },
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function has_number_hl(buf, ns, row, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    assert_eq(has_number_hl(session.local_num_buf, session.local_result_session.ns, 2, "DiffBanditConnectorChange"),
      true, "Source number pane should mark the compact source row for a change after a result-side add")
    assert_eq(has_number_hl(session.local_num_buf, session.local_result_session.ns, 3, "DiffBanditConnectorChange"),
      false, "Source number pane change background should not lag one row after a result-side add")
    assert_eq(has_number_hl(session.result_left_num_buf, session.local_result_session.ns, 1, "DiffBanditConnectorAdd"),
      true, "Result number pane should keep the accepted inserted row add background")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local mirrored = setmetatable({ mirror_connector_sides = true }, Session)
    assert_eq(mirrored:display_glyph("◤"), "◥", "Mirrored sessions should flip upper-left triangles")
    assert_eq(mirrored:display_glyph("◥"), "◤", "Mirrored sessions should flip upper-right triangles")
  end

  do
    local render_host = require("diffbandit.session.render_host")
    assert_eq(render_host.map_display_glyph("◢", { cell_wedges = true }), "",
      "cell_wedges should paint lower-right as Powerline E0BA")
    assert_eq(render_host.map_display_glyph("◣", { cell_wedges = true }), "",
      "cell_wedges should paint lower-left as Powerline E0B8")
    assert_eq(render_host.map_display_glyph("◤", { cell_wedges = true }), "",
      "cell_wedges should paint upper-left as Powerline E0BC")
    assert_eq(render_host.map_display_glyph("◥", { cell_wedges = true }), "",
      "cell_wedges should paint upper-right as Powerline E0BE")
    assert_eq(render_host.map_display_glyph("◤", { mirror = true, cell_wedges = true }), "",
      "mirror then cell_wedges: upper-left becomes upper-right Powerline")
    assert_eq(render_host.map_display_glyph("◢", {}), "◢",
      "default display should keep Unicode geometric wedges")
    local old_g = vim.g.diffbandit_cell_wedges
    vim.g.diffbandit_cell_wedges = true
    assert_eq(render_host.cell_wedges_enabled({}), true,
      "vim.g.diffbandit_cell_wedges should enable cell wedges")
    vim.g.diffbandit_cell_wedges = old_g
    assert_eq(render_host.cell_wedges_enabled({ ui = { cell_wedges = true } }), true,
      "ui.cell_wedges config should enable cell wedges")
  end

  do
    local left = { "one", "two", "four" }
    local right = { "one", "TWO", "three", "four" }
    local pair = assert((diff_pair_mod.build(left, right, config)))
    local hunks = assert((diff.compute_hunks(to_text(left), to_text(right), config.diff)))
    local direct = view.build(left, right, hunks, config)
    assert_eq(table.concat(pair.view.connectors, "\n"), table.concat(direct.connectors, "\n"),
      "Diff pair renderer should preserve the existing view connector model")

    local base = { "one", "base", "three" }
    local local_lines = { "one", "local", "three" }
    local remote_lines = { "one", "remote", "three" }
    local initial_left = assert((diff_pair_mod.build(local_lines, base, config)))
    local initial_right = assert((diff_pair_mod.build(base, remote_lines, config)))
    local edited = { "one", "manual", "three" }
    local edited_left = assert((diff_pair_mod.build(local_lines, edited, config)))
    local edited_right = assert((diff_pair_mod.build(edited, remote_lines, config)))
    assert_eq(#initial_left.hunks > 0, true, "Initial local/result pair should have a diff")
    assert_eq(#initial_right.hunks > 0, true, "Initial result/remote pair should have a diff")
    assert_eq(edited_left.right_lines[2], "manual", "Edited result should update the left pair result side")
    assert_eq(edited_right.left_lines[2], "manual", "Edited result should update the right pair result side")
    assert_eq(local_lines[2], "local", "Local source lines should remain unchanged by result edits")
    assert_eq(remote_lines[2], "remote", "Remote source lines should remain unchanged by result edits")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "renamed_old.txt", { "old name line" })
    commit_baseline(repo)
    git_test_command({ "mv", "renamed_old.txt", "renamed_new.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].status, "R", "Renamed file should classify as rename")
    assert_eq(loaded.left.git_relpath, "renamed_old.txt", "Rename left source should use old path")
    assert_eq(loaded.right.git_relpath, "renamed_new.txt", "Rename right source should use new path")
    local lines = status_mod.build({
      config = config,
      left = loaded.left,
      right = loaded.right,
      file_queue = queue,
      file_queue_index = 1,
      current_chunk = 1,
      view = { chunks = { {} } },
      staged_chunk_states = {},
    })
    assert_eq(lines.center:find("renamed_old.txt %-%> renamed_new.txt") ~= nil, true,
      "Rename status should show path direction")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "copy_source.txt", { "copy base" })
    commit_baseline(repo)
    write_repo_file(repo, "copy_dest.txt", { "copy base" })
    git_test_command({ "add", "copy_dest.txt" }, repo)

    local queue = assert((git_mod.queue({
      root = repo,
      mode = "staged",
      find_copies = true,
    }, config.git)))
    assert_eq(queue.entries[1].status, "C", "Opt-in copy detection should classify copied files")
    queue.load(1)
    assert_eq(queue.entries[1].actions_enabled, false, "Copied entries should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mode_only.sh", { "#!/bin/sh", "echo mode" })
    commit_baseline(repo)
    git_test_command({ "update-index", "--chmod=+x", "mode_only.sh" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "staged", pathspecs = { "mode_only.sh" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].content_kind, "metadata", "Mode-only diff should classify as metadata")
    assert_eq(loaded.right.text:find("mode change", 1, true) ~= nil, true,
      "Mode-only diff should show Git summary text")
    assert_eq(queue.entries[1].actions_enabled, false, "Mode-only metadata should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    local uv = vim.uv or vim.loop
    assert(uv.fs_symlink("old-target.txt", repo .. "/link.txt"))
    git_test_command({ "add", "link.txt" }, repo)
    commit_baseline(repo)
    assert(os.remove(repo .. "/link.txt"))
    assert(uv.fs_symlink("new-target.txt", repo .. "/link.txt"))

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "link.txt" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].content_kind, "symlink", "Symlink diff should classify as symlink")
    assert_eq(loaded.left.text, "symlink -> old-target.txt\n", "Symlink left side should show old target")
    assert_eq(loaded.right.text, "symlink -> new-target.txt\n", "Symlink right side should show new target")
    assert_eq(queue.entries[1].actions_enabled, false, "Symlink actions should be disabled")
  end

  do
    local repo = make_git_repo()
    local old_oid = "1111111111111111111111111111111111111111"
    local new_oid = "2222222222222222222222222222222222222222"
    git_test_command({ "update-index", "--add", "--cacheinfo", "160000," .. old_oid .. ",vendor/lib" }, repo)
    git_test_command({ "commit", "-m", "submodule baseline" }, repo)
    git_test_command({ "update-index", "--add", "--cacheinfo", "160000," .. new_oid .. ",vendor/lib" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "staged", pathspecs = { "vendor/lib" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].content_kind, "submodule", "Gitlink diff should classify as submodule")
    assert_eq(loaded.right.text:find("Submodule", 1, true) ~= nil, true,
      "Submodule diff should show a metadata summary")
    assert_eq(queue.entries[1].actions_enabled, false, "Submodule actions should be disabled")
  end

  do
    local dump = hex_mod.dump(string.rep("a", 12), {
      max_bytes = 8,
      bytes_per_row = 4,
    })
    assert_eq(dump.truncated, true, "Large binary dump should mark truncation")
    assert_eq(dump.lines[#dump.lines], "[DiffBandit: hex view truncated at 8 of 12 bytes]",
      "Large binary dump should include truncation notice")
  end

  local function make_action_session(queue)
    local loaded = select(1, queue.load(queue.index or 1))
    local hunks, err = diff.compute_hunks(loaded.left.text, loaded.right.text, config.diff)
    assert_eq(err, nil, "Action session diff should compute")
    local v = view.build(loaded.left.lines, loaded.right.lines, hunks, config)
    local fake = setmetatable({
      config = config,
      file_queue = queue,
      file_queue_index = queue.index or 1,
      left = loaded.left,
      right = loaded.right,
      hunks = hunks,
      view = v,
      current_chunk = v.chunks[1] and 1 or 0,
    }, Session)
    function fake:replace_sources(sources, opts)
      local next_hunks, next_err = diff.compute_hunks(sources.left.text, sources.right.text, config.diff)
      assert_eq(next_err, nil, "Action refresh diff should compute")
      self.left = sources.left
      self.right = sources.right
      self.hunks = next_hunks
      self.view = view.build(sources.left.lines, sources.right.lines, next_hunks, config)
      self.current_chunk = self.view.chunks[1] and math.min((opts and opts.preferred_chunk) or 1, #self.view.chunks) or 0
      return true, nil
    end
    return fake
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "stage.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "stage.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "stage.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "Stage hunk action should not error")
    assert_eq(ok, true, "Stage hunk action should succeed")
    assert_eq(#(session.file_queue.entries or {}), 1, "Stage refresh should keep the original queue")
    assert_eq(git_mod.read_index(repo, "stage.txt"), "one\nTWO\nthree\n", "Stage hunk should update the index")
    assert_eq(table.concat(read_file(repo .. "/stage.txt"), "\n") .. "\n", "one\nTWO\nthree\n", "Stage hunk should not rewrite worktree content")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo stage hunk should not error")
    assert_eq(ok, true, "Undo stage hunk should succeed")
    assert_eq(git_mod.read_index(repo, "stage.txt"), "one\ntwo\nthree\n", "Undo should restore previous index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "discard.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "discard.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "discard.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.discard(session)
    assert_eq(err, nil, "Discard hunk action should not error")
    assert_eq(ok, true, "Discard hunk action should succeed")
    assert_eq(table.concat(read_file(repo .. "/discard.txt"), "\n") .. "\n", "one\ntwo\nthree\n", "Discard should restore worktree content from index")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo discard hunk should not error")
    assert_eq(ok, true, "Undo discard hunk should succeed")
    assert_eq(table.concat(read_file(repo .. "/discard.txt"), "\n") .. "\n", "one\nTWO\nthree\n", "Undo should restore discarded worktree content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "scratch-shadow.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "scratch-shadow.txt", { "one", "TWO", "three" })

    local shadow = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = shadow })
    vim.api.nvim_buf_set_name(shadow, repo .. "/scratch-shadow.txt")
    vim.api.nvim_set_option_value("modifiable", false, { buf = shadow })

    local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "scratch-shadow.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.discard(session)
    assert_eq(err, nil, "Discard with path-shadowing scratch buffer should not error")
    assert_eq(ok, true, "Discard with path-shadowing scratch buffer should succeed")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo discard should ignore path-shadowing scratch buffer")
    assert_eq(ok, true, "Undo discard should restore the worktree file")
    assert_eq(table.concat(read_file(repo .. "/scratch-shadow.txt"), "\n") .. "\n", "one\nTWO\nthree\n",
      "Undo discard should restore the file on disk when only a scratch buffer shadows the path")

    pcall(vim.api.nvim_buf_delete, shadow, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "unstage.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "unstage.txt", { "one", "TWO", "three" })
    git_test_command({ "add", "unstage.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "staged", pathspecs = { "unstage.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.unstage(session)
    assert_eq(err, nil, "Unstage hunk action should not error")
    assert_eq(ok, true, "Unstage hunk action should succeed")
    assert_eq(git_mod.read_index(repo, "unstage.txt"), "one\ntwo\nthree\n", "Unstage should restore index content from HEAD")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo unstage hunk should not error")
    assert_eq(ok, true, "Undo unstage hunk should succeed")
    assert_eq(git_mod.read_index(repo, "unstage.txt"), "one\nTWO\nthree\n", "Undo should restore staged index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "add_all.txt", { "one", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "add_all.txt", { "one", "two", "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "add_all.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], nil, "All-mode pure addition should start unstaged")

    local ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "All-mode pure addition stage should not error")
    assert_eq(ok, true, "All-mode pure addition stage should succeed")
    local after_states = actions_mod.staged_chunk_states(session)
    assert_eq(after_states[1], true, "All-mode pure addition should show staged marker after staging")
    assert_eq(git_mod.read_index(repo, "add_all.txt"), "one\ntwo\nthree\n",
      "All-mode pure addition should update the index")

    ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode pure addition toggle unstage should not error")
    assert_eq(ok, true, "All-mode pure addition toggle unstage should succeed")
    local unstaged_states = actions_mod.staged_chunk_states(session)
    assert_eq(unstaged_states[1], nil, "All-mode pure addition should show unstaged marker after toggling again")
    assert_eq(git_mod.read_index(repo, "add_all.txt"), "one\nthree\n",
      "All-mode pure addition toggle unstage should restore the index")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "baseline" })
    commit_baseline(repo)
    write_repo_file(repo, "new_file.txt", { "new one", "new two" })
    git_test_command({ "add", "new_file.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "new_file.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], true, "All-mode staged new file should start staged")

    local ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode staged new file toggle unstage should not error")
    assert_eq(ok, true, "All-mode staged new file toggle unstage should succeed")
    assert_eq(git_mod.read_index(repo, "new_file.txt"), nil,
      "All-mode staged new file toggle unstage should remove the index entry")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "already_staged_add.txt", { "one", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "already_staged_add.txt", { "one", "two", "three" })
    git_test_command({ "add", "already_staged_add.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "already_staged_add.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], true, "All-mode staged added hunk should start staged")

    local ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode staged added hunk toggle unstage should not error")
    assert_eq(ok, true, "All-mode staged added hunk toggle unstage should succeed")
    assert_eq(git_mod.read_index(repo, "already_staged_add.txt"), "one\nthree\n",
      "All-mode staged added hunk toggle unstage should restore the index")
    assert_eq(table.concat(read_file(repo .. "/already_staged_add.txt"), "\n") .. "\n", "one\ntwo\nthree\n",
      "All-mode staged added hunk toggle unstage should leave the worktree content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mixed_staged_add.txt", { "one", "three", "four" })
    commit_baseline(repo)
    write_repo_file(repo, "mixed_staged_add.txt", { "one", "two", "three", "four" })
    git_test_command({ "add", "mixed_staged_add.txt" }, repo)
    write_repo_file(repo, "mixed_staged_add.txt", { "one", "two", "THREE", "four" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "mixed_staged_add.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], true, "All-mode mixed staged added hunk should start staged")

    local ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode mixed staged added hunk toggle unstage should not error")
    assert_eq(ok, true, "All-mode mixed staged added hunk toggle unstage should succeed")
    assert_eq(git_mod.read_index(repo, "mixed_staged_add.txt"), "one\nthree\nfour\n",
      "All-mode mixed staged added hunk toggle unstage should restore only the index hunk")
    assert_eq(table.concat(read_file(repo .. "/mixed_staged_add.txt"), "\n") .. "\n", "one\ntwo\nTHREE\nfour\n",
      "All-mode mixed staged added hunk toggle unstage should leave nearby worktree edits")
  end

  -- All-mode staging anchors on the worktree: once one hunk is staged the
  -- index no longer has HEAD's line numbers, so the next hunk must land at
  -- its index position, not its HEAD position.
  do
    local repo = make_git_repo()
    write_repo_file(repo, "two_hunks.txt", { "a", "b", "c", "d", "e" })
    commit_baseline(repo)
    write_repo_file(repo, "two_hunks.txt", { "a", "X1", "X2", "X3", "b", "c", "d", "Y", "e" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "two_hunks.txt" } }, config.git)))
    local session = make_action_session(queue)
    assert_eq(#session.view.chunks, 2, "Two separated edits make two hunks")
    session.current_chunk = 1
    assert_eq(actions_mod.stage(session), true, "Staging the first hunk succeeds")
    session.current_chunk = 2
    assert_eq(actions_mod.stage(session), true, "Staging the second hunk succeeds")
    assert_eq(git_mod.read_index(repo, "two_hunks.txt"), "a\nX1\nX2\nX3\nb\nc\nd\nY\ne\n",
      "The second hunk lands after d even though the first shifted the index")
    local states = actions_mod.staged_chunk_states(session)
    assert_eq(states[1] == true and states[2] == true, true, "Both hunks show as staged")
  end

  -- A view against a merge base (diffbandit <rev>, compare): committed hunks
  -- cannot be staged, pending ones stage and unstage against HEAD, and the
  -- markers only flag staged changes.
  do
    local repo = make_git_repo()
    git_test_command({ "checkout", "-q", "-b", "main" }, repo)
    write_repo_file(repo, "branch.txt", { "1", "2", "3", "4", "5" })
    commit_baseline(repo)
    git_test_command({ "switch", "-q", "-c", "topic" }, repo)
    write_repo_file(repo, "branch.txt", { "1", "2", "3", "4", "5", "6", "7", "8" })
    git_test_command({ "commit", "-q", "-am", "branch adds 6-8" }, repo)
    write_repo_file(repo, "branch.txt", { "ONE", "2", "3", "4", "5", "6", "7", "8" })
    local merge_base = vim.trim(git_test_command({ "merge-base", "main", "HEAD" }, repo))
    local head_text = "1\n2\n3\n4\n5\n6\n7\n8\n"

    local queue = assert((git_mod.queue({ root = repo, mode = "all", base = merge_base, pathspecs = { "branch.txt" } }, config.git)))
    local session = make_action_session(queue)
    assert_eq(#session.view.chunks, 2, "The view shows the pending edit and the committed addition")
    local states = actions_mod.staged_chunk_states(session)
    assert_eq(states[1] == nil and states[2] == nil, true, "Committed changes are not shown as staged")

    session.current_chunk = 2
    local ok, err = actions_mod.stage(session)
    assert_eq(ok, false, "A committed hunk cannot be staged")
    assert_eq(err, "nothing to stage in this hunk: it is already staged or committed", "The refusal says why")
    assert_eq(git_mod.read_index(repo, "branch.txt"), head_text, "Refusing leaves the index untouched")
    ok, err = actions_mod.unstage(session)
    assert_eq(ok, false, "A committed hunk cannot be unstaged")
    assert_eq(git_mod.read_index(repo, "branch.txt"), head_text, "Unstaging a committed hunk leaves the index untouched")

    session.current_chunk = 1
    assert_eq(actions_mod.stage(session), true, "The pending hunk stages")
    assert_eq(git_mod.read_index(repo, "branch.txt"), "ONE\n2\n3\n4\n5\n6\n7\n8\n", "Only the pending edit reaches the index")
    states = actions_mod.staged_chunk_states(session)
    assert_eq(states[1], true, "The staged pending hunk shows as staged")
    assert_eq(states[2], nil, "The committed hunk still does not")

    session.current_chunk = 1
    assert_eq(actions_mod.toggle_stage(session), true, "Toggling a staged pending hunk unstages it")
    assert_eq(git_mod.read_index(repo, "branch.txt"), head_text, "Unstaging restores HEAD, not the merge base")
  end

  -- Against a merge base, unstaging a staged new file removes it from the
  -- index instead of leaving an empty one.
  do
    local repo = make_git_repo()
    git_test_command({ "checkout", "-q", "-b", "main" }, repo)
    write_repo_file(repo, "keep.txt", { "base" })
    commit_baseline(repo)
    git_test_command({ "switch", "-q", "-c", "topic" }, repo)
    write_repo_file(repo, "keep.txt", { "base", "topic" })
    git_test_command({ "commit", "-q", "-am", "topic" }, repo)
    write_repo_file(repo, "fresh.txt", { "new" })
    git_test_command({ "add", "fresh.txt" }, repo)
    local merge_base = vim.trim(git_test_command({ "merge-base", "main", "HEAD" }, repo))
    local queue = assert((git_mod.queue({ root = repo, mode = "all", base = merge_base, pathspecs = { "fresh.txt" } }, config.git)))
    local session = make_action_session(queue)
    assert_eq(actions_mod.staged_chunk_states(session)[1], true, "The staged new file shows as staged")
    assert_eq(actions_mod.toggle_stage(session), true, "Toggling unstages it")
    assert_eq(git_mod.read_index(repo, "fresh.txt"), nil, "The new file leaves the index")
  end

  -- Before the first commit staging compares with the empty tree, which is
  -- also the view's base: unstaging a new file removes its index entry.
  do
    local repo = make_git_repo()
    write_repo_file(repo, "first.txt", { "one" })
    git_test_command({ "add", "first.txt" }, repo)
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "first.txt" } }, config.git)))
    assert_eq(queue.opts.unborn_head, true, "The repository has no commits yet")
    local session = make_action_session(queue)
    assert_eq(actions_mod.staged_chunk_states(session)[1], true, "The staged file shows as staged")
    assert_eq(actions_mod.toggle_stage(session), true, "Toggling unstages it")
    assert_eq(git_mod.read_index(repo, "first.txt"), nil, "Unstaging removes the entry")
  end
end

do
  local original_notify = vim.notify
  vim.notify = function() end
  local fake = setmetatable({
    file_queue = { entries = { { path = "one" }, { path = "two" } } },
    file_queue_index = 1,
    transitions = {},
  }, Session)
  fake.goto_queue_file = function(self, index, chunk_position)
    self.transitions[#self.transitions + 1] = {
      index = index,
      chunk_position = chunk_position,
    }
    self.file_queue_index = index
    return true
  end

  assert_eq(fake:confirm_file_boundary("next"), true,
    "First next boundary press should be handled")
  assert_eq(#fake.transitions, 0,
    "First next boundary press should only arm the transition")
  assert_eq(fake.pending_file_boundary.direction, "next",
    "First next boundary press should remember direction")
  assert_eq(fake:confirm_file_boundary("next"), true,
    "Second next boundary press should be handled")
  assert_eq(#fake.transitions, 1,
    "Second next boundary press should open the next file")
  assert_eq(fake.transitions[1].index, 2,
    "Second next boundary press should target the next file")
  assert_eq(fake.transitions[1].chunk_position, "top",
    "Next file transition should land at the top of the next file")

  fake.pending_file_boundary = { direction = "next", file_index = 2 }
  fake:confirm_file_boundary("prev")
  assert_eq(fake.pending_file_boundary.direction, "prev",
    "Opposite boundary direction should replace the pending transition")
  assert_eq(#fake.transitions, 1,
    "First previous boundary press should not immediately transition")
  vim.notify = original_notify
end

do
  local fake = {
    file_queue = { entries = { { path = "one" }, { path = "two" }, { path = "three" } }, index = 2 },
    file_queue_index = 2,
    transitions = {},
  }
  function fake:goto_queue_file(index, chunk_position, opts)
    self.transitions[#self.transitions + 1] = {
      index = index,
      chunk_position = chunk_position,
      preserve_focus = opts and opts.preserve_focus,
    }
    self.file_queue_index = index
    return true
  end

  panel_mod.navigate_file(fake, "next")
  assert_eq(fake.transitions[1].index, 3,
    "Panel ]f navigation should move to the next queue file")
  assert_eq(fake.transitions[1].chunk_position, "top",
    "Panel ]f navigation should open the next file at the top")
  assert_eq(fake.transitions[1].preserve_focus, true,
    "Panel ]f navigation should preserve panel focus")

  panel_mod.navigate_file(fake, "prev")
  assert_eq(fake.transitions[2].index, 2,
    "Panel [f navigation should move to the previous queue file")
end

do
  local fake = {
    panel = { mode = "review" },
    closed = false,
  }
  function fake:close()
    self.closed = true
  end
  panel_mod.close(fake)
  assert_eq(fake.closed, false,
    "Hiding a review panel should not close the owning diff session (q calls the host's close)")
end

-- Document-navigation keymaps survive LspAttach handlers that install
-- buffer-local diagnostic maps ([d/]d) over the session's maps.
do
  local right_path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "one" }, right_path)
  local right_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value("swapfile", false, { buf = right_buf })
  vim.api.nvim_buf_set_name(right_buf, right_path)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { "one" })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = right_buf })

  local session = assert((Session.start({
    left = source_mod.from_lines({ "zero" }, nil, "left"),
    right = source_mod.from_lines({ "one" }, right_path, "right", {
      editable = { target = "buffer", bufnr = right_buf, path = right_path },
    }),
  }, config, {})))
  local top_key = config.navigation.document_keys.top
  local session_cb = buffer_keymap_callback(session.right_buf, "n", top_key)
  assert_eq(type(session_cb), "function",
    "Session should map the document-top key on the right buffer")

  local foreign = function() end
  vim.keymap.set("n", top_key, foreign, { buffer = session.right_buf })
  assert_eq(buffer_keymap_callback(session.right_buf, "n", top_key), foreign,
    "A buffer-local LSP-style map should shadow the session map")

  vim.api.nvim_exec_autocmds("LspAttach", { buffer = session.right_buf })
  vim.wait(500, function()
    return buffer_keymap_callback(session.right_buf, "n", top_key) == session_cb
  end, 10)
  assert_eq(buffer_keymap_callback(session.right_buf, "n", top_key), session_cb,
    "LspAttach should re-assert the session's document-navigation map")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = right_buf })
  session:close()
  assert_eq(buffer_keymap_callback(right_buf, "n", top_key), foreign,
    "Closing the session should restore the shadowing diagnostic map")
  pcall(vim.api.nvim_buf_delete, right_buf, { force = true })
end

-- Git file-queue ]f then ]c keeps both panes aligned on the chunk navigation
-- anchors, with the user's global scrolloff kept above them.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local function many(n)
    local lines = {}
    for i = 1, n do
      lines[i] = "line " .. i
    end
    return lines
  end
  local function with_inserts(n, at, count)
    local lines = many(n)
    for k = 1, count do
      table.insert(lines, at, "insert-" .. k)
    end
    return lines
  end
  local repo = make_git_repo()
  write_repo_file(repo, "first.txt", many(80))
  write_repo_file(repo, "second.txt", many(90))
  commit_baseline(repo)
  write_repo_file(repo, "first.txt", with_inserts(80, 40, 8))
  write_repo_file(repo, "second.txt", with_inserts(90, 55, 10))

  local previous_scrolloff = vim.o.scrolloff
  vim.o.scrolloff = 8
  local queue = assert((git_mod.queue({ root = repo, mode = "unstaged" }, config.git)))
  assert_eq(#(queue.entries or {}), 2, "Queue should include both modified files")
  local loaded = assert((select(1, queue.load(1))))
  local session = assert((Session.start({
    left = loaded.left,
    right = loaded.right,
  }, config, {
    queue = queue,
    chunk_position = "top",
  })))

  session:goto_next_chunk()
  local chunk = session.view.chunks[session.current_chunk]
  local left_anchor, right_anchor = session:chunk_navigation_anchors(chunk)
  local context = 8
  assert_eq(win_topline(session.left_win), math.max(1, left_anchor - context),
    "First-file ]c should align the left pane")
  assert_eq(win_topline(session.right_win), math.max(1, right_anchor - context),
    "First-file ]c should align the right pane")

  local first_index = session.file_queue_index or 1
  session:goto_next_file()
  assert_eq(session.file_queue_index, first_index + 1,
    "]f should open the next git queue file")
  assert_eq(session.current_chunk, 0, "]f should land at the top of the next file")
  session:goto_next_chunk()
  chunk = session.view.chunks[session.current_chunk]
  left_anchor, right_anchor = session:chunk_navigation_anchors(chunk)
  assert_eq(win_topline(session.left_win), math.max(1, left_anchor - context),
    "]c after ]f should align the left pane")
  assert_eq(win_topline(session.right_win), math.max(1, right_anchor - context),
    "]c after ]f should align the right pane")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
  session:close()
  vim.o.scrolloff = previous_scrolloff
end

-- Three-way merge gutters follow their content panes on scroll, matching the
-- two-way session's owned gutter synchronization.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local many = {}
  for i = 1, 80 do
    many[i] = "line " .. i
  end
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local merge_session = assert((merge_mod.start({
    root = repo,
    path = "merge-scroll.txt",
    base_lines = many,
    local_lines = many,
    remote_lines = many,
    result_lines = many,
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))

  -- Headless nvim never emits WinScrolled (it is checked during UI redraw),
  -- so fire it explicitly with the scrolled window as <amatch>.
  vim.api.nvim_set_current_win(merge_session.result_win)
  vim.api.nvim_win_set_cursor(merge_session.result_win, { 50, 0 })
  vim.api.nvim_win_call(merge_session.result_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(merge_session.result_win) })
  vim.wait(1000, function()
    local top = win_topline(merge_session.result_win)
    return top > 1
      and win_topline(merge_session.result_left_num_win) == top
      and win_topline(merge_session.result_right_num_win) == top
  end, 10)
  local result_top = win_topline(merge_session.result_win)
  assert_ne(result_top, 1, "Scrolling the merge result pane should move its topline")
  assert_eq(win_topline(merge_session.result_left_num_win), result_top,
    "Merge result left number pane should follow the result pane topline")
  assert_eq(win_topline(merge_session.result_right_num_win), result_top,
    "Merge result right number pane should follow the result pane topline")

  vim.api.nvim_set_current_win(merge_session.local_win)
  vim.api.nvim_win_set_cursor(merge_session.local_win, { 30, 0 })
  vim.api.nvim_win_call(merge_session.local_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(merge_session.local_win) })
  vim.wait(1000, function()
    local top = win_topline(merge_session.local_win)
    return top > 1
      and win_topline(merge_session.local_num_win) == top
      and win_topline(merge_session.local_result_connector_win) == top
  end, 10)
  local local_top = win_topline(merge_session.local_win)
  assert_ne(local_top, 1, "Scrolling the merge local pane should move its topline")
  assert_eq(win_topline(merge_session.local_num_win), local_top,
    "Merge local number pane should follow the local pane topline")
  assert_eq(win_topline(merge_session.local_result_connector_win), local_top,
    "Merge local connector should follow the local pane topline")
  assert_eq(win_topline(merge_session.result_left_num_win), win_topline(merge_session.result_win),
    "Scrolling the local pane should leave result gutters synced to the result pane")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()
end


-- ==============================================================================
-- Merge: apply non-conflicting changes against an edited result
-- ==============================================================================
-- gA used to splice each hunk at its BASE line numbers into the current
-- result. After a conflict resolution changed the line count above a hunk it
-- landed at the wrong rows (and a second gA duplicated every hunk).
do
  local text_mod = require("diffbandit.util.text")
  local base = { "a", "b", "c", "d", "e", "f", "g", "h" }
  local local_lines = { "a", "b1", "b2", "c", "d", "L", "e", "f", "g", "h" }
  local remote_lines = { "a", "B", "c", "d", "e", "f", "G", "h" }
  local conflicts, non_conflicting = merge_model_mod.build_regions(base, local_lines, remote_lines, {})
  assert_eq(#conflicts, 1, "fixture: line b conflicts")
  assert_eq(#non_conflicting, 2, "fixture: local insert after d + remote change of g")

  local function apply(result)
    local plan = merge_model_mod.plan_non_conflicting(base, result, non_conflicting, {})
    for _, edit in ipairs(plan.edits) do
      result = text_mod.replace_range(result, edit.start, edit.count, edit.replacement)
    end
    return result, plan
  end

  local pristine = apply(vim.deepcopy(base))
  assert_eq(table.concat(pristine, ","), "a,b,c,d,L,e,f,G,h",
    "non-conflicting hunks apply at base rows to an untouched result")

  -- Conflict resolved with local first: b -> b1,b2 shifts everything by +1.
  local resolved = { "a", "b1", "b2", "c", "d", "e", "f", "g", "h" }
  local applied, plan = apply(resolved)
  assert_eq(table.concat(applied, ","), "a,b1,b2,c,d,L,e,f,G,h",
    "non-conflicting hunks follow a conflict resolution that changed the line count")
  assert_eq(plan.skipped, 0, "nothing was in the result yet")

  local again, replan = apply(applied)
  assert_eq(table.concat(again, ","), "a,b1,b2,c,d,L,e,f,G,h",
    "applying non-conflicting changes twice must not duplicate them")
  assert_eq(#replan.edits, 0, "second apply has nothing to do")
  assert_eq(replan.skipped, 2, "both hunks are recognised as already applied")
end

-- ==============================================================================
-- Merge: conflict regions track result edits
-- ==============================================================================
-- Accepting a pair hunk only updated region rows when it exactly covered the
-- current conflict, so a partial accept (or a non-conflicting >>/<<) left
-- every later conflict pointing at stale rows; and filling an empty
-- (insertion) region kept its "after row N" start, off by one.
do
  local region = { result_start = 5, result_count = 0 }
  merge_model_mod.resize_region(region, 3)
  assert_eq(region.result_start, 6, "filling an insertion region starts at its first new row")
  assert_eq(region.result_count, 3, "filled region count")
  merge_model_mod.resize_region(region, 0)
  assert_eq(region.result_start, 5, "emptying a region returns to the after-row anchor")

  local function regions()
    return {
      { result_start = 2, result_count = 1 },   -- row 2
      { result_start = 5, result_count = 0 },   -- insertion after row 5
      { result_start = 8, result_count = 2 },   -- rows 8-9
    }
  end
  local function spans(rs)
    local out = {}
    for i, r in ipairs(rs) do
      out[i] = r.result_start .. "+" .. r.result_count
    end
    return table.concat(out, " ")
  end

  local rs = regions()
  merge_model_mod.track_result_edit(rs, 3, 0, 2) -- insert 2 rows after row 3
  assert_eq(spans(rs), "2+1 7+0 10+2", "an insertion above shifts later regions only")

  rs = regions()
  merge_model_mod.track_result_edit(rs, 8, 0, 3) -- insert 3 rows after row 8 (inside rows 8-9)
  assert_eq(spans(rs), "2+1 5+0 8+5", "a partial accept inside a region grows that region")

  rs = regions()
  merge_model_mod.track_result_edit(rs, 5, 0, 4) -- fill the insertion region
  assert_eq(spans(rs), "2+1 6+4 12+2", "filling an insertion region moves its start and shifts later ones")

  rs = regions()
  merge_model_mod.track_result_edit(rs, 8, 2, 0) -- delete rows 8-9 (the whole region)
  assert_eq(spans(rs), "2+1 5+0 7+0", "deleting a whole region leaves an after-row anchor")
end

-- Performance paths: filesystem root discovery, concurrent listing with the
-- stage snapshot, and blob batching must answer exactly what git answers.
do
  local process_mod = require("diffbandit.util.process")
  local results = process_mod.run_many({ { "git", "--version" }, false, { "git", "no-such-command-xyz" } })
  assert_eq(type(results[1][1]), "string", "run_many returns each command's output in order")
  assert_eq(results[2][1], nil, "a false slot yields an empty result")
  assert_eq(results[3][1], nil, "a failing command has no output")
  assert_eq(type(results[3][2]), "string", "a failing command reports its error")

  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "one" })
  write_repo_file(repo, "sub/b.txt", { "two" })
  commit_baseline(repo)
  local git_root = vim.trim(git_test_command({ "rev-parse", "--show-toplevel" }, repo .. "/sub"))
  assert_eq(git_mod.find_root(repo .. "/sub"), git_root, "filesystem discovery finds git's toplevel from a subdirectory")
  assert_eq(git_mod.find_root(repo .. "/sub/b.txt"), git_root, "discovery starts from a file's directory")
  local worktree = vim.fn.tempname()
  git_test_command({ "worktree", "add", "-q", worktree }, repo)
  local worktree_root = vim.trim(git_test_command({ "rev-parse", "--show-toplevel" }, worktree))
  assert_eq(git_mod._private.discover_root(worktree), worktree_root, "a linked worktree's .git file marks its root")
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  local saved_ceiling = vim.env.GIT_CEILING_DIRECTORIES
  vim.env.GIT_CEILING_DIRECTORIES = vim.fn.fnamemodify(outside, ":h")
  assert_eq(git_mod._private.discover_root(outside), nil, "discovery defers to git when the environment redirects it")
  assert_eq(git_mod.find_root(outside), nil, "a directory outside any repository has no root")
  vim.env.GIT_CEILING_DIRECTORIES = saved_ceiling

  write_repo_file(repo, "a.txt", { "one", "staged" })
  git_test_command({ "add", "a.txt" }, repo)
  write_repo_file(repo, "a.txt", { "one", "staged", "unstaged" })
  write_repo_file(repo, "sub/b.txt", { "two", "unstaged" })
  write_repo_file(repo, "new.txt", { "new" })
  local queue = assert(git_mod.queue({ root = repo, mode = "all" }, {}))
  assert_ne(queue.stage_snapshot, nil, "a working-tree queue carries a stage snapshot")
  local from_snapshot = git_mod.queue_stage_states(queue)
  local from_git = git_mod.file_stage_states(queue.root, queue.entries, queue.opts)
  assert_eq(table.concat(from_snapshot, ","), table.concat(from_git, ","), "snapshot stage states match git's")
  assert_eq(table.concat(from_git, ","), "partial,unstaged,unstaged", "a.txt partial, new.txt and sub/b.txt unstaged")
  assert_eq(git_mod.snapshot_has_staged_changes(queue, "a.txt"), true, "the snapshot knows a.txt has staged changes")
  assert_eq(git_mod.snapshot_has_staged_changes(queue, "sub/b.txt"), false, "the snapshot knows sub/b.txt has none")

  -- A mutating git command retires the snapshot even within the same tick.
  git_mod.stage_file(repo, { path = "sub/b.txt" })
  assert_eq(git_mod.snapshot_has_staged_changes(queue, "sub/b.txt"), nil, "a mutation invalidates the snapshot")
  assert_eq(git_mod.queue_stage_states(queue)[3], "staged", "after invalidation stage states come from git")

  -- Loading a file batches its HEAD and index blobs for the stage markers.
  queue = assert(git_mod.queue({ root = repo, mode = "all" }, {}))
  local loaded = assert(queue.load(1))
  local blobs = loaded.left.git_stage_blobs
  assert_ne(blobs, nil, "a modified file's sources carry its HEAD and index blobs")
  assert_eq(blobs.head, "one\n", "HEAD blob")
  assert_eq(blobs.index, "one\nstaged\n", "index blob")
  assert_eq(blobs.generation, git_mod.generation(), "blobs are current until the next mutation")
  assert_eq(loaded.left.lines[1], "one", "the left side reads HEAD from the batched blob")
  local untracked_loaded = assert(queue.load(2))
  assert_eq(untracked_loaded.left.git_stage_blobs, nil, "untracked files have no stage markers to compare")
end

-- git.current_branch() names the checked-out branch, or the detached commit.
do
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "one" })
  commit_baseline(repo)
  git_test_command({ "switch", "-q", "-c", "topic" }, repo)
  assert_eq(git_mod.current_branch(repo), "topic", "current_branch names the checked-out branch")
  git_test_command({ "switch", "-q", "--detach" }, repo)
  local short = vim.trim(git_test_command({ "rev-parse", "--short", "HEAD" }, repo))
  assert_eq(git_mod.current_branch(repo), "detached " .. short, "a detached HEAD reports its commit")
end
