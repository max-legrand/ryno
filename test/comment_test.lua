-- Line comments in the review buffer: nvim -l test/comment_test.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local review = require("ryno.review")
local api = vim.api
local fails = 0
local function ok(c, m)
  if not c then fails = fails + 1 end
  print((c and "ok   " or "FAIL ") .. m)
end

local cfg = vim.deepcopy({ focus = true, open = "current", keys = {
  accept = "<leader>ia", reject = "<leader>ir", accept_all = "<leader>iA", reject_all = "<leader>iR",
  next = "]c", prev = "[c", undo = "<leader>iu", comment = "<leader>ic", comment_hunk = "<leader>iC", send = "<leader>is",
} })
local sent
review.setup(cfg, function(m) sent = m end)

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function start(id, original, proposed)
  sent = nil
  review.enqueue({ type = "review", id = id, tool = "edit", path = dir .. "/x.lua", relpath = "x.lua", isNew = false,
    original = original, proposed = proposed })
  return review.active
end

-- type a comment into the popup and submit it
local function type_comment(text)
  local win = api.nvim_get_current_win()
  ok(api.nvim_win_get_config(win).relative ~= "", "comment popup opened")
  api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, -1, false, vim.split(text, "\n"))
  api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
end

local function note_lines(buf)
  local n = 0
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("ryno"), 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      if vl[2] and vl[2][2] == "RynoNote" then n = n + 1 end
    end
  end
  return n
end

vim.g.mapleader = " "

