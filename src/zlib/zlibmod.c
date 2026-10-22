#define ZLIB_CONST
#include <zlib.h>

#include "../common/data.h"
#include "zlibmod.h"

#ifndef z_const
#  define z_const   /* zlib before 1.2.5.2 */
#endif

/* ============================================================================================ */

const char* const ZLIB_DECOMPRESSOR_CLASS_NAME = "compress.zlib.decompressor";
const char* const ZLIB_COMPRESSOR_CLASS_NAME   = "compress.zlib.compressor";

/* ============================================================================================ */

/* maxsize when no limit is given */
#define CZ_NO_LIMIT    SIZE_MAX

/* avail_in and avail_out of zlib are 32 bit (uInt): larger data is processed in pieces */
#define CZ_MAX_UINT    ((size_t)(uInt)-1)

/* the default memLevel of zlib (DEF_MEM_LEVEL in zutil.h, not exported) */
#if MAX_MEM_LEVEL >= 8
#  define CZ_DEF_MEM_LEVEL 8
#else
#  define CZ_DEF_MEM_LEVEL MAX_MEM_LEVEL
#endif

#define MSG_MAXSIZE         "output exceeds maxsize"
#define MSG_END_OF_INPUT    "unexpected end of input"
#define MSG_TRAILING        "unexpected data after end of stream"

/* ============================================================================================ */

#define FMT_NONE   0   /* not given */
#define FMT_ZLIB   1
#define FMT_GZIP   2
#define FMT_RAW    3
#define FMT_AUTO   4   /* inflate: zlib or gzip, from the header */

#define OPT_FORMAT    0x0001
#define OPT_LEVEL     0x0002
#define OPT_METHOD    0x0004
#define OPT_WBITS     0x0008
#define OPT_MEMLEVEL  0x0010
#define OPT_STRATEGY  0x0020
#define OPT_DICT      0x0040
#define OPT_MAXSIZE   0x0080
#define OPT_OUT       0x0100   /* the former option out: never allowed, see optionError() */
#define OPT_TRAILING  0x0200
#define OPT_GZHEADER  0x0400

#define OPTS_DEFLATE  (OPT_FORMAT | OPT_LEVEL | OPT_METHOD | OPT_WBITS | OPT_MEMLEVEL \
                       | OPT_STRATEGY | OPT_DICT | OPT_GZHEADER)
#define OPTS_INFLATE  (OPT_FORMAT | OPT_WBITS | OPT_DICT | OPT_MAXSIZE | OPT_TRAILING)

/*
 * The option gzipHeader: the fields for deflateSetHeader(). The strings are read from
 * values that checkOptions() leaves on the stack; the deflater copies them.
 */
typedef struct GzipHeader
{
    int         given;
    int         text;
    int         hcrc;
    int         os;            /* -1: not given, zlib's default (OS_CODE) */
    uLong       mtime;
    Input       name;          /* ptr NULL: not given */
    Input       comment;
    Input       extra;
} GzipHeader;

typedef struct Options
{
    int         format;
    int         level;
    int         method;
    int         wbits;         /* option windowBits as given, wbitsGiven: if given */
    int         wbitsGiven;
    int         memLevel;
    int         strategy;
    int         windowBits;    /* computed: the value for deflateInit2()/inflateInit2() */
    int         raw;           /* computed: raw deflate */
    Input       dict;          /* dictionary, dictGiven: if given */
    int         dictGiven;
    size_t      maxsize;
    int         allowTrailing;
    GzipHeader  gz;            /* gzipHeader, gz.given: if given */
} Options;

static int checkIntOption(lua_State* L, int arg, lua_Integer min, lua_Integer max, const char* msg)
{
    lua_Integer v;
    if (!topInteger(L, &v) || v < min || v > max) {
        luaL_argerror(L, arg, msg);
    }
    return (int)v;
}

/* a boolean field of gzipHeader at the top of the stack */
static int checkGzipBool(lua_State* L, int arg, const char* field)
{
    if (lua_type(L, -1) != LUA_TBOOLEAN) {
        luaL_argerror(L, arg, lua_pushfstring(L, "gzipHeader: invalid %s value", field));
    }
    return lua_toboolean(L, -1);
}

/*
 * A string field (name, comment, extra) of the gzipHeader table at index t: the value
 * stays on the stack while it is used. nul: NUL bytes are not allowed; maxLen: limit.
 */
static void checkGzipString(lua_State* L, int arg, int t, const char* field, int nul,
                            size_t maxLen, Input* in)
{
    lua_getfield(L, t, field);                                          /* -> value */
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);                                                  /* -> */
        in->ptr = NULL;
        in->len = 0;
        return;
    }
    lua_pushfstring(L, "gzipHeader: %s: ", field);                      /* -> value, prefix */
    if (!toInput(L, -2, arg, lua_tostring(L, -1), in)) {
        luaL_argerror(L, arg, lua_pushfstring(L, "gzipHeader: %s: string or carray expected, got %s",
                                                 field, luaL_typename(L, -2)));
    }
    lua_pop(L, 1);                                                      /* -> value */
    if (!nul && memchr(in->ptr, 0, in->len)) {
        luaL_argerror(L, arg, lua_pushfstring(L, "gzipHeader: %s must not contain NUL bytes", field));
    }
    if (in->len > maxLen) {
        luaL_argerror(L, arg, lua_pushfstring(L, "gzipHeader: %s too long (more than %d bytes)", field, (int)maxLen));
    }
    /* the value stays on the stack */
}

