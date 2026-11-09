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
assert(vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
vim.fn.delete(file)
print("ALL OK: read-only Neovim review blocks, wrapping, session isolation and clearing")
vim.cmd("qa!")
