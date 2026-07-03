local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(test_dir .. "/..", ":p")
package.path = package.path .. ";" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua"

local config_mod = require("diffbandit.config")
local config = config_mod.defaults()
local diff = require("diffbandit.diff")
local highlights = require("diffbandit.highlights")
local view = require("diffbandit.view")
local paths_mod = require("diffbandit.connector_routes")
local Session = require("diffbandit.session")
local git_mod = require("diffbandit.git")
local actions_mod = require("diffbandit.actions")
local status_mod = require("diffbandit.status")
local hex_mod = require("diffbandit.hex")
local panel_mod = require("diffbandit.panel")
local overview_mod = require("diffbandit.overview")
local merge_mod = require("diffbandit.merge")
local diff_pair_mod = require("diffbandit.diff_pair")
local state_mod = require("diffbandit.state")
local folder_mod = require("diffbandit.folder")
local folder_model_mod = require("diffbandit.folder_model")
local merge_model_mod = require("diffbandit.merge_model")
local source_mod = require("diffbandit.source")
local text_mod = require("diffbandit.text")

-- Helper: read file lines
local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return {} end
  return lines
end

local function write_binary_file(path, bytes)
  local uv = vim.uv or vim.loop
  local fd = assert(uv.fs_open(path, "w", 420))
  assert(uv.fs_write(fd, bytes, 0))
  assert(uv.fs_close(fd))
end

-- Helper: convert lines to text
local function to_text(lines)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n"
end

local function test_source(label, lines)
  return {
    label = label,
    path = label,
    lines = lines,
    text = to_text(lines),
    filetype = "",
  }
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "assertion failed") .. string.format("\nExpected: %s\nActual:   %s", tostring(b), tostring(a)))
  end
end

local function assert_ne(a, b, msg)
  if a == b then
    error((msg or "assertion failed") .. string.format("\nExpected values to differ, both were: %s", tostring(a)))
  end
end

local function buffer_keymap_callback(bufnr, mode, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    if map.lhs == lhs then
      return map.callback
    end
  end
  return nil
end

assert_eq(config.git.panel.keys.toggle_amend, "<Space>",
  "Commit panel amend toggle should use the commit-pane normal-mode space key")
assert_eq(config.git.panel.keys.focus_panel, "C",
  "Git diff document focus-panel key should default to normal-mode C")
assert_eq(config.git.panel.keys.file_actions, "a",
  "Commit panel file actions should default to normal-mode a")
assert_eq(config.git.panel.keys.commit, nil, "Commit panel should commit through :w by default")
assert_eq(config.ui.overview.enabled, true, "Overview gutter should be enabled by default")
assert_eq(config.ui.overview.width, 1, "Overview gutter should default to one column")
assert_eq(config.ui.connector_width, 3, "Connector core should default to a compact minimum width")
assert_eq(config.ui.connector_max_width, 24, "Connector core widening should default to a bounded maximum")
assert_eq(config.ui.scroll_debounce_ms, 16, "Viewport scroll rerenders should debounce by default")
assert_eq(config.merge.result_initial_content, "base", "Merge result should initialize from the base by default")
assert_eq(config.merge.keys.accept_local, ">>", "Merge accept-local key should default to >>")
assert_eq(config.navigation.snap_key, "]s", "Session snap-to-cursor key should default to ]s")
assert_eq(config.merge.keys.snap, "]s", "Merge snap-to-cursor key should default to ]s")
assert_eq(config.folder.compare.mode, "digest", "Folder diff should default to digest comparison")
assert_eq(config.folder.gutter_width, 7, "Folder diff gutter should default to a centered seven-column status pane")
assert_eq(config.folder.compare.batch_size, 64, "Folder diff digest batching should default to 64 file pairs")
assert_eq(config.folder.compare.max_concurrency, 2, "Folder diff should default to bounded digest concurrency")
assert_eq(config.folder.keys.open, "<CR>", "Folder diff open key should default to enter")

do
  assert_eq(text_mod.to_text({}), "", "Shared text helper should serialize empty lines as empty text")
  assert_eq(text_mod.to_text({ "a", "b" }), "a\nb\n", "Shared text helper should preserve trailing newline convention")
  assert_eq(#text_mod.split_lines("a\nb\n"), 2, "Shared text helper should drop final empty split segment")
  local replaced = text_mod.replace_range({ "a", "c" }, 1, 0, { "b" })
  assert_eq(table.concat(replaced, ","), "a,b,c", "Shared range helper should insert after zero-count start")

  local source_obj = source_mod.from_text("one\ntwo\n", "sample.lua", "sample", { role = "left" })
  assert_eq(source_obj.text, "one\ntwo\n", "Shared source helper should normalize source text")
  assert_eq(source_obj.role, "left", "Shared source helper should merge metadata")

  assert_eq(folder_model_mod.is_difference_status("different"), true,
    "Folder model should classify different as a difference")
  assert_eq(folder_model_mod.is_difference_status("same"), false,
    "Folder model should not classify same rows as differences")
  assert_eq(merge_model_mod.line_ending_warning({ left = "a\n", right = "b\r\n" }),
    "line endings differ across conflict stages",
    "Merge model should report mixed conflict-stage line endings")
end

do
  local right_path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "right original" }, right_path)
  local right_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value("swapfile", false, { buf = right_buf })
  vim.api.nvim_buf_set_name(right_buf, right_path)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { "right original" })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = right_buf })

  local session = assert((Session.start({
    left = source_mod.from_lines({ "left original" }, nil, "left"),
    right = source_mod.from_lines({ "right original" }, right_path, "right", {
      editable = { target = "buffer", bufnr = right_buf, path = right_path },
    }),
  }, config, {})))
  assert_eq(session.right_buf, right_buf,
    "Editable right-side buffer source should reuse the original buffer")
  assert_eq(vim.api.nvim_get_option_value("buftype", { buf = session.right_buf }), "",
    "Editable right-side buffer should remain a normal buffer")
  assert_eq(vim.api.nvim_get_option_value("signcolumn", { scope = "local", win = session.right_win }), "auto",
    "Editable right-side window should allow diagnostic signs")
  vim.api.nvim_buf_set_lines(session.right_buf, 0, -1, false, { "right edited" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.right_buf })
  vim.wait(100, function()
    return session.right.text == "right edited\n"
  end, 5)
  assert_eq(session.right.text, "right edited\n",
    "Editing the reusable right buffer should refresh the diff source text")
  vim.api.nvim_set_current_win(session.right_win)
  local undo_callback = buffer_keymap_callback(session.right_buf, "n", config.actions.keys.undo)
  assert_eq(type(undo_callback), "function",
    "Editable right-side buffer should have a callable undo mapping")
  undo_callback()
  vim.wait(100, function()
    return session.right.text == "right original\n"
  end, 5)
  assert_eq(vim.api.nvim_buf_get_lines(session.right_buf, 0, -1, false)[1], "right original",
    "Undo in an editable right-side buffer should use native buffer undo")
  assert_eq(session.right.text, "right original\n",
    "Undo in an editable right-side buffer should refresh the diff source text")
  vim.api.nvim_win_set_cursor(session.right_win, { 1, #"right" })
  vim.api.nvim_buf_set_lines(session.right_buf, 0, -1, false, { "right original plus" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.right_buf })
  vim.wait(100, function()
    return session.right.text == "right original plus\n"
  end, 5)
  assert_eq(vim.api.nvim_win_get_cursor(session.right_win)[2], #"right",
    "Editable right-side refresh should preserve the cursor column")
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = right_buf })
  session:close()
  pcall(vim.api.nvim_buf_delete, right_buf, { force = true })
end

do
  local right_path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "right original" }, right_path)
  local session = assert((Session.start({
    left = source_mod.from_lines({ "left original" }, nil, "left"),
    right = source_mod.from_lines({ "right original" }, right_path, "right", {
      editable = { target = "file", path = right_path },
    }),
  }, config, {})))
  vim.api.nvim_set_current_win(session.right_win)
  vim.api.nvim_buf_set_lines(session.right_buf, 0, -1, false, { "right saved" })
  vim.cmd("write")
  assert_eq(read_file(right_path)[1], "right saved",
    "Writing an editable right-side file buffer should update disk content")
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
  session:close()
end

do
  local right_path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "return { value = 1 }" }, right_path)
  local lsp_start_buf = nil
  local builtin_lsp_start_buf = nil
  local created_lsp_start = false
  local original_get_configs = vim.lsp.get_configs
  local original_is_enabled = vim.lsp.is_enabled
  local original_lsp_start = vim.lsp.start
  vim.lsp.get_configs = function()
    return {
      { name = "test_lua_ls", cmd = { "lua-language-server" }, filetypes = { "lua" }, root_markers = { ".git" } },
      { name = "test_pyright", cmd = { "pyright-langserver", "--stdio" }, filetypes = { "python" } },
    }
  end
  vim.lsp.is_enabled = function(name)
    return name == "test_lua_ls" or name == "test_pyright"
  end
  vim.lsp.start = function(_, opts)
    builtin_lsp_start_buf = opts and opts.bufnr or nil
    return 1000
  end
  if vim.fn.exists(":LspStart") == 0 then
    vim.api.nvim_create_user_command("LspStart", function()
      lsp_start_buf = vim.api.nvim_get_current_buf()
    end, {})
    created_lsp_start = true
  end
  local session = assert((Session.start({
    left = source_mod.from_lines({ "return { value = 0 }" }, nil, "left"),
    right = source_mod.from_lines({ "return { value = 1 }" }, right_path, "right", {
      editable = { target = "file", path = right_path },
    }),
  }, config, {})))
  assert_eq(vim.api.nvim_get_option_value("buflisted", { buf = session.right_buf }), true,
    "DiffBandit-created editable right buffers should stay listed for editor integrations")
  assert_eq(vim.api.nvim_get_option_value("filetype", { buf = session.right_buf }), "lua",
    "DiffBandit-created editable right buffers should keep the detected filetype")
  assert_eq(builtin_lsp_start_buf, session.right_buf,
    "DiffBandit-created editable right buffers should start matching built-in LSP configs")
  if created_lsp_start then
    assert_eq(lsp_start_buf, session.right_buf,
      "DiffBandit-created editable right buffers should request LSP startup on the editable buffer")
  end
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
  session:close()
  if created_lsp_start then
    pcall(vim.api.nvim_del_user_command, "LspStart")
  end
  vim.lsp.get_configs = original_get_configs
  vim.lsp.is_enabled = original_is_enabled
  vim.lsp.start = original_lsp_start
end

do
  local lsp_start_count = 0
  local command_start_count = 0
  local created_lsp_start = false
  local original_lsp_start = vim.lsp.start
  vim.lsp.start = function(...)
    lsp_start_count = lsp_start_count + 1
    if original_lsp_start then
      return original_lsp_start(...)
    end
    return nil
  end
  if vim.fn.exists(":LspStart") == 0 then
    vim.api.nvim_create_user_command("LspStart", function()
      command_start_count = command_start_count + 1
    end, {})
    created_lsp_start = true
  end

  local session = assert((Session.start({
    left = source_mod.from_lines({ "return { value = 0 }" }, "syntax-left.lua", "left"),
    right = source_mod.from_lines({ "return { value = 1 }" }, "syntax-right.lua", "right"),
  }, config, {})))
  assert_eq(vim.api.nvim_get_option_value("filetype", { buf = session.left_buf }), "lua",
    "Read-only diff left buffer should keep Lua filetype for syntax")
  assert_eq(vim.api.nvim_get_option_value("filetype", { buf = session.right_buf }), "lua",
    "Read-only diff right buffer should keep Lua filetype for syntax")
  assert_eq(vim.api.nvim_get_option_value("modifiable", { buf = session.left_buf }), false,
    "Read-only diff left buffer should remain non-modifiable")
  assert_eq(vim.api.nvim_get_option_value("modifiable", { buf = session.right_buf }), false,
    "Read-only diff right buffer should remain non-modifiable")
  assert_eq(vim.api.nvim_get_option_value("signcolumn", { scope = "local", win = session.left_win }), "no",
    "Read-only diff left window should keep diagnostic signs hidden")
  assert_eq(vim.api.nvim_get_option_value("signcolumn", { scope = "local", win = session.right_win }), "no",
    "Read-only diff right window should keep diagnostic signs hidden")
  assert_eq(lsp_start_count, 0,
    "Read-only diff source buffers should not start built-in LSP clients")
  assert_eq(command_start_count, 0,
    "Read-only diff source buffers should not invoke :LspStart")
  session:close()

  if created_lsp_start then
    pcall(vim.api.nvim_del_user_command, "LspStart")
  end
  vim.lsp.start = original_lsp_start
end

do
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local path = repo .. "/merge-real.txt"
  vim.fn.writefile({ "conflict markers" }, path)
  local worktree_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value("swapfile", false, { buf = worktree_buf })
  vim.api.nvim_buf_set_name(worktree_buf, path)
  vim.api.nvim_buf_set_lines(worktree_buf, 0, -1, false, { "conflict markers" })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = worktree_buf })

  local session = assert((merge_mod.start({
    root = repo,
    path = "merge-real.txt",
    base_lines = { "base result" },
    local_lines = { "local result" },
    remote_lines = { "remote result" },
    result_lines = { "base result" },
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))
  assert_eq(session.result_buf, worktree_buf,
    "Merge result should reuse an existing worktree buffer")
  assert_eq(vim.api.nvim_buf_get_lines(worktree_buf, 0, -1, false)[1], "base result",
    "Opening a merge result should initialize the real buffer content")
  assert_eq(vim.api.nvim_get_option_value("modified", { buf = worktree_buf }), true,
    "Initializing the merge result should leave the real buffer modified")
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = worktree_buf })
  session:close()
  pcall(vim.api.nvim_buf_delete, worktree_buf, { force = true })
end

do
  local lsp_start_count = 0
  local command_start_count = 0
  local created_lsp_start = false
  local original_lsp_start = vim.lsp.start
  vim.lsp.start = function(...)
    lsp_start_count = lsp_start_count + 1
    if original_lsp_start then
      return original_lsp_start(...)
    end
    return nil
  end
  if vim.fn.exists(":LspStart") == 0 then
    vim.api.nvim_create_user_command("LspStart", function()
      command_start_count = command_start_count + 1
    end, {})
    created_lsp_start = true
  end

  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local session = assert((merge_mod.start({
    root = repo,
    path = "merge-syntax.lua",
    base_lines = { "return 0" },
    local_lines = { "return 1" },
    remote_lines = { "return 2" },
    result_lines = { "return 0" },
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))
  assert_eq(vim.api.nvim_get_option_value("filetype", { buf = session.local_buf }), "lua",
    "Read-only merge local buffer should keep Lua filetype for syntax")
  assert_eq(vim.api.nvim_get_option_value("filetype", { buf = session.remote_buf }), "lua",
    "Read-only merge remote buffer should keep Lua filetype for syntax")
  assert_eq(vim.api.nvim_get_option_value("modifiable", { buf = session.local_buf }), false,
    "Read-only merge local buffer should remain non-modifiable")
  assert_eq(vim.api.nvim_get_option_value("modifiable", { buf = session.remote_buf }), false,
    "Read-only merge remote buffer should remain non-modifiable")
  assert_eq(vim.api.nvim_get_option_value("signcolumn", { scope = "local", win = session.local_win }), "no",
    "Read-only merge local window should keep diagnostic signs hidden")
  assert_eq(vim.api.nvim_get_option_value("signcolumn", { scope = "local", win = session.remote_win }), "no",
    "Read-only merge remote window should keep diagnostic signs hidden")
  assert_eq(lsp_start_count, 0,
    "Read-only merge source buffers should not start built-in LSP clients")
  assert_eq(command_start_count, 0,
    "Read-only merge source buffers should not invoke :LspStart")
  session:close()

  if created_lsp_start then
    pcall(vim.api.nvim_del_user_command, "LspStart")
  end
  vim.lsp.start = original_lsp_start
end

do
  local original_showtabline = vim.o.showtabline
  for _, value in ipairs({ 0, 1, 2 }) do
    vim.o.showtabline = value
    local session = assert((Session.start({
      left = test_source("tabline-left.txt", { "one" }),
      right = test_source("tabline-right.txt", { "two" }),
    }, config, {})))
    assert_eq(vim.o.showtabline, value,
      "Starting a diff session should not mutate global showtabline=" .. tostring(value))
    session:close()
    assert_eq(vim.o.showtabline, value,
      "Closing a diff session should preserve global showtabline=" .. tostring(value))
  end
  vim.o.showtabline = original_showtabline
end

do
  local original_list = vim.o.list
  local original_listchars = vim.o.listchars
  vim.o.list = true
  vim.o.listchars = "trail:·"

  local function win_list(win)
    return vim.api.nvim_get_option_value("list", { scope = "local", win = win })
  end

  local session = assert((Session.start({
    left = test_source("list-left.txt", { "one  " }),
    right = test_source("list-right.txt", { "two  " }),
  }, config, {
    panel = true,
    queue = { entries = {} },
  })))
  assert_eq(win_list(session.left_win), true,
    "Diff source panes should retain user list rendering")
  assert_eq(win_list(session.right_win), true,
    "Diff target panes should retain user list rendering")
  for _, win in ipairs({
    session.left_overview_win,
    session.left_num_win,
    session.connector_win,
    session.right_num_win,
    session.right_overview_win,
    session.left_header_win,
    session.center_header_win,
    session.right_header_win,
    session.panel and session.panel.nav_win,
    session.panel and session.panel.commit_win,
  }) do
    if win then
      assert_eq(win_list(win), false,
        "Diff visual chrome panes should suppress listchars")
    end
  end
  session:close()

  local merge_session = assert((merge_mod.start({
    root = root,
    path = "merge-list.txt",
    base_lines = { "base  " },
    local_lines = { "local  " },
    remote_lines = { "remote  " },
    result_lines = { "base  " },
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {
    panel = true,
    queue = { entries = {} },
  })))
  assert_eq(win_list(merge_session.local_win), true,
    "Merge local pane should retain user list rendering")
  assert_eq(win_list(merge_session.result_win), true,
    "Merge result pane should retain user list rendering")
  assert_eq(win_list(merge_session.remote_win), true,
    "Merge remote pane should retain user list rendering")
  for _, win in ipairs({
    merge_session.local_num_win,
    merge_session.local_result_connector_win,
    merge_session.result_left_num_win,
    merge_session.result_right_num_win,
    merge_session.result_remote_connector_win,
    merge_session.remote_num_win,
    merge_session.local_header_win,
    merge_session.result_header_win,
    merge_session.remote_header_win,
    merge_session.panel and merge_session.panel.nav_win,
    merge_session.panel and merge_session.panel.commit_win,
  }) do
    if win then
      assert_eq(win_list(win), false,
        "Merge visual chrome panes should suppress listchars")
    end
  end
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()

  vim.o.list = original_list
  vim.o.listchars = original_listchars
end

local function get_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local function luminance(color)
  if not color then
    return 0
  end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  return ((0.2126 * r) + (0.7152 * g) + (0.0722 * b)) / 255
end

-- Scenario 1: initial state
do
  local left = {"test"}
  local right = {"tast more"}
  local left_text = table.concat(left, "\n") .. "\n"
  local right_text = table.concat(right, "\n") .. "\n"

  local hunks, err = diff.compute_hunks(left_text, right_text, config.diff)
  assert_eq(err, nil, "diff error (scenario 1)")
  local v = view.build(left, right, hunks, config)

  local meta_first
  for _, m in ipairs(v.line_meta) do
    if (m.left_line == 1 or m.right_line == 1) and m.kind ~= "context" then
      meta_first = m
      break
    end
  end
  assert_eq(meta_first and meta_first.kind or nil, "change", "expected 'change' on first line before insertion")
end

-- Scenario 2: right adds a new line; first line should be change with green suffix; new line fully green (add)
do
  local left = {"test"}
  local right = {"test more", "with some additions"}
  local left_text = table.concat(left, "\n") .. "\n"
  local right_text = table.concat(right, "\n") .. "\n"

  local hunks, err = diff.compute_hunks(left_text, right_text, config.diff)
  assert_eq(err, nil, "diff error (scenario 2)")
  local v = view.build(left, right, hunks, config)

  local meta_r1, meta_r2
  for _, m in ipairs(v.line_meta) do
    if m.right_line == 1 then meta_r1 = m end
    if m.right_line == 2 then meta_r2 = m end
  end
  assert_eq(meta_r1 and meta_r1.kind or nil, "change", "first line should be 'change' after insertion")
  assert_eq(meta_r2 and meta_r2.kind or nil, "add", "second line should be 'add' (pure addition)")

  local spans = diff.changed_spans(left[1], right[1])
  assert_eq(#(spans.right_changes), 0, "no blue change spans expected on first line when only suffix added")
end

do
  local spans = diff.changed_spans("local add/add version", "incoming add/add version")
  assert_eq(spans.add_start, nil, "Longer replacement word should not split into an added suffix")
  assert_eq(#spans.right_changes, 1, "Longer replacement word should keep a right-side change span")
  assert_eq(spans.right_changes[1][1], 1, "Longer replacement word change span should start at first column")
  assert_eq(spans.right_changes[1][2], 8, "Longer replacement word change span should cover the full incoming word")
end

-- Overview gutters should be side-native and viewport-proportional.
do
  local fake_view = {
    line_meta = {
      { kind = "add", right_index = 4, filler_right = false, chunk = 1 },
      { kind = "delete", left_index = 2, filler_left = false, chunk = 2 },
      { kind = "change", left_index = 3, right_index = 3, filler_left = false, filler_right = false, chunk = 3 },
      { kind = "add", left_index = 5, filler_left = true, chunk = 4 },
      { kind = "delete", right_index = 6, filler_right = true, chunk = 5 },
    },
  }

  local left_marks = overview_mod.build_marks(fake_view, "left", 3)
  assert_eq(#left_marks, 2, "Left overview should include only delete/change real left rows")
  assert_eq(left_marks[1].kind, "delete", "Left overview should keep delete rows")
  assert_eq(left_marks[2].kind, "change", "Left overview should keep change rows")
  assert_eq(left_marks[2].current, true, "Overview marks should track the current chunk")

  local right_marks = overview_mod.build_marks(fake_view, "right", 3)
  assert_eq(#right_marks, 2, "Right overview should include only add/change real right rows")
  assert_eq(right_marks[1].kind, "add", "Right overview should keep add rows")
  assert_eq(right_marks[2].kind, "change", "Right overview should keep change rows")

  local rows = overview_mod.project_marks({
    { line = 1, kind = "add", current = false },
    { line = 50, kind = "delete", current = true },
    { line = 50, kind = "change", current = false },
    { line = 100, kind = "change", current = false },
  }, 100, 10)
  assert_eq(rows[1].kind, "add", "First source line should project to the first overview row")
  assert_eq(rows[5].kind, "delete", "Current chunk should win same-row overview collisions")
  assert_eq(rows[10].kind, "change", "Last source line should project to the last overview row")
end

-- Viewport rerenders should be coalesced so rapid mouse-wheel scroll events do
-- not trigger a full render per event.
do
  local fake_session = setmetatable({
    config = {
      ui = {
        scroll_debounce_ms = 1,
      },
    },
    rerender_count = 0,
  }, { __index = Session })

  function fake_session:rerender_for_viewport()
    self.rerender_count = self.rerender_count + 1
  end

  fake_session:request_viewport_rerender()
  fake_session:request_viewport_rerender()
  fake_session:request_viewport_rerender()

  local ok = vim.wait(100, function()
    return fake_session.rerender_count == 1
  end, 1)
  assert_eq(ok, true, "Scroll rerender should run after debounce")
  assert_eq(fake_session.rerender_count, 1, "Scroll rerender requests should coalesce")
end

-- Replacing sources must invalidate cached display lines. Commit-panel preview
-- navigation reuses a session while swapping files, so stale cache here would
-- show the previous file content under the next file's headers.
do
  local function source(lines)
    return {
      lines = lines,
      text = to_text(lines),
      filetype = "text",
    }
  end

  local initial = {
    left = source({ "old left" }),
    right = source({ "old right" }),
  }
  local next_sources = {
    left = source({ "new left" }),
    right = source({ "new right" }),
  }
  local initial_hunks = assert((diff.compute_hunks(initial.left.text, initial.right.text, config.diff)))
  local initial_view = view.build(initial.left.lines, initial.right.lines, initial_hunks, config)
  local fake_session = setmetatable({
    config = config,
    left = initial.left,
    right = initial.right,
    hunks = initial_hunks,
    view = initial_view,
    left_buf = vim.api.nvim_create_buf(false, true),
    right_buf = vim.api.nvim_create_buf(false, true),
  }, { __index = Session })

  local old_left_lines = select(1, fake_session:display_lines())
  assert_eq(old_left_lines[1], "old left", "Initial display cache should contain old file content")

  function fake_session:reset_pending_file_boundary() end
  function fake_session:update_title() end
  function fake_session:resize_layout() end
  function fake_session:precompute_connector_core_width() end
  function fake_session:setup_keymaps() end
  function fake_session:set_viewport_toplines_preserve_cursors() end
  function fake_session:clear_active_chunk() end
  function fake_session:render_status_headers() end
  function fake_session:render()
    local left_lines, right_lines = self:display_lines()
    assert_eq(left_lines[1], "new left", "Source replacement should rebuild cached left display lines")
    assert_eq(right_lines[1], "new right", "Source replacement should rebuild cached right display lines")
  end

  local ok, err = fake_session:replace_sources(next_sources, { chunk_position = "top" })
  assert_eq(err, nil, "Source replacement should not error")
  assert_eq(ok, true, "Source replacement should succeed")

  pcall(vim.api.nvim_buf_delete, fake_session.left_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, fake_session.right_buf, { force = true })
end

-- ==============================================================================
-- PATH MODULE UNIT TESTS
-- ==============================================================================

-- Test Suite 3: Lane assignment for extreme overlapping additions
-- Verifies that later overlapping paths get outer lanes (higher lane = further left)
do
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (extreme additions)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  -- Build lookup by origin_left_line
  local by_origin = {}
  for _, p in ipairs(paths) do
    if p.origin_left_line then
      by_origin[p.origin_left_line] = p
    end
  end

  -- Bravo (origin 2): lane 1 (first path, no active lanes)
  assert_eq(by_origin[2] ~= nil, true, "Bravo path should exist")
  assert_eq(by_origin[2].lane, 1, "Bravo should be lane 1")

  -- Charlie (origin 3): lane 1 (Bravo freed at row 2)
  assert_eq(by_origin[3] ~= nil, true, "Charlie path should exist")
  assert_eq(by_origin[3].lane, 1, "Charlie should be lane 1 (Bravo freed)")

  -- Delta (origin 4): lane 2 (Charlie still active)
  assert_eq(by_origin[4] ~= nil, true, "Delta path should exist")
  assert_eq(by_origin[4].lane, 2, "Delta should be lane 2 (nested in Charlie)")

  -- Foxtrot (origin 6): lane 3 (Delta still active at row 6)
  assert_eq(by_origin[6] ~= nil, true, "Foxtrot path should exist")
  assert_eq(by_origin[6].lane, 3, "Foxtrot should be lane 3 (Delta active)")

  -- Golf (origin 7): lane 4 (Foxtrot + Delta active)
  assert_eq(by_origin[7] ~= nil, true, "Golf path should exist")
  assert_eq(by_origin[7].lane, 4, "Golf should be lane 4 (nested in Foxtrot)")

  -- Hotel (origin 8): lane 5 (deepest nesting)
  assert_eq(by_origin[8] ~= nil, true, "Hotel path should exist")
  assert_eq(by_origin[8].lane, 5, "Hotel should be lane 5 (deepest)")
end

-- Test Suite 4: Vertical bar row ranges
-- Verifies bars span from origin_row+1 to triangle_row-1
do
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (bar ranges)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)

  for _, p in ipairs(paths) do
    if p.origin_left_line and (p.kind == "add" or p.kind == "delete") then
      local origin = p.origin_left_line
      local triangle = p.start_row
      local has_bar = (triangle - origin) > 1

      if has_bar then
        -- Bar should exist from origin+1 to triangle-1
        for row = origin + 1, triangle - 1 do
          assert_eq(active_bars[row] ~= nil, true,
            "Bars should exist at row " .. row .. " for origin " .. origin)
          assert_eq(active_bars[row][p.lane] ~= nil, true,
            "Bar at row " .. row .. " should be in lane " .. p.lane)
        end

        -- Bar should NOT exist on origin row
        local no_bar_on_origin = (active_bars[origin] == nil or active_bars[origin][p.lane] == nil)
        assert_eq(no_bar_on_origin, true, "No bar should be on origin row " .. origin)
      end
    end
  end
end

-- Test Suite 4b: Projected routes can run upward after independent scrolling
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 1,
      triangle_display_row = 1,
      lane = 1,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[2] ~= nil, true,
    "Projected upward add route should keep a rail between target and lower origin")
  assert_eq(active_bars[2][1] ~= nil, true,
    "Projected upward add route should use the assigned lane for the rail")
  assert_eq(active_bars[1] == nil or active_bars[1][1] == nil, true,
    "Projected upward add route should not draw a rail on the transition row")
  assert_eq(active_bars[3] == nil or active_bars[3][1] == nil, true,
    "Projected upward add route should not draw a rail on the origin row")
  assert_eq(underlines.origin_has_bar[3], true,
    "Projected upward add origin should connect to a vertical rail")
  assert_eq(underlines.tail_underlines[2] ~= nil, true,
    "Projected upward add route should place the tail underline below the transition")
  assert_eq(underlines.tail_underlines[2].kind, "add",
    "Projected upward tail underline should keep add styling")
end

-- Test Suite 4c: Projected route lanes are assigned from viewport geometry
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "add",
      origin_display_row = 7,
      top = 7,
      display_start_row = 3,
      triangle_display_row = 3,
      route_group = lower_group,
      connect_tail_on_triangle_row = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end
  local active_bars = paths_mod.compute_active_bars(projected_paths)

  assert_eq(by_group[upper_group].lane, 2,
    "Hidden projected continuation should step outward around a visible route")
  assert_eq(by_group[lower_group].lane, 1,
    "Visible projected route should keep the inner add lane")
  assert_eq(active_bars[3] ~= nil and active_bars[3][2] ~= nil, true,
    "Hidden upward continuation should include the origin row to avoid a broken corner")
  assert_eq(active_bars[3] == nil or active_bars[3][1] == nil, true,
    "Visible lower route should not draw its inner rail on the triangle row")
  assert_eq(active_bars[7] ~= nil and active_bars[7][1] ~= nil, true,
    "Visible lower route should terminate on its origin row")
end

-- Test Suite 4d: Split triangles for one projected addition share a lane
do
  local group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 2,
      triangle_display_row = 2,
      route_group = group,
    },
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 4,
      triangle_display_row = 4,
      route_group = group,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  assert_eq(projected_paths[1].lane, projected_paths[2].lane,
    "Split triangles from the same added block should stay on one lane")
end

-- Test Suite 4e: Hidden continuations only step outward on real overlap
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "add",
      origin_display_row = 7,
      top = 7,
      display_start_row = 5,
      triangle_display_row = 5,
      route_group = lower_group,
      connect_tail_on_triangle_row = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end

  assert_eq(by_group[upper_group].lane, 1,
    "Hidden continuation should stay inner when the visible route starts after a full-row gap")
  assert_eq(by_group[lower_group].lane, 1,
    "Visible route should reuse the inner lane when there is no adjacent collision")
end

-- Test Suite 4f: Adjacent upward projected additions still draw a tail
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 2,
      triangle_display_row = 2,
      lane = 1,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[2] == nil or active_bars[2][1] == nil, true,
    "Adjacent upward add route should not draw a rail on the triangle row")
  assert_eq(active_bars[3] ~= nil and active_bars[3][1] ~= nil, true,
    "Adjacent upward add route should terminate on the origin row")
  assert_eq(underlines.origin_has_bar[3], true,
    "Adjacent upward add origin should connect to the triangle-row rail")
  assert_eq(underlines.tail_underlines[2] ~= nil, true,
    "Adjacent upward add route should underline from the rail to the triangle")
end

-- Test Suite 4g: Lower hidden upward continuations keep the inner lane
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = -10,
      triangle_display_row = -10,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "add",
      origin_display_row = 7,
      top = 7,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = lower_group,
      hide_triangle = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end

  assert_eq(by_group[lower_group].lane, 1,
    "Lower clipped upward route should keep the inner add lane")
  assert_eq(by_group[upper_group].lane, 2,
    "Upper clipped upward route should step outward around the lower route")
end

-- Test Suite 4h: Same-row projected additions do not draw an extra tail
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 3,
      top = 3,
      display_start_row = 3,
      triangle_display_row = 3,
      lane = 1,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[3] == nil or active_bars[3][1] == nil, true,
    "Same-row add transition should not draw a vertical rail")
  assert_eq(underlines.origin_has_bar[3], false,
    "Same-row add transition should use the glyph column, not a routed bar")
  assert_eq(underlines.tail_underlines[2] == nil, true,
    "Same-row add transition should not underline the row above the glyph")
  assert_eq(underlines.tail_underlines[3] == nil, true,
    "Same-row add transition should not create a separate tail underline")
end

-- Test Suite 4i: Adjacent upward projected deletions mirror addition tail behavior
do
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 3,
      origin_right_line = 3,
      top = 3,
      display_start_row = 2,
      triangle_display_row = 2,
      lane = 1,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })

  assert_eq(active_bars[2] == nil or active_bars[2][1] == nil, true,
    "Adjacent upward delete route should not draw a rail on the triangle row")
  assert_eq(active_bars[3] ~= nil and active_bars[3][1] ~= nil, true,
    "Adjacent upward delete route should terminate on the origin row")
  assert_eq(underlines.origin_has_bar[3], true,
    "Adjacent upward delete origin should connect to the triangle-row rail")
  assert_eq(underlines.tail_underlines[2] ~= nil, true,
    "Adjacent upward delete route should underline from the triangle toward the rail")
  assert_eq(underlines.tail_underlines[2].kind, "delete",
    "Adjacent upward delete tail underline should keep delete styling")
  assert_eq(underlines.delete_origin_right_lines[3].underline_start_after, 1,
    "Adjacent upward delete origin underline should start after the rail column")
