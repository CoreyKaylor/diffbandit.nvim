-- Git merge resolver (port of run.sh run_git_merge_test and
-- run_git_merge_lsp_test). The bash test ran its phases in sequence on
-- separate nvim instances; here each phase is its own case with its own
-- fixture, so they are independent.
local child_mod = require("helpers.child")
local state = require("helpers.state")

local child = child_mod.new({ lines = 32, columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

local function fail(message, detail)
  error("Git merge resolver test failed: " .. message .. (detail and ("\n" .. detail) or ""), 0)
end

local function has(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Host-side poll that does not run the host event loop (see state.wait_until).
local poll = state.wait_until

local function main_branch(repo)
  return (state.git(repo, { "branch", "--show-current" }):gsub("%s+$", ""))
end

-- Merge `branch` into the current branch and require it to conflict.
local function merge_must_conflict(repo, branch, message)
  local _, code = state.git(repo, { "merge", branch }, { allow_fail = true })
  if code == 0 then
    fail(message)
  end
end

-- conflict.txt / second_conflict.txt: local vs remote edits of one line.
local function write_merge_repo(repo)
  state.init_repo(repo)
  state.write(repo .. "/conflict.txt", { "one", "base", "three" })
  state.write(repo .. "/second_conflict.txt", { "alpha", "base two", "omega" })
  state.git(repo, { "add", "conflict.txt" })
  state.git(repo, { "add", "second_conflict.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = main_branch(repo)
  state.git(repo, { "checkout", "-b", "feature" })
  state.write(repo .. "/conflict.txt", { "one", "remote", "three" })
  state.write(repo .. "/second_conflict.txt", { "alpha", "remote two", "omega" })
  state.git(repo, { "commit", "-am", "remote change" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/conflict.txt", { "one", "local", "three" })
  state.write(repo .. "/second_conflict.txt", { "alpha", "local two", "omega" })
  state.git(repo, { "commit", "-am", "local change" })
  merge_must_conflict(repo, "feature", "fixture merge did not conflict")
end

T["panel conflict preview"] = function()
  local dir = child_mod.case_dir("git-merge-panel")
  local repo = dir .. "/repo"
  write_merge_repo(repo)

  child:start({ cwd = repo })
  child:cmd("DiffBanditCommitPanel")
  child:settle()
  child:keys("j")
  child:settle()
  local panel_capture = child:capture(dir, "panel_conflict_preview")
  local panel_state = child:state("DBWritePanelState", dir, "panel_after_conflict_open")
  child:keys("j")
  child:settle()
  local second_panel_state = child:state("DBWritePanelState", dir, "panel_after_second_conflict_open")

  state.contains(panel_state, "surface=session", "panel conflict preview should open a merge session")
  state.contains(panel_state, "panel_visible=true", "panel should remain visible after opening a conflict")
  state.contains(panel_state, "focus=panel", "panel should keep focus after opening a conflict")
  state.contains(panel_state, "row=  ! U conflict.txt", "panel should keep the selected conflict row visible")
  if not (has(panel_capture, "Merge Conflicts") and has(panel_capture, "local/c")
      and has(panel_capture, "merge result") and has(panel_capture, "remote/incom")) then
    fail("panel conflict preview did not render merge status headers (" .. dir .. "/panel_conflict_preview.txt)",
      table.concat(panel_capture, "\n"))
  end
  state.contains(second_panel_state, "surface=session", "panel second conflict preview should stay in a merge session")
  state.contains(second_panel_state, "panel_visible=true", "panel should remain visible after opening a second conflict")
  state.contains(second_panel_state, "focus=panel", "panel should keep focus after opening a second conflict")
  state.contains(second_panel_state, "row=  ! U second_conflict.txt", "panel should move to the second conflict row")
end

T["accept local and write"] = function()
  local dir = child_mod.case_dir("git-merge-accept")
  local repo = dir .. "/repo"
  write_merge_repo(repo)

  child:start({ cwd = repo })
  child:cmd("DiffBanditMerge conflict.txt")
  child:settle()
  local plain = child:capture(dir, "capture")
  if not (has(plain, "local/current") and has(plain, "merge result")
      and has(plain, "conflict 1/1") and has(plain, "remote/incoming")) then
    fail("merge status headers did not render (" .. dir .. "/capture.txt)", table.concat(plain, "\n"))
  end
  child:keys(">>")
  child:settle()
  child:cmd("w")
  child:settle()
  child:stop()

  local unmerged = state.git(repo, { "ls-files", "-u", "--", "conflict.txt" })
  if unmerged:find("%S") then
    fail("conflict remains unmerged", unmerged)
  end
  -- "$(cat file)" strips trailing newlines before comparing.
  local content = table.concat(state.read(repo .. "/conflict.txt") or {}, "\n"):gsub("\n+$", "")
  if content ~= "one\nlocal\nthree" then
    fail("accept-local result was not written", content)
  end
end

T["lua lsp attaches to the result only"] = function()
  -- Same skip as bash: no lua-language-server, no phase.
  if vim.fn.executable("lua-language-server") ~= 1 then
    MiniTest.skip("lua-language-server not found")
  end
  local dir = child_mod.case_dir("git-merge-lsp")
  local repo = dir .. "/lua-lsp-repo"
  state.init_repo(repo)
  local function body(arg)
    return { "local function compute(value)", "  return missing_global(value)", "end", "", "return compute(" .. arg .. ")" }
  end
  state.write(repo .. "/conflict.lua", body("1"))
  state.git(repo, { "add", "conflict.lua" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = main_branch(repo)
  state.git(repo, { "checkout", "-b", "incoming" })
  state.write(repo .. "/conflict.lua", body('"incoming"'))
  state.git(repo, { "commit", "-am", "incoming" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/conflict.lua", body("2"))
  state.git(repo, { "commit", "-am", "local" })
  local _, code = state.git(repo, { "merge", "incoming" }, { allow_fail = true })
  if code == 0 then
    error("Git merge LSP test failed: fixture merge did not conflict", 0)
  end

  child:start({ cwd = repo })
  child:cmd("DBEnableLuaLsp")
  child:cmd("DiffBanditMerge conflict.lua")
  child:settle()

  -- LSP startup is outside settle(): poll (host side) for what bash waited
  -- 4s for, the lua_ls client on the result buffer.
  local lsp_state, lsp_path
  poll(function()
    lsp_state, lsp_path = child:state("DBWriteEditableState", dir, "lua-lsp")
    return has(lsp_state, "lsp_clients=lua_ls")
  end, 30000)
  -- Give lua_ls time to publish diagnostics (missing_global) so the
  -- "no diagnostics on sources" checks below are meaningful; not asserted,
  -- as the bash test doesn't assert it either.
  poll(function()
    lsp_state, lsp_path = child:state("DBWriteEditableState", dir, "lua-lsp")
    local n = tonumber(state.value(lsp_state, "diagnostics") or "0") or 0
    return n > 0
  end, 15000)
  local local_state = child:state("DBWriteEditableState", dir, "lua-lsp-local", "local")
  local remote_state = child:state("DBWriteEditableState", dir, "lua-lsp-remote", "remote")

  state.contains(lsp_state, "role=result", "Lua merge LSP should inspect the center result buffer")
  state.contains(lsp_state, "buftype=", "Lua merge result should be a normal buffer")
  state.contains(lsp_state, "filetype=lua", "Lua merge result should keep Lua filetype")
  state.contains(lsp_state, "lsp_clients=lua_ls", "Lua merge result should have lua_ls attached (" .. lsp_path .. ")")
  state.contains(local_state, "role=local", "Lua merge LSP should inspect the local source buffer")
  state.contains(local_state, "filetype=lua", "Lua merge local source buffer should keep Lua filetype")
  state.contains(local_state, "modifiable=false", "Lua merge local source buffer should remain read-only")
  state.line_equals(local_state, "lsp_clients=", "Lua merge local source buffer should not attach LSP")
  state.line_equals(local_state, "diagnostics=0", "Lua merge local source buffer should not show diagnostics")
  state.contains(remote_state, "role=remote", "Lua merge LSP should inspect the remote source buffer")
  state.contains(remote_state, "filetype=lua", "Lua merge remote source buffer should keep Lua filetype")
  state.contains(remote_state, "modifiable=false", "Lua merge remote source buffer should remain read-only")
  state.line_equals(remote_state, "lsp_clients=", "Lua merge remote source buffer should not attach LSP")
  state.line_equals(remote_state, "diagnostics=0", "Lua merge remote source buffer should not show diagnostics")
end

T["full fixture resolve and commit"] = function()
  local dir = child_mod.case_dir("git-merge-full")
  local repo = dir .. "/full-repo"
  state.init_repo(repo)
  state.write(repo .. "/delete_vs_modify.txt", { "base delete/modify" })
  state.write(repo .. "/modify_vs_delete.txt", { "base modify/delete" })
  state.write(repo .. "/same_line.txt", { "base same" })
  state.git(repo, { "add", "delete_vs_modify.txt", "modify_vs_delete.txt", "same_line.txt" })
  state.git(repo, { "commit", "-m", "baseline" })
  local main = main_branch(repo)
  state.git(repo, { "checkout", "-b", "incoming" })
  state.write(repo .. "/add_add.txt", { "incoming add/add" })
  state.write(repo .. "/delete_vs_modify.txt", { "incoming modifies" })
  state.git(repo, { "rm", "modify_vs_delete.txt" })
  state.write(repo .. "/same_line.txt", { "incoming same" })
  state.git(repo, { "add", "-A" })
  state.git(repo, { "commit", "-m", "incoming conflict sides" })
  state.git(repo, { "checkout", main })
  state.write(repo .. "/add_add.txt", { "local add/add" })
  state.git(repo, { "rm", "delete_vs_modify.txt" })
  state.write(repo .. "/modify_vs_delete.txt", { "local modifies" })
  state.write(repo .. "/same_line.txt", { "local same" })
  state.git(repo, { "add", "-A" })
  state.git(repo, { "commit", "-m", "local conflict sides" })
  merge_must_conflict(repo, "incoming", "full fixture merge did not conflict")
  local porcelain = state.git(repo, { "status", "--porcelain" })
  local unmerged = 0
  for line in porcelain:gmatch("[^\n]+") do
    local xy = line:sub(1, 3)
    if xy == "AA " or xy == "DU " or xy == "UD " or xy == "UU " then
      unmerged = unmerged + 1
    end
  end
  if unmerged ~= 4 then
    fail("full fixture should have four unmerged paths", porcelain)
  end

  child:start({ cwd = repo })
  child:cmd("DiffBanditCommitPanel")
  child:settle()
  for _, path in ipairs({ "add_add.txt", "delete_vs_modify.txt", "modify_vs_delete.txt", "same_line.txt" }) do
    child:cmd("DBOpenQueuePath " .. path)
    child:settle()
    child:cmd("DBAcceptResolve local")
    child:settle()
  end
  child:cmd("DBPanelCommit full fixture merge")
  child:settle()
  local full_panel_state = child:state("DBWritePanelState", dir, "full_after_commit")
  child:stop()

  local left = state.git(repo, { "ls-files", "-u" })
  if left:find("%S") then
    fail("full fixture left unmerged entries", left)
  end
  local status = state.git(repo, { "status", "--porcelain" })
  if status ~= "" then
    fail("full fixture should be clean after commit", status)
  end
  local _, merge_head = state.git(repo, { "rev-parse", "-q", "--verify", "MERGE_HEAD" }, { allow_fail = true })
  if merge_head == 0 then
    fail("full fixture should complete the merge commit")
  end
  local message = state.git(repo, { "log", "-1", "--pretty=%B" })
  if message:gsub("\n", "") ~= "full fixture merge" then
    fail("full fixture commit message mismatch", message)
  end
  state.contains(full_panel_state, "queue_count=0", "full fixture commit should leave an empty queue")
end

return T
