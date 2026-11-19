-- Opt-in: open DiffBandit from fugitive's own commands (config.fugitive.auto_open).
local config_mod = require("diffbandit.config")
local fugitive = require("diffbandit.git.fugitive")
local keyhelp = require("diffbandit.util.keyhelp")
local nvim = require("diffbandit.util.nvim")
local pending = require("diffbandit.util.pending")
local state = require("diffbandit.state")

local M = {}

local DD_DESC = "Diff the file under the cursor"

local function enabled(config, flow)
  local auto_open = config_mod.section(config, "fugitive").auto_open
  if type(auto_open) == "table" then
    return auto_open[flow] == true
  end
  return auto_open == true
end

local function report(result, err)
  if not result and err then
    nvim.notify_error(tostring(err))
  end
end

-- A view in this tab already follows the list, so another would only stack.
local function view_open()
  local tab = vim.api.nvim_get_current_tabpage()
  local session = state.sessions[tab]
  return (session and not session.disposed) or state.panels[tab] ~= nil
end

-- Fugitive fires this before its first jump, and both tools share the event.
local function on_tool_list()
  local token = pending.begin("fugitive auto-open")
  vim.schedule(function()
    pending.done(token)
    local title = vim.fn.getqflist({ title = 0 }).title or ""
    local flow = title:match("%smergetool%f[%W]") and "mergetool" or "difftool"
    local config = state.get_config()
    -- `:Git! difftool` does not jump, so the current buffer is not the entry.
    if not enabled(config, flow) or view_open() or not fugitive.current_entry() then
      return
    end
    local diffbandit = require("diffbandit")
    if flow == "mergetool" then
      report(diffbandit.merge())
    else
      report(diffbandit.git_file())
    end
  end)
end

local function map_status_dd(buf)
  local existing = vim.fn.maparg("dd", "n", false, true)
  if existing.desc == "DiffBandit: " .. DD_DESC then
    return
  end
  local function fugitive_dd()
    if existing.rhs then
      -- maparg keeps <SID> literal, and it only resolves inside fugitive's script.
      local rhs = existing.rhs:gsub("<SID>", string.format("<SNR>%d_", existing.sid or 0))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(rhs, true, true, true), "n", false)
    end
  end
  vim.keymap.set("n", "dd", function()
    local target = fugitive.status_target()
    -- Commit and heading lines have no file to show: they stay fugitive's.
    if not (enabled(state.get_config(), "dd") and target and target.path) then
      return fugitive_dd()
    end
    local diffbandit = require("diffbandit")
    if target.status == "U" then
      report(diffbandit.merge())
    else
      report(diffbandit.git_file())
    end
  end, keyhelp.opts(buf, "Files", DD_DESC, { buffer = buf, nowait = true, silent = true }))
end

function M.setup(config)
  local group = vim.api.nvim_create_augroup("DiffBanditFugitiveAuto", { clear = true })
  if enabled(config, "mergetool") or enabled(config, "difftool") then
    vim.api.nvim_create_autocmd("QuickFixCmdPost", {
      group = group,
      pattern = "cfugitive-difftool",
      callback = on_tool_list,
    })
  end
  if enabled(config, "dd") then
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FugitiveIndex",
      callback = function()
        map_status_dd(vim.api.nvim_get_current_buf())
      end,
    })
  end
end

return M
