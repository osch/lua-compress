-- Benchmark: compress and decompress 1 MB, string results vs. carray targets (the out
-- argument; reset before each call, which keeps the capacity).
-- Usage: lua bench01.lua [reps]

local brotli = require("compress.brotli")

local format = string.format
local clock  = os.clock

local ok, carray = pcall(require, "carray")
if not ok then
    carray = nil
    print("carray module not available: carray variants skipped")
end

local reps = tonumber((...)) or 20

local function newRandom(seed)
    local x = seed
    return function(n)
        x = (x * 16807) % 2147483647
        return x % n
    end
end

-- 1 MB: mostly text with some random bytes
local function data()
    local words = { "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
                    "elit", "sed", "do", "eiusmod", "tempor", "\n" }
    local rnd = newRandom(1)
    local t, len = {}, 0
    while len < 1024 * 1024 do
        local w
        if rnd(20) == 0 then
            w = string.char(rnd(256), rnd(256), rnd(256), rnd(256))
        else
            w = words[rnd(#words) + 1] .. " "
        end
        t[#t + 1] = w
        len = len + #w
    end
    return table.concat(t):sub(1, 1024 * 1024)
end

local function bench(name, n, f)
    f() -- warm up
    local t0 = clock()
    for _ = 1, n do f() end
    local dt = (clock() - t0) / n
    print(format("%-44s %8.2f ms  %8.1f MB/s", name, dt * 1000, 1 / dt))
end

local s = data()
print(format("compress.brotli %s, libbrotli %s, %s, %d bytes", brotli._VERSION, (brotli.version()),
             _VERSION, #s))

for _, q in ipairs({ 1, 5, 9, 11 }) do
    local c = brotli.compress(s, { quality = q })
    local n = (q >= 10) and math.max(1, math.floor(reps / 10)) or reps
    print(format("-- quality %d: %d bytes (%.1f %%)", q, #c, 100 * #c / #s))
    bench(format("compress   string -> string  (q%d)", q), n, function()
        brotli.compress(s, { quality = q })
    end)
    if carray then
        local src = carray.new("char"):append(s)
        local out = carray.new("char")
        bench(format("compress   carray -> carray  (q%d)", q), n, function()
            out:reset()
            brotli.compress(src, { quality = q }, out)
        end)
    end
    bench(format("decompress string -> string  (q%d)", q), reps * 5, function()
        brotli.decompress(c)
    end)
    if carray then
        local cin = carray.new("char"):append(c)
        local out = carray.new("char")
        bench(format("decompress string -> carray  (q%d)", q), reps * 5, function()
            out:reset()
            brotli.decompress(c, out)
        end)
        bench(format("decompress carray -> carray  (q%d)", q), reps * 5, function()
            out:reset()
            brotli.decompress(cin, out)
        end)
        bench(format("decompress string -> new carray (q%d)", q), reps * 5, function()
            brotli.decompress(c, carray.new("char"))
        end)
    end
    local chunk = 65536
    bench(format("decompressor, 64 KB chunks   (q%d)", q), reps * 5, function()
        local d = brotli.decompressor()
        for i = 1, #c, chunk do d:update(c:sub(i, i + chunk - 1)) end
        d:finish()
    end)
end
