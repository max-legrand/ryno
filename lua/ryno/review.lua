-- Inline diff review (avante "legacy" style).
--
-- The user's file buffer is never modified while reviewing: the proposal is shown in a
-- cursorable scratch buffer, with removed lines rendered as virtual lines above it.
-- Each hunk is accepted/rejected individually; when none are pending the
-- result is sent back to the agent.
local diff = require("ryno.diff")

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("ryno")

---@type table|nil
M.active = nil
M.queue = {}
M.done = {} -- id -> { win, line, scratch } kept until the agent reports `applied`
M.send = function(_) end
M.config = {}

-- mix `fg` into `bg` (24-bit ints) by fraction `a`
local function blend(fg, bg, a)
  local function ch(shift)
    local f, b = bit.band(bit.rshift(fg, shift), 255), bit.band(bit.rshift(bg, shift), 255)
    return math.floor(b + (f - b) * a + 0.5)
  end
  return bit.lshift(ch(16), 16) + bit.lshift(ch(8), 8) + ch(0)
end

local syntax_overlay_cache = {}

local function hl()
  local function get(name)
    return api.nvim_get_hl(0, { name = name, link = false })
  end
  -- Derived from the *current* theme and redefined at the start of every review (the theme may load
  -- after this plugin), so these are deliberately not `default`. Override via setup{ hl = { RynoAdd = {...} } }.
  local function set(name, val)
    api.nvim_set_hl(0, name, (M.config.hl or {})[name] or val)
  end

  -- Many minimal themes define DiffAdd/DiffDelete with a foreground only. Then derive tinted
  -- backgrounds from those colours so hunks stay visible; honour themes that do set a background.
  local base = get("Normal").bg or (vim.o.background == "light" and 0xffffff or 0x000000)
  local function pair(group, fallback_group, fallback_rgb)
    local g = get(group)
    local c = g.fg or get(fallback_group).fg or fallback_rgb
    -- Background-only highlights preserve the filetype's foreground syntax colors.
    return g.bg or blend(c, base, 0.16), g.bg or blend(c, base, 0.40), blend(c, base, 0.28)
  end
  local add_bg, add_text_bg = pair("DiffAdd", "Added", 0x40c060)
  local del_bg, del_text_bg, del_cursor_bg = pair("DiffDelete", "Removed", 0xe05050)
  local change = get("DiffChange")
  local change_bg = change.bg or blend(change.fg or 0xd0a030, base, 0.16)
  set("RynoAdd", { bg = add_bg })
  set("RynoDelete", { bg = del_bg })
  set("RynoAddText", { bg = add_text_bg })
  set("RynoDeleteText", { bg = del_text_bg })
  set("RynoDeleteCursor", { bg = del_cursor_bg, bold = true }) -- removed line under the virtual cursor
  set("RynoAddDone", { bg = change_bg })
  set("RynoDeleteDone", { bg = change_bg })
  syntax_overlay_cache = {}

  -- Winbar: same background as WinBar so nothing looks like a boxed button.
  local bg = get("WinBar").bg
  set("RynoWinbar", { fg = get("WinBar").fg, bg = bg })
  set("RynoWinbarTitle", { fg = get("Title").fg or get("WinBar").fg, bg = bg, bold = true })
  set("RynoWinbarKey", { fg = get("Special").fg, bg = bg, bold = true })
  set("RynoWinbarDim", { fg = get("Comment").fg, bg = bg })
  set("RynoWinbarOk", { fg = get("DiagnosticOk").fg or get("String").fg, bg = bg })
  set("RynoWinbarNo", { fg = get("DiagnosticError").fg or get("ErrorMsg").fg, bg = bg })
end

-- mode: nil (plain removed line), true (changed span), "cursor" (line under the virtual cursor)
local function syntax_overlay(source, mode)
  source = source or "Normal"
  local bg_group = mode == "cursor" and "RynoDeleteCursor" or (mode and "RynoDeleteText" or "RynoDelete")
  local key = bg_group .. "/" .. source
  local cached = syntax_overlay_cache[key]
  if cached then return cached end
  local name = "RynoSyntax" .. (mode == "cursor" and "Cursor_" or (mode and "Text_" or "_")) .. source:gsub("[^%w_]", "_")
  local attrs = api.nvim_get_hl(0, { name = source, link = false })
  attrs.bg = api.nvim_get_hl(0, { name = bg_group, link = false }).bg
  api.nvim_set_hl(0, name, attrs)
  syntax_overlay_cache[key] = name
  return name
