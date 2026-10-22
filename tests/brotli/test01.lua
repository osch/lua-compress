-- compress.brotli with string data: one-shot functions, options, errors and streaming.

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

-- deterministic pseudo random numbers (Park-Miller), exact also with doubles (Lua 5.1)
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

local WORDS = { "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
                "elit", "sed", "do", "eiusmod", "tempor", "\0", "\n", "Brotli", "Lua" }

-- compressible text of at least n bytes
local function text(n, seed)
    local rnd = newRandom(seed or 7)
    local t, len = {}, 0
    while len < n do
        local w = WORDS[rnd(#WORDS) + 1]
        t[#t + 1] = w
        t[#t + 1] = " "
        len = len + #w + 1
    end
    return table.concat(t):sub(1, n)
end

-- streaming helpers: feed data in chunks of the given size
local function streamDecompress(data, chunk, opts)
    local d = brotli.decompressor(opts)
    local out = {}
    for i = 1, #data, chunk do
        local r = d:update(data:sub(i, i + chunk - 1))
        assert(r == nil or (type(r) == "string" and #r > 0))
        out[#out + 1] = r
    end
    out[#out + 1] = d:finish()
    return table.concat(out)
end

local function streamCompress(data, chunk, opts)
    local c = brotli.compressor(opts)
    local out = {}
    for i = 1, #data, chunk do
        local r = c:update(data:sub(i, i + chunk - 1))
        assert(r == nil or (type(r) == "string" and #r > 0))
        out[#out + 1] = r
    end
    out[#out + 1] = c:finish()
    return table.concat(out)
end

PRINT("==================================================================================")
do
    PRINT(format("compress.brotli %s, libbrotlidec %s, libbrotlienc %s", brotli._VERSION, brotli.version()))
    local dv, ev = brotli.version()
    assert(dv:match("^%d+%.%d+%.%d+$") and ev:match("^%d+%.%d+%.%d+$"))
    assert(getmetatable(brotli) == "compress.brotli")
    assert(getmetatable(brotli.decompressor()) == "compress.brotli.decompressor")
    assert(getmetatable(brotli.compressor()) == "compress.brotli.compressor")
    assert(tostring(brotli.decompressor()):match("^compress%.brotli%.decompressor: "))
    assert(tostring(brotli.compressor()):match("^compress%.brotli%.compressor: "))
end
PRINT("==================================================================================")
do
    -- roundtrips of various data
    local all = {}
    for i = 0, 255 do all[#all + 1] = string.char(i) end
    all = table.concat(all)
    local samples = {
        "", "a", "\0", ("\0"):rep(1000), "a\0b\0\0c", all, all:rep(100), text(1000),
        text(100000), randomBytes(1000), randomBytes(100000, 3),
        text(50000) .. randomBytes(50000) .. text(50000, 9),
    }
    for _, s in ipairs(samples) do
        local c = brotli.compress(s)
        assert(type(c) == "string")
        assert(brotli.decompress(c) == s)
    end
    -- numbers are converted to strings as in the string library
    assert(brotli.decompress(brotli.compress(12345)) == "12345")
end
PRINT("==================================================================================")
do
    -- empty data: a valid Brotli stream needs at least one byte
    assert(brotli.compress("") == "\6")
    assert(brotli.decompress("\6") == "")
    assertError("Error in BrotliDecoderDecompressStream: unexpected end of input",
                brotli.decompress, "")
end
PRINT("==================================================================================")
do
    -- quality, lgwin and mode
    local s = text(200000)
    local sizes = {}
    for q = 0, 11 do
        local c = brotli.compress(s, { quality = q })
        assert(brotli.decompress(c) == s)
        sizes[q] = #c
    end
    assert(sizes[11] < sizes[5] and sizes[5] < sizes[0], format("%d %d %d", sizes[11], sizes[5], sizes[0]))

    -- defaults are those of libbrotli: quality 11, lgwin 22, mode generic
    assert(brotli.compress(s) == brotli.compress(s, { quality = 11, lgwin = 22, mode = "generic" }))

    -- a random block repeated at a distance of 4 KB: a 1 KB window cannot reference it
    local r = randomBytes(4096, 11)
    local rr = r .. r
    local small = brotli.compress(rr, { lgwin = 10, quality = 9 })
    local large = brotli.compress(rr, { lgwin = 16, quality = 9 })
    assert(brotli.decompress(small) == rr and brotli.decompress(large) == rr)
    assert(#large < #small - 3000, format("%d %d", #large, #small))
    for w = 10, 24 do
        assert(brotli.decompress(brotli.compress(s, { lgwin = w, quality = 4 })) == s)
    end

    for _, m in ipairs({ "generic", "text", "font" }) do
        assert(brotli.decompress(brotli.compress(s, { mode = m, quality = 9 })) == s)
    end
    -- integral floats are accepted
    assert(brotli.compress(s, { quality = 5.0 }) == brotli.compress(s, { quality = 5 }))

    -- level: the common name of quality in lua-compress
    for _, q in ipairs({ 0, 1, 5, 11 }) do
        local c = brotli.compress(s, { quality = q })
        assert(brotli.compress(s, { level = q }) == c)
        assert(brotli.compress(s, { level = q, quality = q }) == c)
        local e = brotli.compressor({ level = q, sizehint = #s })
        local e2 = brotli.compressor({ quality = q, sizehint = #s })
        assert(e:finish(s) == e2:finish(s))
    end
    assertError("level contradicts quality", brotli.compress, s, { level = 5, quality = 6 })
    assertError("level contradicts quality", brotli.compressor, { quality = 0, level = 11 })
    assertError("bad argument #2", brotli.compress, s, { level = 5, quality = 6 })
    assertError("Invalid level value", brotli.compress, s, { level = 12 })
    assertError("Invalid level value", brotli.compressor, { level = -1 })
    assertError("Invalid level value", brotli.compress, s, { level = "5" })
    assertError("Invalid level value", brotli.compress, s, { level = 2.5 })
end
PRINT("==================================================================================")
do
    -- invalid options
    local s = "data"
    assertError("Invalid quality value", brotli.compress, s, { quality = -1 })
    assertError("Invalid quality value", brotli.compress, s, { quality = 12 })
    assertError("Invalid quality value", brotli.compress, s, { quality = 1.5 })
    assertError("Invalid quality value", brotli.compress, s, { quality = "5" })
    assertError("Invalid window value",  brotli.compress, s, { lgwin = 9 })
    assertError("Invalid window value",  brotli.compress, s, { lgwin = 25 })
    assertError("Invalid encoder mode",  brotli.compress, s, { mode = "binary" })
    assertError("Invalid encoder mode",  brotli.compress, s, { mode = 1 })
    assertError("invalid maxsize value", brotli.decompress, "\6", { maxsize = -1 })
    assertError("invalid maxsize value", brotli.decompress, "\6", { maxsize = 0.5 })
    assertError("invalid sizehint value", brotli.compressor, { sizehint = -1 })
    assertError("unknown option 'qualty'", brotli.compress, s, { qualty = 5 })
    assertError("unknown option 'blocksize'", brotli.compressor, { blocksize = 5 })
    -- options of the module that the function does not take
    assertError("option 'maxsize' is not supported by compress()", brotli.compress, s, { maxsize = 5 })
    assertError("option 'sizehint' is not supported by compress()", brotli.compress, s, { sizehint = 5 })
    assertError("option 'quality' is not supported by decompress()", brotli.decompress, "\6", { quality = 5 })
    assertError("option 'level' is not supported by decompress()", brotli.decompress, "\6", { level = 5 })
    assertError("option 'level' is not supported by decompressor()", brotli.decompressor, { level = 5 })
    assertError("option 'maxsize' is not supported by compressor()", brotli.compressor, { maxsize = 5 })
    assertError("option 'allowtrailing' is not supported by compressor()", brotli.compressor,
                { allowtrailing = true })
    -- the former option out: the carray is the last argument
    for _, f in ipairs({ brotli.compress, brotli.decompress }) do
        assertError("option 'out' is no longer supported: pass the carray as the last argument",
                    f, "\6", { out = 1 })
    end
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                brotli.compressor, { out = 1 })
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                brotli.decompressor, { out = 1 })
    assertError("option names must be strings", brotli.compress, s, { 5 })
    -- the second argument of compress/decompress: options table or output carray
    assertError("table or carray expected, got string", brotli.compress, s, "q")
    assertError("table or carray expected, got number", brotli.decompress, "\6", 5)
    assertError("bad argument #2", brotli.decompress, "\6", true)
    assertError("table expected, got number", brotli.decompressor, 5)
    assertError("out: carray expected, got string", brotli.compress, s, nil, "x")
    assertError("out: carray expected, got table", brotli.decompress, "\6", {}, {})
    assertError("bad argument #3", brotli.decompress, "\6", {}, {})
    assertError("out: carray expected, got userdata", brotli.compress, s, io.stdout)
    assertError("bad argument #2", brotli.compress, s, io.stdout)
    -- nil as options and as out
    assert(brotli.compress(s, nil) == brotli.compress(s))
    assert(brotli.compress(s, nil, nil) == brotli.compress(s))
    assert(brotli.decompress("\6", {}, nil) == "")
    -- invalid data
    assertError("string or carray expected, got table",   brotli.compress, {})
    assertError("string or carray expected, got no value", brotli.compress)
    assertError("string or carray expected, got nil",     brotli.decompress, nil)
    assertError("string or carray expected, got boolean", brotli.decompress, true)
    assertError("bad argument #2",                         brotli.compress, s, { quality = 12 })
end
PRINT("==================================================================================")
do
    -- maxsize
    local s = text(100000)
    local c = brotli.compress(s)
    assert(brotli.decompress(c, { maxsize = #s }) == s)
    assert(brotli.decompress(c, { maxsize = #s + 1 }) == s)
    assert(brotli.decompress(c, { maxsize = 1e12 }) == s)
    assertError("output exceeds maxsize", brotli.decompress, c, { maxsize = #s - 1 })
    assertError("output exceeds maxsize", brotli.decompress, c, { maxsize = 0 })
    assert(brotli.decompress("\6", { maxsize = 0 }) == "")
    -- a compression bomb is stopped early
    local bomb = brotli.compress(("\0"):rep(50 * 1024 * 1024), { quality = 1 })
    assert(#bomb < 100000)
    assertError("output exceeds maxsize", brotli.decompress, bomb, { maxsize = 1000 })
end
PRINT("==================================================================================")
do
    -- corrupt and incomplete input
    local s = text(10000)
    local c = brotli.compress(s)
    assertError("Error in BrotliDecoderDecompressStream: ERROR_FORMAT_", brotli.decompress, "garbage")
    assertError("Error in BrotliDecoderDecompressStream: unexpected end of input",
                brotli.decompress, c:sub(1, #c - 1))
    assertError("Error in BrotliDecoderDecompressStream: unexpected data after end of stream",
                brotli.decompress, c .. "x")
    -- allowtrailing: data after the end of the stream is ignored, as by IO::Compress::Brotli
    assert(brotli.decompress(c .. "x", { allowtrailing = true }) == s)
    assert(brotli.decompress(c .. c, { allowtrailing = true, maxsize = #s }) == s)
    assert(brotli.decompress("\6garbage", { allowtrailing = true }) == "")
    assertError("unexpected data after end of stream", brotli.decompress, c .. "x",
                { allowtrailing = false })
    assertError("invalid allowtrailing value", brotli.decompress, c, { allowtrailing = 1 })
    assertError("option 'allowtrailing' is not supported by compress()", brotli.compress, s, { allowtrailing = true })
    -- every truncation and every single changed byte fails or (rarely) still decodes:
    -- never a crash
    for i = 0, #c - 1 do
        assert(not pcall(brotli.decompress, c:sub(1, i)))
    end
    local failed = 0
    for i = 1, #c do
        local b = c:byte(i)
        local x = c:sub(1, i - 1) .. string.char((b + 1) % 256) .. c:sub(i + 1)
        local ok, r = pcall(brotli.decompress, x)
        if not ok then
            assert(r:find("^Error in BrotliDecoderDecompressStream: "), r)
            failed = failed + 1
        end
    end
    assert(failed > 0)
end
PRINT("==================================================================================")
do
    -- streaming decompression gives the same result as one call, for any chunk size
    local samples = { "", "x", text(100000), randomBytes(70000, 5), ("\0"):rep(300000) }
    for _, s in ipairs(samples) do
        local c = brotli.compress(s)
        for _, chunk in ipairs({ 1, 7, 100, 4096, 65536, #c + 1 }) do
            if chunk < 100 and #c > 20000 then chunk = chunk * 1000 end
            assert(streamDecompress(c, chunk) == s)
        end
    end
    -- update returns nil without output, finish returns the empty string
    local d = brotli.decompressor()
    assert(d:update("") == nil)
    assert(d:update("\6") == nil)
    assert(d:finish() == "")
    -- finish with a last chunk
    local s = text(5000)
    local c = brotli.compress(s)
    d = brotli.decompressor()
    local a = d:update(c:sub(1, 10)) or ""
    assert(a .. d:finish(c:sub(11)) == s)
    assert(brotli.decompressor():finish(c) == s)
end
PRINT("==================================================================================")
do
    -- streaming decompression errors
    local s = text(20000)
    local c = brotli.compress(s)

    local d = brotli.decompressor()
    assertError("Error in BrotliDecoderDecompressStream: ERROR_FORMAT_", d.update, d, "garbage")
    assertError("decompressor is closed", d.update, d, c)
    assertError("decompressor is closed", d.finish, d)

    d = brotli.decompressor()
    d:update(c:sub(1, 10))
    assertError("Error in BrotliDecoderDecompressStream: unexpected end of input", d.finish, d)
    assertError("decompressor is closed", d.update, d, "")

    d = brotli.decompressor()
    assert(d:update(c) == s)
    assert(d:update("") == nil)
    assertError("unexpected data after end of stream", d.update, d, "x")

    d = brotli.decompressor()
    assertError("unexpected data after end of stream", d.update, d, c .. "x")

    d = brotli.decompressor()
    d:update(c)
    assertError("unexpected data after end of stream", d.finish, d, "x")

    d = brotli.decompressor()
    assert(d:finish(c) == s)
    assertError("decompressor is closed", d.finish, d)

    -- allowtrailing in streams: everything after the end is ignored
    d = brotli.decompressor({ allowtrailing = true })
    local a = d:update(c:sub(1, 100)) or ""
    local b = d:update(c:sub(101) .. "trailing") or ""
    assert(a .. b == s)
    assert(d:update("more trailing data") == nil)
    assert(d:update(c) == nil)
    assert(d:finish("x") == "")
    d = brotli.decompressor({ allowtrailing = true })
    assert(d:finish(c .. "x") == s)

    -- maxsize counts the whole stream
    assert(streamDecompress(c, 1000, { maxsize = #s }) == s)
    assertError("output exceeds maxsize", streamDecompress, c, 1000, { maxsize = #s - 1 })
    assertError("output exceeds maxsize", streamDecompress, c, 1, { maxsize = 100 })

    assertError("string or carray expected, got nil", d.update, brotli.decompressor(), nil)
    assertError("compress.brotli.decompressor expected", brotli.decompressor().update, {}, "")
    assertError("compress.brotli.decompressor expected", brotli.decompressor().update,
                brotli.compressor(), "")
end
PRINT("==================================================================================")
do
    -- the status method decompressor:decompress(): no errors for the data, libbrotli's
    -- BrotliDecoderResult as status and the number of bytes consumed
    local SUCCESS = brotli.BROTLI_DECODER_RESULT_SUCCESS
    local MORE_IN = brotli.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT
    local ERROR   = brotli.BROTLI_DECODER_RESULT_ERROR
    local MAXSIZE = brotli.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT
    assert(ERROR == 0 and SUCCESS == 1 and MORE_IN == 2 and MAXSIZE == 3)

    local s = text(50000, 21)
    local c = brotli.compress(s)

    -- the whole stream, then calls after the end
    local d = brotli.decompressor()
    assert(d:msg() == nil)
    local out, st, n = d:decompress(c)
    assert(out == s and st == SUCCESS and n == #c)
    out, st, n = d:decompress("more")
    assert(out == "" and st == SUCCESS and n == 0)
    assert(d:finish() == "")
    assertError("decompressor is closed", d.decompress, d, "")

    -- trailing data is not consumed and raises no error, regardless of allowtrailing
    for _, allow in ipairs({ false, true }) do
        d = brotli.decompressor({ allowtrailing = allow })
        out, st, n = d:decompress(c .. "trailing data")
        assert(out == s and st == SUCCESS and n == #c)
        assert(("x" .. c .. "trailing data"):sub(n + 2) == "trailing data")
    end
    d = brotli.decompressor()
    out, st, n = d:decompress("\6\6")
    assert(out == "" and st == SUCCESS and n == 1)

    -- in pieces: NEEDS_MORE_INPUT while the stream goes on, all input consumed
    for _, chunk in ipairs({ 1, 13, 1000 }) do
        d = brotli.decompressor()
        local parts = {}
        for i = 1, #c, chunk do
            local piece = c:sub(i, i + chunk - 1)
            out, st, n = d:decompress(piece)
            parts[#parts + 1] = out
            if i + chunk - 1 < #c then
                assert(st == MORE_IN and n == #piece, i)
            else
                assert(st == SUCCESS and n == #piece)
            end
        end
        assert(table.concat(parts) == s)
    end
    -- 1 byte pieces with trailing data in the last piece
    d = brotli.decompressor()
    local parts = {}
    for i = 1, #c - 1 do
        out, st, n = d:decompress(c:sub(i, i))
        assert(st == MORE_IN and n == 1)
        parts[#parts + 1] = out
    end
    out, st, n = d:decompress(c:sub(-1) .. "XY")
    assert(st == SUCCESS and n == 1)
    assert(table.concat(parts) .. out == s)

    -- empty and truncated input: NEEDS_MORE_INPUT, only finish() decides that the input ended
    d = brotli.decompressor()
    out, st, n = d:decompress("")
    assert(out == "" and st == MORE_IN and n == 0)
    out, st, n = d:decompress(c:sub(1, 100))
    assert(st == MORE_IN and n == 100 and s:sub(1, #out) == out)
    assertError("Error in BrotliDecoderDecompressStream: unexpected end of input", d.finish, d)
    assert(d:msg() == "unexpected end of input")

    -- invalid data: ERROR, msg() with libbrotli's error code name; the stream cannot go on
    d = brotli.decompressor()
    out, st, n = d:decompress("garbage")
    assert(out == "" and st == ERROR and n <= #"garbage")
    assert(d:msg():match("^ERROR_FORMAT_"), d:msg())
    local m = d:msg()
    out, st, n = d:decompress(c)
    assert(out == "" and st == ERROR and n == 0 and d:msg() == m)
    -- update/finish after the error raise it and close the object
    assertError("Error in BrotliDecoderDecompressStream: " .. m, d.update, d, c)
    assertError("decompressor is closed", d.decompress, d, c)
    assert(d:msg() == m)
    d = brotli.decompressor()
    d:decompress("garbage")
    assertError("Error in BrotliDecoderDecompressStream: ERROR_FORMAT_", d.finish, d)
    -- the output up to the error
    -- (several meta-blocks and a small window: the decoder writes output before the end)
    local found = false
    local c2 = brotli.compress(text(300000, 22), { quality = 1, lgwin = 16 })
    for i = #c2 - 20, #c2 - 400, -1 do
        -- a changed byte that gives an error after some output
        local x = c2:sub(1, i - 1) .. string.char((c2:byte(i) + 77) % 256) .. c2:sub(i + 1)
        if not pcall(brotli.decompress, x) then
            d = brotli.decompressor()
            out, st, n = d:decompress(x)
            assert(n <= #x)
            -- (the error may also be data after the end or a truncated stream)
            if st == ERROR and #out > 0 then
                d = brotli.decompressor()
                parts = {}
                local st2
                for j = 1, #x, 7 do
                    local o2
                    o2, st2 = d:decompress(x:sub(j, j + 6))
                    parts[#parts + 1] = o2
                    if st2 ~= MORE_IN then break end
                end
                -- (in pieces the decoder may have written more before it saw the error)
                local o2 = table.concat(parts)
                assert(st2 == ERROR and o2:sub(1, #out) == out)
                found = true
                break
            end
        end
    end
    assert(found)

    -- maxsize: NEEDS_MORE_OUTPUT with the output up to maxsize
    d = brotli.decompressor({ maxsize = 1000 })
    out, st, n = d:decompress(c)
    assert(out == s:sub(1, 1000) and st == MAXSIZE and n <= #c)
    assert(d:msg() == "output exceeds maxsize")
    out, st, n = d:decompress(c)
    assert(out == "" and st == MAXSIZE and n == 0)
    assertError("output exceeds maxsize", d.update, d, "")
    d = brotli.decompressor({ maxsize = #s })
    out, st, n = d:decompress(c)
    assert(out == s and st == SUCCESS and n == #c)
    d = brotli.decompressor({ maxsize = #s - 1 })
    parts = {}
    for i = 1, #c do
        out, st, n = d:decompress(c:sub(i, i))
        parts[#parts + 1] = out
        if st ~= MORE_IN then break end
    end
    assert(st == MAXSIZE and table.concat(parts) == s:sub(1, #s - 1))
    d = brotli.decompressor({ maxsize = 0 })
    out, st, n = d:decompress("\6")
    assert(out == "" and st == SUCCESS and n == 1)

    -- mixed with update and finish on the same object
    d = brotli.decompressor()
    local a = d:update(c:sub(1, 3000)) or ""
    out, st, n = d:decompress(c:sub(3001, 6000))
    assert(st == MORE_IN and n == 3000)
    assert(a .. out .. d:finish(c:sub(6001)) == s)
    d = brotli.decompressor()
    out, st = d:decompress(c)
    assert(st == SUCCESS)
    assertError("unexpected data after end of stream", d.update, d, "x")

    -- argument errors are raised
    assertError("string or carray expected, got nil", d.decompress, brotli.decompressor(), nil)
    assertError("compress.brotli.decompressor expected", d.decompress, brotli.compressor(), "")
    assertError("compress.brotli.decompressor expected", d.msg, {})
end
PRINT("==================================================================================")
do
    -- streaming compression
    local s = text(300000) .. randomBytes(30000)
    for _, chunk in ipairs({ 1000, 4096, 100000, #s }) do
        for _, q in ipairs({ 0, 1, 2, 5, 9, 11 }) do
            local c = streamCompress(s, chunk, { quality = q })
            assert(brotli.decompress(c) == s)
            -- from quality 2 on, the output equals one call if the size is known
            if q >= 2 then
                assert(streamCompress(s, chunk, { quality = q, sizehint = #s })
                       == brotli.compress(s, { quality = q }), format("q=%d chunk=%d", q, chunk))
            end
        end
    end
    for _, m in ipairs({ "generic", "text", "font" }) do
        local c = streamCompress(s, 5000, { mode = m, lgwin = 18, quality = 6 })
        assert(brotli.decompress(c) == s)
    end

    -- empty stream (the encoder's stream header differs from compress(""), which gives
    -- the same output as BrotliEncoderCompress)
    assert(brotli.decompress(brotli.compressor():finish()) == "")
    assert(brotli.decompress(brotli.compressor():finish("")) == "")

    -- update returns nil while the encoder buffers its input
    local c = brotli.compressor()
    assert(c:update("abc") == nil)
    assert(brotli.decompress(c:finish("def")) == "abcdef")

    -- flush: the output so far can be decoded completely
    c = brotli.compressor({ quality = 5 })
    local d = brotli.decompressor()
    for i = 1, 10 do
        local part = text(1000, i)
        local o1 = c:update(part) or ""
        local o2 = c:flush() or ""
        assert(#o2 > 0)
        assert(d:update(o1 .. o2) == part, i)
    end
    assert(c:flush() == nil)
    assert(d:finish(c:finish()) == "")

    -- after finish the compressor is closed
    assertError("compressor is closed", c.update, c, "x")
    assertError("compressor is closed", c.finish, c)
    assertError("compressor is closed", c.flush, c)
end
PRINT("==================================================================================")
do
    -- 10 MB
    local t0 = os.clock()
    local s = text(5 * 1024 * 1024, 3) .. randomBytes(1024 * 1024, 4) .. text(4 * 1024 * 1024, 5)
    assert(#s == 10 * 1024 * 1024)
    local c = brotli.compress(s, { quality = 5 })
    assert(brotli.decompress(c) == s)
    assert(streamDecompress(c, 65536) == s)
    assert(brotli.decompress(streamCompress(s, 1024 * 1024, { quality = 5 })) == s)
    assertError("output exceeds maxsize", brotli.decompress, c, { maxsize = #s - 1 })
    assert(brotli.decompress(c, { maxsize = #s }) == s)
    PRINT(format("10 MB: %d bytes compressed (%.2f s cpu)", #c, os.clock() - t0))
end
PRINT("==================================================================================")
do
    -- abandoned streams are released by the garbage collector
    for i = 1, 200 do
        local c = brotli.compressor({ quality = 11, lgwin = 24 })
        c:update(text(1000, i))
        local d = brotli.decompressor()
        d:update(brotli.compress(text(1000, i)):sub(1, 20))
    end
    collectgarbage()
    collectgarbage()
end
PRINT("==================================================================================")
print("OK.")
