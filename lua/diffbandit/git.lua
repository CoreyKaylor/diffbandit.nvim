local hex = require("diffbandit.hex")

local M = {}

local function to_text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function detect_filetype(path)
  if not path or path == "" then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

local function source_from_text(text, path, label, metadata)
  local lines = split_lines(text or "")
  local source = {
    path = path,
    label = label or path,
    lines = lines,
    text = to_text(lines),
    filetype = detect_filetype(path),
  }
  for key, value in pairs(metadata or {}) do
    source[key] = value
  end
  return source
end

local function source_from_hex(text, path, label, metadata, opts)
  local dump = hex.dump(text or "", opts and opts.hex or {})
  local source = {
    path = path,
    label = label or path,
    lines = dump.lines,
    text = dump.text,
    filetype = "diffbandit-hex",
    display_numbers = dump.display_numbers,
    display_number_width = dump.display_number_width,
    git_binary_hex = true,
    git_readonly_reason = "binary hex view is read-only",
    hex_total_bytes = dump.total_bytes,
    hex_visible_bytes = dump.visible_bytes,
    hex_truncated = dump.truncated,
  }
  for key, value in pairs(metadata or {}) do
    source[key] = value
  end
  return source
end

local function source_from_binary_notice(path, label, metadata)
  local source = source_from_text("[DiffBandit: binary file hidden]\n", path, label, metadata)
  source.git_binary_hidden = true
  source.git_readonly_reason = "binary file is not rendered as text"
  return source
end

local function run_command(cmd)
  if vim.system then
    local result = vim.system(cmd, { text = false }):wait()
    if result.code ~= 0 then
      return nil, vim.trim(result.stderr or result.stdout or "")
    end
    return result.stdout or "", nil
  end

  local output = vim.fn.system(cmd)
  local code = vim.v.shell_error
  if code ~= 0 then
    return nil, vim.trim(output or "")
  end
  return output or "", nil
end

