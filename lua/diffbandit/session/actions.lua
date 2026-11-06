local nvim = require("diffbandit.util.nvim")
local git_mod = require("diffbandit.git")
local diff_mod = require("diffbandit.diff")
local source_mod = require("diffbandit.util.source")
local text = require("diffbandit.util.text")
local keep_view = require("diffbandit.session.keep_view")

local M = {}

--- Index of the chunk under the focused pane's cursor, or nil on a context line.
function M.chunk_index_at_cursor(session)
  local win = vim.api.nvim_get_current_win()
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok then
    return nil
  end
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
      return meta.chunk
    end
  end
  return nil
end

--- Whether any of the chunk's lines are showing in either source pane. Without
--- panes (actions driven through the API) nothing counts as off-screen.
function M.chunk_on_screen(session, chunk)
  local function valid(win)
    return win and vim.api.nvim_win_is_valid(win)
  end
  if not (valid(session.left_win) or valid(session.right_win)) then
    return true
  end
  local function range(win)
    if valid(win) then
      return vim.fn.line("w0", win), vim.fn.line("w$", win)
    end
    return 1, 0
  end
  local left_first, left_last = range(session.left_win)
  local right_first, right_last = range(session.right_win)
  local meta_list = session.view.line_meta or {}
  for idx = chunk.display_start, chunk.display_end do
    local meta = meta_list[idx] or {}
    local left, right = meta.left_index, meta.right_index
    if (left and left >= left_first and left <= left_last) or (right and right >= right_first and right <= right_last) then
      return true
    end
  end
  return false
end

local function current_chunk(session)
  if not session or not session.view then
    return nil
  end

  local at_cursor = M.chunk_index_at_cursor(session)
  if at_cursor then
    return session.view.chunks[at_cursor], at_cursor
  end

  -- Off a hunk, an action falls to the active one only while it can be seen.
  local index = session.current_chunk
  local chunk = index and index > 0 and session.view.chunks[index] or nil
  if not chunk then
    return nil
  end
  if not M.chunk_on_screen(session, chunk) then
    return nil, nil, "the active hunk is off-screen; jump to it first"
  end
  return chunk, index
end

local function active_hunk(session)
  local chunk, chunk_index, chunk_err = current_chunk(session)
  if not chunk then
    return nil, nil, chunk_err or "no current hunk"
  end
  local hunk = session.hunks and session.hunks[chunk.index or chunk_index]
  if not hunk then
    return nil, nil, "no current hunk"
  end
  return hunk, chunk_index, nil
end

local function shown_entry(session)
  local queue = session.file_queue
  return queue and queue.entries and queue.entries[session.file_queue_index or queue.index or 1]
end

local function queue_context(session)
  local queue = session and session.file_queue
  if not queue or queue.kind ~= "git" then
    return nil, "Git hunk actions are only available in Git diff sessions"
  end
  local entry = shown_entry(session)
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

local function next_undo_seq(session)
  session.action_undo_seq = (session.action_undo_seq or 0) + 1
  return session.action_undo_seq
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

-- All-mode hunk actions anchor on the working tree, the one side every
-- diff here shares: the visible hunks are base -> worktree, while staging
-- edits the index, whose lines are shifted by whatever is already staged
-- (and, against a merge base, by every committed change). Ranges below are
-- half-open spans of line boundaries: a hunk side with lines covers
-- [start, start + count); an empty side is the gap after line `start`.
local function span(range)
  if range.count > 0 then
    return range.start, range.start + range.count
  end
  return range.start + 1, range.start + 1
end

local function spans_touch(a_from, a_to, b_from, b_to)
  local a_point, b_point = a_from == a_to, b_from == b_to
  if a_point and b_point then
    return a_from == b_from
  elseif a_point then
    return b_from < a_from and a_from < b_to
  elseif b_point then
    return a_from < b_from and b_from < a_to
  end
  return a_from < b_to and b_from < a_to
end

