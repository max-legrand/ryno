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
