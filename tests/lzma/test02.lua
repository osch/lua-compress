-- compress.lzma with carray objects: carray input (read without copying) and carray output
-- (the out argument: the output is appended in place), carray chunks and properties.

local lzma = require("compress.lzma")

local format = string.format

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end
local function assertError(pattern, f, ...)
    local ok, err = pcall(f, ...)
    assert(not ok, "error expected")
    assert(tostring(err):find(pattern, 1, true), format("unexpected error message: %s", tostring(err)))
end

local ok, carray = pcall(require, "carray")
if not ok then
    print("carray module not available: test skipped")
    return
end

local function newRandom(seed)
    local x = seed
    return function(n)
        x = (x * 16807) % 2147483647
        return x % n
    end
end

local function text(n, seed)
    local words = { "alpha", "beta", "gamma", "delta", "\0", "\n", "epsilon", "zeta" }
    local rnd = newRandom(seed or 7)
    local t, len = {}, 0
    while len < n do
        local w = words[rnd(#words) + 1]
        t[#t + 1] = w
        t[#t + 1] = " "
        len = len + #w + 1
    end
    return table.concat(t):sub(1, n)
end

local function newC(s, t)
    return carray.new(t or "char"):append(s)
end

local FORMATS = { "xz", "lzma", "raw" }

PRINT("==================================================================================")
do
    -- carray input gives the same results as string input
    local samples = { "", "a", "\0\0\0", "a\0b\0\0c", text(1000), text(200000) }
    for _, s in ipairs(samples) do
        for _, f in ipairs(FORMATS) do
            local c = lzma.compress(s, { format = f, preset = 3 })
            for _, t in ipairs({ "char", "uchar", "schar", "int8", "uint8" }) do
                assert(lzma.compress(newC(s, t), { format = f, preset = 3 }) == c)
                assert(lzma.decompress(newC(c, t), { format = f }) == s)
            end
        end
    end
    assert(lzma.compress(carray.new("char")) == lzma.compress(""))
    assertError("Error in lzma_code: unexpected end of input", lzma.decompress, carray.new("char"))
    assertError("carray elements must be 1 byte in size", lzma.compress, carray.new("int", 4))
    assertError("carray elements must be 1 byte in size", lzma.decompress, carray.new("short", 4))
    assertError("properties: carray elements must be 1 byte in size", lzma.decompress, "x",
                { format = "raw", properties = carray.new("int", 2) })
end
PRINT("==================================================================================")
do
    -- carray output: the output is appended to the carray, which is returned
    local s = text(100000)
    for _, f in ipairs(FORMATS) do
        local c = lzma.compress(s, { format = f })

        local out = carray.new("char")
        assert(lzma.decompress(c, { format = f }, out) == out)
        assert(out:len() == #s and out:tostring() == s)

        local cout = carray.new("uint8")
        assert(lzma.compress(s, { format = f }, cout) == cout)
        assert(cout:tostring() == c)
        cout:reset()
        assert(lzma.compress(s, { format = f, preset = 1 }, cout) == cout)
        assert(cout:tostring() == lzma.compress(s, { format = f, preset = 1 }))
        assert(lzma.compress(s, { format = f, preset = 0 }, cout) == cout)
        assert(cout:tostring() == lzma.compress(s, { format = f, preset = 1 })
                                  .. lzma.compress(s, { format = f, preset = 0 }))
    end
    local c = lzma.compress(s)

    -- appended after the previous content, larger and smaller results
    local o = newC("prefix:")
    assert(lzma.decompress(lzma.compress("short"), o) == o)
    assert(o:tostring() == "prefix:short")
    lzma.decompress(c, o)
    assert(o:tostring() == "prefix:short" .. s)
    lzma.decompress(lzma.compress(""), o)
    assert(o:tostring() == "prefix:short" .. s)
    o:reset()
    lzma.compress("", { format = "raw" }, o)
    assert(o:tostring() == "\0")
    lzma.compress("", { format = "raw" }, o)
    assert(o:tostring() == "\0\0")
    -- with options and out, and out without options
    o = newC("gz:")
    assert(lzma.compress(s, { format = "xz", preset = 3, check = "crc32" }, o) == o)
    assert(o:tostring() == "gz:" .. lzma.compress(s, { format = "xz", preset = 3, check = "crc32" }))
    assert(lzma.decompress(lzma.compress(s, { format = "raw" }), { format = "raw" }, o) == o)
    assert(o:tostring() == "gz:" .. lzma.compress(s, { format = "xz", preset = 3, check = "crc32" }) .. s)

    -- carray in, carray out
    local cin = newC(c)
    local o2 = carray.new("char")
    assert(lzma.decompress(cin, o2) == o2 and o2:tostring() == s)
    local o3 = carray.new("char")
    assert(lzma.compress(o2, o3) == o3 and o3:tostring() == c)

    -- reuse: decoding many times into the same carray, reset in between (keeps the capacity)
    o = newC(("x"):rep(500000))
    for i = 1, 20 do
        local si = text(1000 * i, i)
        o:reset()
        assert(lzma.decompress(lzma.compress(si, { preset = 1 }), o) == o)
        assert(o:tostring() == si)
    end
    -- many appends into one carray
    o = carray.new("char")
    local expect = {}
    for i = 1, 200 do
        local si = text(i * 37, i)
        lzma.decompress(lzma.compress(si, { preset = 1 }), o)
        expect[#expect + 1] = si
    end
    assert(o:tostring() == table.concat(expect))
end
PRINT("==================================================================================")
do
    -- carray output errors
    local c = lzma.compress(text(50000))
    assertError("out: carray expected, got table", lzma.decompress, c, nil, {})
    assertError("out: carray expected, got number", lzma.compress, "x", {}, 1)
    assertError("out: carray elements must be 1 byte in size", lzma.decompress, c,
                carray.new("int"))
    local cin = newC(c)
    assertError("out: carray must not be the input data", lzma.decompress, cin, cin)
    assertError("out: carray must not be the input data", lzma.compress, cin, {}, cin)
    assert(cin:tostring() == c)
    assertError("bad argument #3", lzma.decompress, c, nil, {})
    assertError("bad argument #2", lzma.decompress, c, carray.new("int"))

    -- on errors the output carray keeps its previous content, nothing is appended
    local o = newC("previous content")
    assertError("output exceeds maxsize", lzma.decompress, c, { maxsize = 1000 }, o)
    assert(o:tostring() == "previous content")
    assertError("Error in lzma_code: unexpected end of input",
                lzma.decompress, c:sub(1, 1000), o)
    assert(o:tostring() == "previous content")
    assertError("Error in lzma_code: File format not recognized", lzma.decompress, ("garbage"):rep(2), o)
    assert(o:tostring() == "previous content")
    assertError("Error in lzma_code: unexpected data after end of stream", lzma.decompress, c .. "x",
                o)
    assert(o:tostring() == "previous content")

    -- maxsize counts the output of the call, not the length of the carray
    local s = text(50000)
    assert(lzma.decompress(c, { maxsize = #s }, o):tostring() == "previous content" .. s)
    assertError("output exceeds maxsize", lzma.decompress, c, { maxsize = #s - 1 }, o)
    assert(o:tostring() == "previous content" .. s)
    o:reset()
    -- the limit applies even if the carray's capacity is larger
    assertError("output exceeds maxsize", lzma.decompress, c, { maxsize = #s - 1 }, o)
    assert(o:len() == 0)
end
PRINT("==================================================================================")
do
    -- carray output of the stream methods: appended, the carray is returned (also when
    -- there is no output), the same bytes as with string results
    local s = text(200000, 3)
    local chunks = {}
    for i = 1, #s, 7000 do chunks[#chunks + 1] = s:sub(i, i + 6999) end
    for _, f in ipairs({ "xz", "raw" }) do          -- the formats with flush
        local e = lzma.compressor({ format = f, preset = 2 })
        local strParts = {}
        for _, ch in ipairs(chunks) do strParts[#strParts + 1] = e:update(ch) end
        strParts[#strParts + 1] = e:flush()
        strParts[#strParts + 1] = e:flush("more", "sync")
        strParts[#strParts + 1] = e:flush(nil, lzma.LZMA_SYNC_FLUSH)
        strParts[#strParts + 1] = e:flush("block", lzma.LZMA_RUN)
        strParts[#strParts + 1] = e:finish("end")
        local cs = table.concat(strParts)

        e = lzma.compressor({ format = f, preset = 2 })
        local o = newC("head")
        for _, ch in ipairs(chunks) do assert(e:update(ch, o) == o) end
        assert(e:flush(nil, o) == o)                     -- flush(chunk, out): mode "sync"
        assert(e:flush("more", "sync", o) == o)
        assert(e:flush(nil, lzma.LZMA_SYNC_FLUSH, o) == o)  -- nothing new: no output
        assert(e:flush("block", lzma.LZMA_RUN, o) == o)
        assert(e:finish("end", o) == o)
        assert(o:tostring() == "head" .. cs)
        assert(lzma.decompress(o:tostring():sub(5), { format = f }) == s .. "moreblockend")

        local d = lzma.decompressor({ format = f })
        o = newC("head")
        for i = 1, #cs, 999 do
            assert(d:update(cs:sub(i, i + 998), o) == o)
        end
        assert(d:finish(nil, o) == o)
        assert(o:tostring() == "head" .. s .. "moreblockend")
    end
    -- flush with out and no mode, and with nil mode
    local e = lzma.compressor()
    local o = newC("x")
    assert(e:update("abc", o) == o)
    assert(e:flush("def", o) == o)
    assert(e:flush("ghi", nil, o) == o)
    assert(e:flush(nil, "finish", o) == o)
    assertError("compressor is closed", e.update, e, "x")
    assert(lzma.decompress(o:tostring():sub(2)) == "abcdefghi")
    -- the update that gives no output still returns the carray, unchanged
    e = lzma.compressor({ format = "raw" })
    o = newC("x")
    assert(e:update("abc", o) == o and o:tostring() == "x")
    assert(e:finish(nil, o) == o and lzma.decompress(o:tostring():sub(2), { format = "raw" }) == "abc")
    -- carray chunks and a carray out (not the same object)
    e = lzma.compressor()
    local co = carray.new("uint8")
    assert(e:update(newC("carray chunk"), co) == co)
    assert(e:finish(newC("!"), co) == co)
    assert(lzma.decompress(co) == "carray chunk!")
    -- nil as out: string results
    e = lzma.compressor({ format = "raw" })
    assert(e:update("abc", nil) == nil)
    assert(type(e:flush("x", "sync", nil)) == "string")
    assert(type(e:finish(nil, nil)) == "string")

    -- decompressor: 1 byte pieces into one carray, reuse after reset
    local t = text(3000, 9)
    local c = lzma.compress(t)
    local d = lzma.decompressor()
    o = carray.new("char")
    for i = 1, #c do
        assert(d:update(c:sub(i, i), o) == o)
    end
    assert(d:finish(nil, o) == o and o:tostring() == t)
    o:reset()
    d = lzma.decompressor()
    assert(d:finish(c, o):tostring() == t)
    d = lzma.decompressor()
    o = newC("a")
    assert(d:update("", o) == o and o:tostring() == "a")

    -- errors of the stream methods: the carray keeps what the successful calls appended
    c = lzma.compress(s)
    d = lzma.decompressor()
    o = newC("head")
    d:update(c:sub(1, #c - 10), o)
    local before = o:tostring()
    assert(#before > 4)
    assertError("unexpected data after end of stream", d.update, d, c:sub(#c - 9) .. "x", o)
    assert(o:tostring() == before)
    d = lzma.decompressor()
    o = newC("head")
    assertError("Error in lzma_code: File format not recognized", d.update, d, ("garbage"):rep(2), o)
    assert(o:tostring() == "head")
    d = lzma.decompressor()
    o = newC("head")
    assertError("unexpected end of input", d.finish, d, c:sub(1, 1000), o)
    assert(o:tostring() == "head")
    d = lzma.decompressor()
    assertError("unexpected data after end of stream", d.update, d, c .. "x", o)
    assert(o:tostring() == "head")
    d = lzma.decompressor()
    d:update(c)
    assertError("unexpected data after end of stream", d.finish, d, "x", o)
    assert(o:tostring() == "head")
    -- maxsize counts the output of the stream
    d = lzma.decompressor({ maxsize = #s })
    o = newC(("p"):rep(100))
    for i = 1, #c, 5000 do
        d:update(c:sub(i, i + 4999), o)
    end
    assert(d:finish(nil, o):tostring() == ("p"):rep(100) .. s)
    d = lzma.decompressor({ maxsize = #s - 1 })
    o = newC("head")
    local ok, err = true, nil
    local appended = 0
    for i = 1, #c, 5000 do
        local n0 = o:len()
        ok, err = pcall(d.update, d, c:sub(i, i + 4999), o)
        if not ok then
            assert(o:len() == n0)
            break
        end
        appended = appended + o:len() - n0
    end
    assert(not ok and err:find("output exceeds maxsize", 1, true) and appended <= #s - 1)

    -- argument errors of out
    e = lzma.compressor()
    assertError("out: carray expected, got string", e.update, e, "x", "y")
    assertError("bad argument #3", e.update, e, "x", {})
    assertError("out: carray elements must be 1 byte in size", e.flush, e, nil, carray.new("int"))
    assertError("out: carray expected, got table", e.flush, e, nil, "sync", {})
    assertError("bad argument #4", e.flush, e, nil, "sync", {})
    assertError("invalid flush mode", e.flush, e, nil, {})
    local same = newC("x")
    assertError("out: carray must not be the input data", e.finish, e, same, same)
    d = lzma.decompressor()
    assertError("out: carray expected, got table", d.update, d, "x", {})
    assertError("out: carray must not be the input data", d.update, d, same, same)
    assertError("out: carray expected, got boolean", d.finish, d, nil, true)
    assertError("out: carray expected, got number", d.decompress, d, "x", 1)
end
PRINT("==================================================================================")
do
    -- the status method decompress() (alias code) with carray output
    local s = text(100000, 4)
    for _, name in ipairs({ "decompress", "code" }) do
        local c = lzma.compress(s)
        local d = lzma.decompressor()
        local o = newC("head")
        local out, st, n = d[name](d, c .. "trailing", o)
        assert(out == o and o:tostring() == "head" .. s and st == lzma.LZMA_STREAM_END and n == #c)
        out, st, n = d[name](d, "x", o)
        assert(out == o and o:tostring() == "head" .. s and st == lzma.LZMA_STREAM_END and n == 0)
        -- in pieces
        d = lzma.decompressor()
        o = carray.new("char")
        for i = 1, #c, 777 do
            out, st, n = d[name](d, c:sub(i, i + 776), o)
            assert(out == o)
        end
        assert(st == lzma.LZMA_STREAM_END and o:tostring() == s)
        -- on an error the output up to the error is appended (as for the string result)
        d = lzma.decompressor({ maxsize = 1000 })
        o = newC("head")
        out, st, n = d[name](d, c, o)
        assert(out == o and st == lzma.LZMA_BUF_ERROR and o:tostring() == "head" .. s:sub(1, 1000))
        out, st, n = d[name](d, c, o)
        assert(out == o and o:len() == 1004 and st == lzma.LZMA_BUF_ERROR and n == 0)
        d = lzma.decompressor()
        o = newC("head")
        -- a corrupt footer: the error comes after all of the data
        out, st = d[name](d, c:sub(1, -2) .. string.char((c:byte(-1) + 1) % 256), o)
        assert(out == o and st == lzma.LZMA_DATA_ERROR and o:tostring() == "head" .. s)
        assert(d:msg() == "Compressed data is corrupt")
    end
end
PRINT("==================================================================================")
do
    -- read-only and non-resizable carrays from the test helper module
    local ok2, tc = pcall(require, "compress_testcarray")
    if not ok2 then
        print("test helper compress_testcarray not available: test part skipped")
    else
        local s = text(30000)
        local c = lzma.compress(s)
        -- read-only carrays can be read
        assert(lzma.decompress(tc.readonly(c)) == s)
        assert(lzma.compress(tc.readonly(s)) == c)
        local raw1 = lzma.compress(s, { format = "raw", filter = "lzma1" })
        local props = lzma.properties({ filter = "lzma1" })
        assert(lzma.decompress(raw1, { format = "raw", filter = "lzma1", properties = tc.readonly(props) }) == s)
        assertError("out: carray is not writable", lzma.decompress, c, tc.readonly("abc"))
        -- carrays referencing foreign memory cannot be resized
        assert(lzma.decompress(tc.ref(c)) == s)
        assertError("cannot resize carray", lzma.decompress, c, tc.ref("abc"))
        assertError("cannot resize carray", lzma.compress, s, tc.ref(""))
        -- the carray is not changed by the failed call
        local r = tc.ref("abc")
        assertError("cannot resize carray", lzma.decompress, c, r)
        assert(r:tostring() == "abc")
        -- the stream methods check out in the same way
        local e = lzma.compressor()
        assertError("out: carray is not writable", e.update, e, "x", tc.readonly(""))
        assertError("cannot resize carray", e.finish, e, s, tc.ref(""))
        local d = lzma.decompressor()
        assertError("out: carray is not writable", d.decompress, d, c, tc.readonly(""))
        assertError("cannot resize carray", d.update, d, c, r)
        assert(r:tostring() == "abc")
    end
end
PRINT("==================================================================================")
do
    -- streaming with carray chunks
    local s = text(300000)
    for _, f in ipairs(FORMATS) do
        local c = lzma.compress(s, { format = f })
        local d = lzma.decompressor({ format = f })
        local parts = {}
        for i = 1, #c, 1000 do
            parts[#parts + 1] = d:update(newC(c:sub(i, i + 999)))
        end
        parts[#parts + 1] = d:finish(carray.new("char"))
        assert(table.concat(parts) == s)

        d = lzma.decompressor({ format = f })
        local out, st, n = d:decompress(newC(c .. "trailing", "uint8"))
        assert(out == s and st == lzma.LZMA_STREAM_END and n == #c)

        local e = lzma.compressor({ format = f, preset = 2 })
        parts = {}
        for i = 1, #s, 10000 do
            parts[#parts + 1] = e:update(newC(s:sub(i, i + 9999), "uchar"))
        end
        parts[#parts + 1] = e:flush(newC("x"), (f == "lzma") and lzma.LZMA_RUN or "sync")
        parts[#parts + 1] = e:finish(newC("y"))
        assert(lzma.decompress(table.concat(parts), { format = f }) == s .. "xy")
    end
    assertError("carray elements must be 1 byte in size", lzma.decompressor().update,
                lzma.decompressor(), carray.new("double", 1))
    assertError("carray elements must be 1 byte in size", lzma.decompressor().code,
                lzma.decompressor(), carray.new("double", 1))
end
PRINT("==================================================================================")
do
    -- properties from carrays, raw LZMA1 as 7z stores it
    local s = text(40000, 17)
    local c = lzma.compress(s, { format = "raw", filter = "lzma1", lc = 1, lp = 1, pb = 1 })
    local props = lzma.properties({ filter = "lzma1", lc = 1, lp = 1, pb = 1 })
    for _, t in ipairs({ "char", "uint8" }) do
        local o = lzma.decompress(newC(c), { format = "raw", filter = "lzma1", properties = newC(props, t) },
                                  carray.new("char"))
        assert(o:tostring() == s)
        local d = lzma.decompressor({ format = "raw", filter = "lzma1", properties = newC(props, t) })
        local out, st, n = d:code(newC(c), carray.new("char"))
        assert(out:tostring() == s and st == lzma.LZMA_STREAM_END and n == #c)
    end
    -- the properties carray may change after the decompressor was created (decoded at once)
    local pc = newC(props)
    local d = lzma.decompressor({ format = "raw", filter = "lzma1", properties = pc })
    pc:set(1, 0)
    assert(d:finish(c) == s)
    assertError("properties: carray elements must be 1 byte in size", lzma.decompressor,
                { format = "raw", properties = carray.new("short", 1) })
end
PRINT("==================================================================================")
do
    -- 10 MB in carrays
    local s = text(10 * 1024 * 1024, 5)
    local src = newC(s)
    local comp = carray.new("char")
    local back = carray.new("char")
    for _, f in ipairs(FORMATS) do
        comp:reset()
        back:reset()
        lzma.compress(src, { format = f, preset = 1 }, comp)
        lzma.decompress(comp, { format = f }, back)
        assert(back:len() == #s and back:equals(src))
        assert(lzma.decompress(comp:tostring(), { format = f }) == s)
        assert(comp:tostring() == lzma.compress(s, { format = f, preset = 1 }))
    end
end
PRINT("==================================================================================")
print("OK.")
