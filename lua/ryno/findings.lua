-- Research-mode comments. Extmarks only, separate from diagnostics and edit approvals.
local api = vim.api
local M = {}
local owners = {}
local hidden = false
local config = {}

local function highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal.bg or 0x101010
  local r, g, b = math.floor(bg / 65536), math.floor(bg / 256) % 256, bg % 256
  local light = 0.299 * r + 0.587 * g + 0.114 * b > 150
  local purple = light and 0x704090 or 0xc4b5fd
  local tint = light and 0xeee8f5 or 0x252132
  for name, attrs in pairs({
    RynoFindingTitle = { fg = purple, bg = tint, bold = true },
    RynoFindingBody = { fg = light and 0x503b65 or 0xd8cfe8, bg = tint },
    RynoFindingBorder = { fg = purple, bg = tint },
    RynoFindingHidden = { fg = purple, bold = true },
  }) do
    api.nvim_set_hl(0, name, (config.hl or {})[name] or attrs)
  end
end

local group = api.nvim_create_augroup("RynoFindings", { clear = true })
api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })

local function items()
  local result = {}
  for _, state in pairs(owners) do
    for _, item in ipairs(state.items) do
      if api.nvim_buf_is_valid(item.buf) then
        local pos = api.nvim_buf_get_extmark_by_id(item.buf, state.ns, item.id, {})
        if #pos > 0 then
          item.row, item.state = pos[1], state
          result[#result + 1] = item
        end
      end
    end
  end
  table.sort(result, function(a, b)
    local ap, bp = api.nvim_buf_get_name(a.buf), api.nvim_buf_get_name(b.buf)
    if ap ~= bp then return ap < bp end
    if a.row ~= b.row then return a.row < b.row end
    return a.id < b.id
  end)
  return result
end

local function render(item)
  local concealed = hidden or item.dismissed
  item.id = api.nvim_buf_set_extmark(item.buf, item.state.ns, item.row, 0, {
    id = item.id, virt_lines = concealed and {} or item.block, virt_lines_above = true,
    sign_text = concealed and "◆" or "", sign_hl_group = "RynoFindingHidden",
    priority = 5, -- Leave higher-priority diagnostic signs visible when they share a line.
  })
end

local function jump(item)
  if hidden or item.dismissed then M.toggle() end
  api.nvim_set_current_buf(item.buf)
  api.nvim_win_set_cursor(0, { item.row + 1, 0 })
  vim.fn.winrestview({ topline = item.row + 1, topfill = #item.block })
end

local function mappings(buf)
  local keys = vim.tbl_extend("force", {
    next = "]r", prev = "[r", list = "<leader>if", toggle = "<leader>ih",
    dismiss = "<leader>id", clear = "<leader>iD", hide = "<leader>iH",
  }, config.findings_keys or {})
  local actions = {
    next = function() M.next() end, prev = function() M.prev() end,
    list = function() M.list() end, toggle = function() M.toggle() end,
    hide = function() M.hide() end,
    dismiss = function() M.dismiss() end, clear = function() M.dismiss_all() end,
  }
  for name, fn in pairs(actions) do
    if keys[name] and keys[name] ~= "" then
      vim.keymap.set("n", keys[name], fn, { buffer = buf, desc = "Ryno findings: " .. name })
    end
  end
end

local function clean(text)
  return (text or ""):gsub("[%z\1-\8\11-\31\127]", ""):gsub("\t", "  ")
end

local function wrap(text, width)
  local lines = {}
  for _, paragraph in ipairs(vim.split(clean(text), "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > width then
        lines[#lines + 1], line = line, ""
      end
      -- Split long identifiers/URLs too, without slicing UTF-8 bytes.
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= "" then lines[#lines + 1], line = line, "" end
        local n = 1
        while vim.fn.strdisplaywidth(vim.fn.strcharpart(word, 0, n + 1)) <= width do n = n + 1 end
        lines[#lines + 1] = vim.fn.strcharpart(word, 0, n)
        word = vim.fn.strcharpart(word, n)
      end
      line = line == "" and word or line .. " " .. word
    end
    lines[#lines + 1] = line
  end
  return lines
end

function M.clear(owner)
  for key, state in pairs(owners) do
    if owner == nil or key == owner then
      for buf in pairs(state.buffers) do
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, state.ns, 0, -1) end
      end
      owners[key] = nil
    end
  end
end

function M.show(owner, findings, opts)
  config = opts
  highlights()
  M.clear(owner)
  if #findings == 0 then return end
  local state = {
    ns = api.nvim_create_namespace("ryno-findings-" .. tostring(owner)),
    buffers = {}, items = {},
  }
  owners[owner] = state
  local first
  local width = math.max(20, math.min(100, api.nvim_win_get_width(0) - 6))
  for _, finding in ipairs(findings) do
    local buf = vim.fn.bufadd(finding.path)
    vim.fn.bufload(buf)
    local row = math.max(0, math.min(finding.line - 1, api.nvim_buf_line_count(buf) - 1))
    first = first or { buf = buf, row = row }
    state.buffers[buf] = true
    local block = {}
    local function add(prefix, text, hl)
      local padding = string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
      block[#block + 1] = { { prefix, "RynoFindingBorder" }, { text .. padding, hl } }
    end
    for i, line in ipairs(wrap("ryno: " .. finding.title, width)) do
      add(i == 1 and "╭─ " or "│  ", line, "RynoFindingTitle")
    end
    for _, line in ipairs(wrap(finding.body, width)) do add("│  ", line, "RynoFindingBody") end
    add("╰─ ", "", "RynoFindingBorder")
    if first.buf == buf and first.row == row then first.height = #block end
    local item = { buf = buf, row = row, state = state, block = block, message = clean(finding.title .. "\n" .. finding.body) }
    render(item)
    table.insert(state.items, item)
    mappings(buf)
  end
  -- Do not interrupt an edit-approval diff. Comments still appear in the source buffers.
  if first and config.focus and not hidden and not require("ryno.review").active then
    local wins = vim.fn.win_findbuf(first.buf)
    local win = wins[1]
    if not win then
      local commands = { split = "split", vsplit = "vsplit", tab = "tabnew" }
      if commands[config.open] then vim.cmd(commands[config.open]) end
      win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, first.buf)
    end
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { first.row + 1, 0 })
    api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = first.row + 1, topfill = first.height })
    end)
    require("ryno.review").focus_pane()
  end
  vim.notify(("ryno: %d review comment(s)%s, :RynoFindings to list, :RynoToggleFindings to hide/show"):format(#findings, hidden and " (hidden)" or ""))
end

-- A snapshot for integrations, without registering findings as Neovim diagnostics.
function M.get(buf)
  local result = {}
  if buf == 0 then buf = api.nvim_get_current_buf() end
  for _, item in ipairs(items()) do
    if buf == nil or item.buf == buf then
      result[#result + 1] = {
        bufnr = item.buf, lnum = item.row, message = item.message,
        hidden = not not (hidden or item.dismissed),
      }
    end
  end
  return result
end

function M.list()
  local entries = {}
  for _, item in ipairs(items()) do
    entries[#entries + 1] = { bufnr = item.buf, lnum = item.row + 1, col = 1, text = item.message, type = "I" }
  end
  vim.fn.setloclist(0, {}, "r", { title = "Ryno review findings", items = entries })
  vim.cmd("lopen")
end

local function set_hidden(value)
  hidden = value
  for _, item in ipairs(items()) do
    if not hidden then item.dismissed = false end
    render(item)
  end
  if not hidden then
    for _, item in ipairs(items()) do
      if item.buf == api.nvim_get_current_buf() and item.row == api.nvim_win_get_cursor(0)[1] - 1 then
        jump(item)
        break
      end
    end
  end
  vim.notify("ryno: review comments " .. (hidden and "hidden" or "shown"))
end

function M.hide() set_hidden(true) end
function M.show_all() set_hidden(false) end

function M.toggle()
  local dismissed = false
  for _, item in ipairs(items()) do dismissed = dismissed or item.dismissed end
  -- A toggle after dismissing anything restores all comments, rather than hiding the rest.
  set_hidden(not (hidden or dismissed))
end

local function navigate(direction)
  local entries = items()
  if #entries == 0 then return vim.notify("ryno: no review comments") end
  local buf, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1] - 1
  local name = api.nvim_buf_get_name(buf)
  local target
  for _, item in ipairs(entries) do
    local path = api.nvim_buf_get_name(item.buf)
    if direction > 0 and (path > name or (item.buf == buf and item.row > row)) then
      target = item
      break
    elseif direction < 0 and (path < name or (item.buf == buf and item.row < row)) then
      target = item
    end
  end
  jump(target or (direction > 0 and entries[1] or entries[#entries]))
end

function M.next() navigate(1) end
function M.prev() navigate(-1) end

function M.dismiss()
  local buf, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1] - 1
  for _, item in ipairs(items()) do
    if item.buf == buf and item.row == row then
      item.dismissed = true
      render(item)
      vim.notify("ryno: review dismissed; <leader>ih or :RynoToggleFindings restores it")
      return
    end
  end
  vim.notify("ryno: jump to a review comment to dismiss it")
end

function M.dismiss_all()
  for _, item in ipairs(items()) do
    item.dismissed = true
    render(item)
  end
  vim.notify("ryno: reviews dismissed; <leader>ih or :RynoToggleFindings restores them")
end

return M
