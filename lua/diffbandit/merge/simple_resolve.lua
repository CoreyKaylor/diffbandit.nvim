-- "Resolve simple conflicts" (the magic wand): a Lua port of IntelliJ's
-- MergeResolveUtil.tryResolve (SimpleHelper) from intellij-community
-- platform/util/diff, Apache 2.0.
--
-- A conflict is simple when both sides changed the same lines but their
-- word-level edits never collide:
--
--   base:   foo(a, b)
--   local:  foo(a, b, c)
--   remote: bar(a, b)
--   result: bar(a, b, c)
--
-- The three texts go through the three-way word comparison
-- (word_diff.compare_merge); every merge range must then be a change on one
-- side only, or the same change on both. A strict pass compares with the
-- default policy, where edits that overlap, touch, or are separated only by
-- whitespace share one range and collide. A whitespace pass then ignores
-- whitespace, so a reindent no longer blocks the other side's real change.
--
-- The rest of the module maps that onto merge-view conflicts: clustering
-- overlapping conflict regions, rebuilding each side's lines for a region,
-- and finding where an untouched region sits in the current result.

local diff = require("diffbandit.diff")
local text = require("diffbandit.util.text")
local word_diff = require("diffbandit.diff.word_diff")

local M = {}

local function strip_whitespace(s)
  return (s:gsub("%s+", ""))
end

