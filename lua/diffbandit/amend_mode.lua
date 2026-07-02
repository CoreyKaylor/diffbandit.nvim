-- Amend-mode toggling shared by the panel hosts (diff session and
-- standalone commit panel): seeds the commit message from the last commit
-- and reloads the file queue against the amend base.
local nvim = require("diffbandit.nvim")
local git = require("diffbandit.git")
local panel_mod = require("diffbandit.panel")
local queue_host = require("diffbandit.queue_host")

local M = {}

function M.set_amend_mode(host, enabled)
  if not host.file_queue or host.file_queue.kind ~= "git" or not host.file_queue.root then
    return false, "no Git file queue configured"
  end
  if not host.panel then
    return false, "no commit panel configured"
  end

  panel_mod.capture_message_lines(host)
  local current_entry = queue_host.current_entry(host)
  local preferred_path = current_entry and (current_entry.path or current_entry.old_path)

  if enabled then
    local base, err = git.amend_base(host.file_queue.root)
    if not base then
      nvim.notify_info(tostring(err))
      return false, err
    end
    if not host.normal_queue_opts then
      host.normal_queue_opts = panel_mod.clear_amend_opts((host.file_queue or {}).opts or {})
    end
    host.file_queue.opts = vim.tbl_extend("force", {}, host.normal_queue_opts, {
      mode = "all",
      base = base,
      stage_base = base,
      amend_mode = true,
    })
    host.file_queue.normal_opts = host.normal_queue_opts
    host.panel.amend = true
    if not host.panel.amend_loaded and vim.trim(table.concat(host.panel.message_lines or {}, "\n")) == "" then
      local message = git.last_commit_message(host.file_queue.root)
      if message then
        local loaded_lines = vim.split(message, "\n", { plain = true })
        host.panel.pre_amend_message_lines = vim.deepcopy(host.panel.message_lines or { "" })
        host.panel.amend_loaded_message_lines = loaded_lines
        host.panel.message_lines = loaded_lines
        host.panel.message_initialized = false
      end
      host.panel.amend_loaded = true
    end
  else
    if host.panel.amend_loaded_message_lines
        and panel_mod.lines_equal(host.panel.message_lines, host.panel.amend_loaded_message_lines) then
      host.panel.message_lines = host.panel.pre_amend_message_lines or { "" }
      host.panel.message_initialized = false
    end
    host.panel.pre_amend_message_lines = nil
    host.panel.amend_loaded_message_lines = nil
    host.file_queue.opts = panel_mod.clear_amend_opts(host.normal_queue_opts or (host.file_queue or {}).opts or {})
    host.file_queue.normal_opts = nil
    host.normal_queue_opts = nil
    host.panel.amend = false
  end

  return host:refresh_git_queue(preferred_path)
end

function M.clear_amend_mode(host)
  if host.file_queue then
    host.file_queue.opts = panel_mod.clear_amend_opts(host.normal_queue_opts or host.file_queue.opts or {})
    host.file_queue.normal_opts = nil
  end
  host.normal_queue_opts = nil
  if host.panel then
    host.panel.amend = false
    host.panel.amend_loaded = false
    host.panel.pre_amend_message_lines = nil
    host.panel.amend_loaded_message_lines = nil
  end
end

return M
