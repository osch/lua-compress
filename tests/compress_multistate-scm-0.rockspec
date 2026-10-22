-- Test helper for tests/*/test03.lua, not part of the lua-compress rocks.
-- Install from the repository root: luarocks make tests/compress_multistate-scm-0.rockspec
package = "compress_multistate"
version = "scm-0"
source = {
  url = "https://github.com/osch/lua-compress/archive/master.zip",
  dir = "lua-compress-master",
}
description = {
  summary = "Test helper for lua-compress: independent Lua states and parallel threads",
  homepage = "https://github.com/osch/lua-compress",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
}
build = {
  type = "builtin",
  modules = {
    compress_multistate = {
      sources = { "tests/multistate.c" },
    },
  },
  platforms = {
    unix = {
      modules = {
        compress_multistate = {
          libraries = { "pthread" },
        },
      },
    },
  },
}
