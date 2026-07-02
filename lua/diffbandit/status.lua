local config_mod = require("diffbandit.config")
local M = {}

local plain_icons = {
  app = "DiffBandit",
  git = "Git",
  file = "file",
  hunk = "hunk",
  staged = "staged",
}

local nerd_icons = {
  app = "󰕚 DiffBandit",
  git = "󰊢",
  file = "󰈙",
  hunk = "󰡏",
  staged = "󰄬",
}

local function status_config(config)
  return config_mod.section(config, "ui", "status")
end

local function icons_for(config)
  local status = status_config(config)
  local mode = status.icons or "auto"
  local use_nerd = mode == "nerd"
    or (mode == "auto" and (vim.g.diffbandit_have_nerd_font == true or vim.g.have_nerd_font == true))
  local base = vim.deepcopy(use_nerd and nerd_icons or plain_icons)
  return vim.tbl_extend("force", base, status.icon_overrides or {})
end

local function source_path(source)
  if not source then
    return ""
  end
  return source.git_relpath or source.label or source.path or ""
end

local function source_ref(source)
  if not source then
    return "source"
  end
  if source.git_state == "untracked" then
    return "not tracked"
  end
  if source.git_state == "deleted" then
    return "deleted"
  end
  if source.git_target == "absent" then
    return "absent"
  end
  if source.git_ref and source.git_ref ~= "" then
    return source.git_ref
  end
  if source.git_target == "head" then
    return "HEAD"
  end
  if source.git_target == "index" then
    return "index"
  end
  if source.git_target == "worktree" then
    if source.label and source.label:find("%(buffer%)") then
      return "buffer"
    end
    return "working tree"
  end
  if source.git_target == "rev" then
    return "revision"
  end
  if source.path then
    return "file"
  end
  return "buffer"
end

local function entry_status(session)
  local queue = session and session.file_queue
  if not queue or queue.kind ~= "git" then
    return nil
  end
  local entry = queue.entries and queue.entries[session.file_queue_index or queue.index or 1]
  if not entry then
    return nil
  end
  return entry.raw_status or entry.status
end

local function entry_detail(session)
  local queue = session and session.file_queue
  if not queue or queue.kind ~= "git" then
    return nil
  end
  local entry = queue.entries and queue.entries[session.file_queue_index or queue.index or 1]
  if not entry or not entry.old_path or not entry.path then
    return nil
  end
  return entry.old_path .. " -> " .. entry.path
end

local function count_staged_chunks(session)
  local count = 0
  for _, staged in pairs(session.staged_chunk_states or {}) do
    if staged then
      count = count + 1
    end
  end
  return count
end

local function hunk_position(session)
  local total = #(session.view and session.view.chunks or {})
  if total == 0 then
    return "0/0"
  end
  local current = tonumber(session.current_chunk) or 0
  if current < 1 or current > total then
    return "-/" .. tostring(total)
  end
  return tostring(current) .. "/" .. tostring(total)
end

local function file_position(session)
  local queue = session and session.file_queue
  if not queue then
    return nil
  end
  local total = #(queue.entries or {})
  if total == 0 then
    return "0/0"
  end
  return tostring(session.file_queue_index or queue.index or 1) .. "/" .. tostring(total)
end

local function compact_mode(mode)
  if mode == "unstaged" then
    return "unstg"
  elseif mode == "staged" then
    return "stg"
  end
  return mode
end

function M.enabled(config)
  return status_config(config).enabled ~= false
end

function M.build(session)
  local icons = icons_for(session and session.config or {})
  local left = session and session.left or {}
  local right = session and session.right or {}
  local is_git = session and session.file_queue and session.file_queue.kind == "git"

  local left_text = table.concat({
    source_ref(left),
    source_path(left),
  }, "  ")
  local right_text = table.concat({
    source_ref(right),
    source_path(right),
  }, "  ")

  local center_parts = { icons.app }
  local center_compact
  if is_git then
    local mode = ((session.file_queue or {}).opts or {}).mode or "git"
    local file_pos = file_position(session) or "0/0"
    local hunk_pos = hunk_position(session)
    local status = entry_status(session)
    local detail = entry_detail(session)
    local staged = tostring(count_staged_chunks(session))
      .. "/"
      .. tostring(#(session.view and session.view.chunks or {}))
    center_parts[#center_parts + 1] = icons.git .. ":" .. mode
    center_parts[#center_parts + 1] = icons.file .. " " .. file_pos
    center_parts[#center_parts + 1] = icons.hunk .. " " .. hunk_pos
    if status and status ~= "" then
      center_parts[#center_parts + 1] = status
    end
    if detail and detail ~= "" then
      center_parts[#center_parts + 1] = detail
    end
    center_parts[#center_parts + 1] = icons.staged .. " " .. staged

    center_compact = table.concat(vim.tbl_filter(function(part)
      return part and part ~= ""
    end, {
      compact_mode(mode),
      file_pos,
      "h" .. hunk_pos,
      status,
      staged,
    }), " ")
  else
    local hunk_pos = hunk_position(session)
    center_parts[#center_parts + 1] = icons.hunk .. " " .. hunk_pos
    center_compact = "h" .. hunk_pos
  end

  return {
    left = left_text,
    center = table.concat(center_parts, "  "),
    center_compact = center_compact,
    right = right_text,
  }
end

M._private = {
  icons_for = icons_for,
}

return M