/* reads the gzipHeader table at index t into *gz */
static void checkGzipHeader(lua_State* L, int arg, int t, GzipHeader* gz)
{
    if (lua_type(L, t) != LUA_TTABLE) {
        luaL_argerror(L, arg, lua_pushfstring(L, "gzipHeader: table expected, got %s",
                                                 luaL_typename(L, t)));
    }
    gz->given = 1;
    lua_pushnil(L);                                                     /* -> key */
    while (lua_next(L, t)) {                                            /* -> key, value */
        const char* name = (lua_type(L, -2) == LUA_TSTRING) ? lua_tostring(L, -2) : NULL;
        if (!name) {
            luaL_argerror(L, arg, "gzipHeader: field names must be strings");
        }
        if (strcmp(name, "os") == 0) {
            lua_Integer v;
            if (!topInteger(L, &v) || v < 0 || v > 255) {
                luaL_argerror(L, arg, "gzipHeader: invalid os value");
            }
            gz->os = (int)v;
        } else if (strcmp(name, "mtime") == 0) {
            /* read as number: 0..0xFFFFFFFF also with a 32 bit lua_Integer */
            lua_Number v = (lua_type(L, -1) == LUA_TNUMBER) ? lua_tonumber(L, -1) : -1;
            if (!(v >= 0 && v <= 4294967295.0) || v != (lua_Number)(unsigned long)v) {
                luaL_argerror(L, arg, "gzipHeader: invalid mtime value");
            }
            gz->mtime = (uLong)v;
        } else if (strcmp(name, "text") == 0) {
            gz->text = checkGzipBool(L, arg, "text");
        } else if (strcmp(name, "hcrc") == 0) {
            gz->hcrc = checkGzipBool(L, arg, "hcrc");
        } else if (strcmp(name, "name") != 0 && strcmp(name, "comment") != 0
                   && strcmp(name, "extra") != 0) {
            luaL_argerror(L, arg, lua_pushfstring(L, "gzipHeader: unknown field '%s'", name));
        }
        lua_pop(L, 1);                                                  /* -> key */
    }                                                                   /* -> */
    /* the strings stay on the stack (-> name, comment, extra, as far as given) */
    checkGzipString(L, arg, t, "name",    0, SIZE_MAX,       &gz->name);
    checkGzipString(L, arg, t, "comment", 0, SIZE_MAX,       &gz->comment);
    checkGzipString(L, arg, t, "extra",   1, 65535,          &gz->extra);
}

/*
 * Computes o->windowBits and o->raw from the options format and windowBits. windowBits
 * may select the format as in zlib (negative: raw, 16 + n: gzip, 32 + n: auto); then a
 * format option must not contradict it.
 */
static void computeWindowBits(lua_State* L, int arg, int inflate, Options* o)
{
    int fmt = FMT_NONE;
    int w   = MAX_WBITS;
    if (o->wbitsGiven) {
        int v = o->wbits;
        if      (v < 0)             { fmt = FMT_RAW;  w = -v; }
        else if (v >= 32 && inflate) { fmt = FMT_AUTO; w = v - 32; }
        else if (v >= 16)           { fmt = FMT_GZIP; w = v - 16; }
        else                        { w = v; }
        if (fmt != FMT_NONE && o->format != FMT_NONE && fmt != o->format) {
            luaL_argerror(L, arg, "windowBits contradicts format");
        }
    }
    if (fmt == FMT_NONE) {
        fmt = (o->format != FMT_NONE) ? o->format : FMT_ZLIB;
    }
    /* 0: inflate takes the window size from the zlib header (not possible for raw) */
    if (w > MAX_WBITS || (w < 8 && !(w == 0 && inflate && fmt != FMT_RAW))) {
        luaL_argerror(L, arg, "invalid windowBits value");
    }
    o->format = fmt;
    o->raw    = (fmt == FMT_RAW);
    switch (fmt) {
        case FMT_GZIP: o->windowBits = w + 16; break;
        case FMT_RAW:  o->windowBits = -w;     break;
        case FMT_AUTO: o->windowBits = w + 32; break;
        default:       o->windowBits = w;      break;
    }
}

/*
 * Raises the error for an option that is not valid for the function func: an option of
 * the module that func does not support (opt != 0), an unknown name, or a key that is
 * no string.
 */
static void optionError(lua_State* L, int arg, const char* func, const char* name, unsigned opt)
{
    if (!name) {
        luaL_argerror(L, arg, "option names must be strings");
    }
    if (opt == 0) {
        luaL_argerror(L, arg, lua_pushfstring(L, "unknown option '%s'", name));
    }
    if (opt == OPT_OUT) {
        /* the output carray is an argument of its own, the last one of every call */
        luaL_argerror(L, arg, "option 'out' is no longer supported: "
                              "pass the carray as the last argument");
    }
    luaL_argerror(L, arg, lua_pushfstring(L, "option '%s' is not supported by %s()", name, func));
}

/*
 * Reads the options table at arg (nil or absent: defaults). allowed is the set of
 * options valid for the calling function func (its name for error messages); arg 0:
 * no options. opts.dictionary and opts.gzipHeader are pushed onto the stack, so that they
 * stay referenced.
 */
