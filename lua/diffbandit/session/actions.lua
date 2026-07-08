local nvim = require("diffbandit.util.nvim")
local git_mod = require("diffbandit.git")
local diff_mod = require("diffbandit.diff")
local source_mod = require("diffbandit.util.source")
local text = require("diffbandit.util.text")

local M = {}

local function current_chunk(session)
  if not session or not session.view then
    return nil
  end

  local win = vim.api.nvim_get_current_win()
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if ok then
    local row = cursor[1]
    for idx, meta in ipairs(session.view.line_meta or {}) do
      local matches = false
      if win == session.left_win or win == session.left_num_win then
        matches = meta.left_index == row
      elseif win == session.right_win or win == session.right_num_win then
        matches = meta.right_index == row
      elseif win == session.connector_win then
        matches = idx == row
      end
      if matches and meta.chunk then
        return session.view.chunks[meta.chunk], meta.chunk
      end
    end
  end

  local index = session.current_chunk
  if index and index > 0 then
    return session.view.chunks[index], index
  end
  return nil
end

local function active_hunk(session)
  local chunk, chunk_index = current_chunk(session)
  if not chunk then
    return nil, nil, "no current hunk"
  end
  local hunk = session.hunks and session.hunks[chunk.index or chunk_index]
  if not hunk then
    return nil, nil, "no current hunk"
  end
  return hunk, chunk_index, nil
end

local function queue_context(session)
  local queue = session and session.file_queue
  if not queue or queue.kind ~= "git" then
    return nil, "Git hunk actions are only available in Git diff sessions"
  end
  local entry = queue.entries and queue.entries[session.file_queue_index or queue.index or 1]
  if not entry then
    return nil, "no Git file entry for this diff"
  end
  return {
    queue = queue,
    entry = entry,
    root = queue.root,
    opts = queue.opts or {},
    path = entry.path,
  }, nil
end

local function action_capability_error(ctx)
  if not ctx then
    return nil
  end
  local entry = ctx.entry or {}
  if entry.actions_enabled == false then
    return entry.actions_disabled_reason or "Git hunk actions are disabled for this entry"
  end
  return nil
end

local function read_target(ctx, target)
  if target == "index" then
    return git_mod.read_index(ctx.root, ctx.path)
  elseif target == "head" then
    return git_mod.read_head(ctx.root, ctx.path, ctx.opts.base or "HEAD")
  elseif target == "worktree" then
    return git_mod.read_worktree(ctx.root, ctx.path, ctx.opts.use_buffer)
  end
  return nil, "unsupported target: " .. tostring(target)
end

local function write_target(ctx, target, text)
  if target == "index" then
    return git_mod.write_index(ctx.root, ctx.path, text)
  elseif target == "worktree" then
    return git_mod.write_worktree(ctx.root, ctx.path, text, ctx.opts.use_buffer)
  end
  return false, "cannot write " .. tostring(target)
end

local function target_text_from_session(session, side)
  local source = side == "left" and session.left or session.right
  return source and source.text or ""
end

local function side_lines(session, side)
  local source = side == "left" and session.left or session.right
  return source and source.lines or {}
end

local function side_range(hunk, side)
  local range = side == "left" and hunk.left or hunk.right
  return range.start, range.count
end

local function current_chunk_index(session)
  local _, chunk_index = current_chunk(session)
  return chunk_index
end

