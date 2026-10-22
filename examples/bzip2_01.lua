local bzip2 = require("compress.bzip2")

-- one call: the .bz2 format of the bzip2 tool
local text = string.rep("bzip2 compresses repetitive text very well. ", 1000)
local compressed = bzip2.compress(text)
assert(compressed:sub(1, 4) == "BZh9")                  -- block size 900 kB, as bzip2 -9
assert(bzip2.decompress(compressed) == text)

-- options: blockSize100k 1..9 (default 9, also as level), workFactor 0..250; the output
-- is that of "bzip2 -1" .. "bzip2 -9", and with blockSize100k = 1 that of Perl's
-- IO::Compress::Bzip2 and Compress::Raw::Bzip2 with their defaults
local small = bzip2.compress(text, { blockSize100k = 1 })
assert(bzip2.decompress(small, { small = true }) == text)   -- small: less memory, slower

-- limit the decompressed size (protection against compression bombs)
local ok, err = pcall(bzip2.decompress, compressed, { maxsize = 1000 })
assert(not ok and err == "output exceeds maxsize")

-- the status method decompressor:decompress() (also as bzinflate(), the name of Perl's
-- Compress::Raw::Bunzip2): no error is raised for the data, libbz2's status codes are
-- returned, and the number of bytes consumed shows where the stream ended
local data, status, consumed = bzip2.decompressor():bzinflate(compressed .. "more")
assert(data == text and status == bzip2.BZ_STREAM_END and consumed == #compressed)
local _, status2 = bzip2.decompressor():bzinflate("not bzip2 data")
assert(status2 == bzip2.BZ_DATA_ERROR_MAGIC)

-- concatenated .bz2 streams (as "cat a.bz2 b.bz2"; bzip2 -d decompresses all of them):
-- one decompressor per stream, consumed gives the start of the next one
local function decompressAll(input)
    local out, pos = {}, 1
    repeat
        local d = bzip2.decompressor()
        local o, st, n = d:decompress(input:sub(pos))
        if st ~= bzip2.BZ_STREAM_END then
            error(st == bzip2.BZ_OK and "unexpected end of input" or d:msg())
        end
        out[#out + 1] = o
        pos = pos + n
    until pos > #input
    return table.concat(out)
end
assert(decompressAll(compressed .. small) == text .. text)

-- streaming: data in pieces; flush() ends the current block (BZ_FLUSH), but libbz2
-- holds back its last bits: bzip2 data becomes completely decodable only with finish()
local c = bzip2.compressor({ level = 1 })
local parts = {}
for i = 1, 10 do
    parts[#parts + 1] = c:update("line " .. i .. "\n")   -- string, or nil if nothing yet
end
parts[#parts + 1] = c:finish()
local stream = table.concat(parts)

local dec = bzip2.decompressor()
local out = {}
for i = 1, #stream, 4 do
    out[#out + 1] = dec:update(stream:sub(i, i + 3))
end
out[#out + 1] = dec:finish()
assert(table.concat(out):match("^line 1\nline 2\n"))

-- carray objects are read without copying; a carray as last argument receives the output
-- in place: it is appended, and the carray is returned
local hasCarray, carray = pcall(require, "carray")
if hasCarray then
    local src = carray.new("char"):append(text)
    local buf = carray.new("char")
    assert(bzip2.compress(src, buf) == buf)             -- or bzip2.compress(src, opts, buf)
    local back = carray.new("char"):append("> ")
    bzip2.decompress(buf, back)
    assert(back:tostring() == "> " .. text)
    back:reset()                                        -- empty, keeps the capacity
    local d2 = bzip2.decompressor()
    d2:update(buf, back)                                -- stream methods: carray last
    d2:finish(nil, back)
    assert(back:tostring() == text)
end

print("compress.bzip2 " .. bzip2._VERSION .. ", libbz2 " .. bzip2.version() .. ": OK.")
