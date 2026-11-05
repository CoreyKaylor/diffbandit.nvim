-- 'wrap' in the source panes (issue #26): a wrapped line spans several
-- screen rows, and every gutter must follow. The fixtures tag each line with
-- its own number ("l12 …" / "r7 …"), so on every screen row the number pane
-- must show exactly the line that starts there, and stay blank on wrapped
-- continuation rows.
local child_mod = require("helpers.child")
local state = require("helpers.state")
local files = child_mod.files

local child = child_mod.new({ lines = 30, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

-- Split a captured row into its five panes: left text, left numbers,
-- connector, right numbers, right text.
local function panes(row)
  local parts = vim.split(row, "│", { plain = true })
  if #parts ~= 5 then
    return nil
  end
  return parts
end

local function check_side(plain, text_col, num_col, prefix, label)
  local errors = {}
  local starts, continuations = 0, 0
  for i, row in ipairs(plain) do
    local p = panes(row)
    if p then
      local text = vim.trim(p[text_col])
      local shown = p[num_col]:match("(%d+)")
      local tagged = text:match("^" .. prefix .. "(%d+) ")
      if tagged then
        starts = starts + 1
        if shown ~= tagged then
          errors[#errors + 1] = string.format("%s row %d: line %s shows number %s", label, i, tagged, tostring(shown))
        end
      elseif text ~= "" and not text:match("^~") then
        continuations = continuations + 1
        if shown then
          errors[#errors + 1] = string.format("%s row %d: wrapped continuation shows number %s", label, i, shown)
        end
      end
    end
  end
  if starts == 0 then
    errors[#errors + 1] = label .. ": no tagged lines on screen"
  end
  return errors, continuations
end

local function check(dir, name)
  child:settle()
  local plain = child:capture(dir, name)
  local errors, left_cont = check_side(plain, 1, 2, "l", name .. " left")
  local right_errors, right_cont = check_side(plain, 5, 4, "r", name .. " right")
  vim.list_extend(errors, right_errors)
  if left_cont + right_cont == 0 then
    errors[#errors + 1] = name .. ": no wrapped rows on screen (fixture should wrap)"
  end
  if #errors > 0 then
    error("wrap " .. name .. " failed (capture: " .. dir .. "):\n  - " .. table.concat(errors, "\n  - "), 0)
  end
  return plain
end

local function open(dir)
  child:start()
  child:cmd("DiffBandit " .. files .. "/left_wrap.txt " .. files .. "/right_wrap.txt")
  child:settle()
  child:cmd("DBFocus left")
  child:cmd("setlocal wrap")
  child:cmd("DBFocus right")
  child:cmd("setlocal wrap")
  return check(dir, "initial")
end

T["numbers follow wrapped rows"] = function()
  local dir = child_mod.case_dir("wrap-numbers")
  open(dir)
  -- Scrolling a wrapped pane moves its gutter by screen rows.
  child:keys("gg", "<C-e><C-e><C-e><C-e><C-e><C-e>")
  check(dir, "right-scrolled")
  child:cmd("DBFocus left")
  child:keys("gg", "<C-e><C-e><C-e><C-e><C-e><C-e><C-e><C-e><C-e><C-e><C-e>")
  check(dir, "left-scrolled")
end

T["smoothscroll part-way into a wrapped line"] = function()
  local dir = child_mod.case_dir("wrap-smoothscroll")
  open(dir)
  child:cmd("setlocal smoothscroll")
  -- r7 is a long changed line; scroll its first screen row off the top.
  child:lua([[
    local win = vim.api.nvim_get_current_win()
    local textoff = vim.fn.getwininfo(win)[1].textoff
    vim.fn.winrestview({ topline = 7, lnum = 8, col = 0, skipcol = vim.api.nvim_win_get_width(win) - textoff })
  ]])
  local plain = check(dir, "partial-top")
  -- The topmost right row is a continuation row (no number), and r8 starts
  -- on the row its pane shows it.
  local first
  for _, row in ipairs(plain) do
    first = panes(row)
    if first then
      break
    end
  end
  if not first or first[4]:match("%d") or vim.trim(first[5]):match("^r%d") then
    error("smoothscroll: expected a continuation row at the top:\n" .. table.concat(plain, "\n"), 0)
  end
end

T["toggling wrap off restores one row per line"] = function()
  local dir = child_mod.case_dir("wrap-toggle")
  open(dir)
  child:cmd("DBFocus left")
  child:cmd("setlocal nowrap")
  child:cmd("DBFocus right")
  child:cmd("setlocal nowrap")
  child:settle()
  local plain = child:capture(dir, "nowrap")
  local errors = check_side(plain, 1, 2, "l", "nowrap left")
  vim.list_extend(errors, (check_side(plain, 5, 4, "r", "nowrap right")))
  if #errors > 0 then
    error("wrap toggle failed (capture: " .. dir .. "):\n  - " .. table.concat(errors, "\n  - "), 0)
  end
end

T["resizing re-wraps the gutters"] = function()
  local dir = child_mod.case_dir("wrap-resize")
  open(dir)
  child:lua("vim.o.columns = 150")
  check(dir, "wider")
  child:lua("vim.o.columns = 100")
  check(dir, "narrower")
end

-- Merge panes: an edit in the result rebuilds both pairs, and that rebuild
-- must not reapply the panes' default window options over the user's
-- ':set wrap' (issue #26 follow-up: 'o' in the result turned wrap off).
T["merge edits keep the user's wrap"] = function()
  local dir = child_mod.case_dir("wrap-merge-edit")
  local repo = state.init_repo(dir .. "/repo")
  local long = string.rep("wrapped words ", 12)
  state.write(repo .. "/conflict.txt", { "one " .. long, "base", "three " .. long })
  state.git(repo, { "add", "conflict.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = vim.trim(state.git(repo, { "rev-parse", "--abbrev-ref", "HEAD" }))
  state.git(repo, { "checkout", "-b", "feature" })
  state.write(repo .. "/conflict.txt", { "one " .. long, "remote", "three " .. long })
  state.git(repo, { "commit", "-am", "remote change" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/conflict.txt", { "one " .. long, "local", "three " .. long })
  state.git(repo, { "commit", "-am", "local change" })
  state.git(repo, { "merge", "feature" }, { allow_fail = true })

  child:start({ cwd = repo })
  child:cmd("DiffBanditMerge conflict.txt")
  child:settle()
  local function wraps()
    return child:lua([=[
      local m = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
      local out = {}
      for _, key in ipairs({ "local_win", "result_win", "remote_win" }) do
        out[#out + 1] = vim.wo[m[key]].wrap
      end
      return out
    ]=])
  end
  child:lua([=[
    local m = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    for _, key in ipairs({ "local_win", "result_win", "remote_win" }) do
      vim.wo[m[key]].wrap = true
    end
    vim.api.nvim_set_current_win(m.result_win)
    vim.api.nvim_win_set_cursor(m.result_win, { 1, 0 })
  ]=])
  child:settle()
  child:keys("o", "inserted", "<Esc>")
  child:settle()
  local after = wraps()
  if not (after[1] and after[2] and after[3]) then
    error("wrap reset by a result edit: " .. vim.inspect(after), 0)
  end
  -- The result's number gutter follows the wrapped rows: line 1 wraps, so
  -- the inserted line 2 starts right below its last row. (Its band signs
  -- must not re-wrap the pane after the gutter is painted.)
  local rows = child:lua([=[
    local m = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    local lines = vim.api.nvim_buf_get_lines(m.result_left_num_buf, 0, -1, false)
    return { lines = lines, height = vim.api.nvim_win_text_height(m.result_win, { start_row = 0, end_row = 0 }).all }
  ]=])
  if rows.height < 2 then
    error("fixture line 1 should wrap in the result pane", 0)
  end
  local second = rows.lines[rows.height + 1] or ""
  if not second:match("2") or rows.lines[2]:match("%d") then
    error("result gutter not in row space after edit: " .. vim.inspect(rows), 0)
  end
end

return T
