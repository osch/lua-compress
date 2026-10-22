-- The meta module compress: all modules of lua-compress under one name, each
-- loaded on its first access.
local compress = require("compress")

-- compress.brotli is the module "compress.brotli", loaded on first access
local brotli = compress.brotli
assert(brotli == require("compress.brotli"))

local text = string.rep("lua-compress: one API for several compression libraries. ", 500)
local packed = brotli.compress(text, { quality = 9 })
assert(brotli.decompress(packed) == text)

-- compress.zlib likewise
local zlib = compress.zlib
assert(zlib == require("compress.zlib"))
assert(zlib.decompress(zlib.compress(text, { format = "gzip" }), { format = "gzip" }) == text)

-- and compress.lzma
local lzma = compress.lzma
assert(lzma == require("compress.lzma"))
assert(lzma.decompress(lzma.compress(text, { preset = 1 })) == text)

-- and compress.bzip2
local bzip2 = compress.bzip2
assert(bzip2 == require("compress.bzip2"))
assert(bzip2.decompress(bzip2.compress(text, { level = 1 })) == text)

-- the module names this version knows; any other key gives nil
for _, name in ipairs(compress.names) do
    assert(compress[name] == require("compress." .. name))
end
assert(compress.unknown == nil)

print("compress " .. compress._VERSION .. " (" .. table.concat(compress.names, ", ") .. "): OK.")
