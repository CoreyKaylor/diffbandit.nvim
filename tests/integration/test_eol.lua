-- End-of-file newline and line-ending changes (issue #36): a file whose only
-- change is its final newline must still show a hunk, and hunk actions must
-- keep each target's final newline and line endings.
local child_mod = require("helpers.child")
local state = require("helpers.state")

local child = child_mod.new({ columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local function commit_baseline(repo, files)
  local args = { "add" }
  vim.list_extend(args, files)
  state.git(repo, args)
  state.git(repo, { "commit", "-m", "baseline" })
end

-- Raw bytes: state.git reads as text, which folds CRLF into LF.
local function blob(repo, spec)
  local result = vim.system({ "git", "-C", repo, "show", spec }, { text = false }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function raw(path)
  local f = assert(io.open(path, "rb"))
  local value = f:read("*a")
  f:close()
  return value
end

local function messages()
  return child:lua("return vim.fn.execute('messages')")
end

local function chunk_count()
  return child:lua("return #(_G.DiffBanditTestSession().view.chunks or {})")
end

local function screen()
  local plain = child:capture()
  return table.concat(plain, "\n")
end

-- The issue #36 shape: a CRLF file gains its final CRLF.
local function crlf_gains_final_newline(name)
  local dir = child_mod.case_dir(name)
  local repo = state.init_repo(dir .. "/repo")
  state.git(repo, { "config", "core.autocrlf", "false" })
  state.write(repo .. "/a.cs", "class A\r\n{\r\n}")
  commit_baseline(repo, { "a.cs" })
  state.write(repo .. "/a.cs", "class A\r\n{\r\n}\r\n")
  return repo
end

T["a final newline added to a CRLF file shows as a hunk"] = function()
  local repo = crlf_gains_final_newline("eol-crlf-shows")
  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.cs"):settle()

  state.eq(chunk_count(), 1, "one hunk for the final newline")
  local shown = screen()
  state.truthy(shown:find("No newline at end of file", 1, true), "left side should explain the change", shown)
  state.truthy(not shown:find("^M", 1, true), "CRs should not show", shown)
end

T["the final-newline hunk shows with ignore_whitespace too"] = function()
  local repo = crlf_gains_final_newline("eol-crlf-ignore-ws")
  child:start({ lines = 14, cwd = repo })
  child:lua("require('diffbandit').setup({ diff = { ignore_whitespace = true } })")
  child:cmd("DiffBanditGit -- a.cs"):settle()
  state.eq(chunk_count(), 1, "one hunk for the final newline")
end

T["staging and undoing the final-newline hunk is byte exact"] = function()
  local repo = crlf_gains_final_newline("eol-crlf-stage")
  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.cs"):settle()
  child:keys("]c"):settle()
  child:keys("<Space>"):settle()

  state.eq(blob(repo, ":a.cs"), "class A\r\n{\r\n}\r\n", "index gains the CRLF\n" .. messages())
  state.diff_clean(repo, "worktree", "a.cs", "nothing left unstaged")

  child:cmd("DBFocus right")
  child:keys("u"):settle()
  state.eq(blob(repo, ":a.cs"), "class A\r\n{\r\n}", "undo restores the index without it\n" .. messages())
end

T["discarding the final-newline hunk restores the file byte exact"] = function()
  local repo = crlf_gains_final_newline("eol-crlf-discard")
  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.cs"):settle()
  child:keys("]c"):settle()
  child:keys(">>"):settle()

  state.eq(raw(repo .. "/a.cs"), "class A\r\n{\r\n}", "worktree loses the final CRLF\n" .. messages())
  state.diff_clean(repo, "worktree", "a.cs", "nothing left unstaged")
end

T["a worktree file open in a buffer keeps its format through a discard"] = function()
  local repo = crlf_gains_final_newline("eol-crlf-buffer")
  child:start({ lines = 14, cwd = repo })
  child:cmd("edit a.cs")
  state.eq(child:lua("return vim.bo.fileformat"), "dos", "Vim reads the file as dos")
  child:cmd("DiffBanditGit -- a.cs"):settle()
  state.eq(chunk_count(), 1, "one hunk for the final newline")
  child:keys("]c"):settle()
  child:keys(">>"):settle()

  state.eq(raw(repo .. "/a.cs"), "class A\r\n{\r\n}", "worktree loses the final CRLF\n" .. messages())
  local buf = child:lua([[
    local bufnr = vim.fn.bufnr(vim.fn.getcwd() .. "/a.cs")
    return { eol = vim.bo[bufnr].endofline, ff = vim.bo[bufnr].fileformat, modified = vim.bo[bufnr].modified }
  ]])
  state.eq(buf, { eol = false, ff = "dos", modified = false }, "the buffer matches the file it now holds")
end

T["staging a new file's hunk stores it in its own format"] = function()
  local dir = child_mod.case_dir("eol-stage-new")
  local repo = state.init_repo(dir .. "/repo")
  state.git(repo, { "config", "core.autocrlf", "false" })
  state.write(repo .. "/base.txt", "base\n")
  commit_baseline(repo, { "base.txt" })
  state.write(repo .. "/new.cs", "a\r\nb")
  state.git(repo, { "add", "-N", "new.cs" })

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- new.cs"):settle()
  child:keys("]c"):settle()
  child:keys("<Space>"):settle()
  state.eq(blob(repo, ":new.cs"), "a\r\nb", "index holds the file's bytes\n" .. messages())
end

T["hunk actions keep a UTF-8 byte order mark"] = function()
  local dir = child_mod.case_dir("eol-bom")
  local repo = state.init_repo(dir .. "/repo")
  local bom = "\239\187\191"
  state.write(repo .. "/a.txt", bom .. "one\ntwo\nthree\n")
  commit_baseline(repo, { "a.txt" })
  state.write(repo .. "/a.txt", bom .. "one\ntwo\nTHREE\n")

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.txt"):settle()
  state.eq(chunk_count(), 1, "only the changed line differs")
  child:keys("]c"):settle()
  child:keys(">>"):settle()
  state.eq(raw(repo .. "/a.txt"), bom .. "one\ntwo\nthree\n", "discard keeps the BOM\n" .. messages())
end

T["staging a hunk keeps CRLF line endings"] = function()
  local dir = child_mod.case_dir("eol-stage-crlf")
  local repo = state.init_repo(dir .. "/repo")
  state.git(repo, { "config", "core.autocrlf", "false" })
  state.write(repo .. "/a.cs", "one\r\ntwo\r\nthree\r\n")
  commit_baseline(repo, { "a.cs" })
  state.write(repo .. "/a.cs", "ONE\r\ntwo\r\nthree\r\n")

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.cs"):settle()
  state.eq(chunk_count(), 1, "one changed line")
  child:keys("]c"):settle()
  child:keys("<Space>"):settle()
  state.eq(blob(repo, ":a.cs"), "ONE\r\ntwo\r\nthree\r\n", "index keeps CRLF\n" .. messages())
end

T["file pairs show a final-newline change"] = function()
  local dir = child_mod.case_dir("eol-file-pair")
  state.write(dir .. "/left.txt", "a\n}")
  state.write(dir .. "/right.txt", "a\n}\n")
  child:start({ lines = 14 })
  child:cmd("DiffBandit " .. dir .. "/left.txt " .. dir .. "/right.txt"):settle()
  state.eq(chunk_count(), 1, "one hunk for the final newline")
  local shown = screen()
  state.truthy(shown:find("No newline at end of file", 1, true), "left side should explain the change", shown)
end

T["a line-ending change is named in the headers"] = function()
  local dir = child_mod.case_dir("eol-line-endings")
  local repo = state.init_repo(dir .. "/repo")
  state.git(repo, { "config", "core.autocrlf", "false" })
  state.write(repo .. "/a.cs", "one\r\ntwo\r\n")
  commit_baseline(repo, { "a.cs" })
  state.write(repo .. "/a.cs", "one\ntwo\n")

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.cs"):settle()
  state.eq(chunk_count(), 0, "no line differs")
  local shown = screen()
  state.truthy(shown:find("[CRLF]", 1, true) and shown:find("[LF]", 1, true), "headers name both endings", shown)
end

T["staging a hunk keeps a file without a final newline"] = function()
  local dir = child_mod.case_dir("eol-stage-noeol")
  local repo = state.init_repo(dir .. "/repo")
  state.write(repo .. "/a.txt", "one\ntwo\nthree")
  commit_baseline(repo, { "a.txt" })
  state.write(repo .. "/a.txt", "ONE\ntwo\nthree")

  child:start({ lines = 14, cwd = repo })
  child:cmd("DiffBanditGit -- a.txt"):settle()
  child:keys("]c"):settle()
  child:keys("<Space>"):settle()

  state.eq(blob(repo, ":a.txt"), "ONE\ntwo\nthree", "index after stage\n" .. messages())
  state.eq(raw(repo .. "/a.txt"), "ONE\ntwo\nthree", "worktree untouched")
end

return T