static void checkOptions(lua_State* L, int arg, const char* func, unsigned allowed, Options* o)
{
    int t       = arg ? lua_type(L, arg) : LUA_TNONE;
    int inflate = !(allowed & OPT_LEVEL);

    o->format     = FMT_NONE;
    o->level      = Z_DEFAULT_COMPRESSION;
    o->method     = Z_DEFLATED;
    o->wbits      = MAX_WBITS;
    o->wbitsGiven = 0;
    o->memLevel   = CZ_DEF_MEM_LEVEL;
    o->strategy   = Z_DEFAULT_STRATEGY;
    o->dictGiven  = 0;
    o->dict.ptr   = NULL;
    o->dict.len   = 0;
    o->maxsize    = CZ_NO_LIMIT;
    o->allowTrailing = 0;
    memset(&o->gz, 0, sizeof(o->gz));
    o->gz.os      = -1;

    if (t != LUA_TNONE && t != LUA_TNIL) {
        if (t != LUA_TTABLE) {
            luaL_argerror(L, arg, lua_pushfstring(L, "table expected, got %s", luaL_typename(L, arg)));
        }
        lua_pushnil(L);                                                 /* -> key */
        while (lua_next(L, arg)) {                                      /* -> key, value */
            const char* name = (lua_type(L, -2) == LUA_TSTRING) ? lua_tostring(L, -2) : NULL;
            unsigned    opt  = 0;
            lua_Integer v;
            if (name) {
                if      (strcmp(name, "format")     == 0) opt = OPT_FORMAT;
                else if (strcmp(name, "level")      == 0) opt = OPT_LEVEL;
                else if (strcmp(name, "method")     == 0) opt = OPT_METHOD;
                else if (strcmp(name, "windowBits") == 0) opt = OPT_WBITS;
                else if (strcmp(name, "memLevel")   == 0) opt = OPT_MEMLEVEL;
                else if (strcmp(name, "strategy")   == 0) opt = OPT_STRATEGY;
                else if (strcmp(name, "dictionary") == 0) opt = OPT_DICT;
                else if (strcmp(name, "maxsize")    == 0) opt = OPT_MAXSIZE;
                else if (strcmp(name, "out")        == 0) opt = OPT_OUT;
                else if (strcmp(name, "allowtrailing") == 0) opt = OPT_TRAILING;
                else if (strcmp(name, "gzipHeader") == 0) opt = OPT_GZHEADER;
            }
            if (!(opt & allowed)) {
                optionError(L, arg, func, name, opt);
            }
            switch (opt) {
                case OPT_FORMAT: {
                    const char* f = (lua_type(L, -1) == LUA_TSTRING) ? lua_tostring(L, -1) : "";
                    if      (strcmp(f, "zlib") == 0) o->format = FMT_ZLIB;
                    else if (strcmp(f, "gzip") == 0) o->format = FMT_GZIP;
                    else if (strcmp(f, "raw")  == 0) o->format = FMT_RAW;
                    else if (strcmp(f, "auto") == 0 && inflate) o->format = FMT_AUTO;
                    else luaL_argerror(L, arg, "invalid format value");
                    break;
                }
                case OPT_LEVEL:
                    o->level = checkIntOption(L, arg, Z_DEFAULT_COMPRESSION, Z_BEST_COMPRESSION,
                                              "invalid level value");
                    break;
                case OPT_METHOD:
                    o->method = checkIntOption(L, arg, Z_DEFLATED, Z_DEFLATED, "invalid method value");
                    break;
                case OPT_WBITS:
                    o->wbits = checkIntOption(L, arg, -MAX_WBITS, inflate ? 32 + MAX_WBITS : 16 + MAX_WBITS,
                                              "invalid windowBits value");
                    o->wbitsGiven = 1;
                    break;
                case OPT_MEMLEVEL:
                    o->memLevel = checkIntOption(L, arg, 1, MAX_MEM_LEVEL, "invalid memLevel value");
                    break;
                case OPT_STRATEGY:
                    o->strategy = checkIntOption(L, arg, Z_DEFAULT_STRATEGY, Z_FIXED,
                                                 "invalid strategy value");
                    break;
                case OPT_MAXSIZE:
                    if (!topInteger(L, &v) || v < 0) {
                        luaL_argerror(L, arg, "invalid maxsize value");
                    }
                    o->maxsize = toSize(v);
                    break;
                case OPT_TRAILING:
                    if (lua_type(L, -1) != LUA_TBOOLEAN) {
                        luaL_argerror(L, arg, "invalid allowtrailing value");
                    }
                    o->allowTrailing = lua_toboolean(L, -1);
                    break;
                default: /* OPT_DICT, OPT_GZHEADER, handled below */
                    break;
            }
            lua_pop(L, 1);                                              /* -> key */
        }                                                               /* -> */
        if (allowed & OPT_DICT) {
            lua_getfield(L, arg, "dictionary");                         /* -> dict */
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);                                          /* -> */
            } else {
                if (!toInput(L, -1, arg, "dictionary: ", &o->dict)) {
                    luaL_argerror(L, arg, lua_pushfstring(L, "dictionary: string or carray expected, got %s",
                                                             luaL_typename(L, -1)));
                }
                o->dictGiven = 1;                                       /* dict stays on the stack */
            }
        }
        if (allowed & OPT_GZHEADER) {
            lua_getfield(L, arg, "gzipHeader");                         /* -> gzh */
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);                                          /* -> */
            } else {
                /* the table and its strings stay on the stack */
                checkGzipHeader(L, arg, lua_gettop(L), &o->gz);
            }
        }
    }
    computeWindowBits(L, arg, inflate, o);
    if (o->dictGiven && o->format == FMT_GZIP) {
        luaL_argerror(L, arg, "dictionary is not supported for format 'gzip'");
    }
    if (o->gz.given && o->format != FMT_GZIP) {
        luaL_argerror(L, arg, "gzipHeader is only supported for format 'gzip'");
    }
}

/* ============================================================================================ */

/*
 * Native inflate or deflate state, owned by a userdata with __gc: the state is also
 * released if a Lua error (e.g. out of memory) interrupts a call. The one-shot
 * functions use such a userdata too and release the state before they return.
 */
typedef struct Coder
{
    z_stream    z;
    int         kind;          /* which zlib state is initialized: K_NONE, K_INFLATE, K_DEFLATE */
    int         status;
    size_t      total;         /* inflate: bytes produced so far */
    size_t      maxsize;       /* inflate: limit for total */
    int         allowTrailing; /* inflate: ignore data after the end */
    int         failed;        /* inflate: 0, or the status of an error that ends the stream
                                  although zlib's state could go on (maxsize, dictionary) */
    uint8_t*    dict;          /* inflate: dictionary for Z_NEED_DICT (copy) */
    size_t      dictLen;
    const char* msgFunc;       /* the C function and message of the last error, NULL if none */
    const char* msg;
    gz_header   gz;            /* deflate: the gzip header given to deflateSetHeader(), */
    uint8_t*    gzBuf;         /*   and its strings (one allocation), kept for the stream */
} Coder;

#define K_NONE     0
#define K_INFLATE  1
#define K_DEFLATE  2

#define ST_OPEN    0   /* ready for more data */
#define ST_BUSY    1   /* inside a call; still set if that call was aborted by a Lua error */
#define ST_DONE    2   /* decompressor: end of the stream reached */
#define ST_CLOSED  3   /* native state released: finished or failed */

static void releaseCoder(Coder* c)
{
    if (c->kind == K_INFLATE) {
        inflateEnd(&c->z);
    } else if (c->kind == K_DEFLATE) {
        deflateEnd(&c->z);
    }
    c->kind = K_NONE;
    if (c->dict) {
        free(c->dict);
        c->dict = NULL;
    }
    if (c->gzBuf) {
        free(c->gzBuf);
        c->gzBuf = NULL;
    }
    c->status = ST_CLOSED;
}

static Coder* pushCoder(lua_State* L, const char* className)
{
    Coder* c = (Coder*)lua_newuserdata(L, sizeof(Coder));                /* -> coder */
    memset(c, 0, sizeof(Coder));
    c->z.zalloc = Z_NULL;
    c->z.zfree  = Z_NULL;
    c->z.opaque = Z_NULL;
    c->status   = ST_CLOSED;
    c->maxsize  = CZ_NO_LIMIT;
    luaL_setmetatable(L, className);
    return c;
}

