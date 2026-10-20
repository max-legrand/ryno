local J = dofile("vis/ryno/json.lua")
local fails = 0
local function eq(a, b, m) if not vim.deep_equal(a, b) then fails = fails + 1; print("FAIL", m, vim.inspect(a), vim.inspect(b)) end end
-- round trip vs the reference decoder
local src = { type = "review", id = "x", original = "a\n\t\"q\" \\ é 😀 \1\n", proposed = "", n = 3, ok = true, list = { 1, 2, { a = "b" } } }
eq(vim.json.decode(J.encode(src)), src, "encode -> ref decode")
local ref = vim.json.encode(src)
eq(J.decode(ref), src, "ref encode -> decode")
eq(J.decode('{"a":"\\ud83d\\ude00 \\u00e9","b":[],"c":{},"d":null,"e":-1.5e2}'), { a = "😀 é", b = {}, c = {}, e = -150 }, "unicode / empties")
eq(select(2, pcall(J.decode, '{"a":')) ~= nil, true, "malformed errors")
print(fails == 0 and "json tests OK" or fails .. " FAILED")
os.exit(fails == 0 and 0 or 1)
