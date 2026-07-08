-- Lua port of IntelliJ's low-level LCS engine (com.intellij.util.diff, from
-- intellij-community, Apache 2.0): Diff.buildChanges -> Reindexer.discardUnique
-- -> MyersLCS (bidirectional O(ND) middle-snake Myers) -> Reindexer.reindex.
--
-- diffbandit uses this instead of xdiff inside the smart-align pipeline
-- because block boundaries must match IntelliJ's exactly, and two correct
-- Myers implementations legitimately disagree on tie-breaks (equal-cost
-- alignments); the unique-element pre-discard also has no xdiff equivalent.
--
-- Pure Lua, no nvim API. All indices are 0-based like the original; the
-- public API takes 1-based Lua string arrays and returns change ranges as
-- 0-based half-open {start1, end1, start2, end2}.

local M = {}

-- IntelliJ throws FilesTooBigForDiffException past this edit-distance budget
-- and falls back to patience diff. We fall back to an unbounded Myers run
-- instead: same matching family, and the budget (>= 20000 edits) is only
-- exceeded by pathological inputs.
local DELTA_THRESHOLD_SIZE = 20000

local TOO_BIG = {} -- sentinel error value

-- MyersLCS. `first`/`second` are 0-based int arrays (tables with [0]),
-- changes1/changes2 are 0-based boolean sets; true = changed.
local function myers_lcs(first, second, count1, count2, changes1, changes2)
  for i = 0, count1 - 1 do
    changes1[i] = true
  end
  for i = 0, count2 - 1 do
    changes2[i] = true
  end

  local total = count1 + count2
  local v_forward, v_backward = {}, {}
  for i = 0, total + 1 do
    v_forward[i] = 0
    v_backward[i] = 0
  end

  local function common_forward(old_index, new_index, max_length)
    max_length = math.min(max_length, math.min(count1 - old_index, count2 - new_index))
    local x, y = old_index, new_index
    while x - old_index < max_length and first[x] == second[y] do
      x = x + 1
      y = y + 1
    end
    return x - old_index
  end

  local function common_backward(old_index, new_index, max_length)
    max_length = math.min(max_length, math.min(old_index, new_index) + 1)
    local x, y = old_index, new_index
    while old_index - x < max_length and first[x] == second[y] do
      x = x - 1
      y = y - 1
    end
    return old_index - x
  end

  local function add_unchanged(s1, s2, count)
    for i = s1, s1 + count - 1 do
      changes1[i] = false
    end
    for i = s2, s2 + count - 1 do
      changes2[i] = false
    end
  end

  local function execute(old_start, old_end, new_start, new_end, difference_estimate, throw_exception)
    if not (old_start < old_end and new_start < new_end) then
      return
    end
    local old_length = old_end - old_start
    local new_length = new_end - new_start
    v_forward[new_length + 1] = 0
    v_backward[new_length + 1] = 0
    local half_d = math.floor((difference_estimate + 1) / 2)
    local xx, kk, td = -1, -1, -1

    -- bitwise (a xor b) and 1 == parity difference
    local function parity_bit(a, b)
      return (a + b) % 2
    end

    for d = 0, half_d do
      local L = new_length + math.max(-d, -new_length + parity_bit(d, new_length))
      local R = new_length + math.min(d, old_length - parity_bit(d, old_length))

      local k = L
      while k <= R do
        local x
        if k == L or (k ~= R and v_forward[k - 1] < v_forward[k + 1]) then
          x = v_forward[k + 1]
        else
          x = v_forward[k - 1] + 1
        end
        local y = x - k + new_length
        x = x + common_forward(old_start + x, new_start + y,
          math.min(old_end - old_start - x, new_end - new_start - y))
        v_forward[k] = x
        k = k + 2
      end

      if (old_length - new_length) % 2 ~= 0 then
        k = L
        while k <= R do
          if old_length - (d - 1) <= k and k <= old_length + (d - 1) then
            if v_forward[k] + v_backward[new_length + old_length - k] >= old_length then
              xx = v_forward[k]
              kk = k
              td = 2 * d - 1
              break
            end
          end
          k = k + 2
        end
        if td >= 0 then
          goto found
        end
      end

      k = L
      while k <= R do
        local x
        if k == L or (k ~= R and v_backward[k - 1] < v_backward[k + 1]) then
          x = v_backward[k + 1]
        else
          x = v_backward[k - 1] + 1
        end
        local y = x - k + new_length
        x = x + common_backward(old_end - 1 - x, new_end - 1 - y,
          math.min(old_end - old_start - x, new_end - new_start - y))
        v_backward[k] = x
        k = k + 2
      end

      if (old_length - new_length) % 2 == 0 then
        k = L
        while k <= R do
          if old_length - d <= k and k <= old_length + d then
            if v_forward[old_length + new_length - k] + v_backward[k] >= old_length then
              xx = old_length - v_backward[k]
              kk = old_length + new_length - k
              td = 2 * d
              break
            end
          end
          k = k + 2
        end
        if td >= 0 then
          goto found
        end
      end
    end

    ::found::
    if td > 1 then
      local yy = xx - kk + new_length
      local old_diff = math.floor((td + 1) / 2)
      if xx > 0 and yy > 0 then
        execute(old_start, old_start + xx, new_start, new_start + yy, old_diff, throw_exception)
      end
      if old_start + xx < old_end and new_start + yy < new_end then
        execute(old_start + xx, old_end, new_start + yy, new_end, td - old_diff, throw_exception)
      end
    elseif td >= 0 then
      local x, y = old_start, new_start
      while x < old_end and y < new_end do
        local common = common_forward(x, y, math.min(old_end - x, new_end - y))
        if common > 0 then
          add_unchanged(x, y, common)
          x = x + common
          y = y + common
        elseif old_end - old_start > new_end - new_start then
          x = x + 1
        else
          y = y + 1
        end
      end
    else
      -- Difference exceeds the estimate.
      if throw_exception then
        error(TOO_BIG, 0)
      end
    end
  end

  if count1 == 0 or count2 == 0 then
    return
  end

  local threshold = math.max(20000 + 10 * math.floor(math.sqrt(total)), DELTA_THRESHOLD_SIZE)
  local ok, err = pcall(execute, 0, count1, 0, count2, math.min(threshold, total), true)
  if not ok then
    if err ~= TOO_BIG then
      error(err, 0)
    end
    -- Over budget: rerun unbounded (IntelliJ falls back to patience here).
    for i = 0, count1 - 1 do
      changes1[i] = true
    end
    for i = 0, count2 - 1 do
      changes2[i] = true
    end
    execute(0, count1, 0, count2, total, false)
  end
