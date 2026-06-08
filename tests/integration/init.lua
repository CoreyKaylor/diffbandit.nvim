-- Minimal init for integration tests
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(script_dir .. "/../..", ":p")

-- Set up runtime path
vim.opt.runtimepath:prepend(root)

-- Load the plugin
require("diffbandit").setup({})
