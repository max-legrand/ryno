local client = require("ryno.client")
local review = require("ryno.review")

local M = {}

local defaults = {
  auto_connect = true, -- poll for an agent whose cwd matches ours and connect
  poll_ms = 3000,
  match_cwd = true, -- only auto-connect to agents running in (a parent/child of) our cwd
  auto_accept = false, -- accept everything without review (toggle with :RynoAuto)
  focus = true, -- jump to the reviewed window
  ask_reason = false, -- prompt for a reason when rejecting everything
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
  end)
  conns[desc.pid] = c
end

--- Connect to every agent whose cwd matches ours (or, with `pick`, choose one from all agents).
---@return boolean found
function M.connect(pick)
  local cwd = (M.config.match_cwd and not pick) and vim.fn.getcwd() or nil
  local found = client.discover(cwd)
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
  return "ryno" .. (M.config.auto_accept and "!" or "") .. (n > 1 and ("×" .. n) or "") .. (p > 0 and (" " .. p) or "")
end

function M.info()
  local lines = {}
  for _, c in pairs(conns) do
    lines[#lines + 1] = "  connected: " .. label(c.desc)
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

local function poll()
  if ready then
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
end

-- allow use without calling setup()
review.setup(M.config, function() end)

M.review = review
return M