-- The index span a worktree span corresponds to, through the index ->
-- worktree hunks. A boundary inside a hunk widens to that hunk's edge.
local function map_worktree_span(unstaged, from, to)
  local function map(position, is_end)
    local delta = 0
    for _, hunk in ipairs(unstaged) do
      local left_from, left_to = span(hunk.left)
      local right_from, right_to = span(hunk.right)
      if right_to <= position and not (right_from == right_to and right_from == position and not is_end) then
        delta = left_to - right_to
      elseif right_from < position and position < right_to then
        return is_end and left_to or left_from
      end
    end
    return position + delta
  end
  local mapped_from = map(from, false)
  if from == to then
    return mapped_from, mapped_from
  end
  return mapped_from, math.max(mapped_from, map(to, true))
end

-- What staging compares the index against: the amend base in amend mode,
-- the empty tree before the first commit, HEAD otherwise.
local function staging_reference(opts)
  if opts.stage_base then
    return opts.stage_base
  elseif opts.unborn_head then
    return opts.base
  end
  return "HEAD"
end

local function all_mode_texts(session, ctx, reference)
  local read = git_mod.read_blobs(ctx.root, { reference .. ":" .. ctx.path, ":" .. ctx.path })
  return read[1][1], read[2][1], target_text_from_session(session, "right")
end

