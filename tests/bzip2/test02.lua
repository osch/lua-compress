-- compress.bzip2 with carray objects: carray input (read without copying) and carray output
-- (the out argument: the output is appended in place), carray chunks.

local bzip2 = require("compress.bzip2")

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

PRINT("==================================================================================")
do
    -- carray input gives the same results as string input
    local samples = { "", "a", "\0\0\0", "a\0b\0\0c", text(1000), text(200000) }
    for _, s in ipairs(samples) do
        for _, k in ipairs({ 1, 9 }) do
            local c = bzip2.compress(s, { level = k })
            for _, t in ipairs({ "char", "uchar", "schar", "int8", "uint8" }) do
                assert(bzip2.compress(newC(s, t), { level = k }) == c)
                assert(bzip2.decompress(newC(c, t)) == s)
                assert(bzip2.decompress(newC(c, t), { small = true }) == s)
            end
        end
    end
    assert(bzip2.compress(carray.new("char")) == bzip2.compress(""))
    assertError("Error in BZ2_bzDecompress: unexpected end of input", bzip2.decompress, carray.new("char"))
    assertError("carray elements must be 1 byte in size", bzip2.compress, carray.new("int", 4))
    assertError("carray elements must be 1 byte in size", bzip2.decompress, carray.new("short", 4))
