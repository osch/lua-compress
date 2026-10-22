-- Test helper for tests/*/test02.lua, not part of the lua-compress rocks.
-- Install from the repository root: luarocks make tests/compress_testcarray-scm-0.rockspec
package = "compress_testcarray"
version = "scm-0"
source = {
  url = "https://github.com/osch/lua-compress/archive/master.zip",
  dir = "lua-compress-master",
}
description = {
  summary = "Test helper for lua-compress: read-only and non-resizable carray objects",
  homepage = "https://github.com/osch/lua-compress",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
  "carray",
}
build = {
  type = "builtin",
  modules = {
    compress_testcarray = {
      sources = { "tests/testcarray.c" },
    },
  },
}
