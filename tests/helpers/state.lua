-- Assertions and fixture helpers shared by the integration tests.
-- State files are the "key=value" lines the DB*State commands in
-- tests/integration/init.lua write; git helpers run in the host process.
local M = {}

local function fail(label, message, detail)
  local text = string.format("%s: %s", label or "assertion", message)
  if detail and detail ~= "" then
    text = text .. "\n" .. detail
  end
  error(text, 3)
end

local function as_text(lines)
  return type(lines) == "table" and table.concat(lines, "\n") or tostring(lines or "")
end

--- Substring match anywhere in the state (assert_git_state_contains).
function M.contains(lines, expected, label)
  local text = as_text(lines)
  if not text:find(expected, 1, true) then
    fail(label, "expected '" .. expected .. "'", text)
  end
end

function M.not_contains(lines, unexpected, label)
  local text = as_text(lines)
  if text:find(unexpected, 1, true) then
    fail(label, "did not expect '" .. unexpected .. "'", text)
  end
end

--- Whole-line match (assert_git_state_line_equals / grep -Fx).
function M.line_equals(lines, expected, label)
  for _, line in ipairs(lines) do
    if line == expected then
      return
    end
  end
  fail(label, "expected line '" .. expected .. "'", as_text(lines))
end

--- Value of the first "key=value" line (perf_state_value).
function M.value(lines, key)
  local prefix = key .. "="
  for _, line in ipairs(lines) do
    if line:sub(1, #prefix) == prefix then
      return line:sub(#prefix + 1)
    end
  end
  return nil
end

function M.eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    fail(label, "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

function M.truthy(value, label, detail)
  if not value then
    fail(label, "expected condition to hold", detail)
  end
end

--- Run a command (list) and return code, stdout, stderr.
function M.run(cmd, opts)
  local result = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
  return result.code, result.stdout or "", result.stderr or ""
end

--- Run git in repo; error on failure unless opts.allow_fail.
function M.git(repo, args, opts)
  opts = opts or {}
  local cmd = { "git", "-C", repo }
  vim.list_extend(cmd, args)
  local code, out, err = M.run(cmd, { stdin = opts.stdin })
  if code ~= 0 and not opts.allow_fail then
    error("git " .. table.concat(args, " ") .. " failed (" .. code .. "): " .. err, 2)
  end
  return out, code, err
end

--- Fresh repository with the test identity configured.
function M.init_repo(repo)
  vim.fn.delete(repo, "rf")
  vim.fn.mkdir(repo, "p")
  M.git(repo, { "init", "--quiet" })
  M.git(repo, { "config", "user.email", "diffbandit@example.test" })
  M.git(repo, { "config", "user.name", "DiffBandit Test" })
  return repo
end

--- Write lines (table) or text (string; written verbatim) to path.
function M.write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  if type(content) == "table" then
    vim.fn.writefile(content, path)
  else
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end
end

function M.read(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return vim.fn.readfile(path)
end

function M.diff_contains(repo, mode, file, expected, label)
  local args = mode == "cached" and { "diff", "--cached", "--", file } or { "diff", "--", file }
  local out = M.git(repo, args)
  if not out:find(expected, 1, true) then
    fail(label, "expected '" .. expected .. "' in " .. (mode == "cached" and "cached" or "worktree") .. " diff", out)
  end
end

function M.diff_clean(repo, mode, file, label)
  local args = mode == "cached" and { "diff", "--cached", "--quiet", "--", file } or { "diff", "--quiet", "--", file }
  local _, code = M.git(repo, args, { allow_fail = true })
  if code ~= 0 then
    local shown = M.git(repo, mode == "cached" and { "diff", "--cached", "--", file } or { "diff", "--", file })
    fail(label, (mode == "cached" and "cached" or "worktree") .. " diff not clean", shown)
  end
end

--- Index blob equals expected text (no trailing newline, like "$(git show)").
function M.index_equals(repo, file, expected, label)
  local out = M.git(repo, { "show", ":" .. file }, { allow_fail = true })
  out = out:gsub("\n+$", "")
  if out ~= expected then
    fail(label, "index content mismatch", "Expected:\n" .. expected .. "\nActual:\n" .. out)
  end
end

--- Poll pred (host side) until true or timeout; returns whether it held.
--- Never use vim.wait here: mini.test queues every case with vim.schedule, so
--- running the host event loop starts the next case mid-wait (its post_case
--- then stops this case's child). Sleep without processing events instead.
function M.wait_until(pred, timeout)
  local uv = vim.uv or vim.loop
  local deadline = uv.now() + (timeout or 5000)
  while true do
    if pred() then
      return true
    end
    uv.update_time()
    if uv.now() >= deadline then
      return false
    end
    uv.sleep(10)
  end
end

return M
