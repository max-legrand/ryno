vim.opt.rtp:prepend(vim.fn.getcwd())
local d = require("ryno.diff")
local fails = 0
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then fails = fails + 1; print("FAIL " .. msg .. "\n  got:  " .. vim.inspect(a) .. "\n  want: " .. vim.inspect(b)) end
end

local function run(old_s, new_s, states)
  local old, onl = d.split(old_s)
  local new, nnl = d.split(new_s)
  local hs = d.hunks(old, new)
  for i, h in ipairs(hs) do h.state = states[i] or "accepted" end
  local all = true
  for _, h in ipairs(hs) do if h.state ~= "accepted" then all = false end end
  return d.apply(old, hs, all and nnl or onl), hs
end

local A = "a\nb\nc\nd\ne\nf\ng\n"
local B = "a\nB\nc\nd\ne\nF\nF2\ng\n"
local r, hs = run(A, B, {})
eq(r, B, "accept all")
eq(#hs, 2, "two hunks")
eq((run(A, B, { "rejected", "rejected" })), A, "reject all")
eq((run(A, B, { "accepted", "rejected" })), "a\nB\nc\nd\ne\nf\ng\n", "first only")
eq((run(A, B, { "rejected", "accepted" })), "a\nb\nc\nd\ne\nF\nF2\ng\n", "second only")
-- pure insertion at top, middle, end; pure deletion
eq((run("a\nb\n", "x\na\nb\n", {})), "x\na\nb\n", "insert top")
eq((run("a\nb\n", "a\nx\nb\n", {})), "a\nx\nb\n", "insert mid")
eq((run("a\nb\n", "a\nb\nx\n", {})), "a\nb\nx\n", "insert end")
eq((run("a\nb\nc\n", "a\nc\n", {})), "a\nc\n", "delete")
eq((run("a\nb\nc\n", "a\nc\n", { "rejected" })), "a\nb\nc\n", "reject delete")
-- new file, empty
eq((run("", "x\ny\n", {})), "x\ny\n", "new file")
eq((run("x\ny\n", "", {})), "", "truncate")
-- ranges
local _, h2 = run("a\nb\n", "x\na\nb\n", {})
eq({ d.range(h2[1], 2) }, { 1, 1 }, "range top insert")
print(fails == 0 and "diff tests OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
