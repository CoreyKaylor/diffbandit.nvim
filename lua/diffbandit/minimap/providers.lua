-- What a minimap draws: lines (code shape, scale), hunk marks and
-- diagnostics.
--
-- session_side: one side of a 2-way diff view (its hunks, its lines).
-- editor:       an ordinary buffer: hunks of the buffer against the git
--               index (read asynchronously, re-diffed with vim.diff after
--               edits) and vim.diagnostic entries.
local overview = require("diffbandit.util.overview")
local ui = require("diffbandit.util.ui")

local M = {}

function M.session_side(session, side)
  local function buf()
    return side == "left" and session.left_buf or session.right_buf
  end
  return {
    buf = buf,
    lines = function()
      return ((session.view or {})[side]) or {}
    end,
    marks = function()
      return session:overview_marks(side)
    end,
  }
end

-- --- git hunks ---------------------------------------------------------------

local root_cache = {}

local function git_root(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  local cached = root_cache[dir]
  if cached ~= nil then
    return cached or nil
  end
  local ok, git = pcall(require, "diffbandit.git")
  local root = ok and git.find_root(dir) or nil
  root_cache[dir] = root or false
  return root
end

local function text_diff()
  return (vim.text and vim.text.diff) or vim.diff
end

--- Hunks of `new` against `old` (line lists) as
--- { { start, count, kind } } in `new` lines; a deletion is a zero-count
--- hunk at the line after which lines were removed (at least 1).
function M.line_hunks(old, new)
  local a = #old > 0 and (table.concat(old, "\n") .. "\n") or ""
  local b = #new > 0 and (table.concat(new, "\n") .. "\n") or ""
  local ok, indices = pcall(text_diff(), a, b, { result_type = "indices" })
  local out = {}
  if not ok or type(indices) ~= "table" then
    return out
  end
  for _, h in ipairs(indices) do
    local ca, sb, cb = h[2], h[3], h[4]
    if cb == 0 then
      out[#out + 1] = { start = math.max(1, sb), count = 0, kind = "delete" }
    elseif ca == 0 then
      out[#out + 1] = { start = sb, count = cb, kind = "add" }
    else
      out[#out + 1] = { start = sb, count = cb, kind = "change" }
    end
  end
  return out
end

--- Per-line marks from line hunks; the hunk under `cursor` is current.
function M.hunk_marks(hunks, cursor)
  local marks = {}
  for _, h in ipairs(hunks or {}) do
    local last = h.start + math.max(1, h.count) - 1
    local current = cursor ~= nil and cursor >= h.start and cursor <= last
    for line = h.start, last do
      marks[#marks + 1] = { line = line, kind = h.kind, current = current }
    end
  end
  return marks
end

--- opts = config.minimap (git, git_debounce_ms, diagnostics).
function M.editor(bufnr, opts)
  opts = opts or {}
  local p = { bufnr = bufnr }
  local git_state = {}

  local function lines()
    if not vim.api.nvim_buf_is_valid(p.bufnr) then
      return {}
    end
    local tick = vim.api.nvim_buf_get_changedtick(p.bufnr)
    if p.lines_tick ~= tick then
      p.lines_cache = vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false)
      p.lines_tick = tick
    end
    return p.lines_cache
  end

  local function rediff(mm)
    if git_state.index_lines then
      git_state.hunks = M.line_hunks(git_state.index_lines, lines())
    else
      git_state.hunks = {}
    end
    if mm then
      mm:request_render()
    end
  end

  local function refresh_index(mm)
    if opts.git == false or not vim.api.nvim_buf_is_valid(p.bufnr) then
      return
    end
    local name = vim.api.nvim_buf_get_name(p.bufnr)
    if name == "" or vim.bo[p.bufnr].buftype ~= "" then
      return
    end
    local root = git_root(name)
    if not root then
      return
    end
    local git = require("diffbandit.git")
    local rel = git.relpath(root, name)
    local gen = (git_state.gen or 0) + 1
    git_state.gen = gen
    git.read_index_async(root, rel, function(text)
      if git_state.gen ~= gen or (mm and mm.disposed) then
        return
      end
      if text then
        local index_lines = vim.split(text, "\n", { plain = true })
        if index_lines[#index_lines] == "" then
          index_lines[#index_lines] = nil
        end
        git_state.index_lines = index_lines
      else
        git_state.index_lines = nil -- untracked or not in the index
      end
      rediff(mm)
    end)
  end

  function p.buf()
    return p.bufnr
  end

  p.lines = lines

  function p.line_count()
    if not vim.api.nvim_buf_is_valid(p.bufnr) then
      return 0
    end
    return vim.api.nvim_buf_line_count(p.bufnr)
  end

  -- Marks are rebuilt only when the hunks or the hunk under the cursor
  -- change, so the image key and spans can be reused by table identity.
  function p.marks(mm)
    local win = mm:target_win()
    local cursor = win and vim.api.nvim_win_get_cursor(win)[1] or nil
    local hunks = git_state.hunks
    local current = 0
    for i, h in ipairs(hunks or {}) do
      if cursor and cursor >= h.start and cursor <= h.start + math.max(1, h.count) - 1 then
        current = i
        break
      end
    end
    local cache = p.marks_cache
    if not (cache and cache.hunks == hunks and cache.current == current) then
      cache = { hunks = hunks, current = current, marks = M.hunk_marks(hunks, cursor) }
      p.marks_cache = cache
    end
    return cache.marks
  end

  local diag = opts.diagnostics
  if type(diag) ~= "table" then
    diag = { enabled = diag ~= false }
  end
  if diag.enabled ~= false then
    function p.diagnostics()
      return overview.buffer_diagnostics(p.bufnr, diag.min_severity or "warn")
    end
  end

  function p.on_text_changed(mm)
    ui.reschedule_once(p, "git_rediff_scheduled", function()
      if not mm.disposed then
        rediff(mm)
      end
    end, tonumber(opts.git_debounce_ms) or 300)
  end

  function p.attach(mm)
    p.augroup = vim.api.nvim_create_augroup("DiffBanditMinimapGit" .. mm.id, { clear = true })
    -- The index changes on write-and-stage, external git commands (focus
    -- returns) and DiffBandit's own staging (buffer entered again).
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "FocusGained" }, {
      group = p.augroup,
      callback = function(ev)
        if ev.event == "FocusGained" or ev.buf == p.bufnr then
          refresh_index(mm)
        end
      end,
    })
    refresh_index(mm)
  end

  function p.detach()
    ui.cancel_schedule_once(p, "git_rediff_scheduled")
    git_state.gen = (git_state.gen or 0) + 1
    if p.augroup then
      pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
      p.augroup = nil
    end
  end

  --- The target window now shows another buffer.
  function p.set_buffer(mm, buf)
    p.bufnr = buf
    p.lines_cache, p.lines_tick = nil, nil
    git_state.index_lines, git_state.hunks = nil, nil
    mm:reset_code()
    refresh_index(mm)
  end

  --- Test hook: the git state.
  function p._git_state()
    return git_state
  end

  return p
end

--- Forget cached repository roots (tests, repositories created later).
function M.reset_roots()
  root_cache = {}
end

return M
