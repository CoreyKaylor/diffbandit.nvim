local process = require("diffbandit.util.process")
local text = require("diffbandit.util.text")
local document = require("diffbandit.util.document")
local git_sources = require("diffbandit.git.sources")

local M = {}

-- Subcommands that never change the index, refs, or worktree. Every other
-- command bumps `generation`, which invalidates stage snapshots taken before
-- it (see take_stage_snapshot).
local READ_ONLY = {
  ["rev-parse"] = true,
  diff = true,
  ["ls-files"] = true,
  ["ls-tree"] = true,
  show = true,
  log = true,
  ["for-each-ref"] = true,
  ["merge-base"] = true,
  ["name-rev"] = true,
  ["cat-file"] = true,
}
local generation = 0

local function invalidate_snapshots()
  generation = generation + 1
end

local function git_cmd(root, args)
  if not READ_ONLY[args[1]] then
    invalidate_snapshots()
  end
  local cmd = { "git" }
  if root and root ~= "" then
    cmd[#cmd + 1] = "-C"
    cmd[#cmd + 1] = root
  end
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end
  return cmd
end

local function git_output(root, args)
  return process.run(git_cmd(root, args))
end

local function git_async(root, args, callback)
  local cmd = git_cmd(root, args)
  if process.run_async(cmd, callback) then
    return true
  end

  local output, err = process.run(cmd)
  vim.schedule(function()
    callback(err == nil, err, output or "")
  end)
  return true
end

local function git_exit_code(root, args)
  return process.run_exit_code(git_cmd(root, args))
end

local function git_lines(root, args)
  local output, err = git_output(root, args)
  if not output then
    return nil, err
  end

  return text.split_lines(output), nil
end

local empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

local function has_head(root)
  local _, err = git_output(root, { "rev-parse", "--verify", "HEAD" })
  return err == nil
end

local function split_nul(text)
  local items = {}
  if not text or text == "" then
    return items
  end
  local start = 1
  while start <= #text do
    local stop = text:find("\0", start, true)
    if not stop then
      stop = #text + 1
    end
    local item = text:sub(start, stop - 1)
    if item ~= "" then
      items[#items + 1] = item
    end
    start = stop + 1
  end
  return items
end

local function split_char(value, sep)
  local items = {}
  value = value or ""
  local start = 1
  while start <= #value do
    local stop = value:find(sep, start, true)
    if not stop then
      items[#items + 1] = value:sub(start)
      break
    end
    items[#items + 1] = value:sub(start, stop - 1)
    start = stop + #sep
  end
  return items
end

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return path:gsub("\\", "/")
end

local function realpath(path)
  if not path or path == "" then
    return nil
  end
  local uv = vim.uv or vim.loop
  return uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

local is_absolute = document.is_absolute_path

local fugitive = require("diffbandit.git.fugitive")

local function work_tree_of_git_dir(git_dir)
  local parent = git_dir:match("^(.*)/%.git/?$")
  if parent then
    return parent
  end
  -- A linked worktree's git dir names its work tree's .git file.
  local fd = io.open(git_dir .. "/gitdir", "r")
  if fd then
    local dot_git = fd:read("*l")
    fd:close()
    if dot_git and dot_git ~= "" then
      return (dot_git:gsub("/%.git/?$", ""))
    end
  end
  -- Submodules and core.worktree: only git knows.
  local output = vim.fn.systemlist({ "git", "--git-dir=" .. git_dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and output[1] and output[1] ~= "" then
    return output[1]
  end
  return nil
end

-- A buffer name that is a URL rather than a file. Returns nil for a plain path;
-- otherwise { file, work_tree }, either of which may be nil. vim-fugitive names
-- its buffers fugitive://<git dir>//<stage or commit>[/<path>], and its status
-- buffer has no path. Other schemes (term://, oil://) say nothing about git.
local function buffer_url(name)
  if not name or not name:match("^%a[%w+.-]*://") then
    return nil
  end
  local parsed = fugitive.parse_url(name)
  if not parsed then
    return {}
  end
  local work_tree = work_tree_of_git_dir(parsed.git_dir)
  return {
    work_tree = work_tree,
    file = work_tree and parsed.path and (work_tree .. "/" .. parsed.path) or nil,
  }
end

local function path_dir(path)
  if not path or path == "" then
    local uv = vim.uv or vim.loop
    return uv.cwd()
  end
  local expanded = vim.fn.fnamemodify(path, ":p")
  if vim.fn.isdirectory(expanded) == 1 then
    return expanded
  end
  return vim.fn.fnamemodify(expanded, ":h")
end

-- The work tree containing dir, found the way git discovers it: the nearest
-- ancestor holding a .git directory (with a HEAD) or a .git file (linked
-- worktrees, submodules). Nil when the environment redirects discovery or
-- nothing is found, so find_root asks git.
local function discover_root(dir)
  for _, var in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_CEILING_DIRECTORIES" }) do
    if (vim.env[var] or "") ~= "" then
      return nil
    end
  end
  local uv = vim.uv or vim.loop
  local current = dir:gsub("/+$", "")
  while current ~= "" do
    local stat = uv.fs_stat(current .. "/.git")
    if stat then
      if stat.type == "file" or (stat.type == "directory" and uv.fs_stat(current .. "/.git/HEAD")) then
        return uv.fs_realpath(current)
      end
      return nil
    end
    current = current:match("^(.*)/[^/]*$") or ""
  end
  return nil
end

-- A process spawn is most of the cost of opening a view, so the root comes
-- from the filesystem when it can; git answers the unusual cases.
function M.find_root(start)
  local url = buffer_url(start)
  if url then
    start = url.work_tree
  end
  local dir = path_dir(start)
  local discovered = discover_root(dir)
  if discovered then
    return discovered, nil
  end
  local lines, err = git_lines(dir, { "rev-parse", "--show-toplevel" })
  if not lines or not lines[1] or lines[1] == "" then
    return nil, err ~= "" and err or "not inside a git repository"
  end
  return vim.fn.fnamemodify(lines[1], ":p"):gsub("/$", ""), nil
end

local function current_buffer_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return nil
  end
  local url = buffer_url(name)
  if url then
    if url.file or not url.work_tree then
      return url.file
    end
    -- fugitive's status buffer: the file under the cursor.
    local target = fugitive.status_target()
    return target and target.path and (url.work_tree .. "/" .. target.path) or nil
  end
  return name
end

function M.current_file()
  return current_buffer_path()
end

-- Where to look for the repository: the current file, or the work tree of a
-- buffer that belongs to one without being a file (fugitive's status).
local function current_buffer_start()
  local url = buffer_url(vim.api.nvim_buf_get_name(0))
  if url then
    return url.work_tree
  end
  return current_buffer_path()
end

local function relpath(root, path)
  if not path or path == "" then
    return nil
  end
  local url = buffer_url(path)
  if url then
    path = url.file
    if not path then
      return nil
    end
  end
  local abs = realpath(path) or vim.fn.fnamemodify(path, ":p")
  local root_abs = realpath(root) or vim.fn.fnamemodify(root, ":p")
  root_abs = root_abs:gsub("/$", "")
  if abs == root_abs then
    return ""
  end
  local prefix = root_abs .. "/"
  if abs:sub(1, #prefix) == prefix then
    return normalize_path(abs:sub(#prefix + 1))
  end
  return normalize_path(path)
end

function M.relpath(root, path)
  return relpath(root, path)
end

local function append_pathspecs(args, pathspecs)
  args[#args + 1] = "--"
  for _, pathspec in ipairs(pathspecs or {}) do
    args[#args + 1] = pathspec
  end
end

local function diff_args(opts)
  local mode = opts.mode or "unstaged"
  -- --raw costs the same as --name-status and also carries both sides'
  -- modes, which saves classify_entry three git calls per file.
  local args = { "diff", "--raw", "-z", "--no-ext-diff" }
  if opts.find_renames ~= false then
    args[#args + 1] = "-M"
  end
  if opts.find_copies == true then
    args[#args + 1] = "-C"
    args[#args + 1] = "--find-copies-harder"
  end

  if mode == "staged" then
    args[#args + 1] = "--cached"
  elseif mode == "all" then
    args[#args + 1] = opts.base or "HEAD"
  elseif mode == "rev" then
    args[#args + 1] = opts.base
    args[#args + 1] = opts.target
  elseif mode ~= "unstaged" then
    return nil, string.format("unsupported git diff mode: %s", tostring(mode))
  end

  append_pathspecs(args, opts.pathspecs)
  return args, nil
end

-- `git diff --raw -z`: ":<src mode> <dst mode> <src oid> <dst oid> <status>"
-- then one path, or two (old, new) for renames and copies. A 000000 mode is
-- a side the diff cannot see (absent, or not hashed yet); those entries keep
-- the lazy per-file mode lookup.
local function parse_raw(output)
  local tokens = split_nul(output)
  local entries = {}
  local i = 1
  while i <= #tokens do
    local src_mode, dst_mode, status = tokens[i]:match("^:(%d+) (%d+) %x+ %x+ (%u%d*)$")
    if not status then
      i = i + 1
    else
      local code = status:sub(1, 1)
      local entry
      if code == "R" or code == "C" then
        local old_path, new_path = tokens[i + 1], tokens[i + 2]
        if old_path and new_path then
          entry = { status = code, raw_status = status, path = normalize_path(new_path), old_path = normalize_path(old_path) }
        end
        i = i + 3
      else
        local path = tokens[i + 1]
        if path then
          entry = { status = code, raw_status = status, path = normalize_path(path) }
        end
        i = i + 2
      end
      if entry then
        if src_mode ~= "000000" and dst_mode ~= "000000" then
          entry.modes = { left = src_mode, right = dst_mode }
          entry.raw_modes = true
        end
        entries[#entries + 1] = entry
      end
    end
  end
  return entries
end

local function untracked_args(pathspecs)
  local args = { "ls-files", "--others", "--exclude-standard", "-z" }
  append_pathspecs(args, pathspecs)
  return args
end

local function parse_untracked(output)
  local entries = {}
  for _, path in ipairs(split_nul(output)) do
    entries[#entries + 1] = {
      status = "A",
      raw_status = "??",
      path = normalize_path(path),
      untracked = true,
    }
  end
  return entries
end

local function list_untracked(root, pathspecs)
  local output, err = git_output(root, untracked_args(pathspecs))
  if not output then
    return nil, err
  end
  return parse_untracked(output), nil
end

local function unmerged_args(pathspecs)
  local args = { "ls-files", "-u", "-z" }
  append_pathspecs(args, pathspecs)
  return args
end

local function parse_unmerged(output)
  local seen = {}
  local entries = {}
  for _, token in ipairs(split_nul(output)) do
    local path = token:match("\t(.+)$")
    path = normalize_path(path)
    if path and not seen[path] then
      seen[path] = true
      entries[#entries + 1] = {
        status = "U",
        raw_status = "U",
        path = path,
      }
    end
  end
  return entries
end

local function list_unmerged(root, pathspecs)
  local output, err = git_output(root, unmerged_args(pathspecs))
  if not output then
    return nil, err
  end
  return parse_unmerged(output), nil
end

local function path_set_from_nul(output)
  local set = {}
  for _, path in ipairs(split_nul(output)) do
    set[normalize_path(path)] = true
  end
  return set
end

local function stage_base_from_opts(opts)
  if type(opts) == "table" then
    return opts.stage_base
  elseif type(opts) == "string" then
    return opts
  end
  return nil
end

-- --no-renames lists both sides of a rename, which matches what per-path
-- `diff --cached -- <path>` checks report.
local function staged_set_args(stage_base)
  local args = { "diff", "--cached", "--name-only", "-z", "--no-ext-diff", "--no-renames" }
  if type(stage_base) == "string" and stage_base ~= "" then
    args[#args + 1] = stage_base
  end
  append_pathspecs(args, {})
  return args
end

local function worktree_set_args()
  return { "diff", "--name-only", "-z", "--no-ext-diff", "--" }
end

-- Lists the queue's entries. Every git call this needs (the diff, untracked
-- and unmerged listings, the unborn-HEAD probe, and the stage snapshot that
-- the panel and stage markers read) runs concurrently.
local function list_entries(root, opts)
  local probe_head = opts.mode == "all" and (opts.base == nil or opts.base == "HEAD")
  local args, arg_err = diff_args(opts)
  if not args then
    return nil, arg_err
  end
  local want_untracked = opts.include_untracked ~= false and (opts.mode == "unstaged" or opts.mode == "all")
  local pathspecs = opts.pathspecs or {}
  local want_snapshot = opts.mode ~= "rev" and opts.read_only ~= true
  -- The snapshot's untracked set is repository-wide; reuse the listing when
  -- it is too.
  local snapshot_untracked = want_snapshot and not (want_untracked and #pathspecs == 0)
  local snapshot_generation = generation
  local results = process.run_many({
    git_cmd(root, args),
    want_untracked and git_cmd(root, untracked_args(pathspecs)) or false,
    git_cmd(root, unmerged_args(pathspecs)),
    probe_head and git_cmd(root, { "rev-parse", "--verify", "HEAD" }) or false,
    want_snapshot and git_cmd(root, staged_set_args(stage_base_from_opts(opts))) or false,
    want_snapshot and git_cmd(root, worktree_set_args()) or false,
    snapshot_untracked and git_cmd(root, untracked_args({})) or false,
  })

  local output, err = results[1][1], results[1][2]
  if probe_head and results[4][2] then
    -- Unborn HEAD: compare against the empty tree instead.
    opts.base = empty_tree
    opts.unborn_head = true
    args = diff_args(opts)
    output, err = git_output(root, args)
  end
  if not output then
    return nil, err
  end
  local entries = parse_raw(output)

  local untracked = {}
  if want_untracked then
    if not results[2][1] then
      return nil, results[2][2]
    end
    untracked = parse_untracked(results[2][1])
    for _, entry in ipairs(untracked) do
      entries[#entries + 1] = entry
    end
  end

  if not results[3][1] then
    return nil, results[3][2]
  end
  for _, entry in ipairs(parse_unmerged(results[3][1])) do
    entries[#entries + 1] = entry
  end

  local snapshot
  if want_snapshot and results[5][1] and results[6][1] then
    local worktree = path_set_from_nul(results[6][1])
    local untracked_ok = true
    if snapshot_untracked then
      if results[7][1] then
        untracked = parse_untracked(results[7][1])
      else
        untracked_ok = false
      end
    end
    for _, entry in ipairs(untracked) do
      worktree[entry.path] = true
    end
    if untracked_ok then
      snapshot = {
        generation = snapshot_generation,
        stage_base = stage_base_from_opts(opts),
        staged = path_set_from_nul(results[5][1]),
        worktree = worktree,
      }
    end
  end

  local by_path = {}
  local deduped = {}
  local function priority(entry)
    if entry.status == "U" then
      return 100
    elseif entry.status == "R" or entry.status == "C" then
      return 80
    elseif entry.status == "T" then
      return 70
    end
    return 10
  end
  for _, entry in ipairs(entries) do
    local key = entry.path or ""
    local existing = by_path[key]
    if not existing then
      by_path[key] = entry
      deduped[#deduped + 1] = entry
    elseif priority(entry) > priority(existing) then
      for index, candidate in ipairs(deduped) do
        if candidate == existing then
          deduped[index] = entry
          break
        end
      end
      by_path[key] = entry
    end
  end
  entries = deduped

  table.sort(entries, function(a, b)
    return (a.path or "") < (b.path or "")
  end)
  return entries, nil, snapshot
end

local function abs_path(root, path)
  if is_absolute(path) then
    return path
  end
  return root .. "/" .. path
end

local function find_loaded_buffer(path)
  return document.find_loaded_buffer(path)
end

local function has_modified_loaded_buffer(root, path)
  local bufnr = find_loaded_buffer(abs_path(root, path))
  return bufnr ~= nil and vim.api.nvim_get_option_value("modified", { buf = bufnr }) == true
end

local function entry_uses_modified_buffer(root, entry)
  if not root or not entry then
    return false
  end
  return (entry.path and has_modified_loaded_buffer(root, entry.path))
    or (entry.old_path and has_modified_loaded_buffer(root, entry.old_path))
    or false
end

local function read_worktree(root, path, use_buffer)
  local full_path = abs_path(root, path)
  if use_buffer ~= false then
    local bufnr = find_loaded_buffer(full_path)
    if bufnr and vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return text.to_text(lines), nil, "buffer"
    end
  end

  local ok, lines = pcall(vim.fn.readfile, full_path)
  if not ok then
    return nil, string.format("unable to read worktree file: %s", full_path)
  end
  return text.to_text(lines), nil, "working tree"
end

local function read_worktree_raw(root, path)
  local full_path = abs_path(root, path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(full_path)
  if not stat then
    return nil, string.format("unable to read worktree file: %s", full_path)
  end
  local fd, open_err = uv.fs_open(full_path, "r", 438)
  if not fd then
    return nil, tostring(open_err or ("unable to open worktree file: " .. full_path))
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if data == nil then
    return nil, tostring(read_err or ("unable to read worktree file: " .. full_path))
  end
  return data, nil
end

-- Blobs already read for the file being loaded (see sources_for_entry).
local blob_memo

local function read_blob(root, spec)
  local hit = blob_memo and blob_memo.root == root and blob_memo.blobs[spec]
  if hit then
    return hit[1], hit[2]
  end
  local output, err = git_output(root, { "show", "--no-ext-diff", spec })
  if not output then
    return nil, err
  end
  return output, nil
end

local function git_summary(root, opts, path)
  local args = { "diff", "--summary", "--no-ext-diff" }
  local mode = opts.mode or "unstaged"
  if mode == "staged" then
    args[#args + 1] = "--cached"
  elseif mode == "all" then
    args[#args + 1] = opts.base or "HEAD"
  elseif mode == "rev" then
    args[#args + 1] = opts.base
    args[#args + 1] = opts.target
  elseif mode ~= "unstaged" then
    return nil
  end
  append_pathspecs(args, { path })
  local output = git_output(root, args)
  output = output and vim.trim(output) or ""
  return output ~= "" and output or nil
end

local function tree_mode(root, ref, path)
  if not ref or ref == "" or not path or path == "" then
    return nil
  end
  local output = git_output(root, { "ls-tree", ref, "--", path })
  if not output or output == "" then
    return nil
  end
  return output:match("^(%d+)")
end

local function index_entry(root, path)
  local output = git_output(root, { "ls-files", "-s", "--", path })
  if not output or output == "" then
    return nil
  end
  local mode, oid = output:match("^(%d+)%s+(%x+)")
  return mode and { mode = mode, oid = oid } or nil
end

local function worktree_mode(root, path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_lstat(abs_path(root, path))
  if not stat then
    return nil
  end
  if stat.type == "link" then
    return "120000"
  end
  if stat.type == "directory" then
    return "040000"
  end
  if stat.mode and (stat.mode % 128) >= 64 then
    return "100755"
  end
  return "100644"
end

local function read_worktree_symlink(root, path)
  local uv = vim.uv or vim.loop
  return uv.fs_readlink(abs_path(root, path))
end

local function entry_modes(queue, entry)
  if entry.modes then
    return entry.modes
  end
  local root = queue.root
  local opts = queue.opts or {}
  local mode = opts.mode or "unstaged"
  local left_path = entry.old_path or entry.path
  local right_path = entry.path
  local modes = {}
  if entry.untracked then
    -- Not in the index or any tree: only the worktree side has a mode.
    modes.right = worktree_mode(root, right_path)
  elseif mode == "unstaged" then
    local index = index_entry(root, left_path)
    modes.left = index and index.mode or nil
    modes.right = worktree_mode(root, right_path) or modes.left
  elseif mode == "staged" then
    modes.left = tree_mode(root, opts.base or "HEAD", left_path)
    local index = index_entry(root, right_path)
    modes.right = index and index.mode or nil
  elseif mode == "all" then
    modes.left = tree_mode(root, opts.base or "HEAD", left_path)
    local index = index_entry(root, right_path)
    modes.right = worktree_mode(root, right_path) or (index and index.mode or nil)
  elseif mode == "rev" then
    modes.left = tree_mode(root, opts.base, left_path)
    modes.right = tree_mode(root, opts.target, right_path)
  end
  entry.modes = modes
  return modes
end

local function numstat(root, opts, path)
  local args = { "diff", "--numstat", "--no-ext-diff" }
  local mode = opts.mode or "unstaged"
  if mode == "staged" then
    args[#args + 1] = "--cached"
  elseif mode == "all" then
    args[#args + 1] = opts.base or "HEAD"
  elseif mode == "rev" then
    args[#args + 1] = opts.base
    args[#args + 1] = opts.target
  elseif mode ~= "unstaged" then
    return nil
  end
  append_pathspecs(args, { path })
  local output = git_output(root, args)
  output = output and vim.trim(output) or ""
  return output ~= "" and output or nil
end

-- The diff-source factory lives in git_sources.lua; hand it the low-level
-- readers it needs so the two modules stay cycle-free.
local sources = git_sources.new({
  git_summary = git_summary,
  numstat = numstat,
  entry_modes = entry_modes,
  abs_path = abs_path,
  read_blob = read_blob,
  read_worktree = read_worktree,
  read_worktree_raw = read_worktree_raw,
  read_worktree_symlink = read_worktree_symlink,
  find_loaded_buffer = find_loaded_buffer,
  has_modified_loaded_buffer = has_modified_loaded_buffer,
})
local source_from_kind = sources.source_from_kind

local function normalize_opts(opts, config)
  opts = vim.tbl_extend("force", {}, config or {}, opts or {})
  opts.mode = opts.mode or opts.default_mode or "unstaged"
  opts.scope = opts.scope or opts.default_scope or "repo"
  if opts.mode == "cached" then
    opts.mode = "staged"
  end
  if opts.mode == "rev" and (not opts.base or not opts.target) then
    return nil, "revision mode requires both base and target revisions"
  end
  if opts.mode == "all" then
    opts.base = opts.base or "HEAD"
  end
  opts.pathspecs = opts.pathspecs or {}
  return opts, nil
end

function M.queue(opts, config)
  local normalized, normalize_err = normalize_opts(opts, config)
  if not normalized then
    return nil, normalize_err
  end

  local uv = vim.uv or vim.loop
  local start = normalized.root
    or normalized.path
    or (normalized.scope == "current" and normalized.pathspecs and normalized.pathspecs[1])
    or current_buffer_start()
    or uv.cwd()
  local root, root_err = M.find_root(start)
  if not root then
    return nil, root_err
  end
  normalized.root = root

  if normalized.scope == "current" then
    local target = normalized.path or (normalized.pathspecs and normalized.pathspecs[1]) or current_buffer_path()
    if not target then
      return nil, "no current file for git diff"
    end
    normalized.pathspecs = { relpath(root, target) }
  end
  if normalized.mode == "rev" and normalized.merge_base then
    local merge_base, merge_base_err = M.merge_base(root, normalized.base, normalized.target)
    if not merge_base then
      return nil, merge_base_err or "no merge base"
    end
    normalized.base = merge_base
    normalized.merge_base = nil
  end
  local entries, entries_err, snapshot = list_entries(root, normalized)
  if not entries then
    return nil, entries_err
  end
  if #entries == 0 and normalized.scope == "current" and normalized.use_buffer ~= false then
    local current_path = normalized.pathspecs and normalized.pathspecs[1]
    if current_path and has_modified_loaded_buffer(root, current_path) then
      entries[#entries + 1] = {
        status = "M",
        raw_status = "buffer",
        path = normalize_path(current_path),
        buffer_only = true,
      }
    end
  end
  if #entries == 0 then
    return nil, "no git changes"
  end

  local queue = {
    kind = "git",
    root = root,
    opts = normalized,
    entries = entries,
    index = 1,
    source_cache = {},
  }
  if snapshot then
    queue.stage_snapshot = snapshot
    -- Valid for the synchronous build that follows (first file, panel
    -- marks). By the next event-loop turn the user may have saved a file or
    -- staged from a shell, so later reads go back to git.
    vim.schedule(function()
      if queue.stage_snapshot == snapshot then
        queue.stage_snapshot = nil
      end
    end)
  end

  function queue.load(index)
    local entry = queue.entries[index]
    local cacheable = normalized.use_buffer == false or not entry_uses_modified_buffer(root, entry)
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

function M.root(opts)
  opts = opts or {}
  local uv = vim.uv or vim.loop
  local start = opts.root
    or opts.path
    or current_buffer_start()
    or uv.cwd()
  return M.find_root(start)
end

function M.list_branches(root)
  local output, err = git_output(root, {
    "for-each-ref",
    "--format=%(HEAD)%09%(refname)%09%(refname:short)%09%(objectname:short)%09%(upstream:short)",
    "refs/heads",
    "refs/remotes",
  })
  if not output then
    return nil, err
  end

  local branches = {}
  for _, line in ipairs(text.split_lines(output)) do
    local current, refname, name, oid, upstream = line:match("^([%* ])\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
    if name and name ~= "" and not name:match("/HEAD$") then
      branches[#branches + 1] = {
        refname = refname,
        name = name,
        oid = oid ~= "" and oid or nil,
        upstream = upstream ~= "" and upstream or nil,
        current = current == "*",
        remote = refname and refname:match("^refs/remotes/") ~= nil,
      }
    end
  end
  table.sort(branches, function(a, b)
    if a.current ~= b.current then
      return a.current == true
    end
    return (a.name or "") < (b.name or "")
  end)
  return branches, nil
end

local function log_format_args()
  return {
    "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ad%x1f%s%x1e",
    "--date=short",
  }
end

function M.log(root, opts)
  opts = opts or {}
  local args = { "log" }
  vim.list_extend(args, log_format_args())
  if opts.all then
    args[#args + 1] = "--all"
  end
  if opts.max_count then
    args[#args + 1] = "--max-count=" .. tostring(opts.max_count)
  end
  if opts.rev then
    args[#args + 1] = opts.rev
  end
  append_pathspecs(args, opts.pathspecs or {})

  local output, err = git_output(root, args)
  if not output then
    return nil, err
  end

  local commits = {}
  for _, record in ipairs(split_char(output, "\30")) do
    record = vim.trim(record)
    if record ~= "" then
      local fields = split_char(record, "\31")
      local parents = fields[3] and vim.split(fields[3], " ", { plain = true, trimempty = true }) or {}
      commits[#commits + 1] = {
        hash = fields[1],
        short_hash = fields[2],
        parents = parents,
        author = fields[4],
        date = fields[5],
        subject = fields[6],
      }
    end
  end
  return commits, nil
end

function M.commit_metadata(root, rev)
  local commits, err = M.log(root, { rev = "-1", max_count = 1 })
  if not commits then
    return nil, err
  end
  if rev and rev ~= "" then
    local args = { "log" }
    vim.list_extend(args, log_format_args())
    args[#args + 1] = "-1"
    args[#args + 1] = rev
    local output, output_err = git_output(root, args)
    if not output then
      return nil, output_err
    end
    commits = {}
    for _, record in ipairs(split_char(output, "\30")) do
      record = vim.trim(record)
      if record ~= "" then
        local fields = split_char(record, "\31")
        local parents = fields[3] and vim.split(fields[3], " ", { plain = true, trimempty = true }) or {}
        commits[#commits + 1] = {
          hash = fields[1],
          short_hash = fields[2],
          parents = parents,
          author = fields[4],
          date = fields[5],
          subject = fields[6],
        }
      end
    end
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

-- A queue's options with a comparison from fugitive.entry_target applied, or nil
-- when DiffBandit has no way to show it: staged mode only compares against HEAD.
function M.with_comparison(root, opts, comparison)
  if comparison.mode == "staged" then
    local head = git_output(root, { "rev-parse", "HEAD" })
    if not head or vim.trim(head) ~= comparison.base then
      return nil
    end
  end
  local next_opts = vim.tbl_extend("force", {}, opts or {})
  next_opts.mode = comparison.mode
  next_opts.base = comparison.mode ~= "staged" and comparison.base or nil
  next_opts.target = comparison.target
  next_opts.merge_base = nil
  next_opts.review = nil
  next_opts.read_only = comparison.mode == "rev" or nil
  next_opts.include_untracked = nil
  if comparison.mode == "rev" then
    next_opts.include_untracked = false
  end
  return next_opts
end

function M.commit_queue(root, rev, opts, config)
  if not rev or rev == "" then
    return nil, "commit revision is required"
  end
  opts = opts or {}
  local meta, meta_err = M.commit_metadata(root, rev)
  if not meta then
    return nil, meta_err
  end
  local base = meta.parents and meta.parents[1]
  if not base or base == "" then
    base = empty_tree
  end
  local queue_opts = review_queue_opts(vim.tbl_extend("force", opts, {
    root = root,
    base = base,
    target = rev,
  }), {
    kind = "commit",
    title = (meta.short_hash or rev) .. " " .. (meta.subject or ""),
    commit = meta,
    base = base,
    target = rev,
  })
  return M.queue(queue_opts, config)
end

function M.merge_base(root, base, target)
  local output, err = git_output(root, { "merge-base", base, target })
  if not output then
    return nil, err
  end
  output = vim.trim(output)
  return output ~= "" and output or nil, nil
end

-- The branch a feature branch merges back into: the remote's HEAD
-- (origin/HEAD -> origin/main), else a local main or master.
function M.default_branch(root)
  local remotes = {}
  local upstream_remote = git_output(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })
  upstream_remote = upstream_remote and vim.trim(upstream_remote):match("^([^/]+)/")
  if upstream_remote then
    remotes[#remotes + 1] = upstream_remote
  end
  if upstream_remote ~= "origin" then
    remotes[#remotes + 1] = "origin"
  end
  for _, remote in ipairs(remotes) do
    local ref = git_output(root, { "rev-parse", "--abbrev-ref", remote .. "/HEAD" })
    ref = ref and vim.trim(ref) or ""
    if ref ~= "" and ref ~= remote .. "/HEAD" and M.is_revision(root, ref) then
      return ref, nil
    end
  end
  for _, name in ipairs({ "main", "master" }) do
    if M.is_revision(root, name) then
      return name, nil
    end
  end
  return nil, "no default branch found (no origin/HEAD, main, or master); name a base: diffbandit compare <base>"
end

-- The current branch's upstream (@{upstream}) as a short ref, or nil.
function M.upstream(root)
  local ref = git_output(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })
  ref = ref and vim.trim(ref) or ""
  if ref == "" then
    return nil, "the current branch has no upstream"
  end
  return ref, nil
end

-- True when rev names a commit-ish (used to tell revisions from pathspecs).
function M.is_revision(root, rev)
  if not rev or rev == "" or rev:sub(1, 1) == "-" then
    return false
  end
  return git_exit_code(root, { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }) == 0
end

function M.compare_queue(root, base, target, opts, config)
  opts = opts or {}
  base = base and base ~= "" and base or "HEAD"
  target = target and target ~= "" and target or "HEAD"
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

function M.is_worktree_dirty(root)
  local output, err = git_output(root, { "status", "--porcelain=v1", "-z" })
  if not output then
    return false, err
  end
  return output ~= "", nil
end

local has_in_progress_operation

function M.checkout_branch(root, branch, opts)
  opts = opts or {}
  if not branch or branch == "" then
    return false, "branch is required"
  end
  if has_in_progress_operation(root) then
    return false, "cannot switch branches while a Git operation is in progress"
  end
  local dirty, dirty_err = M.is_worktree_dirty(root)
  if dirty_err then
    return false, dirty_err
  end
  if dirty and opts.force ~= true then
    return false, "worktree has uncommitted changes"
  end
  local args = { "switch" }
  if opts.create == true then
    args[#args + 1] = "-c"
  end
  args[#args + 1] = branch
  local _, err = git_output(root, args)
  return err == nil, err
end

-- HEAD and index blob specs for a file whose stage markers compare them
-- (session/actions staged_chunk_states), or nil.
local function stage_blob_specs(queue, entry)
  local opts = queue.opts or {}
  local mode = opts.mode or "unstaged"
  if (mode ~= "all" and mode ~= "unstaged") or (opts.base or "HEAD") ~= "HEAD" then
    return nil
  end
  if entry.untracked or not entry.path or not entry.actions_enabled then
    return nil
  end
  return { "HEAD:" .. entry.path, ":" .. entry.path }
end

function M.generation()
  return generation
end

function M.sources_for_entry(queue, index)
  local entry = queue.entries[index]
  if not entry then
    return nil, "no changed file at queue index " .. tostring(index)
  end

  -- Read the blobs the left side and the stage markers need in one
  -- concurrent batch; the left source then takes its blob from the memo.
  sources.classify_entry(queue, entry)
  local specs = stage_blob_specs(queue, entry)
  local stage_blobs
  if specs then
    local read_generation = generation
    local read = M.read_blobs(queue.root, specs)
    blob_memo = { root = queue.root, blobs = { [specs[1]] = read[1], [specs[2]] = read[2] } }
    stage_blobs = { head = read[1][1] or "", index = read[2][1] or "", generation = read_generation }
  end
  local ok, left, left_err = pcall(source_from_kind, queue, entry, "left")
  blob_memo = nil
  if not ok then
    error(left, 0)
  end
  if not left then
    return nil, left_err
  end
  local right, right_err = source_from_kind(queue, entry, "right")
  if not right then
    return nil, right_err
  end
  left.git_stage_blobs = stage_blobs

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

  return {
    left = left,
    right = right,
    entry = entry,
    index = index,
  }, nil
end

function M.read_index(root, path)
  return read_blob(root, ":" .. path)
end

function M.read_head(root, path, base)
  return read_blob(root, (base or "HEAD") .. ":" .. path)
end

-- read_blob() for several specs at once, concurrently. Returns a list of
-- { text, err } in spec order.
function M.read_blobs(root, specs)
  local cmds = {}
  for index, spec in ipairs(specs) do
    cmds[index] = git_cmd(root, { "show", "--no-ext-diff", spec })
  end
  return process.run_many(cmds)
end

function M.read_conflict_stage(root, path, stage)
  stage = tonumber(stage)
  if not stage or stage < 1 or stage > 3 then
    return nil, "invalid conflict stage: " .. tostring(stage)
  end
  return read_blob(root, ":" .. tostring(stage) .. ":" .. path)
end

function M.conflict_stages(root, path)
  local base = M.read_conflict_stage(root, path, 1)
  local local_text = M.read_conflict_stage(root, path, 2)
  local remote_text = M.read_conflict_stage(root, path, 3)
  if not local_text and not remote_text then
    return nil, "no unmerged stages for " .. tostring(path)
  end
  return {
    base = base,
    local_text = local_text,
    remote = remote_text,
    has_base = base ~= nil,
    has_local = local_text ~= nil,
    has_remote = remote_text ~= nil,
  }, nil
end

local function first_line(text)
  if not text or text == "" then
    return nil
  end
  return vim.split(text, "\n", { plain = true })[1]
end

local function git_path(root, name)
  local output = git_output(root, { "rev-parse", "--git-path", name })
  output = output and vim.trim(output) or ""
  if output == "" then
    return nil
  end
  if is_absolute(output) then
    return output
  end
  return abs_path(root, output)
end

local function read_git_path(root, name)
  local path = git_path(root, name)
  if not path then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or not lines[1] then
    return nil
  end
  return lines[1]
end

function has_in_progress_operation(root)
  return read_git_path(root, "MERGE_HEAD") ~= nil
    or read_git_path(root, "CHERRY_PICK_HEAD") ~= nil
    or read_git_path(root, "REVERT_HEAD") ~= nil
    or read_git_path(root, "REBASE_HEAD") ~= nil
    or read_git_path(root, "rebase-merge/head-name") ~= nil
    or read_git_path(root, "rebase-apply/head-name") ~= nil
end

local function short_commit(root, rev)
  local output = git_output(root, { "rev-parse", "--short", rev })
  output = output and vim.trim(output) or ""
  return output ~= "" and output or nil
end

local function current_branch_label(root)
  local branch = git_output(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  branch = branch and vim.trim(branch) or ""
  if branch ~= "" then
    return branch
  end
  local short = short_commit(root, "HEAD")
  return short and ("detached " .. short) or "detached HEAD"
end

-- Defined after current_branch_label: above it, the name would resolve to
-- an (unset) global instead of the local.
function M.current_branch(root)
  return current_branch_label(root)
end

local function commit_name(root, rev)
  local name = git_output(root, { "name-rev", "--name-only", "--exclude=tags/*", rev })
  name = name and vim.trim(name) or ""
  if name ~= "" and name ~= "undefined" then
    name = name:gsub("^remotes/", "")
    name = name:gsub("%^0$", "")
    return name
  end
  return short_commit(root, rev)
end

function M.merge_context(root)
  local current = current_branch_label(root)
  local merge_head = first_line(read_git_path(root, "MERGE_HEAD"))
  if merge_head then
    return {
      operation = "merge",
      current = current,
      incoming = commit_name(root, merge_head) or short_commit(root, merge_head) or "incoming",
      incoming_ref = merge_head,
    }
  end

  local cherry_pick_head = first_line(read_git_path(root, "CHERRY_PICK_HEAD"))
  if cherry_pick_head then
    return {
      operation = "cherry-pick",
      current = current,
      incoming = commit_name(root, cherry_pick_head) or short_commit(root, cherry_pick_head) or "incoming commit",
      incoming_ref = cherry_pick_head,
    }
  end

  local rebase_head = first_line(read_git_path(root, "REBASE_HEAD"))
  if rebase_head then
    return {
      operation = "rebase",
      current = current,
      incoming = commit_name(root, rebase_head) or short_commit(root, rebase_head) or "rebased commit",
      incoming_ref = rebase_head,
    }
  end

  local revert_head = first_line(read_git_path(root, "REVERT_HEAD"))
  if revert_head then
    return {
      operation = "revert",
      current = current,
      incoming = commit_name(root, revert_head) or short_commit(root, revert_head) or "reverted commit",
      incoming_ref = revert_head,
    }
  end

  local rebase_branch = read_git_path(root, "rebase-merge/head-name")
    or read_git_path(root, "rebase-apply/head-name")
  if rebase_branch then
    return {
      operation = "rebase",
      current = current,
      incoming = rebase_branch:gsub("^refs/heads/", ""),
      incoming_ref = rebase_branch,
    }
  end

  return {
    operation = "merge",
    current = current,
    incoming = "incoming",
  }
end

function M.unmerged_entries(root, pathspecs)
  return list_unmerged(root, pathspecs or {})
end

function M.read_worktree(root, path, use_buffer)
  return read_worktree(root, path, use_buffer)
end

function M.find_loaded_buffer(root, path)
  return find_loaded_buffer(abs_path(root, path))
end

function M.abs_path(root, path)
  return abs_path(root, path)
end

function M.relpath(root, path)
  return relpath(root, path)
end

function M.git_output(root, args)
  return git_output(root, args)
end

function M.amend_base(root)
  if not has_head(root) then
    return nil, "cannot amend before the first commit"
  end
  local _, parent_err = git_output(root, { "rev-parse", "--verify", "HEAD^" })
  if not parent_err then
    return "HEAD^", nil
  end
  return empty_tree, nil
end

function M.has_staged_changes(root, path, base)
  local args = { "diff", "--cached", "--name-only" }
  if type(base) == "string" and base ~= "" then
    args[#args + 1] = base
  end
  append_pathspecs(args, { path })
  local output, err = git_output(root, args)
  if not output then
    return false, err
  end
  return vim.trim(output) ~= "", nil
end

local function has_untracked_file(root, path)
  local output = git_output(root, { "ls-files", "--others", "--exclude-standard", "--", path })
  return output and vim.trim(output) ~= ""
end

local function has_worktree_changes(root, path)
  local code = git_exit_code(root, { "diff", "--quiet", "--", path })
  return code == 1 or has_untracked_file(root, path)
end

local function has_entry_path(set, entry)
  if not set or not entry then
    return false
  end
  return (entry.path and set[entry.path])
    or (entry.old_path and set[entry.old_path])
    or false
end

-- Staged and worktree path sets, read concurrently.
local function stage_path_sets(root, opts)
  local results = process.run_many({
    git_cmd(root, staged_set_args(stage_base_from_opts(opts))),
    git_cmd(root, worktree_set_args()),
    git_cmd(root, untracked_args({})),
  })
  local staged = results[1][1] and path_set_from_nul(results[1][1]) or nil
  local worktree = results[2][1] and path_set_from_nul(results[2][1]) or nil
  if worktree and results[3][1] then
    for _, entry in ipairs(parse_untracked(results[3][1])) do
      worktree[entry.path] = true
    end
  end
  return staged, worktree
end

-- The queue's stage snapshot, when it is still current: taken during this
-- event-loop turn, with no index- or worktree-changing git command since,
-- and for the same stage base.
local function live_stage_snapshot(queue, opts)
  local snapshot = queue and queue.stage_snapshot
  if not snapshot or snapshot.generation ~= generation then
    return nil
  end
  if snapshot.stage_base ~= stage_base_from_opts(opts or queue.opts) then
    return nil
  end
  return snapshot
end

-- has_staged_changes() from the queue's stage snapshot: true/false while
-- the snapshot is live, nil when only git can tell.
function M.snapshot_has_staged_changes(queue, path)
  local snapshot = live_stage_snapshot(queue, {})
  if snapshot and path then
    return snapshot.staged[normalize_path(path)] == true
  end
  return nil
end

function M.file_stage_state(root, entry, opts)
  if not root or not entry or not entry.path then
    return "unstaged"
  end
  local stage_base = stage_base_from_opts(opts)
  local staged = M.has_staged_changes(root, entry.path, stage_base)
  if not staged and entry.old_path then
    staged = M.has_staged_changes(root, entry.old_path, stage_base)
  end
  local unstaged = has_worktree_changes(root, entry.path)
  if not unstaged and entry.old_path then
    unstaged = has_worktree_changes(root, entry.old_path)
  end
  if staged and unstaged then
    return "partial"
  elseif staged then
    return "staged"
  end
  return "unstaged"
end

local function states_from_sets(entries, staged_set, worktree_set)
  local states = {}
  for index, entry in ipairs(entries or {}) do
    local staged = has_entry_path(staged_set, entry)
    local unstaged = has_entry_path(worktree_set, entry)
    if staged and unstaged then
      states[index] = "partial"
    elseif staged then
      states[index] = "staged"
    else
      states[index] = "unstaged"
    end
  end
  return states
end

function M.file_stage_states(root, entries, opts)
  local states = {}
  if not root then
    for index, _ in ipairs(entries or {}) do
      states[index] = "unstaged"
    end
    return states
  end

  local staged_set, worktree_set = stage_path_sets(root, opts)
  if staged_set and worktree_set then
    return states_from_sets(entries, staged_set, worktree_set)
  end

  for index, entry in ipairs(entries or {}) do
    states[index] = M.file_stage_state(root, entry, opts)
  end
  return states
end

-- file_stage_states() for a queue, from its stage snapshot while it is live.
function M.queue_stage_states(queue)
  queue = queue or {}
  local snapshot = live_stage_snapshot(queue)
  if snapshot then
    return states_from_sets(queue.entries, snapshot.staged, snapshot.worktree)
  end
  return M.file_stage_states(queue.root, queue.entries, queue.opts or {})
end

local function entry_paths(entry)
  local paths = {}
  if entry and entry.old_path and entry.old_path ~= entry.path then
    paths[#paths + 1] = entry.old_path
  end
  if entry and entry.path then
    paths[#paths + 1] = entry.path
  end
  return paths
end

local function untracked_path_set(root, path)
  local entries, err = list_untracked(root, path and { path } or {})
  if not entries then
    return nil, err
  end
  local set = {}
  for _, entry in ipairs(entries) do
    if entry.path then
      set[entry.path] = true
    end
  end
  return set, nil
end

local function stage_args(entry)
  local args = { "add", "-A" }
  append_pathspecs(args, entry_paths(entry))
  return args
end

local function unstage_args(entry, opts)
  local args = { "restore", "--staged" }
  local stage_base = stage_base_from_opts(opts)
  if stage_base and stage_base ~= "" then
    args[#args + 1] = "--source=" .. stage_base
  end
  append_pathspecs(args, entry_paths(entry))
  return args
end

-- In an unborn repository there is no HEAD to restore from. Removing the
-- path from the index is the equivalent of unstaging the file.
local function unstage_fallback_args(entry)
  local args = { "rm", "--cached", "-r", "--ignore-unmatch" }
  append_pathspecs(args, entry_paths(entry))
  return args
end

function M.stage_file(root, entry)
  if not root or not entry or not entry.path then
    return false, "no Git file entry to stage"
  end
  local _, err = git_output(root, stage_args(entry))
  return err == nil, err
end

function M.unstage_file(root, entry, opts)
  if not root or not entry or not entry.path then
    return false, "no Git file entry to unstage"
  end

  local _, err = git_output(root, unstage_args(entry, opts))
  if not err then
    return true, nil
  end

  local _, rm_err = git_output(root, unstage_fallback_args(entry))
  return rm_err == nil, rm_err or err
end

function M.toggle_file_stage(root, entry, opts)
  local state = M.file_stage_state(root, entry, opts)
  if state == "staged" or state == "partial" then
    return M.unstage_file(root, entry, opts)
  end
  return M.stage_file(root, entry)
end

function M.discard_worktree_file(root, entry)
  if not root or not entry or not entry.path then
    return false, "no Git file entry to discard"
  end
  if entry.untracked then
    return false, "untracked files cannot be discarded from the index"
  end
  if entry.old_path and entry.old_path ~= entry.path then
    return false, "renamed files cannot be discarded from the commit panel"
  end
  local _, err = git_output(root, { "restore", "--worktree", "--", entry.path })
  return err == nil, err
end

function M.delete_untracked_file(root, entry)
  invalidate_snapshots()
  if not root or not entry or not entry.path then
    return false, "no untracked file entry to delete"
  end
  if not entry.untracked then
    return false, "refusing to delete a tracked file"
  end
  local untracked, err = untracked_path_set(root, entry.path)
  if not untracked then
    return false, err
  end
  if not untracked[entry.path] then
    return false, "refusing to delete a file that is no longer untracked"
  end
  local full_path = abs_path(root, entry.path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_lstat(full_path)
  if not stat then
    return true, nil
  end
  if stat.type == "directory" then
    return false, "refusing to recursively delete an untracked directory"
  end
  local ok, remove_err = os.remove(full_path)
  return ok == true, remove_err
end

function M.append_gitignore(root, pattern)
  invalidate_snapshots()
  if not root or root == "" then
    return false, "no Git root configured"
  end
  pattern = tostring(pattern or "")
  if pattern == "" then
    return false, "no .gitignore pattern supplied"
  end
  local path = abs_path(root, ".gitignore")
  local lines = {}
  if vim.fn.filereadable(path) == 1 then
    local ok, existing = pcall(vim.fn.readfile, path)
    if not ok then
      return false, tostring(existing)
    end
    lines = existing
  end
  for _, line in ipairs(lines) do
    if line == pattern then
      return true, nil
    end
  end
  lines[#lines + 1] = pattern
  local ok, write_err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return false, tostring(write_err)
  end
  return true, nil
end

function M.toggle_file_stage_async(root, entry, opts, state, callback)
  if not root or not entry or not entry.path then
    vim.schedule(function()
      callback(false, "no Git file entry to stage")
    end)
    return
  end

  local unstage = state == "staged" or state == "partial"
  if not state then
    state = M.file_stage_state(root, entry, opts)
    unstage = state == "staged" or state == "partial"
  end

  local args = unstage and unstage_args(entry, opts) or stage_args(entry)
  git_async(root, args, function(ok, err)
    if ok or not unstage then
      callback(ok, err)
      return
    end

    git_async(root, unstage_fallback_args(entry), function(rm_ok, rm_err)
      callback(rm_ok, rm_err or err)
    end)
  end)
end

function M.has_any_staged_changes(root)
  local code = git_exit_code(root, { "diff", "--cached", "--quiet" })
  return code == 1
end

function M.has_pending_merge_commit(root)
  return read_git_path(root, "MERGE_HEAD") ~= nil
end

function M.has_unmerged(root)
  local output, err = git_output(root, { "ls-files", "-u", "-z" })
  if not output then
    return false, err
  end
  return output ~= "", nil
end

function M.last_commit_message(root)
  local output, err = git_output(root, { "log", "-1", "--pretty=%B" })
  if not output then
    return nil, err
  end
  return vim.trim(output), nil
end

local function write_temp_lines(lines)
  local tmp = vim.fn.tempname()
  local ok, write_err = pcall(vim.fn.writefile, lines, tmp)
  if not ok then
    return nil, tostring(write_err)
  end
  return tmp, nil
end

function M.commit(root, message, opts)
  opts = opts or {}
  message = message or ""
  if vim.trim(message) == "" then
    return false, "commit message cannot be empty"
  end
  local unmerged, unmerged_err = M.has_unmerged(root)
  if unmerged_err then
    return false, unmerged_err
  elseif unmerged then
    return false, "merge conflicts must be resolved before committing"
  end
  if opts.amend then
    if not has_head(root) then
      return false, "cannot amend before the first commit"
    end
  elseif not M.has_any_staged_changes(root) and not M.has_pending_merge_commit(root) then
    return false, "no staged changes to commit"
  end

  local tmp, write_err = write_temp_lines(vim.split(message, "\n", { plain = true }))
  if not tmp then
    return false, write_err
  end

  local args = { "commit" }
  if opts.amend then
    args[#args + 1] = "--amend"
  end
  args[#args + 1] = "-F"
  args[#args + 1] = tmp
  local _, err = git_output(root, args)
  pcall(os.remove, tmp)
  return err == nil, err
end

local function index_mode(root, path)
  local output = git_output(root, { "ls-files", "-s", "--", path })
  if output and output ~= "" then
    local mode = output:match("^(%d+)%s")
    if mode and mode ~= "" then
      return mode
    end
  end

  local stat = (vim.uv or vim.loop).fs_stat(abs_path(root, path))
  if stat and stat.mode and (stat.mode % 128) >= 64 then
    return "100755"
  end
  return "100644"
end

function M.write_index(root, path, value)
  if value == nil then
    local _, err = git_output(root, { "update-index", "--force-remove", "--", path })
    return err == nil, err
  end

  local tmp, write_err = write_temp_lines(text.split_lines(value))
  if not tmp then
    return false, write_err
  end

  local hash, hash_err = git_output(root, { "hash-object", "-w", tmp })
  pcall(os.remove, tmp)
  if not hash then
    return false, hash_err
  end
  hash = vim.trim(hash)

  local mode = index_mode(root, path)
  local _, update_err = git_output(root, { "update-index", "--add", "--cacheinfo", mode .. "," .. hash .. "," .. path })
  if update_err then
    return false, update_err
  end
  return true, nil
end

function M.write_worktree(root, path, value, use_buffer)
  invalidate_snapshots()
  local full_path = abs_path(root, path)
  if use_buffer ~= false then
    local bufnr = find_loaded_buffer(full_path)
    if bufnr then
      local was_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
      if not was_modifiable then
        local mod_ok, mod_err = pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = bufnr })
        if not mod_ok then
          return false, tostring(mod_err)
        end
      end
      local lines = value == nil and {} or text.split_lines(value)
      local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
      if not was_modifiable then
        pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })
      end
      if not ok then
        return false, tostring(err)
      end
      if value == nil then
        if vim.fn.filereadable(full_path) == 1 then
          local remove_ok, remove_err = os.remove(full_path)
          if not remove_ok then
            return false, remove_err
          end
        end
      else
        vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
        local write_ok, write_err = pcall(vim.fn.writefile, lines, full_path)
        if not write_ok then
          return false, tostring(write_err)
        end
      end
      pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
      return true, nil
    end
  end

  if value == nil then
    if vim.fn.filereadable(full_path) == 1 then
      local ok, err = os.remove(full_path)
      if not ok then
        return false, err
      end
    end
    return true, nil
  end

  vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, text.split_lines(value), full_path)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

M._private = {
  parse_raw = parse_raw,
  discover_root = discover_root,
  split_char = split_char,
}

return M
