local nvim = require("diffbandit.util.nvim")
local state = require("diffbandit.state")
local diff_mod = require("diffbandit.diff")
local Session = require("diffbandit.session")
local highlights = require("diffbandit.highlights")
local git_mod = require("diffbandit.vcs")
local source_mod = require("diffbandit.util.source")
local text = require("diffbandit.util.text")
local document = require("diffbandit.util.document")
local CommitPanel = require("diffbandit.panel.commit_host")

-- Views most launches never open load on first use.
local function lazy(name)
  return setmetatable({}, {
    __index = function(_, key)
      return require(name)[key]
    end,
  })
end
local Merge = lazy("diffbandit.merge")
local Folder = lazy("diffbandit.folder")
local git_workflows = lazy("diffbandit.git.workflows")
local queue_host = require("diffbandit.host.queue")
local config_mod = require("diffbandit.config")

local M = {}

local function configure_theme_refresh(config)
  if state.theme_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.theme_augroup)
    state.theme_augroup = nil
  end

  local theme = config_mod.section(config, "ui", "theme")
  if theme.auto_refresh == false then
    return
  end

  state.theme_augroup = vim.api.nvim_create_augroup("DiffBanditTheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.theme_augroup,
    callback = function()
      highlights.apply(state.get_config())
      state.highlights_ready = true
    end,
  })
end

local function ensure_highlights(config)
  if not state.highlights_ready then
    highlights.apply(config or state.get_config())
    configure_theme_refresh(config or state.get_config())
    state.highlights_ready = true
  end
end

function M.setup(opts)
  local config = state.set_config(opts)
  highlights.apply(config)
  configure_theme_refresh(config)
  state.highlights_ready = true
  return config
end

local function start_session(left_source, right_source, opts)
  local config = state.get_config()
  ensure_highlights(config)
  local session, err = Session.start({ left = left_source, right = right_source }, config, opts)
  if not session then
    return nil, err
  end
  state.register(session)
  return session
end

local function live_session(tabpage)
  local session = state.sessions[tabpage or vim.api.nvim_get_current_tabpage()]
  if session and not session.disposed then
    return session
  end
  return nil
end

local function live_panel(tabpage)
  local panel = state.panels[tabpage or vim.api.nvim_get_current_tabpage()]
  if panel and not panel.disposed then
    return panel
  end
  return nil
end

local function current_session()
  return live_session()
end

local function current_panel()
  return live_panel()
end

local CONTENT_BUF_FIELDS = {
  "left_buf",
  "right_buf",
  "local_buf",
  "result_buf",
  "remote_buf",
}

local function host_owns_buf(host, bufnr)
  if not host or host.disposed then
    return false
  end
  for i = 1, #CONTENT_BUF_FIELDS do
    if host[CONTENT_BUF_FIELDS[i]] == bufnr then
      return true
    end
  end
  local editable = host.right and host.right.editable
  if editable and editable.bufnr == bufnr then
    return true
  end
  local panel = host.panel
  if panel and (panel.nav_buf == bufnr or panel.commit_buf == bufnr) then
    return true
  end
  return false
end

local function any_live(map)
  for _, host in pairs(map) do
    if host and not host.disposed then
      return true
    end
  end
  return false
end

function M.has_session(tabpage)
  return live_session(tabpage) ~= nil
end

function M.has_any_session()
  return any_live(state.sessions)
end

function M.owns_buffer(bufnr)
  bufnr = tonumber(bufnr)
  if not bufnr then
    return false
  end
  for _, session in pairs(state.sessions) do
    if host_owns_buf(session, bufnr) then
      return true
    end
  end
  for _, panel in pairs(state.panels) do
    if host_owns_buf(panel, bufnr) then
      return true
    end
  end
  return false
end

-- Tabpage handles and bufnrs are both integers, so a bare number is
-- ambiguous. Use { tab = } / { buf = } or the named predicates.
function M.is_running(query)
  if query == nil then
    return M.has_session()
  end
  if type(query) ~= "table" then
    return false
  end

  local include_panel = query.panel == true
  if query.any then
    return M.has_any_session() or (include_panel and any_live(state.panels))
  end
  if query.buf ~= nil then
    return M.owns_buffer(query.buf)
  end
  if query.tab ~= nil or include_panel then
    local tab = query.tab
    if tab == nil or tab == true or tab == 0 then
      tab = vim.api.nvim_get_current_tabpage()
    end
    return M.has_session(tab) or (include_panel and live_panel(tab) ~= nil)
  end
  return false
