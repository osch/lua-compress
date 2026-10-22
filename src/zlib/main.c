#include "../common/util.h"
#include "main.h"
#include "zlibmod.h"

#ifndef COMPRESS_ZLIB_VERSION
    #error COMPRESS_ZLIB_VERSION is not defined
#endif 

#define COMPRESS_ZLIB_STRINGIFY(x) #x
#define COMPRESS_ZLIB_TOSTRING(x) COMPRESS_ZLIB_STRINGIFY(x)
#define COMPRESS_ZLIB_VERSION_STRING COMPRESS_ZLIB_TOSTRING(COMPRESS_ZLIB_VERSION)

/* ============================================================================================ */

static const char* const COMPRESS_ZLIB_MODULE_NAME = "compress.zlib";

/* ============================================================================================ */


DLL_PUBLIC int luaopen_compress_zlib(lua_State* L)
{
    luaL_checkversion(L); /* does nothing if compiled for Lua 5.1 */

    /* ---------------------------------------- */

    int n = lua_gettop(L);
    
    int module      = ++n; lua_newtable(L);

    lua_pushliteral(L, COMPRESS_ZLIB_VERSION_STRING);
    lua_setfield(L, module, "_VERSION");
    
    luaL_checkstack(L, LUA_MINSTACK, NULL);
    
    compress_zlib_init_module(L, module);

    lua_newtable(L);                                   /* -> module meta */
    lua_pushstring(L, COMPRESS_ZLIB_MODULE_NAME);    /* -> module meta, "compress.zlib" */
    lua_setfield(L, -2, "__metatable");                /* -> module meta */
    lua_setmetatable(L, module);                       /* -> */
    
    lua_settop(L, module);

    return 1;
}

/* ============================================================================================ */
