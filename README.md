# lua-compress 
[![Licence](http://img.shields.io/badge/Licence-MIT-brightgreen.svg)](LICENSE)
[![build status](https://github.com/osch/lua-compress/workflows/test/badge.svg)](https://github.com/osch/lua-compress/actions/workflows/test.yml)
[![Install](https://img.shields.io/badge/Install-LuaRocks-brightgreen.svg)](https://luarocks.org/modules/osch/compress)

<!-- ---------------------------------------------------------------------------------------- -->

Compression and decompression modules for [Lua], each based on the reference C library of
its format, all with the same API: in one call or as a stream, for Lua strings and 
[carray] objects. A carray is read directly from its buffer, without copying, and a carray
given as last argument of a call receives the output in place: it is appended.

| Module                                   | Format                     | C library                   |
|------------------------------------------|----------------------------|-----------------------------|
| [compress.brotli](./doc/brotli.md)       | Brotli                     | libbrotlidec, libbrotlienc  |
| [compress.zlib](./doc/zlib.md)           | zlib, gzip, raw deflate    | zlib                        |
| [compress.lzma](./doc/lzma.md)           | xz, lzma, raw LZMA1/LZMA2  | liblzma (XZ Utils)          |
| [compress.bzip2](./doc/bzip2.md)         | bzip2                      | libbz2                      |

Each module is a rock of its own that needs only its own C library; the meta rock 
*compress* installs all of them and the module *compress*, which loads them on first 
access: *require("compress").brotli* is *require("compress.brotli")*.

   * [Documentation](./doc/README.md#lua-compress-documentation)
   * [compress.brotli](./doc/brotli.md#compressbrotli-documentation)
   * [compress.zlib](./doc/zlib.md#compresszlib-documentation)
   * [compress.lzma](./doc/lzma.md#compresslzma-documentation)
   * [compress.bzip2](./doc/bzip2.md#compressbzip2-documentation)

[Lua]:          https://www.lua.org
[carray]:       https://github.com/osch/lua-carray

<!-- ---------------------------------------------------------------------------------------- -->

## First Example

 ```lua
local brotli = require("compress.brotli")    -- or: require("compress").brotli

-- one call: compress and decompress Lua strings
local text = string.rep("Brotli compresses repetitive text very well. ", 1000)
local compressed = brotli.compress(text)
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

local d = brotli.decompressor()
local out = {}
for _, part in ipairs(parts) do
    out[#out + 1] = d:update(part)
end
out[#out + 1] = d:finish()
assert(table.concat(out):match("^line 1\nline 2\n"))

-- carray objects are read without copying; a carray as last argument receives the output
-- in place: it is appended, and the carray is returned
local carray = require("carray")
local src = carray.new("char"):append(text)
local buf = carray.new("char")
assert(brotli.compress(src, { quality = 9 }, buf) == buf)
src:reset()                                -- empty, keeps the capacity for reuse
brotli.decompress(buf, src)
assert(src:tostring() == text)
local d2 = brotli.decompressor()
d2:update(buf, src)                        -- stream methods: the carray as last argument
d2:finish(nil, src)
assert(src:tostring() == text .. text)

-- compress.zlib has the same API, for the formats zlib, gzip and raw deflate
local zlib = require("compress.zlib")              -- or: require("compress").zlib
local gz = zlib.compress(text, { format = "gzip", level = 9 })
assert(zlib.decompress(gz, { format = "auto" }) == text)
-- decompressor:decompress() is the variant of update() that raises no errors for the data
-- but returns the library's status codes, e.g. zlib's (also as inflate(), as in Perl)
local out, status, consumed = zlib.decompressor():decompress(zlib.compress(text) .. "trailing")
assert(out == text and status == zlib.Z_STREAM_END)

-- compress.lzma: xz (default), lzma and raw LZMA1/LZMA2, e.g. the LZMA1 streams of 7z
-- archives with their 5 property bytes; code() is decompress() under Perl's name
local lzma = require("compress.lzma")              -- or: require("compress").lzma
assert(lzma.decompress(lzma.compress(text, { preset = 9 })) == text)
local props = lzma.properties({ filter = "lzma1" })
local raw = lzma.compress(text, { format = "raw", filter = "lzma1" })
local d3 = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props })
assert(d3:code(raw) == text)

-- compress.bzip2: the .bz2 format; level is blockSize100k (1..9, default 9 as bzip2 -9),
-- bzinflate() is decompress() under Perl's name
local bzip2 = require("compress.bzip2")            -- or: require("compress").bzip2
local bz = bzip2.compress(text, { level = 1 })     -- the output of bzip2 -1 and of Perl
assert(bzip2.decompressor():bzinflate(bz) == text)
```

<!-- ---------------------------------------------------------------------------------------- -->

## Installation

```
luarocks install compress            # all modules and the meta module compress
luarocks install compress.brotli     # only compress.brotli
luarocks install compress.zlib       # only compress.zlib
luarocks install compress.lzma       # only compress.lzma
luarocks install compress.bzip2      # only compress.bzip2
```

compress.brotli needs the Brotli libraries *libbrotlidec* and *libbrotlienc*, 
compress.zlib the zlib library, compress.lzma liblzma of XZ Utils, compress.bzip2 libbz2.
The modules work with Lua 5.1 up to 5.5 and LuaJIT; [carray] is optional. For building 
from source and libraries in non-standard locations (MinGW, MSVC) see 
[Building](./doc/README.md#building).

<!-- ---------------------------------------------------------------------------------------- -->
