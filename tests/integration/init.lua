-- Minimal init for integration tests
local root = "/Users/CoreyK/Projects/oss/diffbandit.nvim"

-- Set up runtime path
vim.opt.runtimepath:prepend(root)

-- Load the plugin
require("diffbandit").setup({})
