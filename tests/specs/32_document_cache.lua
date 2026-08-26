-- Document-model reuse: identity cache, LRU, git source_cache, prefetch.
-- Concatenated after 20_git_merge so make_git_repo / write_repo_file exist.

local diff_document = require("diffbandit.diff.document")
local queue_host = require("diffbandit.host.queue")
local view_builder = require("diffbandit.diff.view")

local function source_pair(left_lines, right_lines)
  return {
    left = test_source("left", left_lines),
    right = test_source("right", right_lines),
  }
end

local function spy_compute()
  local original = diff.compute_hunks_from_lines
  local count = { n = 0 }
  diff.compute_hunks_from_lines = function(...)
    count.n = count.n + 1
    return original(...)
  end
  return count, function()
    diff.compute_hunks_from_lines = original
  end
end

local function spy_view_build()
  local original = view_builder.build
  local count = { n = 0 }
  view_builder.build = function(...)
    count.n = count.n + 1
    return original(...)
  end
  return count, function()
    view_builder.build = original
  end
end

-- Lines entry point matches the text path.
do
  local left = { "alpha", "beta" }
  local right = { "alpha", "BETA" }
  local from_text, err_text = diff.compute_hunks(to_text(left), to_text(right), config.diff)
  local from_lines, err_lines = diff.compute_hunks_from_lines(left, right, config.diff)
  assert_eq(err_text, nil, "text hunks should succeed")
  assert_eq(err_lines, nil, "lines hunks should succeed")
  assert_eq(#from_text, #from_lines, "hunk count should match")
  assert_eq(from_text[1] and from_text[1].type, from_lines[1] and from_lines[1].type,
    "hunk types should match")
  assert_eq(from_text[1] and from_text[1].right.count, from_lines[1] and from_lines[1].right.count,
    "hunk right counts should match")
end

-- pair.build uses the lines entry point (no to_text/split round-trip).
do
  local count, restore = spy_compute()
  local original_text = diff.compute_hunks
  local text_count = 0
  diff.compute_hunks = function(...)
    text_count = text_count + 1
    return original_text(...)
  end
  local pair, err = diff_pair_mod.build({ "a" }, { "b" }, config)
  diff.compute_hunks = original_text
  restore()
  assert_eq(err, nil, "pair.build should succeed")
  assert_eq(pair ~= nil, true, "pair.build should return a pair")
  assert_eq(count.n, 1, "pair.build should call compute_hunks_from_lines once")
  assert_eq(text_count, 0, "pair.build should not call compute_hunks(text)")
end

-- get_or_build hit: second call with identical texts does not recompute.
do
  local count, restore = spy_compute()
  local views, restore_view = spy_view_build()
  local lru = diff_document.new_lru()
  local first = source_pair({ "old" }, { "new" })
  local model1, err1 = diff_document.get_or_build(first, config, { lru = lru })
  local second = source_pair({ "old" }, { "new" })
  local model2, err2 = diff_document.get_or_build(second, config, { lru = lru })
  restore()
  restore_view()
  assert_eq(err1, nil, "first build should succeed")
  assert_eq(err2, nil, "second build should succeed")
  assert_eq(count.n, 1, "identical texts should compute hunks once")
  assert_eq(views.n, 1, "identical texts should build the view once")
  assert_eq(model2.cache_hit, true, "second build should be a cache hit")
  assert_eq(model1.view, model2.view, "hit should reuse the view object")
  assert_eq(model1.base_paths ~= nil, true, "model should include base_paths")
end

-- Miss after text change: no stale display lines.
do
  local count, restore = spy_compute()
  local lru = diff_document.new_lru()
  local first = source_pair({ "old left" }, { "old right" })
  local model1 = assert((diff_document.get_or_build(first, config, { lru = lru })))
  local second = source_pair({ "new left" }, { "new right" })
  local model2 = assert((diff_document.get_or_build(second, config, { lru = lru })))
  restore()
  assert_eq(count.n, 2, "changed texts should recompute")
  assert_eq(model2.cache_hit, false, "changed texts should miss")
  assert_eq(model1.view.left[1], "old left", "first view should keep old left")
  assert_eq(model2.view.left[1], "new left", "second view should show new left")
  assert_eq(model2.view.right[1], "new right", "second view should show new right")
end

-- Diff-option flip is a miss.
do
  local count, restore = spy_compute()
  local lru = diff_document.new_lru()
  local sources = source_pair({ "a b" }, { "a  b" })
  assert((diff_document.get_or_build(sources, { diff = { ignore_whitespace = false } }, { lru = lru })))
  assert((diff_document.get_or_build(sources, { diff = { ignore_whitespace = true } }, { lru = lru })))
  restore()
  assert_eq(count.n, 2, "ignore_whitespace flip should miss the cache")
end

-- LRU evicts the oldest extra entries.
do
  local count, restore = spy_compute()
  local lru = diff_document.new_lru(2)
  for i = 1, 3 do
    local sources = source_pair({ "left-" .. i }, { "right-" .. i })
    assert((diff_document.get_or_build(sources, config, { lru = lru })))
  end
  local first = source_pair({ "left-1" }, { "right-1" })
  assert((diff_document.get_or_build(first, config, { lru = lru })))
  restore()
  assert_eq(count.n, 4, "evicted first entry should recompute on reuse")
end

-- replace_sources: identical texts compute once; different texts rebuild display.
do
  local function source(lines)
    return {
      lines = lines,
      text = to_text(lines),
      filetype = "text",
    }
  end
  local initial = { left = source({ "old left" }), right = source({ "old right" }) }
  local next_sources = { left = source({ "new left" }), right = source({ "new right" }) }
  local model = assert((diff_document.get_or_build(initial, config, { lru = diff_document.new_lru() })))
  local fake_session = setmetatable({
    config = config,
    left = initial.left,
    right = initial.right,
    hunks = model.hunks,
    view = model.view,
    document_model = model,
    document_identity = model.identity,
    document_lru = diff_document.new_lru(),
    left_buf = vim.api.nvim_create_buf(false, true),
    right_buf = vim.api.nvim_create_buf(false, true),
  }, { __index = Session })
  fake_session.document_lru = diff_document.new_lru()
  diff_document.lru_put(fake_session.document_lru, model.identity, model)

  function fake_session:reset_pending_file_boundary() end
  function fake_session:update_title() end
  function fake_session:resize_layout() end
  function fake_session:precompute_connector_core_width() end
  function fake_session:setup_keymaps() end
  function fake_session:clear_keymaps() end
  function fake_session:set_viewport_toplines_preserve_cursors() end
  function fake_session:clear_active_chunk() end
  function fake_session:render_status_headers() end
  function fake_session:setup_autocmds() end
  function fake_session:clear_buffer_paint_namespaces() end

  local count, restore = spy_compute()
  local seen = {}
  function fake_session:render()
    local left_lines, right_lines = self:display_lines()
    seen.left = left_lines[1]
    seen.right = right_lines[1]
  end

  local ok, err = fake_session:replace_sources(initial, { chunk_position = "top" })
  assert_eq(err, nil, "same-source replace should not error")
  assert_eq(ok, true, "same-source replace should succeed")
  assert_eq(count.n, 0, "same live sources should not recompute hunks")

  ok, err = fake_session:replace_sources(next_sources, { chunk_position = "top" })
  restore()
  assert_eq(err, nil, "Source replacement should not error")
  assert_eq(ok, true, "Source replacement should succeed")
  assert_eq(count.n, 1, "new texts should compute once")
  assert_eq(seen.left, "new left", "Source replacement should rebuild cached left display lines")
  assert_eq(seen.right, "new right", "Source replacement should rebuild cached right display lines")

  pcall(vim.api.nvim_buf_delete, fake_session.left_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, fake_session.right_buf, { force = true })
end

-- In-place editable refresh must miss store.document (same table, new text).
do
  local util_document = require("diffbandit.util.document")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "old right" })
  local sources = {
    left = test_source("left", { "left" }),
    right = {
      label = "right",
      path = "right",
      lines = { "old right" },
      text = to_text({ "old right" }),
      filetype = "text",
      editable = { bufnr = buf },
    },
  }
  local count, restore = spy_compute()
  local model1 = assert((diff_document.get_or_build(sources, config, { store = sources })))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new right" })
  util_document.refresh_source_from_editable(sources.right)
  local model2 = assert((diff_document.get_or_build(sources, config, { store = sources })))
  restore()
  assert_eq(count.n, 2, "editable refresh should recompute hunks")
  assert_eq(model1.cache_hit, false, "first editable build is a miss")
  assert_eq(model2.cache_hit, false, "mutated store.document should miss")
  assert_eq(model2.view.right[1], "new right", "view should follow the refreshed buffer")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- Git source_cache holds the model; wiping it forces a miss.
