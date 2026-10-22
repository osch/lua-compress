#include "../common/util.h"
#include "main.h"
#include "bzip2mod.h"

#ifndef COMPRESS_BZIP2_VERSION
    #error COMPRESS_BZIP2_VERSION is not defined
#endif 

#define COMPRESS_BZIP2_STRINGIFY(x) #x
#define COMPRESS_BZIP2_TOSTRING(x) COMPRESS_BZIP2_STRINGIFY(x)
#define COMPRESS_BZIP2_VERSION_STRING COMPRESS_BZIP2_TOSTRING(COMPRESS_BZIP2_VERSION)

/* ============================================================================================ */

static const char* const COMPRESS_BZIP2_MODULE_NAME = "compress.bzip2";

/* ============================================================================================ */


DLL_PUBLIC int luaopen_compress_bzip2(lua_State* L)
{
    luaL_checkversion(L); /* does nothing if compiled for Lua 5.1 */

    /* ---------------------------------------- */

    int n = lua_gettop(L);
    
    int module      = ++n; lua_newtable(L);

    lua_pushliteral(L, COMPRESS_BZIP2_VERSION_STRING);
    lua_setfield(L, module, "_VERSION");
    
    luaL_checkstack(L, LUA_MINSTACK, NULL);
    
    compress_bzip2_init_module(L, module);

    lua_newtable(L);                                   /* -> module meta */
    lua_pushstring(L, COMPRESS_BZIP2_MODULE_NAME);    /* -> module meta, "compress.bzip2" */
    lua_setfield(L, -2, "__metatable");                /* -> module meta */
    lua_setmetatable(L, module);                       /* -> */
    
    lua_settop(L, module);

    return 1;
}

/* ============================================================================================ */