-- Index -> worktree hunks that make up the worktree side of `visible`.
local function unstaged_parts(session, index_text, worktree_text, visible)
  local unstaged = diff_mod.compute_hunks(index_text or "", worktree_text or "", session.config.diff or {})
  local parts = {}
  local from, to = span(visible.right)
  for _, hunk in ipairs(type(unstaged) == "table" and unstaged or {}) do
    local h_from, h_to = span(hunk.right)
    if spans_touch(from, to, h_from, h_to) then
      parts[#parts + 1] = hunk
    end
  end
  return parts, type(unstaged) == "table" and unstaged or {}
end

-- Reference -> index hunks staged inside `visible`, located through the
-- worktree (used when the view's base is not the staging reference).
local function staged_parts(session, reference_text, index_text, worktree_text, visible)
  local _, unstaged = unstaged_parts(session, index_text, worktree_text, visible)
  local staged = diff_mod.compute_hunks(reference_text or "", index_text or "", session.config.diff or {})
  local from, to = map_worktree_span(unstaged, span(visible.right))
  local parts = {}
  for _, hunk in ipairs(type(staged) == "table" and staged or {}) do
    local h_from, h_to = span(hunk.right)
    if spans_touch(from, to, h_from, h_to) then
      parts[#parts + 1] = hunk
    end
  end
  return parts
end

-- Replace each part's `target` side lines in `lines` with its `source` side
-- lines from `source_lines`, bottom-up so earlier ranges stay valid.
local function splice_parts(lines, parts, target, source, source_lines)
  table.sort(parts, function(a, b)
    return a[target].start > b[target].start
  end)
  for _, part in ipairs(parts) do
    lines = text.replace_range(lines, part[target].start, part[target].count,
      text.copy_range(source_lines, part[source].start, part[source].count))
  end
  return lines
end

local function staged_hunks_for_session(session, ctx, blobs)
  local head, index
  if blobs then
    head, index = blobs.head, blobs.index
  else
    local read = git_mod.read_blobs(ctx.root, { (ctx.opts.base or "HEAD") .. ":" .. ctx.path, ":" .. ctx.path })
    head, index = read[1][1] or "", read[2][1] or ""
  end
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
  local view_before = keep_view.capture(session)

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

  local reference = staging_reference(ctx.opts)
  local mapped_next
  if mode == "all" and target == "index" and (source_side == "right" or (ctx.opts.base or "HEAD") ~= reference) then
    local reference_text, index_text, worktree_text = all_mode_texts(session, ctx, reference)
    local parts
    if source_side == "right" then
      -- Stage: bring the index to the worktree where this hunk shows
      -- pending (unstaged) lines.
      parts = unstaged_parts(session, index_text, worktree_text, hunk)
      if #parts == 0 then
        return false, "nothing to stage in this hunk: it is already staged or committed"
      end
      mapped_next = splice_parts(text.split_lines(index_text or ""), parts, "left", "right", text.split_lines(worktree_text or ""))
    else
      -- Unstage against a base other than the staging reference: restore
      -- the reference lines where this hunk has staged changes.
      parts = staged_parts(session, reference_text, index_text, worktree_text, hunk)
      if #parts == 0 then
        return false, "current hunk is not staged"
      end
      mapped_next = splice_parts(text.split_lines(index_text or ""), parts, "right", "left", text.split_lines(reference_text or ""))
    end
    -- An empty result for a path the target side lacks removes the index
    -- entry rather than staging an empty file.
    if #mapped_next == 0 and (index_text == nil
        or (source_side == "right" and session.right and session.right.git_target == "absent")
        or (source_side ~= "right" and reference_text == nil)) then
      mapped_next = nil
    end
  end

  local current = read_target(ctx, target)
  if expected ~= nil and (current or "") ~= expected then
    return false, "target changed outside DiffBandit; refresh before applying this hunk"
  end

  if opts.target_range_side then
    target_range_side = opts.target_range_side
  end

  local next_text
  if mode == "all" and target == "index" and (source_side == "right" or (ctx.opts.base or "HEAD") ~= reference) then
    next_text = mapped_next and text.to_text(mapped_next) or nil
  else
    local range_hunk = opts.hunk or hunk
    local target_start, target_count = side_range(range_hunk, target_range_side)
    local source_start, source_count = side_range(range_hunk, source_side)
    local replacement = text.copy_range(side_lines(session, source_side), source_start, source_count)
    if remove_target_for_absent_source(session, source_side, target_side, range_hunk) then
      next_text = nil
    else
      next_text = text.to_text(text.replace_range(text.split_lines(current or ""), target_start, target_count, replacement))
    end
  end

  -- Committing this path turns "undo the stage" into reversing the commit.
  local head = target == "index" and git_mod.read_head(ctx.root, ctx.path, "HEAD") or nil

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
    right_undo_buf = session.right_buf,
    seq = next_undo_seq(session),
    chunk_index = chunk_index,
    head = head,
  }

  M.refresh(session, chunk_index, view_before)
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
  if mode == "all" and (ctx.opts.base or "HEAD") ~= staging_reference(ctx.opts) then
    return apply_sides(session, "left", "left", { action = "unstage" })
  end
  if mode == "all" then
    local visible_hunk, _, hunk_err = active_hunk(session)
    if not visible_hunk then
      return false, hunk_err
    end
    local staged_hunk = staged_hunk_for_active_hunk(session, ctx, visible_hunk)
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

function M.refresh(session, preferred_chunk, view_before)
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
    chunk_from_cursor = preferred_chunk ~= nil,
    view_before = view_before,
  })
  if not ok then
    return false, err
  end
  return true, nil
end

