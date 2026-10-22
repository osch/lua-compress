local brotli = require("compress.brotli")

-- one call: compress and decompress Lua strings
local text = string.rep("Brotli compresses repetitive text very well. ", 1000)
local compressed = brotli.compress(text)
assert(#compressed < 100)
assert(brotli.decompress(compressed) == text)

-- options: quality 0..11 (default 11), lgwin 10..24 (default 22), mode
local fast = brotli.compress(text, { quality = 1, lgwin = 16, mode = "text" })
assert(brotli.decompress(fast) == text)

-- limit the decompressed size (protection against compression bombs)
local ok, err = pcall(brotli.decompress, compressed, { maxsize = 1000 })
assert(not ok and err == "output exceeds maxsize")

-- streaming: data in pieces, without holding all of it in memory
local c = brotli.compressor({ quality = 5 })
local parts = {}
for i = 1, 10 do
    parts[#parts + 1] = c:update("line " .. i .. "\n")   -- string, or nil if nothing yet
end
parts[#parts + 1] = c:finish()
local stream = table.concat(parts)

local d = brotli.decompressor()
local out = {}
for i = 1, #stream, 4 do
    out[#out + 1] = d:update(stream:sub(i, i + 3))
end
out[#out + 1] = d:finish()
assert(table.concat(out):match("^line 1\nline 2\n"))

-- errors are raised with error()
local ok2, err2 = pcall(brotli.decompress, "not brotli")
assert(not ok2 and err2:match("^Error in BrotliDecoderDecompressStream: "))

-- the status method decompressor:decompress(): unlike brotli.decompress() no error is raised
-- for the data, libbrotli's result codes are returned, and the number of bytes consumed
-- shows where the stream ended
local d2 = brotli.decompressor()
local data, status, consumed = d2:decompress(compressed .. "more data")
assert(data == text and status == brotli.BROTLI_DECODER_RESULT_SUCCESS and consumed == #compressed)
local _, status2 = brotli.decompressor():decompress("not brotli")
assert(status2 == brotli.BROTLI_DECODER_RESULT_ERROR)

-- level is the common name of quality in lua-compress
assert(brotli.compress(text, { level = 5 }) == brotli.compress(text, { quality = 5 }))

-- carray objects are read without copying; a carray as last argument receives the output
-- in place: it is appended, and the carray is returned
local hasCarray, carray = pcall(require, "carray")
if hasCarray then
    local src = carray.new("char"):append(text)
    local buf = carray.new("char")
    assert(brotli.compress(src, buf) == buf)              -- or brotli.compress(src, opts, buf)
    local back = carray.new("char"):append("> ")
    brotli.decompress(buf, back)
    assert(back:tostring() == "> " .. text)
    -- reusing a carray: reset() empties it and keeps its capacity
    back:reset()
    brotli.decompress(buf, back)
    assert(back:tostring() == text)
    -- the stream methods take the carray as their last argument as well
    local c = brotli.compressor()
    buf:reset()
    c:update(src, buf)
    c:finish(nil, buf)                                -- nil: no last chunk
    assert(brotli.decompress(buf) == text)
end

print("compress.brotli " .. brotli._VERSION .. ", libbrotli " .. brotli.version() .. ": OK.")
