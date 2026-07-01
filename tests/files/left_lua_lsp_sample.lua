-- Manual inspection fixture:
-- :lua require("diffbandit").files("tests/files/left_lua_lsp_sample.lua", "tests/files/right_lua_lsp_sample.lua")

---@class DiffBanditInvoice
---@field subtotal number
---@field tax_rate number
---@field customer string

local M = {}

---@param value number
---@return number
local function round_cents(value)
  return math.floor((value * 100) + 0.5) / 100
end

---@param invoice DiffBanditInvoice
---@return table
function M.summarize(invoice)
  local tax = round_cents(invoice.subtotal * invoice.tax_rate)
  local total = round_cents(invoice.subtotal + tax)

  return {
    customer = invoice.customer,
    subtotal = invoice.subtotal,
    tax = tax,
    total = total,
  }
end

return M
