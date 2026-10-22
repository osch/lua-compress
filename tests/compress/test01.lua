-- The meta module compress: lazy loading of the submodules, identity with the
-- modules loaded directly, behaviour for unknown keys.

local format = string.format

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end

PRINT("==================================================================================")
do
    -- nothing is loaded before the first access
    package.loaded["compress.brotli"] = nil
    package.loaded["compress.zlib"] = nil
    package.loaded["compress.lzma"] = nil
    package.loaded["compress.bzip2"] = nil
    local compress = require("compress")
    PRINT(format("compress %s, submodules: %s", compress._VERSION, table.concat(compress.names, ", ")))
    assert(type(compress._VERSION) == "string" and compress._VERSION:match("^%d+%.%d+%.%d+$"))
    assert(getmetatable(compress) == "compress")
    assert(rawget(compress, "brotli") == nil)
    assert(package.loaded["compress.brotli"] == nil)
    assert(rawget(compress, "zlib") == nil)
    assert(package.loaded["compress.zlib"] == nil)

    -- the first access loads the module with require() and caches it
    local brotli = compress.brotli
    assert(type(brotli) == "table")
    assert(rawget(compress, "brotli") == brotli)
    assert(package.loaded["compress.brotli"] == brotli)
    assert(require("compress.brotli") == brotli)
    assert(compress.brotli == brotli)
    assert(require("compress").brotli == require("compress.brotli"))
    assert(brotli.decompress(brotli.compress("meta")) == "meta")
end
PRINT("==================================================================================")
do
    -- the same for compress.zlib
    local compress = require("compress")
    local zlib = compress.zlib
    assert(type(zlib) == "table")
    assert(rawget(compress, "zlib") == zlib)
    assert(package.loaded["compress.zlib"] == zlib)
    assert(require("compress").zlib == require("compress.zlib"))
    assert(zlib.decompress(zlib.compress("meta")) == "meta")
end
PRINT("==================================================================================")
do
    -- the same for compress.lzma
    local compress = require("compress")
    assert(rawget(compress, "lzma") == nil)
    assert(package.loaded["compress.lzma"] == nil)
    local lzma = compress.lzma
    assert(type(lzma) == "table")
    assert(rawget(compress, "lzma") == lzma)
    assert(package.loaded["compress.lzma"] == lzma)
    assert(require("compress").lzma == require("compress.lzma"))
    assert(lzma.decompress(lzma.compress("meta")) == "meta")
end
PRINT("==================================================================================")
do
    -- the same for compress.bzip2
    local compress = require("compress")
    assert(rawget(compress, "bzip2") == nil)
    assert(package.loaded["compress.bzip2"] == nil)
    local bzip2 = compress.bzip2
    assert(type(bzip2) == "table")
    assert(rawget(compress, "bzip2") == bzip2)
    assert(package.loaded["compress.bzip2"] == bzip2)
    assert(require("compress").bzip2 == require("compress.bzip2"))
    assert(bzip2.decompress(bzip2.compress("meta")) == "meta")
    local names = table.concat(compress.names, ",")
    assert(names == "brotli,zlib,lzma,bzip2", names)
end
PRINT("==================================================================================")
do
    -- every listed name is a module of the same name
    local compress = require("compress")
    for _, name in ipairs(compress.names) do
        assert(compress[name] == require("compress." .. name), name)
    end
end
PRINT("==================================================================================")
do
    -- other keys give nil, as for an ordinary table, and are not looked up
    local compress = require("compress")
    assert(compress.foo == nil)
    assert(compress.Brotli == nil)
    assert(compress[1] == nil)
    assert(compress[true] == nil)
    assert(package.loaded["compress.foo"] == nil)
end
PRINT("==================================================================================")
do
    -- errors of require() are raised on access: a listed module that cannot be found
    local compress = require("compress")
    local saved = package.loaded["compress.brotli"]
    rawset(compress, "brotli", nil)
    package.loaded["compress.brotli"] = nil
    local savedPreload = package.preload["compress.brotli"]
    package.preload["compress.brotli"] = function() error("test: load failure") end
    local ok, err = pcall(function() return compress.brotli end)
    assert(not ok and tostring(err):find("test: load failure", 1, true))
    assert(rawget(compress, "brotli") == nil)
    package.preload["compress.brotli"] = savedPreload
    package.loaded["compress.brotli"] = saved
    assert(compress.brotli == saved)
end
PRINT("==================================================================================")
print("OK.")