-- MergeResolveUtil.SimpleHelper.execute for one policy. Texts are byte
-- strings; returns the merged text or nil when a range is a real conflict.
local function try_policy(left, base, right, policy)
  local texts = { left, base, right }
  local function slice(r, side)
    return texts[side]:sub(r["start" .. side] + 1, r["end" .. side])
  end
  local function is_empty(r, side)
    return r["start" .. side] == r["end" .. side]
  end
  local function equal(r, side1, side2, pol)
    local a, b = slice(r, side1), slice(r, side2)
    if pol == "ignore_whitespace" then
      return strip_whitespace(a) == strip_whitespace(b)
    end
    return a == b
  end

  -- MergeRangeUtil.getMergeType for word fragments (no true equality, no
  -- conflict resolver). Sides: 1 = left, 2 = base, 3 = right.
  local function merge_type(r, pol)
    local left_empty, base_empty, right_empty = is_empty(r, 1), is_empty(r, 2), is_empty(r, 3)
    if base_empty then
      if left_empty then
        return { right = true }
      elseif right_empty then
        return { left = true }
      elseif equal(r, 1, 3, pol) then
        return { left = true, right = true }
      end
      return { conflict = true, left = true, right = true }
    end
    if left_empty and right_empty then
      return { left = true, right = true }
    end
    local unchanged_left = equal(r, 2, 1, pol)
    local unchanged_right = equal(r, 2, 3, pol)
    if unchanged_left and unchanged_right then
      return {}
    end
    if unchanged_left then
      return { right = true }
    end
    if unchanged_right then
      return { left = true }
    end
    if equal(r, 1, 3, pol) then
      return { left = true, right = true }
    end
    return { conflict = true, left = true, right = true }
  end

  local out = {}
  local last1, last2, last3 = 0, 0, 0
  local function next_range(e1, e2, e3)
    local r = { start1 = last1, end1 = e1, start2 = last2, end2 = e2, start3 = last3, end3 = e3 }
    last1, last2, last3 = e1, e2, e3
    return r
  end

  -- Text between change ranges. Under the whitespace policy it can still
  -- hold one side's whitespace edit; keep that edit (default policy).
  local function append_base(r)
    if is_empty(r, 1) and is_empty(r, 2) and is_empty(r, 3) then
      return
    end
    if equal(r, 2, 1, "default") and equal(r, 2, 3, "default") then
      out[#out + 1] = slice(r, 2)
      return
    end
    local t = merge_type(r, "default")
    if t.left then
      out[#out + 1] = slice(r, 1)
    elseif t.right then
      out[#out + 1] = slice(r, 3)
    else
      out[#out + 1] = slice(r, 2)
    end
  end

  local function append_conflict(r)
    local t = merge_type(r, policy)
    if t.conflict or not (t.left or t.right) then
      return false
    end
    out[#out + 1] = t.left and slice(r, 1) or slice(r, 3)
    return true
  end

  for _, fragment in ipairs(word_diff.compare_merge(left, base, right, policy)) do
    append_base(next_range(fragment.start1, fragment.start2, fragment.start3))
    if not append_conflict(next_range(fragment.end1, fragment.end2, fragment.end3)) then
      return nil
    end
  end
  append_base(next_range(#left, #base, #right))
  return table.concat(out)
end

--- MergeResolveUtil.tryResolve: the strict pass, then (unless
--- opts.ignore_whitespace == false) the whitespace pass. Returns the merged
--- text or nil.
function M.resolve_text(left, base, right, opts)
  opts = opts or {}
  local resolved = try_policy(left, base, right, "default")
  if resolved == nil and opts.ignore_whitespace ~= false then
    resolved = try_policy(left, base, right, "ignore_whitespace")
  end
  return resolved
end

-- Lines as text with a newline after every line, so no lines ("") and one
-- empty line ("\n") stay distinct.
local function lines_text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Resolve one conflict given each side's lines. Returns the resolved lines
--- or nil when the conflict is not simple.
function M.resolve_lines(base_lines, local_lines, remote_lines, opts)
  local resolved = M.resolve_text(lines_text(local_lines), lines_text(base_lines), lines_text(remote_lines), opts)
  if resolved == nil then
    return nil
  end
  if resolved == "" then
    return {}
  end
  if resolved:sub(-1) ~= "\n" then
    return nil
  end
  return vim.split(resolved:sub(1, -2), "\n", { plain = true })
end

-- Base lines a hunk side covers, using the region model's convention: a
-- range of count > 0 covers [start, start + count - 1]; an insertion
-- (count 0) sits after line `start` and counts as touching that line.
local function hunk_span(start, count)
  if (count or 0) > 0 then
    return start, start + count - 1
  end
  return start, start
end

--- Group conflict regions whose base ranges overlap (one local hunk can
--- conflict with two remote hunks, which yields two regions over the same
--- lines). Returns clusters { start, count, key, indices } sorted by start,
--- in base coordinates; count 0 is an insertion point after line `start`.
function M.clusters(conflicts)
  local order = {}
  for index in ipairs(conflicts or {}) do
    order[#order + 1] = index
  end
  table.sort(order, function(a, b)
    return (conflicts[a].base_start or 0) < (conflicts[b].base_start or 0)
  end)
  local clusters = {}
  local current
  for _, index in ipairs(order) do
    local region = conflicts[index]
    local count = region.base_count or 0
    local first, last = hunk_span(region.base_start or 0, count)
    if current and first <= current.last then
      current.last = math.max(current.last, last)
      current.has_lines = current.has_lines or count > 0
      current.indices[#current.indices + 1] = index
    else
      current = { first = first, last = last, has_lines = count > 0, indices = { index } }
      clusters[#clusters + 1] = current
    end
  end
  for _, cluster in ipairs(clusters) do
    cluster.start = cluster.first
    cluster.count = cluster.has_lines and (cluster.last - cluster.first + 1) or 0
    cluster.key = tostring(cluster.start) .. ":" .. tostring(cluster.count)
  end
  return clusters
end

--- One side's lines for the base region (start, count): the base lines with
--- every hunk of that side inside the region applied. Returns nil when a
--- hunk reaches outside the region.
function M.side_lines(base_lines, side_lines, hunks, start, count)
  local last = count > 0 and (start + count - 1) or start
  local out = {}
  local cursor = count > 0 and start or (start + 1)
  local function copy_base(to)
    for i = cursor, to do
      out[#out + 1] = base_lines[i] or ""
    end
  end
  for _, hunk in ipairs(hunks or {}) do
    local hs, hc = hunk.left.start, hunk.left.count or 0
    local first, hl = hunk_span(hs, hc)
    if first <= last and start <= hl then
      if hc > 0 then
        if count == 0 or hs < start or hl > last then
          return nil
        end
        copy_base(hs - 1)
        cursor = hs + hc
      else
        if count == 0 and hs ~= start then
          return nil
        end
        copy_base(hs)
        cursor = hs + 1
      end
      for i = hunk.right.start, hunk.right.start + (hunk.right.count or 0) - 1 do
        out[#out + 1] = side_lines[i] or ""
      end
    end
  end
  copy_base(last)
  return out
end

-- Base extent a result edit must stay clear of for the region to count as
-- untouched. Wider than the region itself: an edit that only adds lines at
-- a region edge can be reported by the line diff as an insertion just
-- outside it.
local function guard_extent(start, count)
  if count > 0 then
    return start - 0.5, start + count - 1 + 0.5
  end
  return start - 0.5, start + 1.5
end

local function hunk_extent(start, count)
  if (count or 0) > 0 then
    return start, start + count - 1
  end
  return start + 0.5, start + 0.5
end

--- Base→result line hunks, for locate().
function M.result_hunks(base_lines, result_lines, config)
  local hunks = diff.compute_hunks(text.to_text(base_lines), text.to_text(result_lines), (config or {}).diff or {})
  if type(hunks) ~= "table" then
    return {}
  end
  return hunks
end

--- Where a base region sits in the current result. Returns
--- { start, count, touched, rows_first, rows_count }:
---   start/count: the edit that replaces the region (count 0: insert after
---     row `start`), valid while the region is untouched;
---   touched: the result changed the region (or right next to it);
---   rows_first/rows_count: the rows the region spans now, including the
---     changes that touched it.
function M.locate(result_hunks, start, count)
  local g_first, g_last = guard_extent(start, count)
  local offset, delta, touched = 0, 0, false
  for _, h in ipairs(result_hunks or {}) do
    local h_first, h_last = hunk_extent(h.left.start, h.left.count)
    local h_delta = (h.right.count or 0) - (h.left.count or 0)
    if h_last < g_first then
      offset = offset + h_delta
    elseif h_first <= g_last then
      touched = true
      delta = delta + h_delta
    end
  end
  local anchor = count > 0 and (start - 1) or start
  return {
    start = start + offset,
    count = count,
    touched = touched,
    rows_first = anchor + offset + 1,
    rows_count = math.max(0, count + delta),
  }
end

--- Resolve a cluster against the merge's three sides. Returns the resolved
--- lines, or nil plus a reason ("not_simple" or "unmapped").
function M.resolve_cluster(merge, cluster, opts)
  local base_part = {}
  for i = cluster.start, cluster.start + cluster.count - 1 do
    base_part[#base_part + 1] = merge.base_lines[i] or ""
  end
  local local_part = M.side_lines(merge.base_lines, merge.local_lines, merge.local_hunks, cluster.start, cluster.count)
  local remote_part = M.side_lines(merge.base_lines, merge.remote_lines, merge.remote_hunks, cluster.start, cluster.count)
  if not (local_part and remote_part) then
    return nil, "unmapped"
  end
  local resolved = M.resolve_lines(base_part, local_part, remote_part, opts)
  if not resolved then
    return nil, "not_simple"
  end
  return resolved
end

--- Plan simple resolutions against the current result.
--- merge: { base_lines, local_lines, remote_lines, local_hunks,
---   remote_hunks, conflicts }; result_lines: the current result; only:
---   optional cluster key to restrict the plan to.
--- Returns { edits (bottom-to-top { start, count, replacement, cluster }),
---   clusters, touched, not_simple }.
function M.plan(merge, result_lines, opts)
  opts = opts or {}
  local clusters = M.clusters(merge.conflicts)
  local hunks = M.result_hunks(merge.base_lines, result_lines, opts.config)
  local plan = { edits = {}, clusters = clusters, touched = 0, not_simple = 0 }
  for _, cluster in ipairs(clusters) do
    if not opts.only or opts.only == cluster.key then
      local where = M.locate(hunks, cluster.start, cluster.count)
      if where.touched then
        plan.touched = plan.touched + 1
      else
        local resolved = M.resolve_cluster(merge, cluster, opts)
        if resolved then
          plan.edits[#plan.edits + 1] = {
            start = where.start,
            count = cluster.count,
            replacement = resolved,
            cluster = cluster,
          }
        else
          plan.not_simple = plan.not_simple + 1
        end
      end
    end
  end
  table.sort(plan.edits, function(a, b)
    return a.start > b.start
  end)
  return plan
end

return M