/* raises "Error in <func>: <message of ret>" for a failed init, the coder stays closed */
static int failInit(lua_State* L, Coder* c, const char* func, int ret)
{
    const char* m = c->z.msg ? c->z.msg : zError(ret);
    releaseCoder(c);
    return luaL_error(L, "Error in %s: %s", func, m);
}

static Coder* newInflater(lua_State* L, int optsArg, const Options* o)
{
    Coder* c = pushCoder(L, ZLIB_DECOMPRESSOR_CLASS_NAME);              /* -> coder */
    int    ret;

    c->z.next_in  = Z_NULL;
    c->z.avail_in = 0;
    ret = inflateInit2(&c->z, o->windowBits);
    if (ret == Z_STREAM_ERROR) {
        luaL_argerror(L, optsArg, "invalid windowBits value");
    }
    if (ret != Z_OK) {
        failInit(L, c, "inflateInit2", ret);
    }
    c->kind          = K_INFLATE;
    c->maxsize       = o->maxsize;
    c->allowTrailing = o->allowTrailing;
    if (o->dictGiven) {
        if (o->raw) {
            /* raw deflate has no header that asks for it: set it now, as Compress::Raw::Zlib */
            ret = inflateSetDictionary(&c->z, (const Bytef*)o->dict.ptr, (uInt)o->dict.len);
            if (ret != Z_OK) {
                failInit(L, c, "inflateSetDictionary", ret);
            }
        } else if (o->dict.len > 0) {
            c->dict = (uint8_t*)malloc(o->dict.len);
            if (!c->dict) {
                releaseCoder(c);
                luaL_error(L, "not enough memory");
            }
            memcpy(c->dict, o->dict.ptr, o->dict.len);
            c->dictLen = o->dict.len;
        } else {
            /* the empty dictionary: Z_NEED_DICT is answered with it */
            c->dict = (uint8_t*)malloc(1);
            if (!c->dict) {
                releaseCoder(c);
                luaL_error(L, "not enough memory");
            }
            c->dictLen = 0;
        }
    }
    c->status = ST_OPEN;
    return c;
}

/*
 * The operating system code that zlib writes into its default gzip header (OS_CODE of
 * zlib's build, not exported): read from the header of an empty stream. Returns -1 if
 * zlib's state cannot be created.
 */
static int defaultOsCode(void)
{
    z_stream z;
    Bytef    out[64];
    int      ret, os = -1;

    memset(&z, 0, sizeof(z));
    /* the smallest state: window 512 bytes, memLevel 1 */
    if (deflateInit2(&z, 1, Z_DEFLATED, 16 + 9, 1, Z_DEFAULT_STRATEGY) != Z_OK) {
        return -1;
    }
    z.next_in   = (z_const Bytef*)"";
    z.avail_in  = 0;
    z.next_out  = out;
    z.avail_out = (uInt)sizeof(out);
    ret = deflate(&z, Z_FINISH);
    if (ret == Z_STREAM_END && sizeof(out) - z.avail_out >= 10) {
        os = out[9];
    }
    deflateEnd(&z);
    return os;
}

/* copies the string s into p (with a terminating NUL), returns the copy */
static Bytef* copyGzipString(uint8_t** p, const Input* s)
{
    Bytef* r = (Bytef*)*p;
    if (s->len > 0) {
        memcpy(*p, s->ptr, s->len);
    }
    (*p)[s->len] = 0;
    *p += s->len + 1;
    return r;
}

/* sets the gzip header of the option gzipHeader (after deflateInit2()) */
static void setGzipHeader(lua_State* L, Coder* c, const GzipHeader* g)
{
    const Input* str[3];
    size_t       total = 0;
    int          i, ret;
    uint8_t*     p;

    str[0] = &g->name;
    str[1] = &g->comment;
    str[2] = &g->extra;
    for (i = 0; i < 3; ++i) {
        if (str[i]->ptr) {
            if (str[i]->len > SIZE_MAX - 1 - total) {
                releaseCoder(c);
                luaL_error(L, "not enough memory");
            }
            total += str[i]->len + 1;
        }
    }
    memset(&c->gz, 0, sizeof(c->gz));
    c->gz.text = g->text;
    c->gz.hcrc = g->hcrc;
    c->gz.time = g->mtime;
    c->gz.os   = g->os;
    if (c->gz.os < 0) {
        c->gz.os = defaultOsCode();
        if (c->gz.os < 0) {
            releaseCoder(c);
            luaL_error(L, "Error in deflateInit2: %s", zError(Z_MEM_ERROR));
        }
    }
    if (total > 0) {
        c->gzBuf = (uint8_t*)malloc(total);
        if (!c->gzBuf) {
            releaseCoder(c);
            luaL_error(L, "not enough memory");
        }
        p = c->gzBuf;
        if (g->name.ptr) {
            c->gz.name = copyGzipString(&p, &g->name);
        }
        if (g->comment.ptr) {
            c->gz.comment = copyGzipString(&p, &g->comment);
        }
        if (g->extra.ptr) {
            c->gz.extra     = copyGzipString(&p, &g->extra);
            c->gz.extra_len = (uInt)g->extra.len;
        }
    }
    ret = deflateSetHeader(&c->z, &c->gz);
    if (ret != Z_OK) {
        failInit(L, c, "deflateSetHeader", ret);
    }
}

static Coder* newDeflater(lua_State* L, int optsArg, const Options* o)
{
    Coder* c = pushCoder(L, ZLIB_COMPRESSOR_CLASS_NAME);                /* -> coder */
    int    ret;

    ret = deflateInit2(&c->z, o->level, o->method, o->windowBits, o->memLevel, o->strategy);
    if (ret == Z_STREAM_ERROR) {
        /* all other parameters are checked: zlib rejects this windowBits (8 for raw/gzip) */
        luaL_argerror(L, optsArg, "invalid windowBits value");
    }
    if (ret != Z_OK) {
        failInit(L, c, "deflateInit2", ret);
    }
    c->kind = K_DEFLATE;
    if (o->dictGiven) {
        if (o->dict.len > CZ_MAX_UINT) {
            releaseCoder(c);
            luaL_argerror(L, optsArg, "dictionary too large");
        }
        ret = deflateSetDictionary(&c->z, (const Bytef*)o->dict.ptr, (uInt)o->dict.len);
        if (ret != Z_OK) {
            failInit(L, c, "deflateSetDictionary", ret);
        }
    }
    if (o->gz.given) {
        setGzipHeader(L, c, &o->gz);
    }
    c->status = ST_OPEN;
    return c;
}

