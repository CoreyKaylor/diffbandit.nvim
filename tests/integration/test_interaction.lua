-- Interaction scenarios: listchars isolation, chunk/document navigation, and
-- editing the right buffer of a 2-way diff.
local child_mod = require("helpers.child")
local state = require("helpers.state")
local files = child_mod.files

local child = child_mod.new({ columns = 120 })

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      child:stop()
    end,
  },
})

T["listchars"] = function()
  local dir = child_mod.case_dir("listchars")
  state.write(dir .. "/left.txt", "same  \nleft\n")
  state.write(dir .. "/right.txt", "same  \nright\n")

  child:start({ lines = 24 })
  child:cmd("set list listchars=trail:·")
  child:cmd("DiffBandit " .. dir .. "/left.txt " .. dir .. "/right.txt"):settle()
  local plain = child:capture(dir)
  local text = table.concat(plain, "\n")

  state.truthy(text:find("same··", 1, true), "Listchars test failed: source panes did not retain trailing-space markers", text)
  state.truthy(not text:find("····", 1, true), "Listchars test failed: connector or gutter panes rendered trailing-space markers", text)
end

T["navigation"] = function()
  local dir = child_mod.case_dir("navigation")
  child:start({ lines = 8 })
  child:cmd("DiffBandit " .. files .. "/left_navigation.txt " .. files .. "/right_navigation.txt"):settle()

  local function snap(name)
    child:settle()
    return child:state("DBWriteState", dir, name)
  end
  local function expect(lines, label, wanted)
    for _, needle in ipairs(wanted) do
      state.contains(lines, needle, label)
    end
  end

  local initial = snap("initial")
  child:keys("]c")
  local next = snap("after-next")
  child:keys("]c")
  child:settle()
  child:keys("]c")
  local final = snap("after-final")
  child:keys("[c")
  local prev_delete = snap("after-prev-delete")
  child:keys("[c")
  local prev_add = snap("after-prev-add")
  child:keys("[c")
  local prev_change = snap("after-prev-change")
  child:cmd("DBViewport 5 7")
  child:keys("[d")
  local doc_top = snap("after-doc-top")
  child:keys("]c")
  local doc_top_next = snap("after-doc-top-next")
  child:keys("]d")
  local doc_bottom = snap("after-doc-bottom")
  child:keys("[c")
  local doc_bottom_prev = snap("after-doc-bottom-prev")

  expect(initial, "Navigation initial state failed", { "focus=right", "left_top=1", "right_top=1", "chunk=1" })
  expect(next, "Navigation next-change state failed",
    { "focus=right", "left_top=6", "right_top=6", "left_cursor=6", "right_cursor=7", "chunk=2" })
  expect(final, "Navigation final-change state failed", { "focus=right", "left_top=12", "right_top=12", "chunk=4" })
  expect(prev_delete, "Navigation prev-delete state failed",
    { "focus=right", "left_top=9", "right_top=9", "left_cursor=9", "right_cursor=9", "chunk=3" })
  expect(prev_add, "Navigation prev-add state failed",
    { "focus=right", "left_top=6", "right_top=6", "left_cursor=6", "right_cursor=7", "chunk=2" })
  expect(prev_change, "Navigation prev-change state failed",
    { "focus=right", "left_top=3", "right_top=3", "left_cursor=3", "right_cursor=3", "chunk=1" })
  expect(doc_top, "Navigation document-top state failed",
    { "focus=right", "left_top=1", "right_top=1", "left_cursor=1", "right_cursor=1", "chunk=0" })
  expect(doc_top_next, "Navigation document-top next-change state failed",
    { "focus=right", "left_top=3", "right_top=3", "chunk=1" })
  expect(doc_bottom, "Navigation document-bottom state failed",
    { "focus=right", "left_top=11", "right_top=11", "left_cursor=13", "right_cursor=13", "chunk=5" })
  expect(doc_bottom_prev, "Navigation document-bottom prev-change state failed",
    { "focus=right", "left_top=12", "right_top=12", "chunk=4" })
end

T["editable"] = function()
  local dir = child_mod.case_dir("editable")
  state.write(dir .. "/left.lua", { 'local value = "left"', "return value" })
  state.write(dir .. "/right.lua", { "", "return true" })

  child:start({ lines = 24, args = { "-n" } })
  child:cmd("DiffBandit " .. dir .. "/left.lua " .. dir .. "/right.lua"):settle()
  -- The side argument follows the state path.
  local left_state = child:state("DBWriteEditableState", dir, "left", "left")
  child:cmd("DBFocus right")
  child:keys("g", "g", "0")
  child:keys("i", "value", "<Esc>")
  child:settle()
  local typed_state = child:state("DBWriteEditableState", dir, "typed")
  child:keys("u")
  child:settle()
  local undo_state = child:state("DBWriteEditableState", dir, "undo")

  state.contains(left_state, "role=left", "editable diff should inspect the left source buffer")
  state.contains(left_state, "filetype=lua", "editable diff left source buffer should keep Lua filetype")
  state.contains(left_state, "modifiable=false", "editable diff left source buffer should remain read-only")
  state.line_equals(left_state, "lsp_clients=", "editable diff left source buffer should not attach LSP")
  state.line_equals(left_state, "diagnostics=0", "editable diff left source buffer should not show diagnostics")
  state.contains(typed_state, "role=right", "editable diff should inspect the right buffer")
  state.contains(typed_state, "buftype=", "editable diff right buffer should be a normal buffer")
  state.contains(typed_state, "filetype=lua", "editable diff right buffer should keep Lua filetype")
  state.contains(typed_state, "line1=value", "editable diff insert should preserve typed character order")
  state.contains(undo_state, "line1=", "editable diff u should use native buffer undo")
end

return T
