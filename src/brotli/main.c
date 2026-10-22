#include "../common/util.h"
#include "main.h"
#include "brotli.h"

#ifndef COMPRESS_BROTLI_VERSION
    #error COMPRESS_BROTLI_VERSION is not defined
#endif 

#define COMPRESS_BROTLI_STRINGIFY(x) #x
#define COMPRESS_BROTLI_TOSTRING(x) COMPRESS_BROTLI_STRINGIFY(x)
#define COMPRESS_BROTLI_VERSION_STRING COMPRESS_BROTLI_TOSTRING(COMPRESS_BROTLI_VERSION)

/* ============================================================================================ */

static const char* const COMPRESS_BROTLI_MODULE_NAME = "compress.brotli";

/* ============================================================================================ */


DLL_PUBLIC int luaopen_compress_brotli(lua_State* L)
{
    luaL_checkversion(L); /* does nothing if compiled for Lua 5.1 */

    /* ---------------------------------------- */

    int n = lua_gettop(L);
    
    int module      = ++n; lua_newtable(L);

    lua_pushliteral(L, COMPRESS_BROTLI_VERSION_STRING);
    lua_setfield(L, module, "_VERSION");
    
    luaL_checkstack(L, LUA_MINSTACK, NULL);
    
    compress_brotli_init_module(L, module);

    lua_newtable(L);                                   /* -> module meta */
    lua_pushstring(L, COMPRESS_BROTLI_MODULE_NAME);    /* -> module meta, "compress.brotli" */
    lua_setfield(L, -2, "__metatable");                /* -> module meta */
    lua_setmetatable(L, module);                       /* -> */
    
    lua_settop(L, module);

    return 1;
}

/* ============================================================================================ */
