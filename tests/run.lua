-- DiffBandit headless test runner.
-- Specs under tests/specs/ are concatenated into one chunk so harness locals
-- (assert_eq, fixture helpers, etc.) remain visible. The runner injects an
-- absolute repo root and a line map so package.path works from any cwd and
-- assertion failures report the originating spec file:line.

local function read_spec(path)
  local f, err = io.open(path, "r")
  if not f then
    error("cannot open " .. path .. ": " .. tostring(err))
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function count_lines(text)
  if text == "" then
    return 0
  end
  local n = 1
  for _ in text:gmatch("\n") do
    n = n + 1
  end
  if text:sub(-1) == "\n" then
    n = n - 1
  end
  return math.max(1, n)
end

-- Always resolve from this file's real path (works when cwd is outside the repo).
local runner_source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = vim.fn.fnamemodify(runner_source, ":p:h")
local repo_root = vim.fn.fnamemodify(test_dir .. "/..", ":p"):gsub("/$", "")

local specs = {
  "00_harness.lua",
  "10_connector.lua",
  "20_git_merge.lua",
  "30_session_snap.lua",
  "35_render_recovery.lua",
  "40_oracle.lua",
}

local map_entries = {}
local bodies = {}
for _, name in ipairs(specs) do
  local path = test_dir .. "/specs/" .. name
  local src = read_spec(path)
  if src:sub(-1) ~= "\n" then
    src = src .. "\n"
  end
  bodies[#bodies + 1] = { path = path, name = name, src = src }
end

-- Build preamble (root + line map). Spec body offsets are filled after we
-- know the preamble's line count.
local map_literal_parts = { "{" }
for i, body in ipairs(bodies) do
  map_literal_parts[#map_literal_parts + 1] = string.format(
    "{start=0,path=%q,name=%q},",
    body.path,
    body.name)
end
map_literal_parts[#map_literal_parts + 1] = "}"

local preamble = table.concat({
  string.format("local root = %q\n", repo_root),
  "package.path = package.path .. \";\" .. root .. \"/lua/?.lua;\" .. root .. \"/lua/?/init.lua\"\n",
  "local __SPEC_MAP = " .. table.concat(map_literal_parts) .. "\n",
  [[
local function __map_spec_line(n)
  n = tonumber(n) or 0
  local matched
  for i = 1, #__SPEC_MAP do
    local e = __SPEC_MAP[i]
    if n >= e.start then
      matched = e
    end
  end
  if not matched then
    return "tests/run.lua+specs", n
  end
  return matched.path, n - matched.start + 1
end
]],
})

local preamble_lines = count_lines(preamble)
local cursor = preamble_lines + 1
for i, body in ipairs(bodies) do
  -- Patch start offsets into the map literal we already embedded: rebuild preamble properly.
  map_entries[i] = { start = cursor, path = body.path, name = body.name }
  cursor = cursor + count_lines(body.src)
end

-- Rebuild preamble with real start offsets.
map_literal_parts = { "{" }
for _, e in ipairs(map_entries) do
  map_literal_parts[#map_literal_parts + 1] = string.format(
    "{start=%d,path=%q,name=%q},",
    e.start,
    e.path,
    e.name)
end
map_literal_parts[#map_literal_parts + 1] = "}"

preamble = table.concat({
  string.format("local root = %q\n", repo_root),
  "package.path = package.path .. \";\" .. root .. \"/lua/?.lua;\" .. root .. \"/lua/?/init.lua\"\n",
  "local __SPEC_MAP = " .. table.concat(map_literal_parts) .. "\n",
  [[
local function __map_spec_line(n)
  n = tonumber(n) or 0
  local matched
  for i = 1, #__SPEC_MAP do
    local e = __SPEC_MAP[i]
    if n >= e.start then
      matched = e
    end
  end
  if not matched then
    return "tests/run.lua+specs", n
  end
  return matched.path, n - matched.start + 1
end
]],
})

local parts = { preamble }
for _, body in ipairs(bodies) do
  parts[#parts + 1] = body.src
end

local src = table.concat(parts)
-- Chunkname is absolute path of the runner so debug.getinfo fallbacks stay valid.
local chunk, err = load(src, "@" .. vim.fn.fnamemodify(runner_source, ":p"))
if not chunk then
  error("test load failed: " .. tostring(err))
end
chunk()

vim.api.nvim_out_write("OK\n")
vim.cmd("qa")
