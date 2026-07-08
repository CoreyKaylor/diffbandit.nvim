-- Compare diffbandit's compute_hunks output against IntelliJ oracle goldens.
--
-- Run:  timeout 120 nvim --headless -l tools/compare_harness.lua
-- Env switches:
--   DB_FILE=<name-substring>          (limit to matching corpus entries)
--   DB_VERBOSE=1                      (print per-file block diffs)
--
-- Corpus: tools/corpus/<name>.{left,right,golden.json} + manifest.txt,
-- produced by tools/capture_corpus.sh (local-only, gitignored).

-- With `nvim -l`, arg[0] is this script's path.
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(arg[0], ":p:h"), ":h")
vim.opt.rtp:prepend(root)
local diff = require("diffbandit.diff")
local word_diff = require("diffbandit.diff.word_diff")
local config = require("diffbandit.config").defaults()

local corpus = root .. "/tools/corpus"

local function env_flag(name)
  local v = vim.env[name]
  if v == nil or v == "" then
    return nil
  end
  return v ~= "0" and v ~= "false"
end

local diff_opts = vim.deepcopy(config.diff)

local verbose = env_flag("DB_VERBOSE")

-- Normalize a diffbandit hunk side to a 0-based half-open range.
-- vim.diff anchors count==0 sides "after line N" (start == N), which is
-- already the 0-based half-open empty position; count>0 sides are 1-based.
local function norm_side(side)
  if side.count > 0 then
    return side.start - 1, side.start - 1 + side.count
  end
  return side.start, side.start
end

local function hunk_key(h)
  local s1, e1 = norm_side(h.left)
  local s2, e2 = norm_side(h.right)
  return string.format("%d:%d:%d:%d", s1, e1, s2, e2), { s1, e1, s2, e2 }
end

local function range_key(r)
  return string.format("%d:%d:%d:%d", r.start1, r.end1, r.start2, r.end2)
end

local function read_lines_set(blocks)
  -- Set of changed line indices per side, for Jaccard.
  local left, right = {}, {}
  for _, b in ipairs(blocks) do
    for i = b[1], b[2] - 1 do
      left[i] = true
    end
    for i = b[3], b[4] - 1 do
      right[i] = true
    end
  end
  return left, right
end

local function jaccard(a, b)
  local inter, union = 0, 0
  local seen = {}
  for k in pairs(a) do
    seen[k] = true
    union = union + 1
    if b[k] then
      inter = inter + 1
    end
  end
  for k in pairs(b) do
    if not seen[k] then
      union = union + 1
    end
  end
  if union == 0 then
    return 1
  end
  return inter / union
end

-- Minimum boundary distance from block `b` to any block in `list`.
local function min_boundary_distance(b, list)
  local best = math.huge
  for _, o in ipairs(list) do
    local d = math.abs(b[1] - o.start1) + math.abs(b[2] - o.end1)
      + math.abs(b[3] - o.start2) + math.abs(b[4] - o.end2)
    if d < best then
      best = d
    end
  end
  return best
end

local names = {}
if vim.fn.filereadable(corpus .. "/manifest.txt") == 0 then
  print("no corpus: run tools/capture_corpus.sh first")
  vim.cmd("cq")
