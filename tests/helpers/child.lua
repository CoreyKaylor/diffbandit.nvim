-- Child-Neovim driver for integration tests (wraps MiniTest.new_child_neovim).
--
-- A headless child draws a full grid at 'lines' x 'columns' without any UI
-- attached. capture() reads it cell by cell through nvim__inspect_cell (RGB
-- fg/bg + attributes) and renders the same two artifacts tmux used to give us:
--   plain  - text rows, trailing spaces trimmed  (tmux capture-pane -p)
--   ansi   - rows with SGR escapes on attribute changes (capture-pane -e -p)
-- so tests/helpers/verify.lua checks run unchanged.
--
-- nvim__inspect_cell is a private API. If it ever breaks, the fallback is
-- screenattr()/screenstring() per cell plus a hl-id -> colors map built from
-- nvim_get_hl; only capture_grid() below would change.
local M = {}

local source = debug.getinfo(1, "S").source:gsub("^@", "")
M.root = vim.fn.fnamemodify(source, ":p:h:h:h")
M.init = M.root .. "/tests/integration/init.lua"
M.files = M.root .. "/tests/files"

local artifacts_root = vim.env.DIFFBANDIT_TEST_ARTIFACTS
if not artifacts_root or artifacts_root == "" then
  artifacts_root = vim.fn.tempname() .. "_diffbandit"
end
M.artifacts = artifacts_root

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
  return path
end

--- Per-case scratch directory under the artifacts root.
function M.case_dir(name)
  local dir = artifacts_root .. "/" .. name:gsub("[^%w%-_.]", "_")
  vim.fn.delete(dir, "rf")
  return ensure_dir(dir)
end

-- Runs inside the child: wait until DiffBandit has no armed timers or
-- in-flight async processes, twice in a row across an event-loop turn (a
-- callback may arm new work), then repaint.
local SETTLE = [[
local timeout = ...
local ok_mod, pending = pcall(require, "diffbandit.util.pending")
local deadline = vim.uv.now() + timeout
local quiet = 0
while quiet < 2 do
  if vim.uv.now() > deadline then
    return { ok = false, outstanding = ok_mod and pending.list() or {} }
  end
  vim.wait(5)
  if not ok_mod or pending.idle() then
    quiet = quiet + 1
  else
    quiet = 0
    vim.wait(math.max(1, deadline - vim.uv.now()), function()
      return pending.idle()
    end, 2)
  end
end
vim.cmd("redraw")
return { ok = true }
]]

-- Runs inside the child: read every cell of the default grid.
--
-- The separators between the number panes and the connector core are hidden
-- (blank fillchar) and covered by bridge floats (connector/bridge.lua). A
-- headless child does not composite floats into this grid, so those columns
-- read as the blank separator underneath. Unless `raw` is set, they are
-- captured as `│` so the layout parsers in verify.lua keep finding the pane
-- boundaries; test_gutter_bridge.lua checks the bridges themselves.
local CAPTURE = [[
local raw = ...
local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
local lines, columns = vim.o.lines, vim.o.columns
local marked = {}
if not raw then
  local ok, bridge = pcall(require, "diffbandit.connector.bridge")
  for _, sep in ipairs(ok and bridge.separator_cells() or {}) do
    for r = sep.top, sep.bottom do
      marked[r * columns + sep.col] = true
    end
  end
end
local rows = {}
for r = 0, lines - 1 do
  local row = {}
  for c = 0, columns - 1 do
    local cell = vim.api.nvim__inspect_cell(1, r, c)
    local text = cell[1]
    if marked[r * columns + c] and text == " " then
      text = "\226\148\130"
    end
    row[c + 1] = { text, cell[2] }
  end
  rows[r + 1] = row
end
return { rows = rows, fg = normal.fg, bg = normal.bg }
]]

local FLAGS = {
  { "bold", "1" },
  { "italic", "3" },
  { "underline", "4" },
  { "undercurl", "4:3" },
  { "reverse", "7" },
  { "strikethrough", "9" },
}

