-- Init for mini.test workers: `nvim --headless -u tests/minit.lua -c "lua MiniTest.run_file('<file>')"`
-- (tests/run_all.lua does this for every tests/integration/test_*.lua).
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fn.fnamemodify(source, ":p:h:h")

local mini = root .. "/deps/mini.test"
if vim.fn.isdirectory(mini) ~= 1 then
  io.stderr:write("mini.test missing: run tests/deps.sh\n")
  vim.cmd("cquit 1")
end

vim.opt.runtimepath:prepend(mini)
vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/tests/?.lua",
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

-- Isolate children (they inherit this environment) from the user's config,
-- state, and global git configuration.
local sandbox = vim.env.DIFFBANDIT_TEST_ARTIFACTS
if not sandbox or sandbox == "" then
  sandbox = vim.fn.tempname() .. "_diffbandit"
  vim.env.DIFFBANDIT_TEST_ARTIFACTS = sandbox
end
for _, name in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
  local dir = sandbox .. "/.xdg/" .. name:lower()
  vim.fn.mkdir(dir, "p")
  vim.env["XDG_" .. name .. "_HOME"] = dir
end
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_CONFIG_GLOBAL = sandbox .. "/.gitconfig"
vim.fn.writefile({
  "[user]",
  "  name = DiffBandit Test",
  "  email = test@example.invalid",
  "[init]",
  "  defaultBranch = main",
  "[commit]",
  "  gpgsign = false",
}, vim.env.GIT_CONFIG_GLOBAL)
vim.env.TERM = "xterm-256color"
vim.env.COLORTERM = "truecolor"

require("mini.test").setup({
  collect = {
    find_files = function()
      return vim.fn.globpath(root .. "/tests/integration", "test_*.lua", true, true)
    end,
  },
  execute = {
    reporter = nil, -- default: stdout reporter in headless mode
    stop_on_error = false,
  },
})