do
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "one" })
  commit_baseline(repo)
  write_repo_file(repo, "a.txt", { "ONE" })
  local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "a.txt" } }, config.git)))
  local loaded = assert((select(1, queue.load(1))))
  local count, restore = spy_compute()
  local model1 = assert((diff_document.get_or_build(loaded, config, {
    store = loaded,
    lru = diff_document.new_lru(),
  })))
  local loaded_again = assert((select(1, queue.load(1))))
  local model2 = assert((diff_document.get_or_build(loaded_again, config, {
    store = loaded_again,
    lru = diff_document.new_lru(),
  })))
  assert_eq(count.n, 1, "cached git pair should compute once")
  assert_eq(model2.cache_hit, true, "second load should hit store.document")
  assert_eq(loaded.document, model1, "source_cache entry should hold the model")

  queue.source_cache = {}
  local reloaded = assert((select(1, queue.load(1))))
  local model3 = assert((diff_document.get_or_build(reloaded, config, {
    store = reloaded,
    lru = diff_document.new_lru(),
  })))
  restore()
  assert_eq(count.n, 2, "wiping source_cache should miss")
  assert_eq(model3.cache_hit, false, "reloaded pair should rebuild")
end

-- Session.start uses a model already sitting on queue.source_cache (merge hop).
do
  local repo = make_git_repo()
  write_repo_file(repo, "hop.txt", { "base" })
  commit_baseline(repo)
  write_repo_file(repo, "hop.txt", { "changed" })
  local queue = assert((git_mod.queue({ root = repo, mode = "unstaged", pathspecs = { "hop.txt" } }, config.git)))
  local loaded = assert((select(1, queue.load(1))))
  local pre = assert((diff_document.get_or_build(loaded, config, { store = loaded })))
  assert_eq(pre.cache_hit, false, "prefetch-style build is a miss")
  local count, restore = spy_compute()
  local session = assert((Session.start({ left = loaded.left, right = loaded.right }, config, {
    queue = queue,
    chunk_position = "top",
  })))
  restore()
  assert_eq(count.n, 0, "Session.start should reuse queue.source_cache document")
  assert_eq(session.view.right[1], "changed", "started session should show cached right lines")
  session:close()
