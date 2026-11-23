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
-- intra-line (word) diff: byte ranges, 0-based, end exclusive
local function texts(line, rs)
  local out = {}
  for _, r in ipairs(rs or {}) do out[#out + 1] = line:sub(r[1] + 1, r[2]) end
  return out
end
local function inl(a, b)
  local ra, rb = d.inline(a, b)
  return { texts(a, ra), texts(b, rb) }
end
eq(inl("local total = a + b", "local total = a * b"), { { "+" }, { "*" } }, "inline: one operator")
eq(inl('compute(total, "hello world")', 'compute(total, "goodbye world", 3)'), { { "hello" }, { "goodbye", ", 3" } }, "inline: separate words stay separate")
eq(inl("foo bar baz qux", "foo BAR BAZ qux"), { { "bar baz" }, { "BAR BAZ" } }, "inline: runs joined across whitespace")
eq(inl("x = 1", "x = 1 -- note"), { {}, { " -- note" } }, "inline: pure addition")
eq({ d.inline("\tif a then", "    if a then") }, {}, "inline: indentation-only change -> nil")
eq(inl("  x = foo(1)", "      x = foo(2)"), { { "1" }, { "2" } }, "inline: re-indent not emphasised, word change still is")
local ro, rn = d.inline_hunk({ "try:", "  a()" }, { "    try:", "      a()" })
eq({ ro[1], ro[2], rn[1], rn[2] }, { {}, {}, {}, {} }, "inline_hunk: re-indented lines paired without emphasis")

-- wrapping a block in `with lock():` = one new line plus re-indented lines
local mo, mn = d.reindented(
  { "a = 1", "b = 2", "", "c = 3", "d = 4" },
  { "with lock():", "    a = 1", "    b = 2", "", "    c = 30", "    d = 4" }
)
eq(mo, { [1] = 2, [2] = 3, [5] = 6 }, "reindented: old lines that only moved in")
eq(mn, { [2] = 1, [3] = 2, [6] = 5 }, "reindented: new line 1 and changed c are real changes")
local mo2 = d.reindented({ "x" }, { "x" })
eq(mo2, {}, "reindented: identical lines are not re-indents")

-- hunk merging: a rewritten block separated by a couple of generic matching lines becomes one hunk
local OLD = "head\no1\no2\no3\no4\nreturn x(\nok=False,\no5\no6\no7\no8\ntail\n"
local NEW = "head\nn1\nn2\nn3\nn4\nn5\nreturn x(\nok=False,\nn6\nn7\nn8\nn9\ntail\n"
local o, n = d.split(OLD), d.split(NEW)
eq(#d.hunks(o, n, { merge_gap = 0 }), 2, "merge_gap=0: fragments kept")
local merged = d.hunks(o, n)
eq(#merged, 1, "merge: one hunk")
eq({ merged[1].a_start, merged[1].a_count, merged[1].b_start, merged[1].b_count }, { 2, 10, 2, 11 }, "merge: ranges")
eq((run(OLD, NEW, {})), NEW, "merge: accept")
eq((run(OLD, NEW, { "rejected" })), OLD, "merge: reject")
-- small independent edits stay separate even when close together
eq(#d.hunks((d.split("a\nb\nc\nd\n")), (d.split("A\nb\nC\nd\n"))), 2, "merge: one-line edits one line apart stay separate")
-- merge with a pure insertion / pure deletion neighbour
local o2, n2 = (d.split("k\nx1\nx2\nx3\nmid\nz\n")), (d.split("k\nmid\ny1\ny2\ny3\nz\n"))
local m2 = d.hunks(o2, n2)
eq(#m2, 1, "merge: deletion + insertion around one line")
eq((run("k\nx1\nx2\nx3\nmid\nz\n", "k\nmid\ny1\ny2\ny3\nz\n", {})), "k\nmid\ny1\ny2\ny3\nz\n", "merge: deletion + insertion accept")
eq(inl("caf\195\169 x", "caf\195\169 y"), { { "x" }, { "y" } }, "inline: UTF-8 words intact")
eq({ d.inline("completely different", "nothing alike here at all") }, {}, "inline: unrelated lines -> nil")
eq({ d.inline("same", "same") }, {}, "inline: identical -> nil")
local os_, ns_ = d.inline_hunk({ "a = 1", "b = 2" }, { "a = 10", "inserted line here", "b = 20" })
eq({ texts("a = 1", os_[1]), texts("b = 2", os_[2]) }, { { "1" }, { "2" } }, "inline_hunk: old spans")
eq({ ns_[1] ~= nil, ns_[2] == nil, texts("b = 20", ns_[3]) }, { true, true, { "20" } }, "inline_hunk: inserted line skipped, later line still paired")
print(fails == 0 and "diff tests OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
