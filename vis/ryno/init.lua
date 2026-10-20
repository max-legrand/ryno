-- ryno for vis: review pi / prime-agent edits before they are applied.
--
-- vis has no virtual text, so changes are shown as a unified diff in a split;
-- accept or reject the whole change (per-hunk review lives in the nvim plugin).
--
-- Install:   ln -s /path/to/ryno/vis/ryno ~/.config/vis/plugins/ryno
-- visrc.lua: require("plugins/ryno")        -- or require("plugins/ryno").setup{...}
--
-- Commands:  :ryno-connect  :ryno-accept  :ryno-reject [reason]  :ryno-status  :ryno-auto
-- Keys:      <M-y> accept   <M-n> reject
--
-- Needs `vis:communicate` (vis >= 0.9 / lspc patch) and `nc` (BSD or OpenBSD) or `socat`.

local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local json = dofile(here .. "json.lua")

local M = {
  config = {
    auto_connect = true,
    match_cwd = true,
    auto_accept = false,
    keys = { accept = "<M-y>", reject = "<M-n>" },
  },
}

local PROC = "ryno"
local fd -- stdin of the bridge process
local buf = ""
local connected = false
local desc
local queue = {}
local active

local function q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
  local p = io.popen(cmd)
  if not p then
    return ""
  end
  local out = p:read("*a")
  p:close()
  return out
end

local function send(msg)
  if fd then
    fd:write(json.encode(msg) .. "\n")
    fd:flush() -- the communicate handle is buffered
  end
end

local function runtime_dir()
  local e = os.getenv("RYNO_DIR")
  if e and e ~= "" then
    return e
  end
  return "/tmp/ryno-" .. sh("id -u"):gsub("%s+", "")
end

local function alive(pid)
  local ok = os.execute("kill -0 " .. tonumber(pid) .. " 2>/dev/null")
  return ok == true or ok == 0
end

local function realpath(p)
  if p:sub(1, 1) ~= "/" then
    p = (os.getenv("PWD") or ".") .. "/" .. p
  end
  local out = sh("realpath " .. q(p) .. " 2>/dev/null"):gsub("%s+$", "")
  return out ~= "" and out or p
end