end
PRINT("==================================================================================")
do
    -- carray output: the output is appended to the carray, which is returned
    local s = text(100000)
    local c = bzip2.compress(s)

    local out = carray.new("char")
    assert(bzip2.decompress(c, out) == out)
    assert(out:len() == #s and out:tostring() == s)

    local cout = carray.new("uint8")
    assert(bzip2.compress(s, cout) == cout)
    assert(cout:tostring() == c)
    cout:reset()
    assert(bzip2.compress(s, { level = 1 }, cout) == cout)
    assert(cout:tostring() == bzip2.compress(s, { level = 1 }))
    assert(bzip2.compress(s, { level = 2 }, cout) == cout)
    assert(cout:tostring() == bzip2.compress(s, { level = 1 }) .. bzip2.compress(s, { level = 2 }))

    -- appended after the previous content, larger and smaller results
    local o = newC("prefix:")
    assert(bzip2.decompress(bzip2.compress("short"), o) == o)
    assert(o:tostring() == "prefix:short")
    bzip2.decompress(c, o)
    assert(o:tostring() == "prefix:short" .. s)
    bzip2.decompress(bzip2.compress(""), o)
    assert(o:tostring() == "prefix:short" .. s)
    o:reset()
    bzip2.compress("", o)
    assert(o:tostring() == bzip2.compress(""))
    bzip2.compress("", o)
    assert(o:tostring() == bzip2.compress("") .. bzip2.compress(""))
    -- with options and out
    o = newC("bz:")
    assert(bzip2.compress(s, { level = 3, workFactor = 50 }, o) == o)
    assert(o:tostring() == "bz:" .. bzip2.compress(s, { level = 3 }))
    assert(bzip2.decompress(c, { maxsize = #s, small = true }, o) == o)
    assert(o:tostring() == "bz:" .. bzip2.compress(s, { level = 3 }) .. s)

    -- carray in, carray out
    local cin = newC(c)
    local o2 = carray.new("char")
    assert(bzip2.decompress(cin, o2) == o2 and o2:tostring() == s)
    local o3 = carray.new("char")
    assert(bzip2.compress(o2, o3) == o3 and o3:tostring() == c)

    -- reuse: decoding many times into the same carray, reset in between (keeps the capacity)
    o = newC(("x"):rep(500000))
    for i = 1, 20 do
        local si = text(1000 * i, i)
        o:reset()
        assert(bzip2.decompress(bzip2.compress(si, { level = 1 }), o) == o)
        assert(o:tostring() == si)
    end
    -- many appends into one carray
    o = carray.new("char")
    local expect = {}
    for i = 1, 200 do
        local si = text(i * 37, i)
        bzip2.decompress(bzip2.compress(si, { level = 1 }), o)
        expect[#expect + 1] = si
    end
    assert(o:tostring() == table.concat(expect))
end
PRINT("==================================================================================")
do
    -- carray output errors
    local c = bzip2.compress(text(50000))
    assertError("out: carray expected, got table", bzip2.decompress, c, nil, {})
    assertError("out: carray expected, got number", bzip2.compress, "x", {}, 1)
    assertError("out: carray elements must be 1 byte in size", bzip2.decompress, c,
                carray.new("int"))
    local cin = newC(c)
    assertError("out: carray must not be the input data", bzip2.decompress, cin, cin)
    assertError("out: carray must not be the input data", bzip2.compress, cin, {}, cin)
    assert(cin:tostring() == c)
    assertError("bad argument #3", bzip2.decompress, c, nil, {})
    assertError("bad argument #2", bzip2.decompress, c, carray.new("int"))

    -- on errors the output carray keeps its previous content, nothing is appended
    local o = newC("previous content")
    assertError("output exceeds maxsize", bzip2.decompress, c, { maxsize = 1000 }, o)
    assert(o:tostring() == "previous content")
    assertError("Error in BZ2_bzDecompress: unexpected end of input",
                bzip2.decompress, c:sub(1, 1000), o)
    assert(o:tostring() == "previous content")
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", bzip2.decompress, ("garbage"):rep(2), o)
    assert(o:tostring() == "previous content")
    assertError("Error in BZ2_bzDecompress: unexpected data after end of stream", bzip2.decompress,
                c .. "x", o)
    assert(o:tostring() == "previous content")
    local m = math.floor(#c / 2)
    assertError("Error in BZ2_bzDecompress: DATA_ERROR", bzip2.decompress,
                c:sub(1, m) .. string.char((c:byte(m + 1) + 1) % 256) .. c:sub(m + 2), o)
    assert(o:tostring() == "previous content")

    -- maxsize counts the output of the call, not the length of the carray
    local s = text(50000)
    assert(bzip2.decompress(c, { maxsize = #s }, o):tostring() == "previous content" .. s)
    assertError("output exceeds maxsize", bzip2.decompress, c, { maxsize = #s - 1 }, o)
    assert(o:tostring() == "previous content" .. s)
    o:reset()
    -- the limit applies even if the carray's capacity is larger
    assertError("output exceeds maxsize", bzip2.decompress, c, { maxsize = #s - 1 }, o)
    assert(o:len() == 0)
end
PRINT("==================================================================================")
do
    -- carray output of the stream methods: appended, the carray is returned (also when
    -- there is no output), the same bytes as with string results
    local s = text(300000, 3)
    local chunks = {}
    for i = 1, #s, 7000 do chunks[#chunks + 1] = s:sub(i, i + 6999) end
    local e = bzip2.compressor({ level = 1 })
    local strParts = {}
    for _, ch in ipairs(chunks) do strParts[#strParts + 1] = e:update(ch) end
    strParts[#strParts + 1] = e:flush()
    strParts[#strParts + 1] = e:flush("more", "block")
    strParts[#strParts + 1] = e:flush(nil, bzip2.BZ_FLUSH)
    strParts[#strParts + 1] = e:flush("block", bzip2.BZ_RUN)
    strParts[#strParts + 1] = e:finish("end")
    local cs = table.concat(strParts)

    e = bzip2.compressor({ level = 1 })
    local o = newC("head")
    for _, ch in ipairs(chunks) do assert(e:update(ch, o) == o) end
    assert(e:flush(nil, o) == o)                     -- flush(chunk, out): mode "block"
    assert(e:flush("more", "block", o) == o)
    assert(e:flush(nil, bzip2.BZ_FLUSH, o) == o)     -- nothing new: no output
    assert(e:flush("block", bzip2.BZ_RUN, o) == o)
    assert(e:finish("end", o) == o)
    assert(o:tostring() == "head" .. cs)
    assert(bzip2.decompress(o:tostring():sub(5)) == s .. "moreblockend")

    local d = bzip2.decompressor()
    o = newC("head")
    for i = 1, #cs, 999 do
        assert(d:update(cs:sub(i, i + 998), o) == o)
    end
    assert(d:finish(nil, o) == o)
    assert(o:tostring() == "head" .. s .. "moreblockend")

    -- flush with out and no mode, and with nil mode
    e = bzip2.compressor()
    o = newC("x")
    assert(e:update("abc", o) == o)
    assert(e:flush("def", o) == o)
    assert(e:flush("ghi", nil, o) == o)
    assert(e:flush(nil, "finish", o) == o)
    assertError("compressor is closed", e.update, e, "x")
    assert(bzip2.decompress(o:tostring():sub(2)) == "abcdefghi")
    -- the update that gives no output still returns the carray, unchanged
    e = bzip2.compressor()
    o = newC("x")
    assert(e:update("abc", o) == o and o:tostring() == "x")
    assert(e:finish(nil, o) == o and bzip2.decompress(o:tostring():sub(2)) == "abc")
    -- carray chunks and a carray out (not the same object)
    e = bzip2.compressor()
    local co = carray.new("uint8")
    assert(e:update(newC("carray chunk"), co) == co)
    assert(e:finish(newC("!"), co) == co)
    assert(bzip2.decompress(co) == "carray chunk!")
    -- nil as out: string results
    e = bzip2.compressor()
    assert(e:update("abc", nil) == nil)
    assert(type(e:flush("x", "block", nil)) == "string")
    assert(type(e:finish(nil, nil)) == "string")

    -- decompressor: 1 byte pieces into one carray, reuse after reset
    local t = text(3000, 9)
    local c = bzip2.compress(t)
    d = bzip2.decompressor()
    o = carray.new("char")
    for i = 1, #c do
        assert(d:update(c:sub(i, i), o) == o)
    end
    assert(d:finish(nil, o) == o and o:tostring() == t)
    o:reset()
    d = bzip2.decompressor()
    assert(d:finish(c, o):tostring() == t)
    d = bzip2.decompressor()
    o = newC("a")
    assert(d:update("", o) == o and o:tostring() == "a")

    -- errors of the stream methods: the carray keeps what the successful calls appended
    c = bzip2.compress(s, { level = 1 })
    d = bzip2.decompressor()
    o = newC("head")
    d:update(c:sub(1, #c - 10), o)
    local before = o:tostring()
    assert(#before > 4)
    assertError("unexpected data after end of stream", d.update, d, c:sub(#c - 9) .. "x", o)
    assert(o:tostring() == before)
    d = bzip2.decompressor()
    o = newC("head")
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", d.update, d, ("garbage"):rep(2), o)
    assert(o:tostring() == "head")
    d = bzip2.decompressor()
    o = newC("head")
    assertError("unexpected end of input", d.finish, d, c:sub(1, 1000), o)
    assert(o:tostring() == "head")
    d = bzip2.decompressor()
    assertError("unexpected data after end of stream", d.update, d, c .. "x", o)
    assert(o:tostring() == "head")
    d = bzip2.decompressor()
    d:update(c)
    assertError("unexpected data after end of stream", d.finish, d, "x", o)
    assert(o:tostring() == "head")
    -- maxsize counts the output of the stream
    d = bzip2.decompressor({ maxsize = #s })
    o = newC(("p"):rep(100))
    for i = 1, #c, 5000 do
        d:update(c:sub(i, i + 4999), o)
    end
    assert(d:finish(nil, o):tostring() == ("p"):rep(100) .. s)
    d = bzip2.decompressor({ maxsize = #s - 1 })
    o = newC("head")
    local okU, err = true, nil
    local appended = 0
    for i = 1, #c, 5000 do
        local n0 = o:len()
        okU, err = pcall(d.update, d, c:sub(i, i + 4999), o)
        if not okU then
            assert(o:len() == n0)
            break
        end
        appended = appended + o:len() - n0
    end
    assert(not okU and err:find("output exceeds maxsize", 1, true) and appended <= #s - 1)

    -- argument errors of out
    e = bzip2.compressor()
    assertError("out: carray expected, got string", e.update, e, "x", "y")
    assertError("bad argument #3", e.update, e, "x", {})
    assertError("out: carray elements must be 1 byte in size", e.flush, e, nil, carray.new("int"))
    assertError("out: carray expected, got table", e.flush, e, nil, "block", {})
    assertError("bad argument #4", e.flush, e, nil, "block", {})
    assertError("invalid flush mode", e.flush, e, nil, {})
    local same = newC("x")
    assertError("out: carray must not be the input data", e.finish, e, same, same)
    d = bzip2.decompressor()
    assertError("out: carray expected, got table", d.update, d, "x", {})
    assertError("out: carray must not be the input data", d.update, d, same, same)
    assertError("out: carray expected, got boolean", d.finish, d, nil, true)
    assertError("out: carray expected, got number", d.decompress, d, "x", 1)
end
PRINT("==================================================================================")
do
    -- the status method decompress() (alias bzinflate) with carray output
    local s = text(100000, 4)
    for _, name in ipairs({ "decompress", "bzinflate" }) do
        local c = bzip2.compress(s)
        local d = bzip2.decompressor()
        local o = newC("head")
        local out, st, n = d[name](d, c .. "trailing", o)
        assert(out == o and o:tostring() == "head" .. s and st == bzip2.BZ_STREAM_END and n == #c)
        out, st, n = d[name](d, "x", o)
        assert(out == o and o:tostring() == "head" .. s and st == bzip2.BZ_STREAM_END and n == 0)
        -- in pieces
        d = bzip2.decompressor()
        o = carray.new("char")
        for i = 1, #c, 777 do
            out, st, n = d[name](d, c:sub(i, i + 776), o)
            assert(out == o)
        end
        assert(st == bzip2.BZ_STREAM_END and o:tostring() == s)
        -- on an error the output up to the error is appended (as for the string result)
        d = bzip2.decompressor({ maxsize = 1000 })
        o = newC("head")
        out, st, n = d[name](d, c, o)
        assert(out == o and st == bzip2.BZ_OUTBUFF_FULL and o:tostring() == "head" .. s:sub(1, 1000))
        out, st, n = d[name](d, c, o)
        assert(out == o and o:len() == 1004 and st == bzip2.BZ_OUTBUFF_FULL and n == 0)
        d = bzip2.decompressor()
        o = newC("head")
        -- a corrupt combined CRC: the error comes after all of the data
        out, st = d[name](d, c:sub(1, -3) .. string.char((c:byte(-2) + 1) % 256) .. c:sub(-1), o)
        assert(out == o and st == bzip2.BZ_DATA_ERROR and o:tostring() == "head" .. s)
        assert(d:msg() == "DATA_ERROR")
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
        local c = bzip2.compress(s)
        -- read-only carrays can be read
        assert(bzip2.decompress(tc.readonly(c)) == s)
        assert(bzip2.compress(tc.readonly(s)) == c)
        assertError("out: carray is not writable", bzip2.decompress, c, tc.readonly("abc"))
        -- carrays referencing foreign memory cannot be resized
        assert(bzip2.decompress(tc.ref(c)) == s)
        assertError("cannot resize carray", bzip2.decompress, c, tc.ref("abc"))
        assertError("cannot resize carray", bzip2.compress, s, tc.ref(""))
        -- the carray is not changed by the failed call
        local r = tc.ref("abc")
        assertError("cannot resize carray", bzip2.decompress, c, r)
        assert(r:tostring() == "abc")
        -- the stream methods check out in the same way
        local e = bzip2.compressor()
        assertError("out: carray is not writable", e.update, e, "x", tc.readonly(""))
        assertError("cannot resize carray", e.finish, e, s, tc.ref(""))
        local d = bzip2.decompressor()
        assertError("out: carray is not writable", d.decompress, d, c, tc.readonly(""))
        assertError("cannot resize carray", d.update, d, c, r)
        assert(r:tostring() == "abc")
    end
end
PRINT("==================================================================================")
do
    -- streaming with carray chunks
    local s = text(300000)
    local c = bzip2.compress(s)
    local d = bzip2.decompressor()
    local parts = {}
    for i = 1, #c, 1000 do
        parts[#parts + 1] = d:update(newC(c:sub(i, i + 999)))
    end
    parts[#parts + 1] = d:finish(carray.new("char"))
    assert(table.concat(parts) == s)

    d = bzip2.decompressor({ small = true })
    local out, st, n = d:decompress(newC(c .. "trailing", "uint8"))
    assert(out == s and st == bzip2.BZ_STREAM_END and n == #c)

    local e = bzip2.compressor({ level = 2 })
    parts = {}
    for i = 1, #s, 10000 do
        parts[#parts + 1] = e:update(newC(s:sub(i, i + 9999), "uchar"))
    end
    parts[#parts + 1] = e:flush(newC("x"))
    parts[#parts + 1] = e:finish(newC("y"))
    assert(bzip2.decompress(table.concat(parts)) == s .. "xy")
    assertError("carray elements must be 1 byte in size", bzip2.decompressor().update,
                bzip2.decompressor(), carray.new("double", 1))
    assertError("carray elements must be 1 byte in size", bzip2.decompressor().bzinflate,
                bzip2.decompressor(), carray.new("double", 1))
end
PRINT("==================================================================================")
do
    -- 10 MB in carrays
    local s = text(10 * 1024 * 1024, 5)
    local src = newC(s)
    local comp = carray.new("char")
    local back = carray.new("char")
    for _, k in ipairs({ 1, 9 }) do
        comp:reset()
        back:reset()
        bzip2.compress(src, { level = k }, comp)
        bzip2.decompress(comp, back)
        assert(back:len() == #s and back:equals(src))
        assert(comp:tostring() == bzip2.compress(s, { level = k }))
    end
end
PRINT("==================================================================================")
print("OK.")
