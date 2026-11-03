-- Where a minimap's strip lives.
--
-- managed: a window/buffer pair owned by a host layout (the diff view's
--   overview sidecar splits). The host sizes and closes them.
-- float:   a float over the right edge of an editor window's text area,
--   editor-relative (like the connector canvas) and re-placed whenever the
--   layout changes. It never disturbs the window layout; it covers the last
--   `width` text columns, and hides when the window is too narrow.
local M = {}

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

function M.managed(get_win, get_buf)
  return {
    ensure = function()
      local win, buf = get_win(), get_buf()
      if valid_win(win) and valid_buf(buf) then
        return win, buf
      end
      return nil
    end,
    hide = function() end,
    close = function() end,
  }
end

local function scratch_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "diffbandit_minimap"
  return buf
end

--- Text-area geometry of `win` in editor cells: row, col, width, height
--- (0-based row/col, winbar excluded).
function M.text_area(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return nil
  end
  return {
    row = info.winrow - 1 + (info.winbar or 0),
    col = info.wincol - 1,
    width = info.width,
    height = info.height,
  }
end

--- opts = { min_window_width, zindex }
function M.float(opts)
  opts = opts or {}
  local self = { follows_layout = true }

  local function close_win()
    if valid_win(self.win) then
      pcall(vim.api.nvim_win_close, self.win, true)
    end
    self.win, self.cfg_key = nil, nil
  end

  function self.ensure(mm, width)
    local target = mm:target_win()
    if not target then
      close_win()
      return nil
    end
    -- Editor-relative floats open in the current tab: a background tab's
    -- minimap waits for its tab to be shown.
    if vim.api.nvim_win_get_tabpage(target) ~= vim.api.nvim_get_current_tabpage() then
      return nil
    end
    local area = M.text_area(target)
    local min_width = tonumber(opts.min_window_width) or 60
    if not area or area.width < math.max(min_width, width + 1) or area.height < 1 then
      close_win()
      return nil
    end
    if not valid_buf(self.buf) then
      self.buf = scratch_buf()
    end
    local cfg = {
      relative = "editor",
      row = area.row,
      col = area.col + area.width - width,
      width = width,
      height = area.height,
      focusable = false,
      zindex = tonumber(opts.zindex) or 20,
      border = "none",
    }
    local key = table.concat({ cfg.row, cfg.col, cfg.width, cfg.height }, ":")
    if valid_win(self.win) then
      if self.cfg_key ~= key then
        pcall(vim.api.nvim_win_set_config, self.win, cfg)
        self.cfg_key = key
      end
      return self.win, self.buf
    end
    local open_cfg = vim.tbl_extend("force", cfg, { style = "minimal", noautocmd = true, mouse = true })
    local ok, win = pcall(vim.api.nvim_open_win, self.buf, false, open_cfg)
    if not ok then
      open_cfg.mouse = nil
      ok, win = pcall(vim.api.nvim_open_win, self.buf, false, open_cfg)
    end
    if not ok then
      return nil
    end
    local hl = "DiffBanditOverviewContext"
    vim.wo[win].winhighlight = table.concat({
      "Normal:" .. hl, "NormalNC:" .. hl, "NormalFloat:" .. hl, "EndOfBuffer:" .. hl,
    }, ",")
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].winblend = 0
    vim.wo[win].fillchars = "eob: "
    vim.wo[win].scrolloff = 0
    self.win, self.cfg_key = win, key
    return win, self.buf
  end

  function self.hide()
    close_win()
  end

  function self.close()
    close_win()
    if valid_buf(self.buf) then
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
    self.buf = nil
  end

  return self
end

return M
