-- compress.bzip2 with string data: one-shot functions, block sizes, work factor, option
-- errors, streaming, flush modes, the status method decompressor:decompress() (alias
-- bzinflate()), concatenated streams, maxsize, the small decompression mode, 10 MB.

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
                "elit", "sed", "do", "eiusmod", "tempor", "\0", "\n", "bzip2", "Lua" }

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

local function with(base, extra)
    local o = {}
    for k, v in pairs(base or {}) do o[k] = v end
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- streaming helpers: feed data in chunks of the given size
local function streamDecompress(data, chunk, opts)
    local d = bzip2.decompressor(opts)
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
    local c = bzip2.compressor(opts)
    local out = {}
    for i = 1, #data, chunk do
        local r = c:update(data:sub(i, i + chunk - 1))
        assert(r == nil or (type(r) == "string" and #r > 0))
        out[#out + 1] = r
    end
    out[#out + 1] = c:finish()
    return table.concat(out)
end

-- all streams of concatenated bzip2 data (as bzip2 -d and IO::Uncompress::Bunzip2's
-- MultiStream): a new decompressor after each end of stream
local function decompressAll(data)
    local out = {}
    local pos = 1
    repeat
        local d = bzip2.decompressor()
        local o, st, n = d:decompress(data:sub(pos))
        assert(st == bzip2.BZ_STREAM_END, d:msg())
        out[#out + 1] = o
        pos = pos + n
    until pos > #data
    return table.concat(out)
end

PRINT("==================================================================================")
do
    PRINT(format("compress.bzip2 %s, libbz2 %s", bzip2._VERSION, bzip2.version()))
    assert(bzip2.version():match("^%d+%.%d+%.%d+"))
    assert(select("#", bzip2.version()) == 1)
    assert(getmetatable(bzip2) == "compress.bzip2")
    assert(getmetatable(bzip2.decompressor()) == "compress.bzip2.decompressor")
    assert(getmetatable(bzip2.compressor()) == "compress.bzip2.compressor")
    assert(tostring(bzip2.decompressor()):match("^compress%.bzip2%.decompressor: "))
    assert(tostring(bzip2.compressor()):match("^compress%.bzip2%.compressor: "))
end
PRINT("==================================================================================")
do
    -- the constants have libbz2's values
    local K = {
        BZ_RUN = 0, BZ_FLUSH = 1, BZ_FINISH = 2,
        BZ_OK = 0, BZ_RUN_OK = 1, BZ_FLUSH_OK = 2, BZ_FINISH_OK = 3, BZ_STREAM_END = 4,
        BZ_SEQUENCE_ERROR = -1, BZ_PARAM_ERROR = -2, BZ_MEM_ERROR = -3, BZ_DATA_ERROR = -4,
        BZ_DATA_ERROR_MAGIC = -5, BZ_IO_ERROR = -6, BZ_UNEXPECTED_EOF = -7, BZ_OUTBUFF_FULL = -8,
        BZ_CONFIG_ERROR = -9,
    }
    for name, value in pairs(K) do
        assert(bzip2[name] == value, name)
        assert(math.type == nil or math.type(bzip2[name]) == "integer", name)
    end
end
PRINT("==================================================================================")
do
    -- roundtrips of various data
    local all = {}
    for i = 0, 255 do all[#all + 1] = string.char(i) end
    all = table.concat(all)
    local samples = {
        "", "a", "\0", ("\0"):rep(1000), "a\0b\0\0c", all, all:rep(100), text(1000),
        text(100000), randomBytes(1000), randomBytes(50000, 3), ("aaaab"):rep(10000),
        text(30000) .. randomBytes(30000) .. text(30000, 9),
    }
    for _, s in ipairs(samples) do
        local c = bzip2.compress(s, { blockSize100k = 1 })
        assert(type(c) == "string")
        assert(bzip2.decompress(c) == s)
        assert(bzip2.decompress(c, { small = true }) == s)
        assert(bzip2.decompress(bzip2.compress(s)) == s)
    end
    -- numbers are converted to strings as in the string library
    assert(bzip2.decompress(bzip2.compress(12345)) == "12345")
end
PRINT("==================================================================================")
do
    -- the stream header "BZh" and the block size digit, the shortest stream
    local s = text(10000)
    for k = 1, 9 do
        local c = bzip2.compress(s, { blockSize100k = k })
        assert(c:sub(1, 4) == "BZh" .. k)
        assert(bzip2.compress(s, { level = k }) == c)
        assert(bzip2.compress(s, { level = k, blockSize100k = k }) == c)
    end
    assert(bzip2.compress(s) == bzip2.compress(s, { blockSize100k = 9 }))
    -- the empty stream: the header and the end of stream marker with the CRC 0
    assert(bzip2.compress("") == "BZh9\23\114\69\56\80\144\0\0\0\0")
    assert(bzip2.compress("", { level = 1 }) == "BZh1\23\114\69\56\80\144\0\0\0\0")
end
PRINT("==================================================================================")
do
    -- block sizes and work factor
    local s = text(1200000, 3) .. randomBytes(50000, 4)
    local sizes = {}
    for _, k in ipairs({ 1, 2, 5, 9 }) do
        local c = bzip2.compress(s, { blockSize100k = k })
        assert(bzip2.decompress(c) == s)
        sizes[k] = #c
    end
    assert(sizes[9] <= sizes[1] and sizes[1] < #s)
    -- the work factor only selects the sorting algorithm: the output is the same
    local r = ("ab"):rep(100000) .. ("\0"):rep(50000)          -- repetitive: the fallback sort
    for _, data in ipairs({ s:sub(1, 300000), r }) do
        local c = bzip2.compress(data)
        for _, wf in ipairs({ 0, 1, 30, 100, 250 }) do
            assert(bzip2.compress(data, { workFactor = wf }) == c)
        end
    end
    -- errors
    for _, v in ipairs({ 0, 10, -1, 1.5, "9", true }) do
        assertError("invalid blockSize100k value", bzip2.compress, s, { blockSize100k = v })
        assertError("invalid level value", bzip2.compressor, { level = v })
    end
    assertError("level contradicts blockSize100k", bzip2.compress, s, { level = 1, blockSize100k = 2 })
    for _, v in ipairs({ -1, 251, 2.5, "30" }) do
        assertError("invalid workFactor value", bzip2.compress, s, { workFactor = v })
    end
end
PRINT("==================================================================================")
do
    -- option errors
    assertError("option 'maxsize' is not supported by compress()", bzip2.compress, "x", { maxsize = 10 })
    assertError("option 'blockSize100k' is not supported by decompress()", bzip2.decompress, "x",
                { blockSize100k = 1 })
    assertError("option 'level' is not supported by decompress()", bzip2.decompress, "x", { level = 1 })
    assertError("option 'workFactor' is not supported by decompressor()", bzip2.decompressor,
                { workFactor = 30 })
    assertError("option 'small' is not supported by compressor()", bzip2.compressor, { small = true })
    assertError("option 'allowtrailing' is not supported by compressor()", bzip2.compressor,
                { allowtrailing = true })
    assertError("unknown option 'blocksize100k'", bzip2.compress, "x", { blocksize100k = 1 })
    assertError("unknown option 'verbosity'", bzip2.compressor, { verbosity = 1 })
    assertError("unknown option 'quality'", bzip2.compressor, { quality = 1 })
    assertError("unknown option 'multistream'", bzip2.decompressor, { multistream = true })
    -- the former option out: the carray is the last argument
    for _, f in ipairs({ bzip2.compress, bzip2.decompress }) do
        assertError("option 'out' is no longer supported: pass the carray as the last argument",
                    f, "x", { out = 1 })
    end
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                bzip2.compressor, { out = 1 })
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                bzip2.decompressor, { out = 1 })
    assertError("option names must be strings", bzip2.compress, "x", { 1 })
    -- the second argument of compress/decompress: options table or output carray
    assertError("table or carray expected, got string", bzip2.compress, "x", "level")
    assertError("table or carray expected, got boolean", bzip2.decompress, "x", false)
    assertError("table expected, got string", bzip2.compressor, "level")
    assertError("table expected, got number", bzip2.decompressor, 1)
    assertError("out: carray expected, got string", bzip2.compress, "x", {}, "y")
    assertError("bad argument #3", bzip2.compress, "x", nil, 1)
    assertError("out: carray expected, got userdata", bzip2.decompress, "x", io.stdout)
    assert(bzip2.decompress(bzip2.compress("x", nil, nil), nil, nil) == "x")
    assertError("bad argument #2", bzip2.compress, "x", { level = 99 })
    assertError("bad argument #1", bzip2.compressor, { level = 99 })
    assertError("invalid maxsize value", bzip2.decompress, "x", { maxsize = -1 })
    assertError("invalid maxsize value", bzip2.decompress, "x", { maxsize = 1.5 })
    assertError("invalid allowtrailing value", bzip2.decompress, "x", { allowtrailing = 1 })
    assertError("invalid small value", bzip2.decompressor, { small = 1 })
    assertError("string or carray expected, got table", bzip2.compress, {})
    assertError("string or carray expected, got no value", bzip2.decompress)
    assertError("string or carray expected, got boolean", bzip2.compressor().update, bzip2.compressor(), true)
    assertError("string or carray expected, got no value", bzip2.decompressor().update, bzip2.decompressor())
end
PRINT("==================================================================================")
do
    -- empty, corrupt, truncated data and data after the end
    assertError("Error in BZ2_bzDecompress: unexpected end of input", bzip2.decompress, "")
    assertError("Error in BZ2_bzDecompress: unexpected end of input", bzip2.decompress, "BZh9")
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", bzip2.decompress, ("garbage"):rep(2))
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", bzip2.decompress, "BZh0abcdefgh")
    assertError("Error in BZ2_bzDecompress: unexpected end of input", bzip2.decompress, "BZ")
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", bzip2.decompress, "BX")
    assertError("Error in BZ2_bzDecompress: DATA_ERROR", bzip2.decompress, "BZh9garbage!")
    assert(bzip2.decompress(bzip2.compress("")) == "")

    local s = text(100000)
    for _, opts in ipairs({ {}, { small = true } }) do
        local c = bzip2.compress(s)
        for _, n in ipairs({ 1, 2, 3, 4, 10, math.floor(#c / 2), #c - 1 }) do
            local ok, err = pcall(bzip2.decompress, c:sub(1, n), opts)
            assert(not ok and (err:find("Error in BZ2_bzDecompress: unexpected end of input", 1, true)
                               or (n < 4 and err:find("DATA_ERROR_MAGIC", 1, true))), err)
        end
        assertError("Error in BZ2_bzDecompress: unexpected data after end of stream",
                    bzip2.decompress, c .. "x", opts)
        assertError("Error in BZ2_bzDecompress: unexpected data after end of stream",
                    bzip2.decompress, c .. c, opts)
        assert(bzip2.decompress(c .. "trailing data", with(opts, { allowtrailing = true })) == s)
        assert(bzip2.decompress(c .. c, with(opts, { allowtrailing = true })) == s)
        assert(bzip2.decompress(c, with(opts, { allowtrailing = false })) == s)
        -- a corrupted byte in the middle: the block CRC (or the Huffman data) is wrong
        for _, m in ipairs({ 20, math.floor(#c / 2), #c - 6 }) do
            local bad = c:sub(1, m) .. string.char((c:byte(m + 1) + 77) % 256) .. c:sub(m + 2)
            local ok, err = pcall(bzip2.decompress, bad, opts)
            assert(not ok and err:match("^Error in BZ2_bzDecompress: DATA_ERROR"), tostring(err))
        end
    end
end
PRINT("==================================================================================")
do
    -- concatenated streams (bzip2 -d decompresses all of them, as IO::Uncompress::Bunzip2
    -- with MultiStream): one stream per decompressor, consumed tells where the next starts
    local s1, s2, s3 = text(50000, 1), randomBytes(3000, 2), ""
    local c = bzip2.compress(s1) .. bzip2.compress(s2, { level = 1 }) .. bzip2.compress(s3)
    assert(decompressAll(c) == s1 .. s2 .. s3)
    assert(bzip2.decompress(c, { allowtrailing = true }) == s1)
    -- the decoder reads no byte after the end of a stream
    local c1 = bzip2.compress(s1)
    local _, st, n = bzip2.decompressor():decompress(c1 .. "BZh9")
    assert(st == bzip2.BZ_STREAM_END and n == #c1)
end
PRINT("==================================================================================")
do
    -- maxsize
    local s = text(100000)
    local c = bzip2.compress(s, { level = 1 })
    assert(bzip2.decompress(c, { maxsize = #s }) == s)
    assert(bzip2.decompress(c, { maxsize = #s + 1 }) == s)
    assertError("output exceeds maxsize", bzip2.decompress, c, { maxsize = #s - 1 })
    assertError("output exceeds maxsize", bzip2.decompress, c, { maxsize = 0 })
    assert(streamDecompress(c, 1000, { maxsize = #s }) == s)
    assertError("output exceeds maxsize", streamDecompress, c, 1000, { maxsize = #s - 1 })
    assert(bzip2.decompress(bzip2.compress(""), { maxsize = 0 }) == "")
    -- a compression bomb: 50 MB of zeros
    local bomb = bzip2.compressor({ level = 9 })
    local parts = {}
    local zeros = ("\0"):rep(1024 * 1024)
    for i = 1, 50 do parts[#parts + 1] = bomb:update(zeros) end
    parts[#parts + 1] = bomb:finish()
    bomb = table.concat(parts)
    assert(#bomb < 1000, #bomb)
    assertError("output exceeds maxsize", bzip2.decompress, bomb, { maxsize = 1000000 })
    local out, st = bzip2.decompressor({ maxsize = 1000 }):decompress(bomb)
    assert(out == ("\0"):rep(1000) and st == bzip2.BZ_OUTBUFF_FULL)
end
PRINT("==================================================================================")
do
    -- streaming with all chunk sizes gives the same output as one call
    local s = text(300000, 11) .. randomBytes(30000, 2)
    for _, k in ipairs({ 1, 9 }) do
        local opts = { level = k }
        local c = bzip2.compress(s, opts)
        for _, chunk in ipairs({ 3, 1000, 65536, 400000 }) do
            assert(streamDecompress(c, chunk) == s)
            assert(streamDecompress(c, chunk, { small = true }) == s)
        end
        for _, chunk in ipairs({ 7, 1000, 65536, 400000 }) do
            assert(streamCompress(s, chunk, opts) == c)
        end
    end
    -- 1 byte feeding, also for compression
    local s2 = text(20000, 6)
    local c = bzip2.compress(s2, { level = 1 })
    assert(streamCompress(s2, 1, { level = 1 }) == c)
    assert(streamDecompress(c, 1) == s2)
    assert(streamDecompress(c, 1, { maxsize = #s2, small = true }) == s2)
    -- empty chunks
    local d = bzip2.decompressor()
    assert(d:update("") == nil)
    c = bzip2.compress("abc")
    assert(d:update(c:sub(1, 2)) == nil)
    assert(d:update("") == nil)
    assert(d:update("") == nil)
    assert(d:update(c:sub(3)) == "abc")
    assert(d:update("") == nil)
    assert(d:finish() == "")
    local e = bzip2.compressor()
    assert(e:update("") == nil)
    assert(e:update("abc") == nil)          -- libbz2 collects a whole block
    assert(e:finish() == c)
    -- finish with a chunk
    e = bzip2.compressor({ level = 3 })
    assert(e:finish("abc") == bzip2.compress("abc", { level = 3 }))
    d = bzip2.decompressor()
    assert(d:finish(c) == "abc")
    -- after finish and after errors the streams are closed
    assertError("compressor is closed", e.update, e, "x")
    assertError("compressor is closed", e.finish, e)
    assertError("compressor is closed", e.flush, e)
    assertError("decompressor is closed", d.update, d, "x")
    assertError("decompressor is closed", d.bzinflate, d, "x")
    d = bzip2.decompressor()
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", d.update, d, ("garbage"):rep(2))
    assertError("decompressor is closed", d.update, d, "x")
    d = bzip2.decompressor()
    d:update(c:sub(1, 3))
    assertError("Error in BZ2_bzDecompress: unexpected end of input", d.finish, d)
    assertError("decompressor is closed", d.finish, d)
    -- after the end: trailing data
    d = bzip2.decompressor()
    assert(d:update(c) == "abc")
    assertError("Error in BZ2_bzDecompress: unexpected data after end of stream", d.update, d, "x")
    d = bzip2.decompressor()
    assertError("Error in BZ2_bzDecompress: unexpected data after end of stream", d.update, d, c .. "x")
    d = bzip2.decompressor()
    assert(d:update(c) == "abc")
    assertError("Error in BZ2_bzDecompress: unexpected data after end of stream", d.finish, d, "x")
    d = bzip2.decompressor({ allowtrailing = true })
    assert(d:update(c .. "xyz") == "abc")
    assert(d:update("more") == nil)
    assert(d:finish("more") == "")
    -- a stream over several blocks (block size 100 kB), in pieces
    local big = text(450000, 8)
    c = bzip2.compress(big, { level = 1 })
    assert(streamDecompress(c, 4096) == big)
end
PRINT("==================================================================================")
do
    -- flush: BZ_FLUSH ends the block ("block", the default); the block's last bits are held
    -- back, so the output so far is not decodable up to the last byte given
    local s = text(100000, 21)
    for _, mode in ipairs({ "block", bzip2.BZ_FLUSH, false }) do
        local c = bzip2.compressor({ level = 1 })
        local d = bzip2.decompressor()
        local cparts, dparts = {}, {}
        for i = 1, #s, 7777 do
            local piece = s:sub(i, i + 7776)
            local r1 = c:update(piece)
            local r2
            if mode then r2 = c:flush(nil, mode) else r2 = c:flush() end
            assert(r1 == nil and r2)
            cparts[#cparts + 1] = r2
            dparts[#dparts + 1] = d:update(r2)
            -- decoded so far: the data up to the previous flush at least
            local sofar = table.concat(dparts)
            assert(s:sub(1, #sofar) == sofar and #sofar >= i - 7777, i)
            -- a second flush without data gives nothing
            assert(c:flush(nil, mode or nil) == nil)
        end
        cparts[#cparts + 1] = c:finish()
        local all = table.concat(cparts)
        assert(bzip2.decompress(all) == s)
        -- each flush ends a block: worse than without flushes
        assert(#all > #bzip2.compress(s, { level = 1 }))
    end
    -- a flush at the start gives the stream header, but for its last byte (libbz2 writes
    -- the bytes of its bit buffer when the next bits come)
    local c = bzip2.compressor({ level = 4 })
    assert(c:flush() == "BZh")
    assert(c:flush() == nil)
    assert("BZh" .. c:finish("abc") == bzip2.compress("abc", { level = 4 }))
    -- flush with a chunk: the same as update(chunk), then flush()
    local a, b = bzip2.compressor(), bzip2.compressor()
    local fa = a:flush("abc")
    local fb = (b:update("abc") or "") .. b:flush()
    assert(fa == fb)
    assert(a:finish() == b:finish())
    -- BZ_RUN, "finish" and BZ_FINISH
    c = bzip2.compressor()
    local parts = {}
    for i = 1, #s, 10000 do
        parts[#parts + 1] = c:flush(s:sub(i, i + 9999), bzip2.BZ_RUN)
    end
    parts[#parts + 1] = c:flush(nil, "finish")
    assert(table.concat(parts) == bzip2.compress(s))
    assertError("compressor is closed", c.update, c, "x")
    c = bzip2.compressor()
    assert(c:flush(s, bzip2.BZ_FINISH) == bzip2.compress(s))
    -- sync and full flushes are not possible: an error, the stream stays usable
    c = bzip2.compressor()
    assert(c:update("abc") == nil)
    assertError("flush mode 'sync' is not supported for format 'bzip2'", c.flush, c, nil, "sync")
    assertError("flush mode 'full' is not supported for format 'bzip2'", c.flush, c, "x", "full")
    assert(c:finish("def") == bzip2.compress("abcdef"))
    c = bzip2.compressor()
    assertError("invalid flush mode", c.flush, c, "x", "none")
    assertError("invalid flush mode", c.flush, c, "x", 3)
    assertError("invalid flush mode", c.flush, c, "x", -1)
    assertError("invalid flush mode", c.flush, c, "x", 1.5)
    assertError("invalid flush mode", c.flush, c, "x", true)
    assertError("bad argument #3", c.flush, c, "x", "Block")
end
PRINT("==================================================================================")
do
    -- the status method decompress(): output, status, consumed; raises no data errors
    local s = text(100000, 31)
    local c = bzip2.compress(s, { level = 1 })
    local d = bzip2.decompressor()
    -- bzinflate() is the same method, under the name of Compress::Raw::Bunzip2
    assert(d.bzinflate == d.decompress and type(d.bzinflate) == "function")
    local out, st, n = d:decompress(c)
    assert(out == s and st == bzip2.BZ_STREAM_END and n == #c)
    -- after the end: BZ_STREAM_END again, nothing consumed
    out, st, n = d:decompress("more")
    assert(out == "" and st == bzip2.BZ_STREAM_END and n == 0)
    assert(d:msg() == nil)

    -- in pieces: BZ_OK while more input is expected
    d = bzip2.decompressor()
    local parts = {}
    for i = 1, #c, 1000 do
        out, st, n = d:bzinflate(c:sub(i, i + 999))
        assert(type(out) == "string")
        parts[#parts + 1] = out
        if i + 999 < #c then
            assert(st == bzip2.BZ_OK and n == 1000)
        else
            assert(st == bzip2.BZ_STREAM_END and n == #c - i + 1)
        end
    end
    assert(table.concat(parts) == s)
    -- 1 byte pieces
    local c2 = bzip2.compress(s:sub(1, 20000))
    for _, opts in ipairs({ {}, { small = true } }) do
        d = bzip2.decompressor(opts)
        parts = {}
        for i = 1, #c2 do
            out, st, n = d:bzinflate(c2:sub(i, i))
            assert(n == 1)
            parts[#parts + 1] = out
            assert(st == (i < #c2 and bzip2.BZ_OK or bzip2.BZ_STREAM_END))
        end
        assert(table.concat(parts) == s:sub(1, 20000))
    end
    -- empty input: BZ_OK, also repeated
    d = bzip2.decompressor()
    for _ = 1, 3 do
        out, st, n = d:bzinflate("")
        assert(out == "" and st == bzip2.BZ_OK and n == 0)
    end

    -- trailing data: consumed tells where the stream ends
    d = bzip2.decompressor()
    out, st, n = d:decompress(c .. "TRAILING")
    assert(out == s and st == bzip2.BZ_STREAM_END and n == #c)
    -- a truncated stream: BZ_OK, it may go on
    d = bzip2.decompressor()
    out, st, n = d:decompress(c:sub(1, -2))
    assert(#out <= #s and s:sub(1, #out) == out and st == bzip2.BZ_OK and n == #c - 1)
    out, st, n = d:decompress(c:sub(-1) .. "XY")
    assert(st == bzip2.BZ_STREAM_END and n == 1)
    -- and finish after a truncated stream raises
    d = bzip2.decompressor()
    d:decompress(c:sub(1, 100))
    assertError("Error in BZ2_bzDecompress: unexpected end of input", d.finish, d)

    -- corrupt data: the status and the output so far, msg() gives the message
    d = bzip2.decompressor()
    out, st, n = d:bzinflate(("garbage"):rep(2))
    assert(out == "" and st == bzip2.BZ_DATA_ERROR_MAGIC and n <= 14)
    assert(d:msg() == "DATA_ERROR_MAGIC")
    out, st, n = d:bzinflate("more")
    assert(out == "" and st == bzip2.BZ_DATA_ERROR_MAGIC and n == 0)
    assertError("Error in BZ2_bzDecompress: DATA_ERROR_MAGIC", d.update, d, "x")
    assertError("decompressor is closed", d.bzinflate, d, "x")
    assert(d:msg() == "DATA_ERROR_MAGIC")
    -- the output before the error is returned: two blocks, the second one corrupt
    local two = text(150000, 5)
    local e = bzip2.compressor({ level = 1 })
    local p1 = e:update(two:sub(1, 90000)) or ""
    p1 = p1 .. e:flush()
    local p2 = (e:update(two:sub(90001)) or "") .. e:finish()
    local cc = p1 .. p2
    local m = #p1 + math.floor(#p2 / 2)
    local bad = cc:sub(1, m) .. string.char((cc:byte(m + 1) + 1) % 256) .. cc:sub(m + 2)
    d = bzip2.decompressor()
    out, st = d:decompress(bad)
    assert(st == bzip2.BZ_DATA_ERROR and d:msg() == "DATA_ERROR")
    assert(#out >= 90000 and out:sub(1, 90000) == two:sub(1, 90000))
    -- a wrong combined CRC at the end: BZ_DATA_ERROR after all of the data (the last byte
    -- has the padding bits)
    local cx = bzip2.compress("abc")
    d = bzip2.decompressor()
    out, st = d:decompress(cx:sub(1, -3) .. string.char((cx:byte(-2) + 1) % 256) .. cx:sub(-1))
    assert(out == "abc" and st == bzip2.BZ_DATA_ERROR, st)

    -- maxsize: BZ_OUTBUFF_FULL, no more than maxsize bytes of output
    d = bzip2.decompressor({ maxsize = 1000 })
    out, st = d:decompress(c)
    assert(out == s:sub(1, 1000) and st == bzip2.BZ_OUTBUFF_FULL and d:msg() == "output exceeds maxsize")
    out, st, n = d:decompress("x")
    assert(out == "" and st == bzip2.BZ_OUTBUFF_FULL and n == 0)
    assertError("output exceeds maxsize", d.update, d, "x")
    d = bzip2.decompressor({ maxsize = #s })
    out, st = d:decompress(c)
    assert(out == s and st == bzip2.BZ_STREAM_END)

    -- decompress and update on the same stream
    d = bzip2.decompressor()
    local o1 = d:decompress(c:sub(1, 5000))
    local o2 = d:update(c:sub(5001, 10000)) or ""
    local o3 = d:decompress(c:sub(10001))
    assert(o1 .. o2 .. o3 == s)
    assert(d:finish() == "")
end
PRINT("==================================================================================")
do
    -- 10 MB
    local s = text(10 * 1024 * 1024, 5)
    local c = bzip2.compress(s, { level = 9 })
    assert(#c < #s / 2)
    assert(bzip2.decompress(c) == s)
    assert(streamDecompress(c, 1024 * 1024) == s)
    assert(streamCompress(s, 1024 * 1024 + 17) == c)
    assertError("output exceeds maxsize", bzip2.decompress, c, { maxsize = #s - 1 })
    local d = bzip2.decompressor({ small = true })
    local out, st, n = d:decompress(c)
    assert(out == s and st == bzip2.BZ_STREAM_END and n == #c)
    local r = randomBytes(1024 * 1024, 13)
    assert(bzip2.decompress(bzip2.compress(r, { level = 1 })) == r)
end
PRINT("==================================================================================")
print("OK.")