/* checks that the stream object at index 1 may be used */
static Coder* checkStream(lua_State* L, const char* className, const char* what)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, className);
    if (c->status == ST_BUSY) {
        /* a previous call was aborted by a Lua error: the state is undefined */
        releaseCoder(c);
    }
    if (c->status == ST_CLOSED) {
        luaL_error(L, "%s is closed", what);
    }
    return c;
}

/* ============================================================================================ */

/* releases the state, resets a carray target and raises the message on top of the stack */
static int failTop(lua_State* L, Coder* c, Output* o)
{
    releaseCoder(c);
    outDiscard(o);
    return lua_error(L);
}

/* raises the last error recorded in the coder */
static int failCoder(lua_State* L, Coder* c, Output* o)
{
    outDiscard(o);
    if (c->msgFunc) {
        lua_pushfstring(L, "Error in %s: %s", c->msgFunc, c->msg);
    } else {
        lua_pushstring(L, c->msg);
    }
    return failTop(L, c, o);
}

/* records an error of zlib's function func with status ret */
static void setError(Coder* c, const char* func, int ret)
{
    c->msgFunc = func;
    c->msg     = c->z.msg ? c->z.msg : zError(ret);
}

/* ============================================================================================ */

/*
 * Feeds the input to inflate() until all of it is consumed, the stream ends or an error
 * occurs. Raises no error of its own (only Lua errors of the output, e.g. out of memory).
 * Returns zlib's status: Z_OK (all input consumed, the stream goes on), Z_STREAM_END
 * (*consumed: the input bytes up to the end of the stream) or an error status with
 * the message recorded in the coder. maxsize: no more than maxsize bytes are written to
 * the output; if the stream has more, Z_BUF_ERROR is returned and c->failed set.
 */
static int runInflate(Coder* c, const Input* in, Output* o, size_t want, size_t* consumed)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;
    int            ret;
    uint8_t        extra[1];

    c->status = ST_BUSY;
    for (;;) {
        size_t   space, ain, used, produced;
        uint8_t* p;
        int      overflow = 0;
        if (c->maxsize != CZ_NO_LIMIT) {
            size_t left = c->maxsize - c->total;
            if (left == 0) {
                /* the limit is reached: is there more output? */
                overflow = 1;
            } else if (want > left) {
                want = left;
            }
        }
        if (overflow) {
            p     = extra;
            space = 1;
        } else {
            p = outPrep(o, want, &space);
            if (c->maxsize != CZ_NO_LIMIT && space > want) {
                space = want;   /* a carray target may have more space: keep to maxsize */
            }
            if (space > CZ_MAX_UINT) {
                space = CZ_MAX_UINT;
            }
        }
        ain = (avail > CZ_MAX_UINT) ? CZ_MAX_UINT : avail;
        c->z.next_in   = (z_const Bytef*)next;
        c->z.avail_in  = (uInt)ain;
        c->z.next_out  = (Bytef*)p;
        c->z.avail_out = (uInt)space;
        ret = inflate(&c->z, Z_NO_FLUSH);
        used     = ain - c->z.avail_in;
        produced = space - c->z.avail_out;
        next  += used;
        avail -= used;
        if (overflow) {
            if (produced > 0) {
                c->msgFunc = NULL;
                c->msg     = MSG_MAXSIZE;
                c->failed  = Z_BUF_ERROR;
                ret        = Z_BUF_ERROR;
                break;
            }
        } else {
            outCommit(o, produced);
            c->total += produced;
        }
        if (ret == Z_NEED_DICT && c->dict) {
            int r2 = inflateSetDictionary(&c->z, (const Bytef*)c->dict, (uInt)c->dictLen);
            if (r2 != Z_OK) {
                c->msgFunc = "inflateSetDictionary";
                c->msg     = "incorrect dictionary";
                c->failed  = Z_DATA_ERROR;
                ret        = Z_DATA_ERROR;
                break;
            }
            continue;
        }
        if (ret != Z_OK && ret != Z_BUF_ERROR) {
            /* Z_STREAM_END, or an error: Z_NEED_DICT, Z_DATA_ERROR, Z_MEM_ERROR, ... */
            if (ret != Z_STREAM_END) {
                setError(c, "inflate", ret);
            }
            break;
        }
        if (c->z.avail_out == 0) {
            if (!overflow) {
                want = outGrow(o);
            }
            continue;
        }
        if (avail > 0 && (used > 0 || produced > 0)) {
            continue;   /* the next piece of more than 4 GB of input */
        }
        if (avail > 0) {
            setError(c, "inflate", Z_BUF_ERROR);   /* no progress, not expected */
            ret = Z_BUF_ERROR;
            break;
        }
        ret = Z_OK;     /* all input consumed, more is expected */
        break;
    }
    *consumed = in->len - avail;
    if (ret == Z_STREAM_END) {
        c->status = ST_DONE;
    } else {
        c->status = ST_OPEN;
    }
    return ret;
}

/*
 * The raising variant for update/finish/decompress: an error closes the coder. Returns
 * 1 at the end of the stream (after checking for trailing data), 0 if more input is
 * expected.
 */
static int inflateOrFail(lua_State* L, Coder* c, const Input* in, Output* o, size_t want)
{
    size_t consumed;
    int    ret = runInflate(c, in, o, want, &consumed);
    if (ret == Z_STREAM_END) {
        if (consumed < in->len && !c->allowTrailing) {
            c->msgFunc = "inflate";
            c->msg     = MSG_TRAILING;
            failCoder(L, c, o);
        }
        return 1;
    }
    if (ret != Z_OK) {
        failCoder(L, c, o);
    }
    return 0;
}

static int failEndOfInput(lua_State* L, Coder* c, Output* o)
{
    c->msgFunc = "inflate";
    c->msg     = MSG_END_OF_INPUT;
    return failCoder(L, c, o);
}

