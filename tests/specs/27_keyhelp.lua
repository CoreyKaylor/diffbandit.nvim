-- Suite: in-view key help (issue #21): mapping descriptions, the g? window,
-- and the header hints. Uses the git fixtures from 20_git_merge.

local keyhelp = require("diffbandit.util.keyhelp")

-- Every DiffBandit mapping in `buf` that `host` installed carries a
-- "DiffBandit: " description, so :map / which-key / g? can explain it.
local function assert_described(buf, label)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc == nil or map.desc:sub(1, #keyhelp.PREFIX) ~= keyhelp.PREFIX then
      error(string.format("%s: mapping %q has no DiffBandit description", label, map.lhs))
    end
  end
end

local function section_names(sections)
  local names = {}
  for _, section in ipairs(sections) do
    names[#names + 1] = section.name
  end
  return table.concat(names, ",")
end

local function find_row(sections, desc)
  for _, section in ipairs(sections) do
    for _, row in ipairs(section.rows) do
      if row.desc == desc then
        return row, section.name
      end
    end
  end
  return nil
end

local function help_lines()
  local win = vim.api.nvim_get_current_win()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

-- keyhelp: grouping, collapsing, display, and live state.
do
  local buf = vim.api.nvim_create_buf(false, true)
  local base = { buffer = buf }
  vim.keymap.set("n", "]c", function() end, keyhelp.opts(buf, "Hunks", "Next hunk", base))
  vim.keymap.set("n", "<CR>", function() end, keyhelp.opts(buf, "Folder", "Open entry", base))
  vim.keymap.set("n", "o", function() end, keyhelp.opts(buf, "Folder", "Open entry", base))
  vim.keymap.set("n", "<Space>", function() end, keyhelp.opts(buf, "Staging and actions", "Stage", base))
  vim.keymap.set("n", "<<", function() end, keyhelp.opts(buf, "Staging and actions", "Apply right", base))
  vim.keymap.set("n", "g?", function() end, keyhelp.opts(buf, "General", "Show this key help", base))
  vim.keymap.set("n", "x", function() end, { buffer = buf, desc = "someone else's map" })

  local sections = keyhelp.sections(buf)
  assert_eq(section_names(sections), "General,Hunks,Staging and actions,Folder",
    "Help sections follow the canonical order and skip empty ones")
  local open_row = find_row(sections, "Open entry")
  assert_eq(open_row and open_row.keys, "<CR>, o", "Keys sharing a description collapse into one row")
  assert_eq((find_row(sections, "Stage") or {}).keys, "<Space>", "A space lhs displays as <Space>")
  assert_eq((find_row(sections, "Apply right") or {}).keys, "<<", "A < lhs displays as <, not <lt>")
  assert_eq(find_row(sections, "someone else's map"), nil, "Mappings from other plugins are not listed")
  assert_eq(section_names(keyhelp.sections(buf, { "Folder" })), "Folder,General,Hunks,Staging and actions",
    "A view can list its own sections first")

  vim.keymap.del("n", "]c", { buffer = buf })
  assert_eq(find_row(keyhelp.sections(buf), "Next hunk"), nil, "Help lists live mappings, so a removed key disappears")

  assert_eq(keyhelp.hint("g?"), "g? help", "Header hint names the help key")
  assert_eq(keyhelp.hint(false), nil, "A disabled help key shows no hint")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- 2-way git diff: descriptions, g? window, header hint, and the panel.
do
  -- Wide enough for the header to fit the hint next to the path; narrower
  -- headers drop the hint and keep the path.
  local saved_columns = vim.o.columns
  vim.o.columns = 220
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "one", "two" })
  commit_baseline(repo)
  write_repo_file(repo, "a.txt", { "one", "TWO" })
  local queue = assert((git_mod.queue({ root = repo, mode = "all" }, config.git)))
  local loaded = assert((queue.load(1)))
  queue.index = 1
  local session = assert((Session.start({ left = loaded.left, right = loaded.right }, config, {
    queue = queue,
    panel = true,
    panel_initial_selection = 1,
  })))
  state_mod.register(session)

  for _, field in ipairs({ "left_buf", "left_num_buf", "connector_buf", "right_num_buf" }) do
    assert_described(session[field], "Diff " .. field)
  end
  assert_described(session.panel.nav_buf, "Panel file list")

  vim.api.nvim_set_current_win(session.right_win)
  buffer_keymap_callback(session.right_buf, "n", "g?")()
  assert_eq(keyhelp.is_open(), true, "g? in a diff pane opens the key help")
  local text = help_lines()
  assert_eq(text:find("Next hunk", 1, true) ~= nil, true, "Diff help lists hunk navigation")
  assert_eq(text:find("Close this view", 1, true) ~= nil, true, "Diff help lists the close key")
  assert_eq(text:find("Header", 1, true) ~= nil, true, "Diff help explains the compact header fields")
  assert_eq(text:find(":DiffBanditClose", 1, true) ~= nil, true, "Help points at the close command")
  keyhelp.close()
  assert_eq(keyhelp.is_open(), false, "The help window closes")

  local header = vim.api.nvim_buf_get_lines(session.right_header_buf, 0, 1, false)[1] or ""
  assert_eq(vim.trim(header):sub(-#"g? help"), "g? help", "The diff header shows the help hint on the right")

  local nav_hint = vim.api.nvim_buf_get_extmarks(session.panel.nav_buf, session.ns, { 0, 0 }, { 0, -1 }, { details = true })
  local found_hint = false
  for _, mark in ipairs(nav_hint) do
    for _, chunk in ipairs((mark[4] or {}).virt_text or {}) do
      found_hint = found_hint or chunk[1] == "g? help"
    end
  end
  assert_eq(found_hint, true, "The panel's first row shows the help hint")

  local label_marks = vim.api.nvim_buf_get_extmarks(session.panel.commit_buf, session.ns, { 1, 0 }, { 1, -1 }, { details = true })
  local label = ""
  for _, mark in ipairs(label_marks) do
    for _, chunk in ipairs((mark[4] or {}).virt_text or {}) do
      label = label .. chunk[1]
    end
  end
  assert_eq(label:find(":w commit", 1, true) ~= nil, true, "The commit message label says how to commit")

  vim.api.nvim_set_current_win(session.panel.nav_win)
  buffer_keymap_callback(session.panel.nav_buf, "n", "g?")()
  text = help_lines()
  assert_eq(text:find("Stage or unstage the selected file", 1, true) ~= nil, true, "Panel help lists file staging")
  assert_eq(text:find("Partly staged", 1, true) ~= nil, true, "Panel help explains the staged symbols")
  keyhelp.close()

  vim.api.nvim_buf_set_lines(session.panel.commit_buf, 2, -1, false, { "" })
  session:close()
  vim.o.columns = saved_columns
end

-- Review hint line follows remapped keys; help_key = false removes help.
do
  local review_config = config_mod.apply({
    navigation = { help_key = false },
    git = { panel = { keys = { focus_diff = "o", close = "Q" } } },
  })
  local fake = {
    config = review_config,
    file_queue = { kind = "git" },
    panel = { mode = "review" },
  }
  assert_eq(panel_mod.review_help(fake), "o focus diff  ]f/[f files  ]c/[c hunks  Q close",
    "The review hint line uses the configured keys and omits a disabled help key")
  fake.config = config
  assert_eq(panel_mod.review_help(fake), "<CR> focus diff  ]f/[f files  ]c/[c hunks  q close  g? help",
    "The default review hint line includes the help key")

  local left = vim.fn.tempname()
  local right = vim.fn.tempname()
  vim.fn.writefile({ "a" }, left)
  vim.fn.writefile({ "b" }, right)
  local session = assert((Session.start({
    left = source_mod.from_file(left, nil, review_config),
    right = source_mod.from_file(right, nil, review_config),
  }, review_config, {})))
  assert_eq(buffer_keymap_callback(session.left_buf, "n", "g?"), nil, "help_key = false leaves g? unmapped")
  session:close()
end

-- Merge resolver mappings are described too.
do
  local repo = make_git_repo()
  local session = assert((merge_mod.start({
    root = repo,
    path = "help_conflict.txt",
    base_lines = { "base" },
    local_lines = { "local" },
    remote_lines = { "remote" },
    result_lines = { "base" },
    conflicts = {},
    non_conflicting = {},
    local_hunks = {},
    remote_hunks = {},
  }, config, {})))
  for _, field in ipairs({ "local_buf", "remote_buf" }) do
    assert_described(session[field], "Merge " .. field)
  end
  vim.api.nvim_set_current_win(session.result_win)
  buffer_keymap_callback(session.result_buf, "n", "g?")()
  local text = help_lines()
  assert_eq(text:find("Accept local (ours) into the result", 1, true) ~= nil, true, "Merge help lists accept actions")
  assert_eq(text:find(":w", 1, true) ~= nil, true, "Merge help explains writing the result")
  keyhelp.close()
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.result_buf })
  session:close()
end