local function buffer_undo_seq(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local ok, tree = pcall(vim.api.nvim_buf_call, bufnr, vim.fn.undotree)
  if not (ok and type(tree) == "table") then
    return nil
  end
  return tonumber(tree.seq_cur or 0) or 0
end

local function range_end(start, count)
  if count <= 0 then
    return start
  end
  return start + count - 1
end

local function ranges_overlap(a_start, a_count, b_start, b_count)
  local a_end = range_end(a_start, a_count)
  local b_end = range_end(b_start, b_count)
  return a_start <= b_end and b_start <= a_end
end

local function hunk_matches_staged(visible, staged)
  if not visible or not staged then
    return false
  end
  if visible.type == "add" then
    return staged.type == "add"
      and visible.left.start == staged.left.start
      and ranges_overlap(visible.right.start, visible.right.count, staged.right.start, staged.right.count)
  elseif visible.type == "delete" then
    return staged.type == "delete"
      and ranges_overlap(visible.left.start, visible.left.count, staged.left.start, staged.left.count)
  end
  return ranges_overlap(visible.left.start, visible.left.count, staged.left.start, staged.left.count)
    or ranges_overlap(visible.right.start, visible.right.count, staged.right.start, staged.right.count)
end

local function staged_hunks_for_session(session, ctx)
  local head = git_mod.read_head(ctx.root, ctx.path, ctx.opts.base or "HEAD") or ""
  local index = git_mod.read_index(ctx.root, ctx.path) or ""
  local staged_hunks = diff_mod.compute_hunks(head, index, session.config.diff or {})
  if type(staged_hunks) ~= "table" then
    return {}
  end
  return staged_hunks
end

local function staged_hunk_for_active_hunk(session, ctx, visible_hunk)
  for _, staged in ipairs(staged_hunks_for_session(session, ctx)) do
    if hunk_matches_staged(visible_hunk, staged) then
      return staged
    end
  end
  return nil
end

local function remove_target_for_absent_source(session, source_side, target_side, hunk)
  local source = source_side == "left" and session.left or session.right
  if not source or source.git_target ~= "absent" then
    return false
  end
  local target = target_side == "left" and hunk.left or hunk.right
  local target_lines = side_lines(session, target_side)
  return target.count >= #target_lines
end

local function apply_sides(session, source_side, target_side, opts)
  opts = opts or {}
  local ctx, ctx_err = queue_context(session)
  if not ctx then
    return false, ctx_err
  end
  local capability_err = action_capability_error(ctx)
  if capability_err then
    return false, capability_err
  end
  local mode = ctx.opts.mode or "unstaged"
  if mode ~= "unstaged" and mode ~= "staged" and mode ~= "all" then
    return false, "Git hunk actions are disabled for " .. mode .. " diffs"
  end

  local hunk, chunk_index, hunk_err = active_hunk(session)
  if not hunk then
    return false, hunk_err
  end

  local target
  local target_range_side = target_side
  local expected
  if mode == "unstaged" then
    target = target_side == "left" and "index" or "worktree"
    expected = target_text_from_session(session, target_side)
  elseif mode == "staged" then
    if target_side == "left" then
      return false, "HEAD cannot be changed from a staged diff"
    end
    target = "index"
    expected = target_text_from_session(session, target_side)
  else
    if target_side == "right" then
      target = "worktree"
      target_range_side = "right"
      expected = target_text_from_session(session, "right")
    else
      target = "index"
      target_range_side = "left"
      expected = nil
    end
  end

  local current = read_target(ctx, target)
  if expected ~= nil and (current or "") ~= expected then
    return false, "target changed outside DiffBandit; refresh before applying this hunk"
  end

  if opts.target_range_side then
    target_range_side = opts.target_range_side
  end

  local range_hunk = opts.hunk or hunk
  local target_start, target_count = side_range(range_hunk, target_range_side)
  local source_start, source_count = side_range(range_hunk, source_side)
  local replacement = text.copy_range(side_lines(session, source_side), source_start, source_count)
  local next_text
  if remove_target_for_absent_source(session, source_side, target_side, range_hunk) then
    next_text = nil
  else
    next_text = text.to_text(text.replace_range(text.split_lines(current or ""), target_start, target_count, replacement))
  end

  local ok, write_err = write_target(ctx, target, next_text)
  if not ok then
    return false, write_err
  end

  session.action_undo = session.action_undo or {}
  local stack = session.action_undo[ctx.path] or {}
  session.action_undo[ctx.path] = stack
  stack[#stack + 1] = {
    path = ctx.path,
    target = target,
    before = current,
    after = next_text,
    action = opts.action or (source_side .. "_to_" .. target_side),
    right_undo_seq = buffer_undo_seq(session.right_buf),
  }

  M.refresh(session, chunk_index)
  return true, nil
end

function M.apply_left(session)
  return apply_sides(session, "left", "right", { action = "apply_left" })
end

function M.apply_right(session)
  return apply_sides(session, "right", "left", { action = "apply_right" })
end

function M.stage(session)
  local ctx, err = queue_context(session)
  if not ctx then
    return false, err
  end
  local capability_err = action_capability_error(ctx)
  if capability_err then
    return false, capability_err
  end
  local mode = ctx.opts.mode or "unstaged"
  if mode ~= "unstaged" and mode ~= "all" then
    return false, "stage hunk is only available in unstaged or all Git diffs"
  end
  return apply_sides(session, "right", "left", { action = "stage" })
end

function M.unstage(session)
  local ctx, err = queue_context(session)
  if not ctx then
    return false, err
  end
  local capability_err = action_capability_error(ctx)
  if capability_err then
    return false, capability_err
  end
  local mode = ctx.opts.mode or "unstaged"
  if mode ~= "staged" and mode ~= "all" then
    return false, "unstage hunk is only available in staged or all Git diffs"
  end
  if mode == "all" then
    local visible_hunk = active_hunk(session)
    local staged_hunk = visible_hunk and staged_hunk_for_active_hunk(session, ctx, visible_hunk)
    if not staged_hunk then
      return false, "current hunk is not staged"
    end
    return apply_sides(session, "left", "left", {
      action = "unstage",
      hunk = staged_hunk,
      target_range_side = "right",
    })
  end
  return apply_sides(session, "left", "right", { action = "unstage" })
end

function M.discard(session)
  local ctx, err = queue_context(session)
  if not ctx then
    return false, err
  end
  local capability_err = action_capability_error(ctx)
  if capability_err then
    return false, capability_err
  end
  local mode = ctx.opts.mode or "unstaged"
  if mode ~= "unstaged" and mode ~= "all" then
    return false, "discard hunk is only available in unstaged or all Git diffs"
  end
  return apply_sides(session, "left", "right", { action = "discard" })
end

function M.toggle_stage(session)
  local ctx, err = queue_context(session)
  if not ctx then
    return false, err
  end
  local capability_err = action_capability_error(ctx)
  if capability_err then
    return false, capability_err
  end
  local mode = ctx.opts.mode or "unstaged"
  if mode == "unstaged" then
    return M.stage(session)
  elseif mode == "staged" then
    return M.unstage(session)
  elseif mode == "all" then
    local chunk_index = current_chunk_index(session)
    local staged_states = M.staged_chunk_states(session)
    if chunk_index and staged_states and staged_states[chunk_index] then
      return M.unstage(session)
    end
    return M.stage(session)
  end
  return false, "Git hunk actions are disabled for " .. mode .. " diffs"
end

local function no_change_sources(ctx)
  local mode = ctx.opts.mode or "unstaged"
  local left_text, right_text
  local left_label, right_label
  if mode == "staged" then
    left_text = git_mod.read_head(ctx.root, ctx.path, ctx.opts.base or "HEAD") or ""
    right_text = git_mod.read_index(ctx.root, ctx.path) or ""
    left_label = string.format("%s (%s)", ctx.path, ctx.opts.base or "HEAD")
    right_label = string.format("%s (index)", ctx.path)
  elseif mode == "all" then
    left_text = git_mod.read_head(ctx.root, ctx.path, ctx.opts.base or "HEAD") or ""
    right_text = git_mod.read_worktree(ctx.root, ctx.path, ctx.opts.use_buffer) or ""
    left_label = string.format("%s (%s)", ctx.path, ctx.opts.base or "HEAD")
    right_label = string.format("%s (working tree)", ctx.path)
  else
    left_text = git_mod.read_index(ctx.root, ctx.path) or ""
    right_text = git_mod.read_worktree(ctx.root, ctx.path, ctx.opts.use_buffer) or ""
    left_label = string.format("%s (index)", ctx.path)
    right_label = string.format("%s (working tree)", ctx.path)
  end
  local abs = git_mod.abs_path(ctx.root, ctx.path)
  return {
    left = source_mod.from_text(left_text, abs, left_label, {
      git_side = "left",
      git_target = (mode == "staged" or mode == "all") and "head" or "index",
      git_ref = (mode == "staged" or mode == "all") and (ctx.opts.base or "HEAD") or "index",
      git_relpath = ctx.path,
    }),
    right = source_mod.from_text(right_text, abs, right_label, {
      git_side = "right",
      git_target = mode == "staged" and "index" or "worktree",
      git_ref = mode == "staged" and "index" or "working tree",
      git_relpath = ctx.path,
    }),
  }
end

function M.refresh(session, preferred_chunk)
  local ctx, ctx_err = queue_context(session)
  if not ctx then
    return false, ctx_err
  end
  if ctx.queue then
    ctx.queue.source_cache = {}
  end

  local refresh_opts = vim.tbl_extend("force", {}, ctx.opts, {
    scope = "current",
    path = git_mod.abs_path(ctx.root, ctx.path),
    pathspecs = {},
  })
  local current_file_queue = git_mod.queue(refresh_opts, {})
  local sources
  if current_file_queue then
    for index, entry in ipairs(current_file_queue.entries or {}) do
      if entry.path == ctx.path or entry.old_path == ctx.path then
        local loaded = select(1, current_file_queue.load(index))
        if loaded then
          sources = { left = loaded.left, right = loaded.right }
          break
        end
      end
    end
  end
  if not sources then
    sources = no_change_sources(ctx)
    if session.right and session.right.editable and sources.right and sources.right.git_target == "worktree" then
      sources.right.editable = vim.tbl_extend("force", {}, session.right.editable)
    end
    nvim.notify_info("no remaining changes in " .. ctx.path)
  end

  session.file_queue = ctx.queue
  session.file_queue_index = ctx.queue.index or session.file_queue_index or 1
  if session.file_queue then
    session.file_queue.index = session.file_queue_index
  end

  local ok, err = session:replace_sources(sources, {
    chunk_position = preferred_chunk and "preserve" or "first",
    preferred_chunk = preferred_chunk,
    preserve_view = preferred_chunk ~= nil,
  })
  if not ok then
    return false, err
  end
  return true, nil
end

function M.undo(session)
  local ctx, err = queue_context(session)
  if not ctx then
    return false, err
  end
  local stack = session.action_undo and session.action_undo[ctx.path]
  if not stack or #stack == 0 then
    return false, "no DiffBandit action to undo for this file"
  end

  local entry = stack[#stack]
  local current, read_err = read_target(ctx, entry.target)
  if current == nil and read_err then
    current = nil
  end
  if current ~= entry.after then
    return false, "cannot undo: " .. ctx.path .. " changed after the DiffBandit action"
  end

  local ok, write_err = write_target(ctx, entry.target, entry.before)
  if not ok then
    return false, write_err
  end
  stack[#stack] = nil
  if stack[#stack] then
    stack[#stack].right_undo_seq = buffer_undo_seq(session.right_buf)
  end
  M.refresh(session)
  return true, nil
end

function M.staged_chunk_states(session)
  local states = {}
  local ctx = queue_context(session)
  if not ctx then
    return states
  end
  if action_capability_error(ctx) then
    return states
  end
  local mode = ctx.opts.mode or "unstaged"
  if mode == "rev" then
    return states
  end
  if mode == "staged" then
    for index, _ in ipairs(session.view.chunks or {}) do
      states[index] = true
    end
    return states
  end

  local has_staged = git_mod.has_staged_changes(ctx.root, ctx.path)
  if not has_staged then
    return states
  end

  local staged_hunks = staged_hunks_for_session(session, ctx)
  if #staged_hunks == 0 then
    return states
  end

  for chunk_index, chunk in ipairs(session.view.chunks or {}) do
    local hunk = session.hunks and session.hunks[chunk.index or chunk_index]
    if hunk then
      for _, staged in ipairs(staged_hunks) do
        if hunk_matches_staged(hunk, staged) then
          states[chunk_index] = true
          break
        end
      end
    end
  end
  return states
end

M._private = {
  replace_range = text.replace_range,
}

return M
