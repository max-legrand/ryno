-- Pure diff/hunk logic (no UI). Hunks are line-based against the ORIGINAL text.
local M = {}

---@return string[] lines, boolean trailing_newline
function M.split(s)
  if s == nil or s == "" then
    return {}, false
  end
  local nl = s:sub(-1) == "\n"
  if nl then
    s = s:sub(1, -2)
  end
  return vim.split(s, "\n", { plain = true }), nl
end

function M.join(lines, nl)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. (nl and "\n" or "")
end

local function slice(t, start, count)
  local out = {}
  for i = start, start + count - 1 do
    out[#out + 1] = t[i]
  end
  return out
end

local function as_text(lines)
  return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

---@class RynoHunk
---@field a_start integer  1-based first old line; for pure insertions: the old line AFTER which to insert (0 = top)
---@field a_count integer
---@field b_start integer
---@field b_count integer
---@field old string[]
---@field new string[]
---@field state "pending"|"accepted"|"rejected"

--- First line a hunk side occupies, and the line it ends on (for an empty side: the line before it).
local function side_range(start, count)
  if count > 0 then return start, start + count - 1 end
  return start + 1, start
end

--- Merge hunks separated only by a few unchanged lines when both are much larger than the gap.
--- A rewritten block otherwise shows up as fragments interleaved with whatever generic lines happen
--- to match (`return foo(`, `)`, blank lines), which is hard to read. Like diff-match-patch's semantic
--- cleanup: the gap must be at most `max_gap` lines and at most half the size of each neighbour.
local function coalesce(idx, max_gap)
  if not max_gap or max_gap <= 0 then return idx end
  local out = {}
  for _, h in ipairs(idx) do
    local prev = out[#out]
    if prev then
      local _, prev_end = side_range(prev[1], prev[2])
      local first = side_range(h[1], h[2])
      local gap = first - prev_end - 1
      local size_prev, size_h = math.max(prev[2], prev[4]), math.max(h[2], h[4])
      if gap >= 1 and gap <= max_gap and 2 * gap <= math.min(size_prev, size_h) then
        local a1 = side_range(prev[1], prev[2])
        local _, a2 = side_range(h[1], h[2])
        local b1 = side_range(prev[3], prev[4])
        local _, b2 = side_range(h[3], h[4])
        out[#out] = { a1, a2 - a1 + 1, b1, b2 - b1 + 1 }
        goto continue
      end
    end
    out[#out + 1] = { h[1], h[2], h[3], h[4] }
    ::continue::
  end
  return out
end

--- `opts.merge_gap`: merge hunks separated by at most this many unchanged lines when both are at least
--- twice as large as the gap (default 3; 0 keeps every hunk separate).
---@return RynoHunk[]
function M.hunks(old, new, opts)
  local idx = vim.diff(as_text(old), as_text(new), {
    result_type = "indices",
    algorithm = "histogram",
    indent_heuristic = true,
    ctxlen = 0,
    interhunkctxlen = 0,
  })
  local merge_gap = 3
  if opts and opts.merge_gap ~= nil then merge_gap = opts.merge_gap end
  idx = coalesce(idx, merge_gap)
  local hunks = {}
  for i, h in ipairs(idx) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    hunks[i] = {
      a_start = sa,
      a_count = ca,
      b_start = sb,
      b_count = cb,
      old = slice(old, sa, ca),
      new = slice(new, sb, cb),
      state = "pending",
    }
  end
  return hunks
end

--- Rebuild text from `old` honouring hunk states (accepted -> new, otherwise old).
---@param old string[]
---@param hunks RynoHunk[]
---@param nl boolean trailing newline of the result
function M.apply(old, hunks, nl)
  local out, pos = {}, 1
  for _, h in ipairs(hunks) do
    local first = h.a_count > 0 and h.a_start or (h.a_start + 1)
    for i = pos, first - 1 do
      out[#out + 1] = old[i]
    end
    local src = h.state == "accepted" and h.new or h.old
    for _, l in ipairs(src) do
      out[#out + 1] = l
    end
    pos = first + h.a_count
  end
  for i = pos, #old do
    out[#out + 1] = old[i]
  end
  return M.join(out, nl)
end

--- Inclusive 1-based line range a hunk occupies in the original buffer (for cursor lookup).
function M.range(h, nlines)
  if h.a_count > 0 then
    return h.a_start, h.a_start + h.a_count - 1
  end
  local l = math.max(1, math.min(h.a_start, math.max(nlines, 1)))
  return l, l
end

-- ───────────────────────── intra-line (word) diff ─────────────────────────

--- Split a line into words ([%w_] and non-ASCII runs), whitespace runs, and single other characters.
---@return string[] tokens, integer[] starts 0-based byte offset of each token
local function tokenize(s)
  local toks, starts, i, n = {}, {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local j = i
    if c >= 0x80 or s:sub(i, i):match("[%w_]") then
      while j < n do
        local d = s:byte(j + 1)
        if not (d >= 0x80 or string.char(d):match("[%w_]")) then break end
        j = j + 1
      end
    elseif c == 32 or c == 9 then
      while j < n and (s:byte(j + 1) == 32 or s:byte(j + 1) == 9) do j = j + 1 end
    end
    toks[#toks + 1], starts[#starts + 1] = s:sub(i, j), i - 1
    i = j + 1
  end
  return toks, starts
end

local function non_ws(s)
  local _, n = s:gsub("%S", "")
  return n
end

--- Turn changed token runs into byte ranges, joining runs separated only by whitespace.
local function ranges(line, starts, runs)
  local out = {}
  for _, run in ipairs(runs) do
    local s, e = starts[run[1]], (starts[run[2] + 1] or #line)
    local last = out[#out]
    if last and line:sub(last[2] + 1, s):match("^%s*$") then
      last[2] = e
    else
      out[#out + 1] = { s, e }
    end
  end
  return out
end

--- Which parts of a changed line pair differ, at word granularity.
--- Returns byte ranges `{ {start, end}, ... }` (0-based, end exclusive) for `a` and for `b`, or nil when
--- the lines are identical or share too little for the emphasis to help (the whole line is the change).
---
--- Leading indentation is never emphasised: a re-indented block (e.g. code wrapped in a new `with`/`if`)
--- would otherwise be a wall of highlighted whitespace. Lines that differ only in indentation return nil.
---@return integer[][]|nil, integer[][]|nil, number|nil similarity
function M.inline(a, b)
  if a == b then return nil end
  local ia, ib = #a:match("^%s*"), #b:match("^%s*")
  if ia > 0 or ib > 0 then
    local ra, rb, similarity = M.inline(a:sub(ia + 1), b:sub(ib + 1))
    if not ra then return nil end
    for _, r in ipairs(ra) do r[1], r[2] = r[1] + ia, r[2] + ia end
    for _, r in ipairs(rb) do r[1], r[2] = r[1] + ib, r[2] + ib end
    return ra, rb, similarity
  end
  local ta, sa = tokenize(a)
  local tb, sb = tokenize(b)
  if #ta == 0 or #tb == 0 then return nil end
  local idx = vim.diff(table.concat(ta, "\n") .. "\n", table.concat(tb, "\n") .. "\n", {
    result_type = "indices", algorithm = "histogram", ctxlen = 0, interhunkctxlen = 0,
  })
  local ra, rb, changed_a, changed_b = {}, {}, 0, 0
  for _, h in ipairs(idx) do
    local s1, c1, s2, c2 = h[1], h[2], h[3], h[4]
    if c1 > 0 then
      ra[#ra + 1] = { s1, s1 + c1 - 1 }
      for k = s1, s1 + c1 - 1 do changed_a = changed_a + non_ws(ta[k]) end
    end
    if c2 > 0 then
      rb[#rb + 1] = { s2, s2 + c2 - 1 }
      for k = s2, s2 + c2 - 1 do changed_b = changed_b + non_ws(tb[k]) end
    end
  end
  -- Similarity (Dice): visible characters both lines keep, relative to their average length.
  local na, nb = non_ws(a), non_ws(b)
  local kept = math.min(na - changed_a, nb - changed_b)
  local similarity = na + nb > 0 and 2 * kept / (na + nb) or 1
  if similarity < 0.4 then return nil end
  return ranges(a, sa, ra), ranges(b, sb, rb), similarity
end

--- Pair up the removed and added lines of a hunk that are edits of each other, in order, and diff them.
--- Returns the changed byte ranges on each side and a map from paired old indices to new indices.
---@return table<integer, integer[][]>, table<integer, integer[][]>, table<integer, integer>
function M.inline_hunk(old, new)
  local old_spans, new_spans, matches = {}, {}, {}
  if #old == 0 or #new == 0 or #old * #new > 40000 then return old_spans, new_spans, matches end
  local from = 1
  for i = 1, #old do
    local best, best_a, best_b, score
    -- Pick the strongest nearby match, not the first plausible one (e.g. another function header).
    for j = from, math.min(#new, from + 8) do
      if (old[i]:gsub("^%s+", "")) == (new[j]:gsub("^%s+", "")) then
        -- Unchanged or only re-indented: nothing to emphasise.
        best, best_a, best_b = j, {}, {}
        break
      end
      local ra, rb, similarity = M.inline(old[i], new[j])
      if similarity and (not score or similarity > score) then
        best, best_a, best_b, score = j, ra, rb, similarity
      end
    end
    if best then
      matches[i], old_spans[i], new_spans[best], from = best, best_a, best_b, best + 1
    end
    if from > #new then break end
  end
  return old_spans, new_spans, matches
end

--- Lines of a hunk that only changed indentation, matched by diffing the lines with leading whitespace
--- removed (so wrapping a block in `with lock():` pairs every re-indented line, not just the first few).
--- Returns old_moved[i] = j and new_moved[j] = i for each such pair; blank lines are never paired.
---@return table<integer, integer>, table<integer, integer>
function M.reindented(old, new)
  local old_moved, new_moved = {}, {}
  if #old == 0 or #new == 0 then return old_moved, new_moved end
  local function strip(lines)
    local out = {}
    for i, l in ipairs(lines) do out[i] = (l:gsub("^%s+", "")) end
    return out
  end
  local so, sn = strip(old), strip(new)
  local idx = vim.diff(as_text(so), as_text(sn), {
    result_type = "indices", algorithm = "histogram", ctxlen = 0, interhunkctxlen = 0,
  })
  -- Walk the unchanged runs between the stripped-text hunks.
  local i, j = 1, 1
  local function take(until_i)
    while i < until_i do
      if so[i] ~= "" and old[i] ~= new[j] then old_moved[i], new_moved[j] = j, i end
      i, j = i + 1, j + 1
    end
  end
  for _, h in ipairs(idx) do
    local first_old = h[2] > 0 and h[1] or h[1] + 1
    take(first_old)
    i, j = first_old + h[2], (h[4] > 0 and h[3] or h[3] + 1) + h[4]
  end
  take(#old + 1)
  return old_moved, new_moved
end

function M.counts(hunks)
  local acc, rej, pend = 0, 0, 0
  for _, h in ipairs(hunks) do
    if h.state == "accepted" then
      acc = acc + 1
    elseif h.state == "rejected" then
      rej = rej + 1
    else
      pend = pend + 1
    end
  end
  return acc, rej, pend
end

return M
