-- Diff-source factory for Git queue entries: classifies each entry
-- (submodule/symlink/metadata/binary/text) and builds the left/right source
-- tables for the diff view. Extracted from git.lua; the git module injects
-- its low-level readers via new() so the two modules stay cycle-free.
local hex = require("diffbandit.hex")
local source_mod = require("diffbandit.source")
local document = require("diffbandit.document")

local M = {}

local function source_from_text(text, path, label, metadata)
  return source_mod.from_text(text, path, label, metadata)
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

-- readers: git_summary, numstat, entry_modes, abs_path, read_blob,
-- read_worktree, read_worktree_raw, read_worktree_symlink,
-- find_loaded_buffer, has_modified_loaded_buffer
function M.new(readers)
  local git_summary = readers.git_summary
  local numstat = readers.numstat
  local entry_modes = readers.entry_modes
  local abs_path = readers.abs_path
  local read_blob = readers.read_blob
  local read_worktree = readers.read_worktree
  local read_worktree_raw = readers.read_worktree_raw
  local read_worktree_symlink = readers.read_worktree_symlink
  local find_loaded_buffer = readers.find_loaded_buffer
  local has_modified_loaded_buffer = readers.has_modified_loaded_buffer

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
      and (queue.opts or {}).read_only ~= true
    if not entry.actions_enabled then
      if (queue.opts or {}).read_only == true then
        entry.actions_disabled_reason = "Git hunk actions are disabled for read-only revision views"
      elseif entry.content_kind == "symlink" then
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

    local worktree_path = abs_path(root, path)
    local worktree_bufnr = opts.use_buffer ~= false and find_loaded_buffer(worktree_path) or nil
    return git_source(queue, path, string.format("%s (working tree)", label_path), function()
      if opts.use_buffer ~= false and has_modified_loaded_buffer(root, path) then
        return read_worktree(root, path, opts.use_buffer)
      end
      local raw, raw_err = read_worktree_raw(root, path)
      if raw then
        return raw, nil, "working tree"
      end
      return nil, raw_err
    end, {
      git_side = side,
      git_target = "worktree",
      git_ref = "working tree",
      git_relpath = path,
      git_entry_kind = entry.kind,
      editable = {
        target = "git-worktree",
        path = document.normalize_path(worktree_path) or worktree_path,
        bufnr = worktree_bufnr,
        git_root = root,
        git_relpath = path,
      },
    })
  end

  return {
    classify_entry = classify_entry,
    source_from_kind = source_from_kind,
  }
end

return M
