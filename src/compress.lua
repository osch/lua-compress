--[[
    compress - the meta module of lua-compress.

    Gives access to the compression modules of lua-compress under one name:
    compress.brotli is the module "compress.brotli", compress.zlib the module
    "compress.zlib", compress.lzma the module "compress.lzma", compress.bzip2 the
    module "compress.bzip2". A submodule is
    loaded with require() on its first access, so only the modules actually
    used are loaded; afterwards it is cached in this table.
    require("compress").brotli and require("compress.brotli") are the same
    object.

    Only the names of the modules of lua-compress are looked up (compress.names).
    Errors of require() (e.g. a module that is not installed) are raised on
    access. Any other key gives nil, as for an ordinary table.

    See doc/README.md.
--]]

local require      = require
local rawset       = rawset
local type         = type
local ipairs       = ipairs
local setmetatable = setmetatable

local compress = {}

compress._VERSION = "0.0.1"

-- the modules of lua-compress that this meta module loads, in this order also
-- documented in doc/README.md; the meta rock depends on all of them
compress.names = { "brotli", "zlib", "lzma", "bzip2" }

local known = {}
for _, name in ipairs(compress.names) do
    known[name] = true
end

setmetatable(compress, {
    __metatable = "compress",
    __index = function(self, key)
        if type(key) == "string" and known[key] then
            local module = require("compress." .. key)
            rawset(self, key, module)
            return module
        end
        return nil
    end,
})

return compress
