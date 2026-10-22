#ifndef COMPRESS_DATA_H
#define COMPRESS_DATA_H

/*
 * Input and output data of the modules of lua-compress: Lua strings and carrays.
 *
 * Shared as source by all modules (each module includes it in exactly one translation
 * unit): the functions are static, so the modules have no symbols in common and can
 * also be linked into the same program.
 *
 * Conventions (see doc/README.md, "Common Conventions"):
 *   - input data is a Lua string (or a number, as in the string library) or a carray
 *     with 1 byte elements, read directly from its buffer without copying;
 *   - output is a luaL_Buffer that becomes a Lua string, or a carray given as output
 *     target that the output is appended to, resized as needed and written directly.
 *
 * Functions that look up carrays need the CapiCache userdata as upvalue 1.
 */

#include "util.h"

#define CARRAY_CAPI_IMPLEMENT_GET_CAPI 1
#include "carray_capi.h"

#if defined(__GNUC__) || defined(__clang__)
#  define COMPRESS_UNUSED __attribute__((unused))
#else
#  define COMPRESS_UNUSED
#endif

/* ============================================================================================ */

/* output buffers grow at least by this amount (once more than the initial size is needed) */
#define CB_MIN_CHUNK   ((size_t)65536)

/* ============================================================================================ */

/*
 * Remembers the Carray C API of the last carray argument. Its toReadableCarray()
 * accepts any Lua value and returns NULL for everything that is not one of its
 * carrays, so it is tried first and the C API need not be looked up in the
 * metatable for each call. One per Lua state, an upvalue of all functions.
 */
typedef struct CapiCache
{
    const carray_capi* capi;
} CapiCache;

#define CAPI_CACHE  lua_upvalueindex(1)

/* pushes a new CapiCache userdata, returns its stack index */
static COMPRESS_UNUSED int pushCapiCache(lua_State* L)
{
    CapiCache* cc = (CapiCache*)lua_newuserdata(L, sizeof(CapiCache)); /* -> cc */
    memset(cc, 0, sizeof(CapiCache));
    return lua_gettop(L);
}

/* returns the carray at idx (and its C API in *capiOut), NULL if idx is no carray */
static COMPRESS_UNUSED const carray* toCarray(lua_State* L, int idx, const carray_capi** capiOut,
                                              carray_info* info)
{
    CapiCache*         cc   = (CapiCache*)lua_touserdata(L, CAPI_CACHE);
    const carray_capi* capi = cc->capi;
    const carray*      ca   = NULL;

    if (lua_type(L, idx) != LUA_TUSERDATA) {
        return NULL;
    }
    ca = capi ? capi->toReadableCarray(L, idx, info) : NULL;
    if (!ca) {
        capi = carray_get_capi(L, idx, NULL);
        if (capi) {
            ca = capi->toReadableCarray(L, idx, info);
            if (ca) {
                cc->capi = capi;
            }
        }
    }
    *capiOut = ca ? capi : NULL;
    return ca;
}

/* ============================================================================================ */

/*
 * Input data: a Lua string (or number, as in the string library) or a carray with 1 byte
 * elements, which is read directly from its buffer without copying. No Lua code runs
 * while the data is processed, so the pointer stays valid.
 */
typedef struct Input
{
    const uint8_t* ptr;
    size_t         len;
} Input;

/*
 * Reads the data at stack index idx into *in, returns 0 if it is neither a string, a
 * number nor a carray. Raises an error for carrays with elements of other sizes; what
 * is the prefix of the message (e.g. "dictionary: "), raised as argument error of arg.
 */
static COMPRESS_UNUSED int toInput(lua_State* L, int idx, int arg, const char* what, Input* in)
{
    int t = lua_type(L, idx);
    if (t == LUA_TSTRING || t == LUA_TNUMBER) {
        in->ptr = (const uint8_t*)lua_tolstring(L, idx, &in->len);
        return 1;
    }
    if (t == LUA_TUSERDATA) {
        const carray_capi* capi;
        carray_info        info;
        const carray*      ca = toCarray(L, idx, &capi, &info);
        if (ca) {
            if (info.elementSize != 1) {
                luaL_argerror(L, arg, lua_pushfstring(L, "%scarray elements must be 1 byte in size",
                                                         what));
            }
            in->len = info.elementCount;
            in->ptr = (in->len > 0) ? (const uint8_t*)capi->getReadableElementPtr(ca, 0, in->len)
                                    : (const uint8_t*)"";
            if (!in->ptr) {
                luaL_error(L, "cannot access carray");
            }
            return 1;
        }
    }
    return 0;
}