end

local function call_current_session(method)
  local session = current_session()
  if not session then
    nvim.notify_info("no active DiffBandit session")
    return nil
  end
  if type(session[method]) ~= "function" then
    nvim.notify_error("unsupported action " .. method)
    return nil
  end
  return session[method](session)
end

local function load_queue_entry(queue, start_index, step)
  local sources, index, err = queue_host.load_sources({ file_queue = queue }, start_index, step)
  if not sources then
    return nil, err
  end
  queue.index = index
  return sources, nil
end

function M.files(left_path, right_path, opts)
  opts = opts or {}
  local config = state.get_config()
  local left_source, left_err = source_mod.from_file(left_path, opts.left_label, config)
  if not left_source then
    return nil, left_err
  end

  local right_source, right_err = document.source_from_file_or_buffer(right_path, opts.right_label, {
    editable = { target = "file" },
  }, function()
    return source_mod.from_file(right_path, opts.right_label, config)
  end)
  if not right_source then
    return nil, right_err
  end

  return start_session(left_source, right_source, opts)
end

function M.buffers(bufnr_a, bufnr_b, opts)
  opts = opts or {}
  local left_source = source_mod.from_buffer(bufnr_a, opts.left_label)
  local right_source = source_mod.from_buffer(bufnr_b, opts.right_label)
  right_source.editable = {
    target = "buffer",
    bufnr = bufnr_b,
    path = right_source.path,
  }
  return start_session(left_source, right_source, opts)
end

function M.git(opts)
  local config = state.get_config()
  ensure_highlights(config)
  local git_config = vim.tbl_extend("force", {}, config.git or {}, {
    hex = (config.ui or {}).hex or {},
  })
  local queue, err = git_mod.queue(opts or {}, git_config)
  if not queue then
    return nil, err
  end

  local loaded, load_err = load_queue_entry(queue, queue.index or 1, 1)
  if not loaded then
    return nil, load_err
  end

  return start_session(loaded.left, loaded.right, { queue = queue, chunk_position = "top" })
end

local function git_config_for(config)
  return vim.tbl_extend("force", {}, config.git or {}, {
    hex = (config.ui or {}).hex or {},
  })
end

