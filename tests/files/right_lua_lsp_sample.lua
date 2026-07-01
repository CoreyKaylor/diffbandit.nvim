-- Manual inspection fixture:
-- :lua require("diffbandit").files("tests/files/left_lua_lsp_sample.lua", "tests/files/right_lua_lsp_sample.lua")
--
-- The right pane should be a normal editable Lua buffer. With lua_ls attached,
-- this file should show syntax highlighting and diagnostics for:
--   - the unused local `preview_note`
--   - the undefined global `format_currency`
--   - the string passed to `apply_discount`, which expects a number

---@class DiffBanditEditableInvoice
---@field subtotal number
---@field tax_rate number
---@field customer string
---@field discount_percent? number

local M = {}

---@param value number
---@return number
local function round_cents(value)
  return math.floor((value * 100) + 0.5) / 100
end

---@param total number
---@param percent number
---@return number
local function apply_discount(total, percent)
  return round_cents(total - (total * percent))
end

---@param invoice DiffBanditEditableInvoice
---@return table
function M.summarize(invoice)
  local tax = round_cents(invoice.subtotal * invoice.tax_rate)
  local total = round_cents(invoice.subtotal + tax)
  local preview_note = "LuaLS should report this local as unused."

  local discounted_total = apply_discount("not a number", invoice.discount_percent or 0)

  return {
    customer = invoice.customer,
    subtotal = invoice.subtotal,
    tax = tax,
    total = discounted_total,
    display_total = format_currency(discounted_total),
  }
end

return M
