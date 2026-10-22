-- compress.brotli with carray objects: carray input (read without copying) and carray output
-- (the out argument of all functions and methods: the output is appended in place).

local brotli = require("compress.brotli")

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

local function randomBytes(n, seed)
    local rnd = newRandom(seed or 1)
    local t = {}
    for i = 1, n do
        t[i] = string.char(rnd(256))
    end
    return table.concat(t)
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
        for _, t in ipairs({ "char", "uchar", "schar", "int8", "uint8" }) do
            local c = brotli.compress(s, { quality = 6 })
            assert(brotli.compress(newC(s, t), { quality = 6 }) == c)
            assert(brotli.decompress(newC(c, t)) == s)
        end
    end
    assert(brotli.compress(carray.new("char")) == "\6")
    assertError("Error in BrotliDecoderDecompressStream: unexpected end of input",
                brotli.decompress, carray.new("char"))
    assertError("carray elements must be 1 byte in size", brotli.compress, carray.new("int", 4))
    assertError("carray elements must be 1 byte in size", brotli.decompress, carray.new("short", 4))
end
PRINT("==================================================================================")
do
    -- carray output: the output is appended to the carray, which is returned
    local s = text(100000)
    local c = brotli.compress(s)

    local out = carray.new("char")
    assert(brotli.decompress(c, out) == out)
    assert(out:len() == #s and out:tostring() == s)

    local cout = carray.new("uint8")
    assert(brotli.compress(s, cout) == cout)
    assert(cout:tostring() == c)
    assert(brotli.compress(s, { quality = 3 }, cout) == cout)
    assert(cout:tostring() == c .. brotli.compress(s, { quality = 3 }))

    -- appended after the previous content, larger and smaller results
    local o = newC("prefix:")
    assert(brotli.decompress(brotli.compress("short"), o) == o)
    assert(o:tostring() == "prefix:short")
    brotli.decompress(c, o)
    assert(o:tostring() == "prefix:short" .. s)
    brotli.decompress("\6", o)
    assert(o:tostring() == "prefix:short" .. s)
    o:reset()
    brotli.compress("", o)
    assert(o:tostring() == "\6")
    brotli.compress("", o)
    assert(o:tostring() == "\6\6")
    -- incompressible data (stored as uncompressed meta-blocks) is appended as well
    local r = randomBytes(5000, 3)
    o = newC("abc")
    brotli.compress(r, o)
    assert(o:tostring() == "abc" .. brotli.compress(r))

    -- carray in, carray out
    local cin = newC(c)
    local o2 = carray.new("char")
    assert(brotli.decompress(cin, o2) == o2 and o2:tostring() == s)
    local o3 = carray.new("char")
    assert(brotli.compress(o2, o3) == o3 and o3:tostring() == c)

    -- reuse: decoding many times into the same carray, reset in between (keeps the capacity)
    o = newC(("x"):rep(500000))
    for i = 1, 20 do
        local si = text(1000 * i, i)
        o:reset()
        assert(brotli.decompress(brotli.compress(si, { quality = 1 }), o) == o)
        assert(o:tostring() == si)
    end
    -- many appends into one carray
    o = carray.new("char")
    local expect = {}
    for i = 1, 200 do
        local si = text(i * 37, i)
        brotli.decompress(brotli.compress(si, { quality = 1 }), o)
        expect[#expect + 1] = si
    end
    assert(o:tostring() == table.concat(expect))
end
PRINT("==================================================================================")
do
    -- carray output errors
    local c = brotli.compress(text(50000))
    assertError("out: carray expected, got table", brotli.decompress, c, nil, {})
    assertError("out: carray expected, got number", brotli.compress, "x", {}, 1)
    assertError("out: carray elements must be 1 byte in size", brotli.decompress, c,
                carray.new("int"))
    local cin = newC(c)
    assertError("out: carray must not be the input data", brotli.decompress, cin, cin)
    assert(cin:tostring() == c)
    assertError("bad argument #3", brotli.decompress, c, nil, {})

    -- on errors the output carray keeps its previous content, nothing is appended
    local o = newC("previous content")
    assertError("output exceeds maxsize", brotli.decompress, c, { maxsize = 1000 }, o)
    assert(o:tostring() == "previous content")
    assertError("Error in BrotliDecoderDecompressStream: unexpected end of input",
                brotli.decompress, c:sub(1, 1000), o)
    assert(o:tostring() == "previous content")
    assertError("Error in BrotliDecoderDecompressStream: ERROR_FORMAT_",
                brotli.decompress, "garbage", o)
    assert(o:tostring() == "previous content")
    assertError("Error in BrotliDecoderDecompressStream: unexpected data after end of stream",
                brotli.decompress, c .. "x", o)
    assert(o:tostring() == "previous content")

    -- maxsize counts the output of the call, not the length of the carray
    local s = text(50000)
    assert(brotli.decompress(c, { maxsize = #s }, o):tostring() == "previous content" .. s)
    assertError("output exceeds maxsize", brotli.decompress, c, { maxsize = #s - 1 }, o)
    assert(o:tostring() == "previous content" .. s)
    o:reset()
    -- the limit applies even if the carray's capacity is larger
    assertError("output exceeds maxsize", brotli.decompress, c, { maxsize = #s - 1 }, o)
    assert(o:len() == 0)
end
PRINT("==================================================================================")
do
    -- carray output of the stream methods: appended, the carray is returned (also when
    -- there is no output), the same bytes as with string results
    local s = text(200000, 3)
    local function compressParts(e, chunks, o)
        for _, ch in ipairs(chunks) do
            assert(e:update(ch, o) == o)
        end
        assert(e:flush(nil, o) == o)
        assert(e:flush("more", o) == o)
        assert(e:finish("end", o) == o)
        return o
    end
    local chunks = {}
    for i = 1, #s, 7000 do chunks[#chunks + 1] = s:sub(i, i + 6999) end

    local e = brotli.compressor({ quality = 5 })
    local strParts = {}
    for _, ch in ipairs(chunks) do strParts[#strParts + 1] = e:update(ch) end
    strParts[#strParts + 1] = e:flush()
    strParts[#strParts + 1] = e:flush("more")
    strParts[#strParts + 1] = e:finish("end")
    local cs = table.concat(strParts)

    local o = compressParts(brotli.compressor({ quality = 5 }), chunks, newC("head"))
    assert(o:tostring() == "head" .. cs)
    assert(brotli.decompress(o:tostring():sub(5)) == s .. "moreend")
    -- the update that gives no output still returns the carray, unchanged
    local o1 = newC("x")
    e = brotli.compressor()
    assert(e:update("abc", o1) == o1 and o1:tostring() == "x")
    assert(e:finish(nil, o1) == o1 and brotli.decompress(o1:tostring():sub(2)) == "abc")
    -- carray chunks and a carray out (not the same object)
    e = brotli.compressor()
    local co = carray.new("uint8")
    local chunk = newC("carray chunk")
    assert(e:update(chunk, co) == co)
    assert(e:finish(newC("!"), co) == co)
    assert(brotli.decompress(co) == "carray chunk!")
    -- nil as out: string result
    e = brotli.compressor()
    assert(e:update("abc", nil) == nil)
    assert(type(e:finish(nil, nil)) == "string")

    -- decompressor
    local d = brotli.decompressor()
    o = newC("head")
    for i = 1, #cs, 999 do
        assert(d:update(cs:sub(i, i + 998), o) == o)
    end
    assert(d:finish(nil, o) == o)
    assert(o:tostring() == "head" .. s .. "moreend")
    d = brotli.decompressor()
    o = newC("a")
    assert(d:update("", o) == o and o:tostring() == "a")
    assert(d:finish(brotli.compress("bc"), o) == o and o:tostring() == "abc")
    -- 1 byte pieces into one carray
    local c = brotli.compress(text(3000, 9))
    d = brotli.decompressor()
    o = carray.new("char")
    for i = 1, #c do
        assert(d:update(c:sub(i, i), o) == o)
    end
    assert(d:finish(nil, o) == o and o:tostring() == text(3000, 9))
    -- reuse after reset
    o:reset()
    d = brotli.decompressor()
    assert(d:finish(c, o):tostring() == text(3000, 9))

    -- errors of the stream methods: the carray keeps what the successful calls appended
    c = brotli.compress(s)
    d = brotli.decompressor()
    o = newC("head")
    d:update(c:sub(1, #c - 10), o)
    local before = o:tostring()
    assert(#before > 4)
    assertError("unexpected data after end of stream", d.update, d, c:sub(#c - 9) .. "x", o)
    assert(o:tostring() == before)
    d = brotli.decompressor()
    o = newC("head")
    assertError("Error in BrotliDecoderDecompressStream: ERROR_FORMAT_", d.update, d, "garbage", o)
    assert(o:tostring() == "head")
    d = brotli.decompressor()
    o = newC("head")
    assertError("unexpected end of input", d.finish, d, c:sub(1, 1000), o)
    assert(o:tostring() == "head")
    d = brotli.decompressor()
    o = newC("head")
    assertError("unexpected data after end of stream", d.update, d, c .. "x", o)
    assert(o:tostring() == "head")
    d = brotli.decompressor()
    d:update(c)
    assertError("unexpected data after end of stream", d.finish, d, "x", o)
    assert(o:tostring() == "head")
    -- maxsize counts the output of the stream
    d = brotli.decompressor({ maxsize = #s })
    o = newC(("p"):rep(100))
    for i = 1, #c, 5000 do
        d:update(c:sub(i, i + 4999), o)
    end
    assert(d:finish(nil, o):tostring() == ("p"):rep(100) .. s)
    d = brotli.decompressor({ maxsize = #s - 1 })
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
    e = brotli.compressor()
    assertError("out: carray expected, got string", e.update, e, "x", "y")
    assertError("bad argument #3", e.update, e, "x", {})
    assertError("out: carray elements must be 1 byte in size", e.flush, e, nil, carray.new("int"))
    local same = newC("x")
    assertError("out: carray must not be the input data", e.finish, e, same, same)
    d = brotli.decompressor()
    assertError("out: carray expected, got table", d.update, d, "x", {})
    assertError("out: carray must not be the input data", d.update, d, same, same)
    assertError("out: carray expected, got boolean", d.finish, d, nil, true)
    assertError("out: carray expected, got number", d.decompress, d, "x", 1)
end
PRINT("==================================================================================")
do
    -- the status method decompress() with carray output
    local s = text(100000, 4)
    local c = brotli.compress(s)
    local d = brotli.decompressor()
    local o = newC("head")
    local out, st, n = d:decompress(c .. "trailing", o)
    assert(out == o and o:tostring() == "head" .. s)
    assert(st == brotli.BROTLI_DECODER_RESULT_SUCCESS and n == #c)
    out, st, n = d:decompress("x", o)
    assert(out == o and o:tostring() == "head" .. s and st == brotli.BROTLI_DECODER_RESULT_SUCCESS and n == 0)
    -- in pieces
    d = brotli.decompressor()
    o = carray.new("char")
    for i = 1, #c, 777 do
        out, st, n = d:decompress(c:sub(i, i + 776), o)
        assert(out == o)
    end
    assert(st == brotli.BROTLI_DECODER_RESULT_SUCCESS and o:tostring() == s)
    -- on an error the output up to the error is appended (as for the string result)
    d = brotli.decompressor({ maxsize = 1000 })
    o = newC("head")
    out, st, n = d:decompress(c, o)
    assert(out == o and st == brotli.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT)
    assert(o:tostring() == "head" .. s:sub(1, 1000))
    assert(d:msg() == "output exceeds maxsize")
    out, st, n = d:decompress(c, o)
    assert(out == o and o:len() == 1004 and st == brotli.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT and n == 0)
    d = brotli.decompressor()
    o = newC("head")
    out, st = d:decompress(c:sub(1, 3000) .. ("\255"):rep(100), o)
    assert(out == o and st == brotli.BROTLI_DECODER_RESULT_ERROR)
    assert(o:len() >= 4 and s:sub(1, o:len() - 4) == o:tostring():sub(5))
    assertError("carray elements must be 1 byte in size", d.decompress, d, carray.new("double", 1))
end
PRINT("==================================================================================")
do
    -- read-only and non-resizable carrays from the test helper module
    local ok2, tc = pcall(require, "compress_testcarray")
    if not ok2 then
        print("test helper compress_testcarray not available: test part skipped")
    else
        local s = text(30000)
        local c = brotli.compress(s)
        -- read-only carrays can be read
        assert(brotli.decompress(tc.readonly(c)) == s)
        assert(brotli.compress(tc.readonly(s)) == c)
        assertError("out: carray is not writable", brotli.decompress, c, tc.readonly("abc"))
        -- carrays referencing foreign memory cannot be resized
        assert(brotli.decompress(tc.ref(c)) == s)
        assertError("cannot resize carray", brotli.decompress, c, tc.ref("abc"))
        assertError("cannot resize carray", brotli.compress, s, tc.ref(""))
        -- the carray is not changed by the failed call
        local r = tc.ref("abc")
        assertError("cannot resize carray", brotli.decompress, c, r)
        assert(r:tostring() == "abc")
        -- the stream methods check out in the same way
        local e = brotli.compressor()
        assertError("out: carray is not writable", e.update, e, "x", tc.readonly(""))
        assertError("cannot resize carray", e.finish, e, s, tc.ref(""))
        local d = brotli.decompressor()
        assertError("out: carray is not writable", d.decompress, d, c, tc.readonly(""))
        assertError("cannot resize carray", d.update, d, c, r)
        assert(r:tostring() == "abc")
    end
end
PRINT("==================================================================================")
do
    -- streaming with carray chunks
    local s = text(300000)
    local c = brotli.compress(s)
    local d = brotli.decompressor()
    local parts = {}
    for i = 1, #c, 1000 do
        parts[#parts + 1] = d:update(newC(c:sub(i, i + 999)))
    end
    parts[#parts + 1] = d:finish(carray.new("char"))
    assert(table.concat(parts) == s)

    local e = brotli.compressor({ quality = 7, sizehint = #s })
    parts = {}
    for i = 1, #s, 10000 do
        parts[#parts + 1] = e:update(newC(s:sub(i, i + 9999), "uchar"))
    end
    parts[#parts + 1] = e:finish()
    assert(table.concat(parts) == brotli.compress(s, { quality = 7 }))
    assertError("carray elements must be 1 byte in size", brotli.decompressor().update,
                brotli.decompressor(), carray.new("double", 1))
end
PRINT("==================================================================================")
do
    -- 10 MB in carrays
    local s = text(10 * 1024 * 1024, 5)
    local src = newC(s)
    local comp = carray.new("char")
    local back = carray.new("char")
    brotli.compress(src, { quality = 4 }, comp)
    brotli.decompress(comp, back)
    assert(back:len() == #s and back:equals(src))
    assert(brotli.decompress(comp:tostring()) == s)
end
PRINT("==================================================================================")
print("OK.")
