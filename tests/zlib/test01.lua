-- compress.zlib with string data: one-shot functions, formats, parameters, errors,
-- streaming, flush modes, dictionaries, the status method decompressor:decompress() (alias
-- inflate()), checksums.

local zlib = require("compress.zlib")

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
                "elit", "sed", "do", "eiusmod", "tempor", "\0", "\n", "zlib", "Lua" }

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

local FORMATS = { "zlib", "gzip", "raw" }

-- streaming helpers: feed data in chunks of the given size
local function streamDecompress(data, chunk, opts)
    local d = zlib.decompressor(opts)
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
    local c = zlib.compressor(opts)
    local out = {}
    for i = 1, #data, chunk do
        local r = c:update(data:sub(i, i + chunk - 1))
        assert(r == nil or (type(r) == "string" and #r > 0))
        out[#out + 1] = r
    end
    out[#out + 1] = c:finish()
    return table.concat(out)
end

local function hex(s)
    return (s:gsub(".", function(c) return format("%02x", c:byte()) end))
end

PRINT("==================================================================================")
do
    PRINT(format("compress.zlib %s, zlib %s (compiled with %s)", zlib._VERSION, zlib.version()))
    local rv, cv = zlib.version()
    assert(rv:match("^%d+%.%d+") and cv:match("^%d+%.%d+"))
    assert(getmetatable(zlib) == "compress.zlib")
    assert(getmetatable(zlib.decompressor()) == "compress.zlib.decompressor")
    assert(getmetatable(zlib.compressor()) == "compress.zlib.compressor")
    assert(tostring(zlib.decompressor()):match("^compress%.zlib%.decompressor: "))
    assert(tostring(zlib.compressor()):match("^compress%.zlib%.compressor: "))
end
PRINT("==================================================================================")
do
    -- the constants have zlib's values
    local K = {
        Z_OK = 0, Z_STREAM_END = 1, Z_NEED_DICT = 2, Z_ERRNO = -1, Z_STREAM_ERROR = -2,
        Z_DATA_ERROR = -3, Z_MEM_ERROR = -4, Z_BUF_ERROR = -5, Z_VERSION_ERROR = -6,
        Z_NO_FLUSH = 0, Z_PARTIAL_FLUSH = 1, Z_SYNC_FLUSH = 2, Z_FULL_FLUSH = 3, Z_FINISH = 4,
        Z_BLOCK = 5, Z_NO_COMPRESSION = 0, Z_BEST_SPEED = 1, Z_BEST_COMPRESSION = 9,
        Z_DEFAULT_COMPRESSION = -1, Z_FILTERED = 1, Z_HUFFMAN_ONLY = 2, Z_RLE = 3, Z_FIXED = 4,
        Z_DEFAULT_STRATEGY = 0, Z_DEFLATED = 8, MAX_WBITS = 15, MAX_MEM_LEVEL = 9,
        DEF_MEM_LEVEL = 8,
    }
    for name, value in pairs(K) do
        assert(zlib[name] == value, name)
        assert(math.type == nil or math.type(zlib[name]) == "integer", name)
    end
end
PRINT("==================================================================================")
do
    -- roundtrips of various data in all formats
    local all = {}
    for i = 0, 255 do all[#all + 1] = string.char(i) end
    all = table.concat(all)
    local samples = {
        "", "a", "\0", ("\0"):rep(1000), "a\0b\0\0c", all, all:rep(100), text(1000),
        text(100000), randomBytes(1000), randomBytes(100000, 3),
        text(50000) .. randomBytes(50000) .. text(50000, 9),
    }
    for _, s in ipairs(samples) do
        for _, f in ipairs(FORMATS) do
            local c = zlib.compress(s, { format = f })
            assert(type(c) == "string")
            assert(zlib.decompress(c, { format = f }) == s)
            if f ~= "raw" then
                assert(zlib.decompress(c, { format = "auto" }) == s)
            end
        end
        assert(zlib.decompress(zlib.compress(s)) == s)    -- default: zlib
    end
    -- numbers are converted to strings as in the string library
    assert(zlib.decompress(zlib.compress(12345)) == "12345")
end
PRINT("==================================================================================")
do
    -- format headers and trailers
    local s = text(10000)
    local cz = zlib.compress(s)
    local cg = zlib.compress(s, { format = "gzip" })
    local cr = zlib.compress(s, { format = "raw" })
    -- zlib: CMF 0x78 (deflate, 32K window), FLEVEL 2 (default), header check, adler32
    assert(cz:sub(1, 2) == "\120\156")
    assert(cz:sub(3, -5) == cr)
    local a = zlib.adler32(s)
    assert(cz:sub(-4) == string.char(math.floor(a / 16777216) % 256, math.floor(a / 65536) % 256,
                                     math.floor(a / 256) % 256, a % 256))
    -- gzip: zlib's minimal header (mtime 0, no name), the same deflate data, crc32, isize
    assert(cg:sub(1, 8) == "\31\139\8\0\0\0\0\0")
    assert(cg:sub(9, 9) == "\0")                 -- XFL for the default level
    assert(cg:sub(11, -9) == cr)
    local crc = zlib.crc32(s)
    assert(cg:sub(-8, -5) == string.char(crc % 256, math.floor(crc / 256) % 256,
                                         math.floor(crc / 65536) % 256, math.floor(crc / 16777216) % 256))
    assert(cg:sub(-4) == string.char(#s % 256, math.floor(#s / 256) % 256, 0, 0))
    assert(zlib.compress(s, { format = "gzip", level = 9 }):sub(9, 9) == "\2")
    assert(zlib.compress(s, { format = "gzip", level = 1 }):sub(9, 9) == "\4")
    -- the shortest streams
    assert(zlib.compress("", { format = "raw" }) == "\3\0")
    assert(zlib.compress("") == "\120\156\3\0\0\0\0\1")
    assert(hex(zlib.compress("", { format = "gzip" })):match("^1f8b08000000000000..03000000000000000000$"))

    -- formats do not decode each other
    assertError("Error in inflate: incorrect header check", zlib.decompress, cg)
    assertError("Error in inflate: incorrect header check", zlib.decompress, cz, { format = "gzip" })
    assertError("Error in inflate: ", zlib.decompress, cr)
    assertError("Error in inflate: ", zlib.decompress, cz, { format = "raw" })
    assertError("Error in inflate: incorrect header check", zlib.decompress, cr, { format = "auto" })
end
PRINT("==================================================================================")
do
    -- windowBits selects the format as in zlib: negative raw, 16 + n gzip, 32 + n auto
    local s = text(50000, 3)
    assert(zlib.compress(s, { windowBits = -15 }) == zlib.compress(s, { format = "raw" }))
    assert(zlib.compress(s, { windowBits = 31 }) == zlib.compress(s, { format = "gzip" }))
    assert(zlib.compress(s, { windowBits = 15 }) == zlib.compress(s))
    assert(zlib.compress(s, { windowBits = 12, format = "gzip" }) == zlib.compress(s, { windowBits = 28 }))
    assert(zlib.compress(s, { windowBits = -12, format = "raw" }) == zlib.compress(s, { windowBits = -12 }))
    assert(zlib.decompress(zlib.compress(s, { format = "raw" }), { windowBits = -15 }) == s)
    assert(zlib.decompress(zlib.compress(s, { format = "gzip" }), { windowBits = 31 }) == s)
    assert(zlib.decompress(zlib.compress(s, { format = "gzip" }), { windowBits = 47 }) == s)
    assert(zlib.decompress(zlib.compress(s), { windowBits = 47 }) == s)
    -- 0: the window size from the zlib header
    assert(zlib.decompress(zlib.compress(s, { windowBits = 10 }), { windowBits = 0 }) == s)
    assert(zlib.decompress(zlib.compress(s, { windowBits = 10 }), { windowBits = 32 }) == s)
    -- smaller windows decode with larger ones, not vice versa
    for w = 9, 15 do
        for _, f in ipairs(FORMATS) do
            local c = zlib.compress(s, { format = f, windowBits = (f == "raw") and -w or w })
            assert(zlib.decompress(c, { format = f }) == s)
            assert(zlib.decompress(c, { format = f, windowBits = (f == "raw") and -w or w }) == s)
        end
    end
    -- zlib makes 8 a 9 for the zlib format, rejects it for raw and gzip
    assert(zlib.compress(s, { windowBits = 8 }) == zlib.compress(s, { windowBits = 9 }))
    assertError("invalid windowBits value", zlib.compress, s, { windowBits = -8 })
    assertError("invalid windowBits value", zlib.compress, s, { windowBits = 24 })
    assertError("Error in inflate: invalid window size",
                zlib.decompress, zlib.compress(s), { windowBits = 9 })
    -- contradictions and invalid values
    assertError("windowBits contradicts format", zlib.compress, s, { windowBits = -15, format = "zlib" })
    assertError("windowBits contradicts format", zlib.compress, s, { windowBits = 31, format = "raw" })
    assertError("windowBits contradicts format", zlib.decompress, s, { windowBits = 47, format = "gzip" })
    for _, w in ipairs({ 7, 0, -7, -16, 16, 23, 32, 47, 1.5, "15" }) do
        assertError("invalid windowBits value", zlib.compress, s, { windowBits = w })
    end
    for _, w in ipairs({ 7, -7, -16, 16 + 7, 32 + 7, 48, -0.5 }) do
        assertError("invalid windowBits value", zlib.decompress, s, { windowBits = w })
    end
    assertError("invalid format value", zlib.compress, s, { format = "auto" })
    assertError("invalid format value", zlib.compress, s, { format = "deflate" })
    assertError("invalid format value", zlib.decompress, s, { format = 1 })
end
PRINT("==================================================================================")
do
    -- level, memLevel, strategy, method
    local s = text(200000) .. randomBytes(20000) .. text(100000, 5)
    local sizes = {}
    for level = -1, 9 do
        local c = zlib.compress(s, { level = level })
        assert(zlib.decompress(c) == s)
        sizes[level] = #c
    end
    assert(sizes[-1] == sizes[6])
    assert(sizes[0] > #s and sizes[1] < #s and sizes[9] <= sizes[1])
    assert(zlib.compress(s, { level = -1 }) == zlib.compress(s, { level = 6 }))
    assert(zlib.compress(s) == zlib.compress(s, { level = 6, memLevel = 8, windowBits = 15,
                                                  strategy = zlib.Z_DEFAULT_STRATEGY,
                                                  method = zlib.Z_DEFLATED }))
    -- level 0 stores the data: blocks of at most 65535 bytes
    local stored = zlib.compress(s, { level = 0, format = "raw" })
    local nblocks = math.floor((#s + 65534) / 65535)
    assert(#stored == #s + 5 * nblocks)
    for memLevel = 1, 9 do
        local c = zlib.compress(s, { memLevel = memLevel })
        assert(zlib.decompress(c) == s)
    end
    -- memLevel matters for data of more than about 16K symbols (8: the default)
    assert(zlib.compress(s, { memLevel = 9 }) ~= zlib.compress(s))
    assert(zlib.compress(s, { memLevel = 8 }) == zlib.compress(s))
    for _, st in ipairs({ zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED, zlib.Z_HUFFMAN_ONLY,
                          zlib.Z_RLE, zlib.Z_FIXED }) do
        local c = zlib.compress(s, { strategy = st })
        assert(zlib.decompress(c) == s)
    end
    local default = zlib.compress(s)
    assert(zlib.compress(s, { strategy = zlib.Z_HUFFMAN_ONLY }) ~= default)
    assert(zlib.compress(s, { strategy = zlib.Z_FIXED }) ~= default)
    -- runs of the same byte: Z_RLE finds them, Z_HUFFMAN_ONLY not
    local runs = ("a"):rep(1000) .. ("b"):rep(1000)
    assert(#zlib.compress(runs, { strategy = zlib.Z_RLE }) < #zlib.compress(runs, { strategy = zlib.Z_HUFFMAN_ONLY }))
    for _, v in ipairs({ -2, 10, 0.5, "6", true }) do
        assertError("invalid level value", zlib.compress, s, { level = v })
    end
    for _, v in ipairs({ 0, 10, 8.5 }) do
        assertError("invalid memLevel value", zlib.compress, s, { memLevel = v })
    end
    for _, v in ipairs({ -1, 5, "rle" }) do
        assertError("invalid strategy value", zlib.compress, s, { strategy = v })
    end
    for _, v in ipairs({ 0, 7, 9 }) do
        assertError("invalid method value", zlib.compress, s, { method = v })
    end
end
PRINT("==================================================================================")
do
    -- option errors
    assertError("option 'maxsize' is not supported by compress()", zlib.compress, "x", { maxsize = 10 })
    assertError("option 'level' is not supported by decompress()", zlib.decompress, "x", { level = 1 })
    assertError("option 'memLevel' is not supported by decompressor()", zlib.decompressor, { memLevel = 1 })
    assertError("option 'gzipHeader' is not supported by decompressor()", zlib.decompressor,
                { gzipHeader = {} })
    assertError("option 'allowtrailing' is not supported by compressor()", zlib.compressor,
                { allowtrailing = true })
    assertError("unknown option 'windowbits'", zlib.compress, "x", { windowbits = 15 })
    assertError("unknown option 'quality'", zlib.compressor, { quality = 1 })
    -- the former option out: the carray is the last argument
    for _, f in ipairs({ zlib.compress, zlib.decompress }) do
        assertError("option 'out' is no longer supported: pass the carray as the last argument",
                    f, "x", { out = 1 })
    end
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                zlib.compressor, { out = 1 })
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                zlib.decompressor, { out = 1 })
    assertError("option names must be strings", zlib.compress, "x", { 1 })
    -- the second argument of compress/decompress: options table or output carray
    assertError("table or carray expected, got string", zlib.compress, "x", "level")
    assertError("table or carray expected, got boolean", zlib.decompress, "x", false)
    assertError("table expected, got string", zlib.compressor, "level")
    assertError("out: carray expected, got string", zlib.compress, "x", {}, "y")
    assertError("bad argument #3", zlib.compress, "x", nil, 1)
    assertError("out: carray expected, got userdata", zlib.decompress, "x", io.stdout)
    assert(zlib.decompress(zlib.compress("x", nil, nil), nil, nil) == "x")
    assertError("bad argument #2", zlib.compress, "x", { level = 99 })
    assertError("bad argument #1", zlib.compressor, { level = 99 })
    assertError("invalid maxsize value", zlib.decompress, "x", { maxsize = -1 })
    assertError("invalid allowtrailing value", zlib.decompress, "x", { allowtrailing = 1 })
    assertError("string or carray expected, got table", zlib.compress, {})
    assertError("string or carray expected, got no value", zlib.decompress)
    assertError("string or carray expected, got boolean", zlib.compressor().update, zlib.compressor(), true)
    assertError("dictionary: string or carray expected, got table", zlib.compress, "x", { dictionary = {} })
end
PRINT("==================================================================================")
do
    -- empty, corrupt, truncated data and data after the end
    for _, f in ipairs(FORMATS) do
        assertError("Error in inflate: unexpected end of input", zlib.decompress, "", { format = f })
        assert(zlib.decompress(zlib.compress("", { format = f }), { format = f }) == "")
    end
    assertError("Error in inflate: incorrect header check", zlib.decompress, "garbage")
    assertError("Error in inflate: invalid block type", zlib.decompress, "\255\255", { format = "raw" })
    assertError("Error in inflate: incorrect header check", zlib.decompress, "garbage", { format = "auto" })
    assertError("Error in inflate: incorrect header check", zlib.decompress, "garbage", { format = "gzip" })

    local s = text(100000)
    for _, f in ipairs(FORMATS) do
        local c = zlib.compress(s, { format = f })
        for _, n in ipairs({ 1, 2, 10, math.floor(#c / 2), #c - 1 }) do
            assertError("Error in inflate: unexpected end of input", zlib.decompress, c:sub(1, n),
                        { format = f })
        end
        assertError("Error in inflate: unexpected data after end of stream",
                    zlib.decompress, c .. "x", { format = f })
        assertError("Error in inflate: unexpected data after end of stream",
                    zlib.decompress, c .. c, { format = f })
        assert(zlib.decompress(c .. "trailing data", { format = f, allowtrailing = true }) == s)
        assert(zlib.decompress(c, { format = f, allowtrailing = false }) == s)
        -- a corrupted byte in the middle
        local m = math.floor(#c / 2)
        local bad = c:sub(1, m) .. string.char((c:byte(m + 1) + 77) % 256) .. c:sub(m + 2)
        local ok, err = pcall(zlib.decompress, bad, { format = f })
        -- raw deflate has no checksum: the data may decode, but differently
        assert((not ok and err:match("^Error in inflate: ")) or (ok and f == "raw" and err ~= s))
    end
    -- checksum errors
    local cz = zlib.compress(s)
    assertError("Error in inflate: incorrect data check", zlib.decompress,
                cz:sub(1, -2) .. string.char((cz:byte(-1) + 1) % 256))
    local cg = zlib.compress(s, { format = "gzip" })
    assertError("Error in inflate: incorrect data check", zlib.decompress,
                cg:sub(1, -6) .. string.char((cg:byte(-5) + 1) % 256) .. cg:sub(-4), { format = "gzip" })
    assertError("Error in inflate: incorrect length check", zlib.decompress,
                cg:sub(1, -2) .. "\1", { format = "gzip" })
end
PRINT("==================================================================================")
do
    -- maxsize
    local s = text(100000)
    for _, f in ipairs(FORMATS) do
        local c = zlib.compress(s, { format = f })
        assert(zlib.decompress(c, { format = f, maxsize = #s }) == s)
        assert(zlib.decompress(c, { format = f, maxsize = #s + 1 }) == s)
        assertError("output exceeds maxsize", zlib.decompress, c, { format = f, maxsize = #s - 1 })
        assertError("output exceeds maxsize", zlib.decompress, c, { format = f, maxsize = 0 })
        assert(streamDecompress(c, 1000, { format = f, maxsize = #s }) == s)
        assertError("output exceeds maxsize", streamDecompress, c, 1000, { format = f, maxsize = #s - 1 })
    end
    assert(zlib.decompress(zlib.compress(""), { maxsize = 0 }) == "")
    -- a compression bomb: 50 MB of zeros
    local bomb = zlib.compressor({ level = 9 })
    local parts = {}
    local zeros = ("\0"):rep(1024 * 1024)
    for i = 1, 50 do parts[#parts + 1] = bomb:update(zeros) end
    parts[#parts + 1] = bomb:finish()
    bomb = table.concat(parts)
    assert(#bomb < 60000)
    assertError("output exceeds maxsize", zlib.decompress, bomb, { maxsize = 1000000 })
end
PRINT("==================================================================================")
do
    -- dictionaries
    local dict = text(2000, 99)
    local s = text(1000, 99):sub(1, 900) .. text(500, 4)
    for _, f in ipairs({ "zlib", "raw" }) do
        local plain = zlib.compress(s, { format = f })
        local c = zlib.compress(s, { format = f, dictionary = dict })
        assert(#c < #plain)
        assert(zlib.decompress(c, { format = f, dictionary = dict }) == s)
        assert(streamDecompress(c, 7, { format = f, dictionary = dict }) == s)
        assert(streamCompress(s, 100, { format = f, dictionary = dict }) == c)
        -- a dictionary that the data does not need is not used for the zlib format
        assert(zlib.decompress(plain, { format = f, dictionary = dict }) == (f == "zlib" and s or
               zlib.decompress(plain, { format = f, dictionary = dict })))
    end
    local c = zlib.compress(s, { dictionary = dict })
    -- zlib format: the header says that a dictionary is needed (FDICT) and its adler32
    assert(c:byte(2) % 64 >= 32)
    assertError("Error in inflate: need dictionary", zlib.decompress, c)
    assertError("Error in inflateSetDictionary: incorrect dictionary", zlib.decompress, c,
                { dictionary = "wrong" })
    assert(zlib.decompress(c, { format = "auto", dictionary = dict }) == s)
    assert(zlib.decompress(c, { windowBits = 0, dictionary = dict }) == s)
    -- raw: no check, a wrong dictionary gives wrong data or an error
    local cr = zlib.compress(s, { format = "raw", dictionary = dict })
    local ok, r = pcall(zlib.decompress, cr, { format = "raw" })
    assert(not ok or r ~= s)
    -- gzip has no dictionaries
    assertError("dictionary is not supported for format 'gzip'", zlib.compress, s,
                { format = "gzip", dictionary = dict })
    assertError("dictionary is not supported for format 'gzip'", zlib.decompressor,
                { windowBits = 31, dictionary = dict })
    -- the empty dictionary
    local ce = zlib.compress(s, { dictionary = "" })
    assert(zlib.decompress(ce, { dictionary = "" }) == s)
    -- only the last 32K of a dictionary are used
    local big = randomBytes(40000, 8) .. dict
    assert(zlib.decompress(zlib.compress(s, { dictionary = big }), { dictionary = big }) == s)
end
PRINT("==================================================================================")
do
    -- streaming with all chunk sizes gives the same output as one call
    local s = text(300000, 11) .. randomBytes(30000, 2)
    for _, f in ipairs(FORMATS) do
        local c = zlib.compress(s, { format = f })
        for _, chunk in ipairs({ 1, 3, 1000, 65536, 400000 }) do
            assert(streamDecompress(c, chunk, { format = f }) == s)
        end
        for _, chunk in ipairs({ 7, 1000, 65536, 400000 }) do
            assert(streamCompress(s, chunk, { format = f }) == c)
        end
        -- level 9, memLevel 9
        local opts = { format = f, level = 9, memLevel = 9 }
        local c9 = zlib.compress(s, opts)
        assert(streamCompress(s, 4096, opts) == c9)
    end
    -- 1 byte feeding, also for compression
    local s2 = text(20000, 6)
    for _, f in ipairs(FORMATS) do
        local c = zlib.compress(s2, { format = f })
        assert(streamCompress(s2, 1, { format = f }) == c)
        assert(streamDecompress(c, 1, { format = f }) == s2)
        assert(streamDecompress(c, 1, { format = f, maxsize = #s2 }) == s2)
    end
    assert(streamDecompress(zlib.compress(s2, { format = "gzip" }), 1, { format = "auto" }) == s2)
    -- empty chunks
    local d = zlib.decompressor()
    assert(d:update("") == nil)
    local c = zlib.compress("abc")
    assert(d:update(c:sub(1, 2)) == nil)
    assert(d:update("") == nil)
    assert(d:update(c:sub(3)) == "abc")
    assert(d:update("") == nil)
    assert(d:finish() == "")
    -- the first call gives the header (zlib and gzip), as zlib's deflate() does
    local e = zlib.compressor()
    assert(e:update("") == "\120\156")
    assert(e:update("abc") == nil)
    assert("\120\156" .. e:finish() == c)
    e = zlib.compressor({ format = "raw" })
    assert(e:update("") == nil)
    -- finish with a chunk
    e = zlib.compressor({ format = "raw" })
    assert(e:finish("abc") == zlib.compress("abc", { format = "raw" }))
    d = zlib.decompressor({ format = "raw" })
    assert(d:finish(zlib.compress("abc", { format = "raw" })) == "abc")
    -- after finish and after errors the streams are closed
    assertError("compressor is closed", e.update, e, "x")
    assertError("compressor is closed", e.finish, e)
    assertError("decompressor is closed", d.update, d, "x")
    assertError("decompressor is closed", d.inflate, d, "x")
    d = zlib.decompressor()
    assertError("Error in inflate: incorrect header check", d.update, d, "garbage")
    assertError("decompressor is closed", d.update, d, "x")
    d = zlib.decompressor()
    d:update(c:sub(1, 3))
    assertError("Error in inflate: unexpected end of input", d.finish, d)
    assertError("decompressor is closed", d.finish, d)
    -- after the end: trailing data
    d = zlib.decompressor()
    assert(d:update(c) == "abc")
    assertError("Error in inflate: unexpected data after end of stream", d.update, d, "x")
    d = zlib.decompressor()
    assertError("Error in inflate: unexpected data after end of stream", d.update, d, c .. "x")
    d = zlib.decompressor()
    assert(d:update(c) == "abc")
    assertError("Error in inflate: unexpected data after end of stream", d.finish, d, "x")
    d = zlib.decompressor({ allowtrailing = true })
    assert(d:update(c .. "xyz") == "abc")
    assert(d:update("more") == nil)
    assert(d:finish("more") == "")
    -- decompressor output equals the decompressed data
    d = zlib.decompressor({ format = "gzip" })
    local parts = {}
    local cg = zlib.compress(s, { format = "gzip" })
    for i = 1, #cg, 5000 do parts[#parts + 1] = d:update(cg:sub(i, i + 4999)) end
    parts[#parts + 1] = d:finish()
    assert(table.concat(parts) == s)
end
PRINT("==================================================================================")
do
    -- flush modes
    local s = text(100000, 21)
    for _, f in ipairs(FORMATS) do
        for _, mode in ipairs({ "sync", "full", zlib.Z_SYNC_FLUSH, zlib.Z_FULL_FLUSH }) do
            local c = zlib.compressor({ format = f })
            local d = zlib.decompressor({ format = f })
            local cparts, dparts = {}, {}
            for i = 1, #s, 7777 do
                local piece = s:sub(i, i + 7776)
                local r1 = c:update(piece)
                local r2 = c:flush(nil, mode)
                assert(r2 and r2:sub(-4) == "\0\0\255\255")   -- an empty stored block
                cparts[#cparts + 1] = r1
                cparts[#cparts + 1] = r2
                -- everything given so far can be decompressed now
                dparts[#dparts + 1] = d:update((r1 or "") .. r2)
                assert(table.concat(dparts) == s:sub(1, i + 7776))
            end
            -- a second flush without data gives nothing
            assert(c:flush(nil, mode) == nil)
            cparts[#cparts + 1] = c:finish()
            local all = table.concat(cparts)
            assert(zlib.decompress(all, { format = f }) == s)
        end
    end
    -- full flush: decompression can start again after a flush point (raw deflate)
    local c = zlib.compressor({ format = "raw" })
    local p1 = (c:update(s:sub(1, 50000)) or "") .. c:flush(nil, "full")
    local p2 = (c:update(s:sub(50001)) or "") .. c:finish()
    assert(zlib.decompress(p2, { format = "raw" }) == s:sub(50001))
    assert(zlib.decompress(p1 .. p2, { format = "raw" }) == s)
    -- after a sync flush the second part depends on the first one
    c = zlib.compressor({ format = "raw" })
    p1 = (c:update(s:sub(1, 50000)) or "") .. c:flush(nil, "sync")
    p2 = (c:update(s:sub(50001)) or "") .. c:finish()
    assert(not pcall(zlib.decompress, p2, { format = "raw" })
           or zlib.decompress(p2, { format = "raw" }) ~= s:sub(50001))
    -- flush with a chunk, block and partial flush, Z_NO_FLUSH and Z_FINISH
    for _, mode in ipairs({ "block", "partial", zlib.Z_BLOCK, zlib.Z_PARTIAL_FLUSH, zlib.Z_NO_FLUSH }) do
        c = zlib.compressor()
        local parts = {}
        for i = 1, #s, 10000 do
            parts[#parts + 1] = c:flush(s:sub(i, i + 9999), mode)
        end
        parts[#parts + 1] = c:finish()
        assert(zlib.decompress(table.concat(parts)) == s)
    end
    c = zlib.compressor()
    local h = c:flush(s:sub(1, 1000), zlib.Z_NO_FLUSH)    -- like update: only the header yet
    assert(h == "\120\156")
    assert(c:update("") == nil)
    local fin = h .. c:flush(nil, zlib.Z_FINISH)
    assert(zlib.decompress(fin) == s:sub(1, 1000))
    assertError("compressor is closed", c.update, c, "x")
    c = zlib.compressor()
    assert(zlib.decompress(c:flush(s, "finish")) == s)
    -- Z_NO_FLUSH gives the same output as update
    assert(streamCompress(s, 999) == zlib.compress(s))
    c = zlib.compressor()
    assertError("invalid flush mode", c.flush, c, "x", "none")
    assertError("invalid flush mode", c.flush, c, "x", 6)
    assertError("invalid flush mode", c.flush, c, "x", -1)
    assertError("invalid flush mode", c.flush, c, "x", true)
    assertError("bad argument #3", c.flush, c, "x", "Sync")
    -- the default flush mode is sync
    local a, b = zlib.compressor(), zlib.compressor()
    assert(a:flush("abc") == b:flush("abc", "sync"))
    assert(a:finish() == b:finish())
end
PRINT("==================================================================================")
do
    -- the status method decompress(): output, status, consumed; raises no data errors
    local s = text(100000, 31)
    local c = zlib.compress(s)
    local d = zlib.decompressor()
    -- inflate() is the same method, under the name of Compress::Zlib
    assert(d.inflate == d.decompress and type(d.inflate) == "function")
    do
        local d2 = zlib.decompressor()
        local o2, st2, n2 = d2:inflate(c .. "x")
        assert(o2 == s and st2 == zlib.Z_STREAM_END and n2 == #c)
        o2, st2 = zlib.decompressor():inflate("garbage")
        assert(o2 == "" and st2 == zlib.Z_DATA_ERROR)
    end
    local out, st, n = d:decompress(c)
    assert(out == s and st == zlib.Z_STREAM_END and n == #c)
    -- after the end: Z_STREAM_END again, nothing consumed
    out, st, n = d:decompress("more")
    assert(out == "" and st == zlib.Z_STREAM_END and n == 0)
    assert(d:msg() == nil)

    -- in pieces: Z_OK while more input is expected
    d = zlib.decompressor()
    local parts = {}
    for i = 1, #c, 1000 do
        out, st, n = d:decompress(c:sub(i, i + 999))
        assert(type(out) == "string")
        parts[#parts + 1] = out
        if i + 999 < #c then
            assert(st == zlib.Z_OK and n == 1000)
        else
            assert(st == zlib.Z_STREAM_END and n == #c - i + 1)
        end
    end
    assert(table.concat(parts) == s)
    -- 1 byte pieces
    d = zlib.decompressor({ format = "gzip" })
    local cg = zlib.compress(s, { format = "gzip" })
    parts = {}
    for i = 1, #cg do
        out, st, n = d:decompress(cg:sub(i, i))
        assert(n == 1)
        parts[#parts + 1] = out
        assert(st == (i < #cg and zlib.Z_OK or zlib.Z_STREAM_END))
    end
    assert(table.concat(parts) == s)
    -- empty input: Z_OK
    d = zlib.decompressor()
    out, st, n = d:decompress("")
    assert(out == "" and st == zlib.Z_OK and n == 0)

    -- trailing data: consumed tells where the stream ends
    for _, f in ipairs(FORMATS) do
        local cf = zlib.compress(s, { format = f })
        d = zlib.decompressor({ format = f })
        out, st, n = d:decompress(cf .. "TRAILING")
        assert(out == s and st == zlib.Z_STREAM_END and n == #cf)
        -- a truncated stream: Z_OK, it may go on
        d = zlib.decompressor({ format = f })
        out, st, n = d:decompress(cf:sub(1, -2))
        assert(#out <= #s and s:sub(1, #out) == out and st == zlib.Z_OK and n == #cf - 1)
        out, st, n = d:decompress(cf:sub(-1) .. "XY")
        assert(st == zlib.Z_STREAM_END and n == 1)
        -- and finish after a truncated stream raises
        d = zlib.decompressor({ format = f })
        d:decompress(cf:sub(1, 100))
        assertError("Error in inflate: unexpected end of input", d.finish, d)
    end

    -- corrupt data: Z_DATA_ERROR and the output so far, msg() gives zlib's message
    d = zlib.decompressor()
    out, st, n = d:decompress("garbage")
    assert(out == "" and st == zlib.Z_DATA_ERROR and n <= 7)
    assert(d:msg() == "incorrect header check")
    out, st, n = d:decompress("more")
    assert(out == "" and st == zlib.Z_DATA_ERROR and n == 0)
    assertError("Error in inflate: incorrect header check", d.update, d, "x")
    assertError("decompressor is closed", d.inflate, d, "x")
    assert(d:msg() == "incorrect header check")
    -- the output before the error is returned: a flushed part, then an invalid block type
    local e = zlib.compressor()
    local part = (e:update(s:sub(1, 30000)) or "") .. e:flush()
    d = zlib.decompressor()
    out, st, n = d:decompress(part .. "\255\255\255")
    assert(out == s:sub(1, 30000) and st == zlib.Z_DATA_ERROR and n == #part + 1)
    assert(d:msg() == "invalid block type")
    d = zlib.decompressor()
    out, st = d:decompress(c:sub(1, -2) .. string.char((c:byte(-1) + 1) % 256))
    assert(out == s and st == zlib.Z_DATA_ERROR and d:msg() == "incorrect data check")

    -- a dictionary is needed: Z_NEED_DICT
    local dict = text(1000, 99)
    local cd = zlib.compress(s, { dictionary = dict })
    d = zlib.decompressor()
    out, st, n = d:decompress(cd)
    assert(out == "" and st == zlib.Z_NEED_DICT and n == 6)
    assert(d:msg() == "need dictionary")
    d = zlib.decompressor({ dictionary = dict })
    out, st, n = d:decompress(cd)
    assert(out == s and st == zlib.Z_STREAM_END and n == #cd)
    d = zlib.decompressor({ dictionary = "wrong" })
    out, st = d:decompress(cd)
    assert(out == "" and st == zlib.Z_DATA_ERROR and d:msg() == "incorrect dictionary")
    out, st = d:decompress(cd)
    assert(out == "" and st == zlib.Z_DATA_ERROR)

    -- maxsize: Z_BUF_ERROR, no more than maxsize bytes of output
    d = zlib.decompressor({ maxsize = 1000 })
    out, st = d:decompress(c)
    assert(out == s:sub(1, 1000) and st == zlib.Z_BUF_ERROR and d:msg() == "output exceeds maxsize")
    out, st, n = d:decompress("x")
    assert(out == "" and st == zlib.Z_BUF_ERROR and n == 0)
    assertError("output exceeds maxsize", d.update, d, "x")
    d = zlib.decompressor({ maxsize = #s })
    out, st = d:decompress(c)
    assert(out == s and st == zlib.Z_STREAM_END)

    -- inflate and update on the same stream
    d = zlib.decompressor()
    local o1 = d:decompress(c:sub(1, 5000))
    local o2 = d:update(c:sub(5001, 10000)) or ""
    local o3 = d:decompress(c:sub(10001))
    assert(o1 .. o2 .. o3 == s)
    assert(d:finish() == "")
end
PRINT("==================================================================================")
do
    -- checksums
    assert(zlib.crc32("") == 0)
    assert(zlib.adler32("") == 1)
    assert(zlib.crc32("123456789") == 0xCBF43926)
    assert(zlib.adler32("Wikipedia") == 0x11E60398)
    assert(zlib.crc32("The quick brown fox jumps over the lazy dog") == 0x414FA339)
    local a, b = text(100000), randomBytes(5000)
    assert(zlib.crc32(b, zlib.crc32(a)) == zlib.crc32(a .. b))
    assert(zlib.adler32(b, zlib.adler32(a)) == zlib.adler32(a .. b))
    assert(zlib.crc32("", 12345) == 12345)
    assert(zlib.adler32("x", 1) == zlib.adler32("x"))
    assert(zlib.crc32(42) == zlib.crc32("42"))
    local v = zlib.crc32(randomBytes(1000, 77))
    assert(v >= 0 and v <= 0xFFFFFFFF and v % 1 == 0)
    assert(zlib.crc32("abc", 0xFFFFFFFF) >= 0)
    assertError("invalid checksum value", zlib.crc32, "x", -1)
    assertError("invalid checksum value", zlib.crc32, "x", 2^32)
    assertError("invalid checksum value", zlib.adler32, "x", 1.5)
    assertError("number expected, got string", zlib.adler32, "x", "1")
    assertError("string or carray expected, got no value", zlib.crc32)
end
PRINT("==================================================================================")
do
    -- 10 MB
    local s = text(10 * 1024 * 1024, 5)
    for _, f in ipairs(FORMATS) do
        local c = zlib.compress(s, { format = f })
        assert(#c < #s / 2)
        assert(zlib.decompress(c, { format = f }) == s)
        assert(streamDecompress(c, 1024 * 1024, { format = f }) == s)
        assert(streamCompress(s, 1024 * 1024 + 17, { format = f }) == c)
        assertError("output exceeds maxsize", zlib.decompress, c, { format = f, maxsize = #s - 1 })
    end
    local c1 = zlib.compress(s, { level = 1 })
    assert(zlib.decompress(c1) == s)
    local c0 = zlib.compress(s, { level = 0 })
    assert(#c0 > #s and zlib.decompress(c0) == s)
    local d = zlib.decompressor()
    local out, st, n = d:decompress(c1)
    assert(out == s and st == zlib.Z_STREAM_END and n == #c1)
    local r = randomBytes(1024 * 1024, 13)
    assert(zlib.decompress(zlib.compress(r, { format = "gzip" }), { format = "auto" }) == r)
end
PRINT("==================================================================================")
print("OK.")
