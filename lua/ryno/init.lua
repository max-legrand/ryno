local client = require("ryno.client")
local review = require("ryno.review")

local M = {}

local defaults = {
  auto_connect = true, -- poll for an agent whose cwd matches ours and connect
  poll_ms = 3000,
  match_cwd = true, -- only auto-connect to agents running in (a parent/child of) our cwd
  auto_accept = false, -- accept everything without review (toggle with :RynoAuto)
  focus = true, -- jump to the reviewed window
  open = "current", -- where the review opens: "current" window, "split", "vsplit", or a new "tab"
  ask_reason = false, -- prompt for a reason when rejecting everything
  -- Don't auto-connect nvims that were opened as a throwaway $EDITOR (`jj desc`, `git commit`, rebase
  -- todo...), so they never steal a review. Decided once from the files nvim was started with.
  -- Manual :RynoConnect / :RynoLink still work. Also off when $RYNO_DISABLE is set.
  exclude_filetypes = { "jjdescription", "gitcommit", "gitrebase" },
  exclude_patterns = { "%.jjdescription$", "COMMIT_EDITMSG$", "MERGE_MSG$", "TAG_EDITMSG$", "git%-rebase%-todo$" }, -- Lua patterns on the full path
  exclude = nil, -- optional function() -> boolean for custom rules (true = don't auto-connect)
  hl = {}, -- override highlight groups, e.g. { RynoAdd = { bg = "#223322" }, RynoAddText = { bg = "#335533" } }
  keys = {
    accept = "<leader>aa",
    reject = "<leader>ar",
    accept_all = "<leader>aA",
    reject_all = "<leader>aR",
    next = "]c",
    prev = "[c",
  },
}

M.config = vim.deepcopy(defaults)
local conns = {} ---@type table<integer, RynoConn>  pid -> connection (one per matching agent)
local links = {} ---@type table<integer, boolean>  pids this nvim was manually linked to (exclusive when non-empty)
local timer
local ready = false

local function notify(msg, level)
  vim.notify("ryno: " .. msg, level or vim.log.levels.INFO)
end

local function label(d)
  return ("%s (pid %s) in %s"):format(d.agent or "agent", tostring(d.pid or "?"), vim.fn.fnamemodify(d.cwd or "?", ":~"))
end

local function on_msg(c, msg)
  if msg.type == "hello" then
    c.desc = vim.tbl_extend("force", c.desc, msg)
    notify("connected to " .. label(c.desc))
  elseif msg.type == "review" then
    if M.config.auto_accept then
      c.send({ type = "decision", id = msg.id, action = "accept" })
    else
      msg._send, msg._conn = c.send, c -- decisions go back to the agent that asked
      review.enqueue(msg)
    end
  elseif msg.type == "resolved" then
    review.drop(msg.id)
  elseif msg.type == "applied" then
    review.on_applied(msg.id, msg.path)
  end
end

