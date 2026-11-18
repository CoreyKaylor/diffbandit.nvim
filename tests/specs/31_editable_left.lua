-- Ordinary file diffs can opt into editing both real file buffers.
do
  local api = require("diffbandit")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
  end

  local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
  end

  local function file_pair(name, left_text, right_text)
    local left_path = dir .. "/" .. name .. "-left.txt"
    local right_path = dir .. "/" .. name .. "-right.txt"

    write(left_path, left_text)
    write(right_path, right_text)

    return left_path, right_path
  end

  -- The existing two-file API remains read-only on the left by default.
  do
    local left_path, right_path = file_pair(
      "default",
      "one\nleft\nthree\n",
      "one\nright\nthree\n"
    )
    local session = assert(api.files(left_path, right_path))

    assert_eq(vim.bo[session.left_buf].modifiable, false, "default left pane stays read-only")
    assert_eq((actions_mod.apply_right(session)), false, "default reverse transfer stays disabled")

    session:close()
  end

  -- Opting in makes both file buffers editable. Hunk actions remain in memory
  -- until the user writes the target pane.
  do
    local left_path, right_path = file_pair(
      "transfer",
      "one\nleft\nthree\n",
      "one\nright\nthree\n"
    )
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    assert_eq(vim.api.nvim_buf_get_name(session.left_buf), left_path, "left pane uses the file buffer")
    assert_eq(vim.bo[session.left_buf].modifiable, true, "opt-in left pane is editable")
    assert_eq((actions_mod.apply_right(session)), true, "right hunk applies to left")
    assert_eq(vim.bo[session.left_buf].modified, true, "left buffer is modified")
    assert_eq(read(left_path), "one\nleft\nthree\n", "the file remains unchanged until saved")

    vim.api.nvim_set_current_win(session.left_win)
    session:undo_edit_or_action()
    assert_eq(
      vim.api.nvim_buf_get_lines(session.left_buf, 1, 2, false)[1],
      "left",
      "undo restores the left buffer"
    )

    session:goto_next_chunk()
    local applied, apply_err = actions_mod.apply_left(session)
    assert_eq(applied, true, "left hunk applies to right: " .. tostring(apply_err))
    assert_eq(vim.bo[session.right_buf].modified, true, "right buffer is modified")

    session:close()
    assert_eq(vim.api.nvim_buf_is_valid(session.right_buf), true, "unsaved right buffer survives close")
    assert_eq(
      vim.api.nvim_buf_get_lines(session.right_buf, 1, 2, false)[1],
      "left",
      "unsaved right edit survives"
    )
    vim.api.nvim_buf_delete(session.right_buf, { force = true })
  end

  -- A disk edit after the view opens blocks an action into that file.
  do
    local left_path, right_path = file_pair(
      "stale-left",
      "one\nleft\nthree\n",
      "one\nright\nthree\n"
    )
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    write(left_path, "one\nexternal\nthree\n")
    local applied, err = actions_mod.apply_right(session)
    assert_eq(applied, false, "external left edit blocks reverse transfer")
    assert_eq(type(err), "string", "conflict provides a reason")
    assert_eq(read(left_path), "one\nexternal\nthree\n", "external left edit is untouched")

    session:close()
  end

  do
    local left_path, right_path = file_pair(
      "stale-right",
      "one\nleft\nthree\n",
      "one\nright\nthree\n"
    )
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    write(right_path, "one\nexternal\nthree\n")
    assert_eq((actions_mod.apply_left(session)), false, "external right edit blocks forward transfer")
    assert_eq(read(right_path), "one\nexternal\nthree\n", "external right edit is untouched")

    session:close()
  end

  -- Saving an accepted hunk keeps the target file's line endings.
  do
    local left_path, right_path = file_pair(
      "crlf",
      "one\r\nleft\r\nthree\r\n",
      "one\r\nright\r\nthree\r\n"
    )
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    assert_eq((actions_mod.apply_right(session)), true, "CRLF hunk applies to left")
    vim.api.nvim_set_current_win(session.left_win)
    vim.cmd("write")
    assert_eq(read(left_path), "one\r\nright\r\nthree\r\n", "CRLF survives save")

    session:close()
  end

  do
    local left_path, right_path = file_pair("noeol", "one\nleft", "one\nright")
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    assert_eq((actions_mod.apply_right(session)), true, "no-final-newline hunk applies")
    vim.api.nvim_set_current_win(session.left_win)
    vim.cmd("write")
    assert_eq(read(left_path), "one\nright", "save preserves missing final newline")

    session:close()
  end

  -- A hunk action leaves other differences in place and preserves unsaved edits.
  do
    local left_path, right_path = file_pair(
      "partial",
      "a\nleft one\nb\nc\nd\ne\nleft two\nf\n",
      "a\nright one\nb\nc\nd\ne\nright two\nf\n"
    )
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    assert_eq((actions_mod.apply_right(session)), true, "first hunk applies")
    assert_eq(
      vim.api.nvim_buf_get_lines(session.left_buf, 6, 7, false)[1],
      "left two",
      "other hunk stays left"
    )
    assert_eq(#session.hunks, 1, "other hunk remains visible")

    session:close()
    assert_eq(vim.api.nvim_buf_is_valid(session.left_buf), true, "unsaved left buffer survives close")
    assert_eq(
      vim.api.nvim_buf_get_lines(session.left_buf, 1, 2, false)[1],
      "right one",
      "unsaved left edit survives"
    )
    vim.api.nvim_buf_delete(session.left_buf, { force = true })
  end

  -- Reloading a file that changed on disk clears the conflict, in the default
  -- view (right side) and with the opt-in left side.
  do
    local left_path, right_path = file_pair(
      "reload-right",
      "one\nleft\nthree\n",
      "one\nright\nthree\n"
    )
    local session = assert(api.files(left_path, right_path))

    write(right_path, "one\nright\nthree\nfour\n")
    assert_eq((actions_mod.apply_left(session)), false, "stale right buffer blocks forward transfer")
    vim.api.nvim_buf_call(session.right_buf, function()
      vim.cmd("silent edit!")
    end)
    local applied, apply_err = actions_mod.apply_left(session)
    assert_eq(applied, true, "reloaded right buffer accepts forward transfer: " .. tostring(apply_err))

    session:close()
    vim.api.nvim_buf_delete(session.right_buf, { force = true })
  end

  do
    local left_path, right_path = file_pair(
      "reload-left",
      "one\nleft\nthree\n",
      "one\nright\nthree\n"
    )
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    write(left_path, "one\nleft\nthree\nfour\n")
    assert_eq((actions_mod.apply_right(session)), false, "stale left buffer blocks reverse transfer")
    vim.api.nvim_buf_call(session.left_buf, function()
      vim.cmd("silent edit!")
    end)
    local applied, apply_err = actions_mod.apply_right(session)
    assert_eq(applied, true, "reloaded left buffer accepts reverse transfer: " .. tostring(apply_err))

    session:close()
    vim.api.nvim_buf_delete(session.left_buf, { force = true })
  end

  -- Undoing a hunk that changed the final newline restores 'endofline', so a
  -- save after undo writes the original bytes; redo brings the change back.
  do
    local left_path, right_path = file_pair("eol-undo", "one\nleft\n", "one\nright")
    local session = assert(api.files(left_path, right_path, { editable_left = true }))

    assert_eq((actions_mod.apply_right(session)), true, "end-of-file hunk applies to left")
    assert_eq(vim.bo[session.left_buf].endofline, false, "hunk carries the missing final newline")

    vim.api.nvim_set_current_win(session.left_win)
    session:undo_edit_or_action()
    assert_eq(vim.bo[session.left_buf].endofline, true, "undo restores endofline")
    vim.cmd("silent write")
    assert_eq(read(left_path), "one\nleft\n", "save after undo keeps the final newline")

    vim.cmd("silent redo")
    session:refresh_editable_side("left")
    assert_eq(vim.bo[session.left_buf].endofline, false, "redo re-applies the missing final newline")
    vim.cmd("silent write")
    assert_eq(read(left_path), "one\nright", "save after redo matches the source")

    session:close()
  end

  -- A file diffed against itself keeps one editable buffer, on the right.
  do
    local left_path = file_pair("same", "one\n", "one\n")
    local session = assert(api.files(left_path, left_path, { editable_left = true }))

    assert_eq(session.left_buf ~= session.right_buf, true, "panes do not share a buffer")
    assert_eq(vim.bo[session.left_buf].modifiable, false, "left stays read-only")

    session:close()
  end
end
