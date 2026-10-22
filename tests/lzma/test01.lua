-- compress.lzma with string data: one-shot functions, formats, presets and LZMA options,
-- option errors, raw LZMA1/LZMA2 with properties, streaming, flush modes, the status method
-- decompressor:decompress() (alias code()), maxsize, memlimit, 10 MB.

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
                "elit", "sed", "do", "eiusmod", "tempor", "\0", "\n", "lzma", "Lua" }

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

-- the formats with their decoder options; raw1: raw LZMA1 (with end marker)
local FORMATS = {
    { name = "xz",   opts = { format = "xz" } },
    { name = "lzma", opts = { format = "lzma" } },
    { name = "raw",  opts = { format = "raw" } },
    { name = "raw1", opts = { format = "raw", filter = "lzma1" } },
}

local function with(base, extra)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- streaming helpers: feed data in chunks of the given size
local function streamDecompress(data, chunk, opts)
    local d = lzma.decompressor(opts)
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
    local c = lzma.compressor(opts)
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

local function le32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

PRINT("==================================================================================")
do
    PRINT(format("compress.lzma %s, liblzma %s (compiled with %s)", lzma._VERSION, lzma.version()))
    local rv, cv = lzma.version()
    assert(rv:match("^%d+%.%d+%.%d+") and cv:match("^%d+%.%d+%.%d+"))
    assert(getmetatable(lzma) == "compress.lzma")
    assert(getmetatable(lzma.decompressor()) == "compress.lzma.decompressor")
    assert(getmetatable(lzma.compressor()) == "compress.lzma.compressor")
    assert(tostring(lzma.decompressor()):match("^compress%.lzma%.decompressor: "))
    assert(tostring(lzma.compressor()):match("^compress%.lzma%.compressor: "))
end
PRINT("==================================================================================")
do
    -- the constants have liblzma's values
    local K = {
        LZMA_OK = 0, LZMA_STREAM_END = 1, LZMA_NO_CHECK = 2, LZMA_UNSUPPORTED_CHECK = 3,
        LZMA_GET_CHECK = 4, LZMA_MEM_ERROR = 5, LZMA_MEMLIMIT_ERROR = 6, LZMA_FORMAT_ERROR = 7,
        LZMA_OPTIONS_ERROR = 8, LZMA_DATA_ERROR = 9, LZMA_BUF_ERROR = 10, LZMA_PROG_ERROR = 11,
        LZMA_RUN = 0, LZMA_SYNC_FLUSH = 1, LZMA_FULL_FLUSH = 2, LZMA_FINISH = 3,
        LZMA_FULL_BARRIER = 4,
        LZMA_CHECK_NONE = 0, LZMA_CHECK_CRC32 = 1, LZMA_CHECK_CRC64 = 4, LZMA_CHECK_SHA256 = 10,
        LZMA_PRESET_DEFAULT = 6, LZMA_PRESET_LEVEL_MASK = 0x1F, LZMA_PRESET_EXTREME = 0x80000000,
        LZMA_MODE_FAST = 1, LZMA_MODE_NORMAL = 2, LZMA_MF_HC3 = 0x03, LZMA_MF_HC4 = 0x04,
        LZMA_MF_BT2 = 0x12, LZMA_MF_BT3 = 0x13, LZMA_MF_BT4 = 0x14,
        LZMA_DICT_SIZE_MIN = 4096, LZMA_DICT_SIZE_DEFAULT = 8388608,
        LZMA_LCLP_MIN = 0, LZMA_LCLP_MAX = 4, LZMA_LC_DEFAULT = 3, LZMA_LP_DEFAULT = 0,
        LZMA_PB_MIN = 0, LZMA_PB_MAX = 4, LZMA_PB_DEFAULT = 2,
    }
    for name, value in pairs(K) do
        assert(lzma[name] == value, name)
        assert(math.type == nil or math.type(lzma[name]) == "integer", name)
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
        text(100000), randomBytes(1000), randomBytes(50000, 3),
        text(30000) .. randomBytes(30000) .. text(30000, 9),
    }
    for _, s in ipairs(samples) do
        for _, f in ipairs(FORMATS) do
            local c = lzma.compress(s, with(f.opts, { preset = 1 }))
            assert(type(c) == "string")
            assert(lzma.decompress(c, f.opts) == s, f.name)
            if f.name == "xz" or f.name == "lzma" then
                assert(lzma.decompress(c, { format = "auto" }) == s)
            end
        end
        assert(lzma.decompress(lzma.compress(s, { preset = 0 })) == s)    -- default: xz
    end
    -- numbers are converted to strings as in the string library
    assert(lzma.decompress(lzma.compress(12345)) == "12345")
