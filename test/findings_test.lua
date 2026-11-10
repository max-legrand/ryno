vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local findings = require("ryno.findings")
local file = vim.fn.tempname()
vim.fn.writefile({ "one", "two", "three" }, file)
vim.cmd.edit(file)
local buf = api.nvim_get_current_buf()
-- Existing unsaved changes must remain editable and untouched.
api.nvim_buf_set_lines(buf, 1, 2, false, { "unsaved user change" })
local before = api.nvim_buf_get_lines(buf, 0, -1, false)
local config = { focus = true, open = "current" }
local owner, other = {}, {}
findings.show(owner, { { path = file, line = 2, title = "Batch arrivals", body = "Combine counts, not energy.\nVerify a diamond graph. " .. string.rep("界", 110) } }, config)
assert(vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
assert(vim.bo[buf].modified and vim.bo[buf].modifiable)
assert(vim.fn.readfile(file)[2] == "two")
assert(#findings.get(buf) == 1)
assert(#vim.diagnostic.get(buf) == 0, "reviews are not registered as diagnostics")
local lsp_ns = api.nvim_create_namespace("test-lsp")
vim.diagnostic.set(lsp_ns, buf, { { lnum = 2, col = 0, message = "Real compiler error", severity = vim.diagnostic.severity.ERROR } })
api.nvim_win_set_cursor(0, { 1, 0 })
vim.diagnostic.jump({ count = 1, float = false })
assert(api.nvim_win_get_cursor(0)[1] == 3, "diagnostic navigation skips review comments")
vim.diagnostic.jump({ count = -1, float = false })
assert(api.nvim_win_get_cursor(0)[1] == 3, "reverse diagnostic navigation skips reviews too")
vim.diagnostic.reset(lsp_ns)
local blocks = 0
for _, ns in pairs(api.nvim_get_namespaces()) do
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].virt_lines then
      blocks = blocks + 1
      assert(mark[2] == 1 and mark[4].virt_lines_above)
      assert(#mark[4].virt_lines > 4)
      for _, line in ipairs(mark[4].virt_lines) do
        local text = ""
        for _, chunk in ipairs(line) do text = text .. chunk[1] end
        assert(vim.fn.strdisplaywidth(text) <= 110)
      end
    end
  end
end
assert(blocks == 1, "review displayed as a virtual comment block")
assert(api.nvim_get_hl(0, { name = "RynoFindingTitle", link = false }).bold)
assert(api.nvim_get_hl(0, { name = "RynoFindingBody", link = false }).bg, "review blocks have dedicated background")
assert(vim.fn.maparg("]r", "n", false, true).buffer == 1, "next finding has a buffer-local keybinding")
assert(vim.fn.maparg("<leader>ih", "n", false, true).buffer == 1, "hide/show has a keybinding")
findings.show(other, { { path = file, line = 1, title = "Other session", body = "Independent finding" } }, config)
assert(#findings.get(buf) == 2)
findings.next()
assert(api.nvim_win_get_cursor(0)[1] == 2, "next jumps to next review anchor")
findings.next()
assert(api.nvim_win_get_cursor(0)[1] == 1, "next wraps")
findings.prev()
assert(api.nvim_win_get_cursor(0)[1] == 2, "previous wraps")
local function visible_blocks()
  local count = 0
  for _, ns in pairs(api.nvim_get_namespaces()) do
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if mark[4].virt_lines and #mark[4].virt_lines > 0 then count = count + 1 end
    end
  end
  return count
end
local function hidden_markers()
  local count = 0
  for _, ns in pairs(api.nvim_get_namespaces()) do
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if (mark[4].sign_text or ""):find("◆", 1, true) then
        count = count + 1
        assert(mark[4].sign_hl_group == "RynoFindingHidden")
      end
    end
  end
  return count
end
assert(hidden_markers() == 0, "visible reviews do not show hidden-review markers")
findings.hide()
findings.hide()
assert(visible_blocks() == 0 and #findings.get(buf) == 2, "hide all is idempotent and retains findings")
assert(hidden_markers() == 2, "hidden reviews have gutter markers")
findings.list()
assert(#vim.fn.getloclist(0) == 2, "hidden findings remain in the list")
vim.cmd("lclose")
api.nvim_set_current_buf(buf)
findings.toggle()
assert(visible_blocks() == 2, "show restores blocks")
assert(hidden_markers() == 0, "showing reviews removes gutter markers")
findings.show_all()
assert(visible_blocks() == 2, "show all is idempotent")
api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
api.nvim_win_set_cursor(0, { 1, 0 })
findings.next()
assert(api.nvim_win_get_cursor(0)[1] == 2, "navigation follows anchors after user edits")
api.nvim_buf_set_lines(buf, 0, 1, false, {})
api.nvim_win_set_cursor(0, { 2, 0 })
findings.toggle()
findings.next()
assert(visible_blocks() == 2, "jumping reveals hidden findings")
api.nvim_win_set_cursor(0, { 2, 0 })
findings.dismiss()
assert(#findings.get(buf) == 2 and visible_blocks() == 1, "dismiss hides only the comment at cursor and retains it")
assert(hidden_markers() == 1, "dismissed review has a gutter marker")
findings.toggle()
assert(visible_blocks() == 2, "hide/show restores a dismissed comment")
findings.dismiss_all()
assert(visible_blocks() == 0 and #findings.get(buf) == 2, "dismiss all retains reviews")
findings.toggle()
assert(visible_blocks() == 2, "hide/show restores all dismissed comments")
api.nvim_win_set_cursor(0, { 2, 0 })
findings.dismiss()
api.nvim_win_set_cursor(0, { 1, 0 })
findings.next()
assert(api.nvim_win_get_cursor(0)[1] == 2 and visible_blocks() == 2, "navigation can reveal a dismissed comment")
findings.show(owner, {}, config)
assert(#findings.get(buf) == 1, "clearing one session preserves another")
findings.list()
assert(#vim.fn.getloclist(0) == 1)
findings.clear()
assert(#findings.get(buf) == 0)
assert(#vim.diagnostic.get(buf) == 0)
assert(hidden_markers() == 0, "clearing findings removes gutter markers")
local file2 = vim.fn.tempname()
vim.fn.writefile({ "second file" }, file2)
findings.show(owner, {
  { path = file, line = 1, title = "First", body = "First file comment" },
  { path = file2, line = 1, title = "Second", body = "Second file comment" },
}, {
  focus = false, findings_keys = { next = false, toggle = "<leader>iz" },
  hl = { RynoFindingBody = { fg = "#abcdef", bg = "#123456" } },
})
local buf2 = vim.fn.bufnr(file2)
api.nvim_set_current_buf(buf2)
assert(vim.fn.maparg("]r", "n", false, true).buffer ~= 1, "finding key can be disabled")
assert(vim.fn.maparg("<leader>iz", "n", false, true).buffer == 1, "finding key can be customized")
findings.next()
assert(api.nvim_get_current_buf() == buf, "navigation crosses files")
findings.prev()
assert(api.nvim_get_current_buf() == buf2, "previous crosses files")
api.nvim_exec_autocmds("ColorScheme", {})
assert(api.nvim_get_hl(0, { name = "RynoFindingBody", link = false }).fg == 0xabcdef, "custom highlights survive colorscheme changes")
findings.clear()
vim.fn.delete(file2)
vim.cmd("lclose")
api.nvim_set_current_buf(buf)
local source_win = api.nvim_get_current_win()
local long_body = {}
for i = 1, 100 do long_body[i] = "Feedback line " .. i end
local popup_config = { focus = true, findings_display = "popup" }
findings.show(owner, {
  { path = file, line = 1, title = "Scrollable", body = table.concat(long_body, "\n") },
  { path = file, line = 2, title = "Next popup", body = "Second comment" },
}, popup_config)
local popup_win = api.nvim_get_current_win()
local popup_buf = api.nvim_get_current_buf()
assert(popup_win ~= source_win and api.nvim_win_get_config(popup_win).relative == "editor")
assert(not vim.bo[popup_buf].modifiable and vim.bo[popup_buf].buftype == "nofile")
assert(api.nvim_buf_line_count(popup_buf) > api.nvim_win_get_height(popup_win), "long feedback exceeds popup viewport")
assert(visible_blocks() == 0 and hidden_markers() == 2, "popup mode uses anchors, not inline blocks")
vim.cmd("normal! G")
assert(api.nvim_win_get_cursor(0)[1] == 101, "all feedback lines are reachable")
assert(vim.fn.maparg("q", "n", false, true).buffer == 1)
findings.next()
assert(api.nvim_get_current_buf() ~= buf and api.nvim_buf_get_lines(0, 0, 1, false)[1] == "Next popup", "navigation works inside popup")
findings.dismiss()
assert(api.nvim_get_current_win() == source_win and api.nvim_win_get_cursor(0)[1] == 2,
  "dismiss returns to source anchor: expected " .. source_win .. ", got " .. api.nvim_get_current_win())
findings.prev()
findings.hide()
assert(api.nvim_get_current_win() == source_win, "hide closes popup")
findings.next()
assert(api.nvim_get_current_win() ~= source_win, "navigation restores hidden feedback in popup")
findings.clear()
assert(api.nvim_get_current_win() == source_win and not api.nvim_buf_is_valid(popup_buf), "clear cleans up popup buffers")
findings.show(owner, { { path = file, line = 1, title = "Manual", body = "Open manually" } }, {
  focus = false, findings_display = "popup",
})
assert(api.nvim_get_current_win() == source_win, "focus=false does not open popup")
api.nvim_win_set_cursor(0, { 1, 0 })
findings.open()
assert(api.nvim_get_current_win() ~= source_win)
findings.close()
assert(api.nvim_get_current_win() == source_win)
findings.clear()
findings.show(owner, { { path = file, line = 1, title = "Inline", body = "Still supports popup" } }, config)
assert(visible_blocks() == 1, "virtual text remains available")
findings.open()
assert(api.nvim_get_current_win() ~= source_win, "inline comments can also open in popup")
findings.clear()
local anchor_file = vim.fn.tempname()
local source_lines = {}
for i = 1, 100 do source_lines[i] = "source line " .. i end
vim.fn.writefile(source_lines, anchor_file)
vim.cmd.edit(anchor_file)
local anchor_win = api.nvim_get_current_win()
local anchor_config = { focus = false, findings_display = "popup", findings_popup_position = "above" }
findings.show(owner, { { path = anchor_file, line = 50, title = "Anchored", body = table.concat(long_body, "\n") } }, anchor_config)
api.nvim_win_set_cursor(0, { 50, 0 })
vim.cmd("normal! zz")
vim.cmd("redraw")
local origin = api.nvim_win_get_position(anchor_win)
local anchor_row = vim.fn.screenpos(anchor_win, 50, 1).row - origin[1] - 1
findings.open()
local float = api.nvim_win_get_config(0)
assert(float.relative == "win" and float.win == anchor_win, "popup is source-window relative")
assert(float.row + float.height + 2 == anchor_row, "popup border ends immediately above source line")
assert(float.height < #long_body, "anchored popup shrinks to available space")
findings.close()
api.nvim_win_set_cursor(0, { 50, 0 })
vim.cmd("normal! zt")
findings.open()
float = api.nvim_win_get_config(0)
assert(float.relative == "win" and float.row == 1, "top-of-window anchor falls back below")
findings.close()
findings.clear()
api.nvim_set_current_buf(buf)
vim.fn.delete(anchor_file)
assert(vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
vim.fn.delete(file)
print("ALL OK: read-only Neovim review blocks, wrapping, session isolation and clearing")
vim.cmd("qa!")