--- The action `u` would undo: the newest one on the current file or on a file
--- that has since left the queue (which the session can no longer open to undo).
function M.latest_undo(session)
  local queue = session and session.file_queue
  if not (queue and queue.kind == "git") then
    return nil
  end
  local current = shown_entry(session)
  local listed = {}
  for _, entry in ipairs(queue.entries or {}) do
    listed[entry.path] = true
    if entry.old_path then
      listed[entry.old_path] = true
    end
  end
  local latest, latest_stack
  for path, stack in pairs(session.action_undo or {}) do
    local top = stack[#stack]
    if top and ((current and current.path == path) or not listed[path]) and (not latest or top.seq > latest.seq) then
      latest, latest_stack = top, stack
    end
  end
  return latest, latest_stack
end

local function mark_entry(session, entry)
  entry.right_undo_seq = buffer_undo_seq(session.right_buf)
  entry.right_undo_buf = session.right_buf
end

--- Ties the newest action on `path` to the right pane's current undo position.
function M.mark_undo_position(session, path)
  local stack = session.action_undo and session.action_undo[path]
  if stack and stack[#stack] then
    mark_entry(session, stack[#stack])
  end
end

--- After the pane switches files: edits from here on undo before an action on a
--- file that left the queue, and edits from before do not.
function M.note_file_shown(session)
  local latest = M.latest_undo(session)
  local shown = shown_entry(session)
  if latest and not (shown and shown.path == latest.path) then
    mark_entry(session, latest)
  end
end

local function undo_entry_current(ctx, entry)
  if (read_target(ctx, entry.target)) ~= entry.after then
    return false
  end
  return entry.target ~= "index" or git_mod.read_head(ctx.root, ctx.path, "HEAD") == entry.head
end

function M.undo(session)
  local queue = session and session.file_queue
  if not queue or queue.kind ~= "git" then
    return false, "Git hunk actions are only available in Git diff sessions"
  end
  local entry, stack = M.latest_undo(session)
  if not entry then
    return false, "no DiffBandit action to undo for this file"
  end
  local ctx = { root = queue.root, opts = queue.opts or {}, path = entry.path }
  local shown = shown_entry(session)
  local same_file = shown ~= nil and shown.path == entry.path
  local view_before = same_file and keep_view.capture(session) or nil

  if not undo_entry_current(ctx, entry) then
    local message = "cannot undo: " .. ctx.path .. " changed after the DiffBandit action"
    if same_file then
      return false, message
    end
    -- Off-screen and out of the queue, it would block every other undo for good.
    nvim.notify_info(message)
    session.action_undo[entry.path] = nil
    return M.undo(session)
  end

  local ok, write_err = write_target(ctx, entry.target, entry.before)
  if not ok then
    return false, write_err
  end
  stack[#stack] = nil
  if not same_file then
    -- The queue refresh that follows brings the file back.
    session.undo_return = { path = entry.path, chunk = entry.chunk_index }
    return true, nil
  end
  M.mark_undo_position(session, entry.path)
  M.refresh(session, session.current_chunk, view_before)
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

  local base = ctx.opts.base or "HEAD"
  local reference = staging_reference(ctx.opts)
  if mode == "all" and base ~= reference then
    -- The view's base (a merge base, an older revision) is not what staging
    -- compares against: find the staged changes through the worktree.
    local reference_text, index_text, worktree_text = all_mode_texts(session, ctx, reference)
    if (reference_text or "") == (index_text or "") then
      return states
    end
    for chunk_index, chunk in ipairs(session.view.chunks or {}) do
      local hunk = session.hunks and session.hunks[chunk.index or chunk_index]
      if hunk and #staged_parts(session, reference_text, index_text, worktree_text, hunk) > 0 then
        states[chunk_index] = true
      end
    end
    return states
  end

  local has_staged = git_mod.snapshot_has_staged_changes(ctx.queue, ctx.path)
  if has_staged == false then
    return states
  end
  -- Blobs read with the file's sources, while no git command has changed
  -- the index since.
  local blobs = session.left and session.left.git_stage_blobs
  if blobs and (blobs.generation ~= git_mod.generation() or base ~= "HEAD") then
    blobs = nil
  end
  if blobs then
    if blobs.head == blobs.index then
      return states
    end
  elseif has_staged == nil and base == "HEAD" then
    -- Read both sides at once; an index equal to HEAD has nothing staged,
    -- which spares the separate `diff --cached` probe.
    local read = git_mod.read_blobs(ctx.root, { "HEAD:" .. ctx.path, ":" .. ctx.path })
    blobs = { head = read[1][1] or "", index = read[2][1] or "" }
    if blobs.head == blobs.index then
      return states
    end
  elseif has_staged == nil and not git_mod.has_staged_changes(ctx.root, ctx.path) then
    return states
  end

  local staged_hunks = staged_hunks_for_session(session, ctx, blobs)
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