end

-- ───────────────────────── window / buffer selection ─────────────────────────

local function real(p)
  return (vim.uv or vim.loop).fs_realpath(p) or p
end

local function is_normal_win(w)
  return api.nvim_win_get_config(w).relative == "" and vim.bo[api.nvim_win_get_buf(w)].buftype == ""
end

local function pick_window(path)
  local rp = real(path)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if is_normal_win(w) and real(api.nvim_buf_get_name(api.nvim_win_get_buf(w))) == rp then
          return w
      end
  end
  if is_normal_win(api.nvim_get_current_win()) then
    return api.nvim_get_current_win()
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_normal_win(w) then
      return w
    end
  end
  vim.cmd("botright new")
  return api.nvim_get_current_win()
end

local OPEN_CMDS = { split = "belowright split", vsplit = "belowright vsplit", tab = "tab split" }

--- Window to show the review in, per `config.open`:
---   "current" (default) reuse the current/matching window; "split" / "vsplit" / "tab" open a new one.
--- New windows are closed again when the review ends. Returns win, opened(bool), origin_win.
local function open_window(path)
  local mode = M.config.open or "current"
  local origin = api.nvim_get_current_win()
  if mode == "current" then
    return pick_window(path), false, origin
  end
  local cmd = OPEN_CMDS[mode]
  if not cmd then
    vim.notify(("ryno: unknown open mode %q (use current, split, vsplit or tab)"):format(tostring(mode)), vim.log.levels.WARN)
    return pick_window(path), false, origin
  end
  -- split from the window showing the file (or a normal window); `split` keeps its buffer, so no
  -- stray [No Name] buffer is created
  api.nvim_set_current_win(pick_window(path))
  vim.cmd(cmd)
  local win = api.nvim_get_current_win()
  if not M.config.focus and api.nvim_win_is_valid(origin) then
    api.nvim_set_current_win(origin)
  end
  return win, true, origin
end

local function same_lines(buf, old)
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #old == 0 then
    return #cur == 0 or (#cur == 1 and cur[1] == "")
  end
  return vim.deep_equal(cur, old)
end

local function make_scratch(r, lines, suffix)
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  local ft = vim.filetype.match({ filename = r.msg.path })
  local name
  if suffix == "old" then
    name = "ryno://old/" .. r.msg.relpath
  else
    -- Give native vim.lsp.enable() a normal, same-directory URI/filetype so configured servers
    -- can attach and analyze the proposed text. This is only a buffer name: no preview file is made.
    local dir, stem, ext = vim.fn.fnamemodify(r.msg.path, ":p:h"), vim.fn.fnamemodify(r.msg.path, ":t:r"), vim.fn.fnamemodify(r.msg.path, ":e")
    local id = tostring(r.id):gsub("[^%w_-]", "_")
    name = dir .. "/.ryno-" .. stem .. "-" .. id .. (ext ~= "" and ("." .. ext) or "")
  end
  pcall(api.nvim_buf_set_name, b, name)
  vim.bo[b].buftype = ""
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if ft then
    vim.bo[b].filetype = ft
  end
  vim.bo[b].modified = false
  vim.bo[b].modifiable = false
  return b
end

-- ───────────────────────── rendering ─────────────────────────

-- Display form of a mapping: <leader> -> ␣ (or the leader char), <CR> -> ↵.
local function show(lhs)
  local leader = vim.g.mapleader or "\\"
  leader = leader == " " and "␣" or leader
  local out = lhs:gsub("<[Ll]eader>", leader)
  out = out:gsub("<[Ss]pace>", "␣"):gsub("<[Cc][Rr]>", "↵")
  return out
end