end

-- Test Suite 4j: Upward left-side overlaps give the lower route the rightmost lane
do
  local upper_group = {}
  local lower_group = {}
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 3,
      top = 3,
      display_start_row = 0,
      triangle_display_row = 0,
      route_group = upper_group,
      hide_triangle = true,
    },
    {
      kind = "delete",
      origin_display_row = 7,
      top = 7,
      display_start_row = 3,
      triangle_display_row = 3,
      route_group = lower_group,
      connect_tail_on_triangle_row = true,
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end
  local active_bars = paths_mod.compute_active_bars(projected_paths)

  assert_eq(by_group[upper_group].lane, 1,
    "Upper upward deletion continuation should keep the left-side inner lane")
  assert_eq(by_group[lower_group].lane, 2,
    "Lower upward deletion route should take the rightmost lane")
  assert_eq(active_bars[3] ~= nil and active_bars[3][1] ~= nil, true,
    "Upper upward deletion continuation should include the origin row to avoid a broken corner")
  assert_eq(active_bars[3] == nil or active_bars[3][2] == nil, true,
    "Lower upward deletion route should not draw its outer rail on the triangle row")
  assert_eq(active_bars[7] ~= nil and active_bars[7][2] ~= nil, true,
    "Lower upward deletion route should terminate on its origin row")
end

-- Test Suite 4k: Multiple route tails can share one display row
do
  local projected_paths = {
    {
      kind = "add",
      origin_display_row = 11,
      top = 11,
      display_start_row = 18,
      triangle_display_row = 18,
      lane = 2,
    },
    {
      kind = "delete",
      origin_display_row = 45,
      top = 45,
      display_start_row = 17,
      triangle_display_row = 17,
      lane = 3,
      connect_tail_on_triangle_row = true,
    },
  }
  local active_bars = paths_mod.compute_active_bars(projected_paths)
  local underlines = paths_mod.compute_underlines(projected_paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 24,
    rail_spacing = 1,
    sidecar_numbers = true,
  })
  local row_tails = underlines.tail_underlines[17] and underlines.tail_underlines[17].__items or {}
  local saw_add = false
  local saw_delete = false
  for _, tail in ipairs(row_tails) do
    saw_add = saw_add or tail.kind == "add"
    saw_delete = saw_delete or tail.kind == "delete"
  end

  assert_eq(#row_tails, 2, "Shared tail row should retain both route underlines")
  assert_eq(saw_add, true, "Shared tail row should retain the add route underline")
  assert_eq(saw_delete, true, "Shared tail row should retain the delete route underline")
end

-- Test Suite 4l: Change endpoints do not cross nearby deletion rails
do
  local change_group = {}
  local delete_group = {}
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 2,
      top = 2,
      display_start_row = 6,
      triangle_display_row = 6,
      route_group = delete_group,
    },
    {
      kind = "change",
      route_group = change_group,
      viewport_change_links = {
        {
          from_side = "right",
          from_row = 1,
          from_glyph = "◢",
          from_visible = true,
          to_side = "left",
          to_row = 3,
          to_glyph = "◤",
          to_visible = true,
        },
      },
    },
  }

  paths_mod.assign_lanes(projected_paths)

  local by_group = {}
  for _, p in ipairs(projected_paths) do
    by_group[p.route_group] = p
  end

  assert_eq(by_group[change_group].lane < by_group[delete_group].lane, true,
    "Visible change endpoint should not underline through the nearby deletion rail")
end

-- Test Suite 4m: Visible local routes stay planned before clipped continuations
do
  local long_delete = {}
  local long_change = {}
  local middle_delete = {}
  local middle_change = {}
  local lower_delete = {}
  local projected_paths = {
    {
      kind = "delete",
      origin_display_row = 40,
      triangle_display_row = 61,
      target_start_index = 61,
      route_group = long_delete,
      hide_triangle = true,
      suppress_tail = true,
    },
    {
      kind = "change",
      route_group = long_change,
      viewport_change_links = {
        {
          from_side = "right",
          from_row = 51,
          from_glyph = "◢",
          from_visible = true,
          to_side = "left",
          to_row = 61,
          to_glyph = "◤",
          to_visible = false,
          underline_row = 51,
        },
      },
    },
    {
      kind = "delete",
      origin_display_row = 8,
      triangle_display_row = 31,
      target_start_index = 31,
      route_group = middle_delete,
    },
    {
      kind = "change",
      route_group = middle_change,
      viewport_change_links = {
        {
          from_side = "right",
          from_row = 9,
          from_glyph = "◢",
          from_visible = true,
          to_side = "left",
          to_row = 39,
          to_glyph = "◤",
          to_visible = true,
        },
      },
    },
    {
      kind = "delete",
      origin_display_row = 9,
      triangle_display_row = 40,
      target_start_index = 40,
      route_group = lower_delete,
    },
  }

  local plan = paths_mod.plan_routes(projected_paths, {
    connector_core_width = 12,
    viewport_topline = 1,
    viewport_height = 60,
    max_route_backtrack_steps = 500,
  })
  assert_eq(plan.strategy, "greedy",
    "Visible adjacent route layout should not require backtracking during render")

  local function route_for(group)
    for _, route in ipairs(plan.routes or {}) do
      if route.group == group then
        return route
      end
    end
    return nil
  end

  for _, group in ipairs({ middle_delete, middle_change, lower_delete }) do
    local route = route_for(group)
    assert_eq(route ~= nil, true, "Visible adjacent route should be retained")
    assert_eq(route.overflow_hidden == true, false, "Visible adjacent route should not be hidden by a clipped route")
    assert_eq(#(route.segments or {}) > 0, true, "Visible adjacent route should keep connector geometry")
  end
end

-- Test Suite 4n: Offscreen-below change links anchor on the visible endpoint row
do
  local fake_session = setmetatable({ view = {}, left = { lines = {} }, right = { lines = {} } }, Session)
  local projected = fake_session:project_paths_for_toplines({
    {
      kind = "change",
      start_left_index = 117,
      end_left_index = 117,
      start_right_index = 51,
      end_right_index = 51,
      route_group = {},
    },
  }, 1, 1, 60, 60)

  local link = projected[1].viewport_change_links[1]
  assert_eq(link.from_row, 51, "Visible right change wedge should stay on right row 51")
  assert_eq(link.underline_row, 51, "Offscreen-below change connector should anchor at the wedge row")

  local plan = paths_mod.plan_routes(projected, {
    connector_core_width = 12,
    viewport_topline = 1,
    viewport_height = 60,
  })
  assert_eq(plan.routes[1].source_row, 51,
    "Offscreen-below change route should connect from the visible endpoint row")
end

-- Test Suite 5: No visual collisions between bars
-- Verifies different lanes have different column positions
do
  local glyph_base = 14  -- Example value
  local rail_spacing = 1

  -- Test lane_col returns different values for different lanes
  local col1 = paths_mod.lane_col(1, glyph_base, rail_spacing)
  local col2 = paths_mod.lane_col(2, glyph_base, rail_spacing)
  local col3 = paths_mod.lane_col(3, glyph_base, rail_spacing)

  assert_eq(col1 ~= col2, true, "Lane 1 and 2 should have different columns")
  assert_eq(col2 ~= col3, true, "Lane 2 and 3 should have different columns")
  assert_eq(col1 > col2, true, "Lane 1 should be further right (higher col) than lane 2")
  assert_eq(col2 > col3, true, "Lane 2 should be further right than lane 3")

  -- Test with actual paths - verify no collisions on any row
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, _ = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)

  for row, lanes_at_row in pairs(active_bars) do
    local cols_used = {}
    for lane, _ in pairs(lanes_at_row) do
      if type(lane) == "number" then
        local col = paths_mod.lane_col(lane, glyph_base, rail_spacing)
        assert_eq(cols_used[col] == nil, true,
          "Collision at row " .. row .. " col " .. col .. " (lane " .. lane .. ")")
        cols_used[col] = true
      end
    end
  end
end

-- Test Suite 6: Underline endpoint calculation
-- Verifies underlines are within valid bounds
do
  local left = read_file(root .. "/tests/files/left_extreme.txt")
  local right = read_file(root .. "/tests/files/right_extreme.txt")
  local hunks, _ = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)

  local layout = {
    left_number_width = 3,
    connector_core_width = 12,
    rail_spacing = 1,
  }

  local underlines = paths_mod.compute_underlines(paths, active_bars, layout)

  -- Verify bar columns are within connector bounds
  for origin_row, bar_col in pairs(underlines.origin_bar_cols) do
    assert_eq(bar_col >= layout.left_number_width, true,
      "Bar col at row " .. origin_row .. " should be >= left_number_width")
    assert_eq(bar_col < layout.left_number_width + layout.connector_core_width, true,
      "Bar col at row " .. origin_row .. " should be < connector end")
  end

  -- Verify tail underlines exist for paths with bars
  for tail_row, tail_info in pairs(underlines.tail_underlines) do
    assert_eq(tail_info.bar_col ~= nil, true, "Tail underline at row " .. tail_row .. " should have bar_col")
    assert_eq(tail_info.triangle_col ~= nil, true, "Tail underline at row " .. tail_row .. " should have triangle_col")
    assert_eq(tail_info.kind ~= nil, true, "Tail underline at row " .. tail_row .. " should have kind")
  end
end