static COMPRESS_UNUSED void checkInput(lua_State* L, int arg, Input* in)
{
    if (!toInput(L, arg, arg, "", in)) {
        luaL_argerror(L, arg, lua_pushfstring(L, "string or carray expected, got %s",
                                                 luaL_typename(L, arg)));
    }
}

/* like checkInput, but none or nil give empty data */
static COMPRESS_UNUSED void optInput(lua_State* L, int arg, Input* in)
{
    if (lua_isnoneornil(L, arg)) {
        in->ptr = (const uint8_t*)"";
        in->len = 0;
    } else {
        checkInput(L, arg, in);
    }
}

/* ============================================================================================ */

/*
 * The optional arguments [opts][, out] of the one-shot functions, starting at arg: a
 * table (or nil) is opts, followed by the optional out; a userdata is out (no opts, so
 * f(data, out) is f(data, nil, out)). Anything else raises an argument error. Returns the
 * stack index of out, 0 if none; *optsArg is set to the index of opts, 0 if none.
 */
static COMPRESS_UNUSED int checkOptsOut(lua_State* L, int arg, int* optsArg)
{
    int t = lua_type(L, arg);
    if (t == LUA_TUSERDATA) {
        *optsArg = 0;
        return arg;
    }
    if (t != LUA_TNONE && t != LUA_TNIL && t != LUA_TTABLE) {
        luaL_argerror(L, arg, lua_pushfstring(L, "table or carray expected, got %s",
                                                 luaL_typename(L, arg)));
    }
    *optsArg = (t == LUA_TTABLE) ? arg : 0;
    return lua_isnoneornil(L, arg + 1) ? 0 : arg + 1;
}

/* the stack index of the optional out argument of a method at arg, 0 if none or nil */
static COMPRESS_UNUSED int optOut(lua_State* L, int arg)
{
    return lua_isnoneornil(L, arg) ? 0 : arg;
}

/* ============================================================================================ */

/* integer value at the top of the stack, returns 0 if it is not an integral number */
static COMPRESS_UNUSED int topInteger(lua_State* L, lua_Integer* v)
{
    int isnum = 0;
    if (lua_type(L, -1) == LUA_TNUMBER) {
        *v = lua_tointegerx(L, -1, &isnum);
        if (isnum && (lua_Number)*v != lua_tonumber(L, -1)) {
            isnum = 0;
        }
    }
    return isnum;
}

static COMPRESS_UNUSED size_t toSize(lua_Integer v)
{
#if defined(LLONG_MAX) && SIZE_MAX < LLONG_MAX
    if ((unsigned long long)v > (unsigned long long)SIZE_MAX) {
        return SIZE_MAX;
    }
#endif
    return (size_t)v;
}

/* ============================================================================================ */

/*
 * Output target: a luaL_Buffer that becomes a Lua string, or a carray (the out argument,
 * the last argument of a call) that the output is appended to. The carray's element
 * count is set to its capacity while writing, so existing capacity is reused without
 * reallocation; at the end it is set to its previous length plus the number of bytes
 * produced (the capacity is kept). On an error of a raising call the carray is set back
 * to its previous length (outDiscard): it keeps its previous content, nothing of the
 * failed call is appended.
 */
typedef struct Output
{
    luaL_Buffer        b;      /* string target */
    lua_State*         L;
    const carray_capi* capi;   /* carray target, NULL for a string target */
    carray*            ca;
    int                caIdx;
    uint8_t*           ptr;    /* carray buffer, cap bytes */
    size_t             cap;    /* current element count of the carray */
    size_t             base;   /* length of the carray before the call */
    size_t             len;    /* bytes produced (after base) */
} Output;

/*
 * Prepares the output: outIdx is the stack index of the carray target, 0 for a string
 * target. Errors of the carray are raised as argument errors of arg (the position of
 * the out argument); dataArg is the stack index of the input data (0 if none), which
 * must not be the carray. Must be called after everything else was pushed: a luaL_Buffer
 * needs the top of the stack.
 */