end
for _, name in ipairs(vim.fn.readfile(corpus .. "/manifest.txt")) do
  if name ~= "" and (not vim.env.DB_FILE or name:find(vim.env.DB_FILE, 1, true)) then
    names[#names + 1] = name
  end
end

local total = { ours = 0, oracle = 0, exact = 0, files = 0, files_exact = 0, jaccard_sum = 0 }
local total_sub = { ours = 0, oracle = 0, exact = 0 }
local total_inner = { oracle = 0, exact = 0 }
local offby = {}

for _, name in ipairs(names) do
  local left_lines, left_text = diff.read_file(corpus .. "/" .. name .. ".left")
  local _, right_text = diff.read_file(corpus .. "/" .. name .. ".right")
  if not left_lines then
    goto continue
  end
  local golden = vim.json.decode(table.concat(vim.fn.readfile(corpus .. "/" .. name .. ".golden.json"), "\n"))
  local hunks = diff.compute_hunks(left_text, right_text, diff_opts)

  -- Layer 1: top-level line blocks.
  local ours, ours_keys = {}, {}
  for _, h in ipairs(hunks) do
    local key, blk = hunk_key(h)
    ours[#ours + 1] = blk
    ours_keys[key] = true
  end
  local exact = 0
  local oracle_missing = {}
  for _, r in ipairs(golden.lines) do
    if ours_keys[range_key(r)] then
      exact = exact + 1
    else
      oracle_missing[#oracle_missing + 1] = r
    end
  end
  for _, b in ipairs(ours) do
    local matched = false
    for _, r in ipairs(golden.lines) do
      if range_key(r) == string.format("%d:%d:%d:%d", b[1], b[2], b[3], b[4]) then
        matched = true
        break
      end
    end
    if not matched then
      local d = min_boundary_distance(b, golden.lines)
      offby[d] = (offby[d] or 0) + 1
    end
  end

  local oracle_blocks = {}
  for _, r in ipairs(golden.lines) do
    oracle_blocks[#oracle_blocks + 1] = { r.start1, r.end1, r.start2, r.end2 }
  end
  local our_left, our_right = read_lines_set(ours)
  local or_left, or_right = read_lines_set(oracle_blocks)
  local jac = (jaccard(our_left, or_left) + jaccard(our_right, or_right)) / 2

  -- Layer 2: sub-blocks (row alignment inside blocks).
  local our_subs, our_sub_keys = 0, {}
  for _, h in ipairs(hunks) do
    local subs = h.sub_hunks or { h }
    for _, s in ipairs(subs) do
      our_subs = our_subs + 1
      local key = hunk_key({ left = s.left, right = s.right })
      our_sub_keys[key] = true
    end
  end
  local oracle_subs, sub_exact = 0, 0
  local oracle_inner, inner_exact = 0, 0
  local right_lines = vim.fn.readfile(corpus .. "/" .. name .. ".right")
  for _, b in ipairs(golden.blocks) do
    for _, sb in ipairs(b.subBlocks) do
      oracle_subs = oracle_subs + 1
      local r = sb.lines or sb
      if our_sub_keys[range_key(r)] then
        sub_exact = sub_exact + 1
      end
    end
    -- Layer 3: inner word fragments, block-scoped like the IDE
    -- (byte==UTF-16 offsets only for ASCII; non-ASCII rows may
    -- legitimately differ in units).
    local br = b.range
    if br.end1 > br.start1 and br.end2 > br.start2 then
      local t1 = table.concat(left_lines, "\n", br.start1 + 1, br.end1)
      local t2 = table.concat(right_lines, "\n", br.start2 + 1, br.end2)
      local ok_split, subs = pcall(word_diff.compare_and_split, t1, t2, br.end1 - br.start1, br.end2 - br.start2)
      local frag_keys = {}
      if ok_split then
        for _, sub in ipairs(subs) do
          for _, f in ipairs(sub.fragments) do
            frag_keys[string.format("%d:%d:%d:%d", f.start1, f.end1, f.start2, f.end2)] = true
          end
        end
      end
      for _, sb in ipairs(b.subBlocks) do
        for _, o in ipairs(sb.inner or {}) do
          oracle_inner = oracle_inner + 1
          if frag_keys[range_key(o)] then
            inner_exact = inner_exact + 1
          end
        end
      end
    end
  end

  total.files = total.files + 1
  total.ours = total.ours + #ours
  total.oracle = total.oracle + #golden.lines
  total.exact = total.exact + exact
  total.jaccard_sum = total.jaccard_sum + jac
  if exact == #golden.lines and #ours == #golden.lines then
    total.files_exact = total.files_exact + 1
  end
  total_sub.ours = total_sub.ours + our_subs
  total_sub.oracle = total_sub.oracle + oracle_subs
  total_sub.exact = total_sub.exact + sub_exact
  total_inner.oracle = total_inner.oracle + oracle_inner
  total_inner.exact = total_inner.exact + inner_exact

  local marker = (exact == #golden.lines and #ours == #golden.lines) and "  " or "* "
  print(string.format("%s%-60s blocks %2d/%2d exact %2d  jac %.3f  subs %2d/%2d exact %2d",
    marker, name:sub(1, 60), #ours, #golden.lines, exact, jac, our_subs, oracle_subs, sub_exact))

  if verbose and exact ~= #golden.lines then
    for _, r in ipairs(oracle_missing) do
      print(string.format("    oracle: left %d..%d right %d..%d", r.start1, r.end1, r.start2, r.end2))
    end
    for _, b in ipairs(ours) do
      local key = string.format("%d:%d:%d:%d", b[1], b[2], b[3], b[4])
      local found = false
      for _, r in ipairs(golden.lines) do
        if range_key(r) == key then
          found = true
          break
        end
      end
      if not found then
        print(string.format("    ours:   left %d..%d right %d..%d", b[1], b[2], b[3], b[4]))
      end
    end
  end

  ::continue::
end

print(string.rep("-", 100))
print(string.format("files %d (fully exact %d)  blocks ours %d oracle %d exact %d (%.1f%%)  mean jaccard %.3f",
  total.files, total.files_exact, total.ours, total.oracle, total.exact,
  total.oracle > 0 and 100 * total.exact / total.oracle or 0,
  total.files > 0 and total.jaccard_sum / total.files or 0))
print(string.format("sub-blocks ours %d oracle %d exact %d (%.1f%%)",
  total_sub.ours, total_sub.oracle, total_sub.exact,
  total_sub.oracle > 0 and 100 * total_sub.exact / total_sub.oracle or 0))
print(string.format("inner fragments oracle %d exact %d (%.1f%%)",
  total_inner.oracle, total_inner.exact,
  total_inner.oracle > 0 and 100 * total_inner.exact / total_inner.oracle or 0))
local mism = {}
for d, n in pairs(offby) do
  mism[#mism + 1] = { d, n }
end
table.sort(mism, function(a, b) return a[1] < b[1] end)
local parts = {}
for _, e in ipairs(mism) do
  parts[#parts + 1] = string.format("d%d:%d", e[1], e[2])
end
print("unmatched-block boundary distance histogram: " .. (next(parts) and table.concat(parts, " ") or "none"))
vim.cmd("qa!")