-- Test Suite 7: Simple additions (pure_additions case)
do
  local left = read_file(root .. "/tests/files/left_additions.txt")
  local right = read_file(root .. "/tests/files/right_additions.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (simple additions)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  -- Count addition paths
  local add_paths = 0
  for _, p in ipairs(paths) do
    if p.kind == "add" then
      add_paths = add_paths + 1
    end
  end

  -- Should have multiple addition blocks
  assert_eq(add_paths >= 1, true, "Should have at least 1 addition path")

  -- Verify origin markers in line_meta
  local origin_count = 0
  for _, meta in ipairs(v.line_meta) do
    if meta.origin == "add" then
      origin_count = origin_count + 1
    end
  end
  assert_eq(origin_count >= 1, true, "Should have at least 1 origin row marked")

  local by_right_start = {}
  for _, p in ipairs(paths) do
    if p.kind == "add" then
      by_right_start[p.start_right_line] = p
    end
  end
  assert_eq(by_right_start[3].origin_display_row, 2,
    "First addition should originate from compact left row 2")
  assert_eq(by_right_start[7].origin_display_row, 4,
    "Second addition should originate from compact left row 4")
  assert_eq(by_right_start[11].origin_display_row, 5,
    "Third addition should originate from compact left row 5")
  assert_eq(by_right_start[11].display_start_row, 11,
    "Addition triangle should use compact right target row")

  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local projected = fake_session:project_paths_for_toplines(paths, 1, 1, 40, 40)
  local plan = paths_mod.plan_routes(projected, {
    connector_core_width = 12,
    viewport_topline = 1,
    viewport_height = 40,
  })
  assert_eq(plan.success, true, "Simple additions should produce a planned route")

  local routes_by_origin = {}
  for _, route in ipairs(plan.routes or {}) do
    if route.kind == "add" and route.path and route.path.origin_display_row then
      routes_by_origin[route.path.origin_display_row] = route
    end
  end

  local function count_segments(route, segment_type)
    local count = 0
    for _, segment in ipairs(route.segments or {}) do
      if segment.type == segment_type then
        count = count + 1
      end
    end
    return count
  end

  assert_eq(count_segments(routes_by_origin[2], "horizontal"), 1,
    "Adjacent top addition should be a single straight connector underline")
  assert_eq(count_segments(routes_by_origin[2], "vertical"), 0,
    "Adjacent top addition should not introduce a connector pipe")
  assert_eq(routes_by_origin[2].segments[1].row, 2,
    "Adjacent top addition should connect along the bottom edge of its origin row")
  assert_eq(routes_by_origin[2].segments[1].start_col, 0,
    "Adjacent top addition should start at the connector core left edge")
  assert_eq(routes_by_origin[2].segments[1].end_col, 11,
    "Adjacent top addition should reach the right transition edge")
  assert_eq(count_segments(routes_by_origin[5], "horizontal"), 2,
    "Lower addition should keep both source and target horizontal segments")
  assert_eq(count_segments(routes_by_origin[5], "vertical"), 1,
    "Lower addition should connect those horizontals with one vertical pipe")
  assert_eq(routes_by_origin[4].rail_col > routes_by_origin[5].rail_col, true,
    "Middle addition should step outward so the lower addition keeps its source bend")
end

-- Test Suite 8: Simple deletions (pure_deletions case)
do
  local left = read_file(root .. "/tests/files/left_deletions.txt")
  local right = read_file(root .. "/tests/files/right_deletions.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (simple deletions)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)
  local underlines = paths_mod.compute_underlines(paths, active_bars, {
    left_number_width = 3,
    connector_core_width = 12,
    rail_spacing = 1,
  })

  local by_start = {}
  for _, p in ipairs(paths) do
    if p.kind == "delete" then
      by_start[p.start_row] = p
    end
  end

  assert_eq(by_start[3] ~= nil, true, "First deletion path should start at left line 3")
  assert_eq(by_start[3].end_row, 5, "First deletion path should end at left line 5")
  assert_eq(by_start[3].origin_right_line, 2, "First deletion origin should be right line 2")

  assert_eq(by_start[8] ~= nil, true, "Second deletion path should start at left line 8")
  assert_eq(by_start[8].end_row, 9, "Second deletion path should end at left line 9")
  assert_eq(by_start[8].origin_right_line, 4, "Second deletion origin should be right line 4")

  for row = 5, 7 do
    assert_eq(active_bars[row] ~= nil, true, "Second deletion should have a bar at row " .. row)
    assert_eq(active_bars[row][by_start[8].lane] ~= nil, true,
      "Second deletion bar should use its assigned lane at row " .. row)
  end

  assert_eq(underlines.delete_origin_right_lines[2] ~= nil, true,
    "First delete origin should be tracked by right line")
  assert_eq(underlines.delete_origin_right_lines[4] ~= nil, true,
    "Second delete origin should be tracked by right line")
  assert_eq(underlines.tail_underlines[7] ~= nil, true,
    "Second deletion should have a tail underline before its triangle")
  assert_eq(underlines.tail_underlines[7].triangle_col, 3,
    "Pure delete tail should start at the compact left-side delete wedge")
  assert_eq(underlines.tail_underlines[7].bar_col > underlines.tail_underlines[7].triangle_col, true,
    "Delete tail should connect from the left-side wedge toward the route rail")
  local sidecar_underlines = paths_mod.compute_underlines(paths, active_bars, {
    left_number_width = 0,
    connector_core_width = 12,
    rail_spacing = 1,
    sidecar_numbers = true,
  })
  assert_eq(sidecar_underlines.tail_underlines[7].triangle_col, 0,
    "Sidecar delete tail should start at connector-pane column 0 adjacent to the left number pane")
  assert_eq(sidecar_underlines.tail_underlines[7].bar_col, 1,
    "Sidecar delete rail should leave one connector cell for the underscore before the pipe")
  assert_eq(sidecar_underlines.delete_origin_right_lines[4].underline_start_after, 1,
    "Sidecar delete origin underline should start after the rail column")
  assert_eq(by_start[8].origin_display_row, 4,
    "Second deletion should originate from compact right row 4")
  assert_eq(by_start[8].display_start_row, 8,
    "Second deletion triangle should use compact left target row 8")
end

-- Test Suite 9: Mixed changes + deletions + additions in one file
do
  local left = read_file(root .. "/tests/files/left_mixed.txt")
  local right = read_file(root .. "/tests/files/right_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (mixed)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local active_bars = paths_mod.compute_active_bars(paths)
  local underlines = paths_mod.compute_underlines(paths, active_bars, {
    left_number_width = 3,
    connector_core_width = 12,
    rail_spacing = 1,
  })

  local function find_meta(predicate)
    for idx, m in ipairs(v.line_meta) do
      if predicate(m) then
        return idx, m
      end
    end
    return nil, nil
  end

  -- Change block 1: left 3/4 vs right 3/4 should be change
  do
    local _, m3 = find_meta(function(m) return m.left_line == 3 and m.right_line == 3 end)
    local _, m4 = find_meta(function(m) return m.left_line == 4 and m.right_line == 4 end)
    assert_eq(m3 and m3.kind or nil, "change", "Expected line 3 to be a change")
    assert_eq(m4 and m4.kind or nil, "change", "Expected line 4 to be a change")
  end

  -- Deletion: left line 6 is deleted
  do
    local _, md = find_meta(function(m) return m.left_line == 6 end)
    assert_eq(md and md.kind or nil, "delete", "Expected left line 6 to be delete")
  end

  -- Additions: right lines 8/9 are added (Added line 1/2)
  local idx_a8, ma8 = find_meta(function(m) return m.right_line == 8 end)
  local idx_a9, ma9 = find_meta(function(m) return m.right_line == 9 end)
  assert_eq(ma8 and ma8.kind or nil, "add", "Expected right line 8 to be add")
  assert_eq(ma9 and ma9.kind or nil, "add", "Expected right line 9 to be add")

  -- Add rows produced inside change hunks must not carry change connector glyphs
  do
    local c8 = idx_a8 and v.connectors[idx_a8] or nil
    local c9 = idx_a9 and v.connectors[idx_a9] or nil
    assert_eq(c8 and c8:match("^%s*$") ~= nil or false, true, "Expected connector for added line 1 to be spaces")
    assert_eq(c9 and c9:match("^%s*$") ~= nil or false, true, "Expected connector for added line 2 to be spaces")
  end

  -- Mixed replacement row should remain a change with a separate added suffix.
  do
    local spans = diff.changed_spans("Original text here", "Modified text here with extra content")
    assert_eq(spans.add_start, 19, "Mixed replacement should split added suffix after replacement text")
    assert_eq(#spans.right_changes, 1, "Mixed replacement should keep a right-side change span")
    assert_eq(spans.right_changes[1][1], 1, "Mixed replacement change span should start at first column")
    assert_eq(spans.right_changes[1][2], 8, "Mixed replacement emphasis should cover only the changed word")
  end

  -- Paths should include both an add path (for Added line 1/2) and a delete path.
  -- The adjacent change (hunk 3) and add (hunk 4) are separate zero-context
  -- chunks: the add must keep its own routed path and stage marker rather
  -- than fusing into the neighboring chunk's change envelope.
  do
    local found_add = false
    local found_delete = false
    for _, p in ipairs(paths) do
      if p.kind == "add" and p.start_row == 8 and p.end_row == 9 then
        found_add = true
        assert_eq(p.origin_left_line, 8, "Expected add origin to be left line 8")
        assert_eq(p.embedded_in_change, false,
          "Adjacent add from its own chunk should route independently")
      end
      if p.kind == "delete" and p.start_row == 6 and p.end_row == 6 then
        found_delete = true
        assert_eq(p.origin_right_line, 5, "Expected delete origin to be right line 5")
      end
      if p.kind == "change" then
        assert_eq(p.mixed_add, nil,
          "No change path should absorb another chunk's add rows")
      end
    end
    assert_eq(found_add, true, "Expected to find an add path for right lines 8-9")
    assert_eq(found_delete, true, "Expected to find a delete path for left line 6")
    assert_eq(underlines.delete_origin_right_lines[5].glyph_col, 3,
      "Mixed delete wedge should stay compact after the left line number")
  end
end

-- Test Suite 10: Comprehensive routes include compact-row offset changes
do
  local left = read_file(root .. "/tests/files/left_comprehensive.txt")
  local right = read_file(root .. "/tests/files/right_comprehensive.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (comprehensive)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  local saw_offset_change = false
  local saw_add_with_different_meta_and_visual_rows = false
  local saw_delete_with_right_origin = false

  for _, p in ipairs(paths) do
    if p.kind == "change" and p.offset then
      saw_offset_change = true
      assert_eq(p.display_start_row ~= nil, true, "Offset change should have display_start_row")
      assert_eq(p.display_end_row ~= nil, true, "Offset change should have display_end_row")
    elseif p.kind == "add" and p.meta_start_row ~= p.display_start_row then
      saw_add_with_different_meta_and_visual_rows = true
      assert_eq(p.origin_side, "left", "Add route origin side")
      assert_eq(p.target_side, "right", "Add route target side")
    elseif p.kind == "delete" and p.origin_right_line then
      saw_delete_with_right_origin = true
      assert_eq(p.origin_side, "right", "Delete route origin side")
      assert_eq(p.target_side, "left", "Delete route target side")
    end
  end

  assert_eq(saw_offset_change, true, "Comprehensive case should include an offset change route")
  assert_eq(saw_add_with_different_meta_and_visual_rows, true,
    "Comprehensive case should prove routes use compact visual rows, not metadata rows")
  assert_eq(saw_delete_with_right_origin, true,
    "Comprehensive case should include a delete route with right-side origin")
end

-- Test Suite 11: Independent viewport projection uses each side's topline
do
  local left = read_file(root .. "/tests/files/left_mixed.txt")
  local right = read_file(root .. "/tests/files/right_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (viewport projection mixed)")

  local v = view.build(left, right, hunks, config)

  assert_eq(#v.line_meta, 12, "Mixed aligned connector model should have 12 visual rows")
  assert_eq(#v.left, 10, "Mixed left compact buffer should have 10 real rows")
  assert_eq(#v.right, 11, "Mixed right compact buffer should have 11 real rows")

  local left_by_index = {}
  local right_by_index = {}
  for _, meta in ipairs(v.line_meta) do
    if meta.left_index then
      left_by_index[meta.left_index] = meta
    end
    if meta.right_index then
      right_by_index[meta.right_index] = meta
    end
  end

  local left_topline = 3
  local right_topline = 7
  local screen_row = 2
  local left_meta = left_by_index[left_topline + screen_row - 1]
  local right_meta = right_by_index[right_topline + screen_row - 1]

  assert_eq(left_meta.left_line, 4, "Left number projection follows left topline")
  assert_eq(right_meta.right_line, 8, "Right number projection follows right topline")
  assert_eq(left_meta.left_line ~= right_meta.right_line, true,
    "Independent projection must not force matching line numbers on a screen row")
end

-- Test Suite 12: Scroll fixtures expose long add/delete/mixed regions
do
  local fixtures = {
    {
      name = "scroll additions",
      left = root .. "/tests/files/left_scroll_additions.txt",
      right = root .. "/tests/files/right_scroll_additions.txt",
      expected_kind = "add",
    },
    {
      name = "scroll deletions",
      left = root .. "/tests/files/left_scroll_deletions.txt",
      right = root .. "/tests/files/right_scroll_deletions.txt",
      expected_kind = "delete",
    },
    {
      name = "scroll mixed",
      left = root .. "/tests/files/left_scroll_mixed.txt",
      right = root .. "/tests/files/right_scroll_mixed.txt",
      expected_kind = "mixed",
    },
    {
      name = "scroll changes",
      left = root .. "/tests/files/left_scroll_changes.txt",
      right = root .. "/tests/files/right_scroll_changes.txt",
      expected_kind = "change",
    },
  }

  for _, fixture in ipairs(fixtures) do
    local left = read_file(fixture.left)
    local right = read_file(fixture.right)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, "diff error (" .. fixture.name .. ")")

    local v = view.build(left, right, hunks, config)
    local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
    local longest = 0
    local found = false
    for _, p in ipairs(paths) do
      if fixture.expected_kind == "mixed" then
        -- Adjacent change+add chunks: the add stays its own chunk's route,
        -- anchored on the neighboring change row, spanning the added block.
        if p.kind == "add" and p.origin_kind == "change" and not p.embedded_in_change then
          found = true
          longest = math.max(longest, (p.block_display_end or 0) - (p.block_display_start or 0) + 1)
        end
      elseif fixture.expected_kind == "change" then
        if p.kind == "change" then
          found = true
          longest = math.max(longest, (p.end_left_index or 0) - (p.start_left_index or 0) + 1)
        end
      elseif p.kind == fixture.expected_kind and not p.embedded_in_change then
        found = true
        longest = math.max(longest, (p.block_display_end or 0) - (p.block_display_start or 0) + 1)
      end
    end
    assert_eq(found, true, fixture.name .. " should produce the expected route type")
    if fixture.expected_kind == "change" then
      assert_eq(longest >= 3, true, fixture.name .. " should include multiple changed rows")
    else
      assert_eq(longest >= 6, true, fixture.name .. " should include a scrollable route")
    end
  end
end

-- Test Suite 12b: Dense mixed fixture forces stable multi-lane width
do
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense mixed)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)

  local counts = { add = 0, delete = 0, change = 0 }
  local saw_adjacent_add = false
  for _, p in ipairs(paths) do
    counts[p.kind] = (counts[p.kind] or 0) + 1
    if p.kind == "add" and p.origin_kind == "change" and not p.embedded_in_change then
      saw_adjacent_add = true
    end
  end
  assert_eq(counts.add >= 3, true, "Dense mixed fixture should include multiple add routes")
  assert_eq(counts.delete >= 2, true, "Dense mixed fixture should include multiple delete routes")
  assert_eq(counts.change >= 2, true, "Dense mixed fixture should include multiple change routes")
  assert_eq(saw_adjacent_add, true,
    "Dense mixed fixture should route the change-adjacent add as its own chunk")

  local projected = fake_session:project_paths_for_toplines(paths, 1, 49, 14, 14)
  local max_lane = paths_mod.max_lane(projected)
  assert_eq(max_lane, 7, "Dense mixed conflict viewport should reserve seven physical lanes")
  local required_width, required_plan = paths_mod.required_connector_core_width_for_paths(projected, 3, 24, {
    viewport_topline = 1,
    viewport_height = 14,
    max_route_backtrack_steps = 500,
  })
  assert_eq(required_width, 16,
    "Seven-lane dense conflict should use the smallest solvable compact connector width")
  assert_eq(required_plan.success, true, "Seven-lane dense conflict should remain collision-free")

  local active_bars = paths_mod.compute_active_bars(projected)
  local function row_has_bar(row, kind, lane, origin)
    local row_bars = active_bars[row]
    if not row_bars or not row_bars.__items then
      return false
    end
    for _, item in ipairs(row_bars.__items) do
      if item.lane == lane
          and item.path.kind == kind
          and item.path.origin_display_row == origin then
        return true
      end
    end
    return false
  end
  assert_eq(row_has_bar(1, "add", 2, 11), true,
    "Clipped add route from origin 11 should enter from the top edge")
  assert_eq(row_has_bar(9, "add", 2, 11), true,
    "Clipped add route from origin 11 should not be overwritten by same-lane delete/add routes")
  assert_eq(row_has_bar(9, "delete", 7, 5), true,
    "Dense conflict should keep the lower deletion route active alongside add routes")
end

-- Shared invariant checker for planned connector routes: cell exclusivity
-- (mirroring the planner's endpoint-sharing rule), in-bounds geometry, route
-- shape, visible routes carrying segments, and routes/hidden bookkeeping.
local function assert_plan_invariants(plan, layout, label, opts)
  opts = opts or {}
  if not opts.success_optional then
    local expect_success = opts.expect_success
    if expect_success == nil then
      expect_success = true
    end
    assert_eq(plan.success, expect_success, label .. " plan success flag")
  end

  local function endpoint_at(route, side, row)
    return (route.source_side == side and route.source_row == row and route.source_visible ~= false)
      or (route.target_side == side and route.target_row == row and route.target_visible ~= false)
  end

  -- Mirrors routes_can_share_cell: edge-docked endpoints always start at the
  -- pane edge, so two same-row endpoints can never be separated by widening;
  -- stacking them (with deterministic paint order) is the only solvable
  -- layout and is deliberately legal. A "both"-side horizontal is itself
  -- pinned to its row and may stack with any route ending on that row.
  local function endpoint_on_row(route, row)
    return endpoint_at(route, "left", row) or endpoint_at(route, "right", row)
  end
  local function may_share(route, owner, row, cell_type, side)
    if owner == route or owner.group == route.group then
      return true
    end
    if cell_type ~= "horizontal" or not side then
      return false
    end
    if side == "both" then
      return endpoint_on_row(route, row) and endpoint_on_row(owner, row)
    end
    return endpoint_at(route, side, row) and endpoint_at(owner, side, row)
  end

  local core_width = layout.connector_core_width
  local occupied = {}
  local function check_cell(row, col, route, cell_type, side)
    -- Rows outside the buffer are deliberately allowed: offscreen
    -- continuations emit a stub one row past the top edge, and projected
    -- origins keep their true (possibly negative) rows because every
    -- projected route anchors somewhere visible -- offscreen span overlap
    -- implies visible overlap, so the extra rows add no collision risk,
    -- while clamping them collapses dock ordering and degrades placement.
    -- Rendering clips anything outside the buffer.
    assert_eq(col >= 0 and col <= core_width - 1, true,
      label .. " cell col should stay within the connector core (col " .. tostring(col) .. ")")
    occupied[row] = occupied[row] or {}
    for check_col = col - 1, col + 1 do
      local owner = occupied[row][check_col]
      assert_eq(owner == nil or may_share(route, owner, row, cell_type, side), true,
        label .. " should not crowd connector cells at row " .. tostring(row) .. ", col " .. tostring(col))
    end
    occupied[row][col] = route
  end

  local hidden_set = {}
  for _, route in ipairs(plan.hidden_routes or {}) do
    hidden_set[route] = true
    assert_eq(route.overflow_hidden, true,
      label .. " hidden routes should be marked overflow_hidden")
    assert_eq(route.hide_reason ~= nil, true,
      label .. " hidden routes should record why they were hidden")
  end

  for _, route in ipairs(plan.routes or {}) do
    if not opts.allow_hidden_in_routes then
      assert_eq(hidden_set[route] == nil, true,
        label .. " plan.routes and plan.hidden_routes should be disjoint")
    end
    local horizontal_count = 0
    local vertical_count = 0
    local cell_count = 0
    for _, segment in ipairs(route.segments or {}) do
      if segment.type == "horizontal" then
        if not segment.continuation then
          horizontal_count = horizontal_count + 1
        end
        for col = segment.start_col, segment.end_col do
          check_cell(segment.row, col, route, "horizontal", segment.side)
          cell_count = cell_count + 1
        end
      elseif segment.type == "vertical" then
        vertical_count = vertical_count + 1
        for row = segment.start_row, segment.end_row do
          check_cell(row, segment.col, route, "vertical", nil)
          cell_count = cell_count + 1
        end
      end
    end
    assert_eq(horizontal_count <= 2, true, label .. " route should have at most two horizontal segments")
    assert_eq(vertical_count <= 1, true, label .. " route should have at most one vertical segment")
    if not hidden_set[route] and not opts.allow_empty_visible_routes then
      assert_eq(cell_count >= 1, true,
        label .. " visible routes should draw at least one connector cell")
    end
  end
end

-- Test Suite 12c: Planned connector routes are two-turn, collision-free shapes
do
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense mixed planner)")

  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local projections = {
    { 1, 1, 4, "dense initial" },
    { 1, 38, 12, "dense pre-conflict" },
    { 1, 46, 16, "dense four-route conflict" },
    { 1, 49, 16, "dense lower-route entering" },
    { 1, 53, 16, "dense post-conflict" },
    { 8, 46, 7, "dense lane reuse" },
  }

  for _, projection in ipairs(projections) do
    local projected = fake_session:project_paths_for_toplines(paths, projection[1], projection[2], 14, 14)
    local width, plan = paths_mod.required_connector_core_width_for_paths(projected, 3, 24, {
      viewport_topline = projection[1],
      viewport_height = 14,
      max_route_backtrack_steps = 500,
    })
    assert_eq(width, projection[3], projection[4] .. " should use its compact planned connector width")
    assert_plan_invariants(plan, { connector_core_width = width }, projection[4])
  end

  local function route_segment_counts(plan)
    local counts = { horizontal = 0, vertical = 0 }
    for _, route in ipairs(plan.routes or {}) do
      for _, segment in ipairs(route.segments or {}) do
        counts[segment.type] = (counts[segment.type] or 0) + 1
      end
    end
    return counts
  end

  local one_vertical = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 1,
      triangle_display_row = 4,
      route_group = {},
    },
  }
  local one_width, one_plan = paths_mod.required_connector_core_width_for_paths(one_vertical, 3, 24)
  local one_counts = route_segment_counts(one_plan)
  assert_eq(one_width, 3, "Single vertical route should keep the compact three-column minimum")
  assert_eq(one_counts.horizontal, 2, "Single vertical route should retain both endpoint horizontals")
  assert_eq(one_counts.vertical, 1, "Single vertical route should retain one interior rail")

  local two_vertical = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 1,
      triangle_display_row = 4,
      route_group = {},
    },
    {
      kind = "delete",
      origin_side = "right",
      target_side = "left",
      origin_display_row = 4,
      triangle_display_row = 1,
      route_group = {},
    },
  }
  local two_width, two_plan = paths_mod.required_connector_core_width_for_paths(two_vertical, 3, 24)
  assert_eq(two_width, 5, "Competing vertical routes should widen only enough to avoid collisions")
  assert_plan_invariants(two_plan, { connector_core_width = two_width }, "two compact vertical routes")

  local upward = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 5,
      triangle_display_row = 1,
      route_group = {},
    },
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 6,
      triangle_display_row = 2,
      route_group = {},
    },
  }
  local upward_plan = paths_mod.plan_routes(upward, { connector_core_width = 12 })
  assert_plan_invariants(upward_plan, { connector_core_width = 12 }, "upward priority")
  assert_eq(upward[1].planned_rail_col < upward[2].planned_rail_col, true,
    "Top-edge upward route should take the leftmost rail")

  local downward = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 1,
      triangle_display_row = 5,
      route_group = {},
    },
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 2,
      triangle_display_row = 6,
      route_group = {},
    },
  }
  local downward_plan = paths_mod.plan_routes(downward, { connector_core_width = 12 })
  assert_plan_invariants(downward_plan, { connector_core_width = 12 }, "downward priority")
  assert_eq(downward[2].planned_rail_col < downward[1].planned_rail_col, true,
    "Bottom-edge downward route should take the leftmost rail")

  local overflow = {}
  local overflow_group = {}
  for i = 1, 10 do
    overflow[i] = {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 12,
      triangle_display_row = 1 - i,
      route_group = overflow_group,
    }
  end
  local overflow_plan = paths_mod.plan_routes(overflow, {
    connector_core_width = 24,
    viewport_topline = 1,
    viewport_height = 14,
  })
  assert_plan_invariants(overflow_plan, { connector_core_width = 24 }, "overflow cap")
  assert_eq(#overflow_plan.routes, paths_mod.MAX_VISIBLE_CONNECTOR_ROUTES,
    "Overflow planner should keep at most eight vertical routes")
  assert_eq(#overflow_plan.hidden_routes, 2,
    "Overflow planner should hide routes beyond the eight-route cap")
  assert_eq(overflow[10].overflow_hidden, true,
    "Overflow planner should hide the farthest top-docked route first")
  assert_eq(overflow[9].overflow_hidden, true,
    "Overflow planner should hide the second farthest top-docked route")
  assert_eq(overflow[1].overflow_hidden == true, false,
    "Overflow planner should keep the nearest visible route")

  assert_eq(paths_mod.required_connector_core_width(99, 3), 24,
    "Connector width should cap at the eight-route width")
end

-- Test Suite 13: Chunk navigation anchors align semantic origins and targets
do
  local function anchors_for(left, right)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, "diff error (navigation anchors)")
    local v = view.build(left, right, hunks, config)
    local session = { view = v }
    return Session.chunk_navigation_anchors(session, v.chunks[1])
  end

  local left_anchor, right_anchor = anchors_for(
    { "alpha", "bravo", "charlie" },
    { "alpha", "bravo", "added", "charlie" }
  )
  assert_eq(left_anchor, 2, "Add navigation should anchor left on the origin row")
  assert_eq(right_anchor, 2, "Add navigation should anchor right on the row above the insertion")

  left_anchor, right_anchor = anchors_for(
    { "alpha", "bravo", "deleted", "charlie" },
    { "alpha", "bravo", "charlie" }
  )
  assert_eq(left_anchor, 3, "Delete navigation should anchor left on the first deleted row")
  assert_eq(right_anchor, 2, "Delete navigation should anchor right on the origin row")

  left_anchor, right_anchor = anchors_for(
    { "alpha", "old", "charlie" },
    { "alpha", "new", "charlie" }
  )
  assert_eq(left_anchor, 2, "Change navigation should anchor left on the first changed row")
  assert_eq(right_anchor, 2, "Change navigation should anchor right on the first changed row")

  left_anchor, right_anchor = anchors_for(
    { "alpha", "old one", "old two", "charlie" },
    { "alpha", "new one", "new two", "added", "charlie" }
  )
  assert_eq(left_anchor, 2, "Mixed navigation should anchor left on the first changed row")
  assert_eq(right_anchor, 2, "Mixed navigation should anchor right on the first changed row")
end

-- Test Suite 14: Theme-derived highlights preserve existing color semantics
do
  local function set_palette(groups)
    for name, opts in pairs(groups) do
      vim.api.nvim_set_hl(0, name, opts)
    end
  end

  set_palette({
    Normal = { fg = 0xE0E2EA, bg = 0x14161B },
    LineNr = { fg = 0x4F5258 },
    Comment = { fg = 0x9B9EA4 },
    DiffAdd = { fg = 0xEEF1F8, bg = 0x005523 },
    DiffDelete = { fg = 0xFFC0B9 },
    DiffChange = { fg = 0xEEF1F8, bg = 0x4F5258 },
    DiffText = { fg = 0xEEF1F8, bg = 0x007373 },
  })
  highlights.apply(config_mod.defaults())

  assert_eq(get_hl("DiffBanditAdd").bg, 0x005523,
    "Default-like palette should keep usable DiffAdd background")
  assert_eq(get_hl("DiffBanditChangeLeft").bg, 0x4F5258,
    "Default-like palette should keep usable DiffChange background")
  assert_ne(get_hl("DiffBanditDelete").bg, 0xD3D3D3,
    "Default-like palette should not fall back to light delete gray")
  assert_eq(luminance(get_hl("DiffBanditDelete").bg) < 0.5, true,
    "Default-like palette should synthesize a dark delete background")
  assert_ne(get_hl("DiffBanditChangeEmphasis").bg, get_hl("DiffBanditChangeLeft").bg,
    "Change emphasis should remain distinct from the base change background")
  assert_ne(get_hl("DiffBanditChangeEmphasis").bg, 0x007373,
    "Change emphasis should be adaptive instead of using DiffText directly")
  assert_eq(get_hl("DiffBanditContext").fg, nil,
    "Context backgrounds should not set a foreground that masks syntax highlighting")

  set_palette({
    Normal = { fg = 0x101010, bg = 0xFFFFFF },
    LineNr = { fg = 0x808080 },
    Comment = { fg = 0x707070 },
    DiffAdd = { fg = 0x006B2B },
    DiffDelete = { fg = 0xB00020 },
    DiffChange = { bg = 0xDDEBFF },
  })
  highlights.apply(config_mod.defaults())
  assert_eq(get_hl("DiffBanditAdd").bg ~= nil, true,
    "Light palette should synthesize add background from foreground when needed")
  assert_eq(get_hl("DiffBanditDelete").bg ~= nil, true,
    "Light palette should synthesize delete background from foreground when needed")
  assert_eq(luminance(get_hl("DiffBanditChangeEmphasis").bg) < luminance(get_hl("DiffBanditChangeLeft").bg), true,
    "Light palette change emphasis should darken the change background")

  set_palette({
    Normal = { fg = 0xEEEEEE, bg = 0x101010 },
    LineNr = { fg = 0x777777 },
    Comment = { fg = 0x909090 },
    DiffAdd = { bg = 0x123D2B },
    DiffDelete = { bg = 0x4A2426 },
    DiffChange = { bg = 0x253344 },
  })
  highlights.apply(config_mod.defaults())
  assert_eq(luminance(get_hl("DiffBanditChangeEmphasis").bg) > luminance(get_hl("DiffBanditChangeLeft").bg), true,
    "Dark palette change emphasis should lighten the change background")

  highlights.apply(config_mod.apply({
    ui = {
      theme = {
        colors = {
          add = 0x112233,
          delete = "#445566",
          change = 0x778899,
          change_emphasis = 0xABCDEF,
        },
      },
    },
  }))
  assert_eq(get_hl("DiffBanditAdd").bg, 0x112233,
    "Add override should set the add source background")
  assert_eq(get_hl("DiffBanditOverviewAdd").bg, 0x112233,
    "Add override should propagate to overview add markers")
  assert_eq(get_hl("DiffBanditConnectorAddLine").fg, 0x112233,
    "Add override should propagate to add connector rails")
  assert_eq(get_hl("DiffBanditConnectorAddLine").bold, true,
    "Connector rail glyphs should render bold by default")
  assert_eq(get_hl("DiffBanditDelete").bg, 0x445566,
    "Delete override should accept hex strings")
  assert_eq(get_hl("DiffBanditOverviewDelete").bg, 0x445566,
    "Delete override should propagate to overview delete markers")
  assert_eq(get_hl("DiffBanditDeleteRightSeparator").sp, 0x445566,
    "Delete override should propagate to delete underlines")
  assert_eq(get_hl("DiffBanditChangeRight").bg, 0x778899,
    "Change override should set the change source background")
  assert_eq(get_hl("DiffBanditOverviewChange").bg, 0x778899,
    "Change override should propagate to overview change markers")
  assert_eq(get_hl("DiffBanditConnectorExpansionChange").fg, 0x778899,
    "Change override should propagate to change wedges")
  assert_eq(get_hl("DiffBanditConnectorExpansionChange").bold, true,
    "Connector transition glyphs should render bold by default")
  assert_eq(get_hl("DiffBanditChangeEmphasis").bg, 0xABCDEF,
    "Change emphasis override should win over adaptive derivation")

  highlights.apply(config_mod.apply({
    ui = {
      theme = {
        highlights = {
          DiffBanditConnectorAddLine = { fg = 0x010203, bg = 0x040506 },
        },
      },
    },
  }))
  assert_eq(get_hl("DiffBanditConnectorAddLine").fg, 0x010203,
    "Per-group highlight override should apply last")
  assert_eq(get_hl("DiffBanditConnectorAddLine").bg, 0x040506,
    "Per-group highlight override should include background")

  local diffbandit = require("diffbandit")
  set_palette({
    Normal = { fg = 0xEEEEEE, bg = 0x101010 },
    LineNr = { fg = 0x777777 },
    Comment = { fg = 0x909090 },
    DiffAdd = { bg = 0x203040 },
    DiffDelete = { bg = 0x402020 },
    DiffChange = { bg = 0x202040 },
  })
  diffbandit.setup({})
  assert_eq(get_hl("DiffBanditAdd").bg, 0x203040,
    "Setup should apply the current add color")
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x304050 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_eq(get_hl("DiffBanditAdd").bg, 0x304050,
    "ColorScheme refresh should rederive add color")
