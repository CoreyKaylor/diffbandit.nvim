-- Open the file a diff shows in a window of its own (navigation.open_file_key),
-- at the line under the cursor, or at the active hunk from the commit panel.
--
-- A Git or jj review opens the working-tree file. The line shown may come from
-- an older version (a commit from the log, the index), so it is carried to the
-- working tree by diffing what the pane shows against the file as it is now.
-- A diff of two plain files opens the file of the pane the cursor is in.

local config_mod = require("diffbandit.config")
local diff = require("diffbandit.diff")
local view_builder = require("diffbandit.diff.view")
local document = require("diffbandit.util.document")
local layout = require("diffbandit.util.layout")
local nvim = require("diffbandit.util.nvim")

local M = {}

local uv = vim.uv or vim.loop

local function is_binary(source)
  return source.binary_hex or source.git_binary_hex or source.binary_hidden or source.git_binary_hidden
end

-- Carry `line` of the hunks' left side to their right side: unchanged lines
-- shift by the lines added or removed above them, and a line inside a hunk
-- lands on the same offset into its replacement (clamped to it). Returns the
-- line and whether it maps to an unchanged line.
function M.map_line(hunks, line)
  local offset = 0
  for _, h in ipairs(hunks or {}) do
    local lstart, lcount = h.left.start, h.left.count
    local rstart, rcount = h.right.start, h.right.count
    if lcount == 0 then
      -- Insertion after line lstart.
      if line <= lstart then
        return line + offset, true
      end
      offset = offset + rcount
    else
      if line < lstart then
        return line + offset, true
      end
      if line < lstart + lcount then
        if rcount == 0 then
          -- Deleted lines: land on the line that follows them.
          return rstart + 1, false
        end
        return rstart + math.min(line - lstart, rcount - 1), false
      end
      offset = offset + rcount - lcount
    end
  end
  return line + offset, true
end

local function file_exists(path)
  return path and uv.fs_stat(path) ~= nil
end

local function in_review(session)
  return (session.left and session.left.git_relpath) or (session.right and session.right.git_relpath)
end

-- { path, line, exact, carry } for row `row` of `side`, or nil plus a
-- reason. `carry` holds the lines `line` counts in when they may differ from
-- the file's.
function M.resolve(session, side, row)
  if not session.view then
    return nil, "no diff to open"
  end
  local source = session[side]
  if in_review(session) then
    local right = session.right or {}
    if right.git_state == "metadata" then
      return nil, "nothing to open for " .. tostring(right.git_relpath)
    end
    local path = right.path
    local name = right.git_relpath or path
    if right.git_target == "absent" or not (file_exists(path) or document.find_loaded_buffer(path)) then
      return nil, tostring(name) .. " is not in the working tree"
    end
    if is_binary(right) then
      return { path = path, line = 1, exact = false }
    end
    local exact = true
    if side == "left" then
      row, exact = view_builder.counterpart_row(session.view.line_meta, "left", row)
    end
    -- Unless the pane is the working tree (or the file's own buffer), its
    -- line is carried to the file once it is open (see M.open).
    local carry = right.git_target ~= "worktree" and not right.editable
    return { path = path, line = row, exact = exact, carry = carry and session.view.right or nil }
  end

  -- Two plain files: the pane's own file, else the other pane's.
  local function file_of(src)
    local path = src and ((src.editable and src.editable.path) or src.path)
    if path and (file_exists(path) or document.find_loaded_buffer(path)) then
      return path
    end
  end
  local path = file_of(source)
  if path then
    return { path = path, line = is_binary(source) and 1 or row, exact = true }
  end
  local other = side == "left" and "right" or "left"
  path = file_of(session[other])
  if not path then
    return nil, "no file on disk to open"
  end
  local line, exact = view_builder.counterpart_row(session.view.line_meta, side, row)
  return { path = path, line = is_binary(session[other]) and 1 or line, exact = exact }
end

-- Every window-local option DiffBandit sets on its panes and panel.
local function diffbandit_window_options()
  local names = { winbar = true, fillchars = true }
  for _, opts in ipairs({ layout.win_opts.source(), layout.win_opts.panel() }) do
    for name in pairs(opts) do
      names[name] = true
    end
  end
  return names
end

-- :tabedit and :split copy the current window's options into the new window,
-- and Neovim also restores the options a buffer last had in a window: from a
-- DiffBandit pane either one carries the pane's look (highlights, no number
-- column, padding winbar) into the user's window. Put those options back to
-- the user's global values.
local function reset_window_options(win)
  local winhl = vim.api.nvim_get_option_value("winhighlight", { win = win })
  if not winhl:find("DiffBandit", 1, true) then
    return
  end
  vim.api.nvim_win_call(win, function()
    for name in pairs(diffbandit_window_options()) do
      local info = vim.api.nvim_get_option_info2(name, {})
      -- Global-local options drop their local value; window-local ones
      -- copy the global one.
      pcall(vim.cmd, (info.global_local and "set " or "setlocal ") .. name .. "<")
    end
  end)
end

-- The pane's buffer is the user's file now: closing the diff must not delete
-- it from under the new window.
local function release_buffer(session, bufnr)
  for _, side in ipairs({ "left", "right" }) do
    local editable = session[side] and session[side].editable
    if editable and editable.bufnr == bufnr then
      editable.created_by_diffbandit = false
    end
  end
end

function M.open(session, target)
  local navigation = config_mod.section(session.config, "navigation")
  local cmd = navigation.open_file_cmd or "tabedit"
  local ok, err = pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(target.path))
  if not ok then
    nvim.notify_error(tostring(err))
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  reset_window_options(win)
  release_buffer(session, bufnr)
  local line, exact = target.line or 1, target.exact
  if target.carry then
    -- Diff the text the pane showed against the buffer as it opened (the
    -- file, or a loaded buffer with its unsaved edits).
    local hunks = diff.compute_hunks_from_lines(target.carry, document.buffer_lines(bufnr),
      config_mod.section(session.config, "diff"))
    local carried
    line, carried = M.map_line(hunks, line)
    exact = exact and carried
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  line = math.min(math.max(1, line), line_count)
  pcall(vim.api.nvim_win_set_cursor, win, { line, exact and target.col or 0 })
  pcall(vim.cmd, "normal! zvzz")
  return true
end

-- The pane the cursor is in (or was last in, from a helper pane).
local function cursor_side(session)
  local win = vim.api.nvim_get_current_win()
  if win == session.left_win or win == session.left_num_win then
    return "left", session.left_win
  elseif win == session.right_win or win == session.right_num_win then
    return "right", session.right_win
  end
  local last = session.last_source_win
  if last and last == session.left_win then
    return "left", session.left_win
  end
  return "right", session.right_win
end

-- From the diff: the line (and column) under the cursor.
function M.open_at_cursor(session)
  local side, win = cursor_side(session)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local target, err = M.resolve(session, side, cursor[1])
  if not target then
    nvim.notify_info(err)
    return false
  end
  target.col = cursor[2]
  return M.open(session, target)
end

-- From the commit panel: the active hunk (the one ]c last moved to), else
-- the first hunk, else the top of the file.
function M.open_at_hunk(session)
  local view = session.view
  if not view then
    return false
  end
  local chunks = view.chunks or {}
  local chunk = chunks[session.current_chunk or 0] or chunks[1]
  local row = 1
  if chunk then
    row = math.max(1, chunk.right.finish >= chunk.right.start and chunk.right.start or chunk.right.start + 1)
  end
  local target, err = M.resolve(session, "right", row)
  if not target then
    nvim.notify_info(err)
    return false
  end
  target.col = 0
  return M.open(session, target)
end

return M