end
PRINT("==================================================================================")
do
    -- format headers
    local s = text(10000)
    local cx = lzma.compress(s)
    local cl = lzma.compress(s, { format = "lzma" })
    local cr = lzma.compress(s, { format = "raw" })
    local c1 = lzma.compress(s, { format = "raw", filter = "lzma1" })
    -- xz: magic, stream flags with the check (CRC64 by default), footer magic "YZ"
    assert(cx:sub(1, 6) == "\253" .. "7zXZ\0")
    assert(cx:sub(7, 8) == "\0\4")
    assert(cx:sub(-2) == "YZ")
    assert(lzma.compress(s, { check = "crc32" }):sub(7, 8) == "\0\1")
    assert(lzma.compress(s, { check = "none" }):sub(7, 8) == "\0\0")
    assert(lzma.compress(s, { check = "sha256" }):sub(7, 8) == "\0\10")
    assert(lzma.compress(s, { check = lzma.LZMA_CHECK_CRC32 }) == lzma.compress(s, { check = "crc32" }))
    -- .lzma: the 5 property bytes (lc/lp/pb, dictionary size) and the size -1 (unknown)
    assert(cl:sub(1, 5) == lzma.properties({ filter = "lzma1" }))
    assert(cl:sub(1, 5) == "\93\0\0\128\0")
    assert(cl:sub(6, 13) == ("\255"):rep(8))
    -- the raw LZMA1 stream is the body of the .lzma file
    assert(cl:sub(14) == c1)
    -- an LZMA2 stream ends with the end marker 0x00
    assert(cr:sub(-1) == "\0")
    -- the shortest streams
    assert(lzma.compress("", { format = "raw" }) == "\0")
    assert(#lzma.compress("") == 32)
    assert(hex(lzma.compress("", { format = "lzma" })):match("^5d00008000ffffffffffffffff"))

    -- formats do not decode each other
    assertError("Error in lzma_code: File format not recognized", lzma.decompress, cl)
    assertError("Error in lzma_code: ", lzma.decompress, cx, { format = "lzma" })
    assertError("Error in lzma_code: ", lzma.decompress, cx, { format = "raw" })
    assertError("Error in lzma_code: File format not recognized", lzma.decompress, cr, { format = "auto" })
    assertError("Error in lzma_code: File format not recognized", lzma.decompress, ("garbage"):rep(3))
end
PRINT("==================================================================================")
do
    -- presets, extreme, level as alias of preset, the LZMA options
    local s = text(200000) .. randomBytes(20000) .. text(100000, 5)
    local sizes = {}
    for p = 0, 9 do
        if p <= 6 or p == 9 then
            local c = lzma.compress(s, { preset = p })
            assert(lzma.decompress(c) == s)
            assert(lzma.compress(s, { level = p }) == c)
            assert(lzma.compress(s, { level = p, preset = p }) == c)
            sizes[p] = #c
        end
    end
    assert(lzma.compress(s) == lzma.compress(s, { preset = 6 }))
    assert(lzma.compress(s) == lzma.compress(s, { preset = lzma.LZMA_PRESET_DEFAULT }))
    assert(sizes[0] < #s and sizes[9] <= sizes[0])
    local e = lzma.compress(s, { preset = 2, extreme = true })
    assert(e ~= lzma.compress(s, { preset = 2 }) and lzma.decompress(e) == s)
    assert(lzma.compress(s, { preset = 2, extreme = false }) == lzma.compress(s, { preset = 2 }))
    assertError("level contradicts preset", lzma.compress, s, { level = 1, preset = 2 })
    -- the options of the preset given explicitly: the same output (xz: lzma_stream_encoder
    -- instead of lzma_easy_encoder)
    local p6 = { dictSize = 8 * 1024 * 1024, lc = 3, lp = 0, pb = 2, mode = "normal", niceLen = 64,
                 mf = "bt4", depth = 0 }
    for _, f in ipairs(FORMATS) do
        local c = lzma.compress(s, f.opts)
        assert(lzma.compress(s, with(f.opts, p6)) == c, f.name)
        assert(lzma.compress(s, with(f.opts, { mode = lzma.LZMA_MODE_NORMAL, mf = lzma.LZMA_MF_BT4 })) == c)
    end
    -- other options change the output, the data is the same
    local variants = {
        { dictSize = 4096 }, { dictSize = 65536 }, { lc = 0 }, { lc = 4 }, { lp = 2, lc = 2 },
        { pb = 0 }, { pb = 4 }, { mode = "fast" }, { niceLen = 2, mf = "bt2" }, { niceLen = 273 },
        { mf = "hc3" }, { mf = "hc4" }, { mf = "bt2" }, { mf = "bt3" }, { depth = 4 },
        { dictSize = 100000 }, { preset = 1, dictSize = 1024 * 1024 },
    }
    local base = lzma.compress(s)
    local differ = 0
    for _, v in ipairs(variants) do
        for _, f in ipairs(FORMATS) do
            local c = lzma.compress(s, with(f.opts, v))
            local dopts = f.opts
            if f.name == "raw" or f.name == "raw1" then
                -- raw: the decoder needs lc/lp/pb (and a dictionary at least as large)
                dopts = with(f.opts, { lc = v.lc, lp = v.lp, pb = v.pb })
            end
            assert(lzma.decompress(c, dopts) == s, f.name)
        end
        if lzma.compress(s, v) ~= base then
            differ = differ + 1
        end
    end
    assert(differ >= #variants - 3)
    -- the dictionary size is in the .lzma header and in the LZMA2 properties, rounded up to
    -- 2^n or 3 * 2^(n-1) (liblzma's .lzma encoder does so as well)
    assert(le32(lzma.compress(s, { format = "lzma", dictSize = 100000 }), 2) == 131072)
    assert(le32(lzma.compress(s, { format = "lzma", dictSize = 65536 }), 2) == 65536)
    assert(lzma.properties({ dictSize = 100000 }) == lzma.properties({ dictSize = 3 * 32768 + 1 }))
    -- errors
    for _, v in ipairs({ -1, 10, 1.5, "6", true }) do
        assertError("invalid preset value", lzma.compress, s, { preset = v })
        assertError("invalid level value", lzma.compressor, { level = v })
    end
    assertError("invalid extreme value", lzma.compress, s, { extreme = 1 })
    assertError("invalid check value", lzma.compress, s, { check = "md5" })
    assertError("invalid check value", lzma.compress, s, { check = 2 })
    for _, v in ipairs({ 4095, 1536 * 1024 * 1024 + 1, -1, 4096.5 }) do
        assertError("invalid dictSize value", lzma.compress, s, { dictSize = v })
    end
    assertError("invalid lc value", lzma.compress, s, { lc = 5 })
    assertError("invalid lp value", lzma.compress, s, { lp = -1 })
    assertError("invalid pb value", lzma.compress, s, { pb = 5 })
    assertError("lc + lp must not exceed 4", lzma.compress, s, { lc = 3, lp = 2 })
    assertError("lc + lp must not exceed 4", lzma.compress, s, { lp = 2 })   -- lc 3 of the preset
    assertError("invalid mode value", lzma.compress, s, { mode = "slow" })
    assertError("invalid mode value", lzma.compress, s, { mode = 3 })
    assertError("invalid niceLen value", lzma.compress, s, { niceLen = 1 })
    assertError("invalid niceLen value", lzma.compress, s, { niceLen = 274 })
    assertError("invalid mf value", lzma.compress, s, { mf = "bt5" })
    assertError("invalid depth value", lzma.compress, s, { depth = -1 })
    -- a niceLen below the match finder's minimum (hc3: 3, bt4: 4) is raised by liblzma
    for _, v in ipairs({ { mf = "hc3", niceLen = 2 }, { mf = "bt4", niceLen = 3 } }) do
        for _, f in ipairs(FORMATS) do
            assert(lzma.decompress(lzma.compress(s, with(f.opts, v)), f.opts) == s)
        end
    end
end
PRINT("==================================================================================")
do
    -- option errors
    assertError("option 'maxsize' is not supported by compress()", lzma.compress, "x", { maxsize = 10 })
    assertError("option 'preset' is not supported by decompress()", lzma.decompress, "x", { preset = 1 })
    assertError("option 'level' is not supported by decompress()", lzma.decompress, "x", { level = 1 })
    assertError("option 'check' is not supported by decompressor()", lzma.decompressor, { check = "crc32" })
    assertError("option 'memlimit' is not supported by compressor()", lzma.compressor, { memlimit = 1 })
    assertError("option 'properties' is not supported by compress()", lzma.compress, "x",
                { format = "raw", properties = "\93\0\0\1\0" })
    assertError("option 'allowtrailing' is not supported by compressor()", lzma.compressor,
                { allowtrailing = true })
    assertError("option 'size' is not supported by compress()", lzma.compress, "x", { size = 1 })
    assertError("option 'format' is not supported by properties()", lzma.properties, { format = "raw" })
    assertError("option 'mode' is not supported by decompress()", lzma.decompress, "x",
                { format = "raw", mode = "fast" })
    assertError("unknown option 'dictsize'", lzma.compress, "x", { dictsize = 4096 })
    assertError("unknown option 'quality'", lzma.compressor, { quality = 1 })
    assertError("unknown option 'windowBits'", lzma.decompressor, { windowBits = 15 })
    -- the former option out: the carray is the last argument
    for _, f in ipairs({ lzma.compress, lzma.decompress }) do
        assertError("option 'out' is no longer supported: pass the carray as the last argument",
                    f, "x", { out = 1 })
    end
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                lzma.compressor, { out = 1 })
    assertError("option 'out' is no longer supported: pass the carray as the last argument",
                lzma.decompressor, { out = 1 })
    assertError("option names must be strings", lzma.compress, "x", { 1 })
    -- options that depend on the format
    assertError("check is only supported for format 'xz'", lzma.compress, "x", { format = "lzma", check = "none" })
    assertError("check is only supported for format 'xz'", lzma.compress, "x", { format = "raw", check = "crc32" })
    assertError("filter is only supported for format 'raw'", lzma.compress, "x", { filter = "lzma1" })
    assertError("filter is only supported for format 'raw'", lzma.decompressor, { format = "auto", filter = "lzma2" })
    assertError("properties is only supported for format 'raw'", lzma.decompress, "x",
                { properties = "\93\0\0\1\0" })
    assertError("dictSize is only supported for format 'raw'", lzma.decompress, "x", { dictSize = 4096 })
    assertError("lc is only supported for format 'raw'", lzma.decompressor, { format = "lzma", lc = 1 })
    assertError("properties cannot be combined with pb", lzma.decompressor,
                { format = "raw", properties = "\0", pb = 1 })
    assertError("size is only supported for format 'raw' with filter 'lzma1'", lzma.decompressor,
                { format = "raw", size = 10 })
    assertError("size is only supported for format 'raw' with filter 'lzma1'", lzma.decompressor,
                { size = 10 })
    assertError("invalid format value", lzma.compress, "x", { format = "auto" })
    assertError("invalid format value", lzma.compress, "x", { format = "zlib" })
    assertError("invalid format value", lzma.decompress, "x", { format = 1 })
    assertError("invalid filter value", lzma.compress, "x", { format = "raw", filter = "delta" })
    assertError("invalid filter value", lzma.properties, { filter = "lzma3" })
    -- the second argument of compress/decompress: options table or output carray
    assertError("table or carray expected, got string", lzma.compress, "x", "preset")
    assertError("table or carray expected, got boolean", lzma.decompress, "x", false)
    assertError("table expected, got string", lzma.compressor, "preset")
    assertError("out: carray expected, got string", lzma.compress, "x", {}, "y")
    assertError("bad argument #3", lzma.compress, "x", nil, 1)
    assertError("out: carray expected, got userdata", lzma.decompress, "x", io.stdout)
    assert(lzma.decompress(lzma.compress("x", nil, nil), nil, nil) == "x")
    assertError("bad argument #2", lzma.compress, "x", { preset = 99 })
    assertError("bad argument #1", lzma.compressor, { preset = 99 })
    assertError("invalid maxsize value", lzma.decompress, "x", { maxsize = -1 })
    assertError("invalid memlimit value", lzma.decompress, "x", { memlimit = -1 })
    assertError("invalid size value", lzma.decompress, "x", { format = "raw", filter = "lzma1", size = 1.5 })
    assertError("invalid allowtrailing value", lzma.decompress, "x", { allowtrailing = 1 })
    assertError("string or carray expected, got table", lzma.compress, {})
    assertError("string or carray expected, got no value", lzma.decompress)
    assertError("string or carray expected, got boolean", lzma.compressor().update, lzma.compressor(), true)
    assertError("properties: string or carray expected, got table", lzma.decompress, "x",
                { format = "raw", properties = {} })
end
PRINT("==================================================================================")
do
    -- raw LZMA1 and LZMA2 with properties, as 7z stores them
    local s = text(50000, 12)
    -- properties(): LZMA1 5 bytes ((pb * 5 + lp) * 9 + lc, dictionary size little endian),
    -- LZMA2 1 byte (the dictionary size)
    assert(lzma.properties({ filter = "lzma1" }) == "\93\0\0\128\0")
    assert(lzma.properties({ filter = "lzma1", preset = 1 }) == "\93\0\0\16\0")
    assert(lzma.properties({ filter = "lzma1", lc = 0, lp = 2, pb = 0, dictSize = 65536 })
           == string.char(18, 0, 0, 1, 0))
    assert(lzma.properties({ filter = "lzma1", dictSize = 100000 }) == "\93\160\134\1\0")
    assert(lzma.properties() == "\22")                       -- LZMA2, 8 MiB
    assert(lzma.properties({ filter = "lzma2", dictSize = 4096 }) == "\0")
    assert(lzma.properties({ level = 9 }) == "\28")          -- 64 MiB
    assertError("lc + lp must not exceed 4", lzma.properties, { filter = "lzma1", lc = 4, lp = 1 })
    for _, v in ipairs({
            { filter = "lzma1" }, { filter = "lzma1", preset = 1 }, { filter = "lzma1", lc = 0, lp = 2, pb = 0 },
            { filter = "lzma1", dictSize = 100000, pb = 4 }, { filter = "lzma1", lc = 4, lp = 0 },
            { filter = "lzma2" }, { filter = "lzma2", dictSize = 65536, lc = 1, lp = 1, pb = 1 } }) do
        local c = lzma.compress(s, with(v, { format = "raw" }))
        local props = lzma.properties(v)
        -- the decoder with the properties, and with the explicit fields
        assert(lzma.decompress(c, { format = "raw", filter = v.filter, properties = props }) == s)
        assert(lzma.decompress(c, { format = "raw", filter = v.filter, lc = v.lc, lp = v.lp, pb = v.pb,
                                    dictSize = v.dictSize }) == s)
        local out, st, n = lzma.decompressor({ format = "raw", filter = v.filter, properties = props }):code(c)
        assert(out == s and st == lzma.LZMA_STREAM_END and n == #c)   -- our streams have end markers
    end
    -- wrong lc/lp/pb: other data or an error (LZMA1 has no check)
    local c = lzma.compress(s, { format = "raw", filter = "lzma1" })
    local ok, r = pcall(lzma.decompress, c, { format = "raw", filter = "lzma1", lc = 0 })
    assert(not ok or r ~= s)
    -- invalid properties
    assertError("Error in lzma_properties_decode: Unsupported options", lzma.decompress, c,
                { format = "raw", filter = "lzma1", properties = "\93\0\0" })
    assertError("Error in lzma_properties_decode: Unsupported options", lzma.decompressor,
                { format = "raw", filter = "lzma1", properties = "\255\0\0\1\0" })
    assertError("Error in lzma_properties_decode: Unsupported options", lzma.decompressor,
                { format = "raw", properties = "\93\0\0\1\0" })      -- LZMA2: 1 byte
    assertError("Error in lzma_properties_decode: Unsupported options", lzma.decompressor,
                { format = "raw", properties = "\41" })              -- LZMA2: dictionary > 4 GiB
    -- a dictionary that is too small for the data: an error, or other data
    local big = text(200000, 3) .. text(200000, 3)
    local cb = lzma.compress(big, { format = "raw", filter = "lzma1" })
    ok, r = pcall(lzma.decompress, cb, { format = "raw", filter = "lzma1", dictSize = 4096 })
    assert(not ok or r ~= big)
    -- the decoders take dictionary sizes up to 4 GiB - 1
    assert(lzma.decompressor({ format = "raw", filter = "lzma1", dictSize = 0xFFFFFFFF, memlimit = 1 })
           :code(cb) == "")
    -- the default of the raw decoders: the options of preset 6, as Perl's Lzma::Filter::Lzma1()
    assert(lzma.decompress(c, { format = "raw", filter = "lzma1" }) == s)
end
PRINT("==================================================================================")
do
    -- raw LZMA1 without end marker (as 7z writes it): the end of the input is the end, or
    -- the option size gives the uncompressed size
    local s = text(30000, 21)
    local c = lzma.compress(s, { format = "raw", filter = "lzma1" })
    -- a 7z archive from 7-Zip 26.01 (7z a -mx=5 -mhc=on a.7z name_*.txt, five files with
    -- "file <i> content\n") with an encoded header: an LZMA1 stream with the coder
    -- properties 5d 00 10 00 00 (lc 3, lp 0, pb 2, 4 KiB dictionary), 250 bytes unpacked
    local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
    local sz = dofile(here .. "sevenzip.lua")
    local archive = sz.SAMPLE
    local sig = sz.signature(archive)
    assert(sig.nextOffset + 32 + sig.nextSize == #archive)
    local si = sz.streamsInfo(archive, 32 + sig.nextOffset + 2)    -- after kEncodedHeader
    assert(si.packPos == 0x26 and si.packSizes[1] == 127 and #si.folders == 1)
    local coder = si.folders[1].coders[1]
    assert(coder.id == sz.LZMA and coder.properties == "\93\0\16\0\0" and si.folders[1].unpackSize == 250)
    local hdr = archive:sub(32 + si.packPos + 1, 32 + si.packPos + si.packSizes[1])
    local props = coder.properties
    local out, st, n = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props }):code(hdr)
    -- no end marker: LZMA_OK, all input consumed, the decoded header (kHeader = 0x01 ...)
    assert(st == lzma.LZMA_OK and n == #hdr and #out == 250, #out)
    assert(out:byte(1) == 1 and out:find("n\0a\0m\0e\0_\0" .. "3\0.\0t\0x\0t\0", 1, true))
    assert(sz.decodeHeader(archive, lzma) == out)
    local full = out
    -- the CRC of the header (kCRC of the unpack info), if compress.zlib is installed
    local okz, zlib = pcall(require, "compress.zlib")
    if okz then
        assert(zlib.crc32(out) == si.folders[1].crc)
    end
    -- the main streams info in the decoded header: the packed files, also LZMA2 here
    local main = sz.streamsInfo(out, 3)                  -- kHeader, kMainStreamsInfo
    assert(main.packPos == 0 and main.folders[1].coders[1].id == sz.LZMA2)
    local files = sz.decodeFolder(archive, main, 1, lzma)
    assert(files == "file 1 content\nfile 2 content\nfile 3 content\nfile 4 content\nfile 5 content\n")
    -- finish() and decompress() accept the end of the input as the end of the stream
    assert(lzma.decompress(hdr, { format = "raw", filter = "lzma1", properties = props }) == out)
    assert(streamDecompress(hdr, 1, { format = "raw", filter = "lzma1", properties = props }) == out)
    -- Perl's Lzma::Filter::Lzma1() defaults (8 MiB dictionary) also decode it
    assert(lzma.decompress(hdr, { format = "raw", filter = "lzma1" }) == out)
    -- with size: LZMA_STREAM_END after exactly size bytes, trailing data is noticed
    local okSize = pcall(lzma.decompressor, { format = "raw", filter = "lzma1", size = 1 })
    if not okSize then
        print("liblzma without LZMA_FILTER_LZMA1EXT (before 5.4): option size not tested")
    else
        local d = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props, size = 250 })
        out, st, n = d:code(hdr .. "TRAILING")
        assert(#out == 250 and st == lzma.LZMA_STREAM_END and n == #hdr)
        assert(lzma.decompress(hdr, { format = "raw", filter = "lzma1", properties = props, size = 250 })
               == out)
        assertError("Error in lzma_code: unexpected data after end of stream", lzma.decompress,
                    hdr .. "x", { format = "raw", filter = "lzma1", properties = props, size = 250 })
        assert(lzma.decompress(hdr .. "x", { format = "raw", filter = "lzma1", properties = props,
                                             size = 250, allowtrailing = true }) == out)
        -- a truncated stream with size is an error at the end
        assertError("Error in lzma_code: unexpected end of input", lzma.decompress,
                    hdr:sub(1, 100), { format = "raw", filter = "lzma1", properties = props, size = 250 })
        -- a smaller size: the output ends there; a larger one: the data is corrupt
        out = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props, size = 100 }):code(hdr)
        assert(#out == 100)
        out, st = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props, size = 251 })
                  :code(hdr)
        assert(st == lzma.LZMA_OK or st == lzma.LZMA_DATA_ERROR)
        -- streams with end marker and size: both are accepted (LZMA_LZMA1EXT_ALLOW_EOPM)
        assert(lzma.decompress(c, { format = "raw", filter = "lzma1", size = #s }) == s)
        -- (in pieces only if the end marker is not split: liblzma 5.8 gives LZMA_DATA_ERROR
        -- when the input of a stream with known size and end marker is split in its last
        -- bytes; this holds for liblzma's .lzma decoder with a size in the header as well)
        assert(streamDecompress(c, #c - 10, { format = "raw", filter = "lzma1", size = #s }) == s)
        out, st, n = lzma.decompressor({ format = "raw", filter = "lzma1", size = 0 }):code("\0\0\0\0\0")
        assert(out == "" and st == lzma.LZMA_STREAM_END)
    end
    -- truncated without size: not noticed (no end marker, no size), the output is shorter
    local part = lzma.decompress(hdr:sub(1, 100), { format = "raw", filter = "lzma1", properties = props })
    assert(#part < 250 and full:sub(1, #part) == part)
    -- our raw LZMA1 stream has an end marker: the end and trailing data are noticed
    assertError("Error in lzma_code: unexpected data after end of stream", lzma.decompress, c .. "x",
                { format = "raw", filter = "lzma1" })
end
PRINT("==================================================================================")
do
    -- empty, corrupt, truncated data and data after the end
    for _, f in ipairs(FORMATS) do
        if f.name ~= "raw1" then
            assertError("Error in lzma_code: unexpected end of input", lzma.decompress, "", f.opts)
        end
        assert(lzma.decompress(lzma.compress("", f.opts), f.opts) == "")
    end
    -- raw LZMA1 without size: the end of the input is the end
    assert(lzma.decompress("", { format = "raw", filter = "lzma1" }) == "")
    assertError("Error in lzma_code: unexpected end of input", lzma.decompress, "", { format = "auto" })
    assertError("Error in lzma_code: File format not recognized", lzma.decompress, ("garbage"):rep(2))
    assertError("Error in lzma_code: File format not recognized", lzma.decompress, ("garbage"):rep(2),
                { format = "auto" })
    assertError("Error in lzma_code: ", lzma.decompress, "\255\255\255\255", { format = "raw" })

    local s = text(100000)
    for _, f in ipairs(FORMATS) do
        local c = lzma.compress(s, f.opts)
        for _, n in ipairs({ 1, 2, 10, math.floor(#c / 2), #c - 1 }) do
            local ok, err = pcall(lzma.decompress, c:sub(1, n), f.opts)
            -- raw LZMA1: the end marker may be cut off only partly (then decoded data, or an error)
            assert(not ok and (err:find("Error in lzma_code: unexpected end of input", 1, true)
                               or (f.name == "raw1" and err:find("Error in lzma_code: ", 1, true)))
                   or (ok and f.name == "raw1"), f.name .. " " .. n)
        end
        assertError("Error in lzma_code: unexpected data after end of stream",
                    lzma.decompress, c .. "x", f.opts)
        assertError("Error in lzma_code: unexpected data after end of stream",
                    lzma.decompress, c .. c, f.opts)
        assert(lzma.decompress(c .. "trailing data", with(f.opts, { allowtrailing = true })) == s)
        assert(lzma.decompress(c, with(f.opts, { allowtrailing = false })) == s)
        -- a corrupted byte in the middle
        local m = math.floor(#c / 2)
        local bad = c:sub(1, m) .. string.char((c:byte(m + 1) + 77) % 256) .. c:sub(m + 2)
        local ok, err = pcall(lzma.decompress, bad, f.opts)
        -- lzma and raw have no checksum: the data may decode, but differently
        assert((not ok and err:match("^Error in lzma_code: ")) or (ok and f.name ~= "xz" and err ~= s))
    end
    -- checksum errors of xz
    for _, check in ipairs({ "crc32", "crc64", "sha256" }) do
        local cx = lzma.compress(s, { check = check })
        -- the check field is just before the index: change a byte of it
        local size = ({ crc32 = 4, crc64 = 8, sha256 = 32 })[check]
        local found = false
        for pos = #cx - 12 - 12, #cx - 60, -1 do
            local bad = cx:sub(1, pos - 1) .. string.char((cx:byte(pos) + 1) % 256) .. cx:sub(pos + 1)
            local ok, err = pcall(lzma.decompress, bad)
            if not ok and err == "Error in lzma_code: Compressed data is corrupt" then
                found = true
                break
            end
        end
        assert(found and size, check)
    end
    -- the check none: a corrupted byte may go unnoticed
    assert(lzma.decompress(lzma.compress(s, { check = "none" })) == s)
end
PRINT("==================================================================================")
do
    -- maxsize
    local s = text(100000)
    for _, f in ipairs(FORMATS) do
        local c = lzma.compress(s, with(f.opts, { preset = 1 }))
        assert(lzma.decompress(c, with(f.opts, { maxsize = #s })) == s)
        assert(lzma.decompress(c, with(f.opts, { maxsize = #s + 1 })) == s)
        assertError("output exceeds maxsize", lzma.decompress, c, with(f.opts, { maxsize = #s - 1 }))
        assertError("output exceeds maxsize", lzma.decompress, c, with(f.opts, { maxsize = 0 }))
        assert(streamDecompress(c, 1000, with(f.opts, { maxsize = #s })) == s)
        assertError("output exceeds maxsize", streamDecompress, c, 1000, with(f.opts, { maxsize = #s - 1 }))
    end
    assert(lzma.decompress(lzma.compress(""), { maxsize = 0 }) == "")
    -- a compression bomb: 50 MB of zeros
    local bomb = lzma.compressor({ preset = 0 })
    local parts = {}
    local zeros = ("\0"):rep(1024 * 1024)
    for i = 1, 50 do parts[#parts + 1] = bomb:update(zeros) end
    parts[#parts + 1] = bomb:finish()
    bomb = table.concat(parts)
    assert(#bomb < 20000)
    assertError("output exceeds maxsize", lzma.decompress, bomb, { maxsize = 1000000 })
    local out, st = lzma.decompressor({ maxsize = 1000 }):code(bomb)
    assert(out == ("\0"):rep(1000) and st == lzma.LZMA_BUF_ERROR)
end
PRINT("==================================================================================")
do
    -- memlimit: LZMA_MEMLIMIT_ERROR, as error or status
    local s = text(20000)
    for _, f in ipairs({ { format = "xz" }, { format = "lzma" }, { format = "auto" } }) do
        local c = lzma.compress(s, { format = (f.format == "auto") and "xz" or f.format })
        assert(lzma.decompress(c, with(f, { memlimit = 100 * 1024 * 1024 })) == s)
        assertError("Error in lzma_code: Memory usage limit reached", lzma.decompress, c,
                    with(f, { memlimit = 1024 * 1024 }))
        local d = lzma.decompressor(with(f, { memlimit = 1 }))
        local out, st = d:code(c)
        assert(out == "" and st == lzma.LZMA_MEMLIMIT_ERROR and d:msg() == "Memory usage limit reached")
        out, st = d:code(c)
        assert(out == "" and st == lzma.LZMA_MEMLIMIT_ERROR)
        assertError("Error in lzma_code: Memory usage limit reached", d.update, d, "x")
        assertError("decompressor is closed", d.code, d, "x")
    end
    -- raw: the memory usage of the decoder, checked when the decoder is created (status of
    -- the first call)
    local c = lzma.compress(s, { format = "raw", filter = "lzma1" })
    assert(lzma.decompress(c, { format = "raw", filter = "lzma1", memlimit = 9 * 1024 * 1024 }) == s)
    assert(lzma.decompress(c, { format = "raw", filter = "lzma1", dictSize = 65536, memlimit = 1024 * 1024 }) == s)
    assertError("Error in lzma_raw_decoder: Memory usage limit reached", lzma.decompress, c,
                { format = "raw", filter = "lzma1", memlimit = 1024 * 1024 })
    local d = lzma.decompressor({ format = "raw", memlimit = 1000 })
    local out, st, n = d:decompress(c)
    assert(out == "" and st == lzma.LZMA_MEMLIMIT_ERROR and n == 0)
    assert(d:msg() == "Memory usage limit reached")
    assertError("Error in lzma_raw_decoder: Memory usage limit reached", d.finish, d)
    -- 0 is a limit of 1 byte, as in liblzma
    assertError("Memory usage limit reached", lzma.decompress, lzma.compress(s), { memlimit = 0 })
end
PRINT("==================================================================================")
do
    -- streaming with all chunk sizes gives the same output as one call
    local s = text(300000, 11) .. randomBytes(30000, 2)
    for _, f in ipairs(FORMATS) do
        local opts = with(f.opts, { preset = 2 })
        local c = lzma.compress(s, opts)
        for _, chunk in ipairs({ 3, 1000, 65536, 400000 }) do
            assert(streamDecompress(c, chunk, f.opts) == s)
        end
        for _, chunk in ipairs({ 7, 1000, 65536, 400000 }) do
            assert(streamCompress(s, chunk, opts) == c)
        end
    end
    -- 1 byte feeding, also for compression
    local s2 = text(20000, 6)
    for _, f in ipairs(FORMATS) do
        local c = lzma.compress(s2, with(f.opts, { preset = 1 }))
        assert(streamCompress(s2, 1, with(f.opts, { preset = 1 })) == c)
        assert(streamDecompress(c, 1, f.opts) == s2)
        assert(streamDecompress(c, 1, with(f.opts, { maxsize = #s2 })) == s2)
    end
    assert(streamDecompress(lzma.compress(s2, { format = "lzma" }), 1, { format = "auto" }) == s2)
    -- empty chunks
    local d = lzma.decompressor()
    assert(d:update("") == nil)
    local c = lzma.compress("abc")
    assert(d:update(c:sub(1, 2)) == nil)
    assert(d:update("") == nil)
    assert(d:update("") == nil)
    assert(d:update(c:sub(3)) == "abc")
    assert(d:update("") == nil)
    assert(d:finish() == "")
    local e = lzma.compressor()
    assert(e:update("") == nil)
    assert(e:update("") == nil)
    -- the first data gives the stream header of xz (12 bytes) and the block header
    local h = e:update("abc")
    assert(h == c:sub(1, #h) and #h > 12)
    assert(h .. e:finish() == c)
    -- finish with a chunk
    e = lzma.compressor({ format = "raw" })
    assert(e:finish("abc") == lzma.compress("abc", { format = "raw" }))
    d = lzma.decompressor({ format = "raw" })
    assert(d:finish(lzma.compress("abc", { format = "raw" })) == "abc")
    -- after finish and after errors the streams are closed
    assertError("compressor is closed", e.update, e, "x")
    assertError("compressor is closed", e.finish, e)
    assertError("decompressor is closed", d.update, d, "x")
    assertError("decompressor is closed", d.code, d, "x")
    d = lzma.decompressor()
    assertError("Error in lzma_code: File format not recognized", d.update, d, ("garbage"):rep(2))
    assertError("decompressor is closed", d.update, d, "x")
    d = lzma.decompressor()
    d:update(c:sub(1, 3))
    assertError("Error in lzma_code: unexpected end of input", d.finish, d)
    assertError("decompressor is closed", d.finish, d)
    -- after the end: trailing data
    d = lzma.decompressor()
    assert(d:update(c) == "abc")
    assertError("Error in lzma_code: unexpected data after end of stream", d.update, d, "x")
    d = lzma.decompressor()
    assertError("Error in lzma_code: unexpected data after end of stream", d.update, d, c .. "x")
    d = lzma.decompressor()
    assert(d:update(c) == "abc")
    assertError("Error in lzma_code: unexpected data after end of stream", d.finish, d, "x")
    d = lzma.decompressor({ allowtrailing = true })
    assert(d:update(c .. "xyz") == "abc")
    assert(d:update("more") == nil)
    assert(d:finish("more") == "")
end
PRINT("==================================================================================")
do
    -- flush modes
    local s = text(100000, 21)
    local cases = {
        { { format = "xz" },  { "sync", "full", "barrier", lzma.LZMA_SYNC_FLUSH, lzma.LZMA_FULL_FLUSH,
                                lzma.LZMA_FULL_BARRIER } },
        { { format = "raw" }, { "sync", lzma.LZMA_SYNC_FLUSH } },
    }
    for _, cs in ipairs(cases) do
        local opts = cs[1]
        for _, mode in ipairs(cs[2]) do
            local c = lzma.compressor(with(opts, { preset = 1 }))
            local d = lzma.decompressor(opts)
            local cparts, dparts = {}, {}
            for i = 1, #s, 7777 do
                local piece = s:sub(i, i + 7776)
                local r1 = c:update(piece)
                local r2 = c:flush(nil, mode)
                assert(r2)
                cparts[#cparts + 1] = r1
                cparts[#cparts + 1] = r2
                -- everything given so far can be decompressed now
                dparts[#dparts + 1] = d:update((r1 or "") .. r2)
                assert(table.concat(dparts) == s:sub(1, i + 7776))
            end
            -- a second flush without data gives nothing
            assert(c:flush(nil, mode) == nil, tostring(mode))
            cparts[#cparts + 1] = c:finish()
            local all = table.concat(cparts)
            assert(lzma.decompress(all, opts) == s)
        end
    end
    -- full flush (xz): a new block; the data after it does not refer to the data before
    local c = lzma.compressor()
    local p1 = (c:update(s:sub(1, 50000)) or "") .. c:flush(nil, "full")
    local p2 = (c:update(s:sub(50001)) or "") .. c:finish()
    assert(lzma.decompress(p1 .. p2) == s)
    assert(#p1 + #p2 > #lzma.compress(s))
    -- flush with a chunk, LZMA_RUN, "finish" and LZMA_FINISH
    c = lzma.compressor()
    local parts = {}
    for i = 1, #s, 10000 do
        parts[#parts + 1] = c:flush(s:sub(i, i + 9999), lzma.LZMA_RUN)
    end
    parts[#parts + 1] = c:flush(nil, "finish")
    assert(table.concat(parts) == lzma.compress(s))
    assertError("compressor is closed", c.update, c, "x")
    c = lzma.compressor()
    assert(c:flush(s, lzma.LZMA_FINISH) == lzma.compress(s))
    -- formats without flush: an error, the stream stays usable
    for _, opts in ipairs({ { format = "lzma" }, { format = "raw", filter = "lzma1" } }) do
        c = lzma.compressor(opts)
        local h = c:update("abc") or ""          -- .lzma: the 13 byte header
        local what = opts.filter and "filter 'lzma1'" or "format 'lzma'"
        assertError("flush mode 'sync' is not supported for " .. what, c.flush, c)
        assertError("flush mode 'sync' is not supported for " .. what, c.flush, c, "x", "sync")
        assertError("flush mode 'full' is not supported for " .. what, c.flush, c, "x", "full")
        assertError("flush mode 'barrier' is not supported for " .. what, c.flush, c, "x",
                    lzma.LZMA_FULL_BARRIER)
        assert(h .. c:flush("def", "finish") == lzma.compress("abcdef", opts))
    end
    c = lzma.compressor({ format = "raw" })
    assertError("flush mode 'full' is not supported for filter 'lzma2'", c.flush, c, nil, "full")
    assert(lzma.decompress(c:finish("abc"), { format = "raw" }) == "abc")
    c = lzma.compressor()
    assertError("invalid flush mode", c.flush, c, "x", "none")
    assertError("invalid flush mode", c.flush, c, "x", 5)
    assertError("invalid flush mode", c.flush, c, "x", -1)
    assertError("invalid flush mode", c.flush, c, "x", true)
    assertError("bad argument #3", c.flush, c, "x", "Sync")
    -- the default flush mode is sync
    local a, b = lzma.compressor(), lzma.compressor()
    assert(a:flush("abc") == b:flush("abc", "sync"))
    assert(a:finish() == b:finish())
end
PRINT("==================================================================================")
do
    -- the status method decompress(): output, status, consumed; raises no data errors
    local s = text(100000, 31)
    local c = lzma.compress(s, { preset = 1 })
    local d = lzma.decompressor()
    -- code() is the same method, under the name of Compress::Raw::Lzma
    assert(d.code == d.decompress and type(d.code) == "function")
    local out, st, n = d:decompress(c)
    assert(out == s and st == lzma.LZMA_STREAM_END and n == #c)
    -- after the end: LZMA_STREAM_END again, nothing consumed
    out, st, n = d:decompress("more")
    assert(out == "" and st == lzma.LZMA_STREAM_END and n == 0)
    assert(d:msg() == nil)

    -- in pieces: LZMA_OK while more input is expected
    d = lzma.decompressor()
    local parts = {}
    for i = 1, #c, 1000 do
        out, st, n = d:code(c:sub(i, i + 999))
        assert(type(out) == "string")
        parts[#parts + 1] = out
        if i + 999 < #c then
            assert(st == lzma.LZMA_OK and n == 1000)
        else
            assert(st == lzma.LZMA_STREAM_END and n == #c - i + 1)
        end
    end
    assert(table.concat(parts) == s)
    -- 1 byte pieces
    for _, f in ipairs(FORMATS) do
        local cf = lzma.compress(s:sub(1, 20000), with(f.opts, { preset = 0 }))
        d = lzma.decompressor(f.opts)
        parts = {}
        for i = 1, #cf do
            out, st, n = d:code(cf:sub(i, i))
            assert(n == 1)
            parts[#parts + 1] = out
            assert(st == (i < #cf and lzma.LZMA_OK or lzma.LZMA_STREAM_END), f.name)
        end
        assert(table.concat(parts) == s:sub(1, 20000))
    end
    -- empty input: LZMA_OK, also repeated (liblzma itself would give LZMA_BUF_ERROR)
    d = lzma.decompressor()
    for _ = 1, 3 do
        out, st, n = d:code("")
        assert(out == "" and st == lzma.LZMA_OK and n == 0)
    end

    -- trailing data: consumed tells where the stream ends
    for _, f in ipairs(FORMATS) do
        local cf = lzma.compress(s, with(f.opts, { preset = 1 }))
        d = lzma.decompressor(f.opts)
        out, st, n = d:decompress(cf .. "TRAILING")
        assert(out == s and st == lzma.LZMA_STREAM_END and n == #cf, f.name)
        -- a truncated stream: LZMA_OK, it may go on
        d = lzma.decompressor(f.opts)
        out, st, n = d:decompress(cf:sub(1, -2))
        assert(#out <= #s and s:sub(1, #out) == out and st == lzma.LZMA_OK and n == #cf - 1)
        out, st, n = d:decompress(cf:sub(-1) .. "XY")
        assert(st == lzma.LZMA_STREAM_END and n == 1)
        -- and finish after a truncated stream raises
        if f.name ~= "raw1" then
            d = lzma.decompressor(f.opts)
            d:decompress(cf:sub(1, 100))
            assertError("Error in lzma_code: unexpected end of input", d.finish, d)
        end
    end

    -- corrupt data: the status and the output so far, msg() gives the message
    d = lzma.decompressor()
    out, st, n = d:code(("garbage"):rep(2))
    assert(out == "" and st == lzma.LZMA_FORMAT_ERROR and n <= 14)
    assert(d:msg() == "File format not recognized")
    out, st, n = d:code("more")
    assert(out == "" and st == lzma.LZMA_FORMAT_ERROR and n == 0)
    assertError("Error in lzma_code: File format not recognized", d.update, d, "x")
    assertError("decompressor is closed", d.code, d, "x")
    assert(d:msg() == "File format not recognized")
    -- the output before the error is returned: a flushed part, then an invalid LZMA2
    -- control byte
    local e = lzma.compressor({ format = "raw" })
    local part = (e:update(s:sub(1, 30000)) or "") .. e:flush()
    d = lzma.decompressor({ format = "raw" })
    out, st, n = d:code(part .. "\3\255\255")
    assert(out == s:sub(1, 30000) and st == lzma.LZMA_DATA_ERROR and n == #part + 1)
    assert(d:msg() == "Compressed data is corrupt")
    -- a corrupted xz header: LZMA_DATA_ERROR (the CRC32 of the stream flags)
    local cx = lzma.compress("abc")
    d = lzma.decompressor()
    out, st = d:code(cx:sub(1, 6) .. "\1" .. cx:sub(8))
    assert(out == "" and st == lzma.LZMA_DATA_ERROR and d:msg() == "Compressed data is corrupt")

    -- maxsize: LZMA_BUF_ERROR, no more than maxsize bytes of output
    d = lzma.decompressor({ maxsize = 1000 })
    out, st = d:decompress(c)
    assert(out == s:sub(1, 1000) and st == lzma.LZMA_BUF_ERROR and d:msg() == "output exceeds maxsize")
    out, st, n = d:decompress("x")
    assert(out == "" and st == lzma.LZMA_BUF_ERROR and n == 0)
    assertError("output exceeds maxsize", d.update, d, "x")
    d = lzma.decompressor({ maxsize = #s })
    out, st = d:decompress(c)
    assert(out == s and st == lzma.LZMA_STREAM_END)

    -- code and update on the same stream
    d = lzma.decompressor()
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
    for _, f in ipairs({ FORMATS[1], FORMATS[4] }) do
        local opts = with(f.opts, { preset = 1 })
        local c = lzma.compress(s, opts)
        assert(#c < #s / 2)
        assert(lzma.decompress(c, f.opts) == s)
        assert(streamDecompress(c, 1024 * 1024, f.opts) == s)
        assert(streamCompress(s, 1024 * 1024 + 17, opts) == c)
        assertError("output exceeds maxsize", lzma.decompress, c, with(f.opts, { maxsize = #s - 1 }))
        local d = lzma.decompressor(f.opts)
        local out, st, n = d:decompress(c)
        assert(out == s and st == lzma.LZMA_STREAM_END and n == #c)
    end
    local r = randomBytes(1024 * 1024, 13)
    assert(lzma.decompress(lzma.compress(r, { format = "lzma", preset = 0 }), { format = "auto" }) == r)
end
PRINT("==================================================================================")
print("OK.")
