-- compress.lzma in several independent Lua states of the same process, also used
-- from parallel OS threads: compress.lzma keeps all its state (stream objects, carray
-- C API cache) per Lua state and has no global mutable data.
-- Needs the test helper module compress_multistate (tests/multistate.c).

local lzma = require("compress.lzma")

local format = string.format

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end

local ok, ms = pcall(require, "compress_multistate")
if not ok then
    print("test helper compress_multistate not available: test skipped")
    return
end
local hasCarray = pcall(require, "carray")

PRINT("==================================================================================")
local A = ms.new()
local B = ms.new()
do
    local init = [[
        lzma = require("compress.lzma")
        hasCarray, carray = pcall(require, "carray")
        function text(n, tag)
            local t = {}
            for i = 1, n do t[i] = tag .. (i % 1000) .. " " end
            return table.concat(t)
        end
        return lzma._VERSION
    ]]
    assert(A:run(init) == lzma._VERSION)
    assert(B:run(init) == lzma._VERSION)
end
PRINT("==================================================================================")
do
    -- interleaved use: streams in A and B stay independent
    A:run([[ s = text(20000, "a"); c = lzma.compress(s, { preset = 1 })
             d = lzma.decompressor(); e = lzma.compressor({ preset = 1 })
             outD, outE = {}, {} ]])
    B:run([[ s = text(20000, "b"); c = lzma.compress(s, { preset = 1 })
             d = lzma.decompressor(); e = lzma.compressor({ preset = 1 })
             outD, outE = {}, {} ]])
    local step = [[
        local i = ...
        outD[#outD + 1] = d:update(c:sub(i, i + 999))
        outE[#outE + 1] = e:update(s:sub(i * 4, i * 4 + 3999))
    ]]
    for i = 1, 200000, 1000 do
        A:run(format("return (function(...) %s end)(%d)", step, i))
        B:run(format("return (function(...) %s end)(%d)", step, i))
    end
    local check = [[
        outD[#outD + 1] = d:finish()
        outE[#outE + 1] = e:finish()
        return table.concat(outD) == s and lzma.decompress(table.concat(outE)) == s:sub(4)
    ]]
    assert(A:run(check) == true)
    assert(B:run(check) == true)

    if hasCarray then
        local code = [[
            local o = carray.new("char")
            lzma.decompress(lzma.compress(carray.new("char"):append(...), { preset = 0 }), o)
            return o:tostring()
        ]]
        assert(A:run("return (function(...) "..code.." end)('carray in A')") == "carray in A")
        assert(B:run("return (function(...) "..code.." end)('carray in B')") == "carray in B")
    end
end
PRINT("==================================================================================")
do
    -- parallel threads: both states compress and decompress at the same time
    local work = [[
        local tag = %q
        local s = text(50000, tag)
        local n = 0
        for round = 1, 10 do
            local c = lzma.compress(s, { preset = 1, dictSize = 65536 })
            assert(lzma.decompress(c) == s)
            local d = lzma.decompressor({ maxsize = #s, format = "auto" })
            local g = lzma.compress(s, { format = "raw", filter = "lzma1", preset = 0 })
            local out, st = lzma.decompressor({ format = "raw", filter = "lzma1" }):code(g)
            assert(out == s and st == lzma.LZMA_STREAM_END)
            local parts = {}
            for i = 1, #c, 777 do parts[#parts + 1] = d:update(c:sub(i, i + 776)) end
            parts[#parts + 1] = d:finish()
            assert(table.concat(parts) == s)
            assert(not pcall(lzma.decompress, c, { maxsize = #s - 1 }))
            if hasCarray then
                local o = carray.new("char")
                lzma.decompress(carray.new("char"):append(c), o)
                assert(o:tostring() == s)
            end
            n = n + #c
        end
        return tag .. ":" .. n
    ]]
    local t0 = os.clock()
    local ra, rb = ms.parallel(A, format(work, "A"), B, format(work, "B"))
    PRINT(format("parallel: %s / %s (%.2f s cpu)", ra, rb, os.clock() - t0))
    assert(ra:match("^A:%d+$") and rb:match("^B:%d+$"))
end
PRINT("==================================================================================")
do
    -- closing A (with open streams) does not affect B
    A:run([[ open1 = lzma.compressor({ preset = 0 }); open1:update("pending")
             open2 = lzma.decompressor(); open2:update(lzma.compress("x"):sub(1, 1)) ]])
    A:close()
    assert(not pcall(A.run, A, "return 1"))
    collectgarbage()
    assert(B:run([[ return lzma.decompress(lzma.compress("still working")) ]]) == "still working")
    B:close()
    -- and the main state still works
    assert(lzma.decompress(lzma.compress("main")) == "main")
end
PRINT("==================================================================================")
print("OK.")
