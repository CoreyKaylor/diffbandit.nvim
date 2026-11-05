-- Folder diff: open a folder session, open a row as a child file diff, and
-- return to the folder with q (port of run.sh run_folder_diff_test).
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

local function grep(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function expect(lines, needle, message, path)
  if not grep(lines, needle) then
    error(string.format("Folder diff test failed: %s (%s)\n%s", message, path, table.concat(lines, "\n")), 0)
  end
end

T["open child diff and return"] = function()
  local dir = child_mod.case_dir("folder")
  local left, right = dir .. "/left", dir .. "/right"
  state.write(left .. "/same.txt", { "same" })
  state.write(right .. "/same.txt", { "same" })
  state.write(left .. "/diff.txt", { "left" })
  state.write(right .. "/diff.txt", { "rght" })
  state.write(left .. "/left-only.txt", { "left-only" })
  state.write(right .. "/right-only.txt", { "right-only" })
  state.write(left .. "/nested/inner.txt", { "nested-left" })
  state.write(right .. "/nested/inner.txt", { "nested-right" })

  child:start()
  child:cmd("DiffBanditFolderDiff " .. vim.fn.fnameescape(left) .. " " .. vim.fn.fnameescape(right))
  child:settle()
  local capture = child:capture(dir, "capture")
  local capture_path = dir .. "/capture.txt"
  local initial, initial_path = child:state("DBWriteFolderState", dir, "folder-initial")
  child:cmd("DBSelectFolderPath diff.txt")
  child:keys("<CR>")
  child:settle()
  local child_state, child_path = child:state("DBWriteFolderState", dir, "folder-child")
  -- Scratch source panes carry the full source path (shown by <C-g>), not "[Scratch]".
  local pane_names = child:lua([[
    local s = require("diffbandit.state").sessions[vim.api.nvim_get_current_tabpage()]
    return { vim.api.nvim_buf_get_name(s.left_buf), vim.api.nvim_buf_get_name(s.right_buf) }
  ]])
  child:keys("q")
  child:settle()
  local ret, return_path = child:state("DBWriteFolderState", dir, "folder-return")

  for _, row in ipairs({ "same.txt", "left-only.txt", "right-only.txt" }) do
    expect(capture, row, "capture did not include expected folder rows", capture_path)
  end
  expect(initial, "surface=folder", "initial state was not a folder session", initial_path)
  expect(child_state, "surface=file", "opening a row did not create a child file diff", child_path)
  expect(child_state, "has_return_to=true", "child file diff did not carry return metadata", child_path)
  local real_left = vim.uv.fs_realpath(left .. "/diff.txt")
  local real_right = vim.uv.fs_realpath(right .. "/diff.txt")
  MiniTest.expect.equality(pane_names, { real_left .. " (left)", real_right .. " (right)" })
  expect(ret, "surface=folder", "q from child diff did not return to folder session", return_path)
  expect(ret, "selected_rel=diff.txt", "return did not restore selected folder row", return_path)
end

return T