end

-- ==============================================================================
-- CONNECTOR HARDENING TESTS (Suite 15)
-- ==============================================================================

-- Test Suite 15a: Hunks at the very first display row keep their connectors
do
  local function project_first_row(left, right, label)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert_eq(err, nil, "diff error (" .. label .. ")")
    local v = view.build(left, right, hunks, config)
    local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
    assert_eq(#paths >= 1, true, label .. " should produce at least one base path")
    local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
    return paths, fake_session:project_paths_for_toplines(paths, 1, 1, 10, 10)
  end

  -- A hunk starting at display row 1 has no origin row above it. build_paths
  -- synthesizes a same-row anchor (synthetic_origin) so the hunk still
  -- projects and routes; renderers skip origin glyphs/underlines for it.
  local function assert_first_row_routes(paths, projected, label)
    assert_eq(paths[1].origin_display_row, 1, label .. " should anchor on its own first row")
    assert_eq(paths[1].synthetic_origin, true, label .. " anchor should be flagged synthetic")
    assert_eq(#projected, 2, label .. " should project the split pair around the anchor row")
    local layout = { connector_core_width = 12 }
    local plan = paths_mod.plan_routes(projected, layout)
    assert_plan_invariants(plan, layout, label)
    assert_eq(#plan.routes >= 1, true, label .. " should plan at least one visible route")
  end

  local add_paths, add_projected = project_first_row(
    { "alpha", "beta" },
    { "new one", "new two", "alpha", "beta" },
    "insert-at-top")
  assert_first_row_routes(add_paths, add_projected, "insert-at-top")

  local delete_paths, delete_projected = project_first_row(
    { "old one", "old two", "alpha", "beta" },
    { "alpha", "beta" },
    "delete-at-top")
  assert_first_row_routes(delete_paths, delete_projected, "delete-at-top")

  local _, change_projected = project_first_row(
    { "old", "alpha" },
    { "new", "alpha" },
    "change-at-top")
  assert_eq(#change_projected >= 1, true,
    "Change hunks at the first display row should still project")
end

-- Test Suite 15b: Embedded adds merge into their own chunk's change band
do
  -- Hand-crafted hunks: the live diff config (linematch) usually splits uneven
  -- changes into separate hunks, but larger hunks bypass linematch and produce
  -- change hunks with uneven counts -- the shape that creates embedded adds.
  local left = { "ctx", "old", "tail" }
  local right = { "ctx", "new", "extra", "tail" }
  local mixed_hunks = {
    { index = 1, type = "change", left = { start = 2, count = 1 }, right = { start = 2, count = 2 } },
  }
  local v = view.build(left, right, mixed_hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)

  local change_path, add_path
  for _, p in ipairs(paths) do
    if p.kind == "change" then change_path = p end
    if p.kind == "add" then add_path = p end
  end
  assert_eq(add_path ~= nil, true, "Mixed change hunk should produce an embedded add path")
  assert_eq(add_path.embedded_in_change, true, "Extra right-side row should be flagged embedded")
  assert_eq(change_path.mixed_add, true, "Embedded add should merge into the change band")
  assert_eq(change_path.end_right_index, 3, "Merged change band should extend over the added row")

  -- Embedded adds are deliberately not routed on their own; the change band
  -- carries them. Pin that so an unmerged embedded add is visibly a bug.
  local solo_plan = paths_mod.plan_routes({ add_path }, { connector_core_width = 12 })
  assert_eq(#solo_plan.routes, 0, "Embedded add paths should not plan standalone routes")

  -- The merge pass must respect chunk boundaries. With zero-context adjacent
  -- hunks, an add whose origin row is the previous chunk's change row must
  -- NOT merge into that neighboring chunk's band (that would fuse two
  -- independently-stageable chunks); it falls back to normal routing instead.
  local adj_left = { "ctx", "old", "tail" }
  local adj_right = { "ctx", "new", "inserted", "tail" }
  local adjacent_hunks = {
    { index = 1, type = "change", left = { start = 2, count = 1 }, right = { start = 2, count = 1 } },
    { index = 2, type = "add", left = { start = 2, count = 0 }, right = { start = 3, count = 1 } },
  }
  local adj_view = view.build(adj_left, adj_right, adjacent_hunks, config)
  local adj_paths = paths_mod.compute_paths(adj_view.chunks, adj_view.line_meta)
  local adj_change, adj_add
  for _, p in ipairs(adj_paths) do
    if p.kind == "change" then adj_change = p end
    if p.kind == "add" then adj_add = p end
  end
  assert_eq(adj_add.chunk, 2, "Adjacent add path should belong to the second chunk")
  assert_eq(adj_add.embedded_in_change, false,
    "Cross-chunk adds should fall back to normal routing, not stay embedded")
  assert_eq(adj_change.mixed_add, nil,
    "A neighboring chunk's change band should not absorb another chunk's add")
  local adj_layout = { connector_core_width = 12 }
  local adj_plan = paths_mod.plan_routes({ adj_add }, adj_layout)
  assert_plan_invariants(adj_plan, adj_layout, "cross-chunk add")
  assert_eq(#adj_plan.routes, 1, "Cross-chunk add should plan its own visible route")
end

-- Test Suite 15c: Overflow pruning keeps the cap with fully-visible routes
do
  local function overflow_fixture()
    local group = {}
    local paths = {}
    for i = 1, 10 do
      paths[i] = {
        kind = "add",
        chunk = i,
        origin_side = "left",
        target_side = "right",
        origin_display_row = i,
        triangle_display_row = 14,
        route_group = group,
      }
    end
    return paths
  end

  local paths = overflow_fixture()
  local layout = { connector_core_width = 24, viewport_topline = 1, viewport_height = 14 }
  local plan = paths_mod.plan_routes(paths, layout)
  assert_plan_invariants(plan, layout, "fully-visible overflow")
  assert_eq(#plan.routes, paths_mod.MAX_VISIBLE_CONNECTOR_ROUTES,
    "Fully-visible overflow should keep exactly the route cap")
  assert_eq(#plan.hidden_routes, 2, "Fully-visible overflow should hide two routes")
  -- All ten routes are fully on-screen, so hiding is decided purely by the
  -- dock-row tie-break: the two latest origins are dropped, with a reason.
  assert_eq(paths[9].overflow_hidden, true, "Overflow should hide the ninth route")
  assert_eq(paths[10].overflow_hidden, true, "Overflow should hide the tenth route")
  assert_eq(paths[9].hide_reason, "overflow-cap", "Overflow hides should record the cap reason")
  assert_eq(plan.hidden_summary["overflow-cap"], 2, "Plan should summarize cap hides")
  assert_eq(paths[1].overflow_hidden == true, false, "Overflow should keep the first route")

  -- The active chunk's connector is what the user navigated to: it must
  -- survive pruning while any other candidate remains.
  local active_paths = overflow_fixture()
  local active_layout = {
    connector_core_width = 24,
    viewport_topline = 1,
    viewport_height = 14,
    active_chunk_index = 9,
  }
  local active_plan = paths_mod.plan_routes(active_paths, active_layout)
  assert_plan_invariants(active_plan, active_layout, "active-chunk overflow")
  assert_eq(#active_plan.hidden_routes, 2, "Active-chunk overflow should still hide two routes")
  assert_eq(active_paths[9].overflow_hidden == true, false,
    "Overflow should never hide the active chunk's route while others remain")
  assert_eq(active_paths[10].overflow_hidden, true,
    "Overflow should hide the farthest non-active route")
  assert_eq(active_paths[8].overflow_hidden, true,
    "Overflow should hide the next non-active route in dock order")
end

-- Test Suite 15d: Width saturation force-hides routes instead of overlapping
do
  local paths = {}
  for i = 1, 6 do
    paths[i] = {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = i,
      triangle_display_row = i + 7,
      route_group = {},
    }
  end
  local layout = { connector_core_width = 4 }
  local plan = paths_mod.plan_routes(paths, layout)
  assert_eq(plan.strategy, "greedy-hidden", "Width saturation should fall back to greedy-hidden")
  assert_eq(#plan.hidden_routes, 5, "Width saturation should force-hide the unplaceable routes")
  assert_eq(#plan.routes, 1, "Width saturation should keep only the placeable route visible")
  assert_eq(plan.hidden_summary["width-exhausted"], 5,
    "Width saturation hides should record the width reason")
  assert_plan_invariants(plan, layout, "width saturation", { expect_success = false })
end

-- Test Suite 15e: Dense adjacent hunks hold plan and lane invariants under scroll
do
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (dense hardening)")
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)

  for _, toplines in ipairs({ { 1, 1 }, { 1, 38 }, { 1, 46 }, { 8, 46 }, { 20, 30 }, { 40, 40 } }) do
    local label = string.format("dense hardening %d/%d", toplines[1], toplines[2])
    local projected = fake_session:project_paths_for_toplines(paths, toplines[1], toplines[2], 14, 14)
    -- lane_resolution_bailed=true is expected on dense projections: the
    -- legacy crossing loop oscillates and its pass cap ships a bounded,
    -- collision-free state. The stacking check below is the real invariant;
    -- the flag exists so a bail is observable instead of silent.
    local width, plan = paths_mod.required_connector_core_width_for_paths(projected, 3, 24, {
      viewport_topline = toplines[1],
      viewport_height = 14,
      max_route_backtrack_steps = 500,
    })
    assert_plan_invariants(plan, { connector_core_width = width }, label)

    -- No two same-kind paths may hold the same lane on the same row: their
    -- lane-column formula is shared per kind, so stacking means ambiguous
    -- rails. Different kinds anchor to different edges and may reuse numbers.
    local active_bars = paths_mod.compute_active_bars(projected)
    for row, bars in pairs(active_bars) do
      local seen_lanes = {}
      for _, item in ipairs(bars.__items or {}) do
        local key = item.path.kind .. ":" .. tostring(item.lane)
        assert_eq(seen_lanes[key] == nil, true,
          label .. " row " .. tostring(row) .. " should not stack two rails on " .. key)
        seen_lanes[key] = item.path
      end
    end
  end
end

-- Test Suite 15f: The live pressure sizer stays consistent with the planner
do
  -- The gutter width is sized ONCE per document by pressure_core_width and
  -- never resizes while scrolling. Across a grid of independent topline
  -- pairs, every viewport must either plan cleanly at that width or hide
  -- routes with a recorded reason -- never silently.
  local single = paths_mod.pressure_core_width({
    { kind = "add", origin_display_row = 1, triangle_display_row = 4 },
  }, 3, 24)
  assert_eq(single, 7, "A single routed range should size to minimum plus slack lanes")
  assert_eq(paths_mod.pressure_core_width({}, 3, 24), 3,
    "A document with no routes should keep the compact minimum width")

  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (pressure sizer)")
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local width = paths_mod.pressure_core_width(paths, 3, 24)
  assert_eq(width >= 3 and width <= 24, true, "Pressure width should respect the configured bounds")

  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)
  local toplines = { 1, 10, 20, 30, 40, 50 }
  for _, lt in ipairs(toplines) do
    for _, rt in ipairs(toplines) do
      local label = string.format("pressure sizer %d/%d", lt, rt)
      local projected = fake_session:project_paths_for_toplines(paths, lt, rt, 14, 14)
      local layout = {
        connector_core_width = width,
        viewport_topline = lt,
        viewport_height = 14,
        max_route_backtrack_steps = 500,
      }
      local plan = paths_mod.plan_routes(projected, layout)
      assert_plan_invariants(plan, layout, label, { success_optional = true })
      if not plan.success then
        assert_eq(#plan.hidden_routes >= 1, true,
          label .. " planner failure must surface as recorded hidden routes")
      end
    end
  end
end

-- Test Suite 15g: Offscreen-origin continuations keep a visible anchor
do
  local paths = {
    {
      kind = "add",
      origin_side = "left",
      target_side = "right",
      origin_display_row = 5,
      triangle_display_row = 1,
      hide_triangle = true,
      route_group = {},
    },
  }
  local layout = { connector_core_width = 12 }
  local plan = paths_mod.plan_routes(paths, layout)
  assert_plan_invariants(plan, layout, "hide_triangle continuation")
  assert_eq(#plan.routes, 1, "Hidden-triangle route should still plan")
  local touches_triangle_row = false
  local cell_count = 0
  for _, segment in ipairs(plan.routes[1].segments or {}) do
    if segment.type == "horizontal" then
      cell_count = cell_count + (segment.end_col - segment.start_col + 1)
      if segment.row == 1 then touches_triangle_row = true end
    else
      cell_count = cell_count + (segment.end_row - segment.start_row + 1)
      if segment.start_row <= 1 and segment.end_row >= 1 then touches_triangle_row = true end
    end
  end
  assert_eq(cell_count >= 1, true,
    "Hidden-triangle route should keep at least one visible connector cell")
  assert_eq(touches_triangle_row, false,
    "Hidden-triangle route should not draw on the suppressed triangle row")
end

-- Test Suite 15h: Routes never hide before the connector core is saturated
do
  -- The scroll-aware sizer widens the core for the worst stacking that
  -- independent scrolling can produce, and the render path falls back to an
  -- upward width search (stretched to the core edge) when the fixed-width
  -- tree thrashes. Together: across every topline pair, the only legal hide
  -- reason is the eight-route visibility cap.
  local left = read_file(root .. "/tests/files/left_dense_mixed.txt")
  local right = read_file(root .. "/tests/files/right_dense_mixed.txt")
  local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  assert_eq(err, nil, "diff error (saturation sweep)")
  local v = view.build(left, right, hunks, config)
  local paths = paths_mod.compute_paths(v.chunks, v.line_meta)
  local core = paths_mod.pressure_core_width(paths, 3, 24, 14)
  assert_eq(core, 17, "Scroll-aware sizing should widen the dense core for stackable routes")
  local fake_session = setmetatable({ view = v, left = { lines = left }, right = { lines = right } }, Session)

  for lt = 1, 57, 4 do
    for rt = 1, 57, 4 do
      local label = string.format("saturation %d/%d", lt, rt)
      local projected = fake_session:project_paths_for_toplines(paths, lt, rt, 14, 14)
      local layout = {
        connector_core_width = core,
        viewport_topline = lt,
        viewport_height = 14,
        max_route_backtrack_steps = 500,
      }
      local plan = paths_mod.plan_routes(projected, layout)
      if not plan.success then
        local solved_width, retry = paths_mod.required_connector_core_width_for_paths(projected, 3, core, layout)
        assert_eq(retry.success, true, label .. " fallback width search should solve within the core")
        plan = paths_mod.stretch_plan_to_core(retry, solved_width, core)
        for _, route in ipairs(plan.routes) do
          for _, segment in ipairs(route.segments or {}) do
            if segment.type == "horizontal" and (segment.side == "right" or segment.side == "both") then
              assert_eq(segment.end_col <= core - 1, true,
                label .. " stretched horizontals should stay within the core")
            end
          end
        end
      end
      for _, r in ipairs(plan.hidden_routes) do
        assert_eq(r.hide_reason, "overflow-cap",
          label .. " routes should only hide at the visibility cap, not before saturation")
      end
      assert_plan_invariants(plan, layout, label, { success_optional = true })
    end
  end
end

-- ==============================================================================
-- GIT PROVIDER TESTS
-- ==============================================================================

local function git_test_command(args, cwd)
  if vim.system then
    local cmd = vim.list_extend({ "git" }, args)
    local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
    if result.code ~= 0 then
      error("git command failed: git " .. table.concat(args, " ") .. "\n" .. tostring(result.stderr or result.stdout))
    end
    return result.stdout or ""
  end

  local uv = vim.uv or vim.loop
  local old_cwd = uv.cwd()
  if cwd then
    uv.chdir(cwd)
  end
  local output = vim.fn.system(vim.list_extend({ "git" }, args))
  local code = vim.v.shell_error
  if cwd then
    uv.chdir(old_cwd)
  end
  if code ~= 0 then
    error("git command failed: git " .. table.concat(args, " ") .. "\n" .. tostring(output))
  end
  return output
end

local function git_status_command(args, cwd)
  if vim.system then
    local cmd = vim.list_extend({ "git" }, args)
    local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
    return result.code, result.stdout or "", result.stderr or ""
  end

  local uv = vim.uv or vim.loop
  local old_cwd = uv.cwd()
  if cwd then
    uv.chdir(cwd)
  end
  local output = vim.fn.system(vim.list_extend({ "git" }, args))
  local code = vim.v.shell_error
  if cwd then
    uv.chdir(old_cwd)
  end
  return code, output or "", ""
end

local function make_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git_test_command({ "init" }, dir)
  git_test_command({ "config", "user.email", "diffbandit@example.test" }, dir)
  git_test_command({ "config", "user.name", "DiffBandit Test" }, dir)
  return dir
end

local function write_repo_file(root_dir, path, lines)
  local full = root_dir .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  vim.fn.writefile(lines, full)
end

local function commit_baseline(root_dir)
  git_test_command({ "add", "." }, root_dir)
  git_test_command({ "commit", "-m", "baseline" }, root_dir)
end

do
  local left = vim.fn.tempname()
  local right = vim.fn.tempname()
  vim.fn.mkdir(left .. "/nested", "p")
  vim.fn.mkdir(right .. "/nested", "p")
  write_repo_file(left, "same.txt", { "same" })
  write_repo_file(right, "same.txt", { "same" })
  write_repo_file(left, "size.txt", { "short" })
  write_repo_file(right, "size.txt", { "longer" })
  write_repo_file(left, "left-only.txt", { "left" })
  write_repo_file(right, "right-only.txt", { "right" })
  write_repo_file(left, "nested/pending.bin", { "aa" })
  write_repo_file(right, "nested/pending.bin", { "bb" })

  local private = folder_mod._private
  local left_entries = private.scan_tree(left, {})
  local right_entries = private.scan_tree(right, {})
  local rows, by_rel = private.build_rows(left_entries, right_entries)
  private.recompute_aggregate(rows, by_rel)

  assert_eq(by_rel["left-only.txt"].direct_status, "left_only",
    "Folder model should mark left-only files")
  assert_eq(by_rel["right-only.txt"].direct_status, "right_only",
    "Folder model should mark right-only files")
  assert_eq(by_rel["size.txt"].direct_status, "different",
    "Folder model should mark size mismatches as different without digesting")
  assert_eq(by_rel["nested/pending.bin"].direct_status, "pending",
    "Folder model should defer same-size regular files to digest comparison")
  assert_eq(by_rel["nested"].status, "pending",
    "Folder model should aggregate pending descendants into parent folders")

  by_rel["nested/pending.bin"].direct_status = "different"
  private.recompute_aggregate(rows, by_rel)
  assert_eq(by_rel["nested"].status, "different",
    "Folder model should aggregate differing descendants into parent folders")
end

do
  local private = folder_mod._private
  local nul_output = "abc123  /tmp/space name.txt\0def456  /tmp/new\nline.bin\0"
  local parsed_nul = private.parse_md5sum_z(nul_output)
  assert_eq(parsed_nul["/tmp/space name.txt"], "abc123",
    "Folder digest parser should preserve spaces in md5sum -z paths")
  assert_eq(parsed_nul["/tmp/new\nline.bin"], "def456",
    "Folder digest parser should preserve newline paths in md5sum -z output")

  local parsed_order = private.parse_line_order("aaa\nbbb\n", { "/left", "/right" })
  assert_eq(parsed_order["/left"], "aaa",
    "macOS md5 -q parser should associate digests by input order")
  assert_eq(parsed_order["/right"], "bbb",
    "macOS md5 -q parser should parse the second digest by input order")

  local parsed_lines = private.parse_digest_lines("ccc  /tmp/file one\n")
  assert_eq(parsed_lines["/tmp/file one"], "ccc",
    "shasum parser should preserve paths with spaces")

  local backend = private.detect_backend(config)
  assert_ne(backend, nil, "Folder diff should detect an external digest or cmp backend")
end

do
  local replaced = actions_mod._private.replace_range({ "a", "c" }, 1, 0, { "b" })
  assert_eq(to_text(replaced), "a\nb\nc\n", "Zero-count replacement should insert after the anchor line")
  replaced = actions_mod._private.replace_range({ "a", "b", "c" }, 2, 1, { "B" })
  assert_eq(to_text(replaced), "a\nB\nc\n", "Positive-count replacement should replace the target range")
end

do
  local entries = git_mod._private.parse_name_status("M\0space name.txt\0R100\0old path.txt\0new path.txt\0")
  assert_eq(#entries, 2, "NUL name-status parser should read modified and renamed entries")
  assert_eq(entries[1].path, "space name.txt", "Parser should preserve spaces in paths")
  assert_eq(entries[2].old_path, "old path.txt", "Parser should capture rename old path")
  assert_eq(entries[2].path, "new path.txt", "Parser should capture rename new path")
end

do
  local session = {
    config = config,
    left = { path = "/tmp/left.txt", label = "left.txt" },
    right = { path = "/tmp/right.txt", label = "right.txt" },
    current_chunk = 1,
    view = { chunks = { {} } },
  }
  local lines = status_mod.build(session)
  assert_eq(lines.left, "file  left.txt", "Plain status should identify left file")
  assert_eq(lines.center, "DiffBandit  hunk 1/1", "Plain status should summarize non-git hunk state")
  assert_eq(lines.right, "file  right.txt", "Plain status should identify right file")
end

do
  local old_have_nerd = vim.g.have_nerd_font
  local old_diffbandit_have_nerd = vim.g.diffbandit_have_nerd_font
  vim.g.have_nerd_font = true
  vim.g.diffbandit_have_nerd_font = nil
  local nerd_config = config_mod.apply({
    ui = {
      status = {
        icons = "auto",
      },
    },
  })
  local icons = status_mod._private.icons_for(nerd_config)
  assert_eq(icons.git ~= "Git", true, "Auto icon mode should use Nerd Font glyphs when advertised")
  vim.g.have_nerd_font = old_have_nerd
  vim.g.diffbandit_have_nerd_font = old_diffbandit_have_nerd
end

do
  local dump = hex_mod.dump(string.char(0, 1, 2, 65, 66, 255), {
    bytes_per_row = 4,
    max_bytes = 4,
    show_ascii = true,
  })
  assert_eq(dump.display_numbers[1], "00000000", "Hex dump should label the first row by byte offset")
  assert_eq(dump.lines[1], "00 01 02 41  |...A|", "Hex dump should include grouped bytes and ASCII preview")
  assert_eq(dump.truncated, true, "Hex dump should report truncation when max_bytes is exceeded")
  assert_eq(dump.lines[2], "[DiffBandit: hex view truncated at 4 of 6 bytes]",
    "Hex dump should add a truncation notice row")
  assert_eq(hex_mod.is_binary("plain text\n"), false, "Plain text should not be detected as binary")
  assert_eq(hex_mod.is_binary("a\000b"), true, "NUL-containing text should be detected as binary")
  local no_offsets = hex_mod.dump("abcd", { show_offsets = false })
  assert_eq(no_offsets.display_numbers, nil, "Hex dump should honor disabled offset labels")
end

if vim.fn.executable("git") == 1 then
  do
    local repo = make_git_repo()
    write_repo_file(repo, "alpha.txt", { "one" })
    commit_baseline(repo)
    write_repo_file(repo, "alpha.txt", { "one changed" })
    write_repo_file(repo, "new file.txt", { "new content" })

    local queue, err = git_mod.queue({
      root = repo,
      mode = "unstaged",
      include_untracked = true,
    }, config.git)
    assert_eq(err, nil, "Unstaged queue should load")
    assert_eq(#queue.entries, 2, "Unstaged queue should include modified and untracked files")

    local alpha
    local alpha_index
    local untracked
    for index, entry in ipairs(queue.entries) do
      if entry.path == "alpha.txt" then
        alpha = select(1, queue.load(index))
        alpha_index = index
      elseif entry.path == "new file.txt" then
        untracked = select(1, queue.load(index))
      end
    end

    assert_eq(alpha.left.text, "one\n", "Unstaged left source should read index content")
    assert_eq(alpha.right.text, "one changed\n", "Unstaged right source should read working tree content")
    do
      queue.index = alpha_index
      local status_session = {
        config = config,
        left = alpha.left,
        right = alpha.right,
        file_queue = queue,
        file_queue_index = alpha_index,
        current_chunk = 1,
        view = { chunks = { {}, {} } },
        staged_chunk_states = { [1] = true },
      }
      local lines = status_mod.build(status_session)
      assert_eq(lines.left, "index  alpha.txt", "Git status should identify left index side")
      assert_eq(lines.center, "DiffBandit  Git:unstaged  file " .. tostring(alpha_index) .. "/2  hunk 1/2  M  staged 1/2", "Git status should summarize queue and staged chunks")
      assert_eq(lines.center_compact, "unstg " .. tostring(alpha_index) .. "/2 h1/2 M 1/2", "Git status should provide a compact center summary")
      assert_eq(lines.right, "working tree  alpha.txt", "Git status should identify right working tree side")
    end
    assert_eq(untracked.left.text, "", "Untracked left source should be empty")
    assert_eq(untracked.left.label, "new file.txt (not tracked)", "Untracked left source should explain missing base")
    assert_eq(untracked.left.git_state, "untracked", "Untracked left source should carry git state")
    assert_eq(untracked.left.empty_reason, "New untracked file", "Untracked left source should carry empty notice text")
    assert_eq(untracked.right.text, "new content\n", "Untracked right source should read working tree content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "staged.txt", { "old" })
    commit_baseline(repo)
    write_repo_file(repo, "staged.txt", { "new" })
    git_test_command({ "add", "staged.txt" }, repo)

    local queue, err = git_mod.queue({
      root = repo,
      mode = "staged",
    }, config.git)
    assert_eq(err, nil, "Staged queue should load")
    assert_eq(#queue.entries, 1, "Staged queue should include staged file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "old\n", "Staged left source should read HEAD content")
    assert_eq(loaded.right.text, "new\n", "Staged right source should read index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "history.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "history.txt", { "base", "second" })
    git_test_command({ "commit", "-am", "second commit" }, repo)
    local rev = vim.trim(git_test_command({ "rev-parse", "HEAD" }, repo))

    local commits, log_err = git_mod.log(repo, { max_count = 2 })
    assert_eq(log_err, nil, "Git log helper should not error")
    assert_eq(#commits, 2, "Git log helper should return requested commits")
    assert_eq(commits[1].subject, "second commit", "Git log helper should parse commit subject")

    local queue, queue_err = git_mod.commit_queue(repo, rev, {}, config.git)
    assert_eq(queue_err, nil, "Commit queue should load for a normal commit")
    assert_eq(queue.opts.read_only, true, "Commit queue should be marked read-only")
    assert_eq(queue.opts.review.kind, "commit", "Commit queue should carry review metadata")
    assert_eq(#queue.entries, 1, "Commit queue should include changed files")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "base\n", "Commit queue left side should read the parent")
    assert_eq(loaded.right.text, "base\nsecond\n", "Commit queue right side should read the commit")
    assert_eq(loaded.entry.actions_enabled, false, "Commit queue entries should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "root.txt", { "root" })
    git_test_command({ "add", "root.txt" }, repo)
    git_test_command({ "commit", "-m", "root commit" }, repo)
    local rev = vim.trim(git_test_command({ "rev-parse", "HEAD" }, repo))

    local queue, queue_err = git_mod.commit_queue(repo, rev, {}, config.git)
    assert_eq(queue_err, nil, "Root commit queue should load")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "", "Root commit queue should compare against the empty tree")
    assert_eq(loaded.right.text, "root\n", "Root commit queue should read root commit content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "branch.txt", { "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "branch.txt", { "base", "feature" })
    git_test_command({ "commit", "-am", "feature commit" }, repo)
    git_test_command({ "checkout", main_branch }, repo)

    local branches, branch_err = git_mod.list_branches(repo)
    assert_eq(branch_err, nil, "Branch listing should not error")
    local saw_feature = false
    for _, branch in ipairs(branches) do
      if branch.name == "feature" then
        saw_feature = true
      end
    end
    assert_eq(saw_feature, true, "Branch listing should include local branches")

    local queue, queue_err = git_mod.compare_queue(repo, main_branch, "feature", {}, config.git)
    assert_eq(queue_err, nil, "Branch compare queue should load")
    assert_eq(queue.opts.read_only, true, "Branch compare queue should be read-only")
    assert_eq(queue.opts.review.kind, "compare", "Branch compare queue should carry review metadata")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.right.text, "base\nfeature\n", "Branch compare should read target branch content")

    write_repo_file(repo, "dirty.txt", { "dirty" })
    local ok, checkout_err = git_mod.checkout_branch(repo, "feature")
    assert_eq(ok, false, "Checkout helper should refuse dirty worktrees by default")
    assert_eq(checkout_err, "worktree has uncommitted changes", "Checkout helper should report dirty worktree")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "panel.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "panel.txt", { "one", "TWO", "three" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "panel.txt" } }, config.git)))
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "unstaged",
      "Panel file state should start unstaged for worktree-only changes")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { mode = "all" }), "unstaged",
      "Panel file state should not treat all-mode opts as a staged base")

    local ok, err = git_mod.stage_file(repo, queue.entries[1])
    assert_eq(err, nil, "Panel file stage should not error")
    assert_eq(ok, true, "Panel file stage should succeed")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "staged",
      "Panel file state should become staged after file stage")

    write_repo_file(repo, "panel.txt", { "one", "TWO", "THREE" })
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "partial",
      "Panel file state should detect staged and unstaged changes for the same file")

    ok, err = git_mod.unstage_file(repo, queue.entries[1])
    assert_eq(err, nil, "Panel file unstage should not error")
    assert_eq(ok, true, "Panel file unstage should succeed")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1]), "unstaged",
      "Panel file state should return to unstaged after whole-file unstage")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "tracked.txt", { "staged" })
    git_test_command({ "add", "tracked.txt" }, repo)
    write_repo_file(repo, "tracked.txt", { "worktree" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "tracked.txt" } }, config.git)))
    local ok, err = git_mod.discard_worktree_file(repo, queue.entries[1])
    assert_eq(ok, true, "Panel discard file action should succeed")
    assert_eq(err, nil, "Panel discard file action should not error")
    assert_eq(table.concat(read_file(repo .. "/tracked.txt"), "\n") .. "\n", "staged\n",
      "Panel discard should restore the worktree to the staged index content")
    assert_eq(git_mod.read_index(repo, "tracked.txt"), "staged\n",
      "Panel discard should preserve staged content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "restore_me.txt", { "base" })
    commit_baseline(repo)
    assert(os.remove(repo .. "/restore_me.txt"))

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "restore_me.txt" } }, config.git)))
    local ok, err = git_mod.discard_worktree_file(repo, queue.entries[1])
    assert_eq(ok, true, "Panel restore deleted file action should succeed")
    assert_eq(err, nil, "Panel restore deleted file action should not error")
    assert_eq(table.concat(read_file(repo .. "/restore_me.txt"), "\n") .. "\n", "base\n",
      "Panel restore deleted file action should restore index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "keep.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "scratch.log", { "temporary" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "scratch.log" } }, config.git)))
    assert_eq(queue.entries[1].untracked, true, "Panel delete test should load an untracked file")
    local ok, err = git_mod.delete_untracked_file(repo, queue.entries[1])
    assert_eq(ok, true, "Panel delete untracked action should succeed")
    assert_eq(err, nil, "Panel delete untracked action should not error")
    assert_eq(vim.fn.filereadable(repo .. "/scratch.log"), 0,
      "Panel delete untracked action should remove the file")

    ok, err = git_mod.delete_untracked_file(repo, { path = "keep.txt" })
    assert_eq(ok, false, "Panel delete untracked action should refuse tracked files")
    assert_eq(err, "refusing to delete a tracked file",
      "Panel delete untracked action should explain tracked file refusal")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "base" })
    commit_baseline(repo)

    local ok, err = git_mod.append_gitignore(repo, "/logs/*.log")
    assert_eq(ok, true, "Panel ignore action should create .gitignore")
    assert_eq(err, nil, "Panel ignore action should not error")
    ok, err = git_mod.append_gitignore(repo, "/logs/*.log")
    assert_eq(ok, true, "Panel ignore action should allow an existing pattern")
    assert_eq(err, nil, "Panel ignore duplicate action should not error")
    local lines = read_file(repo .. "/.gitignore")
    assert_eq(#lines, 1, "Panel ignore action should avoid duplicate .gitignore entries")
    assert_eq(lines[1], "/logs/*.log", "Panel ignore action should write the requested pattern")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "logs/app.log", { "temporary" })
    write_repo_file(repo, "tracked.txt", { "changed" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    local by_path = {}
    for index, entry in ipairs(queue.entries) do
      by_path[entry.path] = { entry = entry, index = index }
    end
    local session = {
      file_queue = queue,
      panel = { stage_states = git_mod.file_stage_states(repo, queue.entries, queue.opts) },
    }
    local untracked_actions = panel_mod.file_actions_for_entry(session, by_path["logs/app.log"].entry,
      session.panel.stage_states[by_path["logs/app.log"].index])
    local action_ids = {}
    for _, action in ipairs(untracked_actions) do
      action_ids[action.id] = true
    end
    assert_eq(action_ids.stage, true, "Panel untracked action list should include stage")
    assert_eq(action_ids.delete_untracked, true, "Panel untracked action list should include delete")
    assert_eq(action_ids["ignore:/logs/app.log"], true, "Panel untracked action list should include exact ignore")
    assert_eq(action_ids["ignore:*.log"], true, "Panel untracked action list should include extension ignore")
    assert_eq(action_ids["ignore:/logs/"], true, "Panel untracked action list should include parent directory ignore")

    local tracked_actions = panel_mod.file_actions_for_entry(session, by_path["tracked.txt"].entry,
      session.panel.stage_states[by_path["tracked.txt"].index])
    action_ids = {}
    for _, action in ipairs(tracked_actions) do
      action_ids[action.id] = true
    end
    assert_eq(action_ids.stage, true, "Panel tracked action list should include stage")
    assert_eq(action_ids.discard_worktree, true, "Panel tracked action list should include discard")
    assert_eq(action_ids.delete_untracked, nil, "Panel tracked action list should not include delete untracked")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "alpha.txt", { "one" })
    write_repo_file(repo, "beta.txt", { "one" })
    commit_baseline(repo)
    write_repo_file(repo, "alpha.txt", { "two" })
    write_repo_file(repo, "beta.txt", { "two" })
    git_test_command({ "add", "alpha.txt" }, repo)
    write_repo_file(repo, "alpha.txt", { "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    local states = git_mod.file_stage_states(repo, queue.entries, queue.opts)
    local by_path = {}
    for index, entry in ipairs(queue.entries) do
      by_path[entry.path] = states[index]
    end
    assert_eq(by_path["alpha.txt"], "partial", "Batched panel state should detect partial files")
    assert_eq(by_path["beta.txt"], "unstaged", "Batched panel state should detect unstaged files")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "amend.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "amend.txt", { "committed" })
    git_test_command({ "add", "amend.txt" }, repo)
    git_test_command({ "commit", "-m", "second" }, repo)

    local base, err = git_mod.amend_base(repo)
    assert_eq(err, nil, "Amend base should resolve for a normal repository")
    assert_eq(base, "HEAD^", "Amend base should compare against the parent commit")

    local queue = assert((git_mod.queue({ root = repo, mode = "all", base = base, pathspecs = { "amend.txt" } }, config.git)))
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { stage_base = base }), "staged",
      "Amend panel state should treat current HEAD content as staged against the amend base")

    write_repo_file(repo, "amend.txt", { "committed", "working tree" })
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { stage_base = base }), "partial",
      "Amend panel state should show partial when the commit content and worktree both differ from the amend base")
    local ok, unstage_err = git_mod.unstage_file(repo, queue.entries[1], { stage_base = base })
    assert_eq(ok, true, "Amend unstage should restore the index from the amend base")
    assert_eq(unstage_err, nil, "Amend unstage should not error")
    assert_eq(git_mod.file_stage_state(repo, queue.entries[1], { stage_base = base }), "unstaged",
      "Amend unstage should clear the staged state against the amend base")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "root.txt", { "first" })
    commit_baseline(repo)
    local base, err = git_mod.amend_base(repo)
    assert_eq(err, nil, "Amend base should resolve for the root commit")
    assert_ne(base, "HEAD^", "Root amend base should not use a missing parent ref")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "commit.txt", { "base" })
    commit_baseline(repo)
    local ok, err = git_mod.commit(repo, "   ", {})
    assert_eq(ok, false, "Panel commit should reject an empty message")
    assert_eq(err, "commit message cannot be empty", "Panel commit should explain empty message validation")
    ok, err = git_mod.commit(repo, "no staged changes", {})
    assert_eq(ok, false, "Panel commit should reject committing without staged changes")
    assert_eq(err, "no staged changes to commit", "Panel commit should explain missing staged changes")

    write_repo_file(repo, "commit.txt", { "changed" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "commit.txt" } }, config.git)))
    ok, err = git_mod.stage_file(repo, queue.entries[1])
    assert_eq(ok, true, "Commit test stage should succeed")
    assert_eq(err, nil, "Commit test stage should not error")
    ok, err = git_mod.commit(repo, "panel commit", {})
    assert_eq(ok, true, "Panel commit should succeed with staged changes")
    assert_eq(err, nil, "Panel commit should not error")
    local message = git_test_command({ "log", "-1", "--pretty=%B" }, repo)
    assert_eq(vim.trim(message), "panel commit", "Panel commit should write the requested message")

    ok, err = git_mod.commit(repo, "panel amend", { amend = true })
    assert_eq(ok, true, "Panel amend should allow message-only amend")
    assert_eq(err, nil, "Panel amend should not error")
    message = git_test_command({ "log", "-1", "--pretty=%B" }, repo)
    assert_eq(vim.trim(message), "panel amend", "Panel amend should update the latest commit message")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "merge_no_diff.txt", { "one", "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "merge_no_diff.txt", { "one", "incoming" })
    git_test_command({ "commit", "-am", "incoming merge side" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "merge_no_diff.txt", { "one", "local" })
    git_test_command({ "commit", "-am", "local merge side" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "No-diff merge commit fixture should conflict")
    write_repo_file(repo, "merge_no_diff.txt", { "one", "local" })
    git_test_command({ "add", "merge_no_diff.txt" }, repo)
    assert_eq(git_mod.has_any_staged_changes(repo), false,
      "Resolving a conflict to HEAD should leave no cached diff")
    assert_eq(git_mod.has_pending_merge_commit(repo), true,
      "Resolved no-diff merge should still have a pending merge commit")
    local ok, err = git_mod.commit(repo, "merge no diff", {})
    assert_eq(ok, true, "Panel commit should allow a resolved merge with no staged diff")
    assert_eq(err, nil, "Resolved no-diff merge commit should not error")
    local message = git_test_command({ "log", "-1", "--pretty=%B" }, repo)
    assert_eq(vim.trim(message), "merge no diff", "Resolved no-diff merge should create a merge commit")
  end

  do
    local session = {
      config = config_mod.apply({
        git = {
          panel = {
            icons = "plain",
          },
        },
      }),
      file_queue = {
        root = "/tmp/repo",
        entries = {
          { status = "U", raw_status = "U", path = "lua/diffbandit/merge.lua" },
          { status = "M", path = "lua/diffbandit/git.lua", kind = "modified" },
          { status = "A", raw_status = "??", path = "tests/files/new.txt", untracked = true, kind = "untracked" },
        },
      },
      panel = {
        stage_states = {
          [2] = "partial",
          [3] = "unstaged",
        },
      },
    }
    local rows = panel_mod._private.build_rows(session)
    assert_eq(rows[1].text, "▾ Merge Conflicts  1 files", "Panel rows should group conflicts first")
    assert_eq(rows[2].text:find("! U merge.lua", 1, true) ~= nil, true,
      "Panel conflict row should use conflict status instead of staged state")
    assert_eq(rows[3].text, "▾ Changes  1 files", "Panel rows should group tracked changes")
    assert_eq(rows[4].type, "file", "Panel rows should include tracked file row")
    assert_eq(rows[5].text, "▾ Unversioned Files  1 files", "Panel rows should group unversioned files")
    assert_eq(rows[6].type, "file", "Panel rows should include unversioned file row")
    assert_eq(rows[4].text:find("◧ M git.lua", 1, true) ~= nil, true,
      "Panel file row should include staged state, status, and basename")
  end

  do
    local nav_buf = vim.api.nvim_create_buf(false, true)
    local original_file_stage_states = git_mod.file_stage_states
    local called = false
    git_mod.file_stage_states = function()
      called = true
      return {}
    end
    local session = {
      ns = vim.api.nvim_create_namespace("DiffBanditPanelRenderNoGit"),
      config = config,
      file_queue = {
        root = "/tmp/repo",
        entries = {
          { status = "M", path = "one.txt", kind = "modified" },
        },
      },
      panel = {
        nav_buf = nav_buf,
        stage_states = { [1] = "unstaged" },
      },
      file_queue_index = 1,
    }
    panel_mod.render_nav(session, 1)
    git_mod.file_stage_states = original_file_stage_states
    assert_eq(called, false, "Panel nav render should not refresh Git stage states implicitly")
    vim.api.nvim_buf_delete(nav_buf, { force = true })
  end

  do
    local buf = vim.api.nvim_create_buf(false, true)
    local session = {
      ns = vim.api.nvim_create_namespace("DiffBanditPanelCommitTest"),
      config = config,
      panel = {
        commit_buf = buf,
        stage_states = { [1] = "staged" },
        amend = true,
        message_lines = { "commit body" },
        validation_message = "commit message cannot be empty",
      },
    }
    panel_mod.render_commit(session)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_eq(#lines, 3, "Commit pane should reserve two virtual header rows before the message")
    assert_eq(lines[1], "", "Commit pane amend status row should be virtual text")
    assert_eq(lines[2], "", "Commit pane message label row should be virtual text")
    assert_eq(lines[3], "commit body", "Commit pane message body should remain real buffer text")
    local marks = vim.api.nvim_buf_get_extmarks(buf, session.ns, 0, -1, { details = true })
    assert_eq(#marks >= 2, true, "Commit pane should render virtual header overlays")
    local found_validation = false
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      for _, chunk in ipairs(details.virt_text or {}) do
        if chunk[1] and chunk[1]:find("commit message cannot be empty", 1, true) then
          found_validation = true
        end
      end
    end
    assert_eq(found_validation, true, "Commit pane should render validation text in the virtual header")
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "baseline.txt", { "base" })
    commit_baseline(repo)
    write_repo_file(repo, "added.txt", { "new" })
    git_test_command({ "add", "added.txt" }, repo)

    local queue, err = git_mod.queue({
      root = repo,
      mode = "staged",
      pathspecs = { "added.txt" },
    }, config.git)
    assert_eq(err, nil, "Staged added-file queue should load")
    assert_eq(#queue.entries, 1, "Staged added-file queue should include one file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "", "Staged added left source should be empty")
    assert_eq(loaded.left.label, "added.txt (HEAD: absent)", "Staged added left source should explain missing HEAD version")
    assert_eq(loaded.left.git_state, "absent", "Staged added left source should carry absent git state")
    assert_eq(loaded.left.empty_reason, "New file", "Staged added left source should carry empty notice text")
    assert_eq(loaded.right.text, "new\n", "Staged added right source should read index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "gone.txt", { "old" })
    commit_baseline(repo)
    git_test_command({ "rm", "gone.txt" }, repo)

    local queue, err = git_mod.queue({
      root = repo,
      mode = "staged",
    }, config.git)
    assert_eq(err, nil, "Staged deleted-file queue should load")
    assert_eq(#queue.entries, 1, "Staged deleted-file queue should include one file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "old\n", "Staged deleted left source should read HEAD content")
    assert_eq(loaded.right.text, "", "Staged deleted right source should be empty")
    assert_eq(loaded.right.label, "gone.txt (index: deleted)", "Staged deleted right source should explain missing index version")
    assert_eq(loaded.right.git_state, "deleted", "Staged deleted right source should carry deleted git state")
    assert_eq(loaded.right.empty_reason, "Deleted file", "Staged deleted right source should carry empty notice text")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "buffer.txt", { "saved" })
    commit_baseline(repo)

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
    vim.api.nvim_buf_set_name(bufnr, repo .. "/buffer.txt")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved" })

    local queue, err = git_mod.queue({
      root = repo,
      mode = "unstaged",
      scope = "current",
      path = repo .. "/buffer.txt",
      use_buffer = true,
    }, config.git)
    assert_eq(err, nil, "Current-file queue should include unsaved buffer changes")
    assert_eq(#queue.entries, 1, "Current-file queue should synthesize one buffer-only entry")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.text, "saved\n", "Buffer diff left source should read index content")
    assert_eq(loaded.right.text, "unsaved\n", "Buffer diff right source should read live buffer content")
    assert_eq(loaded.right.editable and loaded.right.editable.bufnr, bufnr,
      "Git worktree right source should carry the reusable live buffer identity")
    assert_eq(loaded.right.editable and loaded.right.editable.target, "git-worktree",
      "Git worktree right source should be marked as an editable worktree target")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mapped-undo.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "mapped-undo.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({
      root = repo,
      mode = "unstaged",
      pathspecs = { "mapped-undo.txt" },
    }, config.git)))
    local loaded = select(1, queue.load(1))
    local session = assert((Session.start({
      left = loaded.left,
      right = loaded.right,
    }, config, {
      queue = queue,
    })))

    session:stage_hunk()
    assert_eq(git_mod.read_index(repo, "mapped-undo.txt"), "one\nTWO\nthree\n",
      "Mapped undo setup should stage the hunk first")

    vim.api.nvim_set_current_win(session.right_win)
    local undo_callback = buffer_keymap_callback(session.right_buf, "n", config.actions.keys.undo)
    assert_eq(type(undo_callback), "function",
      "Editable Git right buffer should have a callable undo mapping")
    undo_callback()
    assert_eq(git_mod.read_index(repo, "mapped-undo.txt"), "one\ntwo\nthree\n",
      "Undo in an editable Git right buffer with no native edit should pop the DiffBandit action stack")

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mapped-undo-after-edit.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "mapped-undo-after-edit.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({
      root = repo,
      mode = "unstaged",
      pathspecs = { "mapped-undo-after-edit.txt" },
    }, config.git)))
    local loaded = select(1, queue.load(1))
    local session = assert((Session.start({
      left = loaded.left,
      right = loaded.right,
    }, config, {
      queue = queue,
    })))

    vim.api.nvim_set_current_win(session.right_win)
    vim.api.nvim_buf_set_lines(session.right_buf, 0, -1, false, { "one", "THREE", "three" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.right_buf })
    vim.wait(100, function()
      return session.right.text == "one\nTHREE\nthree\n"
    end, 5)

    session:stage_hunk()
    assert_eq(git_mod.read_index(repo, "mapped-undo-after-edit.txt"), "one\nTHREE\nthree\n",
      "Mapped undo after edit setup should stage the edited right-buffer content")

    local undo_callback = buffer_keymap_callback(session.right_buf, "n", config.actions.keys.undo)
    undo_callback()
    assert_eq(git_mod.read_index(repo, "mapped-undo-after-edit.txt"), "one\ntwo\nthree\n",
      "Undo after edit then stage should undo the newer stage action first")
    assert_eq(vim.api.nvim_buf_get_lines(session.right_buf, 0, -1, false)[2], "THREE",
      "Undoing the stage action first should leave the right-buffer edit intact")

    undo_callback()
    vim.wait(100, function()
      return session.right.text == "one\nTWO\nthree\n"
    end, 5)
    assert_eq(vim.api.nvim_buf_get_lines(session.right_buf, 0, -1, false)[2], "TWO",
      "A second undo should then use native buffer undo")

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.right_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local binary_path = repo .. "/binary.bin"
    write_binary_file(binary_path, string.char(0, 1, 2, 3, 65, 66, 67, 68))
    git_test_command({ "add", "binary.bin" }, repo)
    commit_baseline(repo)
    write_binary_file(binary_path, string.char(0, 1, 2, 4, 65, 66, 67, 69))

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "binary.bin" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.git_binary_hex, true, "Binary left source should render as hex")
    assert_eq(loaded.right.git_binary_hex, true, "Binary right source should render as hex")
    assert_eq(loaded.left.display_numbers[1], "00000000", "Binary hex source should expose byte offsets")
    assert_eq(loaded.left.lines[1]:find("00 01 02 03", 1, true) ~= nil, true,
      "Binary left source should include baseline bytes")
    assert_eq(loaded.right.lines[1]:find("00 01 02 04", 1, true) ~= nil, true,
      "Binary right source should include changed bytes")
    assert_eq(queue.entries[1].content_kind, "binary", "Binary queue entry should be classified as binary")
    assert_eq(queue.entries[1].actions_enabled, false, "Binary queue entry should disable hunk actions")
  end

  do
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git_test_command({ "init" }, repo)
    write_repo_file(repo, "first.txt", { "first content" })

    local queue, err = git_mod.queue({ root = repo, mode = "all" }, config.git)
    assert_eq(err, nil, "Unborn repository queue should diff against the empty tree")
    assert_eq(#queue.entries, 1, "Unborn repository queue should include the untracked file")
    local loaded = select(1, queue.load(1))
    assert_eq(loaded.left.git_ref, "not tracked", "Unborn untracked left side should still identify not-tracked state")
    assert_eq(loaded.right.text, "first content\n", "Unborn untracked right side should read worktree content")
  end

  do
    local repo = make_git_repo()
    local queue = {
      kind = "git",
      root = repo,
      opts = { mode = "all" },
      entries = {
        { status = "U", raw_status = "U", path = "conflict.txt" },
        { status = "T", raw_status = "T", path = "typechange.txt" },
      },
    }
    local unmerged = select(1, git_mod.sources_for_entry(queue, 1))
    assert_eq(unmerged.left.empty_reason, "Git metadata entry", "Unmerged left side should render a metadata placeholder")
    assert_eq(unmerged.right.text, "Unmerged file: resolve conflicts outside DiffBandit\n",
      "Unmerged right side should explain the conflict state")
    assert_eq(queue.entries[1].actions_enabled, false, "Unmerged entries should disable hunk actions")

    local typechange = select(1, git_mod.sources_for_entry(queue, 2))
    assert_eq(typechange.right.text, "File type changed\n",
      "Typechange right side should explain metadata-only changes")
    assert_eq(queue.entries[2].actions_enabled, false, "Typechange entries should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "conflict.txt", { "one", "base", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "conflict.txt", { "one", "remote", "three" })
    git_test_command({ "commit", "-am", "remote change" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "conflict.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local change" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Test merge should produce a conflict")

    local entries = assert(git_mod.unmerged_entries(repo, {}))
    assert_eq(#entries, 1, "Unmerged entry scan should find the conflicted file")
    assert_eq(entries[1].path, "conflict.txt", "Unmerged entry should carry the conflicted path")

    local stages = assert((git_mod.conflict_stages(repo, "conflict.txt")))
    assert_eq(stages.base, "one\nbase\nthree\n", "Conflict base stage should read :1:")
    assert_eq(stages.local_text, "one\nlocal\nthree\n", "Conflict local stage should read :2:")
    assert_eq(stages.remote, "one\nremote\nthree\n", "Conflict remote stage should read :3:")

    local data = assert((merge_mod.load(repo, "conflict.txt", config)))
    assert_eq(#data.conflicts, 1, "Merge model should identify the overlapping edit conflict")
    assert_eq(to_text(data.result_lines), stages.base, "Merge result should initialize from base lines")

    local context = git_mod.merge_context(repo)
    assert_eq(context.operation, "merge", "Merge context should detect MERGE_HEAD")
    assert_eq(context.current, main_branch, "Merge context should detect the current branch")
    assert_eq(context.incoming:find("feature", 1, true) ~= nil, true,
      "Merge context should prefer a friendly incoming branch name")

    local result_buf = vim.api.nvim_create_buf(false, true)
    local fake_merge = setmetatable({
      config = config,
      path = "conflict.txt",
      conflicts = data.conflicts,
      current_conflict = 1,
      line_ending_warning = data.line_ending_warning,
      merge_context = context,
      result_buf = result_buf,
    }, { __index = merge_mod })
    local status_lines = fake_merge:build_status_lines()
    assert_eq(status_lines.left:find("local/current", 1, true) ~= nil, true,
      "Merge local status header should identify the current side")
    assert_eq(status_lines.result:find("merge result", 1, true) ~= nil, true,
      "Merge result status header should identify the editable result")
    assert_eq(status_lines.result:find("conflict 1/1", 1, true) ~= nil, true,
      "Merge result status header should include conflict position")
    assert_eq(status_lines.remote:find("remote/incoming", 1, true) ~= nil, true,
      "Merge remote status header should identify the incoming side")
    fake_merge.status_lines = {
      left = status_lines.left,
      center = status_lines.result,
      right = status_lines.remote,
    }
    status_lines = fake_merge:build_status_lines()
    assert_eq(status_lines.result:find("merge result", 1, true) ~= nil, true,
      "Merge status builder should not be shadowed by rendered status state")
    pcall(vim.api.nvim_buf_delete, result_buf, { force = true })

    local ok, commit_err = git_mod.commit(repo, "should fail", {})
    assert_eq(ok, false, "Commit should fail while unmerged entries remain")
    assert_eq(commit_err, "merge conflicts must be resolved before committing",
      "Commit failure should explain unresolved conflicts")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "pick.txt", { "one", "base", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "pick.txt", { "one", "remote", "three" })
    git_test_command({ "commit", "-am", "picked change" }, repo)
    local picked = vim.trim(git_test_command({ "rev-parse", "HEAD" }, repo))
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "pick.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local change" }, repo)
    local pick_code = git_status_command({ "cherry-pick", picked }, repo)
    assert_eq(pick_code ~= 0, true, "Cherry-pick fixture should conflict")
    local context = git_mod.merge_context(repo)
    assert_eq(context.operation, "cherry-pick", "Merge context should detect CHERRY_PICK_HEAD")
    assert_eq(context.incoming ~= nil and context.incoming ~= "", true,
      "Cherry-pick context should provide an incoming commit label")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "detached.txt", { "base" })
    commit_baseline(repo)
    git_test_command({ "checkout", "--detach" }, repo)
    local context = git_mod.merge_context(repo)
    assert_eq(context.current:find("detached", 1, true) == 1, true,
      "Merge context should describe detached HEAD")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "add.txt", { "one", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "add.txt", { "one", "remote", "three" })
    git_test_command({ "commit", "-am", "remote insertion" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "add.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local insertion" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Add/add fixture should conflict")
    local data = assert((merge_mod.load(repo, "add.txt", config)))
    assert_eq(data.conflicts[1].result_count, 0, "Add/add conflict should preserve a zero-count base range")
  end

  do
    local repo = make_git_repo()
    git_test_command({ "commit", "--allow-empty", "-m", "baseline" }, repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "add_add.txt", { "remote one", "remote two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "remote add/add" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "add_add.txt", { "local one", "local two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "local add/add" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Empty-base add/add fixture should conflict")
    local data = assert((merge_mod.load(repo, "add_add.txt", config)))
    assert_eq(#data.result_lines, 0, "Empty-base add/add result should start with no logical lines")
    assert_eq(data.conflicts[1].result_count, 0,
      "Empty-base add/add conflict should preserve a zero-count result range")

    local session = assert((merge_mod.start(data, config, {})))
    assert_eq(#session.result_lines, 0,
      "Empty editable result buffer should render as zero logical result lines")
    local result_marks = vim.api.nvim_buf_get_extmarks(session.result_buf, session.active_ns, 0, -1, { details = true })
    local has_delete_background = false
    local has_result_top_edge = false
    for _, mark in ipairs(result_marks) do
      local details = mark[4] or {}
      if mark[2] == 0 and details.line_hl_group == "DiffBanditDelete" then
        has_delete_background = true
      end
      local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
      if virt_text:find("▔", 1, true) then
        has_result_top_edge = true
      end
    end
    assert_eq(has_delete_background, false,
      "Zero-line merge result conflict should not paint a full center document row")
    assert_eq(has_result_top_edge, true,
      "Zero-line merge result conflict should render a top-edge marker across the center document")

    local function has_marker(buf, glyph)
      local marks = vim.api.nvim_buf_get_extmarks(buf, session.active_ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if virt_text == glyph then
          return true
        end
      end
      return false
    end

    assert_eq(has_marker(session.local_num_buf, "◤"), true,
      "Zero-line merge result conflict should mark the local/source gutter edge")
    assert_eq(has_marker(session.remote_num_buf, "◥"), true,
      "Zero-line merge result conflict should mark the remote/source gutter edge with a mirrored triangle")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_left_num_buf, session.active_ns, 0, -1, {}) == 0, true,
      "Zero-line merge result conflict should not cover the left result line-number pane")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_right_num_buf, session.active_ns, 0, -1, {}) == 0, true,
      "Zero-line merge result conflict should not cover the right result line-number pane")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.local_result_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Zero-line merge result conflict should render the local/result connector top edge")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_remote_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Zero-line merge result conflict should render the result/remote connector top edge")
    assert_eq(session:accept("local"), true, "Accepting the local side should update the merge result")
    assert_eq(#session.result_lines, 2, "Accepting local should render accepted result lines")
    assert_eq(has_marker(session.local_num_buf, "◤"), false,
      "Accepted local result should remove the zero-line local/source triangle")
    vim.api.nvim_win_call(session.result_win, function()
      vim.cmd("silent! undo")
    end)
    session:render()
    assert_eq(#session.result_lines, 0, "Undo after accept should restore an empty logical result")
    assert_eq(has_marker(session.local_num_buf, "◤"), true,
      "Undo after accept should restore the zero-line local/source triangle")
    assert_eq(has_marker(session.remote_num_buf, "◥"), true,
      "Undo after accept should restore the zero-line remote/source triangle")
    assert_eq(session:accept("remote"), true, "Accepting the remote side should update the merge result")
    assert_eq(#session.result_lines, 2, "Accepting remote should render accepted result lines")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_buf, session.active_ns, 0, -1, {}) == 0, true,
      "Accepted remote result should not receive merge active-row overlays")

    local function has_hl(buf, ns, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if details.hl_group == hl or details.line_hl_group == hl then
          return true
        end
      end
      return false
    end

    local function has_hl_on_row(buf, ns, row, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row and (details.hl_group == hl or details.line_hl_group == hl) then
          return true
        end
      end
      return false
    end

    local function has_hl_span(buf, ns, row, hl, start_col, end_col)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row
            and mark[3] == start_col
            and details.end_col == end_col
            and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    assert_eq(has_hl(session.result_buf, session.local_result_session.extmark_ns, "DiffBanditChangeRight"), true,
      "Accepted remote result should keep the local/result change background")
    assert_eq(has_hl(session.result_buf, session.local_result_session.extmark_ns, "DiffBanditChangeEmphasis"), true,
      "Accepted remote result should keep word-level change emphasis")
    assert_eq(has_hl(session.result_buf, session.local_result_session.extmark_ns, "DiffBanditAdd"), false,
      "Accepted remote replacement word should not split into an added suffix")
    assert_eq(has_hl_on_row(session.result_buf, session.local_result_session.extmark_ns, 0, "DiffBanditChangeEmphasis"), true,
      "Accepted remote first result row should keep word-level change emphasis")
    assert_eq(has_hl_on_row(session.result_buf, session.local_result_session.extmark_ns, 1, "DiffBanditChangeEmphasis"), true,
      "Accepted remote second result row should keep word-level change emphasis")
    assert_eq(has_hl_span(session.result_buf, session.local_result_session.extmark_ns, 0, "DiffBanditChangeEmphasis", 0, 6), true,
      "Accepted remote first result row should emphasize the full replacement word")
    assert_eq(has_hl_span(session.result_buf, session.local_result_session.extmark_ns, 1, "DiffBanditChangeEmphasis", 0, 6), true,
      "Accepted remote second result row should emphasize the full replacement word")
    assert_eq(has_hl(session.result_buf, session.result_remote_session.extmark_ns, "DiffBanditContext"), false,
      "Accepted remote result should not get context background from the matching remote/result pair")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    -- Mid-document zero-range conflict: both sides insert different lines at
    -- the same interior point, so the conflict region has zero result lines
    -- while the result document itself is non-empty. The ▔ overlay is
    -- reserved for the empty result document — here it would cover (and hide)
    -- a real content row; the pair renderers' delete routes mark the spot.
    local repo = make_git_repo()
    write_repo_file(repo, "mid_add.txt", { "top", "alpha = 1", "bottom" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "mid_add.txt", { "top", "alpha = 1", "remote extra", "bottom" })
    git_test_command({ "commit", "-am", "remote mid insertion" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "mid_add.txt", { "top", "alpha = 1", "local extra", "bottom" })
    git_test_command({ "commit", "-am", "local mid insertion" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Mid-document add/add fixture should conflict")
    local session = assert((merge_mod.start(assert((merge_mod.load(repo, "mid_add.txt", config))), config, {})))
    assert_eq(#session.result_lines > 0, true, "Mid-document conflict should keep a non-empty result document")
    local function overlay_glyphs(buf)
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, session.active_ns, 0, -1, { details = true })) do
        local details = mark[4] or {}
        local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if virt_text:find("▔", 1, true) or virt_text == "◤" or virt_text == "◥" then
          found[#found + 1] = virt_text
        end
      end
      return found
    end
    assert_eq(#overlay_glyphs(session.result_buf), 0,
      "Non-empty result must not draw the zero-range ▔ overlay over a real content row")
    assert_eq(#overlay_glyphs(session.local_num_buf), 0,
      "Non-empty result must not draw the zero-range local gutter marker")
    assert_eq(#overlay_glyphs(session.remote_num_buf), 0,
      "Non-empty result must not draw the zero-range remote gutter marker")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    -- Delete/modify conflict: the shared result content pane must prefer the
    -- surviving side's change diff (band + inner emphasis) over the deleted
    -- side's add band, which stays available below it as a range mark.
    local repo = make_git_repo()
    write_repo_file(repo, "delete_vs_edit.txt", { "shared header line", "shared body line" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "delete_vs_edit.txt", { "shared header line", "incoming body line" })
    git_test_command({ "commit", "-am", "incoming edits file" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    git_test_command({ "rm", "delete_vs_edit.txt" }, repo)
    git_test_command({ "commit", "-m", "local deletes file" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Delete-vs-edit fixture should conflict")
    local session = assert((merge_mod.start(assert((merge_mod.load(repo, "delete_vs_edit.txt", config))), config, {})))
    local local_add_range, local_add_line_hl, local_add_priority
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.result_buf,
      session.local_result_session.extmark_ns, 0, -1, { details = true })) do
      local details = mark[4] or {}
      if details.hl_group == "DiffBanditAdd" then
        local_add_range = true
        local_add_priority = details.priority
      end
      if details.line_hl_group == "DiffBanditAdd" then
        local_add_line_hl = true
      end
    end
    assert_eq(local_add_range, true,
      "Deleted-side pair should paint the shared result add band as a range mark")
    assert_eq(local_add_line_hl or false, false,
      "Deleted-side pair must not paint an add line highlight in the shared result (line highlights beat range priorities)")
    local remote_change_priority
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.result_buf,
      session.result_remote_session.extmark_ns, 0, -1, { details = true })) do
      local details = mark[4] or {}
      if details.hl_group == "DiffBanditChangeRight" then
        remote_change_priority = details.priority
      end
    end
    assert_eq(type(local_add_priority) == "number" and type(remote_change_priority) == "number"
      and local_add_priority < remote_change_priority, true,
      "Shared result change band must outrank the other pair's add band on contested rows")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    git_test_command({ "commit", "--allow-empty", "-m", "baseline" }, repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "feature" }, repo)
    write_repo_file(repo, "add_add.txt", { "remote one", "remote two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "remote add/add" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "add_add.txt", { "local one", "local two" })
    git_test_command({ "add", "add_add.txt" }, repo)
    git_test_command({ "commit", "-m", "local add/add" }, repo)
    local merge_code = git_status_command({ "merge", "feature" }, repo)
    assert_eq(merge_code ~= 0, true, "Panel resolve add/add fixture should conflict")
    local worktree_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_option_value("swapfile", false, { buf = worktree_buf })
    vim.api.nvim_buf_set_name(worktree_buf, repo .. "/add_add.txt")
    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "add_add.txt" } }, config.git)))
    local data = assert((merge_mod.load(repo, "add_add.txt", config)))
    local session = assert((merge_mod.start(data, config, {
      panel = true,
      queue = queue,
      queue_index = 1,
      panel_initial_selection = 1,
    })))

    assert_eq(session.panel.rows[1].text, "▾ Merge Conflicts  1 files",
      "Merge panel should initially list the unresolved add/add conflict")
    assert_eq(session:accept("remote"), true, "Accepting incoming add/add content should update the result")
    assert_eq(session:resolve(), true, "Resolving add/add should write and stage the result")
    assert_eq(vim.trim(git_test_command({ "ls-files", "-u", "--", "add_add.txt" }, repo)), "",
      "Resolved add/add file should no longer have unmerged index stages")
    local cached = git_test_command({ "diff", "--cached", "--", "add_add.txt" }, repo)
    assert_eq(cached:find("+remote one", 1, true) ~= nil, true,
      "Resolved add/add file should stage the accepted incoming content")
    assert_eq(session.panel.rows[1].text, "▾ Changes  1 files",
      "Merge panel should remove resolved conflicts and show the staged changed file")
    assert_eq(session.panel.rows[2].entry.path, "add_add.txt",
      "Merge panel should keep the resolved file selected in the refreshed queue")
    assert_eq(session.panel.stage_states[session.file_queue_index], "staged",
      "Merge panel should mark the resolved changed file as staged")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
    pcall(vim.api.nvim_buf_delete, worktree_buf, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "delete_vs_modify.txt", { "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "delete_vs_modify.txt", { "incoming modified" })
    git_test_command({ "commit", "-am", "incoming modifies file" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    git_test_command({ "rm", "delete_vs_modify.txt" }, repo)
    git_test_command({ "commit", "-m", "local deletes file" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Delete-vs-modify fixture should conflict")
    local data = assert((merge_mod.load(repo, "delete_vs_modify.txt", config)))
    assert_eq(data.has_local, false, "Delete-vs-modify fixture should mark local side as deleted")
    local session = assert((merge_mod.start(data, config, {})))
    assert_eq(session:accept("local"), true, "Accepting the local deleted side should succeed")
    assert_eq(session.delete_result, true, "Accepting local deletion should mark the merge result as file deletion")
    assert_eq(session:resolve(), true, "Resolving local deletion should write the deleted result")
    assert_eq(vim.fn.filereadable(repo .. "/delete_vs_modify.txt"), 0,
      "Resolving local deletion should remove the worktree file")
    assert_eq(vim.trim(git_test_command({ "ls-files", "-u", "--", "delete_vs_modify.txt" }, repo)), "",
      "Resolving local deletion should clear unmerged stages")
    assert_eq(vim.trim(git_test_command({ "ls-files", "--", "delete_vs_modify.txt" }, repo)), "",
      "Resolving local deletion should remove the file from the index")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "modify_vs_delete.txt", { "base" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    git_test_command({ "rm", "modify_vs_delete.txt" }, repo)
    git_test_command({ "commit", "-m", "incoming deletes file" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "modify_vs_delete.txt", { "local modified" })
    git_test_command({ "commit", "-am", "local modifies file" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Modify-vs-delete fixture should conflict")
    local data = assert((merge_mod.load(repo, "modify_vs_delete.txt", config)))
    assert_eq(data.has_remote, false, "Modify-vs-delete fixture should mark remote side as deleted")
    local session = assert((merge_mod.start(data, config, {})))
    assert_eq(session:accept("remote"), true, "Accepting the remote deleted side should succeed")
    assert_eq(session.delete_result, true, "Accepting remote deletion should mark the merge result as file deletion")
    assert_eq(session:resolve(), true, "Resolving remote deletion should write the deleted result")
    assert_eq(vim.fn.filereadable(repo .. "/modify_vs_delete.txt"), 0,
      "Resolving remote deletion should remove the worktree file")
    assert_eq(vim.trim(git_test_command({ "ls-files", "-u", "--", "modify_vs_delete.txt" }, repo)), "",
      "Resolving remote deletion should clear unmerged stages")
    local cached_status = vim.trim(git_test_command({ "diff", "--cached", "--name-status", "--", "modify_vs_delete.txt" }, repo))
    assert_eq(cached_status, "D\tmodify_vs_delete.txt",
      "Resolving remote deletion should stage the deletion against HEAD")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "mixed_non_conflicting.txt",
      base_lines = {},
      local_lines = { "local non-conflicting source" },
      remote_lines = { "remote non-conflicting source" },
      result_lines = {},
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function has_marker(buf, glyph)
      local marks = vim.api.nvim_buf_get_extmarks(buf, session.active_ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        local virt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if virt_text == glyph then
          return true
        end
      end
      return false
    end

    assert_eq(has_marker(session.local_num_buf, "◤"), true,
      "Pair-level zero delete should mark the local/source gutter edge")
    assert_eq(has_marker(session.remote_num_buf, "◥"), true,
      "Pair-level zero delete should mark the remote/source gutter edge with a mirrored triangle")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.local_result_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Pair-level zero delete should render the local/result connector top edge")
    assert_eq(#vim.api.nvim_buf_get_extmarks(session.result_remote_connector_buf, session.active_ns, 0, -1, {}) > 0, true,
      "Pair-level zero delete should render the result/remote connector top edge")
    vim.api.nvim_set_current_win(session.local_win)
    vim.api.nvim_win_set_cursor(session.local_win, { 1, 0 })
    assert_eq(session:accept("local"), true, "Accepting a local pair hunk should update the merge result")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "local non-conflicting source", "Local pair hunk accept should copy the local source into the result")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, {})
    session:render()
    vim.api.nvim_set_current_win(session.remote_win)
    vim.api.nvim_win_set_cursor(session.remote_win, { 1, 0 })
    assert_eq(session:accept("remote"), true, "Accepting a remote pair hunk should update the merge result")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "remote non-conflicting source", "Remote pair hunk accept should copy the remote source into the result")
	    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
	    session:close()
	  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "a_changed.txt", { "base changed" })
    write_repo_file(repo, "b_conflict.txt", { "one", "base", "three" })
    commit_baseline(repo)
    local main_branch = vim.trim(git_test_command({ "branch", "--show-current" }, repo))
    git_test_command({ "checkout", "-b", "incoming" }, repo)
    write_repo_file(repo, "b_conflict.txt", { "one", "incoming", "three" })
    git_test_command({ "commit", "-am", "incoming conflict" }, repo)
    git_test_command({ "checkout", main_branch }, repo)
    write_repo_file(repo, "b_conflict.txt", { "one", "local", "three" })
    git_test_command({ "commit", "-am", "local conflict" }, repo)
    local merge_code = git_status_command({ "merge", "incoming" }, repo)
    assert_eq(merge_code ~= 0, true, "Panel preview fixture should conflict")
    write_repo_file(repo, "a_changed.txt", { "worktree changed" })
    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    assert_eq(queue.entries[1].path, "a_changed.txt", "Panel preview fixture should sort the changed file first")
    assert_eq(queue.entries[2].path, "b_conflict.txt", "Panel preview fixture should sort the conflict second")
    local loaded = assert((queue.load(1)))
    queue.index = 1
    local session = assert((Session.start({ left = loaded.left, right = loaded.right }, config, {
      queue = queue,
      panel = true,
      panel_initial_selection = 1,
      panel_message_lines = { "draft merge commit" },
    })))
    state_mod.register(session)
    vim.api.nvim_set_current_win(session.panel.nav_win)
    assert_eq(session:open_merge_file(2, { preserve_focus = true }), true,
      "Panel preview should open a conflict entry from a normal changed-file diff")
    local merge_session = state_mod.sessions[vim.api.nvim_get_current_tabpage()]
    assert_eq(merge_session ~= nil and merge_session.path, "b_conflict.txt",
      "Panel preview should switch to the requested merge conflict")
    assert_eq(merge_session.panel ~= nil and merge_session.panel.visible, true,
      "Panel preview should keep the commit panel visible in the merge resolver")
    assert_eq(vim.api.nvim_get_current_win(), merge_session.panel.nav_win,
      "Panel preview should keep focus in the panel navigation window")
    assert_eq(merge_session.panel.message_lines[1], "draft merge commit",
      "Panel preview should carry commit message text into the merge resolver")
    merge_session:close()
    session:close()
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "panel_conflict.txt",
      base_lines = { "base" },
      local_lines = { "local" },
      remote_lines = { "remote" },
      result_lines = { "base" },
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local queue = {
      kind = "git",
      root = repo,
      index = 1,
      entries = {
        { status = "U", raw_status = "U", kind = "unmerged", path = "panel_conflict.txt" },
      },
    }
    local session = assert((merge_mod.start(data, config, {
      panel = true,
      queue = queue,
      panel_initial_selection = 1,
    })))
    local original_nav_win = session.panel and session.panel.nav_win
    vim.api.nvim_set_current_win(session.result_win)
    assert_eq(session:focus_commit_panel_for_current_file(), true,
      "Merge focus-panel action should focus the attached panel")
    assert_eq(vim.api.nvim_get_current_win(), original_nav_win,
      "Merge focus-panel action should return to the existing panel window")

    local function enter_and_wait(target_win)
      vim.api.nvim_set_current_win(target_win)
      vim.wait(100, function()
        return vim.api.nvim_get_current_win() ~= target_win
      end, 5)
      return vim.api.nvim_get_current_win()
    end

    vim.api.nvim_set_current_win(session.result_win)
    assert_eq(enter_and_wait(session.result_left_num_win), session.local_win,
      "Merge focus guard should move left through result gutters to the local pane")
    assert_eq(enter_and_wait(session.local_num_win), session.result_win,
      "Merge focus guard should move right through local gutters to the result pane")
    assert_eq(enter_and_wait(session.result_right_num_win), session.remote_win,
      "Merge focus guard should move right through result gutters to the remote pane")
    assert_eq(enter_and_wait(session.remote_num_win), session.result_win,
      "Merge focus guard should move left through remote gutters to the result pane")

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "mixed_non_conflicting.txt",
      base_lines = { "kept" },
      local_lines = { "kept", "local only" },
      remote_lines = { "kept", "remote only" },
      result_lines = { "kept" },
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))
    local local_marks = vim.api.nvim_buf_get_extmarks(session.local_num_buf, session.active_ns, 0, -1, { details = true })
    local remote_marks = vim.api.nvim_buf_get_extmarks(session.remote_num_buf, session.active_ns, 0, -1, { details = true })
    assert_eq(#local_marks, 0, "Pair-level non-top zero delete should not synthesize a local/source triangle")
    assert_eq(#remote_marks, 0, "Pair-level non-top zero delete should not synthesize a remote/source triangle")
    vim.api.nvim_set_current_win(session.local_win)
    vim.api.nvim_win_set_cursor(session.local_win, { 1, 0 })
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should visit non-conflicting local pair hunks")
    assert_eq(vim.api.nvim_win_get_cursor(session.local_win)[1], 2,
      "Merge navigation should move to the next local pair hunk")
    local selected = session:selected_item()
    assert_eq(selected and selected.local_hunk ~= nil, true,
      "Merge navigation should include the local pair hunk in the grouped stop")
    assert_eq(selected and selected.remote_hunk ~= nil, true,
      "Merge navigation should include the remote pair hunk in the grouped stop")
    local status_lines = session:build_status_lines()
    assert_eq(status_lines.result_action:find(">> L", 1, true) ~= nil, true,
      "Merge result header should describe the grouped local action compactly")
    assert_eq(status_lines.result_action:find("<< I", 1, true) ~= nil, true,
      "Merge result header should describe the grouped incoming action compactly")
    assert_eq(session:goto_next_hunk(), true, "Merge navigation at the final grouped hunk should stay on the grouped hunk")
    assert_eq(session:selected_item() and session:selected_item().key, selected and selected.key,
      "Merge navigation should not create a second stop for the same result range")
    assert_eq(session:accept("remote"), true, "Accepting the remote side of the grouped hunk should succeed")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "kept\nremote only", "Grouped remote pair hunk accept should insert the remote line into result")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, { "kept" })
    session.selected_pair_hunk = nil
    session:render()
    vim.api.nvim_set_current_win(session.local_win)
    vim.api.nvim_win_set_cursor(session.local_win, { 1, 0 })
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should return to the local pair hunk")
    assert_eq(session:accept("local"), true, "Accepting the navigated non-conflicting local hunk should succeed")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "kept\nlocal only", "Grouped local pair hunk accept should insert the local line into result")
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, { "kept" })
    session.selected_pair_hunk = nil
    session:render()
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should return to the grouped pair hunk")
    assert_eq(session:accept("both"), true, "Accepting both sides of the grouped non-conflicting hunk should succeed")
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false), "\n"),
      "kept\nlocal only\nremote only", "Grouped both-side accept should insert local and remote lines into result")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local left = read_file(root .. "/tests/files/left_mixed.txt")
    local right = read_file(root .. "/tests/files/right_mixed.txt")
    local data = {
      root = repo,
      path = "mixed_non_conflicting.txt",
      base_lines = {},
      local_lines = left,
      remote_lines = left,
      result_lines = right,
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function has_glyph_at(buf, ns, row, glyph)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        local text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
        if mark[2] == row - 1 and text == glyph then
          return true
        end
      end
      return false
    end

    local function has_semantic_bg_from_col_zero(buf, ns, row, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row - 1 and mark[3] == 0 and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    local function has_semantic_bg_span(buf, ns, row, hl, col, end_col)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row - 1
            and mark[3] == col
            and details.end_col == end_col
            and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    assert_eq(has_glyph_at(session.result_left_num_buf, session.local_result_session.path_ns, 7, "◢"), true,
      "Mixed result left gutter should draw the lower change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_left_num_buf, session.local_result_session.path_ns, 9, "◥"), true,
      "Mixed result left gutter should draw the upper change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_left_num_buf, session.local_result_session.path_ns, 6, "◢"), false,
      "Mixed result left gutter change wedge should not shift one row up")
    assert_eq(has_glyph_at(session.result_right_num_buf, session.result_remote_session.path_ns, 7, "◣"), true,
      "Mixed result right gutter should draw the mirrored lower change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_right_num_buf, session.result_remote_session.path_ns, 9, "◤"), true,
      "Mixed result right gutter should draw the mirrored upper change wedge on the compact result row")
    assert_eq(has_glyph_at(session.result_right_num_buf, session.result_remote_session.path_ns, 8, "◤"), false,
      "Mixed result right gutter change wedge should not shift one row up")
    assert_eq(has_semantic_bg_from_col_zero(session.result_right_num_buf, session.result_remote_session.ns, 7,
      "DiffBanditConnectorChange"), true,
      "Mixed result right number gutter should color through the connector-side spacer on overlap rows")
    assert_eq(has_semantic_bg_from_col_zero(session.result_right_num_buf, session.result_remote_session.ns, 8,
      "DiffBanditConnectorChange"), false,
      "Mixed result right number gutter should not extend the change band over the adjacent add chunk")
    assert_eq(has_semantic_bg_span(session.result_right_num_buf, session.result_remote_session.ns, 8,
      "DiffBanditConnectorAdd", 0, session.result_remote_session:right_triangle_col()), true,
      "Mixed result right number gutter should color the adjacent add chunk with the add band")
    -- With the adjacent add routed as its own chunk, the change band no
    -- longer overlaps the add rows, so the connector-side spacer stays
    -- uncolored and the change mark starts after it.
    assert_eq(has_semantic_bg_from_col_zero(session.remote_num_buf, session.result_remote_session.ns, 8,
      "DiffBanditConnectorChange"), false,
      "Mixed remote number gutter should keep the spacer uncolored without band overlap")
    assert_eq(has_semantic_bg_span(session.remote_num_buf, session.result_remote_session.ns, 8,
      "DiffBanditConnectorChange", 1, 0), true,
      "Mixed remote number gutter should still color the change row after the spacer")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local function numbered_lines(changed)
      local lines = {}
      for index = 1, 80 do
        lines[index] = changed and changed[index] or ("line " .. tostring(index))
      end
      return lines
    end
    local data = {
      root = repo,
      path = "lower_merge_hunk.txt",
      base_lines = numbered_lines(),
      local_lines = numbered_lines({ [20] = "local line 20", [60] = "local line 60" }),
      remote_lines = numbered_lines(),
      result_lines = numbered_lines(),
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function topline(win)
      local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
      return ok and view and view.topline or 1
    end

    vim.api.nvim_set_current_win(session.result_win)
    vim.api.nvim_win_set_cursor(session.result_win, { 1, 0 })
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should jump to the lower pair hunk")
    assert_eq(session:selected_item() and session:selected_item().local_index, 1,
      "Merge hunk navigation should start at the first pair hunk")
    assert_eq(topline(session.local_win) > 1, true,
      "Merge hunk navigation should scroll the local source pane")
    assert_eq(topline(session.result_win) > 1, true,
      "Merge hunk navigation should scroll the center result pane")
    assert_eq(topline(session.remote_win) > 1, true,
      "Merge hunk navigation should scroll the remote source pane")
    assert_eq(topline(session.local_num_win), topline(session.local_win),
      "Merge local line-number pane should follow the local source viewport")
    assert_eq(topline(session.result_left_num_win), topline(session.result_win),
      "Merge result left line-number pane should follow the result viewport")
    assert_eq(topline(session.result_right_num_win), topline(session.result_win),
      "Merge result right line-number pane should follow the result viewport")
    assert_eq(topline(session.remote_num_win), topline(session.remote_win),
      "Merge remote line-number pane should follow the remote source viewport")
    assert_eq(topline(session.local_result_connector_win), topline(session.local_win),
      "Merge local/result connector should follow the local source viewport")
    assert_eq(topline(session.result_remote_connector_win), topline(session.remote_win),
      "Merge result/remote connector should follow the remote source viewport")
    assert_eq(session:goto_next_hunk(), true, "Merge navigation should move to the second pair hunk")
    assert_eq(session:selected_item() and session:selected_item().local_index, 2,
      "Merge hunk navigation should select the second pair hunk before document-top reset")
    session:goto_document_edge("bottom")
    assert_eq(vim.api.nvim_win_get_cursor(session.local_win)[1], 80,
      "Merge document-bottom navigation should move the local cursor to EOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.result_win)[1], 80,
      "Merge document-bottom navigation should move the result cursor to EOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.remote_win)[1], 80,
      "Merge document-bottom navigation should move the remote cursor to EOF")
    assert_eq(topline(session.local_result_connector_win), topline(session.local_win),
      "Merge document-bottom navigation should keep the local/result connector viewport synced")
    assert_eq(topline(session.result_remote_connector_win), topline(session.remote_win),
      "Merge document-bottom navigation should keep the result/remote connector viewport synced")
    session:goto_document_edge("top")
    assert_eq(vim.api.nvim_win_get_cursor(session.local_win)[1], 1,
      "Merge document-top navigation should move the local cursor to BOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.result_win)[1], 1,
      "Merge document-top navigation should move the result cursor to BOF")
    assert_eq(vim.api.nvim_win_get_cursor(session.remote_win)[1], 1,
      "Merge document-top navigation should move the remote cursor to BOF")
    assert_eq(session:goto_next_hunk(), true,
      "Merge hunk navigation after document-top should restart at the first pair hunk")
    assert_eq(session:selected_item() and session:selected_item().local_index, 1,
      "Merge document-top navigation should reset the selected hunk boundary")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local repo = make_git_repo()
    local function large_lines(overrides)
      local lines = {}
      for index = 1, 2000 do
        lines[index] = overrides and overrides[index] or ("large merge line " .. tostring(index))
      end
      return lines
    end
    local data = {
      root = repo,
      path = "large_merge.txt",
      base_lines = large_lines(),
      local_lines = large_lines({
        [750] = "large local line 750",
        [1500] = "large local line 1500",
      }),
      remote_lines = large_lines({
        [1500] = "large incoming line 1500",
      }),
      result_lines = large_lines(),
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }

    local original_build = diff_pair_mod.build
    local build_count = 0
    diff_pair_mod.build = function(...)
      build_count = build_count + 1
      return original_build(...)
    end

    local ok, err = pcall(function()
      local session = assert((merge_mod.start(data, config, {})))
      assert_eq(build_count, 2, "Large merge initial render should build the two source/result pairs")
      session:render()
      assert_eq(build_count, 2, "Large merge unchanged render should reuse existing pair models")
      vim.api.nvim_win_call(session.result_win, function()
        vim.api.nvim_win_set_cursor(session.result_win, { 1000, 0 })
        vim.cmd("normal! zt")
      end)
      session:render()
      assert_eq(build_count, 2, "Large merge viewport-only render should not rebuild pair diffs")
      vim.api.nvim_buf_set_lines(session.result_buf, 999, 1000, false, { "large edited result line 1000" })
      session:render()
      assert_eq(build_count, 4, "Large merge content edit should rebuild both pair models once")
      session:render()
      assert_eq(build_count, 4, "Large merge stale follow-up render should not rebuild pair models")
      assert_eq(vim.api.nvim_buf_get_lines(session.local_buf, 999, 1000, false)[1],
        "large merge line 1000", "Large merge result edits should not mutate the local source")
      assert_eq(vim.api.nvim_buf_get_lines(session.remote_buf, 999, 1000, false)[1],
        "large merge line 1000", "Large merge result edits should not mutate the remote source")
      pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
      session:close()
    end)
    diff_pair_mod.build = original_build
    if not ok then
      error(err)
    end
  end

  do
    local repo = make_git_repo()
    local data = {
      root = repo,
      path = "accepted_remote_with_insert.txt",
      base_lines = {},
      local_lines = { "one", "two", "three", "four" },
      remote_lines = { "one", "insert", "two", "THREE", "four" },
      result_lines = { "one", "insert", "two", "THREE", "four" },
      conflicts = {},
      non_conflicting = {},
      local_hunks = {},
      remote_hunks = {},
    }
    local session = assert((merge_mod.start(data, config, {})))

    local function has_number_hl(buf, ns, row, hl)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local details = mark[4] or {}
        if mark[2] == row and details.hl_group == hl then
          return true
        end
      end
      return false
    end

    assert_eq(has_number_hl(session.local_num_buf, session.local_result_session.ns, 2, "DiffBanditConnectorChange"),
      true, "Source number pane should mark the compact source row for a change after a result-side add")
    assert_eq(has_number_hl(session.local_num_buf, session.local_result_session.ns, 3, "DiffBanditConnectorChange"),
      false, "Source number pane change background should not lag one row after a result-side add")
    assert_eq(has_number_hl(session.result_left_num_buf, session.local_result_session.ns, 1, "DiffBanditConnectorAdd"),
      true, "Result number pane should keep the accepted inserted row add background")
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
    session:close()
  end

  do
    local mirrored = setmetatable({ mirror_connector_sides = true }, Session)
    assert_eq(mirrored:display_glyph("◤"), "◥", "Mirrored sessions should flip upper-left triangles")
    assert_eq(mirrored:display_glyph("◥"), "◤", "Mirrored sessions should flip upper-right triangles")
  end

  do
    local left = { "one", "two", "four" }
    local right = { "one", "TWO", "three", "four" }
    local pair = assert((diff_pair_mod.build(left, right, config)))
    local hunks = assert((diff.compute_hunks(to_text(left), to_text(right), config.diff)))
    local direct = view.build(left, right, hunks, config)
    assert_eq(table.concat(pair.view.connectors, "\n"), table.concat(direct.connectors, "\n"),
      "Diff pair renderer should preserve the existing view connector model")

    local base = { "one", "base", "three" }
    local local_lines = { "one", "local", "three" }
    local remote_lines = { "one", "remote", "three" }
    local initial_left = assert((diff_pair_mod.build(local_lines, base, config)))
    local initial_right = assert((diff_pair_mod.build(base, remote_lines, config)))
    local edited = { "one", "manual", "three" }
    local edited_left = assert((diff_pair_mod.build(local_lines, edited, config)))
    local edited_right = assert((diff_pair_mod.build(edited, remote_lines, config)))
    assert_eq(#initial_left.hunks > 0, true, "Initial local/result pair should have a diff")
    assert_eq(#initial_right.hunks > 0, true, "Initial result/remote pair should have a diff")
    assert_eq(edited_left.right_lines[2], "manual", "Edited result should update the left pair result side")
    assert_eq(edited_right.left_lines[2], "manual", "Edited result should update the right pair result side")
    assert_eq(local_lines[2], "local", "Local source lines should remain unchanged by result edits")
    assert_eq(remote_lines[2], "remote", "Remote source lines should remain unchanged by result edits")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "renamed_old.txt", { "old name line" })
    commit_baseline(repo)
    git_test_command({ "mv", "renamed_old.txt", "renamed_new.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].status, "R", "Renamed file should classify as rename")
    assert_eq(loaded.left.git_relpath, "renamed_old.txt", "Rename left source should use old path")
    assert_eq(loaded.right.git_relpath, "renamed_new.txt", "Rename right source should use new path")
    local lines = status_mod.build({
      config = config,
      left = loaded.left,
      right = loaded.right,
      file_queue = queue,
      file_queue_index = 1,
      current_chunk = 1,
      view = { chunks = { {} } },
      staged_chunk_states = {},
    })
    assert_eq(lines.center:find("renamed_old.txt %-%> renamed_new.txt") ~= nil, true,
      "Rename status should show path direction")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "copy_source.txt", { "copy base" })
    commit_baseline(repo)
    write_repo_file(repo, "copy_dest.txt", { "copy base" })
    git_test_command({ "add", "copy_dest.txt" }, repo)

    local queue = assert((git_mod.queue({
      root = repo,
      mode = "staged",
      find_copies = true,
    }, config.git)))
    assert_eq(queue.entries[1].status, "C", "Opt-in copy detection should classify copied files")
    queue.load(1)
    assert_eq(queue.entries[1].actions_enabled, false, "Copied entries should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mode_only.sh", { "#!/bin/sh", "echo mode" })
    commit_baseline(repo)
    git_test_command({ "update-index", "--chmod=+x", "mode_only.sh" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "staged", pathspecs = { "mode_only.sh" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].content_kind, "metadata", "Mode-only diff should classify as metadata")
    assert_eq(loaded.right.text:find("mode change", 1, true) ~= nil, true,
      "Mode-only diff should show Git summary text")
    assert_eq(queue.entries[1].actions_enabled, false, "Mode-only metadata should disable hunk actions")
  end

  do
    local repo = make_git_repo()
    local uv = vim.uv or vim.loop
    assert(uv.fs_symlink("old-target.txt", repo .. "/link.txt"))
    git_test_command({ "add", "link.txt" }, repo)
    commit_baseline(repo)
    assert(os.remove(repo .. "/link.txt"))
    assert(uv.fs_symlink("new-target.txt", repo .. "/link.txt"))

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "link.txt" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].content_kind, "symlink", "Symlink diff should classify as symlink")
    assert_eq(loaded.left.text, "symlink -> old-target.txt\n", "Symlink left side should show old target")
    assert_eq(loaded.right.text, "symlink -> new-target.txt\n", "Symlink right side should show new target")
    assert_eq(queue.entries[1].actions_enabled, false, "Symlink actions should be disabled")
  end

  do
    local repo = make_git_repo()
    local old_oid = "1111111111111111111111111111111111111111"
    local new_oid = "2222222222222222222222222222222222222222"
    git_test_command({ "update-index", "--add", "--cacheinfo", "160000," .. old_oid .. ",vendor/lib" }, repo)
    git_test_command({ "commit", "-m", "submodule baseline" }, repo)
    git_test_command({ "update-index", "--add", "--cacheinfo", "160000," .. new_oid .. ",vendor/lib" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "staged", pathspecs = { "vendor/lib" } }, config.git)))
    local loaded = select(1, queue.load(1))
    assert_eq(queue.entries[1].content_kind, "submodule", "Gitlink diff should classify as submodule")
    assert_eq(loaded.right.text:find("Submodule", 1, true) ~= nil, true,
      "Submodule diff should show a metadata summary")
    assert_eq(queue.entries[1].actions_enabled, false, "Submodule actions should be disabled")
  end

  do
    local dump = hex_mod.dump(string.rep("a", 12), {
      max_bytes = 8,
      bytes_per_row = 4,
    })
    assert_eq(dump.truncated, true, "Large binary dump should mark truncation")
    assert_eq(dump.lines[#dump.lines], "[DiffBandit: hex view truncated at 8 of 12 bytes]",
      "Large binary dump should include truncation notice")
  end

  local function make_action_session(queue)
    local loaded = select(1, queue.load(queue.index or 1))
    local hunks, err = diff.compute_hunks(loaded.left.text, loaded.right.text, config.diff)
    assert_eq(err, nil, "Action session diff should compute")
    local v = view.build(loaded.left.lines, loaded.right.lines, hunks, config)
    local fake = setmetatable({
      config = config,
      file_queue = queue,
      file_queue_index = queue.index or 1,
      left = loaded.left,
      right = loaded.right,
      hunks = hunks,
      view = v,
      current_chunk = v.chunks[1] and 1 or 0,
    }, Session)
    function fake:replace_sources(sources, opts)
      local next_hunks, next_err = diff.compute_hunks(sources.left.text, sources.right.text, config.diff)
      assert_eq(next_err, nil, "Action refresh diff should compute")
      self.left = sources.left
      self.right = sources.right
      self.hunks = next_hunks
      self.view = view.build(sources.left.lines, sources.right.lines, next_hunks, config)
      self.current_chunk = self.view.chunks[1] and math.min((opts and opts.preferred_chunk) or 1, #self.view.chunks) or 0
      return true, nil
    end
    return fake
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "stage.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "stage.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "stage.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "Stage hunk action should not error")
    assert_eq(ok, true, "Stage hunk action should succeed")
    assert_eq(#(session.file_queue.entries or {}), 1, "Stage refresh should keep the original queue")
    assert_eq(git_mod.read_index(repo, "stage.txt"), "one\nTWO\nthree\n", "Stage hunk should update the index")
    assert_eq(table.concat(read_file(repo .. "/stage.txt"), "\n") .. "\n", "one\nTWO\nthree\n", "Stage hunk should not rewrite worktree content")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo stage hunk should not error")
    assert_eq(ok, true, "Undo stage hunk should succeed")
    assert_eq(git_mod.read_index(repo, "stage.txt"), "one\ntwo\nthree\n", "Undo should restore previous index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "discard.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "discard.txt", { "one", "TWO", "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "discard.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.discard(session)
    assert_eq(err, nil, "Discard hunk action should not error")
    assert_eq(ok, true, "Discard hunk action should succeed")
    assert_eq(table.concat(read_file(repo .. "/discard.txt"), "\n") .. "\n", "one\ntwo\nthree\n", "Discard should restore worktree content from index")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo discard hunk should not error")
    assert_eq(ok, true, "Undo discard hunk should succeed")
    assert_eq(table.concat(read_file(repo .. "/discard.txt"), "\n") .. "\n", "one\nTWO\nthree\n", "Undo should restore discarded worktree content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "scratch-shadow.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "scratch-shadow.txt", { "one", "TWO", "three" })

    local shadow = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = shadow })
    vim.api.nvim_buf_set_name(shadow, repo .. "/scratch-shadow.txt")
    vim.api.nvim_set_option_value("modifiable", false, { buf = shadow })

    local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "scratch-shadow.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.discard(session)
    assert_eq(err, nil, "Discard with path-shadowing scratch buffer should not error")
    assert_eq(ok, true, "Discard with path-shadowing scratch buffer should succeed")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo discard should ignore path-shadowing scratch buffer")
    assert_eq(ok, true, "Undo discard should restore the worktree file")
    assert_eq(table.concat(read_file(repo .. "/scratch-shadow.txt"), "\n") .. "\n", "one\nTWO\nthree\n",
      "Undo discard should restore the file on disk when only a scratch buffer shadows the path")

    pcall(vim.api.nvim_buf_delete, shadow, { force = true })
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "unstage.txt", { "one", "two", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "unstage.txt", { "one", "TWO", "three" })
    git_test_command({ "add", "unstage.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "staged", pathspecs = { "unstage.txt" } }, config.git)))
    local session = make_action_session(queue)
    local ok, err = actions_mod.unstage(session)
    assert_eq(err, nil, "Unstage hunk action should not error")
    assert_eq(ok, true, "Unstage hunk action should succeed")
    assert_eq(git_mod.read_index(repo, "unstage.txt"), "one\ntwo\nthree\n", "Unstage should restore index content from HEAD")

    ok, err = actions_mod.undo(session)
    assert_eq(err, nil, "Undo unstage hunk should not error")
    assert_eq(ok, true, "Undo unstage hunk should succeed")
    assert_eq(git_mod.read_index(repo, "unstage.txt"), "one\nTWO\nthree\n", "Undo should restore staged index content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "add_all.txt", { "one", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "add_all.txt", { "one", "two", "three" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "add_all.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], nil, "All-mode pure addition should start unstaged")

    local ok, err = actions_mod.stage(session)
    assert_eq(err, nil, "All-mode pure addition stage should not error")
    assert_eq(ok, true, "All-mode pure addition stage should succeed")
    local after_states = actions_mod.staged_chunk_states(session)
    assert_eq(after_states[1], true, "All-mode pure addition should show staged marker after staging")
    assert_eq(git_mod.read_index(repo, "add_all.txt"), "one\ntwo\nthree\n",
      "All-mode pure addition should update the index")

    ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode pure addition toggle unstage should not error")
    assert_eq(ok, true, "All-mode pure addition toggle unstage should succeed")
    local unstaged_states = actions_mod.staged_chunk_states(session)
    assert_eq(unstaged_states[1], nil, "All-mode pure addition should show unstaged marker after toggling again")
    assert_eq(git_mod.read_index(repo, "add_all.txt"), "one\nthree\n",
      "All-mode pure addition toggle unstage should restore the index")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "tracked.txt", { "baseline" })
    commit_baseline(repo)
    write_repo_file(repo, "new_file.txt", { "new one", "new two" })
    git_test_command({ "add", "new_file.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "new_file.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], true, "All-mode staged new file should start staged")

    local ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode staged new file toggle unstage should not error")
    assert_eq(ok, true, "All-mode staged new file toggle unstage should succeed")
    assert_eq(git_mod.read_index(repo, "new_file.txt"), nil,
      "All-mode staged new file toggle unstage should remove the index entry")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "already_staged_add.txt", { "one", "three" })
    commit_baseline(repo)
    write_repo_file(repo, "already_staged_add.txt", { "one", "two", "three" })
    git_test_command({ "add", "already_staged_add.txt" }, repo)

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "already_staged_add.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], true, "All-mode staged added hunk should start staged")

    local ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode staged added hunk toggle unstage should not error")
    assert_eq(ok, true, "All-mode staged added hunk toggle unstage should succeed")
    assert_eq(git_mod.read_index(repo, "already_staged_add.txt"), "one\nthree\n",
      "All-mode staged added hunk toggle unstage should restore the index")
    assert_eq(table.concat(read_file(repo .. "/already_staged_add.txt"), "\n") .. "\n", "one\ntwo\nthree\n",
      "All-mode staged added hunk toggle unstage should leave the worktree content")
  end

  do
    local repo = make_git_repo()
    write_repo_file(repo, "mixed_staged_add.txt", { "one", "three", "four" })
    commit_baseline(repo)
    write_repo_file(repo, "mixed_staged_add.txt", { "one", "two", "three", "four" })
    git_test_command({ "add", "mixed_staged_add.txt" }, repo)
    write_repo_file(repo, "mixed_staged_add.txt", { "one", "two", "THREE", "four" })

    local queue = assert((git_mod.queue({ root = repo, mode = "all", pathspecs = { "mixed_staged_add.txt" } }, config.git)))
    local session = make_action_session(queue)
    local before_states = actions_mod.staged_chunk_states(session)
    assert_eq(before_states[1], true, "All-mode mixed staged added hunk should start staged")

    local ok, err = actions_mod.toggle_stage(session)
    assert_eq(err, nil, "All-mode mixed staged added hunk toggle unstage should not error")
    assert_eq(ok, true, "All-mode mixed staged added hunk toggle unstage should succeed")
    assert_eq(git_mod.read_index(repo, "mixed_staged_add.txt"), "one\nthree\nfour\n",
      "All-mode mixed staged added hunk toggle unstage should restore only the index hunk")
    assert_eq(table.concat(read_file(repo .. "/mixed_staged_add.txt"), "\n") .. "\n", "one\ntwo\nTHREE\nfour\n",
      "All-mode mixed staged added hunk toggle unstage should leave nearby worktree edits")
  end
end

do
  local original_notify = vim.notify
  vim.notify = function() end
  local fake = setmetatable({
    file_queue = { entries = { { path = "one" }, { path = "two" } } },
    file_queue_index = 1,
    transitions = {},
  }, Session)
  fake.goto_queue_file = function(self, index, chunk_position)
    self.transitions[#self.transitions + 1] = {
      index = index,
      chunk_position = chunk_position,
    }
    self.file_queue_index = index
    return true
  end

  assert_eq(fake:confirm_file_boundary("next"), true,
    "First next boundary press should be handled")
  assert_eq(#fake.transitions, 0,
    "First next boundary press should only arm the transition")
  assert_eq(fake.pending_file_boundary.direction, "next",
    "First next boundary press should remember direction")
  assert_eq(fake:confirm_file_boundary("next"), true,
    "Second next boundary press should be handled")
  assert_eq(#fake.transitions, 1,
    "Second next boundary press should open the next file")
  assert_eq(fake.transitions[1].index, 2,
    "Second next boundary press should target the next file")
  assert_eq(fake.transitions[1].chunk_position, "top",
    "Next file transition should land at the top of the next file")

  fake.pending_file_boundary = { direction = "next", file_index = 2 }
  fake:confirm_file_boundary("prev")
  assert_eq(fake.pending_file_boundary.direction, "prev",
    "Opposite boundary direction should replace the pending transition")
  assert_eq(#fake.transitions, 1,
    "First previous boundary press should not immediately transition")
  vim.notify = original_notify
end

do
  local fake = {
    file_queue = { entries = { { path = "one" }, { path = "two" }, { path = "three" } }, index = 2 },
    file_queue_index = 2,
    transitions = {},
  }
  function fake:goto_queue_file(index, chunk_position, opts)
    self.transitions[#self.transitions + 1] = {
      index = index,
      chunk_position = chunk_position,
      preserve_focus = opts and opts.preserve_focus,
    }
    self.file_queue_index = index
    return true
  end

  panel_mod.navigate_file(fake, "next")
  assert_eq(fake.transitions[1].index, 3,
    "Panel ]f navigation should move to the next queue file")
  assert_eq(fake.transitions[1].chunk_position, "top",
    "Panel ]f navigation should open the next file at the top")
  assert_eq(fake.transitions[1].preserve_focus, true,
    "Panel ]f navigation should preserve panel focus")

  panel_mod.navigate_file(fake, "prev")
  assert_eq(fake.transitions[2].index, 2,
    "Panel [f navigation should move to the previous queue file")
end

do
  local fake = {
    panel = { mode = "review" },
    closed = false,
  }
  function fake:close()
    self.closed = true
  end
  panel_mod.close(fake)
  assert_eq(fake.closed, true,
    "Closing a review panel should close the owning diff session")
end

-- Document-navigation keymaps survive LspAttach handlers that install
-- buffer-local diagnostic maps ([d/]d) over the session's maps.
do
  local right_path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "one" }, right_path)
  local right_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value("swapfile", false, { buf = right_buf })
  vim.api.nvim_buf_set_name(right_buf, right_path)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { "one" })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = right_buf })

  local session = assert((Session.start({
    left = source_mod.from_lines({ "zero" }, nil, "left"),
    right = source_mod.from_lines({ "one" }, right_path, "right", {
      editable = { target = "buffer", bufnr = right_buf, path = right_path },
    }),
  }, config, {})))
  local top_key = config.navigation.document_keys.top
  local session_cb = buffer_keymap_callback(session.right_buf, "n", top_key)
  assert_eq(type(session_cb), "function",
    "Session should map the document-top key on the right buffer")

  local foreign = function() end
  vim.keymap.set("n", top_key, foreign, { buffer = session.right_buf })
  assert_eq(buffer_keymap_callback(session.right_buf, "n", top_key), foreign,
    "A buffer-local LSP-style map should shadow the session map")

  vim.api.nvim_exec_autocmds("LspAttach", { buffer = session.right_buf })
  vim.wait(500, function()
    return buffer_keymap_callback(session.right_buf, "n", top_key) == session_cb
  end, 10)
  assert_eq(buffer_keymap_callback(session.right_buf, "n", top_key), session_cb,
    "LspAttach should re-assert the session's document-navigation map")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = right_buf })
  session:close()
  assert_eq(buffer_keymap_callback(right_buf, "n", top_key), foreign,
    "Closing the session should restore the shadowing diagnostic map")
  pcall(vim.api.nvim_buf_delete, right_buf, { force = true })
end

-- Three-way merge gutters follow their content panes on scroll, matching the
-- two-way session's owned gutter synchronization.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local many = {}
  for i = 1, 80 do
    many[i] = "line " .. i
  end
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local merge_session = assert((merge_mod.start({
    root = repo,
    path = "merge-scroll.txt",
    base_lines = many,
    local_lines = many,
    remote_lines = many,
    result_lines = many,
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))

  -- Headless nvim never emits WinScrolled (it is checked during UI redraw),
  -- so fire it explicitly with the scrolled window as <amatch>.
  vim.api.nvim_set_current_win(merge_session.result_win)
  vim.api.nvim_win_set_cursor(merge_session.result_win, { 50, 0 })
  vim.api.nvim_win_call(merge_session.result_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(merge_session.result_win) })
  vim.wait(1000, function()
    local top = win_topline(merge_session.result_win)
    return top > 1
      and win_topline(merge_session.result_left_num_win) == top
      and win_topline(merge_session.result_right_num_win) == top
  end, 10)
  local result_top = win_topline(merge_session.result_win)
  assert_ne(result_top, 1, "Scrolling the merge result pane should move its topline")
  assert_eq(win_topline(merge_session.result_left_num_win), result_top,
    "Merge result left number pane should follow the result pane topline")
  assert_eq(win_topline(merge_session.result_right_num_win), result_top,
    "Merge result right number pane should follow the result pane topline")

  vim.api.nvim_set_current_win(merge_session.local_win)
  vim.api.nvim_win_set_cursor(merge_session.local_win, { 30, 0 })
  vim.api.nvim_win_call(merge_session.local_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(merge_session.local_win) })
  vim.wait(1000, function()
    local top = win_topline(merge_session.local_win)
    return top > 1
      and win_topline(merge_session.local_num_win) == top
      and win_topline(merge_session.local_result_connector_win) == top
  end, 10)
  local local_top = win_topline(merge_session.local_win)
  assert_ne(local_top, 1, "Scrolling the merge local pane should move its topline")
  assert_eq(win_topline(merge_session.local_num_win), local_top,
    "Merge local number pane should follow the local pane topline")
  assert_eq(win_topline(merge_session.local_result_connector_win), local_top,
    "Merge local connector should follow the local pane topline")
  assert_eq(win_topline(merge_session.result_left_num_win), win_topline(merge_session.result_win),
    "Scrolling the local pane should leave result gutters synced to the result pane")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()
end

-- Test Suite 16: Snap-to-cursor line mapping and viewport alignment

-- Suite 16a: counterpart_row maps aligned rows across the compact buffers
do
  local function build_view(left, right)
    local hunks, err = diff.compute_hunks(to_text(left), to_text(right), config.diff)
    assert(hunks, err)
    return view.build(left, right, hunks, config)
  end

  -- Add hunk: context rows map exactly, added rows anchor to the line above.
  local v = build_view({ "a", "b", "c", "d" }, { "a", "b", "X", "c", "d" })
  local row, exact = view.counterpart_row(v.line_meta, "left", 4)
  assert_eq(row, 5, "Trailing context after an add should map left 4 to right 5")
  assert_eq(exact, true, "Context rows should map exactly")
  row, exact = view.counterpart_row(v.line_meta, "right", 5)
  assert_eq(row, 4, "Trailing context should map right 5 back to left 4")
  assert_eq(exact, true, "Context rows should map exactly in both directions")
  row, exact = view.counterpart_row(v.line_meta, "right", 3)
  assert_eq(row, 2, "An added row should anchor to the nearest left row above")
  assert_eq(exact, false, "Filler-facing rows should report a non-exact mapping")

  -- Delete hunk: every deleted row anchors to the context line above it.
  v = build_view({ "a", "b", "c", "d" }, { "a", "d" })
  assert_eq((view.counterpart_row(v.line_meta, "left", 2)), 1,
    "First deleted row should anchor to the context row above")
  assert_eq((view.counterpart_row(v.line_meta, "left", 3)), 1,
    "Whole delete blocks should anchor to one target row")

  -- Uneven change: linematch pairs q with z, so the surplus left rows x/y
  -- face filler and anchor to the context row above; z maps exactly.
  v = build_view({ "a", "x", "y", "z", "b" }, { "a", "q", "b" })
  assert_eq((view.counterpart_row(v.line_meta, "left", 2)), 1,
    "Left surplus change rows should anchor to the nearest right row above")
  assert_eq((view.counterpart_row(v.line_meta, "left", 3)), 1,
    "All surplus rows in one block should share the same anchor")
  row, exact = view.counterpart_row(v.line_meta, "left", 4)
  assert_eq(row, 2, "The paired change row should map to its counterpart")
  assert_eq(exact, true, "Paired change rows should map exactly")

  -- Add at the very top of the file: no row above, fall back to nearest below.
  v = build_view({ "m" }, { "X", "m" })
  row, exact = view.counterpart_row(v.line_meta, "right", 1)
  assert_eq(row, 1, "A top-of-file add should fall back to the nearest row below")
  assert_eq(exact, false, "The top-of-file fallback should report non-exact")

  -- Degenerate and out-of-range input never errors.
  assert_eq((view.counterpart_row({}, "left", 3)), 3,
    "Empty aligned views should return the input row unchanged")
  local far = (view.counterpart_row(v.line_meta, "right", 999))
  assert_eq(far >= 1, true, "Out-of-range rows should clamp to a valid target row")
end

-- Suite 16b: Session snap_to_cursor aligns the opposite pane to the cursor's
-- screen offset without moving the focused pane.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local left_lines = {}
  for i = 1, 60 do
    left_lines[i] = "line " .. i
  end
  local right_lines = {}
  for i = 1, 10 do
    right_lines[i] = "line " .. i
  end
  for i = 1, 5 do
    right_lines[10 + i] = "inserted " .. i
  end
  for i = 11, 60 do
    right_lines[i + 5] = "line " .. i
  end

  local session = assert((Session.start({
    left = source_mod.from_lines(left_lines, nil, "left"),
    right = source_mod.from_lines(right_lines, nil, "right"),
  }, config, {})))

  assert_eq(type(buffer_keymap_callback(session.left_buf, "n", config.navigation.snap_key)), "function",
    "Session should map the snap key on the left buffer")
  assert_eq(type(buffer_keymap_callback(session.connector_buf, "n", config.navigation.snap_key)), "function",
    "Session should map the snap key on the connector buffer")

  -- Left cursor on line 40 with topline 30 (screen offset 10); right pane at top.
  vim.api.nvim_set_current_win(session.left_win)
  vim.api.nvim_win_set_cursor(session.left_win, { 30, 0 })
  vim.api.nvim_win_call(session.left_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_win_set_cursor(session.left_win, { 40, 3 })
  assert_eq(win_topline(session.left_win), 30, "Test setup should leave the left topline at 30")

  session:snap_to_cursor()

  assert_eq(vim.api.nvim_win_get_cursor(session.right_win)[1], 45,
    "Snap should move the right cursor to the row facing the left cursor")
  assert_eq(win_topline(session.right_win), 35,
    "Snap should preserve the cursor's screen offset in the right pane")
  assert_eq(win_topline(session.left_win), 30,
    "Snap should not scroll the focused pane")
  assert_eq(vim.api.nvim_win_get_cursor(session.left_win)[1], 40,
    "Snap should not move the focused pane's cursor row")
  assert_eq(vim.api.nvim_win_get_cursor(session.left_win)[2], 3,
    "Snap should not move the focused pane's cursor column")
  assert_eq(win_topline(session.right_num_win), 35,
    "Snap should carry the right number gutter along")

  -- Snapping from the right pane maps back through the same alignment.
  vim.api.nvim_set_current_win(session.right_win)
  session:snap_to_cursor()
  assert_eq(vim.api.nvim_win_get_cursor(session.left_win)[1], 40,
    "Snap from the right pane should map the cursor back to the left row")

  session:close()
end

-- Suite 16c: Merge snap_to_cursor aligns both other panes, pivoting
-- local<->remote through the shared result pane.
do
  local function win_topline(win)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
  end
  local base = {}
  for i = 1, 80 do
    base[i] = "line " .. i
  end
  local local_lines = {}
  for i = 1, 20 do
    local_lines[i] = "line " .. i
  end
  for i = 1, 3 do
    local_lines[20 + i] = "local extra " .. i
  end
  for i = 21, 80 do
    local_lines[i + 3] = "line " .. i
  end
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local merge_session = assert((merge_mod.start({
    root = repo,
    path = "merge-snap.txt",
    base_lines = base,
    local_lines = local_lines,
    remote_lines = base,
    result_lines = base,
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))

  assert_eq(type(buffer_keymap_callback(merge_session.result_buf, "n", config.merge.keys.snap)), "function",
    "Merge should map the snap key on the result buffer")

  -- Result cursor on line 50 with topline 40 (screen offset 10).
  vim.api.nvim_set_current_win(merge_session.result_win)
  vim.api.nvim_win_set_cursor(merge_session.result_win, { 40, 0 })
  vim.api.nvim_win_call(merge_session.result_win, function()
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_win_set_cursor(merge_session.result_win, { 50, 4 })
  assert_eq(win_topline(merge_session.result_win), 40, "Test setup should leave the result topline at 40")

  merge_session:snap_to_cursor()

  assert_eq(vim.api.nvim_win_get_cursor(merge_session.result_win)[1], 50,
    "Snap should not move the focused result pane's cursor row")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.result_win)[2], 4,
    "Snap should not move the focused result pane's cursor column")

  assert_eq(vim.api.nvim_win_get_cursor(merge_session.local_win)[1], 53,
    "Snap should offset the local cursor past the local-only insertion")
  assert_eq(win_topline(merge_session.local_win), 43,
    "Snap should preserve the screen offset in the local pane")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.remote_win)[1], 50,
    "Snap should mirror the result row into the identical remote pane")
  assert_eq(win_topline(merge_session.remote_win), 40,
    "Snap should preserve the screen offset in the remote pane")
  assert_eq(win_topline(merge_session.result_win), 40,
    "Snap should not scroll the focused result pane")
  assert_eq(win_topline(merge_session.local_num_win), 43,
    "Snap should carry the local number gutter along")

  -- Snapping from the local pane pivots through result to reach remote.
  vim.api.nvim_set_current_win(merge_session.local_win)
  vim.api.nvim_win_set_cursor(merge_session.local_win, { 60, 2 })
  merge_session:snap_to_cursor()
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.result_win)[1], 57,
    "Snap from local should map the cursor back through the insertion offset")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.remote_win)[1], 57,
    "Snap from local should pivot through result to position remote")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.local_win)[1], 60,
    "Snap from local should not move the focused pane's cursor row")
  assert_eq(vim.api.nvim_win_get_cursor(merge_session.local_win)[2], 2,
    "Snap from local should not move the focused pane's cursor column")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()
