local text = require("diffbandit.text")

local uv = vim.uv or vim.loop

local M = {}

function M.parse_md5sum_z(output)
  local digests = {}
  local start = 1
  while start <= #(output or "") do
    local stop = output:find("\0", start, true)
    if not stop then
      break
    end
    local record = output:sub(start, stop - 1)
    local digest, path = record:match("^([%da-fA-F]+)%s+(.+)$")
    if digest and path then
      digests[path] = digest
    end
    start = stop + 1
  end
  return digests
end

function M.parse_digest_lines(output)
  local digests = {}
  for _, line in ipairs(text.split_lines(output)) do
    local digest, path = line:match("^([%da-fA-F]+)%s+(.+)$")
    if digest and path then
      path = path:gsub("^%*", "")
      digests[path] = digest
    end
  end
  return digests
end

function M.parse_line_order(output, paths)
  local digests = {}
  local lines = text.split_lines(output)
  for index, path in ipairs(paths or {}) do
    if lines[index] and lines[index] ~= "" then
      digests[path] = vim.trim(lines[index])
    end
  end
  return digests
end

function M.is_difference_status(status)
  return status == "different"
    or status == "type_mismatch"
    or status == "left_only"
    or status == "right_only"
    or status == "error"
end


-- Filesystem path helpers shared by the tree scanner and row builder.
local function join_path(root, rel)
  if not rel or rel == "" then
    return root
  end
  return root .. "/" .. rel
end

local function path_depth(rel)
  if not rel or rel == "" then
    return 0
  end
  local depth = 0
  for _ in rel:gmatch("/") do
    depth = depth + 1
  end
  return depth
end

local function basename(rel)
  if not rel or rel == "" then
    return ""
  end
  return rel:match("([^/]+)$") or rel
end

local function parent_rel(rel)
  if not rel or rel == "" then
    return nil
  end
  local parent = rel:match("^(.*)/[^/]+$")
  if parent == "" then
    return nil
  end
  return parent
end

local function should_skip(rel, opts)
  local filters = opts or {}
  local includes = filters.include or {}
  local excludes = filters.exclude or {}
  for _, pattern in ipairs(excludes) do
    if pattern ~= "" and rel:find(pattern) then
      return true
    end
  end
  if #includes == 0 then
    return false
  end
  for _, pattern in ipairs(includes) do
    if pattern ~= "" and rel:find(pattern) then
      return false
    end
  end
  return true
end

local function scan_tree(root, opts)
  local entries = {}

  local function scan_dir(rel)
    local dir = join_path(root, rel)
    local handle, err = uv.fs_scandir(dir)
    if not handle then
      if rel ~= "" then
        entries[rel] = {
          rel = rel,
          path = dir,
          kind = "directory",
          error = tostring(err or "unable to scan directory"),
          stat = uv.fs_lstat(dir) or uv.fs_stat(dir),
        }
      end
      return
    end

    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local child_rel = rel == "" and name or (rel .. "/" .. name)
      if not should_skip(child_rel, opts) then
        local full = join_path(root, child_rel)
        local stat = uv.fs_lstat(full)
        local kind = stat and stat.type or typ or "unknown"
        local link_target
        if kind == "link" then
          link_target = uv.fs_readlink(full)
        end
        local stat_error = nil
        if not stat then
          stat_error = "unable to stat path"
        end
        entries[child_rel] = {
          rel = child_rel,
          path = full,
          kind = kind,
          stat = stat,
          link_target = link_target,
          error = stat_error,
        }
        if kind == "directory" then
          scan_dir(child_rel)
        end
      end
    end
  end

  scan_dir("")
  return entries
end

local function compare_direct(left, right)
  if left and left.error then
    return "error"
  end
  if right and right.error then
    return "error"
  end
  if left and not right then
    return "left_only"
  end
  if right and not left then
    return "right_only"
  end
  if not left and not right then
    return "same"
  end
  if left.kind ~= right.kind then
    return "type_mismatch"
  end
  if left.kind == "directory" then
    return "same"
  end
  if left.kind == "link" then
    return left.link_target == right.link_target and "same" or "different"
  end
  if left.kind ~= "file" then
    return "same"
  end
  if (left.stat and left.stat.size) ~= (right.stat and right.stat.size) then
    return "different"
  end
  return "pending"
end

local function sort_rows(rows)
  table.sort(rows, function(a, b)
    if a.rel == b.rel then
      return false
    end
    local a_parts = vim.split(a.rel, "/", { plain = true })
    local b_parts = vim.split(b.rel, "/", { plain = true })
    local count = math.min(#a_parts, #b_parts)
    for i = 1, count do
      if a_parts[i] ~= b_parts[i] then
        return a_parts[i] < b_parts[i]
      end
    end
    return #a_parts < #b_parts
  end)
end

local function build_rows(left_entries, right_entries)
  local seen = {}
  for rel in pairs(left_entries or {}) do
    seen[rel] = true
  end
  for rel in pairs(right_entries or {}) do
    seen[rel] = true
  end

  local rows = {}
  local by_rel = {}
  for rel in pairs(seen) do
    local left = left_entries[rel]
    local right = right_entries[rel]
    local kind = (left and left.kind) or (right and right.kind) or "unknown"
    local row = {
      rel = rel,
      name = basename(rel),
      depth = path_depth(rel),
      parent = parent_rel(rel),
      left = left,
      right = right,
      kind = kind,
      direct_status = compare_direct(left, right),
      status = compare_direct(left, right),
      diff_count = 0,
      pending_count = 0,
      child_count = 0,
    }
    rows[#rows + 1] = row
    by_rel[rel] = row
  end
  sort_rows(rows)
  local children_by_parent = {}
  for _, row in ipairs(rows) do
    local parent_key = row.parent or ""
    children_by_parent[parent_key] = children_by_parent[parent_key] or {}
    children_by_parent[parent_key][#children_by_parent[parent_key] + 1] = row
    if row.parent and by_rel[row.parent] then
      by_rel[row.parent].child_count = by_rel[row.parent].child_count + 1
    end
  end
  for _, children in pairs(children_by_parent) do
    for index, child in ipairs(children) do
      child.sibling_last = index == #children
    end
  end
  return rows, by_rel
end

local function recompute_aggregate(rows, by_rel)
  for _, row in ipairs(rows or {}) do
    row.status = row.direct_status
    row.diff_count = M.is_difference_status(row.status) and 1 or 0
    row.pending_count = row.status == "pending" and 1 or 0
  end

  for i = #(rows or {}), 1, -1 do
    local row = rows[i]
    local parent = row.parent and by_rel[row.parent]
    if parent then
      parent.diff_count = parent.diff_count + (row.diff_count or 0)
      parent.pending_count = parent.pending_count + (row.pending_count or 0)
    end
  end

  for _, row in ipairs(rows or {}) do
    if row.kind == "directory" and row.direct_status == "same" then
      if (row.diff_count or 0) > 0 then
        row.status = "different"
      elseif (row.pending_count or 0) > 0 then
        row.status = "pending"
      end
    end
  end
end

M.parent_rel = parent_rel
M.scan_tree = scan_tree
M.build_rows = build_rows
M.recompute_aggregate = recompute_aggregate

return M
