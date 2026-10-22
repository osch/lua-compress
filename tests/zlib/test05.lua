-- compress.zlib: the gzip header fields of the option gzipHeader (deflateSetHeader()):
-- every field, combinations, the header bytes, streaming, round trips, carray strings,
-- errors.

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

local function newRandom(seed)
    local x = seed
    return function(n)
        x = (x * 16807) % 2147483647
        return x % n
    end
end

local function text(n, seed)
    local words = { "lorem", "ipsum", "dolor", "sit", "amet", "\0", "\n", "zlib", "Lua" }
    local rnd = newRandom(seed or 7)
    local t, len = {}, 0
    while len < n do
        local w = words[rnd(#words) + 1]
        t[#t + 1] = w .. " "
        len = len + #w + 1
    end
    return table.concat(t):sub(1, n)
end

local function le16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end
local function u16(s, i) return s:byte(i) + 256 * s:byte(i + 1) end
local function u32(s, i) return u16(s, i) + 65536 * u16(s, i + 2) end

-- parses the gzip header of s (RFC 1952) and checks its structure; returns its fields
-- and the length of the header
local function parseHeader(s)
    assert(s:sub(1, 3) == "\31\139\8", "gzip magic and method")
    local flg = s:byte(4)
    assert(flg < 32, "reserved flag bits")
    local h = {
        flags = flg, mtime = u32(s, 5), xfl = s:byte(9), os = s:byte(10),
        text = flg % 2 == 1, hcrc = math.floor(flg / 2) % 2 == 1,
    }
    local pos = 11
    if math.floor(flg / 4) % 2 == 1 then
        local xlen = u16(s, pos)
        h.extra = s:sub(pos + 2, pos + 1 + xlen)
        assert(#h.extra == xlen)
        pos = pos + 2 + xlen
    end
    if math.floor(flg / 8) % 2 == 1 then
        local e = assert(s:find("\0", pos, true), "name not NUL-terminated")
        h.name = s:sub(pos, e - 1)
        pos = e + 1
    end
    if math.floor(flg / 16) % 2 == 1 then
        local e = assert(s:find("\0", pos, true), "comment not NUL-terminated")
        h.comment = s:sub(pos, e - 1)
        pos = e + 1
    end
    if h.hcrc then
        -- CRC16: the two low bytes of the CRC-32 of the header bytes before it
        assert(u16(s, pos) == zlib.crc32(s:sub(1, pos - 1)) % 65536, "header CRC")
        h.crc16 = u16(s, pos)
        pos = pos + 2
    end
    return h, pos - 1
end

local s = text(20000, 3)
local plain = zlib.compress(s, { format = "gzip" })
local DEFAULT_OS = plain:byte(10)

local function gz(hdr, extra)
    local o = { format = "gzip", gzipHeader = hdr }
    for k, v in pairs(extra or {}) do o[k] = v end
    return zlib.compress(s, o)
end

-- the compressed data after the header and the trailer are the same as without header
local function checkBody(c, len)
    assert(c:sub(len + 1) == plain:sub(11), "deflate data and trailer")
    assert(zlib.decompress(c, { format = "gzip" }) == s)
    assert(zlib.decompress(c, { format = "auto" }) == s)
    assert(zlib.decompress(c, { windowBits = 31 }) == s)
end

PRINT("==================================================================================")
do
    -- zlib's default header: without gzipHeader and with an empty one the same bytes
    PRINT(format("zlib's default OS code: %d", DEFAULT_OS))
    assert(gz({}) == plain)
    assert(gz({ os = DEFAULT_OS, mtime = 0, text = false, hcrc = false }) == plain)
    local h, len = parseHeader(plain)
    assert(len == 10 and h.flags == 0 and h.mtime == 0 and h.xfl == 0)
    -- the empty data too
    assert(zlib.compress("", { format = "gzip", gzipHeader = {} }) == zlib.compress("", { format = "gzip" }))
    -- windowBits 16 + n selects gzip
    assert(zlib.compress(s, { windowBits = 31, gzipHeader = {} }) == plain)
    assert(zlib.compress(s, { windowBits = 25, gzipHeader = { name = "x" } })
           == zlib.compress(s, { format = "gzip", windowBits = 9, gzipHeader = { name = "x" } }))
end
PRINT("==================================================================================")
do
    -- os
    for _, os in ipairs({ 0, 3, 10, 19, 255 }) do
        local c = gz({ os = os })
        local h, len = parseHeader(c)
        assert(h.os == os and h.flags == 0 and h.mtime == 0 and len == 10)
        assert(c:sub(1, 9) == plain:sub(1, 9))
        checkBody(c, len)
    end
    -- mtime, little endian
    for _, t in ipairs({ 0, 1, 255, 256, 1234567890, 0x12345678, 0x80000000, 0xFFFFFFFF }) do
        local c = gz({ mtime = t })
        local h, len = parseHeader(c)
        assert(h.mtime == t and c:sub(5, 8) == le32(t) and h.os == DEFAULT_OS and len == 10)
        checkBody(c, len)
    end
    assert(gz({ mtime = 1.0e9 }) == gz({ mtime = 1000000000 }))
    -- text (FTEXT) and hcrc (FHCRC)
    do
        local c = gz({ text = true })
        local h, len = parseHeader(c)
        assert(h.flags == 1 and h.text and len == 10)
        checkBody(c, len)
        c = gz({ hcrc = true })
        h, len = parseHeader(c)
        assert(h.flags == 2 and h.hcrc and len == 12)
        assert(c:sub(11, 12) == le16(zlib.crc32(c:sub(1, 10)) % 65536))
        checkBody(c, len)
        assert(gz({ text = false, hcrc = false }) == plain)
    end
    -- extra (FEXTRA): length little endian, any bytes (NUL too), also empty
    for _, x in ipairs({ "", "AB\3\0xyz", "\0\0\0\0", ("x"):rep(300), ("\255"):rep(65535) }) do
        local c = gz({ extra = x })
        local h, len = parseHeader(c)
        assert(h.flags == 4 and h.extra == x and c:sub(11, 12) == le16(#x) and len == 12 + #x)
        checkBody(c, len)
    end
    -- name (FNAME) and comment (FCOMMENT), NUL-terminated, also empty
    for _, n in ipairs({ "", "a", "file.txt", "dir/\195\164\255.tar", ("n"):rep(100000) }) do
        local c = gz({ name = n })
        local h, len = parseHeader(c)
        assert(h.flags == 8 and h.name == n and c:sub(11, 11 + #n) == n .. "\0" and len == 11 + #n)
        checkBody(c, len)
        c = gz({ comment = n })
        h, len = parseHeader(c)
        assert(h.flags == 16 and h.comment == n and c:sub(11, 11 + #n) == n .. "\0" and len == 11 + #n)
        checkBody(c, len)
    end
    -- numbers are converted to strings, as for data
    assert(parseHeader(gz({ name = 123 })).name == "123")
end
PRINT("==================================================================================")
do
    -- combinations: all subsets of the optional fields, in the order of RFC 1952
    local fields = {
        { "text", true }, { "hcrc", true }, { "extra", "AB\2\0hi" }, { "name", "a.txt" },
        { "comment", "a comment" },
    }
    local n = 0
    for mask = 0, 31 do
        local hdr = { os = 3, mtime = 1700000000 }
        local expectFlags = 0
        for i, f in ipairs(fields) do
            if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then
                hdr[f[1]] = f[2]
                expectFlags = expectFlags + 2 ^ (i - 1)
            end
        end
        local c = gz(hdr)
        local h, len = parseHeader(c)
        assert(h.flags == expectFlags and h.os == 3 and h.mtime == 1700000000)
        for _, f in ipairs(fields) do
            local expect = hdr[f[1]]
            if expect == nil and type(f[2]) == "boolean" then expect = false end
            assert(h[f[1]] == expect, f[1])
        end
        checkBody(c, len)
        n = n + 1
    end
    -- the full header byte by byte
    local c = gz({ os = 3, mtime = 0x01020304, text = true, hcrc = true, extra = "AB\3\0xyz",
                   name = "a.txt", comment = "hi" })
    local hdr = "\31\139\8\31\4\3\2\1\0\3" .. "\7\0AB\3\0xyz" .. "a.txt\0" .. "hi\0"
    assert(c:sub(1, #hdr) == hdr)
    assert(c:sub(#hdr + 1, #hdr + 2) == le16(zlib.crc32(hdr) % 65536))
    checkBody(c, #hdr + 2)
    PRINT(format("%d combinations", n))
end
PRINT("==================================================================================")
do
    -- XFL is set by zlib from level and strategy, independent of the header
    for _, p in ipairs({ { 9, 0, 2 }, { 1, 0, 4 }, { 0, 0, 4 }, { 6, 0, 0 }, { 6, 2, 4 } }) do
        local c = zlib.compress(s, { format = "gzip", level = p[1], strategy = p[2],
                                     gzipHeader = { name = "n", os = 3 } })
        local h, len = parseHeader(c)
        assert(h.xfl == p[3] and h.name == "n")
        assert(c:sub(len + 1) == zlib.compress(s, { format = "gzip", level = p[1], strategy = p[2] }):sub(11))
    end
    -- with the other parameters
    for _, o in ipairs({ { memLevel = 1 }, { memLevel = 9 }, { windowBits = 25 }, { level = 0 } }) do
        local opts = { format = "gzip", gzipHeader = { name = "file", hcrc = true } }
        for k, v in pairs(o) do opts[k] = v end
        local c = zlib.compress(s, opts)
        local h, len = parseHeader(c)
        assert(h.name == "file" and h.hcrc)
        opts.gzipHeader = nil
        assert(c:sub(len + 1) == zlib.compress(s, opts):sub(11))
        assert(zlib.decompress(c, { format = "gzip" }) == s)
    end
end
PRINT("==================================================================================")
do
    -- decompression reads the header fields: streaming with all chunk sizes, inflate(),
    -- a wrong header CRC is detected
    local c = gz({ os = 3, mtime = 77, text = true, hcrc = true, extra = ("e"):rep(1000),
                   name = ("n"):rep(1000), comment = ("c"):rep(1000) })
    local _, len = parseHeader(c)
    for _, chunk in ipairs({ 1, 7, 1000, 4096 }) do
        local d = zlib.decompressor({ format = "gzip" })
        local out = {}
        for i = 1, #c, chunk do
            out[#out + 1] = d:update(c:sub(i, i + chunk - 1))
        end
        out[#out + 1] = d:finish()
        assert(table.concat(out) == s)
    end
    local d = zlib.decompressor({ format = "auto" })
    local out, st, consumed = d:inflate(c .. "trailing")
    assert(out == s and st == zlib.Z_STREAM_END and consumed == #c)
    -- the header alone: no output yet, Z_OK
    d = zlib.decompressor({ format = "gzip" })
    out, st, consumed = d:inflate(c:sub(1, len))
    assert(out == "" and st == zlib.Z_OK and consumed == len)
    -- a wrong header CRC
    local bad = c:sub(1, len - 2) .. le16((u16(c, len - 1) + 1) % 65536) .. c:sub(len + 1)
    assertError("Error in inflate: header crc mismatch", zlib.decompress, bad, { format = "gzip" })
    -- the fields are not checked without FHCRC: a changed name decompresses
    local c2 = gz({ name = "abc" })
    assert(zlib.decompress((c2:gsub("abc", "xyz")), { format = "gzip" }) == s)
end
PRINT("==================================================================================")
do
    -- streaming: the same output as compress() for any chunk sizes, flushes
    local hdr = { os = 255, mtime = 42, text = true, hcrc = true, extra = "XY\4\0data",
                  name = "stream.txt", comment = "streamed" }
    local c = gz(hdr)
    for _, chunk in ipairs({ 1, 7, 1000, 65536 }) do
        local cs = zlib.compressor({ format = "gzip", gzipHeader = hdr })
        local out = {}
        for i = 1, #s, chunk do
            out[#out + 1] = cs:update(s:sub(i, i + chunk - 1))
        end
        out[#out + 1] = cs:finish()
        assert(table.concat(out) == c, chunk)
    end
    -- the first call returns the header at once, also for an empty chunk
    local cs = zlib.compressor({ format = "gzip", gzipHeader = hdr })
    local first = cs:update("")
    local _, len = parseHeader(c)
    assert(first == c:sub(1, len))
    local rest = cs:finish(s)
    assert(first .. rest == c)
    -- with flushes
    cs = zlib.compressor({ format = "gzip", gzipHeader = { name = "flushed" } })
    local out = { cs:flush("abc"), cs:flush("def", "full"), cs:finish("ghi") }
    local all = table.concat(out)
    assert(parseHeader(all).name == "flushed")
    assert(zlib.decompress(all, { format = "gzip" }) == "abcdefghi")
    -- the header strings are copied: the option table and its strings may be collected
    -- before the header is written, also when the header is written over many calls
    -- (memLevel 1: a small pending buffer, the long name needs many deflate() calls)
    local longName = ("long name "):rep(20000)
    cs = zlib.compressor({ format = "gzip", memLevel = 1,
                           gzipHeader = { name = longName .. "!", comment = ("c"):rep(50000) .. "!" } })
    collectgarbage("collect")
    collectgarbage("collect")
    out = {}
    for i = 1, #s, 100 do
        out[#out + 1] = cs:update(s:sub(i, i + 99))
        collectgarbage("step")
    end
    out[#out + 1] = cs:finish()
    all = table.concat(out)
    local h = parseHeader(all)
    assert(h.name == longName .. "!" and h.comment == ("c"):rep(50000) .. "!")
    assert(zlib.decompress(all, { format = "gzip" }) == s)
    -- a compressor that is not used releases its header (garbage collector)
    for _ = 1, 100 do
        zlib.compressor({ format = "gzip", gzipHeader = { name = ("x"):rep(10000) } })
    end
    collectgarbage("collect")
end
PRINT("==================================================================================")
do
    -- carrays for name, comment and extra
    local ok, carray = pcall(require, "carray")
    if not ok then
        print("carray module not available: test part skipped")
    else
        local function ca(str) return carray.new("char"):append(str) end
        local hdr = { name = "n.txt", comment = "comment", extra = "AB\2\0\0\1" }
        local c = gz(hdr)
        assert(gz({ name = ca(hdr.name), comment = ca(hdr.comment), extra = ca(hdr.extra) }) == c)
        assert(gz({ name = carray.new("uint8"):append(110, 46, 116, 120, 116), comment = "comment",
                    extra = carray.new("int8"):append(65, 66, 2, 0, 0, 1) }) == c)
        assert(parseHeader(gz({ name = ca("") })).name == "")
        assert(parseHeader(gz({ extra = carray.new("char") })).extra == "")
        local cs = zlib.compressor({ format = "gzip", gzipHeader = { name = ca(hdr.name),
                                     comment = ca(hdr.comment), extra = ca(hdr.extra) } })
        assert(cs:finish(s) == c)
        assertError("gzipHeader: name: carray elements must be 1 byte in size", gz,
                    { name = carray.new("int", 3) })
        assertError("gzipHeader: extra: carray elements must be 1 byte in size", gz,
                    { extra = carray.new("double", 1) })
        assertError("gzipHeader: comment must not contain NUL bytes", gz, { comment = ca("a\0b") })
        assertError("gzipHeader: extra too long (more than 65535 bytes)", gz,
                    { extra = carray.new("char", 65536) })
    end
end
PRINT("==================================================================================")
do
    -- errors
    assertError("gzipHeader is only supported for format 'gzip'", zlib.compress, s, { gzipHeader = {} })
    assertError("gzipHeader is only supported for format 'gzip'", zlib.compress, s,
                { format = "zlib", gzipHeader = { name = "x" } })
    assertError("gzipHeader is only supported for format 'gzip'", zlib.compress, s,
                { format = "raw", gzipHeader = {} })
    assertError("gzipHeader is only supported for format 'gzip'", zlib.compress, s,
                { windowBits = -15, gzipHeader = {} })
    assertError("gzipHeader is only supported for format 'gzip'", zlib.compressor, { gzipHeader = {} })
    assertError("bad argument #2 to", zlib.compress, s, { gzipHeader = {} })
    assertError("bad argument #1 to", zlib.compressor, { gzipHeader = "x" })
    assertError("option 'gzipHeader' is not supported by decompress()", zlib.decompress, plain,
                { gzipHeader = {} })
    assertError("option 'gzipHeader' is not supported by decompressor()", zlib.decompressor,
                { gzipHeader = {} })
    assertError("gzipHeader: table expected, got string", gz, "name")
    assertError("gzipHeader: table expected, got boolean", gz, true)
    assertError("gzipHeader: unknown field 'mtim'", gz, { mtim = 0 })
    assertError("gzipHeader: unknown field 'Name'", gz, { Name = "x" })
    assertError("gzipHeader: field names must be strings", gz, { "x" })
    assertError("gzipHeader: field names must be strings", gz, { [true] = 1 })
    for _, v in ipairs({ -1, 256, 1.5, "3", true }) do
        assertError("gzipHeader: invalid os value", gz, { os = v })
    end
    for _, v in ipairs({ -1, 2 ^ 32, 1.5, "0", false, 0 / 0, math.huge }) do
        assertError("gzipHeader: invalid mtime value", gz, { mtime = v })
    end
    for _, v in ipairs({ 1, 0, "yes", {} }) do
        assertError("gzipHeader: invalid text value", gz, { text = v })
        assertError("gzipHeader: invalid hcrc value", gz, { hcrc = v })
    end
    assertError("gzipHeader: name must not contain NUL bytes", gz, { name = "a\0b" })
    assertError("gzipHeader: name must not contain NUL bytes", gz, { name = "\0" })
    assertError("gzipHeader: comment must not contain NUL bytes", gz, { comment = "abc\0" })
    assertError("gzipHeader: name: string or carray expected, got table", gz, { name = {} })
    assertError("gzipHeader: comment: string or carray expected, got boolean", gz, { comment = true })
    assertError("gzipHeader: extra: string or carray expected, got function", gz, { extra = print })
    assertError("gzipHeader: extra too long (more than 65535 bytes)", gz, { extra = ("x"):rep(65536) })
    -- the other options are still checked
    assertError("invalid level value", zlib.compress, s, { format = "gzip", level = 10, gzipHeader = {} })
    assertError("dictionary is not supported for format 'gzip'", zlib.compress, s,
                { format = "gzip", dictionary = "d", gzipHeader = {} })
end
PRINT("==================================================================================")
print("OK.")
