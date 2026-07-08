local nvim = require("diffbandit.util.nvim")

local M = {}

local set_buffer_options = nvim.set_buffer_options

function M.truncate_display(text, width)
  text = text or ""
  width = math.max(0, width or 0)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 1 then
    return string.rep(" ", width)
  end

  local ellipsis = "…"
  local target_width = width - vim.fn.strdisplaywidth(ellipsis)
  local out = {}
  local used = 0
  local char_count = vim.fn.strchars(text)
  for i = 0, char_count - 1 do
    local char = vim.fn.strcharpart(text, i, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if used + char_width > target_width then
      break
    end
    out[#out + 1] = char
    used = used + char_width
  end
  return table.concat(out) .. ellipsis
end

function M.set_header_line(buf, namespace, text, width)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  text = " " .. M.truncate_display(text or "", math.max(1, (width or 1) - 1))
  set_buffer_options(buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  set_buffer_options(buf, { modifiable = false })
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "DiffBanditStatus", 0, 0, -1)
  local accent_end = text:find("  ", 2, true)
  if accent_end then
    vim.api.nvim_buf_add_highlight(buf, namespace, "DiffBanditStatusAccent", 0, 1, accent_end - 1)
  end
end

function M.set_header_line_with_right(buf, namespace, text, right_text, width)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  width = math.max(1, width or 1)
  text = text or ""
  right_text = right_text or ""
  local right_width = vim.fn.strdisplaywidth(right_text)
  local available_left = width - right_width - 2
  if right_text == "" or available_left < 1 then
    return M.set_header_line(buf, namespace, text, width)
  end
  local left = " " .. M.truncate_display(text, math.max(1, available_left - 1))
  local padding = math.max(1, width - vim.fn.strdisplaywidth(left) - right_width)
  local line = left .. string.rep(" ", padding) .. right_text
  set_buffer_options(buf, { modifiable = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  set_buffer_options(buf, { modifiable = false })
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "DiffBanditStatus", 0, 0, -1)
  local accent_end = line:find("  ", 2, true)
  if accent_end then
    vim.api.nvim_buf_add_highlight(buf, namespace, "DiffBanditStatusAccent", 0, 1, accent_end - 1)
  end
  local start_col = math.max(0, #line - #right_text)
  vim.api.nvim_buf_add_highlight(buf, namespace, "DiffBanditStatusMuted", 0, start_col, -1)
end

function M.truncate_dotted(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local result = ""
  local marker = "..."
  local char_count = vim.fn.strchars(text)
  for index = 0, char_count - 1 do
    local next_text = result .. vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(next_text .. marker) > width then
      break
    end
    result = next_text
  end
  return result .. marker
end

function M.digits_of(count)
  return math.max(3, #tostring(math.max(1, count or 1)))
end

--- Resolve icon mode ("nerd" | "plain") from a config field that is
--- "nerd", "plain", or "auto" (auto follows vim.g.have_nerd_font).
function M.use_nerd_icons(mode)
  mode = mode or "auto"
  return mode == "nerd"
    or (mode == "auto" and (vim.g.diffbandit_have_nerd_font == true or vim.g.have_nerd_font == true))
end

--- Debounce a host action behind a boolean flag field: first call schedules,
--- later calls coalesce until the deferred fn clears the flag.
--- delay_ms is clamped to >= 0 (negative config values degrade to immediate).
function M.schedule_once(host, flag_field, fn, delay_ms)
  if not host or host[flag_field] then
    return
  end
  host[flag_field] = true
  local delay = math.max(0, tonumber(delay_ms) or 16)
  vim.defer_fn(function()
    host[flag_field] = false
    if host.disposed then
      return
    end
    fn()
  end, delay)
end

return M