end

-- Neighbor prefetch builds a document model on the cacheable entry.
do
  local repo = make_git_repo()
  write_repo_file(repo, "one.txt", { "one-base" })
  write_repo_file(repo, "two.txt", { "two-base" })
  commit_baseline(repo)
  write_repo_file(repo, "one.txt", { "one-new" })
  write_repo_file(repo, "two.txt", { "two-new" })
  local queue = assert((git_mod.queue({ root = repo, mode = "unstaged" }, config.git)))
  assert((select(1, queue.load(1))))
  local host = {
    file_queue = queue,
    file_queue_index = 1,
    config = config,
    disposed = false,
  }
  local count, restore = spy_compute()
  queue_host.prefetch_neighbors(host, 1, 0)
  local ready = vim.wait(400, function()
    local neighbor = queue.source_cache[2]
    return neighbor and neighbor.document and neighbor.document.view ~= nil
  end, 10)
  restore()
  assert_eq(ready, true, "prefetch should attach a document to the neighbor")
  local neighbor = queue.source_cache[2]
  assert_eq(neighbor.document.cache_hit, false, "prefetch build is the first compute")
  assert_eq(count.n >= 1, true, "prefetch should compute the neighbor model")

  local hit_count, restore_hit = spy_compute()
  local reused = assert((diff_document.get_or_build(neighbor, config, { store = neighbor })))
  restore_hit()
  assert_eq(hit_count.n, 0, "goto of a prefetched neighbor should not recompute")
  assert_eq(reused.cache_hit, true, "prefetched neighbor should be a store hit")
end

-- Cancelled prefetch token does not start later neighbor work.
do
  local repo = make_git_repo()
  write_repo_file(repo, "a.txt", { "a0" })
  write_repo_file(repo, "b.txt", { "b0" })
  write_repo_file(repo, "c.txt", { "c0" })
  commit_baseline(repo)
  write_repo_file(repo, "a.txt", { "a1" })
  write_repo_file(repo, "b.txt", { "b1" })
  write_repo_file(repo, "c.txt", { "c1" })
  local queue = assert((git_mod.queue({ root = repo, mode = "unstaged" }, config.git)))
  local host = {
    file_queue = queue,
    file_queue_index = 2,
    config = config,
    disposed = false,
  }
  queue_host.prefetch_neighbors(host, 2, 50)
  local token = host.prefetch_token
  host.prefetch_token = token + 1
  vim.wait(200, function()
    return false
  end, 20)
  assert_eq(queue.source_cache[1] == nil or queue.source_cache[1].document == nil, true,
    "cancelled prefetch should not install a document on neighbor 1")
  assert_eq(queue.source_cache[3] == nil or queue.source_cache[3].document == nil, true,
    "cancelled prefetch should not install a document on neighbor 3")
end
