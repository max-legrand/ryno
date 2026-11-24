-- Diff review of a proposed change.
--
-- The user's file buffer is never modified while reviewing (except with `review_in_file`, where it is
-- restored afterwards). Two layouts, switchable during a review (`keys.layout`):
--   "unified": one buffer with the removed lines as real (red) lines above the proposed (green) lines.
--   "split":   the original and the proposed text side by side in Neovim's native diff mode.
-- Each hunk is accepted/rejected individually; when none are pending the result is sent back to the agent.
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

local LAYOUTS = { unified = true, split = true }

-- mix `fg` into `bg` (24-bit ints) by fraction `a`
local function blend(fg, bg, a)
  local function ch(shift)
    local f, b = bit.band(bit.rshift(fg, shift), 255), bit.band(bit.rshift(bg, shift), 255)
    return math.floor(b + (f - b) * a + 0.5)
  end
  return bit.lshift(ch(16), 16) + bit.lshift(ch(8), 8) + ch(0)
end

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
  -- Returns line bg, changed-text bg (word emphasis).
  local function pair(group, fallback_group, fallback_rgb)
    local g = get(group)
    -- Background-only highlights preserve the filetype's foreground syntax colors.
    if g.bg then
      -- The theme's own line colour; emphasise changed words by pushing it further toward the hue
      -- (the git-sign colour, e.g. Added, is a cleaner hue than DiffAdd's fg, which is often a contrast colour).
      local hue = get(fallback_group).fg or g.fg or fallback_rgb
      return g.bg, blend(hue, g.bg, 0.30)
    end
    local c = g.fg or get(fallback_group).fg or fallback_rgb
    return blend(c, base, 0.16), blend(c, base, 0.40)
  end
  local add_bg, add_text_bg = pair("DiffAdd", "Added", 0x40c060)
  local del_bg, del_text_bg = pair("DiffDelete", "Removed", 0xe05050)
  local change = get("DiffChange")
  local change_bg = change.bg or blend(change.fg or 0xd0a030, base, 0.16)
  set("RynoAdd", { bg = add_bg })
  set("RynoDelete", { bg = del_bg })
  set("RynoAddText", { bg = add_text_bg })
  set("RynoDeleteText", { bg = del_text_bg })
  set("RynoAddDone", { bg = change_bg })
  -- indentation-only lines: just a sign and the changed indentation, no full-line tint
  set("RynoIndent", { bg = blend(get("Added").fg or get("DiffAdd").fg or 0x40c060, base, 0.10) })
  set("RynoIndentSign", { fg = get("Comment").fg })
  -- signs for removed/added lines
  set("RynoAddSign", { fg = get("Added").fg or get("DiffAdd").fg or 0x40c060 })
  set("RynoDeleteSign", { fg = get("Removed").fg or get("DiffDelete").fg or 0xe05050 })
  -- rejected hunks: the original text stays (✗ signs), the rejected proposal is shown struck through
  set("RynoRejected", { fg = get("Comment").fg, strikethrough = true })
  set("RynoRejectedSign", { fg = get("DiagnosticError").fg or get("ErrorMsg").fg, bold = true })
  set("RynoRejectedComment", { fg = get("DiagnosticWarn").fg or get("WarningMsg").fg, italic = true })
  -- line comments: a tinted band below the commented line(s)
  local note_fg = get("DiagnosticHint").fg or get("Special").fg or 0x60a0d0
  set("RynoNote", { fg = note_fg, bg = blend(note_fg, base, 0.10), italic = true })
  set("RynoNoteSign", { fg = note_fg, bg = blend(note_fg, base, 0.10), bold = true })

  -- Winbar: same background as WinBar so nothing looks like a boxed button.
  local bg = get("WinBar").bg
  set("RynoWinbar", { fg = get("WinBar").fg, bg = bg })
  set("RynoWinbarTitle", { fg = get("Title").fg or get("WinBar").fg, bg = bg, bold = true })
  set("RynoWinbarKey", { fg = get("Special").fg, bg = bg, bold = true })
  set("RynoWinbarDim", { fg = get("Comment").fg, bg = bg })
  set("RynoWinbarOk", { fg = get("DiagnosticOk").fg or get("String").fg, bg = bg })
  set("RynoWinbarNo", { fg = get("DiagnosticError").fg or get("ErrorMsg").fg, bg = bg })
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
  if api.nvim_win_get_config(api.nvim_get_current_win()).relative == "" then
    return api.nvim_get_current_win()
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  vim.cmd("botright new")
  return api.nvim_get_current_win()
end

local OPEN_CMDS = { split = "belowright split", vsplit = "belowright vsplit", tab = "tab split" }

--- In Rex, give keyboard focus to this nvim's pane when a review opens (`config.focus_pane`), but
--- only if the pane is in its session's active tab: never switch tabs. Asynchronous, errors ignored.
local function focus_rex_pane()
  local session, block = vim.env.REX_SESSION, vim.env.REX_BLOCK
  if not M.config.focus_pane or (session or "") == "" or (block or "") == "" or vim.fn.executable("rex") == 0 then
    return
  end
  vim.system({ "rex", "session", "inspect", session, "--json" }, { text = true }, vim.schedule_wrap(function(r)
    local ok, view = pcall(vim.json.decode, r.stdout or "")
    if r.code ~= 0 or not ok or type(view) ~= "table" then
      return
    end
    for _, w in ipairs(view.windows or {}) do
      if w.window_id == view.active_window_id then
        if w.focused_block_id == block then
          return -- already focused
        end
        for _, layer in ipairs(w.layers or {}) do
          for _, b in ipairs(layer.blocks or {}) do
            if b.block_id == block then
              local args = vim.json.encode({ session_id = session, block_id = block })
              vim.system({ "rex", "api", "call", "session.focus_block", args }, { text = true })
              return
            end
          end
        end
        return -- our pane is in another tab: leave it
      end
    end
  end))
end

-- Research comments use the same pane-focus policy as approval diffs.
M.focus_pane = focus_rex_pane

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
  if suffix == "old" then vim.bo[b].buftype = "nofile" end
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if ft then
    vim.bo[b].filetype = ft
    -- FileType hooks that call vim.treesitter.start() without a buffer start it on the *current* buffer
    -- instead, so start it here explicitly (no-op when a hook already did, or when there is no parser).
    if not vim.treesitter.highlighter.active[b] then
      pcall(vim.treesitter.start, b, vim.treesitter.language.get_lang(ft) or ft)
    end
  end
  vim.bo[b].modified = false
  vim.bo[b].modifiable = false
  return b
end

-- ───────────────────────── winbar ─────────────────────────

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
  -- The window being drawn: while a winbar is evaluated, it is temporarily the current window
  -- (g:actual_curwin is the user's current window, which may be another one).
  local drawing = vim.g.statusline_winid or api.nvim_get_current_win()
  if not r or not r.hunks then
    return ""
  end
  if r.left and drawing == r.left.win then
    return fmt({ { " original ", "RynoWinbarTitle" }, { r.msg.relpath, "RynoWinbarDim" } })
  end
  if drawing ~= r.win then
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
    if pend == 0 then
      parts[#parts + 1] = { "ready to send", "RynoWinbarOk" } -- confirm_send: waiting for the send key
    else
      parts[#parts + 1] = { pend .. " pending", "RynoWinbarDim" }
    end
    return parts
  end
  local function hint(key, what)
    if not key or key == "" then return {} end
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
  local other = r.layout == "split" and "unified" or "split"
  local rights = pend == 0 and {
    join(hint(k.send, "send"), hint(k.undo, "undo"), hint(k.comment, "comment line"), hint(k.comment_hunk, "comment hunk"), hint(k.next .. "/" .. k.prev, "jump"), hint(k.layout, other)),
    join(hint(k.send, "send"), hint(k.undo, "undo"), hint(k.comment, "comment"), hint(k.next .. "/" .. k.prev, "jump")),
    join(hint(k.send, "send"), hint(k.undo, "undo")),
    hint(k.send, "send"),
    {},
  } or {
    join(
      hint(k.accept, yes), hint(k.reject, no),
      hint(k.accept_all, yes_all), hint(k.reject_all, no_all),
      hint(k.undo, "undo"), hint(k.comment, "comment line"), hint(k.comment_hunk, "comment hunk"),
      hint(k.next .. "/" .. k.prev, "jump"), hint(k.layout, other)
    ),
    join(
      hint(k.accept, yes), hint(k.reject, no),
      hint(k.accept_all, yes_all), hint(k.reject_all, no_all),
      hint(k.undo, "undo"), hint(k.comment, "comment"),
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

-- A global, not `v:lua.require('ryno.review').winbar()`: that converts the whole module (including the
-- review state, whose tables are keyed by hunk) to a Vimscript value on every redraw.
_G.RynoReviewWinbar = function() return M.winbar() end
local WINBAR_EXPR = "%{%v:lua.RynoReviewWinbar()%}"

-- ───────────────────────── views: which buffer row shows what ─────────────────────────
--
-- A view is a window + buffer + row map. `rows[row]` (1-based) is one of:
--   { i = k }                     unchanged line k of the original
--   { h = hunk, side = s, i = k } line k of h.old ("old") or h.new ("new")
-- `first[h]` / `count[h]` are the rows a hunk occupies; a hunk with no rows in a view (e.g. a pure
-- insertion in the original pane) gets the row it sits at, with count 0.
-- The main view (r.main) is the unified buffer, or the proposed pane in the split layout; the split
-- layout adds r.left, the original text.

--- Lines that only changed indentation are folded (fold_reindent): their old copy is not shown.
local function shown_old(h)
  if h.old_shown then return h.old_shown end
  if M.config.fold_reindent ~= false and not h.old_moved then
    h.old_moved, h.new_moved = diff.reindented(h.old, h.new)
  end
  local out = {}
  for i = 1, #h.old do
    if not (h.old_moved and h.old_moved[i]) then out[#out + 1] = i end
  end
  h.old_shown = out
  return out
end

local function new_view(win, buf)
  return { win = win, buf = buf, rows = {}, lines = {}, first = {}, count = {}, index = {} }
end

local function add_row(v, line, e)
  v.lines[#v.lines + 1] = line
  v.rows[#v.lines] = e
  if e.h then
    v.index[e.h] = v.index[e.h] or { old = {}, new = {} }
    v.index[e.h][e.side][e.i] = #v.lines
  end
end

--- Lay out the original lines around the hunks; `body(h)` adds each hunk's rows.
local function build(v, r, body)
  local pos = 1
  for _, h in ipairs(r.hunks) do
    local first = h.a_count > 0 and h.a_start or (h.a_start + 1)
    for i = pos, first - 1 do add_row(v, r.old[i], { i = i }) end
    v.first[h] = #v.lines + 1
    body(h)
    v.count[h] = #v.lines + 1 - v.first[h]
    pos = first + h.a_count
  end
  for i = pos, #r.old do add_row(v, r.old[i], { i = i }) end
end

local function match_lines(h)
  if not h.new_spans then
    h.old_spans, h.new_spans, h.matches = diff.inline_hunk(h.old, h.new)
  end
end

local function unified_view(r, v)
  build(v, r, function(h)
    if h.state == "rejected" then
      -- the rejected proposal (struck through), then the original lines it keeps
      for k, l in ipairs(h.new) do add_row(v, l, { h = h, side = "new", i = k }) end
      for k, l in ipairs(h.old) do add_row(v, l, { h = h, side = "old", i = k }) end
    elseif h.state == "accepted" then
      for k, l in ipairs(h.new) do add_row(v, l, { h = h, side = "new", i = k }) end
    else
      match_lines(h)
      local olds, i, j = shown_old(h), 1, 1
      local function old_until(stop)
        while i <= #olds and olds[i] < stop do
          local k = olds[i]
          add_row(v, h.old[k], { h = h, side = "old", i = k })
          i = i + 1
        end
      end
      local function new_until(stop)
        while j < stop do
          add_row(v, h.new[j], { h = h, side = "new", i = j })
          j = j + 1
        end
      end
      -- Show insertions before the line they precede, then the old/new replacement together.
      for k = 1, #h.old do
        local paired = h.matches[k]
        if paired then
          old_until(k)
          new_until(paired)
          old_until(k + 1)
          new_until(paired + 1)
        end
      end
      old_until(#h.old + 1)
      new_until(#h.new + 1)
    end
  end)
end

--- The split layout's proposed pane: the proposed text, with rejected hunks reverted to the original.
local function proposed_view(r, v)
  build(v, r, function(h)
    local side = h.state == "rejected" and "old" or "new"
    for k, l in ipairs(h[side]) do add_row(v, l, { h = h, side = side, i = k }) end
  end)
end

local function original_view(r, v)
  build(v, r, function(h)
    for k, l in ipairs(h.old) do add_row(v, l, { h = h, side = "old", i = k }) end
  end)
end

local function set_lines(buf, lines)
  if vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), lines) then return end
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = was
end

local function line_count(v)
  return math.max(#v.lines, 1)
end

--- Row a hunk is shown at in view `v` (its first row, or where it sits when it has none there).
local function hunk_row(v, h)
  return math.max(1, math.min(v.first[h], line_count(v)))
end

local function hunk_at_row(r, v, row)
  local e = v.rows[row]
  if e and e.h then return e.h end
  for _, h in ipairs(r.hunks) do
    if v.count[h] == 0 and hunk_row(v, h) == row then return h end
  end
end

local function cursor_row(v)
  return api.nvim_win_get_cursor(api.nvim_win_is_valid(v.win) and v.win or 0)[1]
end

--- The view the cursor is in (the original pane in the split layout, otherwise the main view).
local function current_view(r)
  if r.left and api.nvim_get_current_win() == r.left.win then return r.left end
  return r.main
end

local function hunk_at_cursor(r)
  local v = current_view(r)
  return hunk_at_row(r, v, cursor_row(v))
end

-- ───────────────────────── rendering ─────────────────────────

--- Expand tabs to the next tab stop, given the display column `col` the text starts at.
local function expand_tabs(s, col, ts)
  local out, pos = {}, 1
  while true do
    local t = s:find("\t", pos, true)
    local seg = s:sub(pos, (t or 0) - 1)
    out[#out + 1] = seg
    col = col + vim.fn.strdisplaywidth(seg)
    if not t then break end
    local n = ts - col % ts
    out[#out + 1] = string.rep(" ", n)
    col, pos = col + n, t + 1
  end
  return table.concat(out), col
end

--- Virtual lines that may be long (comments, rejected proposals) wrap rather than being cut off at the
--- window edge where Neovim supports it.
local overflow_mode
local function with_overflow(opts)
  if overflow_mode == nil then
    overflow_mode = false
    local probe = api.nvim_create_buf(false, true)
    for _, mode in ipairs({ "wrap", "scroll" }) do
      if pcall(api.nvim_buf_set_extmark, probe, ns, 0, 0, { virt_lines = { { { "" } } }, virt_lines_overflow = mode }) then
        overflow_mode = mode
        break
      end
    end
    api.nvim_buf_delete(probe, { force = true })
  end
  if overflow_mode then opts.virt_lines_overflow = overflow_mode end
  return opts
end

local function gutter_for(win)
  local textoff = api.nvim_win_is_valid(win) and (vim.fn.getwininfo(win)[1] or {}).textoff or 0
  return function(mark)
    return textoff > 0 and (mark .. string.rep(" ", math.max(textoff - vim.fn.strdisplaywidth(mark), 0))) or ""
  end
end

-- ───────────────────────── line comments ("notes") ─────────────────────────
-- A note comments on lines i..j of one side of a hunk: "new" = proposed lines (h.new), "old" = removed /
-- original lines (h.old). It does not decide the hunk; a hunk with notes can only be rejected, and its
-- notes are sent to the agent with the rejection.

--- File line numbers a note covers: in the original file for "old", in the proposed file for "new".
local function note_rows(h, n)
  local base = n.side == "old" and h.a_start or h.b_start
  return base + n.i - 1, base + n.j - 1
end

local function find_note(h, t)
  for k, n in ipairs(h.notes or {}) do
    if n.side == t.side and n.i == t.i and n.j == t.j then return k, n end
  end
end

local function note_virt(v, n)
  local gutter = gutter_for(v.win)
  local ts = vim.bo[v.buf].tabstop
  local text = vim.split(n.text, "\n", { plain = true })
  if n.j > n.i then text[1] = ("▲ %d lines: %s"):format(n.j - n.i + 1, text[1]) end
  local out = {}
  for k, l in ipairs(text) do
    out[#out + 1] = { { gutter(k == 1 and "»" or ""), "RynoNoteSign" }, { " " .. expand_tabs(l, 0, ts), "RynoNote" }, { "", "RynoNote" } }
  end
  return out
end

--- Each note goes below the last line it covers, in the view showing that side; failing that, below the
--- hunk in the main view.
local function place_notes(r, h)
  for _, n in ipairs(h.notes or {}) do
    local v = (n.side == "old" and r.left) or r.main
    local row = v.index[h] and v.index[h][n.side][n.j]
    if not row then
      v = r.main
      row = v.count[h] > 0 and (v.first[h] + v.count[h] - 1) or hunk_row(v, h)
    end
    api.nvim_buf_set_extmark(v.buf, ns, math.max(0, math.min(row, line_count(v)) - 1), 0,
      with_overflow({ virt_lines = note_virt(v, n), virt_lines_leftcol = true, priority = 4200 }))
  end
end

--- "✗ rejected: comment" header above a rejected hunk; `proposal` adds the rejected lines (struck through)
--- for views that don't show them as buffer lines.
local function place_rejected_header(r, v, h, proposal)
  local gutter = gutter_for(v.win)
  local ts = vim.bo[v.buf].tabstop
  local comment = h.comment and vim.split(h.comment, "\n", { plain = true }) or {}
  local head = { { gutter("✗"), "RynoRejectedSign" }, { r.msg.post and "rolled back" or "rejected", "RynoRejectedSign" } }
  if comment[1] then
    head[#head + 1] = { ": " .. expand_tabs(comment[1], 0, ts), "RynoRejectedComment" }
  end
  local vl = { head }
  for i = 2, #comment do
    vl[#vl + 1] = { { gutter(""), "RynoRejectedComment" }, { "  " .. expand_tabs(comment[i], 0, ts), "RynoRejectedComment" } }
  end
  if proposal then
    for _, l in ipairs(h.new) do
      vl[#vl + 1] = { { gutter("~"), "RynoRejectedSign" }, { (expand_tabs(l, 0, ts)), "RynoRejected" } }
    end
  end
  local n = line_count(v)
  local above = v.first[h] <= n
  h.rej_n, h.rej_above = #vl, above
  api.nvim_buf_set_extmark(v.buf, ns, above and v.first[h] - 1 or n - 1, 0, with_overflow({
    virt_lines = vl, virt_lines_above = above, virt_lines_leftcol = true, priority = 4200,
  }))
end

local function line_hl(buf, row0, group, priority)
  api.nvim_buf_set_extmark(buf, ns, row0, 0, {
    end_row = row0 + 1, end_col = 0, hl_group = group, hl_eol = true, strict = false, priority = priority or 4200,
  })
end

local function sign(buf, row0, text, group)
  api.nvim_buf_set_extmark(buf, ns, row0, 0, { sign_text = text, sign_hl_group = group, priority = 4200 })
end

local function spans_hl(buf, row0, spans, group)
  for _, sp in ipairs(spans or {}) do
    api.nvim_buf_set_extmark(buf, ns, row0, sp[1], { end_col = sp[2], hl_group = group, strict = false, priority = 4300 })
  end
end

--- One row of the unified view: removed lines red, proposed lines green, word changes emphasised.
local function decorate_unified(v, row, e)
  local h, buf, row0 = e.h, v.buf, row - 1
  if h.state == "accepted" then
    line_hl(buf, row0, "RynoAddDone")
    sign(buf, row0, "✓", "RynoAddDone")
  elseif h.state == "rejected" then
    if e.side == "new" then
      line_hl(buf, row0, "RynoRejected")
      sign(buf, row0, "~", "RynoRejectedSign")
    else
      sign(buf, row0, "✗", "RynoRejectedSign")
    end
  elseif e.side == "old" then
    line_hl(buf, row0, "RynoDelete")
    sign(buf, row0, "-", "RynoDeleteSign")
    spans_hl(buf, row0, h.old_spans[e.i], "RynoDeleteText")
  else
    local from = h.new_moved and h.new_moved[e.i]
    if from then
      -- Only the indentation changed: tint just the indentation that was added.
      local a, b = #h.old[from]:match("^%s*"), #h.new[e.i]:match("^%s*")
      sign(buf, row0, b > a and "→" or "←", "RynoIndentSign")
      if b > a then
        api.nvim_buf_set_extmark(buf, ns, row0, a, { end_col = b, hl_group = "RynoIndent", strict = false, priority = 4200 })
      end
      return
    end
    line_hl(buf, row0, "RynoAdd")
    sign(buf, row0, "+", "RynoAddSign")
    spans_hl(buf, row0, h.new_spans[e.i], "RynoAddText")
  end
end

--- Signs only in the split layout: native diff mode draws the changes.
local function decorate_split(v, row, e)
  local h = e.h
  local text, group
  if h.state == "rejected" then
    text, group = "✗", "RynoRejectedSign"
  elseif h.state == "accepted" then
    text, group = "✓", "RynoAddDone"
  else
    text, group = e.side == "old" and "-" or "+", e.side == "old" and "RynoDeleteSign" or "RynoAddSign"
  end
  sign(v.buf, row - 1, text, group)
end

local function diagnostics(r)
  -- The unified buffer mixes old and new lines: language-server diagnostics on it would be noise.
  if r.diag_was == nil then return end
  pcall(vim.diagnostic.enable, r.layout == "split" and r.diag_was, { bufnr = r.buf })
end

local function render(r)
  r.main = new_view(r.win, r.buf)
  if r.layout == "split" then proposed_view(r, r.main) else unified_view(r, r.main) end
  set_lines(r.buf, r.main.lines)
  api.nvim_buf_clear_namespace(r.buf, ns, 0, -1)
  if r.left then
    local lw = r.left.win
    r.left = new_view(lw, r.left.buf)
    original_view(r, r.left)
    api.nvim_buf_clear_namespace(r.left.buf, ns, 0, -1)
  end

  if r.layout == "split" then
    for _, v in ipairs({ r.main, r.left }) do
      for row, e in pairs(v.rows) do
        if e.h then decorate_split(v, row, e) end
      end
    end
    for _, h in ipairs(r.hunks) do
      if h.state == "rejected" then place_rejected_header(r, r.main, h, true) end
    end
    for _, w in ipairs({ r.win, r.left and r.left.win }) do
      if w and api.nvim_win_is_valid(w) then api.nvim_win_call(w, function() vim.cmd("silent! diffupdate") end) end
    end
  else
    for row, e in pairs(r.main.rows) do
      if e.h then decorate_unified(r.main, row, e) end
    end
    for _, h in ipairs(r.hunks) do
      if h.state == "rejected" and (h.comment or r.main.count[h] == 0) then
        place_rejected_header(r, r.main, h, false)
      elseif h.state == "accepted" and r.main.count[h] == 0 then
        sign(r.buf, hunk_row(r.main, h) - 1, "✓", "RynoAddDone")
      end
    end
  end
  for _, h in ipairs(r.hunks) do place_notes(r, h) end
  diagnostics(r)

  if api.nvim_win_is_valid(r.win) then
    for _, w in ipairs({ r.win, r.left and r.left.win }) do
      if w and api.nvim_win_is_valid(w) and vim.wo[w].winbar ~= WINBAR_EXPR then
        vim.wo[w].winbar = WINBAR_EXPR
      end
    end
    if not pcall(api.nvim__redraw, { win = r.win, winbar = true }) then
      vim.cmd.redrawstatus()
    end
  end
end

-- ───────────────────────── layouts ─────────────────────────

local function close_split(r)
  if not r.left then return end
  local left = r.left
  r.left = nil
  if api.nvim_win_is_valid(left.win) then
    pcall(api.nvim_win_close, left.win, true)
  end
  if api.nvim_win_is_valid(r.win) then
    api.nvim_win_call(r.win, function() vim.cmd("silent! diffoff") end)
    vim.wo[r.win].foldenable = r.was_foldenable
  end
end

local function open_split(r)
  local was_current = api.nvim_get_current_win()
  local buf = make_scratch(r, r.old, "old")
  local win = api.nvim_open_win(buf, false, { split = "left", win = r.win })
  r.left = new_view(win, buf)
  r.was_foldenable = vim.wo[r.win].foldenable
  for _, w in ipairs({ win, r.win }) do
    api.nvim_win_call(w, function() vim.cmd("diffthis") end)
  end
  r.set_keys(buf)
  if api.nvim_win_is_valid(was_current) then api.nvim_set_current_win(was_current) end
end

local function goto_row(v, row)
  if not api.nvim_win_is_valid(v.win) then return end
  api.nvim_win_set_cursor(v.win, { math.max(1, math.min(row, api.nvim_buf_line_count(v.buf))), 0 })
  api.nvim_win_call(v.win, function()
    vim.cmd("normal! zz")
  end)
end

local function goto_hunk(r, h)
  local v = current_view(r)
  goto_row(v, hunk_row(v, h))
  -- a rejected hunk's header above line 1 is only drawn as window filler: scroll it into view
  if h.state == "rejected" and h.rej_above and hunk_row(v, h) <= 1 and api.nvim_win_is_valid(v.win) then
    api.nvim_win_call(v.win, function()
      vim.fn.winrestview({ topline = 1, topfill = h.rej_n or 0 })
    end)
  end
end

--- Switch between the unified and the split layout, keeping the cursor on the same line.
local function toggle_layout(r)
  local v = current_view(r)
  local e = v.rows[cursor_row(v)] or {}
  local h = hunk_at_cursor(r)
  close_split(r)
  r.layout = r.layout == "split" and "unified" or "split"
  if r.layout == "split" then open_split(r) end
  api.nvim_set_current_win(r.win)
  render(r)
  local m = r.main
  local row = e.h and m.index[e.h] and m.index[e.h][e.side][e.i]
  if not row and not e.h and e.i then
    for k, x in pairs(m.rows) do
      if not x.h and x.i == e.i then row = k break end
    end
  end
  if row then goto_row(m, row) elseif h then goto_hunk(r, h) end
end

-- ───────────────────────── navigation ─────────────────────────

--- Echo a decided hunk's state (and comment) when navigation lands on it; clear the echo otherwise.
--- Kept to one screen line (v:echospace) so it never triggers a hit-enter prompt.
local function announce(r, h)
  local chunks = {}
  if h.state == "accepted" then
    chunks = { { r.msg.post and "✓ kept" or "✓ accepted", "DiagnosticOk" } }
  elseif h.state == "rejected" then
    chunks = { { r.msg.post and "✗ rolled back" or "✗ rejected", "DiagnosticError" } }
    if h.comment then
      local text = h.comment:gsub("%s*\n%s*", " ↵ ")
      chunks[#chunks + 1] = { ": ", "Comment" }
      chunks[#chunks + 1] = { text, "Normal" }
    end
  end
  local nn = #(h.notes or {})
  if nn > 0 then
    chunks[#chunks + 1] = { ("%s%d line comment%s%s"):format(#chunks > 0 and "  " or "", nn, nn == 1 and "" or "s",
      h.state == "pending" and " (reject to send)" or ""), "DiagnosticHint" }
  end
  local room, out = vim.v.echospace - 1, {}
  for _, c in ipairs(chunks) do
    if room < 2 then break end
    local text = c[1]
    if vim.fn.strdisplaywidth(text) > room then
      local n = vim.fn.strchars(text)
      repeat
        n = n - 1
        text = vim.fn.strcharpart(c[1], 0, n) .. "…"
      until n <= 0 or vim.fn.strdisplaywidth(text) <= room
    end
    out[#out + 1] = { text, c[2] }
    room = room - vim.fn.strdisplaywidth(text)
  end
  api.nvim_echo(out, false, {})
end

--- Jump to the next/previous hunk. `pending_only` skips decided (accepted/rejected/commented) hunks:
--- used for the auto-advance after a decision, while ]c/[c visit every hunk.
local function step(r, dir, pending_only)
  local v = current_view(r)
  local row = cursor_row(v)
  local pend = vim.tbl_filter(function(h)
    return not pending_only or h.state == "pending"
  end, r.hunks)
  if #pend == 0 then
    return
  end
  local target
  if dir > 0 then
    for _, h in ipairs(pend) do
      if hunk_row(v, h) > row then
        target = h
        break
      end
    end
    target = target or pend[1]
  else
    for i = #pend, 1, -1 do
      if hunk_row(v, pend[i]) < row then
        target = pend[i]
        break
      end
    end
    target = target or pend[#pend]
  end
  goto_hunk(r, target)
  announce(r, target)
end

-- ───────────────────────── lifecycle ─────────────────────────

local function cleanup(r)
  pcall(close_split, r)
  pcall(api.nvim_del_augroup_by_name, "RynoReview")
  if r.buf and api.nvim_buf_is_valid(r.buf) then
    api.nvim_buf_clear_namespace(r.buf, ns, 0, -1)
    for _, m in ipairs(r.maps or {}) do
      pcall(vim.keymap.del, m[1], m[2], { buffer = m[3] })
    end
    if r.in_file then
      vim.bo[r.buf].modifiable = true
      api.nvim_buf_set_lines(r.buf, 0, -1, false, r.file_lines)
      vim.bo[r.buf].modified = r.file_modified
      vim.bo[r.buf].modifiable = r.was_modifiable
      if r.diag_was ~= nil then pcall(vim.diagnostic.enable, r.diag_was, { bufnr = r.buf }) end
    elseif not r.scratch then
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
  end
  if action ~= "accept" then
    msg.rejected = {}
    for _, h in ipairs(r.hunks) do
      if h.state == "rejected" then
        local notes
        for _, n in ipairs(h.notes or {}) do
          local a, b = note_rows(h, n)
          notes = notes or {}
          notes[#notes + 1] = {
            side = n.side, line = a, endLine = b,
            code = table.concat(n.side == "old" and h.old or h.new, "\n", n.i, n.j),
            comment = n.text,
          }
        end
        msg.rejected[#msg.rejected + 1] = {
          line = math.max(1, h.a_start),
          old = table.concat(h.old, "\n"),
          new = table.concat(h.new, "\n"),
          comment = h.comment,
          notes = notes,
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

local function send_decision(r, extra)
  local acc = diff.counts(r.hunks)
  local action = (acc == #r.hunks) and "accept" or (acc == 0 and "reject" or "partial")
  conclude(r, action, extra)
end

--- Send the decision once no hunks are pending. `manual` = the last hunk was decided one at a time
--- (not accept/reject all): with `config.confirm_send` the review then waits for the send key instead,
--- so decisions and comments can still be revisited.
local function maybe_conclude(r, extra, manual)
  local _, _, pend = diff.counts(r.hunks)
  if pend > 0 or (manual and M.config.confirm_send) then
    render(r)
    if pend == 0 then
      local k = M.config.keys
      api.nvim_echo({
        { "ryno: all hunks decided, ", "Normal" },
        { show(k.send or ""), "Special" }, { " to send, ", "Normal" },
        { show(k.undo or ""), "Special" }, { " to change a decision", "Normal" },
      }, false, {})
    end
    return false
  end
  send_decision(r, extra)
  return true
end

local function send_here(r)
  local _, _, pend = diff.counts(r.hunks)
  if pend > 0 then
    vim.notify(("ryno: %d hunk%s still pending"):format(pend, pend == 1 and "" or "s"), vim.log.levels.INFO)
    return
  end
  send_decision(r)
end

local function undo_here(r)
  local h = hunk_at_cursor(r)
  if not h or h.state == "pending" then
    vim.notify("ryno: no decided hunk under cursor", vim.log.levels.INFO)
    return
  end
  h.state, h.comment = "pending", nil
  render(r)
  goto_hunk(r, h)
end

--- Floating editor for a comment. `on_submit(text)` runs only if the review is still active.
local function edit_comment(r, title, initial_text, on_submit)
  local back = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(false, true)
  local initial = vim.split(initial_text or "", "\n", { plain = true })
  api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local width = math.min(70, math.max(40, api.nvim_win_get_width(r.win) - 8))
  local height = 8
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal", border = "rounded", title = title,
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"
  vim.cmd("startinsert")

  local closed = false
  local function finish(submit)
    if closed then return end
    closed = true
    local text
    if submit and api.nvim_buf_is_valid(buf) then
      text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    vim.cmd("stopinsert")
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if api.nvim_win_is_valid(back) then api.nvim_set_current_win(back)
    elseif api.nvim_win_is_valid(r.win) then api.nvim_set_current_win(r.win) end
    if submit and text ~= nil and M.active == r and not r.concluded then
      on_submit(text)
    end
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", function() finish(true) end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", function() finish(false) end, { buffer = buf, nowait = true, silent = true })
end

--- What a line comment targets: the hunk plus a hunk-relative line range { side, i, j } covering the
--- rows `rows` (default: the cursor row), clamped to the hunk and side of the first changed row. The
--- range is nil when the hunk has no rows to point at in this view.
local function comment_target(r, rows)
  local v = current_view(r)
  local lo = rows and rows[1] or cursor_row(v)
  local hi = rows and rows[2] or lo
  local anchor
  for row = lo, hi do
    local e = v.rows[row]
    if e and e.h then anchor = e break end
  end
  if not anchor then return hunk_at_row(r, v, lo), nil end
  local i, j
  for row = lo, hi do
    local e = v.rows[row]
    if e and e.h == anchor.h and e.side == anchor.side then
      i, j = math.min(i or e.i, e.i), math.max(j or e.i, e.i)
    end
  end
  return anchor.h, { side = anchor.side, i = i, j = j }
end

--- Comment on the whole hunk: rejects it (the comment is sent with the rejection).
local function comment_hunk(r, h)
  edit_comment(r, " Comment on hunk + reject (Ctrl-S submit, Esc cancel) ", h.comment, function(text)
    h.comment = text ~= "" and text or nil
    h.state = "rejected"
    if not maybe_conclude(r, nil, true) then step(r, 1, true) end
  end)
end

--- Comment on the line under the cursor (or the visual range `rows`). Keeps the hunk's state, so several
--- lines can be commented; rejecting the hunk sends the comments. An empty comment deletes it.
--- `whole` (or no line to point at) comments on the whole hunk instead.
local function comment_here(r, rows, whole)
  local h, t = comment_target(r, rows)
  if not h or h.state == "accepted" then
    vim.notify("ryno: comment requires a pending or rejected hunk under cursor (undo an accepted one first)", vim.log.levels.INFO)
    return
  end
  if whole or not t then
    return comment_hunk(r, h)
  end
  local a, b = note_rows(h, t)
  local where = (a == b and ("line %d"):format(a) or ("lines %d-%d"):format(a, b)) .. (t.side == "old" and " (original)" or " (proposed)")
  local idx, existing = find_note(h, t)
  edit_comment(r, (" Comment on %s (Ctrl-S save, Esc cancel) "):format(where), existing and existing.text, function(text)
    h.notes = h.notes or {}
    if text:match("^%s*$") then
      if idx then table.remove(h.notes, idx) end
    elseif existing then
      existing.text = text
    else
      t.text = text
      h.notes[#h.notes + 1] = t
    end
    render(r)
    if h.state == "pending" and #h.notes > 0 then
      local k = M.config.keys
      api.nvim_echo({
        { ("ryno: %d line comment%s on this hunk; "):format(#h.notes, #h.notes == 1 and "" or "s"), "Normal" },
        { show(k.reject or ""), "Special" }, { " rejects it and sends them", "Normal" },
      }, false, {})
    end
  end)
end

local function has_notes(h)
  return h.notes ~= nil and #h.notes > 0
end

local function decide_here(r, state)
  local h = hunk_at_cursor(r)
  if not h or h.state ~= "pending" then
    vim.notify("ryno: no pending hunk under cursor", vim.log.levels.INFO)
    return
  end
  if state == "accepted" and has_notes(h) then
    vim.notify("ryno: this hunk has line comments: reject it to send them, or clear them (save an empty comment) to accept", vim.log.levels.WARN)
    return
  end
  h.state = state
  if not maybe_conclude(r, nil, true) then
    step(r, 1, true)
  end
end

local function decide_all(r, state)
  local commented = 0
  for _, h in ipairs(r.hunks) do
    if h.state == "pending" then
      -- commented hunks are never accepted wholesale: they are rejected so their comments reach the agent
      if state == "accepted" and has_notes(h) then
        h.state, commented = "rejected", commented + 1
      else
        h.state = state
      end
    end
  end
  if commented > 0 then
    vim.notify(("ryno: %d commented hunk%s rejected with %s comments"):format(commented, commented == 1 and "" or "s", commented == 1 and "its" or "their"), vim.log.levels.INFO)
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
  --- Review keys in `buf` (the main buffer, and the original pane in the split layout).
  function r.set_keys(buf)
    local function map(lhs, fn, desc, mode)
      if lhs and lhs ~= "" then
        mode = mode or "n"
        vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "ryno: " .. desc })
        r.maps[#r.maps + 1] = { mode, lhs, buf }
      end
    end
    map(k.accept, function() decide_here(r, "accepted") end, "accept hunk")
    map(k.reject, function() decide_here(r, "rejected") end, "reject hunk")
    map(k.accept_all, function() decide_all(r, "accepted") end, "accept all")
    map(k.reject_all, function() decide_all(r, "rejected") end, "reject all")
    map(k.next, function() step(r, 1) end, "next hunk")
    map(k.prev, function() step(r, -1) end, "previous hunk")
    map(k.undo, function() undo_here(r) end, "undo hunk decision")
    map(k.comment, function() comment_here(r) end, "comment on line")
    map(k.comment, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      comment_here(r, { math.min(a, b), math.max(a, b) })
    end, "comment on selected lines", "x")
    map(k.comment_hunk, function() comment_here(r, nil, true) end, "comment on hunk + reject")
    map(k.send, function() send_here(r) end, "send decision")
    map(k.layout, function() toggle_layout(r) end, "switch unified/split layout")
  end
  r.set_keys(r.buf)
  -- Closing the original pane by hand ends the split layout.
  r.aug = api.nvim_create_augroup("RynoReview", { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = r.aug,
    callback = function(a)
      if r.left and tonumber(a.match) == r.left.win and not r.concluded then
        vim.schedule(function()
          if M.active ~= r or not r.left or api.nvim_win_is_valid(r.left.win) then return end
          r.left.win = -1
          close_split(r)
          r.layout = "unified"
          render(r)
        end)
      end
    end,
  })
end

local function begin(r)
  hl()
  r.old, r.old_nl = diff.split(r.msg.original or "")
  r.new, r.new_nl = diff.split(r.msg.proposed)
  r.hunks = diff.hunks(r.old, r.new, { merge_gap = M.config.merge_gap })
  r.layout = LAYOUTS[M.config.layout] and M.config.layout or "unified"

  if #r.hunks == 0 then -- only the trailing newline differs: nothing to review line-wise
    r.scratch = false
    return conclude(r, "accept")
  end

  r.win, r.opened, r.origin_win = open_window(r.msg.path)
  focus_rex_pane()
  r.prev_buf = api.nvim_win_get_buf(r.win)
  r.was_winbar = api.nvim_get_option_value("winbar", { win = r.win })
  if M.config.focus then
    api.nvim_set_current_win(r.win)
  end

  -- Review in a scratch buffer. The user's real buffer (including unsaved changes) remains untouched;
  -- post-apply notification switches this window to the file.
  if not r.msg.isNew then
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and real(api.nvim_buf_get_name(b)) == real(r.msg.path) and vim.bo[b].modified then
        vim.notify("ryno: " .. r.msg.relpath .. " has unsaved changes; review is against on-disk text", vim.log.levels.WARN)
        break
      end
    end
  end
  local file_buf
  if M.config.review_in_file and not r.msg.isNew and not r.msg.deleted then
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and real(api.nvim_buf_get_name(b)) == real(r.msg.path) then
        file_buf = b
        break
      end
    end
    if not file_buf then
      local b = vim.fn.bufadd(r.msg.path)
      if b and b > 0 then
        pcall(vim.fn.bufload, b)
        if api.nvim_buf_is_loaded(b) and real(api.nvim_buf_get_name(b)) == real(r.msg.path) then
          file_buf = b
        end
      end
    end
  end
  if file_buf and vim.bo[file_buf].modified then
    vim.notify("ryno: file buffer has unsaved changes; using a separate review buffer", vim.log.levels.WARN)
    file_buf = nil
  elseif file_buf and not same_lines(file_buf, r.old) then
    vim.notify("ryno: file buffer differs from the on-disk original; using a separate review buffer", vim.log.levels.WARN)
    file_buf = nil
  end
  if file_buf then
    r.in_file, r.scratch, r.buf = true, false, file_buf
    r.file_lines = api.nvim_buf_get_lines(file_buf, 0, -1, false)
    r.file_modified = vim.bo[file_buf].modified
    r.was_modifiable = vim.bo[file_buf].modifiable
    vim.bo[file_buf].modifiable = false
    api.nvim_win_set_buf(r.win, file_buf)
  else
    r.scratch = true
    r.buf = make_scratch(r, {})
    api.nvim_win_set_buf(r.win, r.buf)
  end
  local ok, enabled = pcall(vim.diagnostic.is_enabled, { bufnr = r.buf })
  if ok then r.diag_was = enabled end

  set_keys(r)
  if r.layout == "split" then open_split(r) end
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
M.send_review = with_active(send_here)
M.toggle_layout = with_active(toggle_layout)

function M.pending_count()
  return (M.active and 1 or 0) + #M.queue
end

return M