local function fmt(parts)
  local out, w = {}, 0
  for _, p in ipairs(parts) do
    out[#out + 1] = "%#" .. p[2] .. "#" .. (p[1]:gsub("%%", "%%%%"))
    w = w + vim.fn.strdisplaywidth(p[1])
  end
  return table.concat(out), w
end

local winbar_impl

--- Evaluated by the window's 'winbar' on every redraw, so it adapts to the window width.
--- Errors inside statusline expressions vanish silently, so surface them in the bar instead.
function M.winbar()
  local ok, res = pcall(winbar_impl)
  if ok then
    return res
  end
  return "%#ErrorMsg# ryno winbar: " .. tostring(res):gsub("%%", "%%%%"):gsub("\n", " ")
end

winbar_impl = function()
  local r = M.active
  -- the window being drawn: g:actual_curwin (a string) for winbars, g:statusline_winid for statuslines
  local drawing = tonumber(vim.g.actual_curwin) or vim.g.statusline_winid or api.nvim_get_current_win()
  if not r or not r.hunks or drawing ~= r.win then
    return ""
  end
  local width = api.nvim_win_get_width(r.win)
  local k = M.config.keys
  local acc, rej, pend = diff.counts(r.hunks)

  local function left(name)
    local parts = {
      { " ryno ", "RynoWinbarTitle" },
      { (r.msg.tool or "edit") .. " ", "RynoWinbarDim" },
      { name, "RynoWinbar" },
      { r.msg.post and "  already applied" or "", "RynoWinbarNo" },
      { "  ", "RynoWinbar" },
    }
    if acc > 0 then
      parts[#parts + 1] = { acc .. "✓ ", "RynoWinbarOk" }
    end
    if rej > 0 then
      parts[#parts + 1] = { rej .. "✗ ", "RynoWinbarNo" }
    end
    parts[#parts + 1] = { pend .. " pending", "RynoWinbarDim" }
    return parts
  end
  local function hint(key, what)
    return { { show(key), "RynoWinbarKey" }, { " " .. what .. "  ", "RynoWinbarDim" } }
  end
  local function join(...)
    local out = {}
    for _, group in ipairs({ ... }) do
      for _, p in ipairs(group) do
        out[#out + 1] = p
      end
    end
    return out
  end

  -- for a post-hoc review the change is already on disk: reject means "roll back"
  local yes, no = "accept", "reject"
  local yes_all, no_all = "accept all", "reject all"
  if r.msg.post then
    yes, no, yes_all, no_all = "keep", "roll back", "keep all", "roll back all"
  end
  local rights = {
    join(
      hint(k.accept, yes), hint(k.reject, no),
      hint(k.accept_all, yes_all), hint(k.reject_all, no_all),
      hint(k.next .. "/" .. k.prev, "jump")
    ),
    join(hint(k.accept, yes), hint(k.reject, no), hint(k.accept_all, "all"), hint(k.reject_all, "none")),
    join(hint(k.accept, r.msg.post and "keep" or "✓"), hint(k.reject, r.msg.post and "undo" or "✗")),
    {},
  }
  local names = { r.msg.relpath, vim.fn.fnamemodify(r.msg.relpath, ":t") }

  for _, name in ipairs(names) do
    local ls, lw = fmt(left(name))
    for _, rp in ipairs(rights) do
      local rs, rw = fmt(rp)
      if lw + rw <= width then
        return ls .. "%#RynoWinbar#%=" .. rs
      end
    end
  end
  local ls = fmt(left(names[2]))
  return ls
end

local WINBAR_EXPR = "%{%v:lua.require('ryno.review').winbar()%}"

-- Common prefix/suffix (UTF-8 safe) between an old and a new line, for intra-line highlighting.
-- Returns nil when the lines share too little for a span to be meaningful.
local function is_cont(byte)
  return byte ~= nil and bit.band(byte, 0xC0) == 0x80
end

local function changed_span(a, b)
  local n = math.min(#a, #b)
  local p = 0
  while p < n and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  while p > 0 and (is_cont(a:byte(p + 1)) or is_cont(b:byte(p + 1))) do
    p = p - 1
  end
  local sfx = 0
  while sfx < n - p and a:byte(#a - sfx) == b:byte(#b - sfx) do
    sfx = sfx + 1
  end
  while sfx > 0 and (is_cont(a:byte(#a - sfx + 1)) or is_cont(b:byte(#b - sfx + 1))) do
    sfx = sfx - 1
  end
  if (p + sfx) * 10 < math.max(#a, #b) * 4 or (p == 0 and sfx == 0) then
    return nil
  end
  return p, sfx
end

local function preview(r)
  -- Pending/accepted hunks show the proposed text as real buffer lines, so normal cursor
  -- movement can inspect every line. Rejected hunks revert to the original text in the preview.
  local out, pos = {}, 1
  for _, h in ipairs(r.hunks) do
    local first = h.a_count > 0 and h.a_start or (h.a_start + 1)
    for i = pos, first - 1 do out[#out + 1] = r.old[i] end
    h.display_start = #out + 1
    local src = h.state == "rejected" and h.old or h.new
    h.display_count = #src
    for _, line in ipairs(src) do out[#out + 1] = line end
    pos = first + h.a_count
  end
  for i = pos, #r.old do out[#out + 1] = r.old[i] end
  return out
end

local function syntax_group(buf, row, col)
  local info = vim.inspect_pos(buf, row, col)
  local syntax = info.syntax
  if syntax and #syntax > 0 then
    local item = syntax[#syntax]
    return item.hl_group, item.end_col
  end
  -- Treesitter captures are highlight group names (e.g. @function); use them when syntax is absent.
  local ts = info.treesitter
  if ts and #ts > 0 then
    local item = ts[#ts]
    return item.capture, item.end_col
  end
  return nil, nil
end

local function syntax_chunks(buf, row, line, base_hl, strong_hl)
  local chunks, col, active, start = {}, 0, nil, 0
  while col < #line do
    local group, finish = syntax_group(buf, row, col)
    local next_col = finish and finish > col and finish or (col + 1)
    -- Keep UTF-8 codepoints intact when inspect_pos has no token span.
    if next_col == col + 1 then
      while next_col < #line and bit.band(line:byte(next_col + 1), 0xC0) == 0x80 do next_col = next_col + 1 end
    end
    local changed = strong_hl and strong_hl(col, next_col)
    local hl_group = syntax_overlay(group, changed)
    if hl_group ~= active then
      if col > start then chunks[#chunks + 1] = { line:sub(start + 1, col), active } end
      start, active = col, hl_group
    end
    col = math.min(next_col, #line)
  end
  if #line > start then chunks[#chunks + 1] = { line:sub(start + 1), active or base_hl } end
  if #chunks == 0 then chunks[1] = { "", base_hl } end
  return chunks
end

-- Removed lines are virtual (not buffer lines), so the cursor can't land on them. Instead the review keeps
-- a "virtual cursor" `r.vpos = { h = hunk, i = index into h.old }`: while set, the real cursor sits on the
-- buffer row the virtual lines are attached to, and j/k walk through the removed lines (see `vstep`).
local function attach_row(r, h)
  return math.max(0, math.min(h.display_start - 1, api.nvim_buf_line_count(r.buf) - 1))
end

local function virt_chunks(r, h, i, selected)
  local done = h.state == "accepted"
  local base = selected and "RynoDeleteCursor" or (done and "RynoDeleteDone" or "RynoDelete")
  local winw = api.nvim_win_is_valid(r.win) and api.nvim_win_get_width(r.win) or 80
  local textoff = api.nvim_win_is_valid(r.win) and (vim.fn.getwininfo(r.win)[1] or {}).textoff or 4
  local tab = string.rep(" ", vim.bo[r.buf].tabstop)
  local l = h.old[i]
  local gutter = (selected and "▶" or (done and "✓" or "-")) .. string.rep(" ", math.max(textoff - 1, 0))
  local source_row = h.a_start > 0 and (h.a_start - 1 + i - 1) or 0
  local parts = syntax_chunks(r.syntax_buf, source_row, l, base, function(first, last)
    if selected then return "cursor" end
    local sp = h.spans and h.spans[i]
    return sp and first < #l - sp[2] and last > sp[1]
  end)
  local chunks, used = { { gutter, base } }, vim.fn.strdisplaywidth(gutter)
  for _, part in ipairs(parts) do
    part[1] = part[1]:gsub("\t", tab)
    chunks[#chunks + 1] = part
    used = used + vim.fn.strdisplaywidth(part[1])
  end
  chunks[#chunks + 1] = { string.rep(" ", math.max(0, winw - used)), base }
  return chunks
end

local function hunk_virt_lines(r, h)
  h.vl_cache = h.vl_cache or {}
  local vl = {}
  for i = 1, #h.old do
    if r.vpos and r.vpos.h == h and r.vpos.i == i then
      vl[i] = virt_chunks(r, h, i, true)
    else
      h.vl_cache[i] = h.vl_cache[i] or virt_chunks(r, h, i, false)
      vl[i] = h.vl_cache[i]
    end
  end
  return vl
end

local function place_virt(r, h)
  h.vl_id = api.nvim_buf_set_extmark(r.buf, ns, attach_row(r, h), 0, {
    id = h.vl_id, virt_lines = hunk_virt_lines(r, h), virt_lines_above = true, virt_lines_leftcol = true, priority = 4200,
  })
end

local function set_vpos(r, h, i)
  local old = r.vpos
  r.vpos = h and { h = h, i = i } or nil
  if old and old.h ~= h and old.h.vl_id and api.nvim_buf_is_valid(r.buf) then place_virt(r, old.h) end
  if h and h.vl_id and api.nvim_buf_is_valid(r.buf) then place_virt(r, h) end
end

local function render(r)
  local buf = r.buf
  local lines = preview(r)
  local current = api.nvim_buf_get_lines(buf, 0, -1, false)
  if not vim.deep_equal(current, lines) then
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, h in ipairs(r.hunks) do
    h.vl_id, h.vl_cache = nil, {} -- namespace was cleared; widths/state may have changed
    local done = h.state == "accepted"
    local del_hl, add_hl = done and "RynoDeleteDone" or "RynoDelete", done and "RynoAddDone" or "RynoAdd"
    local del_txt, add_txt = done and "RynoDeleteDone" or "RynoDeleteText", done and "RynoAddDone" or "RynoAddText"
    if h.state ~= "rejected" then
      -- Proposed lines are actual buffer lines: readable, searchable, and reachable with j/k/C-d.
      local spans = {}
      for i = 1, math.min(h.a_count, h.b_count) do
        local p, sfx = changed_span(h.old[i], h.new[i])
        if p then spans[i] = { p, sfx } end
      end
      h.spans = spans
      for i = 0, h.display_count - 1 do
        local row = h.display_start - 1 + i
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
          line_hl_group = add_hl,
          sign_text = done and "✓" or "+",
          sign_hl_group = add_hl,
          priority = 4200,
        })
        local sp = spans[i + 1]
        if sp then
          api.nvim_buf_set_extmark(buf, ns, row, sp[1], {
            end_col = #h.new[i + 1] - sp[2], hl_group = add_txt, priority = 4300,
          })
        end
      end
      -- Removed text is virtual above the proposed block (cursorable proposed lines remain in the buffer).
      if #h.old > 0 then
        place_virt(r, h)
      end
    end
  end

  if api.nvim_win_is_valid(r.win) then
    if vim.wo[r.win].winbar ~= WINBAR_EXPR then
      vim.wo[r.win].winbar = WINBAR_EXPR
    end
    if not pcall(api.nvim__redraw, { win = r.win, winbar = true }) then
      vim.cmd.redrawstatus()
    end
  end
end

-- ───────────────────────── navigation / lookup ─────────────────────────

local function cursor_row(r)
  return api.nvim_win_get_cursor(api.nvim_win_is_valid(r.win) and r.win or 0)[1]
end

local function hunk_at_cursor(r)
  local row, n = cursor_row(r), api.nvim_buf_line_count(r.buf)
  for _, h in ipairs(r.hunks) do
    local lo, hi
    if h.display_count > 0 then
      lo, hi = h.display_start, h.display_start + h.display_count - 1
    else
      lo = math.max(1, math.min(h.display_start, math.max(n, 1)))
      hi = lo
    end
    if row >= lo and row <= hi then return h end
  end
end

local function goto_hunk(r, h)
  local lo = h.display_count > 0 and h.display_start or math.max(1, math.min(h.display_start, api.nvim_buf_line_count(r.buf)))
  if api.nvim_win_is_valid(r.win) then
    api.nvim_win_set_cursor(r.win, { lo, 0 })
    api.nvim_win_call(r.win, function()
      vim.cmd("normal! zz")
    end)
  end
  -- land on the first removed line when the hunk has one (it is displayed above the proposed lines)
  if h.state ~= "rejected" and #h.old > 0 then
    set_vpos(r, h, 1)
  else
    set_vpos(r, nil)
  end
end

--- j/k that also walk through the (virtual) removed lines of a hunk, in top-to-bottom display order:
--- removed lines first, then the proposed lines.
local function vstep(r, dir)
  local vp = r.vpos
  local left_up = false
  if vp then
    local ni = vp.i + dir
    if ni >= 1 and ni <= #vp.h.old then
      set_vpos(r, vp.h, ni)
      return
    end
    set_vpos(r, nil)
    if dir > 0 then
      return -- past the last removed line: the real cursor line is next
    end
    left_up = true
  end
  local row = cursor_row(r)
  local function virt_hunk_at(target)
    for _, h in ipairs(r.hunks) do
      if h.state ~= "rejected" and #h.old > 0 and attach_row(r, h) + 1 == target then
        return h
      end
    end
  end
  if dir > 0 then
    local h = virt_hunk_at(row + 1)
    pcall(vim.cmd, "normal! j")
    if h and cursor_row(r) == row + 1 then
      set_vpos(r, h, 1)
    end
  else
    local h = not left_up and virt_hunk_at(row)
    if h then
      set_vpos(r, h, #h.old)
    else
      pcall(vim.cmd, "normal! k")
    end
  end
end

local function vmove(r, dir)
  for _ = 1, vim.v.count1 do
    vstep(r, dir)
  end
end

local function step(r, dir)
  local n, row = api.nvim_buf_line_count(r.buf), cursor_row(r)
  local function start(h)
    return h.display_count > 0 and h.display_start or math.max(1, math.min(h.display_start, n))
  end
  local pend = vim.tbl_filter(function(h)
    return h.state == "pending"
  end, r.hunks)
  if #pend == 0 then
    return
  end
  local target
  if dir > 0 then
    for _, h in ipairs(pend) do
      if start(h) > row then
        target = h
        break
      end
    end
    target = target or pend[1]
  else
    for i = #pend, 1, -1 do
      if start(pend[i]) < row then
        target = pend[i]
        break
      end
    end
    target = target or pend[#pend]
  end
  goto_hunk(r, target)
end

-- ───────────────────────── lifecycle ─────────────────────────

local function cleanup(r)
  if r.syntax_buf and api.nvim_buf_is_valid(r.syntax_buf) then
    pcall(api.nvim_buf_delete, r.syntax_buf, { force = true })
  end
  if r.buf and api.nvim_buf_is_valid(r.buf) then
    api.nvim_buf_clear_namespace(r.buf, ns, 0, -1)
    pcall(api.nvim_del_augroup_by_name, "RynoReview")
    for _, lhs in ipairs(r.maps or {}) do
      pcall(vim.keymap.del, "n", lhs, { buffer = r.buf })
    end
    if not r.scratch then
      vim.bo[r.buf].modifiable = r.was_modifiable
    end
  end
  if r.win and api.nvim_win_is_valid(r.win) then
    if r.opened then
      -- we created this window/tab: close it (scratch is bufhidden=wipe) and go back where we were
      local was_current = api.nvim_get_current_win() == r.win
      pcall(api.nvim_win_close, r.win, true)
      if was_current and r.origin_win and api.nvim_win_is_valid(r.origin_win) then
        pcall(api.nvim_set_current_win, r.origin_win)
      end
    else
      vim.wo[r.win].winbar = r.was_winbar
      if r.scratch and r.prev_buf and api.nvim_buf_is_valid(r.prev_buf) then
        api.nvim_win_set_buf(r.win, r.prev_buf) -- scratch is bufhidden=wipe
      end
    end
  end
end

local start_next

local function conclude(r, action, extra)
  if r.concluded then
    return
  end
  r.concluded = true
  M.active = nil
  cleanup(r)

  local acc = diff.counts(r.hunks)
  local msg = { type = "decision", id = r.id, action = action, accepted = acc, total = #r.hunks }
  if action == "partial" then
    msg.content = diff.apply(r.old, r.hunks, r.old_nl)
    msg.rejected = {}
    for _, h in ipairs(r.hunks) do
      if h.state ~= "accepted" then
        msg.rejected[#msg.rejected + 1] = {
          line = math.max(1, h.a_start),
          old = table.concat(h.old, "\n"),
          new = table.concat(h.new, "\n"),
        }
      end
    end
  end
  if extra and extra.reason and extra.reason ~= "" then
    msg.reason = extra.reason
  end
  if action ~= "reject" then
    local first
    for _, h in ipairs(r.hunks) do
      if h.state == "accepted" then
        first = first or math.max(1, h.a_start)
      end
    end
    -- a window we opened is gone by now (-1 = invalid, so on_applied leaves windows alone)
    M.done[r.id] = { win = r.opened and -1 or r.win or api.nvim_get_current_win(), line = first or 1, scratch = r.scratch, path = r.msg.path }
  end
  ;(r.msg._send or M.send)(msg)
  vim.schedule(start_next)
end

local function maybe_conclude(r, extra)
  local acc, _, pend = diff.counts(r.hunks)
  if pend > 0 then
    render(r)
    return false
  end
  local action = (acc == #r.hunks) and "accept" or (acc == 0 and "reject" or "partial")
  conclude(r, action, extra)
  return true
end

local function decide_here(r, state)
  local h = hunk_at_cursor(r)
  if not h or h.state ~= "pending" then
    vim.notify("ryno: no pending hunk under cursor", vim.log.levels.INFO)
    return
  end
  r.vpos = nil
  h.state = state
  if not maybe_conclude(r) then
    step(r, 1)
  end
end

local function decide_all(r, state)
  r.vpos = nil
  for _, h in ipairs(r.hunks) do
    if h.state == "pending" then
      h.state = state
    end
  end
  local acc = diff.counts(r.hunks)
  if state == "rejected" and acc == 0 and M.config.ask_reason then
    r.concluded = nil
    vim.ui.input({ prompt = "ryno: reason for rejecting (optional): " }, function(s)
      maybe_conclude(r, { reason = s })
    end)
    return
  end
  maybe_conclude(r)
end

local function set_keys(r)
  local k = M.config.keys
  r.maps = {}
  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = r.buf, nowait = true, silent = true, desc = "ryno: " .. desc })
      r.maps[#r.maps + 1] = lhs
    end
  end
  map(k.accept, function() decide_here(r, "accepted") end, "accept hunk")
  map(k.reject, function() decide_here(r, "rejected") end, "reject hunk")
  map(k.accept_all, function() decide_all(r, "accepted") end, "accept all")
  map(k.reject_all, function() decide_all(r, "rejected") end, "reject all")
  map(k.next, function() step(r, 1) end, "next hunk")
  map(k.prev, function() step(r, -1) end, "previous hunk")
  -- j/k also walk through the removed (virtual) lines
  map("j", function() vmove(r, 1) end, "down (through removed lines)")
  map("k", function() vmove(r, -1) end, "up (through removed lines)")
  map("<Down>", function() vmove(r, 1) end, "down (through removed lines)")
  map("<Up>", function() vmove(r, -1) end, "up (through removed lines)")
  -- any other cursor movement drops the virtual cursor
  r.aug = api.nvim_create_augroup("RynoReview", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = r.aug,
    buffer = r.buf,
    callback = function()
      local vp = r.vpos
      if vp and cursor_row(r) ~= attach_row(r, vp.h) + 1 then
        set_vpos(r, nil)
      end
    end,
  })
end

local function begin(r)
  hl()
  r.old, r.old_nl = diff.split(r.msg.original or "")
  r.new, r.new_nl = diff.split(r.msg.proposed)
  r.hunks = diff.hunks(r.old, r.new)
  r.syntax_buf = make_scratch(r, r.old, "old")

  if #r.hunks == 0 then -- only the trailing newline differs: nothing to review line-wise
    r.scratch = false
    return conclude(r, "accept")
  end

  r.win, r.opened, r.origin_win = open_window(r.msg.path)
  r.prev_buf = api.nvim_win_get_buf(r.win)
  r.was_winbar = api.nvim_get_option_value("winbar", { win = r.win })
  if M.config.focus then
    api.nvim_set_current_win(r.win)
  end

  -- Review in a scratch buffer containing the proposed version. The user's real buffer (including
  -- unsaved changes) remains untouched; post-apply notification switches this window to the file.
  if not r.msg.isNew then
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and real(api.nvim_buf_get_name(b)) == real(r.msg.path) and vim.bo[b].modified then
        vim.notify("ryno: " .. r.msg.relpath .. " has unsaved changes; review is against on-disk text", vim.log.levels.WARN)
        break
      end
    end
  end
  r.scratch = true
  r.buf = make_scratch(r, preview(r))
  api.nvim_win_set_buf(r.win, r.buf)

  set_keys(r)
  render(r)
  goto_hunk(r, r.hunks[1])
  vim.notify(("ryno: review %s (%d hunk%s)"):format(r.msg.relpath, #r.hunks, #r.hunks == 1 and "" or "s"))
end

start_next = function()
  if M.active then
    return
  end
  local msg = table.remove(M.queue, 1)
  if not msg then
    return
  end
  M.active = { id = msg.id, msg = msg }
  local ok, err = pcall(begin, M.active)
  if not ok then
    vim.notify("ryno: review failed: " .. tostring(err), vim.log.levels.ERROR)
    local r = M.active
    M.active = nil
    if r and r.buf then
      pcall(cleanup, r)
    end
    ;(msg._send or M.send)({ type = "decision", id = msg.id, action = "reject", reason = "editor error: " .. tostring(err) })
    vim.schedule(start_next)
  end
end

-- ───────────────────────── public API ─────────────────────────

function M.setup(config, send)
  M.config, M.send = config, send
  hl()
  api.nvim_create_autocmd("ColorScheme", { callback = hl })
end

function M.enqueue(msg)
  M.queue[#M.queue + 1] = msg
  start_next()
end

--- Agent no longer needs an answer (other editor answered, abort, disconnect).
function M.drop(id)
  M.done[id] = nil
  if M.active and M.active.id == id then
    local r = M.active
    r.concluded = true
    M.active = nil
    cleanup(r)
    vim.schedule(start_next)
    return
  end
  for i, m in ipairs(M.queue) do
    if m.id == id then
      table.remove(M.queue, i)
      return
    end
  end
end

--- A connection went away: forget its reviews (the agent side rejects them itself).
function M.drop_conn(c)
  M.queue = vim.tbl_filter(function(m)
    return m._conn ~= c
  end, M.queue)
  if M.active and M.active.msg._conn == c then
    M.drop(M.active.id)
  end
end

function M.drop_all()
  M.queue = {}
  if M.active then
    M.drop(M.active.id)
  end
end

--- The agent wrote `path`: refresh buffers and show the result.
function M.on_applied(id, path)
  local info = M.done[id]
  M.done[id] = nil
  local rp = real(path)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and real(api.nvim_buf_get_name(b)) == rp and not vim.bo[b].modified then
      api.nvim_buf_call(b, function()
        vim.cmd("silent! edit")
      end)
    end
  end
  if info and info.scratch and api.nvim_win_is_valid(info.win) then
    -- new file, or reviewed against a scratch copy: show the real file now
    api.nvim_win_call(info.win, function()
      pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    end)
  end
  if info and api.nvim_win_is_valid(info.win) and real(api.nvim_buf_get_name(api.nvim_win_get_buf(info.win))) == rp then
    local n = api.nvim_buf_line_count(api.nvim_win_get_buf(info.win))
    pcall(api.nvim_win_set_cursor, info.win, { math.min(info.line, n), 0 })
  end
end

local function with_active(fn)
  return function(...)
    if not M.active or not M.active.hunks then
      vim.notify("ryno: no review in progress", vim.log.levels.INFO)
      return
    end
    return fn(M.active, ...)
  end
end

M.accept_hunk = with_active(function(r) decide_here(r, "accepted") end)
M.reject_hunk = with_active(function(r) decide_here(r, "rejected") end)
M.accept_all = with_active(function(r) decide_all(r, "accepted") end)
M.reject_all = with_active(function(r) decide_all(r, "rejected") end)
M.next_hunk = with_active(function(r) step(r, 1) end)
M.prev_hunk = with_active(function(r) step(r, -1) end)

function M.pending_count()
  return (M.active and 1 or 0) + #M.queue
end

return M