local function score(a, b)
  a, b = realpath(a):gsub("/+$", ""), realpath(b):gsub("/+$", "")
  if a == b then
    return #a + 1
  end
  if a:sub(1, #b + 1) == b .. "/" then
    return #b
  end
  if b:sub(1, #a + 1) == a .. "/" then
    return #a
  end
end

local function discover()
  local cwd = os.getenv("PWD") or sh("pwd"):gsub("%s+$", "")
  local best
  for f in sh("ls " .. q(runtime_dir()) .. "/*.json 2>/dev/null"):gmatch("[^\n]+") do
    local h = io.open(f, "r")
    if h then
      local ok, d = pcall(json.decode, h:read("*a"))
      h:close()
      if ok and type(d) == "table" and d.socket and d.pid and alive(d.pid) then
        d.score = d.cwd and score(cwd, d.cwd) or nil
        if M.config.match_cwd and not d.score then
          d = nil
        end
        if d and (not best or (d.score or 0) > (best.score or 0)
            or ((d.score or 0) == (best.score or 0) and (d.startedAt or 0) > (best.startedAt or 0))) then
          best = d
        end
      end
    end
  end
  return best
end

-- ───────────────────────── review ─────────────────────────

local tmpdir = "/tmp/ryno-vis-" .. (os.getenv("USER") or "u")

local function write_file(path, text)
  local h = assert(io.open(path, "w"))
  h:write(text or "")
  h:close()
end

local function finish(decision)
  local r = active
  if not r then
    return
  end
  active = nil
  decision.id = r.id
  send(decision)
  pcall(function()
    if r.win then
      r.win:close()
    end
  end)
  os.remove(r.diff)
  if #queue > 0 then
    M.start(table.remove(queue, 1))
  end
end

function M.start(msg)
  if active then
    queue[#queue + 1] = msg
    return
  end
  os.execute("mkdir -p -m 700 " .. q(tmpdir))
  local base = tmpdir .. "/" .. msg.id:gsub("[^%w_%-]", "_")
  local old, new, diff = base .. ".old", base .. ".new", base .. ".diff"
  write_file(old, msg.original)
  write_file(new, msg.proposed)
  local rel = msg.relpath
  local out = sh(("diff -u --label %s --label %s %s %s"):format(
    q(msg.isNew and "/dev/null" or ("a/" .. rel)), q("b/" .. rel), q(old), q(new)))
  os.remove(old)
  os.remove(new)
  local header
  if msg.post then
    header = ("# ryno: a %s command ALREADY changed %s\n# :ryno-accept (%s) keeps it   :ryno-reject (%s) rolls it back\n\n"):format(
      msg.tool or "shell", rel, M.config.keys.accept, M.config.keys.reject)
  else
    header = ("# ryno: agent wants to %s %s\n# :ryno-accept (%s)   :ryno-reject (%s)\n\n"):format(
      msg.tool == "write" and (msg.isNew and "create" or "overwrite") or "edit", rel, M.config.keys.accept, M.config.keys.reject)
  end
  write_file(diff, header .. out)

  active = { id = msg.id, msg = msg, diff = diff }
  vis:command("split " .. diff)
  active.win = vis.win
  pcall(vis.command, vis, "set syntax diff")
  vis:info("ryno: review " .. rel .. " - " .. M.config.keys.accept .. " accept, " .. M.config.keys.reject .. " reject")
end

local function reload(path)
  local target = realpath(path)
  local cur = vis.win
  for win in vis:windows() do
    if win.file and win.file.path and not win.file.modified and realpath(win.file.path) == target then
      pcall(function()
        vis.win = win
        vis:command("e!")
      end)
    end
  end
  pcall(function()
    vis.win = cur
  end)
end

-- ───────────────────────── connection ─────────────────────────

local function on_msg(m)
  if m.type == "hello" then
    desc = m
    vis:info(("ryno: connected to %s (pid %s)"):format(m.agent or "agent", tostring(m.pid)))
  elseif m.type == "review" then
    if M.config.auto_accept then
      send({ type = "decision", id = m.id, action = "accept" })
    else
      M.start(m)
    end
  elseif m.type == "resolved" then
    if active and active.id == m.id then
      pcall(function()
        active.win:close()
      end)
      os.remove(active.diff)
      active = nil
      if #queue > 0 then
        M.start(table.remove(queue, 1))
      end
    else
      for i, x in ipairs(queue) do
        if x.id == m.id then
          table.remove(queue, i)
          break
        end
      end
    end
  elseif m.type == "applied" then
    reload(m.path)
  end
end

vis.events.subscribe(vis.events.PROCESS_RESPONSE, function(name, event, code, msg)
  if name ~= PROC then
    return
  end
  if event == "STDOUT" then
    buf = buf .. msg
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      if line ~= "" then
        local ok, m = pcall(json.decode, line)
        if ok and type(m) == "table" then
          on_msg(m)
        end
      end
    end
  elseif event == "EXIT" or event == "SIGNAL" then
    fd, connected, desc, buf = nil, false, nil, ""
    queue = {}
    if active then
      pcall(function()
        active.win:close()
      end)
      active = nil
    end
    vis:info("ryno: disconnected")
  end
end)

function M.connect()
  if connected then
    return true
  end
  if not vis.communicate then
    vis:info("ryno: this vis has no vis:communicate")
    return false
  end
  local d = discover()
  if not d then
    return false
  end
  -- vis runs this through the user's $SHELL (may be fish): hand everything to sh.
  local script = 'if command -v socat >/dev/null 2>&1; then exec socat - "UNIX-CONNECT:$0"; else exec nc -U "$0"; fi'
  local bridge = "exec sh -c " .. q(script) .. " " .. q(d.socket)
  fd = vis:communicate(PROC, bridge)
  connected = fd ~= nil
  return connected
end

-- ───────────────────────── commands ─────────────────────────

vis:command_register("ryno-connect", function()
  if not M.connect() then
    vis:info("ryno: no agent found for this directory")
    return false
  end
  return true
end, "Connect to a pi/prime-agent instance")

vis:command_register("ryno-accept", function()
  if not active then
    vis:info("ryno: no review in progress")
    return false
  end
  finish({ type = "decision", action = "accept" })
  return true
end, "Accept the change under review")

vis:command_register("ryno-reject", function(argv)
  if not active then
    vis:info("ryno: no review in progress")
    return false
  end
  local reason = table.concat(argv, " ")
  finish({ type = "decision", action = "reject", reason = reason ~= "" and reason or nil })
  return true
end, "Reject the change under review [reason]")

vis:command_register("ryno-auto", function()
  M.config.auto_accept = not M.config.auto_accept
  vis:info("ryno: auto-accept " .. (M.config.auto_accept and "ON" or "off"))
  return true
end, "Toggle auto-accept")

vis:command_register("ryno-status", function()
  if connected and desc then
    vis:info(("ryno: connected to %s pid %s, %d pending%s"):format(
      desc.agent or "agent", tostring(desc.pid), (active and 1 or 0) + #queue, M.config.auto_accept and " (AUTO)" or ""))
  else
    vis:info("ryno: not connected")
  end
  return true
end, "Show ryno status")

local function bind()
  local k = M.config.keys
  if k.accept then
    vis:map(vis.modes.NORMAL, k.accept, function()
      vis:command("ryno-accept")
    end, "ryno: accept change")
  end
  if k.reject then
    vis:map(vis.modes.NORMAL, k.reject, function()
      vis:command("ryno-reject")
    end, "ryno: reject change")
  end
end

function M.setup(opts)
  for k, v in pairs(opts or {}) do
    if type(v) == "table" and type(M.config[k]) == "table" then
      for kk, vv in pairs(v) do
        M.config[k][kk] = vv
      end
    else
      M.config[k] = v
    end
  end
  bind()
end

bind()

if M.config.auto_connect then
  -- vis has no timers: try at startup and whenever a window opens.
  vis.events.subscribe(vis.events.INIT, function()
    M.connect()
  end)
  vis.events.subscribe(vis.events.WIN_OPEN, function()
    if not connected then
      M.connect()
    end
  end)
end

return M