local function review_panel_details(queue)
  local review = ((queue or {}).opts or {}).review or {}
  if review.kind == "commit" then
    local commit = review.commit or {}
    local walk = (queue or {}).log_walk
    return {
      title = (commit.short_hash or review.target or "Commit") .. " " .. (commit.subject or ""),
      subtitle = walk and string.format("Commit %d of %d in the log", walk.index, #walk.commits) or "Commit changes",
      base = review.base,
      target = review.target,
      author = commit.author,
      date = commit.date,
    }
  elseif review.kind == "compare" then
    return {
      title = "Compare " .. tostring(review.requested_base or review.base) .. " with " .. tostring(review.target),
      subtitle = review.direct and "Direct branch comparison" or "Merge-base branch comparison",
      base = review.base,
      target = review.target,
    }
  end
  return {
    title = "Git review",
  }
end

local function start_review_queue(queue)
  local loaded, load_err = load_queue_entry(queue, queue.index or 1, 1)
  if not loaded then
    return nil, load_err
  end
  return start_session(loaded.left, loaded.right, {
    queue = queue,
    chunk_position = "top",
    panel = true,
    panel_mode = "review",
    panel_initial_selection = queue.index or 1,
    panel_details = review_panel_details(queue),
  })
end

-- The entry for preferred_path, following a rename in either direction so
-- walking a file's history stays on that file.
local function queue_index_for_path(queue, preferred)
  if not preferred then
    return nil
  end
  for index, entry in ipairs(queue.entries or {}) do
    if entry.path == preferred.path
        or (preferred.old_path and entry.path == preferred.old_path)
        or (entry.old_path and entry.old_path == preferred.path) then
      return index
    end
  end
  return nil
end

-- opts.log_walk = { commits, index, browser, opts }: the review was opened
-- from a log browser, so the log keys can step to its neighbors.
-- opts.preferred_path = { path, old_path }: open on that file when present.
function M.git_commit(rev, opts)
  opts = opts or {}
  local log_walk = opts.log_walk
  local preferred_path = opts.preferred_path
  if log_walk or preferred_path then
    opts = vim.tbl_extend("force", {}, opts)
    opts.log_walk = nil
    opts.preferred_path = nil
  end
  local config = state.get_config()
  ensure_highlights(config)
  local root, root_err = git_mod.root(opts)
  if not root then
    return nil, root_err
  end
  local queue, err = git_mod.commit_queue(root, rev, opts, git_config_for(config))
  if not queue then
    return nil, err
  end
  queue.log_walk = log_walk
  queue.index = queue_index_for_path(queue, preferred_path) or queue.index
  return start_review_queue(queue)
end

local function focused_role(session)
  local win = vim.api.nvim_get_current_win()
  local panel = session.panel or {}
  if win == panel.nav_win then
    return "nav"
  elseif win == panel.commit_win then
    return "commit"
  elseif win == session.left_win then
    return "left"
  elseif win == session.right_win then
    return "right"
  end
  return nil
end

local function focus_role(session, role)
  local panel = session.panel or {}
  local win = ({
    nav = panel.nav_win,
    commit = panel.commit_win,
    left = session.left_win,
    right = session.right_win,
  })[role or ""]
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

-- Replace a commit review opened from the log with the review of the commit
-- delta rows away (1 = older, -1 = newer), keeping the file and focused pane.
function M.git_log_step(session, delta)
  session = session or current_session()
  local walk = session and session.file_queue and session.file_queue.log_walk
  if not walk then
    nvim.notify_info("this review was not opened from a Git log")
    return false
  end
  local entry = queue_host.current_entry(session)
  local preferred_path = entry and { path = entry.path, old_path = entry.old_path } or nil
  local role = focused_role(session)
  local target = walk.index + delta
  local next_session, commit, skipped
  -- A commit with nothing to show (an empty commit) cannot open; step over it.
  while walk.commits[target] do
    commit = walk.commits[target]
    next_session = M.git_commit(commit.hash, vim.tbl_extend("force", {}, walk.opts or {}, {
      log_walk = vim.tbl_extend("force", {}, walk, { index = target }),
      preferred_path = preferred_path,
    }))
    if next_session then
      break
    end
    skipped = (skipped or 0) + 1
    target = target + delta
  end
  if not next_session then
    nvim.notify_info(delta > 0 and "no older commit in this log" or "no newer commit in this log")
    return false
  end
  if skipped then
    nvim.notify_info(string.format("skipped %d commit%s with no changes to show", skipped, skipped == 1 and "" or "s"))
  end
  session:close_for_replacement(next_session)
  focus_role(next_session, role)
  local browser = walk.browser
  if browser and browser.is_open and browser:is_open() then
    -- Keep the log's cursor on the commit under review; find it by hash, as
    -- R may have refreshed the log since the walk began.
    for row, listed in ipairs(browser.commits or {}) do
      if listed.hash == commit.hash then
        pcall(vim.api.nvim_win_set_cursor, browser.win, { row + 1, 0 })
        break
      end
    end
  end
  return true
end

function M.git_compare(base, target, opts)
  opts = opts or {}
  local config = state.get_config()
  ensure_highlights(config)
  local root, root_err = git_mod.root(opts)
  if not root then
    return nil, root_err
  end
  local queue, err = git_mod.compare_queue(root, base, target, opts, git_config_for(config))
  if not queue then
    return nil, err
  end
  return start_review_queue(queue)
end

function M.git_compare_branches(opts)
  opts = opts or {}
  local root, root_err = git_mod.root(opts)
  if not root then
    return nil, root_err
  end
  git_workflows.select_branch(root, "DiffBandit compare base", function(base)
    git_workflows.select_branch(root, "DiffBandit compare target", function(target)
      local session, err = M.git_compare(base, target, opts)
      if not session and err then
        nvim.notify_error(tostring(err))
      end
    end)
  end)
  return true, nil
end

function M.git_log(opts)
  opts = opts or {}
  local config = state.get_config()
  ensure_highlights(config)
  return git_workflows.open_log(config, opts, {
    open_commit = function(rev, open_opts)
      open_opts = open_opts or {}
      local commit_opts = vim.tbl_extend("force", {}, opts, open_opts)
      local browser = open_opts.browser
      commit_opts.browser = nil
      commit_opts.log_index = nil
      if browser and open_opts.log_index then
        commit_opts.log_walk = {
          commits = browser.commits,
          index = open_opts.log_index,
          browser = browser,
          opts = vim.tbl_extend("force", {}, opts, { root = open_opts.root }),
        }
      end
      local session, err = M.git_commit(rev, commit_opts)
      if not session and err then
        nvim.notify_error(tostring(err))
      end
    end,
  })
end

function M.git_checkout(branch, opts)
  opts = opts or {}
  local root, root_err = git_mod.root(opts)
  if not root then
    return nil, root_err
  end
  local function checkout(selected)
    local ok, err = git_mod.checkout_branch(root, selected, opts)
    if ok then
      nvim.notify_info("checked out " .. tostring(selected))
    else
      nvim.notify_error(tostring(err))
    end
    return ok, err
  end
  if branch and branch ~= "" then
    return checkout(branch)
  end
  git_workflows.select_branch(root, "DiffBandit checkout branch", function(selected)
    checkout(selected)
  end, { local_only = true })
  return true, nil
end

function M.git_menu(opts)
  opts = opts or {}
  local root, root_err = git_mod.root(opts)
  if not root then
    return nil, root_err
  end
  git_workflows.open_menu(root, {
    changes = function(action_opts)
      local panel, err = M.commit_panel(action_opts)
      if not panel and err then
        nvim.notify_error(tostring(err))
      end
    end,
    compare = function(action_opts)
      M.git_compare_branches(action_opts)
    end,
    log = function(action_opts)
      local browser, err = M.git_log(action_opts)
      if not browser and err then
        nvim.notify_error(tostring(err))
      end
    end,
    file_log = function(action_opts)
      local path = vim.api.nvim_buf_get_name(0)
      local rel = git_mod.relpath(root, path)
      action_opts.pathspecs = rel and rel ~= "" and { rel } or {}
      local browser, err = M.git_log(action_opts)
      if not browser and err then
        nvim.notify_error(tostring(err))
      end
    end,
    checkout = function(action_opts)
      M.git_checkout(nil, action_opts)
    end,
  })
  return true, nil
end

local function start_merge_for_entry(queue, entry, opts)
  opts = opts or {}
  if not queue or not entry then
    return nil, "no conflict entry selected"
  end
  local config = state.get_config()
  ensure_highlights(config)
  local data, err = Merge.load(queue.root, entry.path, config)
  if not data then
    return nil, err
  end
  return Merge.start(data, config, vim.tbl_extend("force", opts, {
    queue = queue,
    queue_index = opts.queue_index or queue.index,
  }))
end

function M.merge(path, opts)
  local config = state.get_config()
  ensure_highlights(config)
  return Merge.start_for_path(path, opts or {}, config)
end

-- File-based three-way merge for external tools (jj ui.merge-editor, git
-- mergetool). opts: { base, left, right, output, path?, labels? }.
function M.merge_files(opts)
  local config = state.get_config()
  ensure_highlights(config)
  return Merge.start_files(opts or {}, config)
end

local function start_folder_file_diff(folder_session, row, context)
  if not row then
    return nil, "no folder row selected"
  end
  local config = state.get_config()
  local left_source
  local right_source
  if row.left then
    left_source = source_mod.from_file(row.left.path, row.rel, config)
  else
    left_source = source_mod.from_text("", row.rel, row.rel .. " (missing left)", {
      empty_reason = "missing from left folder",
    })
  end
  if not left_source then
    return nil, "unable to read left file"
  end
  if folder_session.editable_right then
    -- Diff-editor mode (jj split / squash -i): the right folder is the edit
    -- target. A file missing on the right is created on :w.
    local right_path = row.right and row.right.path or (folder_session.right_root .. "/" .. row.rel)
    if row.right then
      right_source = document.source_from_file_or_buffer(right_path, row.rel, {
        editable = { target = "file" },
      }, function()
        return source_mod.from_file(right_path, row.rel, config)
      end)
    else
      vim.fn.mkdir(vim.fn.fnamemodify(right_path, ":h"), "p")
      right_source = source_mod.from_text("", row.rel, row.rel .. " (missing right)", {
        empty_reason = "missing from right folder",
      })
      if right_source then
        right_source.editable = { target = "file", path = document.normalize_path(right_path) or right_path }
      end
    end
  elseif row.right then
    right_source = source_mod.from_file(row.right.path, row.rel, config)
  else
    right_source = source_mod.from_text("", row.rel, row.rel .. " (missing right)", {
      empty_reason = "missing from right folder",
    })
  end
  if not right_source then
    return nil, "unable to read right file"
  end

  local session, err = start_session(left_source, right_source, {
    return_to = {
      session = folder_session,
      tabpage = context and context.tabpage,
      context = context,
    },
  })
  if not session then
    nvim.notify_error(tostring(err))
    return nil, err
  end
  return session, nil
end

function M.folder_diff(left_path, right_path, opts)
  opts = opts or {}
  local config = state.get_config()
  ensure_highlights(config)
  return Folder.start(left_path, right_path, config, vim.tbl_extend("force", opts, {
    open_file_diff = opts.open_file_diff or start_folder_file_diff,
  }))
end

function M.commit_panel(opts)
  local existing_panel = current_panel()
  if existing_panel and not existing_panel.disposed then
    return existing_panel:toggle_commit_panel()
  end

  local existing = current_session()
  if existing and existing.file_queue and existing.file_queue.kind == "git" and type(existing.toggle_commit_panel) == "function" then
    return existing:toggle_commit_panel()
  end

  local config = state.get_config()
  ensure_highlights(config)
  local git_config = git_config_for(config)
  local queue, err = git_mod.queue(opts or {}, git_config)
  if not queue then
    return nil, err
  end
  queue.index = 0

  return CommitPanel.start(config, queue, {
    start_diff = function(left, right, start_opts)
      return start_session(left, right, start_opts)
    end,
    start_merge = function(entry, merge_queue, start_opts)
      return start_merge_for_entry(merge_queue or queue, entry, start_opts)
    end,
  })
end

-- Working-tree changes with the commit panel, opened on the first file
-- (unlike commit_panel(), which waits for a selection before showing a diff).
function M.git_panel(opts)
  local config = state.get_config()
  ensure_highlights(config)
  local queue, err = git_mod.queue(opts or {}, git_config_for(config))
  if not queue then
    return nil, err
  end
  local entry = queue.entries[1]
  if entry.status == "U" then
    queue.index = 1
    return start_merge_for_entry(queue, entry, {
      queue_index = 1,
      panel = true,
      panel_initial_selection = 1,
    })
  end
  local loaded, load_err = load_queue_entry(queue, 1, 1)
  if not loaded then
    return nil, load_err
  end
  return start_session(loaded.left, loaded.right, {
    queue = queue,
    chunk_position = "top",
    panel = true,
    panel_initial_selection = queue.index,
  })
end

-- Standalone entry point used by bin/diffbandit (see diffbandit.launcher).
function M.launch(args, opts)
  return require("diffbandit.launcher").launch(args, opts)
end

function M.git_file(path, opts)
  opts = vim.tbl_extend("force", {}, opts or {}, {
    scope = "current",
    path = path,
  })
  return M.git(opts)
end

function M.toggle_stage_hunk()
  return call_current_session("toggle_stage_hunk")
end

function M.stage_hunk()
  return call_current_session("stage_hunk")
end

function M.unstage_hunk()
  return call_current_session("unstage_hunk")
end

function M.discard_hunk()
  return call_current_session("discard_hunk")
end

function M.apply_left_hunk()
  return call_current_session("apply_left_hunk")
end

function M.apply_right_hunk()
  return call_current_session("apply_right_hunk")
end

function M.undo()
  return call_current_session("undo_action")
end

-- Close the DiffBandit view in the current tab: a diff, merge, or folder
-- session (with its tabpage) and/or a standalone commit panel. Under the
-- bin/diffbandit launcher this quits nvim, matching the panel's close key.
function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  local session = live_session(tab)
  local panel = live_panel(tab)
  if not session and not panel then
    nvim.notify_info("no DiffBandit view in this tab")
    return false
  end
  if require("diffbandit.launcher").should_quit_on_close(tab) then
    pcall(vim.cmd, "confirm qall")
    return true
  end
  if panel then
    panel:close()
  end
  if session then
    session:close()
  end
  return true
end

return M
