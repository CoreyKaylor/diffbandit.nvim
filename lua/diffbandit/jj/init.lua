-- Jujutsu (jj) backend. Implements the same contract as diffbandit.git so
-- hosts, the panel, and hunk actions work unchanged (routed by
-- diffbandit.vcs).
--
-- Model (the jj "squash workflow"):
--   * the working copy is the commit @ (files on disk);
--   * the stage target is its parent @- — staging a hunk moves it from @
--     into @-, unstaging moves it back, and @'s content never changes;
--   * modes map onto revisions:
--       unstaged  @-  -> @          (plain `jj diff`; the default)
--       staged    @-- -> @-
--       all       @-- -> @
--       rev       base -> target    (any revsets)
--
-- Git-shaped blob specs are kept so git/sources.lua can build diff sources
-- unchanged: ":path" reads the stage target (@-), "REV:path" reads REV.
-- Revsets containing ":" are resolved to commit ids before they enter a spec.

local process = require("diffbandit.util.process")
local pending = require("diffbandit.util.pending")
local text = require("diffbandit.util.text")
local git = require("diffbandit.git")
local git_sources = require("diffbandit.git.sources")

local shared = git._shared

local M = {}

M.STAGE_REV = "@-"
M.STAGE_BASE = "@--"

local function jj_cmd(root, args, opts)
  opts = opts or {}
  local cmd = { "jj", "--no-pager", "--color=never" }
  if root and root ~= "" then
    cmd[#cmd + 1] = "-R"
    cmd[#cmd + 1] = root
  end
  if opts.ignore_working_copy then
    cmd[#cmd + 1] = "--ignore-working-copy"
  end
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end
  return cmd
end

-- jj prints paths relative to the process cwd, so every command runs from
-- the workspace root (making paths root-relative, like git's).
local function jj_output(root, args, opts)
  opts = opts or {}
  return process.run(jj_cmd(root, args, opts), { env = opts.env, cwd = root })
end

-- Reads never need a fresh snapshot: the queue build (`jj diff`) snapshots
-- once, and worktree content is read from disk directly.
local function jj_read(root, args)
  return jj_output(root, args, { ignore_working_copy = true })
end

local function fileset(path)
  return 'root-file:"' .. path:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function trim(value)
  return value and vim.trim(value) or ""
end

-- jj aliases for git's "HEAD": the stage base (@--) is what git's HEAD is to
-- the index.
local function rev_of(ref)
  if ref == nil or ref == "" or ref == "HEAD" then
    return M.STAGE_BASE
  end
  return ref
end

-- A user-supplied revision (launcher ranges, compare, rev mode): git's
-- "HEAD" — "what I have checked out" — is the working-copy commit @.
local function user_rev(ref)
  if ref == nil or ref == "" or ref == "HEAD" then
    return "@"
  end
  return ref
end

-- ---------------------------------------------------------------------------
-- Paths and roots

local abs_path = shared.abs_path
M.abs_path = function(root, path)
  return abs_path(root, path)
end
M.relpath = function(root, path)
  -- One value only: git's relpath can leak a gsub count.
  return (git.relpath(root, path))
end
M.find_loaded_buffer = function(path)
  return shared.find_loaded_buffer(path)
end

function M.find_root(start)
  local dir = start
  if not dir or dir == "" then
    dir = (vim.uv or vim.loop).cwd()
  end
  dir = vim.fn.fnamemodify(dir, ":p")
  if vim.fn.isdirectory(dir) ~= 1 then
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  -- `jj root` has no -C; run it from the start directory instead.
  local result = vim.system({ "jj", "--no-pager", "--ignore-working-copy", "root" }, { cwd = dir, text = true }):wait()
  if result.code ~= 0 then
    return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "not inside a jj repository"
  end
  local output = result.stdout
  local root = trim(output)
  if root == "" then
    return nil, "not inside a jj repository"
  end
  return (vim.fn.fnamemodify(root, ":p"):gsub("/$", "")), nil
end

function M.root(opts)
  opts = opts or {}
  local name = vim.api.nvim_buf_get_name(0)
  local start = opts.root or opts.path or (name ~= "" and name or nil) or (vim.uv or vim.loop).cwd()
  return M.find_root(start)
end

-- ---------------------------------------------------------------------------
-- Revisions

-- Commit ids for every commit in revset (in jj's order).
local function commit_ids(root, revset)
  local output, err = jj_read(root, { "log", "--no-graph", "-r", revset, "-T", 'commit_id ++ "\\n"' })
  if not output then
    return nil, err
  end
  return text.split_lines(output), nil
end

-- One commit id for rev, or nil + reason when it resolves to zero or many.
function M.resolve_single(root, rev)
  local ids, err = commit_ids(root, rev)
  if not ids then
    return nil, err
  end
  if #ids ~= 1 then
    return nil, string.format("revision %s resolves to %d commits", rev, #ids)
  end
  return ids[1], nil
end

function M.is_revision(root, rev)
  if not rev or rev == "" or rev:sub(1, 1) == "-" then
    return false
  end
  return M.resolve_single(root, rev) ~= nil
end

-- A spec-safe name for rev: simple revsets stay readable (@-, main,
-- trunk()), anything with ":" (which would split a blob spec) becomes its
-- commit id.
local function spec_rev(root, rev)
  rev = rev_of(rev)
  if not rev:find(":", 1, true) then
    return rev, nil
  end
  return M.resolve_single(root, rev)
end

-- The parent revision diffs are taken against: a single parent, or root()
-- for a root commit. Merge commits have no single tree to stage against.
local function single_parent(root, rev)
  local ids, err = commit_ids(root, "parents(" .. rev .. ")")
  if not ids then
    return nil, err
  end
  if #ids == 0 then
    return "root()", nil
  end
  if #ids > 1 then
    return nil, string.format("%s is a merge commit; diff it with an explicit base", rev)
  end
  -- Keep the readable revset when it names exactly that parent.
  if rev == M.STAGE_REV then
    return M.STAGE_BASE, nil
  end
  return ids[1], nil
end

-- ---------------------------------------------------------------------------
-- Blob reads

local function read_rev_file(root, rev, path)
  return jj_read(root, { "file", "show", "-r", rev, "--", fileset(path) })
end

-- Git-shaped spec: ":path" (stage target), "REV:path".
local function read_blob(root, spec)
  if spec:sub(1, 1) == ":" then
    return read_rev_file(root, M.STAGE_REV, spec:sub(2))
  end
  local rev, path = spec:match("^([^:]*):(.*)$")
  if not rev then
    return nil, "invalid blob spec: " .. spec
  end
  return read_rev_file(root, rev_of(rev), path)
end

function M.read_index(root, path)
  return read_blob(root, ":" .. path)
end

-- Same shape as git.read_blobs: one { text, err } per spec ("text" is nil
-- when the file is absent from that revision).
function M.read_blobs(root, specs)
  local results = {}
  for index, spec in ipairs(specs or {}) do
    local output, err = read_blob(root, spec)
    results[index] = { output, err }
  end
  return results
end

function M.read_head(root, path, base)
  return read_rev_file(root, rev_of(base), path)
end

function M.read_worktree(root, path, use_buffer)
  return shared.read_worktree(root, path, use_buffer)
end

function M.write_worktree(root, path, value, use_buffer)
  return git.write_worktree(root, path, value, use_buffer)
end

-- ---------------------------------------------------------------------------
-- Change listing

local status_letters = {
  modified = "M",
  added = "A",
  removed = "D",
  copied = "C",
  renamed = "R",
}

local file_type_modes = {
  file = "100644",
  executable = "100755",
  symlink = "120000",
  ["git-submodule"] = "160000",
  tree = "040000",
}

local diff_template = table.concat({
  "status",
  "source.path()",
  "target.path()",
  "source.file_type()",
  "target.file_type()",
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\x1e"'

local function range_args(opts)
  return { "--from", opts.jj_from, "--to", opts.jj_to }
end

local function append_filesets(args, root, pathspecs)
  if pathspecs and #pathspecs > 0 then
    args[#args + 1] = "--"
    for _, spec in ipairs(pathspecs) do
      if spec == "." or spec == "" then
        args[#args + 1] = "all()"
      else
        -- Pathspecs are root-relative here (launcher/queue normalize them);
        -- a directory pathspec matches everything below it.
        local quoted = spec:gsub("\\", "\\\\"):gsub('"', '\\"')
        args[#args + 1] = 'root:"' .. quoted .. '"'
      end
    end
  end
  return args
end

-- Parses `jj diff -T diff_template` output into git-style entries.
local function parse_diff_entries(output)
  local entries = {}
  for _, record in ipairs(git._private.split_char(output or "", "\30")) do
    record = record:gsub("^%s+", "")
    if record ~= "" then
      local fields = git._private.split_char(record, "\31")
      local status = status_letters[fields[1]] or "M"
      local source_type, target_type = fields[4], fields[5]
      if status == "M" and source_type and target_type and source_type ~= target_type then
        local function is_file(t)
          return t == "file" or t == "executable"
        end
        if not (is_file(source_type) and is_file(target_type)) then
          status = "T"
        end
      end
      local entry = {
        status = status,
        raw_status = fields[1],
        path = fields[3] ~= "" and fields[3] or fields[2],
        modes = {
          left = status ~= "A" and file_type_modes[source_type] or nil,
          right = status ~= "D" and file_type_modes[target_type] or nil,
        },
      }
      if (status == "R" or status == "C") and fields[2] ~= fields[3] then
        entry.old_path = fields[2]
      end
      if status == "M" and source_type ~= target_type then
        entry.mode_change = true
      end
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries
end

local function list_changes(root, from, to, pathspecs, read_only)
  local args = { "diff", "--from", from, "--to", to, "-T", diff_template }
  append_filesets(args, root, pathspecs)
  -- The first command of a refresh snapshots the working copy.
  local output, err
  if read_only then
    output, err = jj_read(root, args)
  else
    output, err = jj_output(root, args)
  end
  if not output then
    return nil, err
  end
  return parse_diff_entries(output), nil
end

-- Conflicted paths in @ (`jj resolve --list`), as unmerged entries.
function M.unmerged_entries(root, pathspecs)
  local args = { "resolve", "--list", "-r", "@" }
  append_filesets(args, root, pathspecs)
  -- Snapshots: a just-written resolution must be seen as resolved.
  local code, stdout = process.run_exit_code(jj_cmd(root, args), { cwd = root })
  if code ~= 0 then
    -- "No conflicts found" exits non-zero.
    return {}, nil
  end
  local entries = {}
  for _, line in ipairs(text.split_lines(stdout)) do
    local path, sides = line:match("^(.-)%s%s+(.*)$")
    path = path or vim.trim(line)
    if path ~= "" then
      entries[#entries + 1] = {
        status = "U",
        raw_status = "conflict",
        path = path,
        conflict_description = sides,
      }
    end
  end
  return entries, nil
end

function M.has_unmerged(root)
  local entries = M.unmerged_entries(root, {})
  return #entries > 0, nil
end

-- ---------------------------------------------------------------------------
-- Classification readers for git/sources.lua

local function entry_modes(queue, entry)
  if entry.modes then
    return entry.modes
  end
  entry.modes = {}
  return entry.modes
end

-- Non-nil only for mode-only changes (exec bit): sources then renders a
-- metadata entry instead of an empty text diff.
local function summary_reader(root, opts, path)
  local entry = opts and opts.jj_mode_changes and opts.jj_mode_changes[path]
  if entry then
    return string.format("mode change %s => %s %s", entry.modes.left or "?", entry.modes.right or "?", path)
  end
  return nil
end

local function numstat_reader(root, opts, path)
  local args = { "diff", "--stat" }
  vim.list_extend(args, range_args(opts))
  append_filesets(args, root, { path })
  local output = jj_read(root, args)
  if not output then
    return nil
  end
  -- "0 files changed, 0 insertions(+), 0 deletions(-)" for mode-only changes.
  local ins = tonumber(output:match("(%d+) insertions?")) or 0
  local del = tonumber(output:match("(%d+) deletions?")) or 0
  return string.format("%d\t%d\t%s", ins, del, path)
end

local sources = git_sources.new({
  git_summary = summary_reader,
  numstat = numstat_reader,
  entry_modes = entry_modes,
  abs_path = abs_path,
  read_blob = read_blob,
  read_worktree = shared.read_worktree,
  read_worktree_raw = shared.read_worktree_raw,
  read_worktree_symlink = shared.read_worktree_symlink,
  find_loaded_buffer = shared.find_loaded_buffer,
  has_modified_loaded_buffer = shared.has_modified_loaded_buffer,
})

function M.sources_for_entry(queue, index)
  -- Same post-processing as the git backend.
  local entry = queue.entries[index]
  if not entry then
    return nil, "no changed file at queue index " .. tostring(index)
  end
  local left, left_err = sources.source_from_kind(queue, entry, "left")
  if not left then
    return nil, left_err
  end
  local right, right_err = sources.source_from_kind(queue, entry, "right")
  if not right then
    return nil, right_err
  end
  if left.git_binary_hex or right.git_binary_hex or left.git_binary_hidden or right.git_binary_hidden then
    entry.content_kind = "binary"
    entry.actions_enabled = false
    entry.actions_disabled_reason = (left.git_binary_hidden or right.git_binary_hidden)
      and "binary file is not rendered as text"
      or "binary hex view is read-only"
    left.git_readonly_reason = entry.actions_disabled_reason
    right.git_readonly_reason = entry.actions_disabled_reason
    left.editable = nil
    right.editable = nil
  end
  return { left = left, right = right, entry = entry, index = index }, nil
end

-- ---------------------------------------------------------------------------
-- Queues

local function normalize_opts(opts, config)
  opts = vim.tbl_extend("force", {}, config or {}, opts or {})
  local ok, state = pcall(require, "diffbandit.state")
  local jj_config = opts.jj or (ok and state.get_config and (state.get_config() or {}).jj) or {}
  -- git.default_mode ("all") assumes an index; jj defaults to `jj diff`.
  opts.mode = opts.mode or jj_config.default_mode or "unstaged"
  opts.scope = opts.scope or opts.default_scope or "repo"
  if opts.mode == "cached" then
    opts.mode = "staged"
  end
  if opts.mode == "rev" and (not opts.base or not opts.target) then
    return nil, "revision mode requires both base and target revisions"
  end
  opts.pathspecs = opts.pathspecs or {}
  opts.include_untracked = false
  -- No index: files added in @ are absent from @- in every mode.
  opts.index_tracks_additions = false
  return opts, nil
end

-- Resolves the jj range for opts.mode and rewrites base/target into
-- spec-safe names for git/sources.lua.
local function resolve_range(root, opts)
  local mode = opts.mode
  local from, to, err
  if mode == "unstaged" then
    from, to = M.STAGE_REV, "@"
  elseif mode == "staged" then
    from, err = single_parent(root, M.STAGE_REV)
    to = M.STAGE_REV
  elseif mode == "all" then
    if opts.base and opts.base ~= "" and opts.base ~= "HEAD" then
      from = user_rev(opts.base)
    else
      from, err = single_parent(root, M.STAGE_REV)
    end
    to = "@"
  elseif mode == "rev" then
    from, to = user_rev(opts.base), user_rev(opts.target)
  else
    return nil, "unsupported jj mode: " .. tostring(mode)
  end
  if not from then
    return nil, err
  end
  opts.jj_from, opts.jj_to = from, to
  opts.ref_labels = {
    index = M.STAGE_REV,
    worktree = "@ working copy",
    base = mode == "rev" and opts.base or from,
  }
  -- sources.lua reads "<base>:<path>" for the left side of staged/all/rev
  -- and "<target>:<path>" for the right side of rev.
  if mode ~= "unstaged" then
    local base_name, base_err = spec_rev(root, from)
    if not base_name then
      return nil, base_err
    end
    opts.base = base_name
  end
  if mode == "rev" then
    local target_name, target_err = spec_rev(root, to)
    if not target_name then
      return nil, target_err
    end
    opts.target = target_name
  end
  return opts, nil
end

function M.queue(opts, config)
  local normalized, normalize_err = normalize_opts(opts, config)
  if not normalized then
    return nil, normalize_err
  end
  local uv = vim.uv or vim.loop
  local name = vim.api.nvim_buf_get_name(0)
  local start = normalized.root
    or normalized.path
    or (normalized.scope == "current" and normalized.pathspecs and normalized.pathspecs[1])
    or (name ~= "" and name or nil)
    or uv.cwd()
  local root, root_err = M.find_root(start)
  if not root then
    return nil, root_err
  end
  normalized.root = root
  if normalized.scope == "current" then
    local target = normalized.path or (normalized.pathspecs and normalized.pathspecs[1]) or (name ~= "" and name or nil)
    if not target then
      return nil, "no current file for jj diff"
    end
    normalized.pathspecs = { M.relpath(root, target) }
  end

  local entries, entries_err
  local working_copy_merge = false
  -- The refresh's first command snapshots the working copy (reviews of @
  -- must see current files too).
  local parents_output = jj_output(root, { "log", "--no-graph", "-r", "parents(@)", "-T", 'commit_id ++ "\n"' })
  if normalized.mode ~= "rev" then
    working_copy_merge = #text.split_lines(parents_output or "") > 1
  end
  if working_copy_merge then
    -- @ is a merge (e.g. `jj new A B`): there is no single parent tree to
    -- diff or stage against, so the review lists only its conflicts.
    normalized.read_only = true
    normalized.jj_working_copy_merge = true
    entries = {}
  else
    local _, range_err = resolve_range(root, normalized)
    if range_err then
      return nil, range_err
    end
    entries, entries_err = list_changes(root, normalized.jj_from, normalized.jj_to,
      normalized.pathspecs, normalized.read_only == true)
    if not entries then
      return nil, entries_err
    end
  end
  if normalized.mode ~= "rev" then
    -- Conflicted files in @ replace their diff rows.
    local unmerged = M.unmerged_entries(root, normalized.pathspecs)
    local by_path = {}
    for index, entry in ipairs(entries) do
      by_path[entry.path] = index
    end
    for _, conflict in ipairs(unmerged) do
      if by_path[conflict.path] then
        entries[by_path[conflict.path]] = conflict
      else
        entries[#entries + 1] = conflict
      end
    end
    table.sort(entries, function(a, b)
      return a.path < b.path
    end)
  end
  normalized.jj_mode_changes = {}
  for _, entry in ipairs(entries) do
    if entry.mode_change then
      normalized.jj_mode_changes[entry.path] = entry
    end
  end

  if #entries == 0 and normalized.scope == "current" and normalized.use_buffer ~= false then
    local current_path = normalized.pathspecs and normalized.pathspecs[1]
    if current_path and shared.has_modified_loaded_buffer(root, current_path) then
      entries[#entries + 1] = {
        status = "M",
        raw_status = "buffer",
        path = current_path,
        buffer_only = true,
        modes = {},
      }
    end
  end
  if #entries == 0 then
    if working_copy_merge then
      return nil, "@ is a merge commit with no conflicts; review it with `diffbandit show @`"
    end
    return nil, "no jj changes"
  end

  local queue = {
    kind = "git",
    vcs = "jj",
    root = root,
    opts = normalized,
    entries = entries,
    index = 1,
    source_cache = {},
  }

  function queue.load(index)
    local entry = queue.entries[index]
    local cacheable = normalized.use_buffer == false or not shared.entry_uses_modified_buffer(root, entry)
    if cacheable and queue.source_cache[index] then
      return queue.source_cache[index], nil
    end
    local loaded, load_err = M.sources_for_entry(queue, index)
    if loaded and cacheable then
      queue.source_cache[index] = loaded
    end
    return loaded, load_err
  end

  return queue, nil
end

-- ---------------------------------------------------------------------------
-- History

local log_template = table.concat({
  "commit_id",
  "commit_id.short()",
  'parents.map(|p| p.commit_id()).join(" ")',
  "author.name()",
  'author.timestamp().format("%Y-%m-%d")',
  "description.first_line()",
  "change_id.short()",
  'bookmarks.join(" ")',
  'if(conflict, "conflict", "")',
  'if(empty, "empty", "")',
  'if(immutable, "immutable", "")',
  'if(current_working_copy, "@", "")',
  "description",
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\x1e"'

local function parse_log(output)
  local commits = {}
  for _, record in ipairs(git._private.split_char(output or "", "\30")) do
    record = record:gsub("^\n", "")
    if record ~= "" then
      local f = git._private.split_char(record, "\31")
      commits[#commits + 1] = {
        hash = f[1],
        short_hash = f[2],
        parents = vim.split(f[3] or "", " ", { plain = true, trimempty = true }),
        author = f[4],
        date = f[5],
        subject = (f[6] ~= "" and f[6]) or "(no description set)",
        change_id = f[7],
        bookmarks = vim.split(f[8] or "", " ", { plain = true, trimempty = true }),
        conflict = f[9] == "conflict",
        empty = f[10] == "empty",
        immutable = f[11] == "immutable",
        working_copy = f[12] == "@",
        description = f[13] or "",
      }
    end
  end
  return commits
end

-- opts: { rev (revset), all, max_count, pathspecs }. Without a revset jj's
-- own `revsets.log` default applies.
function M.log(root, opts)
  opts = opts or {}
  local args = { "log", "--no-graph", "-T", log_template }
  local revset = opts.rev
  if opts.all then
    revset = "all()"
  end
  if revset and revset ~= "" then
    args[#args + 1] = "-r"
    args[#args + 1] = revset
  end
  if opts.max_count then
    args[#args + 1] = "--limit"
    args[#args + 1] = tostring(opts.max_count)
  end
  append_filesets(args, root, opts.pathspecs or {})
  local output, err = jj_output(root, args)
  if not output then
    return nil, err
  end
  return parse_log(output), nil
end

function M.commit_metadata(root, rev)
  local commits, err = M.log(root, { rev = user_rev(rev), max_count = 2 })
  if not commits then
    return nil, err
  end
  if #commits ~= 1 then
    return nil, string.format("revision %s resolves to %d commits", tostring(rev), #commits)
  end
  return commits[1], nil
end

local function review_queue_opts(opts, review)
  local next_opts = vim.tbl_extend("force", {}, opts or {})
  next_opts.mode = "rev"
  next_opts.read_only = true
  next_opts.include_untracked = false
  next_opts.review = review
  return next_opts
end

function M.commit_queue(root, rev, opts, config)
  if not rev or rev == "" then
    return nil, "commit revision is required"
  end
  local meta, meta_err = M.commit_metadata(root, rev)
  if not meta then
    return nil, meta_err
  end
  local base = #meta.parents == 1 and meta.parents[1] or nil
  if #meta.parents == 0 then
    base = "root()"
  end
  if not base then
    return nil, "merge commits are not supported in commit review yet"
  end
  local queue_opts = review_queue_opts(vim.tbl_extend("force", opts or {}, {
    root = root,
    base = base,
    target = meta.hash,
  }), {
    kind = "commit",
    title = (meta.change_id or meta.short_hash or rev) .. " " .. (meta.subject or ""),
    commit = meta,
    base = base,
    target = meta.hash,
  })
  return M.queue(queue_opts, config)
end

function M.merge_base(root, base, target)
  return M.resolve_single(root, string.format("heads(::(%s) & ::(%s))", base, target))
end

function M.compare_queue(root, base, target, opts, config)
  opts = opts or {}
  base = user_rev(base)
  target = user_rev(target)
  local compare_base = base
  if opts.direct ~= true then
    local merge_base, err = M.merge_base(root, base, target)
    if not merge_base then
      return nil, err
    end
    compare_base = merge_base
  end
  local queue_opts = review_queue_opts(vim.tbl_extend("force", opts, {
    root = root,
    base = compare_base,
    target = target,
  }), {
    kind = "compare",
    title = string.format("%s..%s", base, target),
    base = compare_base,
    requested_base = base,
    target = target,
    direct = opts.direct == true,
  })
  return M.queue(queue_opts, config)
end

-- Bookmarks, shaped like git branches (name, current = on @ or @-).
function M.list_branches(root)
  local output, err = jj_read(root, {
    "bookmark", "list", "--all-remotes", "-T",
    'if(remote, name ++ "@" ++ remote, name) ++ "\\x1f" ++ if(remote, "remote", "") ++ "\\x1f" ++ '
      .. 'if(normal_target, normal_target.commit_id().short(), "") ++ "\\n"',
  })
  if not output then
    return nil, err
  end
  local near = {}
  for _, id in ipairs(commit_ids(root, "@ | @-") or {}) do
    near[id:sub(1, 12)] = true
  end
  local branches = {}
  local seen = {}
  for _, line in ipairs(text.split_lines(output)) do
    local name, remote, oid = line:match("^([^\31]*)\31([^\31]*)\31(.*)$")
    if name and name ~= "" and not name:match("@git$") and not seen[name] then
      seen[name] = true
      branches[#branches + 1] = {
        refname = name,
        name = name,
        oid = oid ~= "" and oid or nil,
        current = oid ~= "" and near[oid:sub(1, 12)] == true,
        remote = remote == "remote",
      }
    end
  end
  table.sort(branches, function(a, b)
    if a.current ~= b.current then
      return a.current == true
    end
    return a.name < b.name
  end)
  return branches, nil
end

-- "Checkout" in jj: start a new change on top of rev (the working copy is
-- always committed, so nothing can be lost).
function M.checkout_branch(root, rev, opts)
  opts = opts or {}
  if not rev or rev == "" then
    return false, "revision is required"
  end
  local args = opts.edit and { "edit", user_rev(rev) } or { "new", user_rev(rev) }
  local _, err = jj_output(root, args)
  return err == nil, err
end

function M.is_worktree_dirty()
  return false, nil
end

-- ---------------------------------------------------------------------------
-- Staging: the write primitive

local write_tool_path

-- A tiny diff-editor "tool" that jj runs non-interactively: it copies the
-- desired contents into $right/<path> (or removes the file).
local function ensure_write_tool()
  if write_tool_path and vim.fn.executable(write_tool_path) == 1 then
    return write_tool_path
  end
  local dir = vim.fn.stdpath("cache") .. "/diffbandit"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/jj-write-tool.sh"
  vim.fn.writefile({
    "#!/bin/sh",
    "# Written by diffbandit.nvim: non-interactive jj diff editor.",
    'target="$1/$DIFFBANDIT_JJ_PATH"',
    'if [ -n "$DIFFBANDIT_JJ_SRC" ]; then',
    '  mkdir -p "$(dirname "$target")" && cp "$DIFFBANDIT_JJ_SRC" "$target"',
    "else",
    '  rm -f "$target"',
    "fi",
  }, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  write_tool_path = path
  return path
end

local function toml_string(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Sets path's content in revision `to` to value (nil deletes it), keeping
-- every descendant's content unchanged. `from` must differ from `to` at
-- path (jj only materializes changed paths for the editor); the other side
-- of the diff being edited always does.
function M.write_rev_file(root, to, path, value, from)
  local tool = ensure_write_tool()
  local src = ""
  if value ~= nil then
    src = vim.fn.tempname()
    local fd = io.open(src, "wb")
    if not fd then
      return false, "unable to write temp file"
    end
    fd:write(value)
    fd:close()
  end
  local args = {
    "diffedit", "--from", from, "--to", to, "--restore-descendants",
    "--tool", "diffbandit-write",
    "--config", "merge-tools.diffbandit-write.program=" .. toml_string(tool),
    "--config", 'merge-tools.diffbandit-write.edit-args=["$right"]',
    "--config", "ui.diff-instructions=false",
    "--", fileset(path),
  }
  local _, err = jj_output(root, args, {
    env = { DIFFBANDIT_JJ_SRC = src, DIFFBANDIT_JJ_PATH = path },
  })
  if src ~= "" then
    pcall(os.remove, src)
  end
  return err == nil, err
end

-- What @- is to the staging model:
--   "staging"   mutable and undescribed: the change being built (stage here)
--   "commit"    a described, mutable commit: only amend mode changes it
--   "immutable" never written
--   nil         @ has no single parent
local function stage_target(root)
  local commits = M.log(root, { rev = M.STAGE_REV, max_count = 2 }) or {}
  if #commits ~= 1 then
    return nil, nil
  end
  local commit = commits[1]
  if commit.immutable then
    return "immutable", commit
  end
  if vim.trim(commit.description or "") == "" then
    return "staging", commit
  end
  return "commit", commit
end

local NO_PARENT = "the working copy has no single parent to stage into"
local NEEDS_STAGING = "@- is a described commit: turn on amend to change it, "
  .. "or stage from the unstaged view to start a staging change"

-- Gate for stage/unstage (session hunk actions and panel file actions).
-- Staging from the unstaged view creates the staging change on demand:
-- it has @-'s tree, so the open diff stays valid.
function M.prepare_stage(root, opts, action)
  opts = opts or {}
  local role = stage_target(root)
  if role == "staging" or (role == "commit" and opts.amend_mode) then
    return true, nil
  end
  if role == nil then
    return false, NO_PARENT
  end
  if action == "unstage" or (opts.mode or "unstaged") ~= "unstaged" then
    if role == "immutable" then
      return false, "@- is immutable; create a staging change first (jj new --insert-before @ --no-edit)"
    end
    return false, NEEDS_STAGING
  end
  local _, err = jj_output(root, { "new", "--insert-before", "@", "--no-edit" })
  if err then
    return false, err
  end
  vim.schedule(function()
    vim.notify("DiffBandit: started an empty staging change under @ (jj new --insert-before @)", vim.log.levels.INFO)
  end)
  return true, nil
end

local function stage_target_error(root)
  local role = stage_target(root)
  if role == nil then
    return NO_PARENT
  end
  if role == "immutable" then
    return "@- is immutable; create a staging change first (jj new --insert-before @ --no-edit)"
  end
  return nil
end

-- The index slot: hunk staging writes @-; unstaging writes @- back toward
-- @--. Either way @ keeps its content.
function M.write_index(root, path, value)
  local err = stage_target_error(root)
  if err then
    return false, err
  end
  -- @ differs from @- at path whenever staging (moving @'s hunk in);
  -- @-- differs from @- whenever unstaging. Pick the side that differs.
  local from = "@"
  local current = read_rev_file(root, M.STAGE_REV, path)
  local worktree = shared.read_worktree_raw(root, path)
  if current ~= nil and worktree ~= nil and current == worktree then
    from = M.STAGE_BASE
  elseif current == nil and worktree == nil then
    from = M.STAGE_BASE
  end
  return M.write_rev_file(root, M.STAGE_REV, path, value, from)
end

function M.has_staged_changes(root, path, base)
  local args = { "diff", "--from", rev_of(base), "--to", M.STAGE_REV, "--name-only" }
  if path then
    append_filesets(args, root, { path })
  end
  local output, err = jj_read(root, args)
  if not output then
    return false, err
  end
  return vim.trim(output) ~= "", nil
end

function M.has_any_staged_changes(root)
  return (M.has_staged_changes(root, nil, nil))
end

local function name_set(root, from, to)
  local output = jj_read(root, { "diff", "--from", from, "--to", to, "--name-only" })
  local set = {}
  for _, line in ipairs(text.split_lines(output or "")) do
    set[line] = true
  end
  return set
end

function M.file_stage_states(root, entries, opts)
  -- A described @- is the previous commit, not staged work (unless amending).
  local role = stage_target(root)
  local staged = {}
  if role == "staging" or (role == "commit" and opts and opts.amend_mode) then
    staged = name_set(root, M.STAGE_BASE, M.STAGE_REV)
  end
  local unstaged = name_set(root, M.STAGE_REV, "@")
  local states = {}
  for index, entry in ipairs(entries or {}) do
    local s = staged[entry.path] or (entry.old_path and staged[entry.old_path])
    local u = unstaged[entry.path] or (entry.old_path and unstaged[entry.old_path])
    if s and u then
      states[index] = "partial"
    elseif s then
      states[index] = "staged"
    else
      states[index] = "unstaged"
    end
  end
  return states
end

-- jj keeps no stage snapshot: the panel reads the states each time, and
-- snapshot_has_staged_changes answers "unknown" so callers probe directly.
function M.queue_stage_states(queue)
  queue = queue or {}
  return M.file_stage_states(queue.root, queue.entries, queue.opts or {})
end

function M.snapshot_has_staged_changes()
  return nil
end

function M.file_stage_state(root, entry, opts)
  return M.file_stage_states(root, { entry }, opts)[1] or "unstaged"
end

local function entry_filesets(root, entry)
  local args = { "--" }
  if entry.old_path and entry.old_path ~= entry.path then
    args[#args + 1] = fileset(entry.old_path)
  end
  args[#args + 1] = fileset(entry.path)
  return args
end

function M.stage_file(root, entry, opts)
  local ready, err = M.prepare_stage(root, opts, "stage")
  if not ready then
    return false, err
  end
  local args = { "squash", "--from", "@", "--into", M.STAGE_REV, "--keep-emptied", "--use-destination-message" }
  vim.list_extend(args, entry_filesets(root, entry))
  local _, run_err = jj_output(root, args)
  return run_err == nil, run_err
end

function M.unstage_file(root, entry, opts)
  local ready, prep_err = M.prepare_stage(root, opts, "unstage")
  if not ready then
    return false, prep_err
  end
  local args = { "restore", "--from", M.STAGE_BASE, "--into", M.STAGE_REV, "--restore-descendants" }
  vim.list_extend(args, entry_filesets(root, entry))
  local _, err = jj_output(root, args)
  return err == nil, err
end

function M.toggle_file_stage(root, entry, opts)
  local state = M.file_stage_state(root, entry, opts)
  if state == "staged" or state == "partial" then
    return M.unstage_file(root, entry, opts)
  end
  return M.stage_file(root, entry, opts)
end

function M.toggle_file_stage_async(root, entry, opts, state, callback)
  -- Deferred work: hold a pending token so tests' settle() waits for it.
  local token = pending.begin("jj_toggle_file_stage")
  vim.schedule(function()
    local ok, err = pcall(function()
      if state == "staged" or state == "partial" then
        callback(M.unstage_file(root, entry, opts))
      elseif state then
        callback(M.stage_file(root, entry, opts))
      else
        callback(M.toggle_file_stage(root, entry, opts))
      end
    end)
    pending.done(token)
    if not ok then
      error(err, 0)
    end
  end)
end

-- Discard = restore @'s file from @- (the working copy follows).
function M.discard_worktree_file(root, entry)
  if not entry or not entry.path then
    return false, "no file entry to discard"
  end
  local args = { "restore", "--from", M.STAGE_REV, "--into", "@" }
  vim.list_extend(args, entry_filesets(root, entry))
  local _, err = jj_output(root, args)
  if err == nil then
    -- Reload buffers showing the restored file.
    vim.schedule(function()
      pcall(vim.cmd, "checktime")
    end)
  end
  return err == nil, err
end

function M.delete_untracked_file()
  return false, "jj tracks new files automatically; discard the change instead"
end

function M.append_gitignore(root, pattern)
  return git.append_gitignore(root, pattern)
end

-- ---------------------------------------------------------------------------
-- Commit

-- Amend's message: @-'s description.
function M.last_commit_message(root)
  local _, commit = stage_target(root)
  local description = commit and commit.description or ""
  if vim.trim(description) == "" then
    return nil
  end
  return (description:gsub("\n+$", ""))
end

-- Amend edits a described @- in place (diffing it against @--). Called
-- when amend mode turns on: an empty staging change left by the last commit
-- is abandoned first, so the commit just made becomes @- again.
function M.amend_base(root)
  local role, commit = stage_target(root)
  if role == "staging" and commit.empty then
    local parents = M.log(root, { rev = "parents(" .. M.STAGE_REV .. ")", max_count = 2 }) or {}
    local parent = parents[1]
    if #parents == 1 and not parent.immutable and vim.trim(parent.description) ~= "" then
      local _, err = jj_output(root, { "abandon", M.STAGE_REV })
      if err then
        return nil, err
      end
      role = "commit"
    end
  end
  if role == "commit" then
    return M.STAGE_BASE, nil
  elseif role == "staging" then
    return nil, "@- holds staged changes: commit them before amending"
  elseif role == "immutable" then
    return nil, "@- is immutable and cannot be amended"
  end
  return nil, NO_PARENT
end

local function has_working_copy_changes(root)
  local output = jj_read(root, { "diff", "--from", M.STAGE_REV, "--to", "@", "--name-only" })
  return output ~= nil and vim.trim(output) ~= ""
end

-- Commit, by @-'s role:
--   amend            describe @- (its content was edited by staging)
--   staging change   describe it and open a fresh staging change above it;
--                    with nothing staged, all of @ goes in first
--   anything else    `jj commit` (describe @, start a new @)
function M.commit(root, message, opts)
  opts = opts or {}
  message = message or ""
  if vim.trim(message) == "" then
    return false, "commit message cannot be empty"
  end
  if M.has_unmerged(root) then
    return false, "merge conflicts must be resolved before committing"
  end
  local role = stage_target(root)
  if opts.amend then
    if role ~= "commit" then
      return false, select(2, M.amend_base(root))
    end
    local _, err = jj_output(root, { "describe", "-r", M.STAGE_REV, "-m", message })
    return err == nil, err
  end
  if role == "staging" then
    if not M.has_any_staged_changes(root) then
      if not has_working_copy_changes(root) then
        return false, "nothing to commit"
      end
      local _, squash_err = jj_output(root, {
        "squash", "--from", "@", "--into", M.STAGE_REV, "--keep-emptied", "--use-destination-message",
      })
      if squash_err then
        return false, squash_err
      end
    end
    local _, describe_err = jj_output(root, { "describe", "-r", M.STAGE_REV, "-m", message })
    if describe_err then
      return false, describe_err
    end
    local _, new_err = jj_output(root, { "new", "--insert-after", M.STAGE_REV, "--no-edit" })
    return new_err == nil, new_err
  end
  if not has_working_copy_changes(root) then
    return false, "nothing to commit"
  end
  local _, err = jj_output(root, { "commit", "-m", message })
  return err == nil, err
end

-- ---------------------------------------------------------------------------
-- Conflicts

-- Splits a file materialized with ui.conflict-marker-style=git into its
-- base/left/right texts. Only two-sided conflicts are representable that
-- way; anything else returns nil + reason.
function M.parse_git_style_conflict(content)
  local sides = { base = {}, left = {}, right = {} }
  local labels = {}
  local section
  local marker_len
  local saw_conflict = false
  local lines = vim.split(content or "", "\n", { plain = true })
  local trailing_newline = lines[#lines] == ""
  if trailing_newline then
    lines[#lines] = nil
  end
  local function push(targets, line)
    for _, name in ipairs(targets) do
      local list = sides[name]
      list[#list + 1] = line
    end
  end
  for _, line in ipairs(lines) do
    local open = line:match("^(<<<<<<<+)")
    if not section and open then
      section = "left"
      marker_len = #open
      saw_conflict = true
      labels.left = labels.left or vim.trim(line:sub(marker_len + 1))
    elseif section and line:match("^" .. string.rep("|", marker_len) .. "%f[^|]") then
      section = "base"
    elseif section and line:match("^" .. string.rep("=", marker_len) .. "$") then
      section = "right"
    elseif section and line:match("^" .. string.rep(">", marker_len) .. "%f[^>]") then
      if section ~= "right" then
        return nil, "conflict markers are malformed"
      end
      labels.right = labels.right or vim.trim(line:sub(marker_len + 1))
      section = nil
    elseif section then
      if section == "left" and line:match("^" .. string.rep("<", marker_len)) then
        return nil, "nested conflict markers"
      end
      push({ section }, line)
    else
      push({ "base", "left", "right" }, line)
    end
  end
  if section then
    return nil, "unterminated conflict"
  end
  if not saw_conflict then
    return nil, "no conflict markers found"
  end
  local function join(list)
    if #list == 0 then
      return ""
    end
    return table.concat(list, "\n") .. "\n"
  end
  return {
    base = join(sides.base),
    local_text = join(sides.left),
    remote = join(sides.right),
    has_local = true,
    has_remote = true,
    labels = labels,
  }, nil
end

function M.conflict_stages(root, path)
  local listed = M.unmerged_entries(root, { path })
  local description = listed[1] and listed[1].conflict_description or ""
  if #listed == 0 then
    return nil, "no jj conflict at " .. tostring(path)
  end
  local sides_count = tonumber(description:match("(%d+)%-sided"))
  if sides_count and sides_count > 2 then
    return nil, string.format("%s has a %d-sided conflict; resolve it with `jj resolve`", path, sides_count)
  end
  if description:find("deletion", 1, true) or description:find("non-file", 1, true) then
    -- e.g. "2-sided conflict including 1 deletion": no three texts to merge.
    return nil, path .. ": " .. description .. "; resolve it with `jj resolve`"
  end
  local output, err = jj_read(root, {
    "file", "show", "-r", "@",
    "--config", "ui.conflict-marker-style=git",
    "--", fileset(path),
  })
  if not output then
    return nil, err
  end
  return M.parse_git_style_conflict(output)
end

-- Header labels: jj's markers name each side ("<change> <commit> "desc"").
function M.merge_context(_, data)
  local labels = data and data.labels or {}
  return {
    operation = "jj conflict",
    current = labels.left or "side #1",
    incoming = labels.right or "side #2",
  }
end

-- The merge host for jj: resolving writes the working-copy file; jj's next
-- snapshot records the resolution (no `git add`).
function M.merge_host()
  return {
    kind = "jj",
    context = function(root, data)
      return M.merge_context(root, data)
    end,
    result_path = function(root, path)
      return abs_path(root, path)
    end,
    resolve = function(session, value)
      if value == nil then
        return false, "deleting a conflicted file: use `jj restore` or `jj resolve` instead"
      end
      return git.write_worktree(session.root, session.path, value, false)
    end,
    after_resolve = function(session)
      session:refresh_git_queue(session.path)
    end,
  }
end

return M
