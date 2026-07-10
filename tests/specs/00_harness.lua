-- `root` and package.path are injected by tests/run.lua (absolute repo path)
-- so the suite works when cwd is outside the repository. Fall back only when
-- a spec is executed standalone.
if not root or root == "" then
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  local test_dir = vim.fn.fnamemodify(source, ":p:h")
  if test_dir:match("/specs$") then
    test_dir = vim.fn.fnamemodify(test_dir .. "/..", ":p")
  elseif not test_dir:match("/tests") then
    test_dir = vim.fn.fnamemodify(vim.fn.getcwd() .. "/tests", ":p")
  end
  root = vim.fn.fnamemodify(test_dir .. "/..", ":p"):gsub("/$", "")
  package.path = package.path .. ";" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua"
end

local config_mod = require("diffbandit.config")
local config = config_mod.defaults()
local diff = require("diffbandit.diff")
local highlights = require("diffbandit.highlights")
local view = require("diffbandit.diff.view")
local connector = require("diffbandit.connector")
local paths_mod = connector -- legacy alias used throughout connector specs
local Session = require("diffbandit.session")
local git_mod = require("diffbandit.git")
local actions_mod = require("diffbandit.session.actions")
local status_mod = require("diffbandit.util.status")
local hex_mod = require("diffbandit.util.hex")
local panel_mod = require("diffbandit.panel")
local overview_mod = require("diffbandit.util.overview")
local merge_mod = require("diffbandit.merge")
local diff_pair_mod = require("diffbandit.diff.pair")
local state_mod = require("diffbandit.state")
local folder_mod = require("diffbandit.folder")
local folder_model_mod = require("diffbandit.folder.model")
local merge_model_mod = require("diffbandit.merge.model")
local source_mod = require("diffbandit.util.source")
local text_mod = require("diffbandit.util.text")

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

local function assert_location()
  if type(__map_spec_line) ~= "function" then
    return ""
  end
  local info = debug.getinfo(3, "l")
  if not info or not info.currentline then
    return ""
  end
  local path, line = __map_spec_line(info.currentline)
  return string.format("%s:%d: ", path, line)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error(assert_location()
      .. (msg or "assertion failed")
      .. string.format("\nExpected: %s\nActual:   %s", tostring(b), tostring(a)))
  end
end

local function assert_ne(a, b, msg)
  if a == b then
    error(assert_location()
      .. (msg or "assertion failed")
      .. string.format("\nExpected values to differ, both were: %s", tostring(a)))
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
  -- edit_refresh_debounce_ms defaults to 150ms; wait past that.
  vim.wait(400, function()
    return session.right.text == "right edited\n"
  end, 10)
  assert_eq(session.right.text, "right edited\n",
    "Editing the reusable right buffer should refresh the diff source text")
  vim.api.nvim_set_current_win(session.right_win)
  local undo_callback = buffer_keymap_callback(session.right_buf, "n", config.actions.keys.undo)
  assert_eq(type(undo_callback), "function",
    "Editable right-side buffer should have a callable undo mapping")
  undo_callback()
  assert_eq(vim.api.nvim_buf_get_lines(session.right_buf, 0, -1, false)[1], "right original",
    "Undo in an editable right-side buffer should use native buffer undo")
  assert_eq(session.right.text, "right original\n",
    "Undo in an editable right-side buffer should refresh the diff source text")
  vim.api.nvim_win_set_cursor(session.right_win, { 1, #"right" })
  vim.api.nvim_buf_set_lines(session.right_buf, 0, -1, false, { "right original plus" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.right_buf })
  vim.wait(400, function()
    return session.right.text == "right original plus\n"
  end, 10)
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
