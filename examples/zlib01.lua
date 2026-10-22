local zlib = require("compress.zlib")

-- one call: zlib format (RFC 1950) by default, also gzip (RFC 1952) and raw deflate (RFC 1951)
local text = string.rep("zlib compresses repetitive text well. ", 1000)
local compressed = zlib.compress(text)
assert(#compressed < 200)
assert(zlib.decompress(compressed) == text)

local gz = zlib.compress(text, { format = "gzip", level = 9 })
assert(zlib.decompress(gz, { format = "auto" }) == text)       -- zlib or gzip, from the header
local raw = zlib.compress(text, { format = "raw" })
assert(zlib.decompress(raw, { format = "raw" }) == text)

-- the parameters of deflateInit2(); Perl's Compress::Zlib uses memLevel 9 (MAX_MEM_LEVEL):
-- with it the output is byte for byte the same as Perl's
local likePerl = zlib.compress(text, { level = 6, memLevel = zlib.MAX_MEM_LEVEL,
                                       strategy = zlib.Z_DEFAULT_STRATEGY })
assert(zlib.decompress(likePerl) == text)

-- limit the decompressed size (protection against compression bombs)
local ok, err = pcall(zlib.decompress, compressed, { maxsize = 1000 })
assert(not ok and err == "output exceeds maxsize")

-- streaming: data in pieces, with flushes
local c = zlib.compressor({ format = "gzip" })
local parts = {}
for i = 1, 10 do
    parts[#parts + 1] = c:update("line " .. i .. "\n")   -- string, or nil if nothing yet
    if i == 5 then
        parts[#parts + 1] = c:flush()                    -- Z_SYNC_FLUSH: all so far decodable
    end
end
parts[#parts + 1] = c:finish()
local stream = table.concat(parts)

local d = zlib.decompressor({ format = "gzip" })
local out = {}
for i = 1, #stream, 4 do
    out[#out + 1] = d:update(stream:sub(i, i + 3))
end
out[#out + 1] = d:finish()
assert(table.concat(out):match("^line 1\nline 2\n"))

-- the status method decompressor:decompress() (also as inflate(), the name of Perl's
-- Compress::Zlib): unlike zlib.decompress() no error is raised for the data, zlib's status
-- codes are returned, and the number of bytes consumed shows where the stream ended
local d2 = zlib.decompressor()
local data, status, consumed = d2:decompress(compressed .. "more data")
assert(data == text and status == zlib.Z_STREAM_END and consumed == #compressed)
local _, status2 = zlib.decompressor():inflate("not zlib data")   -- the same method
assert(status2 == zlib.Z_DATA_ERROR)

-- errors of the raising functions
local ok2, err2 = pcall(zlib.decompress, "not zlib data")
assert(not ok2 and err2 == "Error in inflate: incorrect header check")

-- checksums, also with a running value
assert(zlib.crc32("123456789") == 0xCBF43926)
assert(zlib.adler32("789", zlib.adler32("123456")) == zlib.adler32("123456789"))

-- carray objects are read without copying; a carray as last argument receives the output
-- in place: it is appended, and the carray is returned
local hasCarray, carray = pcall(require, "carray")
if hasCarray then
    local src = carray.new("char"):append(text)
    local buf = carray.new("char")
    assert(zlib.compress(src, buf) == buf)              -- or zlib.compress(src, opts, buf)
    local back = carray.new("char"):append("> ")
    zlib.decompress(buf, back)
    assert(back:tostring() == "> " .. text)
    -- reusing a carray: reset() empties it and keeps its capacity
    back:reset()
    zlib.decompress(buf, back)
    assert(back:tostring() == text)
    -- the stream methods take the carray as their last argument as well
    local c = zlib.compressor()
    buf:reset()
    c:update(src, buf)
    c:finish(nil, buf)                                -- nil: no last chunk
    assert(zlib.decompress(buf) == text)
end

print("compress.zlib " .. zlib._VERSION .. ", zlib " .. zlib.version() .. ": OK.")