end

-- Merge visibility toggles: the commit panel and the local/remote panes can
-- each be hidden and re-shown; show_all restores everything. Buffers, pair
-- models, and navigation survive while windows are closed.
do
  assert_eq(config.merge.keys.toggle_panel, "gzp", "Merge panel toggle should default to gzp")
  assert_eq(config.merge.keys.toggle_local, "gzh", "Merge local-pane toggle should default to gzh")
  assert_eq(config.merge.keys.toggle_remote, "gzl", "Merge remote-pane toggle should default to gzl")
  assert_eq(config.merge.keys.show_all, "gza", "Merge show-all should default to gza")

  local original_columns = vim.o.columns
  vim.o.columns = 220
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local merge_session = assert((merge_mod.start({
    root = repo,
    path = "merge-toggles.txt",
    base_lines = { "one", "two", "three" },
    local_lines = { "one", "TWO", "three" },
    remote_lines = { "one", "two", "THREE" },
    result_lines = { "one", "two", "three" },
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {
    panel = true,
    queue = { entries = {} },
  })))

  local function win_valid(win)
    return win ~= nil and vim.api.nvim_win_is_valid(win)
  end
  local function win_col(win)
    return vim.api.nvim_win_get_position(win)[2]
  end

  -- Panel toggle: closes only the two panel windows and returns their width
  -- to the content panes; toggling back reopens a full-height left column.
  assert_eq(panel_mod.is_open(merge_session), true, "Merge should start with the commit panel open")
  local result_width_with_panel = vim.api.nvim_win_get_width(merge_session.result_win)
  local startup_nav_row = vim.api.nvim_win_get_position(merge_session.panel.nav_win)[1]
  local startup_nav_height = vim.api.nvim_win_get_height(merge_session.panel.nav_win)
  local startup_commit_height = vim.api.nvim_win_get_height(merge_session.panel.commit_win)
  merge_session:toggle_panel_visibility()
  assert_eq(panel_mod.is_open(merge_session), false, "Panel toggle should close the panel windows")
  assert_eq(merge_session.hidden.panel, true, "Panel toggle should record the hidden state")
  assert_eq(win_valid(merge_session.local_win) and win_valid(merge_session.result_win) and win_valid(merge_session.remote_win),
    true, "Hiding the panel should keep all three content panes")
  assert_eq(vim.api.nvim_win_get_width(merge_session.result_win) > result_width_with_panel, true,
    "Hiding the panel should widen the content panes")
  merge_session:toggle_panel_visibility()
  assert_eq(panel_mod.is_open(merge_session), true, "Panel toggle should reopen the panel windows")
  assert_eq(merge_session.hidden.panel, false, "Reopening the panel should clear the hidden state")
  assert_eq(win_col(merge_session.panel.nav_win), 0, "Reopened panel should be the leftmost column")
  assert_eq(vim.api.nvim_win_get_position(merge_session.panel.nav_win)[1], startup_nav_row,
    "Reopened panel nav should start at the same row as at startup (above the header row)")
  assert_eq(vim.api.nvim_win_get_height(merge_session.panel.nav_win), startup_nav_height,
    "Reopened panel nav should restore its startup height")
  assert_eq(vim.api.nvim_win_get_height(merge_session.panel.commit_win), startup_commit_height,
    "Reopened panel commit window should restore its startup height")

  -- Local pane toggle: the pane and its gutters close, the pair model and
  -- buffer survive, and re-showing restores the column order.
  local local_buf = merge_session.local_buf
  merge_session:toggle_pane("local")
  assert_eq(merge_session.hidden.local_pane, true, "Local toggle should record the hidden state")
  assert_eq(merge_session.local_win, nil, "Hiding local should drop the pane window")
  assert_eq(merge_session.local_num_win, nil, "Hiding local should drop its number gutter")
  assert_eq(merge_session.local_result_connector_win, nil, "Hiding local should drop its connector")
  assert_eq(merge_session.result_left_num_win, nil, "Hiding local should drop the result-left number gutter")
  assert_eq(merge_session.local_result_session, nil, "Hiding local should drop its renderer session")
  assert_eq(merge_session.local_result_pair ~= nil, true, "Hiding local should keep the diff pair model")
  assert_eq(vim.api.nvim_buf_is_valid(local_buf), true, "Hiding local should keep the local buffer alive")
  merge_session:toggle_pane("local")
  assert_eq(merge_session.hidden.local_pane, false, "Local toggle should re-show the pane")
  assert_eq(win_valid(merge_session.local_win), true, "Re-shown local pane should have a window")
  assert_eq(merge_session.local_result_session ~= nil, true, "Re-shown local pane should rebuild its renderer")
  assert_eq(win_col(merge_session.local_win) < win_col(merge_session.local_num_win)
      and win_col(merge_session.local_num_win) < win_col(merge_session.local_result_connector_win)
      and win_col(merge_session.local_result_connector_win) < win_col(merge_session.result_left_num_win)
      and win_col(merge_session.result_left_num_win) < win_col(merge_session.result_win),
    true, "Re-shown local group should restore the left-to-right column order")

  -- Hiding a focused pane must bounce focus to the result pane.
  vim.api.nvim_set_current_win(merge_session.local_win)
  merge_session:toggle_pane("local")
  assert_eq(vim.api.nvim_get_current_win(), merge_session.result_win,
    "Hiding the focused pane should move focus to the result pane")

  -- Remote toggle plus everything hidden: result keeps working alone.
  merge_session:toggle_pane("remote")
  merge_session:toggle_panel_visibility()
  assert_eq(merge_session.hidden.remote_pane, true, "Remote toggle should record the hidden state")
  assert_eq(merge_session.remote_win, nil, "Hiding remote should drop the pane window")
  assert_eq(merge_session.result_remote_session, nil, "Hiding remote should drop its renderer session")
  assert_eq(win_valid(merge_session.result_win), true, "Result pane must survive all toggles")
  merge_session:render({ force_pair_rebuild = true })
  assert_eq(win_valid(merge_session.result_win), true, "Render with everything hidden should keep the result pane")

  -- show_all restores the panel and both panes in one step, idempotently.
  merge_session:show_all()
  assert_eq(panel_mod.is_open(merge_session), true, "show_all should reopen the commit panel")
  assert_eq(merge_session.hidden.local_pane, false, "show_all should re-show the local pane")
  assert_eq(merge_session.hidden.remote_pane, false, "show_all should re-show the remote pane")
  for _, win in ipairs({
    merge_session.panel.nav_win,
    merge_session.local_win,
    merge_session.local_num_win,
    merge_session.local_result_connector_win,
    merge_session.result_left_num_win,
    merge_session.result_win,
    merge_session.result_right_num_win,
    merge_session.result_remote_connector_win,
    merge_session.remote_num_win,
    merge_session.remote_win,
  }) do
    assert_eq(win_valid(win), true, "show_all should leave every window valid")
  end
  local restored_order = {
    merge_session.panel.nav_win,
    merge_session.local_win,
    merge_session.local_num_win,
    merge_session.local_result_connector_win,
    merge_session.result_left_num_win,
    merge_session.result_win,
    merge_session.result_right_num_win,
    merge_session.result_remote_connector_win,
    merge_session.remote_num_win,
    merge_session.remote_win,
  }
  for index = 2, #restored_order do
    assert_eq(win_col(restored_order[index - 1]) < win_col(restored_order[index]), true,
      "show_all should restore the full left-to-right column order")
  end
  local window_count = #vim.api.nvim_tabpage_list_wins(merge_session.tabpage)
  merge_session:show_all()
  assert_eq(#vim.api.nvim_tabpage_list_wins(merge_session.tabpage), window_count,
    "show_all with nothing hidden should be a no-op")

  -- Navigation and accept still work against the pair models while hidden.
  merge_session:toggle_pane("local")
  vim.api.nvim_set_current_win(merge_session.result_win)
  merge_session:goto_next_chunk()
  merge_session:accept("local")
  assert_eq(vim.api.nvim_buf_get_lines(merge_session.result_buf, 0, -1, false)[2], "TWO",
    "Accept local should edit the result while the local pane is hidden")
  merge_session:show_pane("local")

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = merge_session.result_buf })
  merge_session:close()
  vim.o.columns = original_columns
end

vim.api.nvim_out_write("OK\n")
vim.cmd("qa")
