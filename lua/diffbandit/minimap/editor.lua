-- Minimaps for ordinary editor windows: one per window, opened by
-- :DiffBanditMinimap or automatically (config.minimap.auto). The strip is a
-- float on the window's right edge (minimap/placement.lua) showing git hunks
-- against the index and diagnostics (minimap/providers.lua). DiffBandit's
-- own tabs (diff, merge, folder, panel) are skipped: their views have their
-- own overview gutters.
local Minimap = require("diffbandit.minimap")
local placement = require("diffbandit.minimap.placement")
local providers = require("diffbandit.minimap.providers")
local state = require("diffbandit.state")

local M = {}

local instances = {}
local auto_group

local function options()
  return state.get_config().minimap or {}
end

local function in_diffbandit_tab(win)
  local tab = vim.api.nvim_win_get_tabpage(win)
  return state.sessions[tab] ~= nil or state.panels[tab] ~= nil
end

--- Whether `win` may show a minimap: a normal window on a file-like buffer
--- whose filetype is not excluded, outside DiffBandit's own tabs.
function M.eligible(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  if in_diffbandit_tab(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  local ft = vim.bo[buf].filetype
  for _, excluded in ipairs(options().exclude_filetypes or {}) do
    if ft == excluded then
      return false
    end
  end
  return true
end

function M.get(win)
  local mm = instances[win]
  if mm and not mm.disposed then
    return mm
  end
  instances[win] = nil
  return nil
end

function M.close(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  local mm = instances[win]
  instances[win] = nil
  if mm then
    mm:close()
  end
end

function M.open(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  if not auto_group then
    M.setup()
  end
  if not M.eligible(win) then
    return nil
  end
  local existing = M.get(win)
  if existing then
    existing:render()
    return existing
  end
  local config = state.get_config()
  local opts = options()
  local provider = providers.editor(vim.api.nvim_win_get_buf(win), opts)
  local mm = Minimap.new({
    config = config,
    options = opts,
    target = function()
      return win
    end,
    placement = placement.float({ min_window_width = opts.min_window_width, zindex = opts.zindex }),
    provider = provider,
    on_target_closed = function()
      M.close(win)
    end,
  })
  mm.editor_provider = provider
  instances[win] = mm
  mm:render()
  return mm
end

function M.toggle(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  if M.get(win) then
    M.close(win)
    return nil
  end
  return M.open(win)
end

--- All open editor minimaps (tests, :checkhealth-style listing).
function M.list()
  local out = {}
  for win in pairs(instances) do
    local mm = M.get(win)
    if mm then
      out[#out + 1] = mm
    end
  end
  return out
end

-- A window switched buffers: rebind, or close when no longer eligible.
local function on_buf_win_enter(win)
  local mm = M.get(win)
  if mm then
    if not M.eligible(win) then
      M.close(win)
      return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if mm.editor_provider.bufnr ~= buf then
      mm.editor_provider.set_buffer(mm, buf)
    end
    mm:render()
    return
  end
  if options().auto then
    M.open(win)
  end
end

--- Install the buffer-switch tracking (and auto-open when configured).
--- Called from setup(); safe to call again after a config change.
function M.setup()
  auto_group = vim.api.nvim_create_augroup("DiffBanditMinimapEditor", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "TabEnter" }, {
    group = auto_group,
    callback = function()
      -- Scheduled: a DiffBandit view registers its tab only after its
      -- windows exist, and a new window gets its buffer after WinNew.
      vim.schedule(function()
        -- Every minimap window, not only the current one: a buffer can be
        -- loaded into another window (previews, nvim_win_set_buf).
        local current = vim.api.nvim_get_current_win()
        local wins = { current }
        for win in pairs(instances) do
          if win ~= current then
            wins[#wins + 1] = win
          end
        end
        for _, win in ipairs(wins) do
          if vim.api.nvim_win_is_valid(win) then
            on_buf_win_enter(win)
          end
        end
      end)
    end,
  })
  if options().auto then
    vim.schedule(function()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if M.eligible(win) then
          M.open(win)
        end
      end
    end)
  end
end

return M
