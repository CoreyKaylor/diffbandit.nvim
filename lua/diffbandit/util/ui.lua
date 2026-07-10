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

--- Shared remaining-ms budget for merge pair solves. Paint between the two
--- plan phases does not drain the sibling: each consumption re-mints an
--- absolute deadline from leftover ms and debits on release.
--- budget_ms <= 0 → nil (disabled), matching single-session no-budget semantics.
function M.route_plan_budget_share(budget_ms)
  local ms = tonumber(budget_ms)
  if ms == nil then
    ms = 25
  end
  if ms <= 0 then
    return nil
  end
  return { remaining_ms = ms }
end

--- Idle recovery is not under scroll pressure: widen the budget so a starved
--- primary solve is not re-starved on the automatic re-solve.
function M.route_plan_recovery_budget_ms(budget_ms)
  return math.max((tonumber(budget_ms) or 25) * 2, 50)
end

local function mint_absolute_deadline(ms)
  if ms == nil then
    ms = 25
  end
  if ms <= 0 or not (vim.uv and vim.uv.hrtime) then
    return nil
  end
  return vim.uv.hrtime() + ms * 1e6
end

--- Mint a wall-clock deadline for the rail solver (nanoseconds from hrtime).
--- budget_ms <= 0 or missing clock → nil (no wall-clock abort).
--- existing may be:
---   - a remaining-ms bag from route_plan_budget_share — mints from leftover
---     ms on each call so inter-pair paint does not steal sibling budget
---   - nil — mint a fresh absolute deadline from budget_ms
function M.route_plan_deadline(budget_ms, existing)
  if type(existing) == "table" and existing.remaining_ms ~= nil then
    if not (vim.uv and vim.uv.hrtime) then
      -- No wall-clock capability: match single-session (nil = no abort).
      return nil
    end
    local rem = tonumber(existing.remaining_ms) or 0
    if rem <= 0 then
      -- Exhausted: force immediate abort for the next solve.
      return 0
    end
    return vim.uv.hrtime() + rem * 1e6
  end
  return mint_absolute_deadline(tonumber(budget_ms))
end

--- Debit a shared remaining-ms bag after the plan phase (not after paint).
function M.route_plan_budget_release(share, deadline)
  if type(share) ~= "table" or share.remaining_ms == nil then
    return
  end
  if deadline == nil or deadline == 0 or not (vim.uv and vim.uv.hrtime) then
    share.remaining_ms = 0
    return
  end
  local left_ms = (deadline - vim.uv.hrtime()) / 1e6
  share.remaining_ms = math.max(0, left_ms)
end

--- Format the viewport dedupe/paint key (toplines + heights + chunk).
--- Single builder so live and ctx-derived stamps cannot drift on fallbacks.
function M.viewport_render_key(left_topline, right_topline, left_height, right_height, current_chunk)
  return string.format("%s:%s:%d:%d:%d",
    tostring(left_topline), tostring(right_topline),
    left_height or 1, right_height or 1, current_chunk or 0)
end

--- Debounce a host action behind a boolean flag field: first call schedules,
--- later calls coalesce until the deferred fn clears the flag.
--- delay_ms is clamped to >= 0 (negative config values degrade to immediate).
---
--- Cancellation: call cancel_schedule_once (or bump flag_field_gen) before an
--- immediate path so a still-armed defer_fn is a no-op. Clearing the flag alone
--- is not enough if a later schedule_once re-arms before the old timer fires —
--- each arm captures a generation token.
function M.schedule_once(host, flag_field, fn, delay_ms)
  if not host or host[flag_field] then
    return
  end
  host[flag_field] = true
  local gen_field = flag_field .. "_gen"
  host[gen_field] = (host[gen_field] or 0) + 1
  local gen = host[gen_field]
  local delay = math.max(0, tonumber(delay_ms) or 16)
  vim.defer_fn(function()
    if host[gen_field] ~= gen then
      return
    end
    host[flag_field] = false
    if host.disposed then
      return
    end
    fn()
  end, delay)
end

--- Cancel a pending schedule_once / reschedule_once for flag_field.
--- Supersedes any armed defer_fn for that field.
function M.cancel_schedule_once(host, flag_field)
  if not host then
    return
  end
  host[flag_field] = false
  local gen_field = flag_field .. "_gen"
  host[gen_field] = (host[gen_field] or 0) + 1
end

--- Like schedule_once but always restarts the timer (idle debounce). Each call
--- invalidates any prior arm so the fn only runs after delay_ms of quiet.
function M.reschedule_once(host, flag_field, fn, delay_ms)
  if not host then
    return
  end
  -- Cancel bumps gen (invalidates prior timer) and clears the arm flag so
  -- schedule_once re-arms — one timer body, shared cancellation semantics.
  M.cancel_schedule_once(host, flag_field)
  M.schedule_once(host, flag_field, fn, delay_ms)
end

return M
