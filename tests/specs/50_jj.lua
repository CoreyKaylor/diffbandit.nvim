-- Suite: jj (Jujutsu) backend against real jj repositories. Skipped when jj
-- is not installed.

if vim.fn.executable("jj") ~= 1 then
  print("SKIP jj specs: jj is not installed")
else
  local vcs = require("diffbandit.vcs")
  local jj_mod = require("diffbandit.jj")

  local saved_jj_config = vim.env.JJ_CONFIG
  local jj_config_path = vim.fn.tempname() .. ".toml"
  vim.fn.writefile({
    "[user]",
    'name = "DiffBandit Test"',
    'email = "diffbandit@example.com"',
  }, jj_config_path)
  vim.env.JJ_CONFIG = jj_config_path

  local function jj_run(args, cwd)
    local cmd = { "jj", "--no-pager", "--color=never" }
    vim.list_extend(cmd, args)
    local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
    assert_eq(result.code, 0, "jj " .. table.concat(args, " ") .. " should succeed: " .. tostring(result.stderr))
    return result.stdout or ""
  end

  local function jj_status(args, cwd)
    local cmd = { "jj", "--no-pager", "--color=never" }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { cwd = cwd, text = true, timeout = 30000 }):wait()
  end

  local function make_jj_repo(opts)
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    local args = { "git", "init" }
    if opts and opts.colocate then
      args[#args + 1] = "--colocate"
    end
    args[#args + 1] = "."
    jj_run(args, repo)
    return repo
  end

  local function write(repo, path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(repo .. "/" .. path, ":h"), "p")
    vim.fn.writefile(lines, repo .. "/" .. path)
  end

  local function show(repo, rev, path)
    return jj_run({ "file", "show", "-r", rev, "--", 'root-file:"' .. path .. '"' }, repo)
  end

  local function make_action_session(queue)
    local loaded = select(1, queue.load(queue.index or 1))
    local hunks, err = diff.compute_hunks(loaded.left.text, loaded.right.text, config.diff)
    assert_eq(err, nil, "jj action session diff should compute")
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
      local next_hunks = diff.compute_hunks(sources.left.text, sources.right.text, config.diff)
      self.left = sources.left
      self.right = sources.right
      self.hunks = next_hunks
      self.view = view.build(sources.left.lines, sources.right.lines, next_hunks, config)
      self.current_chunk = self.view.chunks[1] and math.min((opts and opts.preferred_chunk) or 1, #self.view.chunks) or 0
      return true, nil
    end
    return fake
  end

  -- Detection: jj workspaces (including colocated ones) route to jj.
  do
    local repo = make_jj_repo()
    assert_eq((vcs.detect(repo)), "jj", "A jj workspace routes to the jj backend")
    vim.fn.mkdir(repo .. "/sub/dir", "p")
    assert_eq((vcs.detect(repo .. "/sub/dir")), "jj", "Subdirectories of a jj workspace route to jj")
    assert_eq(vcs.find_root(repo .. "/sub/dir"), (vim.uv or vim.loop).fs_realpath(repo), "jj root resolves from a subdirectory")
    local colocated = make_jj_repo({ colocate = true })
    assert_eq((vcs.detect(colocated)), "jj", "Colocated repos prefer jj")
    local saved = state_mod.get_config()
    state_mod.set_config(vim.tbl_deep_extend("force", saved, { vcs = { prefer = "git" } }))
    assert_eq((vcs.detect(colocated)), "git", "vcs.prefer = git forces the git backend")
    state_mod.set_config(saved)
    local plain = make_git_repo()
    assert_eq((vcs.detect(plain)), "git", "Plain git repos route to git")
  end

  -- Queues: unstaged (@- -> @) lists modify/rename/add/delete with jj labels.
  local repo = make_jj_repo()
  write(repo, "f.txt", { "one", "two", "three", "four", "five" })
  write(repo, "keep.txt", { "keep" })
  write(repo, "gone.txt", { "gone" })
  jj_run({ "commit", "-m", "base" }, repo)
  -- Squash workflow: an empty staging change between the base and @.
  jj_run({ "new", "--insert-before", "@", "--no-edit" }, repo)
  write(repo, "f.txt", { "one", "TWO", "three", "four", "FIVE" })
  os.rename(repo .. "/keep.txt", repo .. "/kept.txt")
  os.remove(repo .. "/gone.txt")
  write(repo, "new.txt", { "new" })

  do
    local queue = assert((vcs.queue({ root = repo }, config.git)))
    assert_eq(queue.vcs, "jj", "jj queues say which backend built them")
    assert_eq(queue.kind, "git", "jj queues keep the repository-queue kind")
    assert_eq(queue.opts.mode, "unstaged", "jj defaults to the unstaged (@- -> @) view")
    local by_path = {}
    for index, entry in ipairs(queue.entries) do
      by_path[entry.path] = { entry = entry, index = index }
    end
    assert_eq(by_path["f.txt"].entry.status, "M", "Modified file")
    assert_eq(by_path["kept.txt"].entry.status, "R", "Renamed file")
    assert_eq(by_path["kept.txt"].entry.old_path, "keep.txt", "Rename keeps its source path")
    assert_eq(by_path["gone.txt"].entry.status, "D", "Deleted file")
    assert_eq(by_path["new.txt"].entry.status, "A", "Added file")

    local loaded = assert((queue.load(by_path["f.txt"].index)))
    assert_eq(loaded.left.text, "one\ntwo\nthree\nfour\nfive\n", "Unstaged left side reads @-")
    assert_eq(loaded.left.label, "f.txt (@-)", "Left label names @-")
    assert_eq(loaded.right.git_target, "worktree", "Right side is the working copy")
    assert_eq(loaded.right.editable ~= nil, true, "The working copy side is editable")
    loaded = assert((queue.load(by_path["new.txt"].index)))
    assert_eq(loaded.left.git_target, "absent", "Added files are absent on the left without an index")
    loaded = assert((queue.load(by_path["gone.txt"].index)))
    assert_eq(loaded.right.git_target, "absent", "Deleted files are absent on the right")
  end

  -- Hunk staging moves the hunk into @- and leaves @ untouched.
  do
    local queue = assert((vcs.queue({ root = repo, mode = "unstaged", pathspecs = { "f.txt" } }, config.git)))
    assert_eq(#queue.entries, 1, "Pathspec narrows the jj queue")
    local session = make_action_session(queue)
    assert_eq(#session.view.chunks, 2, "Two separated hunks")
    local ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "jj stage hunk should not error")
    assert_eq(ok, true, "jj stage hunk should succeed")
    assert_eq(show(repo, "@-", "f.txt"), "one\nTWO\nthree\nfour\nfive\n", "Staging writes only the hunk into @-")
    assert_eq(show(repo, "@", "f.txt"), "one\nTWO\nthree\nfour\nFIVE\n", "Staging keeps @'s content")
    assert_eq(table.concat(read_file(repo .. "/f.txt"), "|"), "one|TWO|three|four|FIVE", "Staging does not touch the working copy")
    assert_eq(vcs.file_stage_state(repo, { path = "f.txt" }), "partial", "Half-staged file is partial")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "jj undo stage should not error")
    assert_eq(show(repo, "@-", "f.txt"), "one\ntwo\nthree\nfour\nfive\n", "Undo restores @-")
    assert_eq(show(repo, "@", "f.txt"), "one\nTWO\nthree\nfour\nFIVE\n", "Undo keeps @")
  end

  -- all mode (@-- -> @) unstages a hunk that is in @-.
  do
    assert(vcs.write_index(repo, "f.txt", "one\nTWO\nthree\nfour\nfive\n"))
    local queue = assert((vcs.queue({ root = repo, mode = "all", pathspecs = { "f.txt" } }, config.git)))
    assert_eq(queue.opts.base, "@--", "all mode diffs from @--")
    local session = make_action_session(queue)
    local states = actions_mod.staged_chunk_states(session)
    assert_eq(states[1], true, "The staged hunk is marked staged in all mode")
    assert_eq(states[2] == true, false, "The unstaged hunk is not")
    local ok, err = actions_mod.unstage(session)
    assert_eq(err, nil, "jj unstage hunk should not error")
    assert_eq(ok, true, "jj unstage hunk should succeed")
    assert_eq(show(repo, "@-", "f.txt"), "one\ntwo\nthree\nfour\nfive\n", "Unstaging moves the hunk back out of @-")
    assert_eq(show(repo, "@", "f.txt"), "one\nTWO\nthree\nfour\nFIVE\n", "Unstaging keeps @")
  end

  -- all mode stages a hunk at its @- position (reads @-- / @- / @ blobs).
  do
    local queue = assert((vcs.queue({ root = repo, mode = "all", pathspecs = { "f.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "jj all-mode stage hunk should not error")
    assert_eq(ok, true, "jj all-mode stage hunk should succeed")
    assert_eq(show(repo, "@-", "f.txt"), "one\nTWO\nthree\nfour\nfive\n", "All-mode staging writes only the hunk into @-")
    assert_eq(show(repo, "@", "f.txt"), "one\nTWO\nthree\nfour\nFIVE\n", "All-mode staging keeps @")
    assert(vcs.write_index(repo, "f.txt", "one\ntwo\nthree\nfour\nfive\n"))
  end

  -- File-level stage/unstage and discard.
  do
    local ok, err = vcs.stage_file(repo, { path = "new.txt" })
    assert_eq(err, nil, "Stage file should not error")
    assert_eq(show(repo, "@-", "new.txt"), "new\n", "Stage file squashes it into @-")
    assert_eq(vcs.file_stage_state(repo, { path = "new.txt" }), "staged", "Fully staged file")
    ok, err = vcs.unstage_file(repo, { path = "new.txt" })
    assert_eq(err, nil, "Unstage file should not error")
    assert_eq(jj_status({ "file", "show", "-r", "@-", "--", 'root-file:"new.txt"' }, repo).code ~= 0, true,
      "Unstage file removes it from @-")
    assert_eq(show(repo, "@", "new.txt"), "new\n", "Unstage file keeps it in @")
    local pending = require("diffbandit.util.pending")
    local toggled
    vcs.toggle_file_stage_async(repo, { path = "new.txt" }, {}, "unstaged", function(done_ok)
      toggled = done_ok
    end)
    assert_eq(pending.idle(), false, "Async jj toggle holds a pending token until it runs")
    vim.wait(5000, function()
      return toggled ~= nil
    end)
    assert_eq(toggled, true, "Async jj toggle stages the file")
    assert_eq(pending.idle(), true, "Async jj toggle releases its pending token")
    ok, err = vcs.unstage_file(repo, { path = "new.txt" })
    assert_eq(err, nil, "Unstage after the async toggle")
    ok, err = vcs.discard_worktree_file(repo, { path = "gone.txt" })
    assert_eq(ok, true, "Discard restores a deleted file: " .. tostring(err))
    assert_eq(read_file(repo .. "/gone.txt")[1], "gone", "Discarded deletion is back on disk")
  end

  -- Commit with a staging change: describe it and open a fresh one; with
  -- nothing staged, all of @ is committed through it.
  do
    assert(vcs.write_index(repo, "f.txt", "one\nTWO\nthree\nfour\nfive\n"))
    assert_eq(vcs.last_commit_message(repo), nil, "An undescribed staging change has no amend message")
    local _, amend_err = vcs.amend_base(repo)
    assert_eq(amend_err, "@- holds staged changes: commit them before amending", "Amend refuses over staged work")
    local ok, err = vcs.commit(repo, "add TWO")
    assert_eq(err, nil, "jj commit should not error")
    assert_eq(ok, true, "jj commit should succeed")
    local log = assert(vcs.log(repo, { rev = "::@", max_count = 4 }))
    assert_eq(log[1].working_copy, true, "@ is still the working copy")
    assert_eq(log[2].subject, "(no description set)", "A fresh empty staging change sits under @")
    assert_eq(log[2].empty, true, "The staging change is empty")
    assert_eq(log[3].subject, "add TWO", "The staged commit got the message")
    assert_eq(log[4].subject, "base", "The base commit is untouched")
    assert_eq(show(repo, "@-", "f.txt"), "one\nTWO\nthree\nfour\nfive\n", "Only the staged hunk was committed")
    assert_eq(show(repo, "@", "f.txt"), "one\nTWO\nthree\nfour\nFIVE\n", "Commit keeps @")
    assert_eq(vcs.has_any_staged_changes(repo), false, "Nothing is staged after the commit")

    ok, err = vcs.commit(repo, "everything else")
    assert_eq(err, nil, "Committing with nothing staged commits all of @")
    log = assert(vcs.log(repo, { rev = "::@", max_count = 3 }))
    assert_eq(log[2].empty, true, "A fresh staging change again")
    assert_eq(log[3].subject, "everything else", "The rest of @ went into the commit")
    assert_eq(show(repo, "@--", "f.txt"), "one\nTWO\nthree\nfour\nFIVE\n", "It holds @'s content")
    _, err = vcs.commit(repo, "empty")
    assert_eq(err, "nothing to commit", "An empty working copy has nothing to commit")
  end

  -- A described @- is the previous commit: it is never staged into by
  -- accident. Staging from the unstaged view starts a staging change; other
  -- views refuse; amend opts in.
  do
    local drepo = make_jj_repo()
    write(drepo, "d.txt", { "1", "2", "3", "4", "5" })
    jj_run({ "commit", "-m", "first" }, drepo)
    write(drepo, "d.txt", { "1", "TWO", "3", "4", "FIVE" })
    local entries = assert((vcs.queue({ root = drepo }, config.git))).entries
    assert_eq(vcs.file_stage_states(drepo, entries, {})[1], "unstaged",
      "A described @- does not show its files as staged")

    local queue = assert((vcs.queue({ root = drepo, mode = "all" }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.stage(session)
    assert_eq(ok, false, "The all view refuses to stage into a described @-")
    assert_eq(err:find("turn on amend", 1, true) ~= nil, true, "The refusal explains amend")

    queue = assert((vcs.queue({ root = drepo, mode = "unstaged" }, config.git)))
    session = make_action_session(queue)
    ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "Staging from the unstaged view starts a staging change")
    local log = assert(vcs.log(drepo, { rev = "::@", max_count = 3 }))
    assert_eq(log[2].subject, "(no description set)", "The new staging change sits under @")
    assert_eq(log[3].subject, "first", "The described commit is now @--")
    assert_eq(show(drepo, "@--", "d.txt"), "1\n2\n3\n4\n5\n", "The described commit was not modified")
    assert_eq(show(drepo, "@-", "d.txt"), "1\nTWO\n3\n4\n5\n", "The hunk went into the staging change")
    ok, err = vcs.commit(drepo, "second")
    assert_eq(err, nil, "Commit the staging change")

    -- After the commit @- is an empty staging change over "second"; turning
    -- amend on abandons it so "second" is @- again. @ still holds FIVE.
    assert_eq(vcs.amend_base(drepo), "@--", "Amend diffs @- against @--")
    log = assert(vcs.log(drepo, { rev = "@-", max_count = 1 }))
    assert_eq(log[1].subject, "second", "The empty staging change was abandoned for amend")
    assert_eq(vcs.last_commit_message(drepo), "second", "Amend starts from @-'s description")
    ok, err = vcs.stage_file(drepo, { path = "d.txt" }, { mode = "all", amend_mode = true })
    assert_eq(err, nil, "Amend mode stages straight into the described @-")
    assert_eq(show(drepo, "@-", "d.txt"), "1\nTWO\n3\n4\nFIVE\n", "Amend staging rewrote @-")
    ok, err = vcs.commit(drepo, "second, amended", { amend = true })
    assert_eq(err, nil, "Amend commit")
    log = assert(vcs.log(drepo, { rev = "@-", max_count = 1 }))
    assert_eq(log[1].subject, "second, amended", "Amend commit rewrote @-'s description")

    write(drepo, "d.txt", { "six" })
    ok, err = vcs.commit(drepo, "third")
    assert_eq(err, nil, "Without a staging change, commit is `jj commit`")
    log = assert(vcs.log(drepo, { rev = "@-", max_count = 1 }))
    assert_eq(log[1].subject, "third", "jj commit described the working copy")
    assert_eq(show(drepo, "@-", "d.txt"), "six\n", "It holds the working copy")
  end

  -- Reviews: commit review, compare, revision checks, log.
  do
    assert_eq(vcs.is_revision(repo, "@-"), true, "@- is a revision")
    assert_eq(vcs.is_revision(repo, "f.txt"), false, "A path is not a revision")
    assert_eq(vcs.is_revision(repo, "all()"), false, "A multi-commit revset is not a single revision")
    -- @- is the empty staging change left by the last commit.
    local queue = assert((vcs.commit_queue(repo, "@--", {}, config.git)))
    assert_eq(queue.opts.read_only, true, "Commit review is read-only")
    assert_eq(queue.opts.review.kind, "commit", "Commit review kind")
    local paths = vim.tbl_map(function(entry)
      return entry.path
    end, queue.entries)
    assert_eq(vim.tbl_contains(paths, "f.txt"), true, "Commit review lists the commit's files")
    -- Reviews of @ snapshot first: a file written just now is current.
    write(repo, "fresh.txt", { "fresh" })
    local wc, wc_err = vcs.commit_queue(repo, "@", {}, config.git)
    assert_eq(wc_err, nil, "Review of @")
    local fresh
    for index, entry in ipairs(wc.entries) do
      if entry.path == "fresh.txt" then
        fresh = assert((wc.load(index)))
      end
    end
    assert_eq(fresh and fresh.right.text, "fresh\n", "A review of @ sees unsnapshotted files")
    os.remove(repo .. "/fresh.txt")
    local compare = assert((vcs.compare_queue(repo, "root()", "@--", { direct = true }, config.git)))
    assert_eq(compare.opts.review.kind, "compare", "Compare review kind")
    local loaded = assert((compare.load(1)))
    assert_eq(loaded.left.git_target, "absent", "root() has no files")
  end

  -- Launcher in a jj workspace.
  do
    local launcher = require("diffbandit.launcher")
    write(repo, "f.txt", { "launch" })
    local session = assert((launcher.launch({}, { cwd = repo })))
    assert_eq(session.file_queue.vcs, "jj", "The launcher opens the jj backend in a jj workspace")
    session:close()
    for _, panel in pairs(state_mod.panels) do
      if panel and not panel.disposed and panel.close then
        pcall(panel.close, panel)
      end
    end
    session = assert((launcher.launch({ "show", "@--" }, { cwd = repo })))
    assert_eq(session.file_queue.opts.review.kind, "commit", "show <rev> opens a jj commit review")
    session:close()
  end

  -- Conflicts in @ are listed as unmerged entries.
  do
    local crepo = make_jj_repo()
    write(crepo, "c.txt", { "1", "2", "3" })
    jj_run({ "commit", "-m", "base" }, crepo)
    local base = vim.trim(jj_run({ "log", "--no-graph", "-r", "@-", "-T", "change_id" }, crepo))
    write(crepo, "c.txt", { "1", "L", "3" })
    jj_run({ "commit", "-m", "left" }, crepo)
    local left = vim.trim(jj_run({ "log", "--no-graph", "-r", "@-", "-T", "change_id" }, crepo))
    jj_run({ "new", base }, crepo)
    write(crepo, "c.txt", { "1", "R", "3" })
    jj_run({ "commit", "-m", "right" }, crepo)
    local right = vim.trim(jj_run({ "log", "--no-graph", "-r", "@-", "-T", "change_id" }, crepo))
    jj_run({ "new", left, right }, crepo)
    local entries = jj_mod.unmerged_entries(crepo, {})
    assert_eq(#entries, 1, "One conflicted file")
    assert_eq(entries[1].path, "c.txt", "Conflicted path")
    assert_eq(entries[1].status, "U", "Conflicts are unmerged entries")
    assert_eq((jj_mod.has_unmerged(crepo)), true, "has_unmerged sees jj conflicts")
    local ok, err = vcs.commit(crepo, "nope")
    assert_eq(ok, false, "Commit refuses while conflicts remain")
    assert_eq(err, "merge conflicts must be resolved before committing", "Conflict refusal message")

    local queue = assert((vcs.queue({ root = crepo }, config.git)))
    assert_eq(queue.entries[1].status, "U", "The conflicted file shows as unmerged in the review queue")

    local stages = assert((vcs.conflict_stages(crepo, "c.txt")))
    assert_eq(stages.base, "1\n2\n3\n", "Conflict base side")
    assert_eq(stages.local_text, "1\nL\n3\n", "Conflict first side")
    assert_eq(stages.remote, "1\nR\n3\n", "Conflict second side")
    assert_eq(stages.labels.left:find("left", 1, true) ~= nil, true, "Side labels come from jj's markers")

    local session = assert((merge_mod.start_for_path(crepo .. "/c.txt", {}, config)))
    assert_eq(session.host.kind, "jj", "jj workspaces get the jj merge host")
    assert_eq(#session.conflicts, 1, "The merge host sees the conflict")
    assert_eq(session:build_status_lines().remote:find("right", 1, true) ~= nil, true, "Header names the second side")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, { "1", "LR", "3" })
    assert_eq(session:resolve(), true, "Resolving writes the working copy")
    session:close()
    assert_eq(#jj_mod.unmerged_entries(crepo, {}), 0, "jj sees the conflict as resolved after the write")
    assert_eq(vim.trim(jj_run({ "file", "show", "-r", "@", "--", 'root-file:"c.txt"' }, crepo)), "1\nLR\n3",
      "The resolution is recorded in @")
  end

  -- Marker parsing edge cases.
  do
    local parsed = assert((jj_mod.parse_git_style_conflict(table.concat({
      "top",
      "<<<<<<<<<< a",
      "<<<<<<< not a marker at this length",
      "|||||||||| base",
      "b",
      "==========",
      "c",
      ">>>>>>>>>> z",
      "",
    }, "\n"))))
    assert_eq(parsed.local_text, "top\n<<<<<<< not a marker at this length\n", "Long markers keep shorter lookalikes as text")
    assert_eq(parsed.base, "top\nb\n", "Long-marker base")
    assert_eq(parsed.remote, "top\nc\n", "Long-marker right")
    local _, perr = jj_mod.parse_git_style_conflict("plain\n")
    assert_eq(perr, "no conflict markers found", "A clean file is not a conflict")
  end

  -- bin/diffbandit as jj's merge-editor and diff-editor, end to end. The
  -- "nvim" is a headless wrapper that acts like a user after startup.
  do
    local tool_dir = vim.fn.tempname()
    vim.fn.mkdir(tool_dir, "p")
    local wrapper = tool_dir .. "/nvim"
    -- Polls until the launcher's view is up, then plays the user.
    local action = [[lua local tries = 0
local function act()
  local state = require("diffbandit.state")
  if next(state.sessions) == nil then
    tries = tries + 1
    if tries > 100 then
      vim.cmd("cquit 3")
    end
    vim.defer_fn(act, 100)
    return
  end
  for _, s in pairs(state.sessions) do
    if s.result_buf and vim.env.DB_ACTION == "resolve" then
      vim.api.nvim_buf_set_lines(s.result_buf, 0, -1, false, { "1", "BOTH", "3" })
      s:resolve()
      s:close()
    elseif s.result_buf then
      s:close()
    elseif s.right_root then
      vim.fn.writefile({ "a", "B", "c" }, s.right_root .. "/f.txt")
      vim.fn.delete(s.right_root .. "/n.txt")
      s:close()
    end
  end
end
vim.defer_fn(act, 100)]]
    vim.fn.writefile({
      "#!/bin/sh",
      string.format("exec %s --headless --clean --cmd %s --cmd %s -c %s \"$@\"",
        vim.fn.shellescape(vim.v.progpath),
        vim.fn.shellescape("set rtp^=" .. root),
        vim.fn.shellescape("runtime plugin/diffbandit.lua"),
        -- writefile() turns embedded newlines into NULs; Lua needs none.
        vim.fn.shellescape((action:gsub("\n", " ")))),
    }, wrapper)
    vim.fn.setfperm(wrapper, "rwxr-xr-x")
    local tool_config = tool_dir .. "/jj.toml"
    vim.fn.writefile({
      "[user]",
      'name = "DiffBandit Test"',
      'email = "diffbandit@example.com"',
      "[merge-tools.diffbandit]",
      string.format('program = "%s/bin/diffbandit"', root),
      'merge-args = ["merge", "$base", "$left", "$right", "$output", "--path", "$path"]',
      'edit-args = ["edit", "$left", "$right"]',
      "merge-tool-edits-conflict-markers = false",
      "[ui]",
      'merge-editor = "diffbandit"',
      'diff-editor = "diffbandit"',
    }, tool_config)
    local saved_nvim = vim.env.DIFFBANDIT_NVIM
    vim.env.JJ_CONFIG = tool_config
    vim.env.DIFFBANDIT_NVIM = wrapper

    local crepo = make_jj_repo()
    write(crepo, "c.txt", { "1", "2", "3" })
    jj_run({ "commit", "-m", "base" }, crepo)
    local base = vim.trim(jj_run({ "log", "--no-graph", "-r", "@-", "-T", "change_id" }, crepo))
    write(crepo, "c.txt", { "1", "L", "3" })
    jj_run({ "commit", "-m", "left" }, crepo)
    local left = vim.trim(jj_run({ "log", "--no-graph", "-r", "@-", "-T", "change_id" }, crepo))
    jj_run({ "new", base }, crepo)
    write(crepo, "c.txt", { "1", "R", "3" })
    jj_run({ "commit", "-m", "right" }, crepo)
    local right = vim.trim(jj_run({ "log", "--no-graph", "-r", "@-", "-T", "change_id" }, crepo))
    jj_run({ "new", left, right }, crepo)

    vim.env.DB_ACTION = "quit"
    local quit = jj_status({ "resolve" }, crepo)
    assert_eq(quit.code ~= 0, true, "Quitting the merge without :w fails jj resolve")
    assert_eq(#jj_mod.unmerged_entries(crepo, {}), 1, "An abandoned merge keeps the conflict")
    vim.env.DB_ACTION = "resolve"
    local resolved = jj_status({ "resolve" }, crepo)
    assert_eq(resolved.code, 0, "jj resolve accepts a resolved merge: " .. tostring(resolved.stderr))
    assert_eq(#jj_mod.unmerged_entries(crepo, {}), 0, "jj resolve recorded the resolution")
    assert_eq(read_file(crepo .. "/c.txt")[2], "BOTH", "The merged text reached the working copy")

    local srepo = make_jj_repo()
    write(srepo, "f.txt", { "a", "b", "c" })
    jj_run({ "commit", "-m", "base" }, srepo)
    write(srepo, "f.txt", { "a", "B", "c", "d" })
    write(srepo, "n.txt", { "new" })
    vim.env.DB_ACTION = "edit"
    local split = jj_status({ "split", "-m", "first" }, srepo)
    assert_eq(split.code, 0, "jj split runs diffbandit as the diff editor: " .. tostring(split.stderr))
    assert_eq(show(srepo, "@-", "f.txt"), "a\nB\nc\n", "The split's first commit holds the kept hunk")
    assert_eq(jj_status({ "file", "show", "-r", "@-", "--", 'root-file:"n.txt"' }, srepo).code ~= 0, true,
      "Files removed from $right stay out of the first commit")
    assert_eq(show(srepo, "@", "n.txt"), "new\n", "The rest stays in @")

    vim.env.DB_ACTION = nil
    vim.env.DIFFBANDIT_NVIM = saved_nvim
  end

  vim.env.JJ_CONFIG = saved_jj_config
end