static COMPRESS_UNUSED void outInit(lua_State* L, Output* o, int outIdx, int arg, int dataArg)
{
    o->L    = L;
    o->capi = NULL;
    o->ca   = NULL;
    o->ptr  = NULL;
    o->cap  = 0;
    o->base = 0;
    o->len  = 0;
    if (outIdx) {
        const carray_capi* capi;
        carray_info        info;
        if (!toCarray(L, outIdx, &capi, &info)) {
            luaL_argerror(L, arg, lua_pushfstring(L, "out: carray expected, got %s",
                                                     luaL_typename(L, outIdx)));
        }
        if (dataArg && lua_rawequal(L, outIdx, dataArg)) {
            luaL_argerror(L, arg, "out: carray must not be the input data");
        }
        o->ca = capi->toWritableCarray(L, outIdx, &info);
        if (!o->ca) {
            luaL_argerror(L, arg, "out: carray is not writable");
        }
        if (info.elementSize != 1) {
            luaL_argerror(L, arg, "out: carray elements must be 1 byte in size");
        }
        o->capi  = capi;
        o->caIdx = outIdx;
        o->base  = info.elementCount;
        o->cap   = info.elementCount;
        if (info.elementCapacity > info.elementCount) {
            uint8_t* p = (uint8_t*)capi->resizeCarray(o->ca, info.elementCapacity, 0);
            if (p) {
                o->ptr = p;
                o->cap = info.elementCapacity;
            }
            /* else: not resizable (references foreign memory), outPrep() raises the error */
        } else if (info.elementCount > 0) {
            o->ptr = (uint8_t*)capi->getWritableElementPtr(o->ca, 0, info.elementCount);
        }
    } else {
        luaL_buffinit(L, &o->b);
    }
}

/* before raising an error: a carray target is set back to its previous length */
static COMPRESS_UNUSED void outDiscard(Output* o)
{
    if (o && o->capi && o->cap != o->base) {
        /* shrinking keeps the capacity and never fails */
        o->capi->resizeCarray(o->ca, o->base, 0);
        o->cap = o->base;
        o->len = 0;
    }
}

/* returns space for at least want bytes, its size in *space */
static COMPRESS_UNUSED uint8_t* outPrep(Output* o, size_t want, size_t* space)
{
    size_t used;
    if (!o->capi) {
        *space = want;
        return (uint8_t*)luaL_prepbuffsize(&o->b, want);
    }
    used = o->base + o->len;
    if (o->cap - used < want) {
        size_t   newCap = (want <= SIZE_MAX - used) ? used + want : SIZE_MAX;
        uint8_t* p;
        if (o->base > 0 && o->cap <= SIZE_MAX / 2 && newCap < 2 * o->cap) {
            /* appending to existing content: grow geometrically, so that many small
             * appends (stream methods) do not reallocate each time */
            newCap = 2 * o->cap;
        }
        p = (uint8_t*)o->capi->resizeCarray(o->ca, newCap, 0);
        if (!p) {
            /* not resizable (references foreign memory) or out of memory */
            outDiscard(o);
            luaL_error(o->L, "cannot resize carray");
        }
        o->ptr = p;
        o->cap = newCap;
    }
    *space = o->cap - used;
    return o->ptr + used;
}

static COMPRESS_UNUSED void outCommit(Output* o, size_t n)
{
    if (!o->capi) {
        luaL_addsize(&o->b, n);
    }
    o->len += n;
}

/* the size for the next outPrep(): the output so far doubles */
static COMPRESS_UNUSED size_t outGrow(const Output* o)
{
    return (o->len > CB_MIN_CHUNK) ? o->len : CB_MIN_CHUNK;
}

/* pushes the result: the string (nil if empty and emptyNil) or the carray */
static COMPRESS_UNUSED void outPush(Output* o, int emptyNil)
{
    if (o->capi) {
        size_t n = o->base + o->len;
        if (o->cap != n) {
            /* shrinking keeps the capacity and never fails */
            o->capi->resizeCarray(o->ca, n, 0);
            o->cap = n;
        }
        lua_pushvalue(o->L, o->caIdx);                                   /* -> carray */
    } else {
        luaL_pushresult(&o->b);                                          /* -> string */
        if (emptyNil && o->len == 0) {
            lua_pop(o->L, 1);                                            /* -> */
            lua_pushnil(o->L);                                           /* -> nil */
        }
    }
}

/* ============================================================================================ */

#endif /* COMPRESS_DATA_H */