/*
 * Feeds the input to deflate() with the given flush mode until all input is consumed
 * and all output is taken (for Z_FINISH: until the stream is finished).
 */
static void runDeflate(lua_State* L, Coder* c, const Input* in, Output* o, int flush, size_t want)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;

    c->status = ST_BUSY;
    for (;;) {
        size_t   space, ain, used;
        uint8_t* p = outPrep(o, want, &space);
        int      fl, ret;
        if (space > CZ_MAX_UINT) {
            space = CZ_MAX_UINT;
        }
        ain = (avail > CZ_MAX_UINT) ? CZ_MAX_UINT : avail;
        fl  = (ain < avail) ? Z_NO_FLUSH : flush;    /* the flush with the last piece */
        c->z.next_in   = (z_const Bytef*)next;
        c->z.avail_in  = (uInt)ain;
        c->z.next_out  = (Bytef*)p;
        c->z.avail_out = (uInt)space;
        ret = deflate(&c->z, fl);
        used   = ain - c->z.avail_in;
        next  += used;
        avail -= used;
        outCommit(o, space - c->z.avail_out);
        if (ret == Z_STREAM_ERROR) {
            setError(c, "deflate", ret);
            failCoder(L, c, o);
        }
        if (ret == Z_STREAM_END) {
            break;
        }
        if (c->z.avail_out == 0) {
            want = outGrow(o);
            continue;
        }
        /* output space left: this piece is consumed (and flushed) */
        if (avail > 0) {
            continue;
        }
        if (fl != Z_FINISH || ret == Z_BUF_ERROR) {
            break;
        }
    }
    c->status = ST_OPEN;
}

/* initial output size for decompressing n bytes */
static size_t decompressGuess(size_t n)
{
    size_t g = (n <= SIZE_MAX / 4) ? n * 4 : n;
    return (g > LUAL_BUFFERSIZE) ? g : LUAL_BUFFERSIZE;
}

/* initial output size for compressing n bytes in one go */
static size_t compressGuess(Coder* c, int level, size_t n)
{
    if (level == 0) {
        /* stored blocks depend on the output space: one call with deflateBound() space,
         * as compress2() does */
        if (n < (size_t)((uLong)-1 / 2)) {
            return (size_t)deflateBound(&c->z, (uLong)n);
        }
        return n + n / 1000 + 1024;
    }
    return n / 4 + 1024;
}

/* ============================================================================================ */
/* module functions                                                                             */
/* ============================================================================================ */

/* compress.zlib.decompress(data [, opts] [, out]) */
static int Zlib_decompress(lua_State* L)
{
    Input   in;
    Options opt;
    Output  o;
    Coder*  c;
    int     optsArg;
    int     outArg;

    checkInput(L, 1, &in);
    outArg = checkOptsOut(L, 2, &optsArg);
    checkOptions(L, optsArg, "decompress", OPTS_INFLATE, &opt);
    c = newInflater(L, 2, &opt);
    outInit(L, &o, outArg, outArg, 1);

    if (!inflateOrFail(L, c, &in, &o, decompressGuess(in.len))) {
        failEndOfInput(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.zlib.compress(data [, opts] [, out]) */
static int Zlib_compress(lua_State* L)
{
    Input   in;
    Options opt;
    Output  o;
    Coder*  c;
    int     optsArg;
    int     outArg;

    checkInput(L, 1, &in);
    outArg = checkOptsOut(L, 2, &optsArg);
    checkOptions(L, optsArg, "compress", OPTS_DEFLATE, &opt);
    c = newDeflater(L, 2, &opt);
    outInit(L, &o, outArg, outArg, 1);

    runDeflate(L, c, &in, &o, Z_FINISH, compressGuess(c, opt.level, in.len));
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.zlib.decompressor([opts]) */
static int Zlib_decompressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "decompressor", OPTS_INFLATE, &opt);
    newInflater(L, 1, &opt);
    return 1;
}

/* compress.zlib.compressor([opts]) */
static int Zlib_compressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "compressor", OPTS_DEFLATE, &opt);
    newDeflater(L, 1, &opt);
    return 1;
}

/* compress.zlib.version() -> zlib version at runtime, zlib version compiled against */
static int Zlib_version(lua_State* L)
{
    lua_pushstring(L, zlibVersion());
    lua_pushstring(L, ZLIB_VERSION);
    return 2;
}

/* a checksum argument: an integer 0..0xFFFFFFFF (read as number, also for Lua 5.1/5.2) */
static uLong checkChecksum(lua_State* L, int arg, uLong dflt)
{
    lua_Number v;
    if (lua_isnoneornil(L, arg)) {
        return dflt;
    }
    if (lua_type(L, arg) != LUA_TNUMBER) {
        luaL_argerror(L, arg, lua_pushfstring(L, "number expected, got %s", luaL_typename(L, arg)));
    }
    v = lua_tonumber(L, arg);
    if (!(v >= 0 && v <= 4294967295.0) || v != (lua_Number)(unsigned long)v) {
        luaL_argerror(L, arg, "invalid checksum value");
    }
    return (uLong)v;
}

static void pushChecksum(lua_State* L, uLong v)
{
#if LUA_VERSION_NUM >= 503
    lua_pushinteger(L, (lua_Integer)v);
#else
    lua_pushnumber(L, (lua_Number)v);     /* lua_Integer may have 32 bits */
#endif
}

/* compress.zlib.crc32(data [, crc]) */
static int Zlib_crc32(lua_State* L)
{
    Input in;
    uLong v;
    checkInput(L, 1, &in);
    v = checkChecksum(L, 2, crc32(0L, Z_NULL, 0));
    while (in.len > 0) {
        size_t n = (in.len > CZ_MAX_UINT) ? CZ_MAX_UINT : in.len;
        v = crc32(v, (const Bytef*)in.ptr, (uInt)n);
        in.ptr += n;
        in.len -= n;
    }
    pushChecksum(L, v);
    return 1;
}

