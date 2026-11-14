-- Run the whole suite in parallel: `nvim -l tests/run_all.lua`
--
-- Jobs: the unit specs (tests/run.lua, one job) plus one mini.test job per
-- tests/integration/test_*.lua. Each job is its own headless nvim with its
-- own artifacts/XDG sandbox, so jobs never share state.
--
-- Environment:
--   DIFFBANDIT_JOBS=N        worker count (default: available parallelism)
--   DIFFBANDIT_TESTS=a,b     only jobs whose name contains one of these
--                            ("unit" selects the unit shards)
--   DIFFBANDIT_SPECS=20,45   run only these unit specs, as one "unit" job
--   DIFFBANDIT_JOB_TIMEOUT   per-job timeout in seconds (default 180)
--   DIFFBANDIT_KEEP=1        keep the artifacts directory even when green
local uv = vim.uv or vim.loop

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fn.fnamemodify(source, ":p:h:h")
local nvim = vim.v.progpath

if vim.fn.isdirectory(root .. "/deps/mini.test") ~= 1 or vim.fn.isdirectory(root .. "/deps/vim-fugitive") ~= 1 then
  local res = vim.system({ root .. "/tests/deps.sh" }, { text = true }):wait()
  if res.code ~= 0 then
    io.stderr:write("tests/deps.sh failed:\n" .. (res.stderr or "") .. "\n")
    os.exit(1)
  end
end

-- The unit specs run as two shards: the git-heavy specs and everything else.
local UNIT_GIT_SPECS = "20,25"
local unit_cmd = { nvim, "--headless", "-u", root .. "/tests/run.lua" }
local jobs
if vim.env.DIFFBANDIT_SPECS and vim.env.DIFFBANDIT_SPECS ~= "" then
  jobs = { { name = "unit", cmd = unit_cmd, ok_marker = "OK" } }
else
  jobs = {
    { name = "unit_git", cmd = unit_cmd, ok_marker = "OK", env = { DIFFBANDIT_SPECS = UNIT_GIT_SPECS } },
    { name = "unit_core", cmd = unit_cmd, ok_marker = "OK", env = { DIFFBANDIT_SPECS_SKIP = UNIT_GIT_SPECS } },
  }
end
for _, file in ipairs(vim.fn.globpath(root .. "/tests/integration", "test_*.lua", true, true)) do
  local rel = vim.fn.fnamemodify(file, ":.")
  jobs[#jobs + 1] = {
    name = vim.fn.fnamemodify(file, ":t:r"):gsub("^test_", ""),
    cmd = {
      nvim, "--headless", "-u", root .. "/tests/minit.lua",
      "-c", string.format("lua MiniTest.run_file(%q)", rel),
    },
  }
end

local filter = vim.env.DIFFBANDIT_TESTS
if filter and filter ~= "" then
  local wanted = vim.split(filter, ",", { trimempty = true })
  jobs = vim.tbl_filter(function(job)
    for _, w in ipairs(wanted) do
      if job.name:find(vim.trim(w), 1, true) then
        return true
      end
    end
    return false
  end, jobs)
end

-- Longest jobs first keeps the pool busy until the end.
local order = { unit = 0, unit_git = 0, unit_core = 0, git_merge = 1, git_actions = 2, git_panel = 3, scroll_additions = 4, scroll_deletions = 5 }
table.sort(jobs, function(a, b)
  return (order[a.name] or 99) < (order[b.name] or 99) or ((order[a.name] or 99) == (order[b.name] or 99) and a.name < b.name)
end)

local parallel = tonumber(vim.env.DIFFBANDIT_JOBS) or (uv.available_parallelism and uv.available_parallelism()) or 4
parallel = math.max(1, parallel)
local timeout_ms = (tonumber(vim.env.DIFFBANDIT_JOB_TIMEOUT) or 180) * 1000

