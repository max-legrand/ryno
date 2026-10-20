-- Discovery + NDJSON-over-unix-socket client for the ryno agent extension.
local uv = vim.uv or vim.loop

local M = {}

function M.runtime_dir()
  local env = vim.env.RYNO_DIR
  if env and env ~= "" then
    return env
  end
  local pw = uv.os_get_passwd()
  return "/tmp/ryno-" .. (pw and pw.uid or "u")
end

local function alive(pid)
  if not pid then
    return false
  end
  local ok, res = pcall(uv.kill, pid, 0)
  return ok and res == 0
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  local ok, d = pcall(vim.json.decode, s)
  return ok and d or nil
end

local function norm(p)
  -- resolve symlinks (macOS: /tmp -> /private/tmp) so both sides compare equal
  p = uv.fs_realpath(p) or p
  return (vim.fs.normalize(p):gsub("/+$", ""))
end

--- Length of the shared directory ancestry if one path contains the other, else nil.
local function cwd_score(a, b)
  a, b = norm(a), norm(b)
  if a == b then
    return #a + 1
  end
  if a:sub(1, #b + 1) == b .. "/" then
    return #b
  end
  if b:sub(1, #a + 1) == a .. "/" then
    return #a
  end
  return nil
end

--- List live agent descriptors, best match for `cwd` first.
---@param cwd string|nil  nil = don't filter
function M.discover(cwd)
  local out = {}
  for _, f in ipairs(vim.fn.glob(M.runtime_dir() .. "/*.json", false, true)) do
    local d = read_json(f)
    if d and d.socket and alive(d.pid) then
      -- nil = this agent's cwd is unrelated to ours (must stay nil: 0 would be truthy)
      d.score = cwd and d.cwd and cwd_score(cwd, d.cwd) or nil
      if not cwd or d.score then
        out[#out + 1] = d
      end
    end
  end
  table.sort(out, function(x, y)
    if (x.score or 0) ~= (y.score or 0) then
      return (x.score or 0) > (y.score or 0)
    end
    return (x.startedAt or 0) > (y.startedAt or 0)
  end)
  return out
end

---@class RynoConn
---@field send fun(msg: table)
---@field close fun()
---@field desc table

--- Connect to a descriptor. Callbacks run on the main loop.
---@param desc table
---@param on_msg fun(msg: table)
---@param on_close fun(err: string|nil)
---@param on_open fun()|nil
---@return RynoConn
function M.connect(desc, on_msg, on_close, on_open)
  local pipe = uv.new_pipe(false)
  local buf, closed = "", false
  local conn = { desc = desc }

  local function close(err)
    if closed then
      return
    end
    closed = true
    if not pipe:is_closing() then
      pipe:close()
    end
    vim.schedule(function()
      on_close(err)
    end)
  end

  function conn.send(msg)
    if not closed then
      pipe:write(vim.json.encode(msg) .. "\n")
    end
  end
  function conn.close()
    close(nil)
  end

  pipe:connect(desc.socket, function(err)
    if err then
      return close(err)
    end
    if on_open then
      vim.schedule(on_open)
    end
    pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then
        return close(rerr)
      end
      buf = buf .. chunk
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        if line ~= "" then
          vim.schedule(function()
            local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
            if ok and type(msg) == "table" then
              on_msg(msg)
            end
          end)
        end
      end
    end)
  end)
  return conn
end

return M
