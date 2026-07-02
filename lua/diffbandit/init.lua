local nvim = require("diffbandit.nvim")
local state = require("diffbandit.state")
local diff_mod = require("diffbandit.diff")
local Session = require("diffbandit.session")
local highlights = require("diffbandit.highlights")
local git_mod = require("diffbandit.git")
local source_mod = require("diffbandit.source")
local text = require("diffbandit.text")
local document = require("diffbandit.document")
local CommitPanel = require("diffbandit.commit_panel")
local Merge = require("diffbandit.merge")
local Folder = require("diffbandit.folder")
local git_workflows = require("diffbandit.git_workflows")
local queue_host = require("diffbandit.queue_host")
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

local function current_session()
  return state.sessions[vim.api.nvim_get_current_tabpage()]
end

local function current_panel()
  return state.panels[vim.api.nvim_get_current_tabpage()]
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
    return {
      title = (commit.short_hash or review.target or "Commit") .. " " .. (commit.subject or ""),
      subtitle = "Commit changes",
      base = review.base,
      target = review.target,
      author = commit.author,
      date = commit.date,
      help = "<CR> focus diff  ]f/[f files  ]c/[c hunks  q close",
    }
  elseif review.kind == "compare" then
    return {
      title = "Compare " .. tostring(review.requested_base or review.base) .. " with " .. tostring(review.target),
      subtitle = review.direct and "Direct branch comparison" or "Merge-base branch comparison",
      base = review.base,
      target = review.target,
      help = "<CR> focus diff  ]f/[f files  ]c/[c hunks  q close",
    }
  end
  return {
    title = "Git review",
    help = "<CR> focus diff  ]f/[f files  ]c/[c hunks  q close",
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

function M.git_commit(rev, opts)
  opts = opts or {}
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
  return start_review_queue(queue)
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
      local session, err = M.git_commit(rev, vim.tbl_extend("force", {}, opts, open_opts or {}))
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
  if row.right then
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

return M
