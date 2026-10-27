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

---@return RynoHunk[]
function M.hunks(old, new)
  local idx = vim.diff(as_text(old), as_text(new), {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
    interhunkctxlen = 0,
  })
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
---@return integer[][]|nil, integer[][]|nil
function M.inline(a, b)
  if a == b then return nil end
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
  if na + nb > 0 and 2 * kept / (na + nb) < 0.4 then return nil end
  return ranges(a, sa, ra), ranges(b, sb, rb)
end

--- Pair up the removed and added lines of a hunk that are edits of each other, in order, and diff them.
--- Returns old_spans[i] and new_spans[j]: the changed byte ranges of paired lines (unpaired: nil).
---@return table<integer, integer[][]>, table<integer, integer[][]>
function M.inline_hunk(old, new)
  local old_spans, new_spans = {}, {}
  if #old == 0 or #new == 0 or #old * #new > 40000 then return old_spans, new_spans end
  local from = 1
  for i = 1, #old do
    -- Look a few lines ahead so a line inserted in the middle doesn't shift every pairing after it.
    for j = from, math.min(#new, from + 8) do
      local ra, rb = M.inline(old[i], new[j])
      if ra then
        old_spans[i], new_spans[j], from = ra, rb, j + 1
        break
      end
    end
    if from > #new then break end
  end
  return old_spans, new_spans
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