local artifacts = vim.fn.tempname() .. "_diffbandit_run"
if vim.env.DIFFBANDIT_TEST_ARTIFACTS and vim.env.DIFFBANDIT_TEST_ARTIFACTS ~= "" then
  artifacts = vim.env.DIFFBANDIT_TEST_ARTIFACTS
end
vim.fn.mkdir(artifacts, "p")

local started_at = uv.hrtime()
local next_job, running, finished = 1, 0, 0

local function strip_ansi(s)
  return (s:gsub("\27%[[%d;]*m", ""))
end

local function launch(job)
  running = running + 1
  job.started = uv.hrtime()
  local env = {
    DIFFBANDIT_TEST_ARTIFACTS = artifacts .. "/" .. job.name,
    -- Workers draw nothing; keep them from probing a terminal.
    TERM = "dumb",
  }
  for key, value in pairs(job.env or {}) do
    env[key] = value
  end
  vim.fn.mkdir(env.DIFFBANDIT_TEST_ARTIFACTS, "p")
  job.handle = vim.system(job.cmd, { text = true, cwd = root, env = env, timeout = timeout_ms }, function(result)
    job.result = result
    job.ms = (uv.hrtime() - job.started) / 1e6
    running = running - 1
    finished = finished + 1
  end)
end

local function fill()
  while running < parallel and next_job <= #jobs do
    launch(jobs[next_job])
    next_job = next_job + 1
  end
end

fill()
while finished < #jobs do
  vim.wait(50, function()
    return finished == #jobs or (running < parallel and next_job <= #jobs)
  end, 10)
  fill()
end

local failures = {}
for _, job in ipairs(jobs) do
  local r = job.result
  local out = (r.stdout or "") .. (r.stderr or "")
  local ok = r.code == 0 and r.signal == 0
  if ok and job.ok_marker then
    ok = out:find(job.ok_marker, 1, true) ~= nil
  end
  if ok and not job.ok_marker then
    local plain = strip_ansi(out)
    -- mini.test prints "Fails (N)" in its summary; any failure must fail the job.
    local fails = plain:match("Fails %((%d+)%)")
    ok = fails == nil or fails == "0"
    -- A case can vanish without failing (e.g. a host-side vim.wait lets the
    -- next case start and stop the child). Every collected case must report.
    local total = tonumber(plain:match("Total number of cases:%s*(%d+)"))
    local reported = 0
    -- One mark per case: o/x for pass/fail, O/X when the case left notes
    -- (MiniTest.skip reports as a note).
    for marks in plain:gmatch("\n[^\n]-%.lua: ([oOxX]*)") do
      reported = reported + #marks
    end
    if not total or reported ~= total then
      ok = false
      job.note = string.format("%d of %s collected cases reported a result", reported, tostring(total))
    end
  end
  job.ok = ok
  if not ok then
    failures[#failures + 1] = job
  end
end

local total_s = (uv.hrtime() - started_at) / 1e9
for _, job in ipairs(jobs) do
  local status = job.ok and "ok  " or (job.result.signal == 15 or job.result.code == 124) and "TIME" or "FAIL"
  io.stdout:write(string.format("%s %-22s %6.1fs\n", status, job.name, job.ms / 1000))
end

for _, job in ipairs(failures) do
  io.stdout:write(string.format("\n===== %s (exit %s, signal %s) =====\n", job.name, job.result.code, job.result.signal))
  if job.note then
    io.stdout:write(job.note .. "\n")
  end
  io.stdout:write((job.result.stdout or "") .. (job.result.stderr or "") .. "\n")
end

io.stdout:write(string.format("\n%d jobs, %d failed, %.1fs wall (%d workers)\n", #jobs, #failures, total_s, parallel))
if #failures > 0 or vim.env.DIFFBANDIT_KEEP == "1" then
  io.stdout:write("artifacts: " .. artifacts .. "\n")
else
  vim.fn.delete(artifacts, "rf")
end
os.exit(#failures > 0 and 1 or 0)
