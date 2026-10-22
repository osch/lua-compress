#include "../common/util.h"
#include "main.h"
#include "lzmamod.h"

#ifndef COMPRESS_LZMA_VERSION
    #error COMPRESS_LZMA_VERSION is not defined
#endif 

#define COMPRESS_LZMA_STRINGIFY(x) #x
#define COMPRESS_LZMA_TOSTRING(x) COMPRESS_LZMA_STRINGIFY(x)
#define COMPRESS_LZMA_VERSION_STRING COMPRESS_LZMA_TOSTRING(COMPRESS_LZMA_VERSION)

/* ============================================================================================ */

static const char* const COMPRESS_LZMA_MODULE_NAME = "compress.lzma";

/* ============================================================================================ */


DLL_PUBLIC int luaopen_compress_lzma(lua_State* L)
{
    luaL_checkversion(L); /* does nothing if compiled for Lua 5.1 */

    /* ---------------------------------------- */

    int n = lua_gettop(L);
    
    int module      = ++n; lua_newtable(L);

    lua_pushliteral(L, COMPRESS_LZMA_VERSION_STRING);
    lua_setfield(L, module, "_VERSION");
    
    luaL_checkstack(L, LUA_MINSTACK, NULL);
    
    compress_lzma_init_module(L, module);

    lua_newtable(L);                                   /* -> module meta */
    lua_pushstring(L, COMPRESS_LZMA_MODULE_NAME);    /* -> module meta, "compress.lzma" */
    lua_setfield(L, -2, "__metatable");                /* -> module meta */
    lua_setmetatable(L, module);                       /* -> */
    
    lua_settop(L, module);

    return 1;
}

/* ============================================================================================ */