end

-- Reindexer.discardUnique: keep only elements that occur on both sides;
-- remember original indices for reindex().
local function discard(needed_set, to_discard)
  local discarded, old_indices = {}, {} -- 0-based int arrays
  local n = 0
  for i = 0, to_discard.size - 1 do
    local value = to_discard.items[i]
    if needed_set[value] then
      discarded[n] = value
      old_indices[n] = i
      n = n + 1
    end
  end
  return { items = discarded, size = n, old_indices = old_indices, original_length = to_discard.size }
end

local function value_set(arr)
  local set = {}
  for i = 0, arr.size - 1 do
    set[arr.items[i]] = true
  end
  return set
end

-- Reindexer.reindex: translate change sets on the discarded arrays back to
-- the original index space (discarded-away elements are always "changed").
local function reindex(side1, side2, dchanges1, dchanges2)
  local len1, len2 = side1.original_length, side2.original_length
  local d1, d2 = side1.size, side2.size
  local changes1, changes2 = {}, {}

  if d1 == len1 and d2 == len2 then
    changes1, changes2 = dchanges1, dchanges2
  else
    local function increment(indexes, size, i, set, length)
      local from = indexes[i] + 1
      local to = (i + 1 < size) and indexes[i + 1] or length
      for j = from, to - 1 do
        set[j] = true
      end
      return i + 1
    end

    local x, y = 0, 0
    while x < d1 or y < d2 do
      if x < d1 and y < d2 and not dchanges1[x] and not dchanges2[y] then
        x = increment(side1.old_indices, d1, x, changes1, len1)
        y = increment(side2.old_indices, d2, y, changes2, len2)
      elseif x < d1 and dchanges1[x] then
        changes1[side1.old_indices[x]] = true
        x = increment(side1.old_indices, d1, x, changes1, len1)
      elseif y < d2 and dchanges2[y] then
        changes2[side2.old_indices[y]] = true
        y = increment(side2.old_indices, d2, y, changes2, len2)
      end
    end
    if d1 == 0 then
      for j = 0, len1 - 1 do
        changes1[j] = true
      end
    else
      for j = 0, side1.old_indices[0] - 1 do
        changes1[j] = true
      end
    end
    if d2 == 0 then
      for j = 0, len2 - 1 do
        changes2[j] = true
      end
    else
      for j = 0, side2.old_indices[0] - 1 do
        changes2[j] = true
      end
    end
  end

  return changes1, changes2