--- Tell the agent(s) which files we have open and whether the user is active here, so that with
--- several nvim instances each review goes to the right one (see pickEditors in extension/ryno.ts).
local function state_msg(active)
  local files, seen = {}, {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        name = (vim.uv or vim.loop).fs_realpath(name) or name
        if not seen[name] and #files < 500 then
          seen[name] = true
          files[#files + 1] = name
        end
      end
    end
  end
  return { type = "editor", cwd = vim.fn.getcwd(), files = files, active = active or nil, linked = next(links) ~= nil }
end

local function send_state(active)
  if next(conns) == nil then
    return
  end
  local msg = state_msg(active)
  for _, c in pairs(conns) do
    c.send(msg)
  end
end

---@param desc table
function M.connect_to(desc)
  if conns[desc.pid] then
    return
  end
  local c
  c = client.connect(desc, function(m)
    if conns[desc.pid] == c then
      on_msg(c, m)
    end
  end, function(err)
    if conns[desc.pid] ~= c then
      return
    end
    conns[desc.pid] = nil
    review.drop_conn(c)
    notify(("disconnected from %s%s"):format(label(c.desc), err and (": " .. tostring(err)) or ""), err and vim.log.levels.WARN or nil)
  end, function()
    if conns[desc.pid] == c then
      c.send(state_msg(false))
    end
  end)
  conns[desc.pid] = c
end

--- Connect to every agent whose cwd matches ours (or, with `pick`, choose one from all agents).
---@return boolean found
function M.connect(pick)
  local cwd = (M.config.match_cwd and not pick) and vim.fn.getcwd() or nil
  local found = client.discover(cwd)
  if next(links) then
    -- manually linked: only talk to the linked sessions; forget links to sessions that are gone
    local live = {}
    for _, d in ipairs(client.discover(nil)) do
      live[d.pid] = true
    end
    for pid in pairs(links) do
      if not live[pid] then
        links[pid] = nil
      end
    end
    if next(links) and not pick then
      found = vim.tbl_filter(function(d)
        return links[d.pid]
      end, client.discover(nil))
    end
  end
  -- An agent that restarted its extension (/new, /resume, /reload) keeps its pid but gets a fresh
  -- socket; our connection then points at an orphan. Drop it so it is re-established below.
  for _, d in ipairs(found) do
    local c = conns[d.pid]
    if c and c.desc.startedAt and d.startedAt and c.desc.startedAt ~= d.startedAt then
      conns[d.pid] = nil
      review.drop_conn(c)
      c.close()
    end
  end
  local list = vim.tbl_filter(function(d)
    return not conns[d.pid]
  end, found)
  if #list == 0 then
    return next(conns) ~= nil
  end
  if pick then
    vim.ui.select(list, { prompt = "ryno: agent", format_item = label }, function(d)
      if d then
        M.connect_to(d)
      end
    end)
  else
    for _, d in ipairs(list) do
      M.connect_to(d)
    end
  end
  return true
end

--- Pin this nvim to a pi/prime-agent session, whatever its cwd: reviews from that session go here
--- first, and this nvim stops auto-connecting to other sessions. Undo with unlink().
---@param pid integer|nil  skip the picker
function M.link(pid)
  local function apply(d)
    links[d.pid] = true
    -- exclusive: drop connections to everything else
    for p, c in pairs(conns) do
      if not links[p] then
        conns[p] = nil
        review.drop_conn(c)
        c.close()
      end
    end
    local c = conns[d.pid]
    if c and c.desc.startedAt and d.startedAt and c.desc.startedAt ~= d.startedAt then
      conns[d.pid] = nil
      review.drop_conn(c)
      c.close()
    end
    send_state(false) -- tell already-connected sessions we're linked (a fresh connection sends its own)
    M.connect_to(d)
    notify("linked to " .. label(d))
  end
  local list = client.discover(nil)
  if pid then
    for _, d in ipairs(list) do
      if d.pid == pid then
        return apply(d)
      end
    end
    return notify("no agent with pid " .. tostring(pid), vim.log.levels.WARN)
  end
  if #list == 0 then
    return notify("no agents found in " .. client.runtime_dir(), vim.log.levels.WARN)
  end
  vim.ui.select(list, {
    prompt = "ryno: link this nvim to",
    format_item = function(d)
      return label(d) .. (links[d.pid] and "  [linked]" or "") .. (d.sessionId and d.sessionId ~= "" and ("  " .. d.sessionId:sub(1, 8)) or "")
    end,
  }, function(d)
    if d then
      apply(d)
    end
  end)
end

--- Remove manual links and go back to cwd-based auto-connect.
function M.unlink()
  if next(links) == nil then
    return notify("not linked")
  end
  links = {}
  send_state(false)
  notify("unlinked; auto-connecting by cwd again")
  M.connect(false)
end

function M.disconnect()
  for _, c in pairs(conns) do
    c.close()
  end
end

function M.connected()
  return next(conns) ~= nil
end

function M.toggle_auto()
  M.config.auto_accept = not M.config.auto_accept
  notify("auto-accept " .. (M.config.auto_accept and "ON" or "off"), M.config.auto_accept and vim.log.levels.WARN or nil)
end

--- For statuslines.
function M.status()
  local n = vim.tbl_count(conns)
  if n == 0 then
    return ""
  end
  local p = review.pending_count()
  return "ryno" .. (next(links) and "⚭" or "") .. (M.config.auto_accept and "!" or "") .. (n > 1 and ("×" .. n) or "") .. (p > 0 and (" " .. p) or "")
end

function M.info()
  local lines = {}
  for _, c in pairs(conns) do
    lines[#lines + 1] = "  connected: " .. label(c.desc) .. (links[c.desc.pid] and " [linked]" or "")
  end
  if #lines == 0 then
    local list = client.discover(nil)
    lines[1] = "not connected"
    if #list == 0 then
      lines[2] = "  no agents found in " .. client.runtime_dir() .. " (is the extension loaded?)"
    else
      for _, d in ipairs(list) do
        lines[#lines + 1] = "  available (cwd doesn't match? try :RynoConnect!): " .. label(d)
      end
    end
  end
  lines[#lines + 1] = ("  %d review(s) pending%s"):format(review.pending_count(), M.config.auto_accept and "; AUTO-ACCEPT" or "")
  notify(table.concat(lines, "\n"))
end

local excluded_cache
--- True if this nvim looks like a throwaway $EDITOR session (see `exclude_*` options). Cached.
function M.excluded()
  if excluded_cache ~= nil then
    return excluded_cache
  end
  local function compute()
    if (vim.env.RYNO_DISABLE or "") ~= "" then
      return true
    end
    local cfg = M.config
    for _, arg in ipairs(vim.fn.argv()) do
      local p = vim.fn.fnamemodify(arg, ":p")
      for _, pat in ipairs(cfg.exclude_patterns or {}) do
        if p:find(pat) then
          return true
        end
      end
    end
    local fts = {}
    for _, ft in ipairs(cfg.exclude_filetypes or {}) do
      fts[ft] = true
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and fts[vim.bo[b].filetype] then
        return true
      end
    end
    if cfg.exclude then
      local ok, res = pcall(cfg.exclude)
      return ok and res and true or false
    end
    return false
  end
  excluded_cache = compute()
  return excluded_cache
end

local function poll()
  -- explicit links always win over the exclusion
  if ready and (next(links) or not M.excluded()) then
    M.connect(false) -- picks up agents that started later; already-connected ones are skipped
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  review.setup(M.config, function() end)
  ready = true
  if M.config.auto_connect and not timer then
    timer = (vim.uv or vim.loop).new_timer()
    timer:start(500, M.config.poll_ms, vim.schedule_wrap(poll))
    vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() M.disconnect() end })
  end
  if not M._state_aug then
    M._state_aug = vim.api.nvim_create_augroup("RynoState", { clear = true })
    -- Throttled: at most one state message per 300ms, sent after the last event.
    local t, dirty_active = (vim.uv or vim.loop).new_timer(), false
    local function ping(active)
      dirty_active = dirty_active or active
      if t:is_active() then
        return
      end
      t:start(300, 0, vim.schedule_wrap(function()
        local a = dirty_active
        dirty_active = false
        send_state(a)
      end))
    end
    vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "WinEnter", "CursorMoved", "InsertEnter" }, {
      group = M._state_aug,
      callback = function() ping(true) end,
    })
    vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout", "BufReadPost", "DirChanged" }, {
      group = M._state_aug,
      callback = function() ping(false) end,
    })
  end
end

-- allow use without calling setup()
review.setup(M.config, function() end)

M.review = review
return M
