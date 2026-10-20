-- Minimal JSON codec (pure Lua, 5.1–5.4). Enough for the ryno protocol.
local M = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function esc(s)
  return (s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end))
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

function M.encode(v)
  local t = type(v)
  if t == "string" then
    return '"' .. esc(v) .. '"'
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    local out = {}
    if next(v) ~= nil and is_array(v) then
      for i, x in ipairs(v) do
        out[i] = M.encode(x)
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, x in pairs(v) do
      out[#out + 1] = '"' .. esc(tostring(k)) .. '":' .. M.encode(x)
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

local unesc = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

function M.decode(s)
  local pos = 1

  local function ws()
    pos = s:find("[^ \t\r\n]", pos) or #s + 1
  end
  local function fail(msg)
    error(("json: %s at %d"):format(msg, pos), 0)
  end

  local value

  local function str()
    pos = pos + 1 -- opening quote
    local parts = {}
    while true do
      local i = s:find('["\\]', pos)
      if not i then
        fail("unterminated string")
      end
      parts[#parts + 1] = s:sub(pos, i - 1)
      if s:sub(i, i) == '"' then
        pos = i + 1
        return table.concat(parts)
      end
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or fail("bad \\u escape")
        pos = i + 6
        if cp >= 0xD800 and cp < 0xDC00 and s:sub(pos, pos + 1) == "\\u" then
          local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo < 0xE000 then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        parts[#parts + 1] = utf8_char(cp)
      else
        parts[#parts + 1] = unesc[e] or fail("bad escape")
        pos = i + 2
      end
    end
  end

  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then
          fail("expected key")
        end
        local k = str()
        ws()
        if s:sub(pos, pos) ~= ":" then
          fail("expected ':'")
        end
        pos = pos + 1
        obj[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          fail("expected ',' or '}'")
        end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          fail("expected ',' or ']'")
        end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif s:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif s:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not num or num == "" then
      fail("unexpected character")
    end
    pos = pos + #num
    return tonumber(num)
  end

  local v = value()
  return v
end

return M
