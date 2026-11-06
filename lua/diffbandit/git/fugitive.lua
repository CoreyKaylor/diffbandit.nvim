-- What vim-fugitive's buffers and quickfix lists say about git. Everything that
-- depends on fugitive's formats lives here; it reads them without requiring
-- fugitive, and unknown shapes yield nil, so callers fall back to plain behavior.
local M = {}

-- fugitive://<git dir>//<rev>[/<path>]; rev is a commit, or a stage digit.
function M.parse_url(name)
  local git_dir, object = (name or ""):match("^fugitive://(.-)//(.*)$")
  if not git_dir then
    return nil
  end
  local rev, path = object:match("^([^/]+)/(.+)$")
  return {
    git_dir = vim.uri_decode(git_dir),
    rev = rev or (object ~= "" and object or nil),
    path = path and vim.uri_decode(path) or nil,
  }
end

local function is_commit(rev)
  return rev ~= nil and rev:match("^%x+$") ~= nil and #rev >= 7
end

-- What a quickfix entry shows. name is the entry's buffer name; item is its
-- record from the list context, where difftool and :0Gclog name the left side.
-- Returns { commit } for a commit, { comparison = { mode, base, target } } for a
-- comparison DiffBandit can show, or {} when the entry says nothing either way.
function M.entry_target(name, item)
  local right = M.parse_url(name)
  if right and is_commit(right.rev) and not right.path then
    return { commit = right.rev }
  end
  local left_name = item and item.diff and #item.diff == 1 and item.diff[1].filename
  local left = left_name and M.parse_url(left_name)
  if not left then
    -- The first version of a file in :0Gclog has nothing on the left.
    if right and is_commit(right.rev) then
      return { commit = right.rev }
    end
    return {}
  end
  if left.rev == "0" and not right then
    return { comparison = { mode = "unstaged" } }
  end
  if is_commit(left.rev) then
    if not right then
      return { comparison = { mode = "all", base = left.rev } }
    elseif right.rev == "0" then
      return { comparison = { mode = "staged", base = left.rev } }
    elseif is_commit(right.rev) then
      return { comparison = { mode = "rev", base = left.rev, target = right.rev } }
    end
  end
  return {}
end

-- The current quickfix entry, when the current buffer is what it points at.
function M.current_entry()
  local list = vim.fn.getqflist({ idx = 0, items = 0, context = 0 })
  local entry = list.items and list.items[list.idx]
  if not entry or entry.bufnr ~= vim.api.nvim_get_current_buf() then
    return nil
  end
  return entry, list.items, list.idx, list.context
end

function M.context_item(context, idx)
  return type(context) == "table" and type(context.items) == "table" and context.items[idx] or nil
end

local SECTION_MODE = {
  Untracked = "unstaged",
  Unstaged = "unstaged",
  Staged = "staged",
}

-- The line under the cursor in fugitive's status buffer: { path, status, mode }
-- for a file (mode is nil in sections without one, like Unmerged), or { commit }.
-- Expanded inline diff lines belong to the file above them.
function M.status_target()
  if vim.bo.filetype ~= "fugitive" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, vim.fn.line("."), false)
  local row = #lines
  while row >= 1 and lines[row]:match("^[ +@%-]") do
    row = row - 1
  end
  local line = lines[row]
  if not line or line == "" then
    return nil
  end
  local section
  for index = row - 1, 1, -1 do
    if lines[index]:match("^%u%a+.* %(%d+%+?%)$") then
      section = lines[index]:match("^(%u%a+)")
      break
    end
  end
  if not section then
    return nil
  end
  local status, rest = line:match("^(%S) (.+)$")
  if status then
    -- A rename reads "R old -> new".
    local path = status == "R" and rest:match("^.- %-> (.+)$") or rest
    return { path = path, status = status, mode = SECTION_MODE[section] }
  end
  local commit = line:match("^(%x%x%x%x%x%x%x+) ")
  return commit and { commit = commit } or nil
end

-- The commit the current buffer stands for: a commit or blob object, or the
-- commit line under the cursor in the status buffer.
function M.current_commit()
  local url = M.parse_url(vim.api.nvim_buf_get_name(0))
  if url and is_commit(url.rev) then
    return url.rev
  end
  local target = M.status_target()
  return target and target.commit or nil
end

return M