end

-- Walk the change sets into change ranges (Reindexer.reindex's builder walk).
local function collect_changes(changes1, changes2, len1, len2, shift)
  local out = {}
  local x, y = 0, 0
  local function add(dx, dy)
    if dx ~= 0 or dy ~= 0 then
      out[#out + 1] = {
        start1 = shift + x, end1 = shift + x + dx,
        start2 = shift + y, end2 = shift + y + dy,
      }
      x = x + dx
      y = y + dy
    end
  end
  while x < len1 and y < len2 do
    while x < len1 and y < len2 and not changes1[x] and not changes2[y] do
      x = x + 1
      y = y + 1
    end
    local dx, dy = 0, 0
    while x + dx < len1 and changes1[x + dx] do
      dx = dx + 1
    end
    while y + dy < len2 and changes2[y + dy] do
      dy = dy + 1
    end
    add(dx, dy)
  end
  if x ~= len1 or y ~= len2 then
    add(len1 - x, len2 - y)
  end
  return out
end

-- Diff two 1-based Lua arrays of strings. Returns 0-based half-open change
-- ranges, matching IntelliJ's Diff.buildChanges output exactly.
function M.diff(items1, items2)
  local n1, n2 = #items1, #items2

  local start_shift = 0
  local max_common = math.min(n1, n2)
  while start_shift < max_common and items1[start_shift + 1] == items2[start_shift + 1] do
    start_shift = start_shift + 1
  end
  local end_cut = 0
  local max_cut = math.min(n1, n2) - start_shift
  while end_cut < max_cut and items1[n1 - end_cut] == items2[n2 - end_cut] do
    end_cut = end_cut + 1
  end

  local t1 = n1 - start_shift - end_cut
  local t2 = n2 - start_shift - end_cut
  if t1 == 0 or t2 == 0 then
    if t1 == 0 and t2 == 0 then
      return {}
    end
    return { { start1 = start_shift, end1 = start_shift + t1, start2 = start_shift, end2 = start_shift + t2 } }
  end

  -- Enumerate trimmed lines to ints.
  local ids, next_id = {}, 0
  local function id_of(s)
    local id = ids[s]
    if id == nil then
      id = next_id
      next_id = next_id + 1
      ids[s] = id
    end
    return id
  end
  local ints1, ints2 = {}, {}
  for i = 0, t1 - 1 do
    ints1[i] = id_of(items1[start_shift + i + 1])
  end
  for i = 0, t2 - 1 do
    ints2[i] = id_of(items2[start_shift + i + 1])
  end

  local arr1 = { items = ints1, size = t1 }
  local arr2 = { items = ints2, size = t2 }
  local side1 = discard(value_set(arr2), arr1)
  local side2 = discard(value_set({ items = side1.items, size = side1.size }), arr2)

  if side1.size == 0 and side2.size == 0 then
    return { { start1 = start_shift, end1 = start_shift + t1, start2 = start_shift, end2 = start_shift + t2 } }
  end

  local dchanges1, dchanges2 = {}, {}
  myers_lcs(side1.items, side2.items, side1.size, side2.size, dchanges1, dchanges2)

  local changes1, changes2 = reindex(side1, side2, dchanges1, dchanges2)
  return collect_changes(changes1, changes2, t1, t2, start_shift)
end

return M