-- 1. comment on proposed line 3 of a 1-hunk change, then reject
local r = start("c1", "a\nb\nc\nd\n", "a\nB1\nB2\nB3\nd\n")
ok(r and #r.hunks == 1, "one hunk")
api.nvim_win_set_cursor(r.win, { 6, 0 }) -- unified buffer: a, b, c (removed), B1, B2, B3, d -> row 6 = B3
require("ryno.review") -- keep local
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>ic", true, false, true), "x", false)
type_comment("use a constant here")
ok(r.hunks[1].state == "pending", "line comment keeps hunk pending")
ok(r.hunks[1].notes and #r.hunks[1].notes == 1, "note stored")
ok(r.hunks[1].notes[1].side == "new" and r.hunks[1].notes[1].i == 3, "note anchored to proposed line 3")
ok(note_lines(r.buf) == 1, "note rendered as a virtual line")

-- accepting a commented hunk is refused
review.accept_hunk()
ok(review.active == r and r.hunks[1].state == "pending", "accept refused for commented hunk")

-- comment on a removed line: removed line 2 ("c") is buffer row 3
api.nvim_win_set_cursor(r.win, { 3, 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>ic", true, false, true), "x", false)
type_comment("why remove c?")
ok(#r.hunks[1].notes == 2 and r.hunks[1].notes[2].side == "old" and r.hunks[1].notes[2].i == 2, "note on removed line")

api.nvim_win_set_cursor(r.win, { 2, 0 })
review.reject_hunk()
ok(sent and sent.action == "reject", "decision sent")
local rj = sent and sent.rejected and sent.rejected[1]
ok(rj and rj.notes and #rj.notes == 2, "notes in decision")
ok(rj and rj.notes[1].side == "new" and rj.notes[1].line == 4 and rj.notes[1].code == "B3" and rj.notes[1].comment == "use a constant here", "proposed-line note payload")
ok(rj and rj.notes[2].side == "old" and rj.notes[2].line == 3 and rj.notes[2].code == "c", "original-line note payload")

-- 2. visual range comment + accept all rejects commented hunks only
r = start("c2", "a\nb\nc\nd\ne\nf\ng\n", "a\nB\nc\nd\ne\nF1\nF2\ng\n")
ok(r and #r.hunks == 2, "two hunks")
api.nvim_win_set_cursor(r.win, { 8, 0 }) -- a, b, B, c, d, e, f, F1, F2, g -> row 8 = F1
api.nvim_feedkeys(api.nvim_replace_termcodes("Vj<leader>ic", true, false, true), "x", false)
type_comment("split this")
local n = r.hunks[2].notes and r.hunks[2].notes[1]
ok(n and n.i == 1 and n.j == 2, "visual range note covers both lines")
review.accept_all()
ok(sent and sent.action == "partial" and sent.accepted == 1, "accept all: commented hunk rejected, other accepted")
ok(sent and sent.rejected and sent.rejected[1].notes[1].endLine == 7, "range note end line")

-- 3. empty comment deletes a note
r = start("c3", "a\nb\n", "a\nX\n")
api.nvim_win_set_cursor(r.win, { 3, 0 }) -- a, b, X
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>ic", true, false, true), "x", false)
type_comment("hmm")
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>ic", true, false, true), "x", false)
type_comment("")
ok(#r.hunks[1].notes == 0, "empty comment deletes the note")
-- whole-hunk comment still rejects
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>iC", true, false, true), "x", false)
type_comment("no")
ok(sent and sent.action == "reject" and sent.rejected[1].comment == "no", "hunk comment rejects")

-- 4. unified layout: removed lines are real buffer lines; re-indented lines are folded
cfg.keys.layout = "<leader>il"
r = start("l1", "def f():\n    a = 1\n    b = 2\n    return a\n",
  "def f():\n    with lock():\n        a = 1\n        b = 2\n    return a\n")
local text = table.concat(api.nvim_buf_get_lines(r.buf, 0, -1, false), "|")
ok(text == "def f():|    with lock():|        a = 1|        b = 2|    return a", "re-indent folded: " .. text)
local long = string.rep("x", 300)
review.reject_all()
r = start("l2", "a\n" .. long .. "\nc\n", "a\nB\nc\n")
local lines = api.nvim_buf_get_lines(r.buf, 0, -1, false)
ok(lines[2] == long and lines[3] == "B", "removed line is a real (scrollable) buffer line")

-- 5. switch to split: native diff of original | proposed, keys work in both panes
api.nvim_win_set_cursor(r.win, { 3, 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>il", true, false, true), "x", false)
ok(r.layout == "split" and r.left and api.nvim_win_is_valid(r.left.win), "split opened")
ok(vim.wo[r.win].diff and vim.wo[r.left.win].diff, "both panes in diff mode")
ok(table.concat(api.nvim_buf_get_lines(r.buf, 0, -1, false), "|") == "a|B|c", "proposed pane holds the proposed text")
ok(table.concat(api.nvim_buf_get_lines(r.left.buf, 0, -1, false), "|") == "a|" .. long .. "|c", "original pane holds the original")
ok(api.nvim_win_get_cursor(r.win)[1] == 2, "cursor kept on the same line")
-- comment on the original pane
api.nvim_set_current_win(r.left.win)
api.nvim_win_set_cursor(r.left.win, { 2, 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>ic", true, false, true), "x", false)
type_comment("keep this")
ok(r.hunks[1].notes and r.hunks[1].notes[1].side == "old" and r.hunks[1].notes[1].i == 1, "comment from the original pane")
ok(note_lines(r.left.buf) == 1, "note shown in the original pane")
-- back to unified
local left_win = r.left.win
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>il", true, false, true), "x", false)
ok(r.layout == "unified" and not r.left and not api.nvim_win_is_valid(left_win), "split closed")
ok(not vim.wo[r.win].diff, "diff mode off")
ok(note_lines(r.buf) == 1, "note follows into unified")
review.reject_hunk()
ok(sent and sent.action == "reject" and sent.rejected[1].notes[1].code == long, "decision carries the note")

-- 6. configured split layout; decide from the split, and the panes are cleaned up
cfg.layout = "split"
r = start("l3", "a\nb\nc\n", "a\nB\nc\n")
ok(r.layout == "split" and r.left, "starts split")
left_win = r.left.win
review.accept_all()
ok(sent and sent.action == "accept", "accepted from split")
ok(not api.nvim_win_is_valid(left_win), "original pane closed after the review")
cfg.layout = nil

-- 7. An insertion before an edited line precedes both copies of that line in unified view.
local old_sig = "def retime(plan, first_new_leg, remaining_duration):"
local new_sig = "def retime(plan, first_new_leg, remaining_duration, *, minimum=None):"
local helper = "def check_stride_pace(seconds, minimum, maximum):\n    return minimum <= seconds <= maximum\n\n\n"
local body = "\n    future = plan['legs'][first_new_leg:]\n"
r = start("l4", old_sig .. body, helper .. new_sig .. body)
ok(#r.hunks == 1, "insertion and signature edit are still one review hunk")
ok(table.concat(api.nvim_buf_get_lines(r.buf, 0, -1, false), "\n") .. "\n"
  == helper .. old_sig .. "\n" .. new_sig .. body, "helper shown above adjacent retime signatures")
review.accept_all()
ok(sent and sent.action == "accept", "aligned hunk can be accepted")

-- 8. An accepted hunk shows only the kept text, and undo restores both sides.
cfg.confirm_send = true
r = start("l5", "before\nold value\nafter\n", "before\nnew value\nafter\n")
review.accept_hunk()
ok(review.active == r and r.hunks[1].state == "accepted", "accepted hunk remains open for confirmation")
ok(vim.deep_equal(api.nvim_buf_get_lines(r.buf, 0, -1, false), { "before", "new value", "after" }),
  "accepted replacement hides its removed line")
api.nvim_win_set_cursor(r.win, { 2, 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>iu", true, false, true), "x", false)
ok(vim.deep_equal(api.nvim_buf_get_lines(r.buf, 0, -1, false), { "before", "old value", "new value", "after" }),
  "undo restores both sides of the replacement")
review.reject_all()

r = start("l6", "before\nremove me\n", "before\n")
review.accept_hunk()
ok(vim.deep_equal(api.nvim_buf_get_lines(r.buf, 0, -1, false), { "before" }), "accepted deletion hides all deleted lines")
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>iu", true, false, true), "x", false)
ok(r.hunks[1].state == "pending", "accepted deletion can be undone from its anchor")
review.reject_all()

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