/* compress.zlib.adler32(data [, adler]) */
static int Zlib_adler32(lua_State* L)
{
    Input in;
    uLong v;
    checkInput(L, 1, &in);
    v = checkChecksum(L, 2, adler32(0L, Z_NULL, 0));
    while (in.len > 0) {
        size_t n = (in.len > CZ_MAX_UINT) ? CZ_MAX_UINT : in.len;
        v = adler32(v, (const Bytef*)in.ptr, (uInt)n);
        in.ptr += n;
        in.len -= n;
    }
    pushChecksum(L, v);
    return 1;
}

/* ============================================================================================ */
/* decompressor methods                                                                         */
/* ============================================================================================ */

#define DEC_WHAT "decompressor"
#define ENC_WHAT "compressor"

static int failTrailing(lua_State* L, Coder* c, Output* o)
{
    c->msgFunc = "inflate";
    c->msg     = MSG_TRAILING;
    return failCoder(L, c, o);
}

/* decompressor:update(chunk [, out]) -> string or nil, or out */
static int Decompressor_update(lua_State* L)
{
    Coder* c = checkStream(L, ZLIB_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
    Input  in;
    Output o;

    checkInput(L, 2, &in);
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    if (c->failed) {
        failCoder(L, c, &o);
    }
    if (c->status == ST_DONE) {
        if (in.len > 0 && !c->allowTrailing) {
            failTrailing(L, c, &o);
        }
    } else {
        inflateOrFail(L, c, &in, &o, decompressGuess(in.len));
    }
    outPush(&o, 1);
    return 1;
}

/* decompressor:finish([chunk [, out]]) -> string, or out */
static int Decompressor_finish(lua_State* L)
{
    Coder* c = checkStream(L, ZLIB_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
    Input  in;
    Output o;

    optInput(L, 2, &in);
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    if (c->failed) {
        failCoder(L, c, &o);
    }
    if (c->status == ST_DONE) {
        if (in.len > 0 && !c->allowTrailing) {
            failTrailing(L, c, &o);
        }
    } else if (!inflateOrFail(L, c, &in, &o, decompressGuess(in.len))) {
        failEndOfInput(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/*
 * decompressor:decompress(chunk [, out]) -> output, status, consumed
 * (also as decompressor:inflate, the name of Compress::Zlib / Compress::Raw::Zlib)
 *
 * Raises no error for the data: the status tells the caller, as for Compress::Zlib's
 * ($out, $status) = $i->inflate($in). output is a string ("" if there is none), or out.
 */
static int Decompressor_decompress(lua_State* L)
{
    Coder* c = checkStream(L, ZLIB_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
    Input  in;
    Output o;
    size_t consumed = 0;
    int    ret;

    checkInput(L, 2, &in);
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    if (c->failed) {
        ret = c->failed;
    } else if (c->status == ST_DONE) {
        /* zlib's inflate() gives Z_STREAM_END again and consumes nothing */
        ret = Z_STREAM_END;
    } else {
        ret = runInflate(c, &in, &o, decompressGuess(in.len), &consumed);
    }
    outPush(&o, 0);
    lua_pushinteger(L, ret);
    lua_pushinteger(L, (lua_Integer)consumed);
    return 3;
}

/* decompressor:msg() -> message of the last error, or nil */
static int Decompressor_msg(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, ZLIB_DECOMPRESSOR_CLASS_NAME);
    if (c->msg) {
        lua_pushstring(L, c->msg);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

/* ============================================================================================ */
/* compressor methods                                                                           */
/* ============================================================================================ */

/* compressor:update/flush/finish: chunk at 2, the optional out at outArg */
static int compressorOp(lua_State* L, int flush, int chunkOptional, int outArg)
{
    Coder* c = checkStream(L, ZLIB_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    Input  in;
    Output o;

    if (chunkOptional) {
        optInput(L, 2, &in);
    } else {
        checkInput(L, 2, &in);
    }
    lua_settop(L, outArg);
    outInit(L, &o, optOut(L, outArg), outArg, 2);
    runDeflate(L, c, &in, &o, flush, LUAL_BUFFERSIZE);
    if (flush == Z_FINISH) {
        releaseCoder(c);
    }
    outPush(&o, flush != Z_FINISH);
    return 1;
}

/* compressor:update(chunk [, out]) -> string or nil, or out */
static int Compressor_update(lua_State* L)
{
    return compressorOp(L, Z_NO_FLUSH, 0, 3);
}

/*
 * compressor:flush([chunk [, mode] [, out]]) -> string or nil (string for Z_FINISH), or
 * out. A carray (userdata) at 3 is out, else 3 is the mode and 4 out.
 */
static int Compressor_flush(lua_State* L)
{
    int flush = Z_SYNC_FLUSH;
    int t     = lua_type(L, 3);
    if (t == LUA_TUSERDATA) {
        return compressorOp(L, flush, 1, 3);
    }
    if (t == LUA_TSTRING) {
        const char* m = lua_tostring(L, 3);
        if      (strcmp(m, "sync")    == 0) flush = Z_SYNC_FLUSH;
        else if (strcmp(m, "full")    == 0) flush = Z_FULL_FLUSH;
        else if (strcmp(m, "block")   == 0) flush = Z_BLOCK;
        else if (strcmp(m, "partial") == 0) flush = Z_PARTIAL_FLUSH;
        else if (strcmp(m, "finish")  == 0) flush = Z_FINISH;
        else luaL_argerror(L, 3, "invalid flush mode");
    } else if (t == LUA_TNUMBER) {
        lua_Integer v;
        lua_pushvalue(L, 3);
        if (!topInteger(L, &v) || v < Z_NO_FLUSH || v > Z_BLOCK) {
            luaL_argerror(L, 3, "invalid flush mode");
        }
        lua_pop(L, 1);
        flush = (int)v;
    } else if (t != LUA_TNONE && t != LUA_TNIL) {
        luaL_argerror(L, 3, "invalid flush mode");
    }
    return compressorOp(L, flush, 1, 4);
}

/* compressor:finish([chunk [, out]]) -> string, or out */
static int Compressor_finish(lua_State* L)
{
    return compressorOp(L, Z_FINISH, 1, 3);
}

/* ============================================================================================ */

static int Coder_release(lua_State* L)
{
    Coder* c = (Coder*)lua_touserdata(L, 1);
    if (c) {
        releaseCoder(c);
    }
    return 0;
}

static int Decompressor_toString(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, ZLIB_DECOMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", ZLIB_DECOMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

static int Compressor_toString(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, ZLIB_COMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", ZLIB_COMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

/* ============================================================================================ */

static const luaL_Reg ModuleFunctions[] =
{
    { "decompress",   Zlib_decompress     },
    { "compress",     Zlib_compress       },
    { "decompressor", Zlib_decompressor   },
    { "compressor",   Zlib_compressor     },
    { "crc32",        Zlib_crc32          },
    { "adler32",      Zlib_adler32        },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg PlainModuleFunctions[] =
{
    { "version",      Zlib_version        },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg DecompressorMethods[] =
{
    { "update",       Decompressor_update  },
    { "finish",       Decompressor_finish  },
    { "decompress",   Decompressor_decompress },   /* also as "inflate", see below */
    { "msg",          Decompressor_msg     },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg DecompressorMetaMethods[] =
{
    { "__tostring",   Decompressor_toString },
    { "__gc",         Coder_release         },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg CompressorMethods[] =
{
    { "update",       Compressor_update    },
    { "flush",        Compressor_flush     },
    { "finish",       Compressor_finish    },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg CompressorMetaMethods[] =
{
    { "__tostring",   Compressor_toString  },
    { "__gc",         Coder_release        },
    { NULL,           NULL } /* sentinel */
};

/* the constants of zlib.h with zlib's values */
typedef struct Constant
{
    const char* name;
    int         value;
} Constant;

static const Constant Constants[] =
{
    /* status codes */
    { "Z_OK",                  Z_OK                  },
    { "Z_STREAM_END",          Z_STREAM_END          },
    { "Z_NEED_DICT",           Z_NEED_DICT           },
    { "Z_ERRNO",               Z_ERRNO               },
    { "Z_STREAM_ERROR",        Z_STREAM_ERROR        },
    { "Z_DATA_ERROR",          Z_DATA_ERROR          },
    { "Z_MEM_ERROR",           Z_MEM_ERROR           },
    { "Z_BUF_ERROR",           Z_BUF_ERROR           },
    { "Z_VERSION_ERROR",       Z_VERSION_ERROR       },
    /* flush modes */
    { "Z_NO_FLUSH",            Z_NO_FLUSH            },
    { "Z_PARTIAL_FLUSH",       Z_PARTIAL_FLUSH       },
    { "Z_SYNC_FLUSH",          Z_SYNC_FLUSH          },
    { "Z_FULL_FLUSH",          Z_FULL_FLUSH          },
    { "Z_FINISH",              Z_FINISH              },
    { "Z_BLOCK",               Z_BLOCK               },
    /* compression levels */
    { "Z_NO_COMPRESSION",      Z_NO_COMPRESSION      },
    { "Z_BEST_SPEED",          Z_BEST_SPEED          },
    { "Z_BEST_COMPRESSION",    Z_BEST_COMPRESSION    },
    { "Z_DEFAULT_COMPRESSION", Z_DEFAULT_COMPRESSION },
    /* strategies */
    { "Z_FILTERED",            Z_FILTERED            },
    { "Z_HUFFMAN_ONLY",        Z_HUFFMAN_ONLY        },
    { "Z_RLE",                 Z_RLE                 },
    { "Z_FIXED",               Z_FIXED               },
    { "Z_DEFAULT_STRATEGY",    Z_DEFAULT_STRATEGY    },
    /* method, window and memory */
    { "Z_DEFLATED",            Z_DEFLATED            },
    { "MAX_WBITS",             MAX_WBITS             },
    { "MAX_MEM_LEVEL",         MAX_MEM_LEVEL         },
    { "DEF_MEM_LEVEL",         CZ_DEF_MEM_LEVEL      },
    { NULL,                    0                     } /* sentinel */
};

/* ============================================================================================ */

static void setupMeta(lua_State* L, const char* className, int capiCache,
                      const luaL_Reg* methods, const luaL_Reg* metaMethods)
{                                                          /* -> meta */
    lua_pushstring(L, className);                          /* -> meta, className */
    lua_setfield(L, -2, "__metatable");                    /* -> meta */

    luaL_setfuncs(L, metaMethods, 0);                      /* -> meta */

    lua_newtable(L);                                       /* -> meta, Class */
    lua_pushvalue(L, capiCache);                           /* -> meta, Class, cc */
    luaL_setfuncs(L, methods, 1);                          /* -> meta, Class */
    lua_setfield(L, -2, "__index");                        /* -> meta */
}

/* ============================================================================================ */

int compress_zlib_init_module(lua_State* L, int module)
{
    int             capiCache = pushCapiCache(L);          /* -> cc */
    const Constant* k;

    if (luaL_newmetatable(L, ZLIB_DECOMPRESSOR_CLASS_NAME)) {     /* -> cc, meta */
        setupMeta(L, ZLIB_DECOMPRESSOR_CLASS_NAME, capiCache,
                  DecompressorMethods, DecompressorMetaMethods);
        /* inflate: the name of Compress::Zlib / Compress::Raw::Zlib, the same function */
        lua_getfield(L, -1, "__index");                    /* -> cc, meta, Class */
        lua_getfield(L, -1, "decompress");                 /* -> cc, meta, Class, f */
        lua_setfield(L, -2, "inflate");                    /* -> cc, meta, Class */
        lua_pop(L, 1);                                     /* -> cc, meta */
    }
    lua_pop(L, 1);                                         /* -> cc */

    if (luaL_newmetatable(L, ZLIB_COMPRESSOR_CLASS_NAME)) {       /* -> cc, meta */
        setupMeta(L, ZLIB_COMPRESSOR_CLASS_NAME, capiCache,
                  CompressorMethods, CompressorMetaMethods);
    }
    lua_pop(L, 1);                                         /* -> cc */

    lua_pushvalue(L, module);                              /* -> cc, module */
        lua_pushvalue(L, capiCache);                       /* -> cc, module, cc */
        luaL_setfuncs(L, ModuleFunctions, 1);              /* -> cc, module */
        luaL_setfuncs(L, PlainModuleFunctions, 0);         /* -> cc, module */
        for (k = Constants; k->name; ++k) {
            lua_pushinteger(L, k->value);                  /* -> cc, module, value */
            lua_setfield(L, -2, k->name);                  /* -> cc, module */
        }
    lua_pop(L, 2);                                         /* -> */

    return 0;
}

/* ============================================================================================ */