local function rgb(n)
  return string.format("%d;%d;%d", math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function cell_state(attrs, default_fg, default_bg)
  local state = { fg = attrs.foreground or default_fg, bg = attrs.background or default_bg, flags = {} }
  for _, flag in ipairs(FLAGS) do
    if attrs[flag[1]] then
      state.flags[flag[2]] = true
    end
  end
  return state
end

-- SGR transition from cur to new, emitted the way tmux does: one escape for
-- a reset (when an attribute turns off) plus added flags, then fg, then bg.
local function transition(cur, new)
  local out = {}
  local codes = {}
  for code in pairs(cur.flags) do
    if not new.flags[code] then
      codes[1] = "0"
      cur = { flags = {} }
      break
    end
  end
  for _, flag in ipairs(FLAGS) do
    local code = flag[2]
    if new.flags[code] and not cur.flags[code] then
      codes[#codes + 1] = code
    end
  end
  if #codes > 0 then
    out[1] = "\27[" .. table.concat(codes, ";") .. "m"
  end
  if new.fg ~= cur.fg then
    out[#out + 1] = new.fg and ("\27[38;2;" .. rgb(new.fg) .. "m") or "\27[39m"
  end
  if new.bg ~= cur.bg then
    out[#out + 1] = new.bg and ("\27[48;2;" .. rgb(new.bg) .. "m") or "\27[49m"
  end
  return table.concat(out)
end

--- Render a captured grid into { plain = {...}, ansi = {...} }.
function M.render_grid(grid)
  local plain, ansi = {}, {}
  local cur = { flags = {} }
  for r, row in ipairs(grid.rows) do
    local p, a = {}, {}
    for _, cell in ipairs(row) do
      local text = cell[1]
      if text ~= "" then -- "" is the right half of a wide character
        local state = cell_state(cell[2] or {}, grid.fg, grid.bg)
        a[#a + 1] = transition(cur, state)
        cur = state
        p[#p + 1] = text
        a[#a + 1] = text
      end
    end
    -- tmux strips trailing spaces from the finished row string (escapes
    -- included), so a row can end in an escape with its spaces dropped.
    plain[r] = (table.concat(p):gsub(" +$", ""))
    ansi[r] = (table.concat(a):gsub(" +$", ""))
  end
  return { plain = plain, ansi = ansi }
end

local Child = {}
Child.__index = Child

--- opts: lines, columns, cwd, args (extra nvim args), init (default integration init)
function M.new(opts)
  local self = setmetatable({ opts = opts or {} }, Child)
  self.child = MiniTest.new_child_neovim()
  return self
end

function Child:start(opts)
  opts = vim.tbl_extend("force", self.opts, opts or {})
  local args = { "-u", opts.init or M.init }
  if opts.cwd then
    vim.list_extend(args, { "--cmd", "cd " .. vim.fn.fnameescape(opts.cwd) })
  end
  vim.list_extend(args, {
    "--cmd",
    string.format("set lines=%d columns=%d", opts.lines or 48, opts.columns or 120),
  })
  vim.list_extend(args, opts.args or {})
  self.child.restart(args)
  return self
end

function Child:stop()
  self.child.stop()
end

function Child:cmd(command)
  self.child.cmd(command)
  return self
end

function Child:lua(code, args)
  return self.child.lua(code, args or {})
end

--- Typed keys (nvim_input), e.g. keys("]c"), keys("i", "value", "<Esc>").
function Child:keys(...)
  self.child.type_keys(...)
  return self
end

function Child:settle(timeout)
  local result = self.child.lua(SETTLE, { timeout or 5000 })
  if not result.ok then
    error("child did not settle; outstanding: " .. table.concat(result.outstanding or {}, ", "), 2)
  end
  return self
end

function Child:capture_grid(raw)
  return self.child.lua(CAPTURE, { raw == true })
end

--- Capture the screen, write capture.txt / capture.ansi into dir, and return
--- plain_lines, ansi_lines. opts.raw keeps bridged separators as drawn.
function Child:capture(dir, name, opts)
  local raw = opts and opts.raw == true
  -- The first read after a highlight redefinition can resolve cells against a
  -- stale attribute table (the grid holds attr ids; the table is rebuilt on the
  -- next event-loop turn). Read until two consecutive grids agree.
  local rendered = M.render_grid(self:capture_grid(raw))
  for _ = 1, 20 do
    local again = M.render_grid(self:capture_grid(raw))
    if vim.deep_equal(again, rendered) then
      break
    end
    rendered = again
  end
  if dir then
    name = name or "capture"
    vim.fn.writefile(rendered.plain, dir .. "/" .. name .. ".txt")
    vim.fn.writefile(rendered.ansi, dir .. "/" .. name .. ".ansi")
  end
  return rendered.plain, rendered.ansi
end

--- Run a DB* state-writer command into dir/<name>.state and return its lines.
function Child:state(command, dir, name, extra)
  local path = dir .. "/" .. name .. ".state"
  vim.fn.delete(path)
  self:cmd(command .. " " .. vim.fn.fnameescape(path) .. (extra and (" " .. extra) or ""))
  if vim.fn.filereadable(path) ~= 1 then
    error("state file was not written: " .. path, 2)
  end
  return vim.fn.readfile(path), path
end

return M