local function git_output(root, args)
  local cmd = { "git" }
  if root and root ~= "" then
    cmd[#cmd + 1] = "-C"
    cmd[#cmd + 1] = root
  end
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end

  return run_command(cmd)
end

local function git_lines(root, args)
  local output, err = git_output(root, args)
  if not output then
    return nil, err
  end

  return split_lines(output), nil
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

local function is_absolute(path)
  return path and path:sub(1, 1) == "/"
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

function M.find_root(start)
  local dir = path_dir(start)
  local lines, err = git_lines(dir, { "rev-parse", "--show-toplevel" })
  if not lines or not lines[1] or lines[1] == "" then
    return nil, err ~= "" and err or "not inside a git repository"
  end
  return vim.fn.fnamemodify(lines[1], ":p"):gsub("/$", ""), nil
end

local function current_buffer_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    return name
  end
  return nil
end

local function relpath(root, path)
  if not path or path == "" then
    return nil
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

local function append_pathspecs(args, pathspecs)
  args[#args + 1] = "--"
  for _, pathspec in ipairs(pathspecs or {}) do
    args[#args + 1] = pathspec
  end
end

local function diff_args(opts)
  local mode = opts.mode or "unstaged"
  local args = { "diff", "--name-status", "-z", "--no-ext-diff" }
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

local function parse_name_status(output)
  local tokens = split_nul(output)
  local entries = {}
  local i = 1
  while i <= #tokens do
    local status = tokens[i]
    local code = status and status:sub(1, 1) or ""
    if code == "R" or code == "C" then
      local old_path = tokens[i + 1]
      local new_path = tokens[i + 2]
      if old_path and new_path then
        entries[#entries + 1] = {
          status = code,
          raw_status = status,
          path = normalize_path(new_path),
          old_path = normalize_path(old_path),
        }
      end
      i = i + 3
    else
      local path = tokens[i + 1]
      if path then
        entries[#entries + 1] = {
          status = code,
          raw_status = status,
          path = normalize_path(path),
        }
      end
      i = i + 2
    end
  end
  return entries
end

local function list_untracked(root, pathspecs)
  local args = { "ls-files", "--others", "--exclude-standard", "-z" }
  append_pathspecs(args, pathspecs)
  local output, err = git_output(root, args)
  if not output then
    return nil, err
  end
  local entries = {}
  for _, path in ipairs(split_nul(output)) do
    entries[#entries + 1] = {
      status = "A",
      raw_status = "??",
      path = normalize_path(path),
      untracked = true,
    }
  end
  return entries, nil
end

local function list_unmerged(root, pathspecs)
  local args = { "ls-files", "-u", "-z" }
  append_pathspecs(args, pathspecs)
  local output, err = git_output(root, args)
  if not output then
    return nil, err
  end
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
  return entries, nil
end

local function list_entries(root, opts)
  local args, arg_err = diff_args(opts)
  if not args then
    return nil, arg_err
  end

  local output, err = git_output(root, args)
  if not output then
    return nil, err
  end
  local entries = parse_name_status(output)

  if opts.include_untracked ~= false and (opts.mode == "unstaged" or opts.mode == "all") then
    local untracked, untracked_err = list_untracked(root, opts.pathspecs)
    if not untracked then
      return nil, untracked_err
    end
    for _, entry in ipairs(untracked) do
      entries[#entries + 1] = entry
    end
  end

  local unmerged, unmerged_err = list_unmerged(root, opts.pathspecs)
  if not unmerged then
    return nil, unmerged_err
  end
  for _, entry in ipairs(unmerged) do
    entries[#entries + 1] = entry
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
  return entries, nil
end

local function abs_path(root, path)
  if is_absolute(path) then
    return path
  end
  return root .. "/" .. path
end

local function find_loaded_buffer(path)
  local abs = realpath(path) or vim.fn.fnamemodify(path, ":p")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
      local buffer_path = realpath(name) or vim.fn.fnamemodify(name, ":p")
      if buftype == "" and name ~= "" and buffer_path == abs then
        return bufnr
      end
    end
  end
  return nil
end

local function has_modified_loaded_buffer(root, path)
  local bufnr = find_loaded_buffer(abs_path(root, path))
  return bufnr ~= nil and vim.api.nvim_get_option_value("modified", { buf = bufnr }) == true
end

local function read_worktree(root, path, use_buffer)
  local full_path = abs_path(root, path)
  if use_buffer ~= false then
    local bufnr = find_loaded_buffer(full_path)
    if bufnr and vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return to_text(lines), nil, "buffer"
    end
  end

  local ok, lines = pcall(vim.fn.readfile, full_path)
  if not ok then
    return nil, string.format("unable to read worktree file: %s", full_path)
  end
  return to_text(lines), nil, "working tree"
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

local function read_blob(root, spec)
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
  if mode == "unstaged" then
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

local function is_metadata_only(queue, entry)
  local summary = git_summary(queue.root, queue.opts or {}, entry.path)
  if not summary then
    return false
  end
  local stats = numstat(queue.root, queue.opts or {}, entry.path)
  return stats == nil or stats:match("^0%s+0%s+") ~= nil
end

local function empty_source(path, label, metadata)
  return source_from_text("", path, label, metadata)
end

local function metadata_source(root, path, label, side, entry, message)
  local text = side == "right" and message or ""
  local source = source_from_text(text, abs_path(root, path), label, {
    git_state = "metadata",
    git_side = side,
    git_target = "metadata",
    git_ref = "metadata",
    git_relpath = path,
    git_entry_kind = entry.kind,
  })
  if side == "left" then
    source.empty_reason = "Git metadata entry"
  end
  source.git_readonly_reason = entry.actions_disabled_reason
  return source
end

local function symlink_text(queue, path, side)
  local root = queue.root
  local opts = queue.opts or {}
  local mode = opts.mode or "unstaged"
  if side == "right" and mode ~= "staged" and mode ~= "rev" then
    local target = read_worktree_symlink(root, path)
    if target then
      return target
    end
  end
  if side == "left" then
    if mode == "unstaged" then
      return read_blob(root, ":" .. path)
    elseif mode == "staged" or mode == "all" then
      return read_blob(root, (opts.base or "HEAD") .. ":" .. path)
    elseif mode == "rev" then
      return read_blob(root, opts.base .. ":" .. path)
    end
  else
    if mode == "staged" then
      return read_blob(root, ":" .. path)
    elseif mode == "rev" then
      return read_blob(root, opts.target .. ":" .. path)
    end
  end
  return read_blob(root, ":" .. path)
end

local function symlink_source(queue, entry, side)
  local root = queue.root
  local path = side == "left" and (entry.old_path or entry.path) or entry.path
  local target = symlink_text(queue, path, side)
  local text = target and ("symlink -> " .. vim.trim(target) .. "\n") or "symlink target unavailable\n"
  local source = source_from_text(text, abs_path(root, path), string.format("%s (symlink)", path), {
    git_state = "symlink",
    git_side = side,
    git_target = "metadata",
    git_ref = "symlink",
    git_relpath = path,
    git_entry_kind = entry.kind,
  })
  source.git_readonly_reason = "symlink hunk actions are disabled"
  return source
end

local function submodule_summary(queue, entry)
  local summary = git_summary(queue.root, queue.opts or {}, entry.path)
  if summary and summary ~= "" then
    return summary
  end
  return "Submodule commit changed"
end

local function should_hex_source(queue, text)
  local opts = queue.opts or {}
  if opts.binary_view == "none" then
    return false
  end
  if opts.hex and opts.hex.enabled == false then
    return false
  end
  return hex.is_binary(text or "")
end

local function git_source(queue, path, label, reader, metadata)
  local root = queue.root
  local text, err, label_suffix = reader()
  if not text then
    return nil, err
  end
  local display_label = label_suffix and string.format("%s (%s)", path, label_suffix) or label
  local is_binary = hex.is_binary(text or "")
  if is_binary and should_hex_source(queue, text) then
    return source_from_hex(text, abs_path(root, path), display_label, metadata, queue.opts)
  elseif is_binary then
    return source_from_binary_notice(abs_path(root, path), display_label, metadata)
  end
  return source_from_text(
    text,
    abs_path(root, path),
    display_label,
    metadata
  )
end

local function classify_entry(queue, entry)
  if entry.classified then
    return entry
  end

  local status = entry.status
  local kind = "modified"
  if entry.untracked then
    kind = "untracked"
  elseif status == "A" then
    kind = "added"
  elseif status == "D" then
    kind = "deleted"
  elseif status == "R" then
    kind = "renamed"
  elseif status == "C" then
    kind = "copied"
  elseif status == "T" then
    kind = "typechange"
  elseif status == "U" then
    kind = "unmerged"
  end

  entry.kind = kind
  entry.content_kind = entry.content_kind or "text"
  local modes = entry_modes(queue, entry)
  if modes.left == "160000" or modes.right == "160000" then
    entry.content_kind = "submodule"
  elseif modes.left == "120000" or modes.right == "120000" then
    entry.content_kind = "symlink"
  elseif is_metadata_only(queue, entry) then
    entry.content_kind = "metadata"
  end
  entry.actions_enabled = kind ~= "renamed"
    and kind ~= "copied"
    and kind ~= "typechange"
    and kind ~= "unmerged"
    and entry.content_kind ~= "symlink"
    and entry.content_kind ~= "submodule"
    and entry.content_kind ~= "metadata"
  if not entry.actions_enabled then
    if entry.content_kind == "symlink" then
      entry.actions_disabled_reason = "Git hunk actions are disabled for symlink entries"
    elseif entry.content_kind == "submodule" then
      entry.actions_disabled_reason = "Git hunk actions are disabled for submodule entries"
    elseif entry.content_kind == "metadata" then
      entry.actions_disabled_reason = "Git hunk actions are disabled for metadata-only entries"
    else
      entry.actions_disabled_reason = "Git hunk actions are disabled for " .. kind .. " entries"
    end
  end
  entry.classified = true
  return entry
end

local function source_from_kind(queue, entry, side)
  classify_entry(queue, entry)
  local root = queue.root
  local opts = queue.opts
  local mode = opts.mode
  local path = side == "left" and (entry.old_path or entry.path) or entry.path
  local label_path = path

  if entry.content_kind == "submodule" then
    return metadata_source(root, path, string.format("%s (submodule)", label_path), side, entry, submodule_summary(queue, entry))
  elseif entry.content_kind == "symlink" then
    return symlink_source(queue, entry, side)
  elseif entry.content_kind == "metadata" then
    return metadata_source(root, path, string.format("%s (metadata)", label_path), side, entry,
      git_summary(root, opts, entry.path) or "Metadata changed")
  end

  if entry.kind == "unmerged" then
    return metadata_source(root, path, string.format("%s (unmerged)", label_path), side, entry,
      "Unmerged file: resolve conflicts outside DiffBandit")
  elseif entry.kind == "typechange" then
    return metadata_source(root, path, string.format("%s (type changed)", label_path), side, entry,
      git_summary(root, opts, entry.path) or "File type changed")
  end

  if side == "left" then
    if entry.untracked or (entry.status == "A" and (mode == "staged" or mode == "all" or mode == "rev")) then
      local label
      if entry.untracked then
        label = string.format("%s (not tracked)", label_path)
      elseif mode == "rev" then
        label = string.format("%s (%s: absent)", label_path, opts.base)
      elseif opts.unborn_head then
        label = string.format("%s (empty tree: absent)", label_path)
      else
        label = string.format("%s (%s: absent)", label_path, opts.base or "HEAD")
      end
      local absent_ref = entry.untracked and "not tracked"
        or (opts.unborn_head and "empty tree" or (mode == "rev" and opts.base or opts.base or "HEAD"))
      return empty_source(abs_path(root, path), label, {
        git_state = entry.untracked and "untracked" or "absent",
        empty_reason = entry.untracked and "New untracked file" or "New file",
        git_side = side,
        git_target = "absent",
        git_ref = absent_ref,
        git_relpath = path,
      })
    end
    if mode == "unstaged" then
      return git_source(queue, path, string.format("%s (index)", label_path), function()
        return read_blob(root, ":" .. path)
      end, { git_side = side, git_target = "index", git_ref = "index", git_relpath = path, git_entry_kind = entry.kind })
    elseif mode == "staged" then
      return git_source(queue, path, string.format("%s (HEAD)", label_path), function()
        return read_blob(root, (opts.base or "HEAD") .. ":" .. path)
      end, { git_side = side, git_target = "head", git_ref = opts.base or "HEAD", git_relpath = path, git_entry_kind = entry.kind })
    elseif mode == "all" then
      local ref = opts.unborn_head and "empty tree" or (opts.base or "HEAD")
      return git_source(queue, path, string.format("%s (%s)", label_path, opts.base or "HEAD"), function()
        return read_blob(root, (opts.base or "HEAD") .. ":" .. path)
      end, { git_side = side, git_target = "head", git_ref = ref, git_relpath = path, git_entry_kind = entry.kind })
    elseif mode == "rev" then
      return git_source(queue, path, string.format("%s (%s)", label_path, opts.base), function()
        return read_blob(root, opts.base .. ":" .. path)
      end, { git_side = side, git_target = "rev", git_ref = opts.base, git_relpath = path, git_entry_kind = entry.kind })
    end
  end

  if entry.status == "D" then
    local label
    if mode == "staged" then
      label = string.format("%s (index: deleted)", label_path)
    elseif mode == "rev" then
      label = string.format("%s (%s: absent)", label_path, opts.target)
    else
      label = string.format("%s (working tree: deleted)", label_path)
    end
    return empty_source(abs_path(root, path), label, {
      git_state = "deleted",
      empty_reason = "Deleted file",
      git_side = side,
      git_target = "absent",
      git_ref = mode == "rev" and opts.target or "deleted",
      git_relpath = path,
    })
  end
  if mode == "staged" then
    return git_source(queue, path, string.format("%s (index)", label_path), function()
      return read_blob(root, ":" .. path)
    end, { git_side = side, git_target = "index", git_ref = "index", git_relpath = path, git_entry_kind = entry.kind })
  elseif mode == "rev" then
    return git_source(queue, path, string.format("%s (%s)", label_path, opts.target), function()
      return read_blob(root, opts.target .. ":" .. path)
    end, { git_side = side, git_target = "rev", git_ref = opts.target, git_relpath = path, git_entry_kind = entry.kind })
  end

  return git_source(queue, path, string.format("%s (working tree)", label_path), function()
    if opts.use_buffer ~= false and has_modified_loaded_buffer(root, path) then
      return read_worktree(root, path, opts.use_buffer)
    end
    local raw, raw_err = read_worktree_raw(root, path)
    if raw then
      return raw, nil, "working tree"
    end
    return nil, raw_err
  end, { git_side = side, git_target = "worktree", git_ref = "working tree", git_relpath = path, git_entry_kind = entry.kind })
end

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
    or current_buffer_path()
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
  if normalized.mode == "all" and (normalized.base == nil or normalized.base == "HEAD") and not has_head(root) then
    normalized.base = empty_tree
    normalized.unborn_head = true
  end

  local entries, entries_err = list_entries(root, normalized)
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
  }

  function queue.load(index)
    return M.sources_for_entry(queue, index)
  end

  return queue, nil
end

function M.sources_for_entry(queue, index)
  local entry = queue.entries[index]
  if not entry then
    return nil, "no changed file at queue index " .. tostring(index)
  end

  local left, left_err = source_from_kind(queue, entry, "left")
  if not left then
    return nil, left_err
  end
  local right, right_err = source_from_kind(queue, entry, "right")
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

function M.has_staged_changes(root, path)
  local output, err = git_output(root, { "diff", "--cached", "--name-only", "--", path })
  if not output then
    return false, err
  end
  return vim.trim(output) ~= "", nil
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

function M.write_index(root, path, text)
  if text == nil then
    local _, err = git_output(root, { "update-index", "--force-remove", "--", path })
    return err == nil, err
  end

  local tmp = vim.fn.tempname()
  local lines = split_lines(text)
  local ok, write_err = pcall(vim.fn.writefile, lines, tmp)
  if not ok then
    return false, tostring(write_err)
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

function M.write_worktree(root, path, text, use_buffer)
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
      local lines = text == nil and {} or split_lines(text)
      local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
      if not was_modifiable then
        pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })
      end
      if not ok then
        return false, tostring(err)
      end
      return true, nil
    end
  end

  if text == nil then
    if vim.fn.filereadable(full_path) == 1 then
      local ok, err = os.remove(full_path)
      if not ok then
        return false, err
      end
    end
    return true, nil
  end

  vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, split_lines(text), full_path)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

M._private = {
  parse_name_status = parse_name_status,
  split_nul = split_nul,
  normalize_opts = normalize_opts,
  split_lines = split_lines,
  to_text = to_text,
}

return M
