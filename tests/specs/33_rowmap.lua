-- util/rowmap: buffer line <-> screen row mapping for wrapped source panes.

do
  local rowmap = require("diffbandit.util.rowmap")
  local new_map = rowmap._private.new_map

  -- Line 3 spans 3 rows, line 7 spans 2.
  local map = new_map(10, { 3, 7 }, { 2, 1 }, 1)
  assert_eq(map.identity, false, "rowmap: tall lines make a non-identity map")
  assert_eq(map:first_row(1), 1, "rowmap: rows above a tall line are unchanged")
  assert_eq(map:first_row(3), 3, "rowmap: a tall line starts on its own row")
  assert_eq(map:last_row(3), 5, "rowmap: a tall line ends after its extra rows")
  assert_eq(map:first_row(4), 6, "rowmap: lines below shift by the extra rows")
  assert_eq(map:first_row(7), 9, "rowmap: second tall line")
  assert_eq(map:last_row(7), 10, "rowmap: second tall line end")
  assert_eq(map:first_row(8), 11, "rowmap: rows accumulate both tall lines")
  assert_eq(map:total_rows(10), 13, "rowmap: total rows")
  assert_eq(map:first_row(12), 15, "rowmap: lines past the buffer (padding) are one row each")
  local line, sub = map:line_at_row(4)
  assert_eq(line .. ":" .. sub, "3:1", "rowmap: row inside a wrapped line")
  line, sub = map:line_at_row(10)
  assert_eq(line .. ":" .. sub, "7:1", "rowmap: last row of the second tall line")
  line, sub = map:line_at_row(11)
  assert_eq(line .. ":" .. sub, "8:0", "rowmap: row after the tall lines")

  local id = rowmap.identity()
  assert_eq(id:first_row(42) .. ":" .. id:last_row(42), "42:42", "rowmap: identity map")
  assert_eq(rowmap.signature(id, id), "id", "rowmap: identity signature")
  assert_eq(rowmap.signature(id, map) ~= "id", true, "rowmap: wrapped signature differs")
end

do
  -- Measured from a real window: heights match nvim_win_text_height, and a
  -- window without wrap (or without long lines) is the identity.
  local rowmap = require("diffbandit.util.rowmap")
  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_width(win, vim.o.columns)
  local width = vim.api.nvim_win_get_width(win)
  local long = string.rep("x", width * 2 + 5)
  local tabbed = string.rep("\t", math.ceil(width / 8) + 1) .. "y"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "short", long, "short", tabbed, "short" })
  vim.wo[win].wrap = false
  assert_eq(rowmap.get(win).identity, true, "rowmap: nowrap window is the identity")
  vim.wo[win].wrap = true
  local map = rowmap.get(win)
  for line = 1, 5 do
    local expected = vim.api.nvim_win_text_height(win, { start_row = line - 1, end_row = line - 1 }).all
    assert_eq(map:height(line), expected, "rowmap: measured height of line " .. line)
  end
  assert_eq(map:height(2), 3, "rowmap: long line wraps into three rows")
  assert_eq(map:height(4) > 1, true, "rowmap: tab-expanded line wraps")
  assert_eq(rowmap.get(win) == map, true, "rowmap: unchanged window reuses its map")
  vim.wo[win].linebreak = true
  assert_eq(rowmap.get(win) ~= map, true, "rowmap: a wrap option change rebuilds the map")
  -- Virtual lines add rows without wrapping.
  vim.wo[win].wrap = false
  local ns = vim.api.nvim_create_namespace("diffbandit_rowmap_spec")
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = { { { "v1" } }, { { "v2" } } } })
  rowmap.invalidate(win)
  local virt = rowmap.get(win)
  assert_eq(virt:height(1), 3, "rowmap: virtual lines below a line count as its rows")
  assert_eq(virt:first_row(2), 4, "rowmap: lines after virtual lines shift")
  vim.cmd("tabclose!")
end

do
  -- Row-space paths: a wrapped origin anchors at its bottom row, and blocks
  -- cover every row of their wrapped lines.
  local rowmap = require("diffbandit.util.rowmap")
  local new_map = rowmap._private.new_map
  local left = { "a", "b long", "c", "d" }
  local right = { "a", "b long", "new 1", "new 2", "c", "d" }
  local hunks, err = diff.compute_hunks(table.concat(left, "\n") .. "\n", table.concat(right, "\n") .. "\n", config.diff)
  assert_eq(err, nil, "rowmap: diff error")
  local v = view.build(left, right, hunks, config)
  -- Left line 2 (the add's origin) wraps to 3 rows; right line 3 to 2 rows.
  local lmap = new_map(#left, { 2 }, { 2 }, 1)
  local rmap = new_map(#right, { 2, 3 }, { 2, 1 }, 2)
  local expanded = rowmap.expand_view(v, lmap, rmap)
  local paths = connector.compute_paths(expanded.chunks, expanded.line_meta)
  local add
  for _, p in ipairs(paths) do
    if p.kind == "add" then
      add = p
    end
  end
  assert_eq(add ~= nil, true, "rowmap: expanded view keeps the add path")
  assert_eq(add.origin_left_index, 4, "rowmap: add origin is the bottom row of the wrapped origin line")
  assert_eq(add.target_start_index, 5, "rowmap: add block starts on the first row of its first line")
  assert_eq(add.target_end_index, 7, "rowmap: add block ends on the last row of its last line")
  assert_eq(add.start_right_line .. ":" .. add.end_right_line, "3:4", "rowmap: source line fields stay in line space")
  assert_eq(rowmap.expand_view(v, rowmap.identity(), rowmap.identity()) == v, true,
    "rowmap: identity maps leave the view untouched")
end
