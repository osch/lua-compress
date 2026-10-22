local lzma = require("compress.lzma")

-- one call: xz format by default, also the legacy .lzma format and raw LZMA1/LZMA2 streams
local text = string.rep("LZMA compresses repetitive text very well. ", 1000)
local compressed = lzma.compress(text)
assert(#compressed < 200)
assert(lzma.decompress(compressed) == text)

-- options: preset 0..9 (default 6, also as level), extreme, check, the LZMA options
local fast = lzma.compress(text, { preset = 1, check = "crc32" })
assert(lzma.decompress(fast) == text)
local old = lzma.compress(text, { format = "lzma", preset = 9, extreme = true })
assert(lzma.decompress(old, { format = "auto" }) == text)       -- xz or lzma, from the header

-- raw LZMA1, as 7z archives store it: the 5 property bytes (lc/lp/pb, dictionary size) are
-- kept apart from the data; lzma.properties() gives them for the options of the encoder
local opts = { format = "raw", filter = "lzma1", dictSize = 65536, lc = 3, lp = 0, pb = 2 }
local raw = lzma.compress(text, opts)
local props = lzma.properties({ filter = "lzma1", dictSize = 65536 })
assert(props == "\93\0\0\1\0")
assert(lzma.decompress(raw, { format = "raw", filter = "lzma1", properties = props }) == text)

-- the status method decompressor:decompress() (also as code(), the name of Perl's
-- Compress::Raw::Lzma): no error is raised for the data, liblzma's status codes are
-- returned, and the number of bytes consumed shows where the stream ended. A raw LZMA1
-- stream of 7z has no end marker: the status stays LZMA_OK; the option size (the unpack
-- size of the 7z folder) makes the decoder stop exactly there with LZMA_STREAM_END.
local d = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props })
local data, status, consumed = d:code(raw)
assert(data == text and status == lzma.LZMA_STREAM_END and consumed == #raw)  -- ours has one
local _, status2 = lzma.decompressor():code(string.rep("not xz data", 2))
assert(status2 == lzma.LZMA_FORMAT_ERROR)

-- limit the decompressed size (protection against compression bombs) and the memory
local ok, err = pcall(lzma.decompress, compressed, { maxsize = 1000 })
assert(not ok and err == "output exceeds maxsize")
local ok2, err2 = pcall(lzma.decompress, old, { format = "lzma", memlimit = 1024 * 1024 })
assert(not ok2 and err2 == "Error in lzma_code: Memory usage limit reached")

-- streaming: data in pieces, with flushes (xz: "sync", "full", "barrier")
local c = lzma.compressor({ preset = 3 })
local parts = {}
for i = 1, 10 do
    parts[#parts + 1] = c:update("line " .. i .. "\n")   -- string, or nil if nothing yet
    if i == 5 then
        parts[#parts + 1] = c:flush()                    -- LZMA_SYNC_FLUSH: all so far decodable
    end
end
parts[#parts + 1] = c:finish()
local stream = table.concat(parts)

local dec = lzma.decompressor()
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
    assert(lzma.compress(src, buf) == buf)              -- or lzma.compress(src, opts, buf)
    local back = carray.new("char"):append("> ")
    lzma.decompress(buf, back)
    assert(back:tostring() == "> " .. text)
    back:reset()                                        -- empty, keeps the capacity
    local d2 = lzma.decompressor()
    d2:update(buf, back)                                -- stream methods: carray last
    d2:finish(nil, back)
    assert(back:tostring() == text)
end

print("compress.lzma " .. lzma._VERSION .. ", liblzma " .. lzma.version() .. ": OK.")
