-- compress.brotli in several independent Lua states of the same process, also used
-- from parallel OS threads: compress.brotli keeps all its state (stream objects, carray
-- C API cache) per Lua state and has no global mutable data.
-- Needs the test helper module compress_multistate (tests/multistate.c).

local brotli = require("compress.brotli")

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
        brotli = require("compress.brotli")
        hasCarray, carray = pcall(require, "carray")
        function text(n, tag)
            local t = {}
            for i = 1, n do t[i] = tag .. (i % 1000) .. " " end
            return table.concat(t)
        end
        return brotli._VERSION
    ]]
    assert(A:run(init) == brotli._VERSION)
    assert(B:run(init) == brotli._VERSION)
end
PRINT("==================================================================================")
do
    -- interleaved use: streams in A and B stay independent
    A:run([[ s = text(20000, "a"); c = brotli.compress(s, { quality = 5 })
             d = brotli.decompressor(); e = brotli.compressor({ quality = 5 })
             outD, outE = {}, {} ]])
    B:run([[ s = text(20000, "b"); c = brotli.compress(s, { quality = 5 })
             d = brotli.decompressor(); e = brotli.compressor({ quality = 5 })
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
        return table.concat(outD) == s and brotli.decompress(table.concat(outE)) == s:sub(4)
    ]]
    assert(A:run(check) == true)
    assert(B:run(check) == true)

    if hasCarray then
        local code = [[
            local o = carray.new("char")
            brotli.decompress(brotli.compress(carray.new("char"):append(...)), o)
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
            local c = brotli.compress(s, { quality = 9, lgwin = 20 })
            assert(brotli.decompress(c) == s)
            local d = brotli.decompressor({ maxsize = #s })
            local parts = {}
            for i = 1, #c, 777 do parts[#parts + 1] = d:update(c:sub(i, i + 776)) end
            parts[#parts + 1] = d:finish()
            assert(table.concat(parts) == s)
            assert(not pcall(brotli.decompress, c, { maxsize = #s - 1 }))
            if hasCarray then
                local o = carray.new("char")
                brotli.decompress(carray.new("char"):append(c), o)
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
    A:run([[ open1 = brotli.compressor(); open1:update("pending")
             open2 = brotli.decompressor(); open2:update(brotli.compress("x"):sub(1, 1)) ]])
    A:close()
    assert(not pcall(A.run, A, "return 1"))
    collectgarbage()
    assert(B:run([[ return brotli.decompress(brotli.compress("still working")) ]]) == "still working")
    B:close()
    -- and the main state still works
    assert(brotli.decompress(brotli.compress("main")) == "main")
end
PRINT("==================================================================================")
print("OK.")
