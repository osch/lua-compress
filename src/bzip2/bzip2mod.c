/*
 * The original bzlib.h declares the functions on Windows only with BZ_EXPORT as functions
 * (else as function pointers, for loading the DLL dynamically). The patched headers of
 * vcpkg and MSYS2 ignore BZ_EXPORT and declare them as functions anyway.
 */
#if defined(_WIN32) && !defined(BZ_EXPORT)
#  define BZ_EXPORT 1
#endif
#include <bzlib.h>
#ifdef small
#  undef small   /* windows.h (included by the original bzlib.h) defines it */
#endif

#include "../common/data.h"
#include "bzip2mod.h"

/* ============================================================================================ */

const char* const CBZ2_DECOMPRESSOR_CLASS_NAME = "compress.bzip2.decompressor";
const char* const CBZ2_COMPRESSOR_CLASS_NAME   = "compress.bzip2.compressor";

/* ============================================================================================ */

/* maxsize when no limit is given */
#define CB_NO_LIMIT    SIZE_MAX

/* avail_in and avail_out of bz_stream are unsigned int */
#define CB_MAX_AVAIL   ((size_t)UINT_MAX)

#define MSG_MAXSIZE         "output exceeds maxsize"
#define MSG_END_OF_INPUT    "unexpected end of input"
#define MSG_TRAILING        "unexpected data after end of stream"

#define FUNC_DECOMPRESS     "BZ2_bzDecompress"
#define FUNC_COMPRESS       "BZ2_bzCompress"

/*
 * The messages of libbz2's status codes: the strings of BZ2_bzerror() (bzerrorstrings in
 * bzlib.c, only reachable there through a BZFILE), for the positive codes their names.
 */
static const char* retMessage(int ret)
{
    switch (ret) {
        case BZ_OK:               return "OK";
        case BZ_RUN_OK:           return "RUN_OK";
        case BZ_FLUSH_OK:         return "FLUSH_OK";
        case BZ_FINISH_OK:        return "FINISH_OK";
        case BZ_STREAM_END:       return "STREAM_END";
        case BZ_SEQUENCE_ERROR:   return "SEQUENCE_ERROR";
        case BZ_PARAM_ERROR:      return "PARAM_ERROR";
        case BZ_MEM_ERROR:        return "MEM_ERROR";
        case BZ_DATA_ERROR:       return "DATA_ERROR";
        case BZ_DATA_ERROR_MAGIC: return "DATA_ERROR_MAGIC";
        case BZ_IO_ERROR:         return "IO_ERROR";
        case BZ_UNEXPECTED_EOF:   return "UNEXPECTED_EOF";
        case BZ_OUTBUFF_FULL:     return "OUTBUFF_FULL";
        case BZ_CONFIG_ERROR:     return "CONFIG_ERROR";
        default:                  return "???";
    }
}

/* ============================================================================================ */

#define OPT_BLOCKSIZE  0x0001
#define OPT_LEVEL      0x0002   /* the common name of blockSize100k, allowed together with it */
#define OPT_WORKFACTOR 0x0004
#define OPT_SMALL      0x0008
#define OPT_MAXSIZE    0x0010
#define OPT_TRAILING   0x0020
#define OPT_OUT        0x0040   /* the former option out: never allowed, see optionError() */

#define OPTS_ENCODER   (OPT_BLOCKSIZE | OPT_WORKFACTOR)
#define OPTS_DECODER   (OPT_SMALL | OPT_MAXSIZE | OPT_TRAILING)

typedef struct Options
{
    unsigned given;            /* the OPT_* bits of the options given */
    int      blockSize100k;
    int      workFactor;
    int      smallMode;
    size_t   maxsize;
    int      allowTrailing;
} Options;

static int checkIntOption(lua_State* L, int arg, lua_Integer min, lua_Integer max, const char* msg)
{
    lua_Integer v;
    if (!topInteger(L, &v) || v < min || v > max) {
        luaL_argerror(L, arg, msg);
    }
    return (int)v;
}

static int checkBoolOption(lua_State* L, int arg, const char* msg)
{
    if (lua_type(L, -1) != LUA_TBOOLEAN) {
        luaL_argerror(L, arg, msg);
    }
    return lua_toboolean(L, -1);
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
 * no options.
 */
static void checkOptions(lua_State* L, int arg, const char* func, unsigned allowed, Options* o)
{
    int t = arg ? lua_type(L, arg) : LUA_TNONE;

    memset(o, 0, sizeof(Options));
    o->blockSize100k = 9;          /* the default of the bzip2 tool */
    o->workFactor    = 0;          /* libbz2's default (30) */
    o->maxsize       = CB_NO_LIMIT;

    if (t == LUA_TNONE || t == LUA_TNIL) {
        return;
    }
    if (t != LUA_TTABLE) {
        luaL_argerror(L, arg, lua_pushfstring(L, "table expected, got %s", luaL_typename(L, arg)));
    }
    lua_pushnil(L);                                                     /* -> key */
    while (lua_next(L, arg)) {                                          /* -> key, value */
        const char* name = (lua_type(L, -2) == LUA_TSTRING) ? lua_tostring(L, -2) : NULL;
        unsigned    opt  = 0;
        if (name) {
            if      (strcmp(name, "blockSize100k") == 0) opt = OPT_BLOCKSIZE;
            else if (strcmp(name, "level")         == 0) opt = OPT_LEVEL;
            else if (strcmp(name, "workFactor")    == 0) opt = OPT_WORKFACTOR;
            else if (strcmp(name, "small")         == 0) opt = OPT_SMALL;
            else if (strcmp(name, "maxsize")       == 0) opt = OPT_MAXSIZE;
            else if (strcmp(name, "allowtrailing") == 0) opt = OPT_TRAILING;
            else if (strcmp(name, "out")           == 0) opt = OPT_OUT;
        }
        if (!(opt & (allowed | ((allowed & OPT_BLOCKSIZE) ? OPT_LEVEL : 0)))) {
            optionError(L, arg, func, name, opt);
        }
        switch (opt) {
            case OPT_BLOCKSIZE:
            case OPT_LEVEL: {
                int v = checkIntOption(L, arg, 1, 9, (opt == OPT_BLOCKSIZE) ? "invalid blockSize100k value"
                                                                          : "invalid level value");
                if ((o->given & (OPT_BLOCKSIZE | OPT_LEVEL)) && o->blockSize100k != v) {
                    /* both given (in any order of lua_next()) */
                    luaL_argerror(L, arg, "level contradicts blockSize100k");
                }
                o->blockSize100k = v;
                break;
            }
            case OPT_WORKFACTOR:
                o->workFactor = checkIntOption(L, arg, 0, 250, "invalid workFactor value");
                break;
            case OPT_SMALL:
                o->smallMode = checkBoolOption(L, arg, "invalid small value");
                break;
            case OPT_MAXSIZE: {
                lua_Integer v;
                if (!topInteger(L, &v) || v < 0) {
                    luaL_argerror(L, arg, "invalid maxsize value");
                }
                o->maxsize = toSize(v);
                break;
            }
            case OPT_TRAILING:
                o->allowTrailing = checkBoolOption(L, arg, "invalid allowtrailing value");
                break;
            default:
                break;
        }
        o->given |= opt;
        lua_pop(L, 1);                                                  /* -> key */
    }                                                                   /* -> */
}

/* ============================================================================================ */

/*
 * Native encoder or decoder state, owned by a userdata with __gc: the state is also
 * released if a Lua error (e.g. out of memory) interrupts a call. The one-shot
 * functions use such a userdata too and release the state before they return.
 */
typedef struct Coder
{
    bz_stream   z;
    int         kind;          /* K_NONE, K_DECODER, K_ENCODER: is z initialized */
    int         status;
    size_t      total;         /* decoder: bytes produced so far */
    size_t      maxsize;       /* decoder: limit for total */
    int         allowTrailing; /* decoder: ignore data after the end */
    int         failed;        /* decoder: the stream cannot go on, the status is failedRet */
    int         failedRet;
    const char* msgFunc;       /* the C function and message of the last error, NULL if none */
    const char* msg;
} Coder;

#define K_NONE     0
#define K_DECODER  1
#define K_ENCODER  2

#define ST_OPEN    0   /* ready for more data */
#define ST_BUSY    1   /* inside a call; still set if that call was aborted by a Lua error */
#define ST_DONE    2   /* decompressor: end of the stream reached */
#define ST_CLOSED  3   /* native state released: finished or failed */

static void releaseCoder(Coder* c)
{
    if (c->kind == K_ENCODER) {
        BZ2_bzCompressEnd(&c->z);
    } else if (c->kind == K_DECODER) {
        BZ2_bzDecompressEnd(&c->z);
    }
    c->kind   = K_NONE;
    c->status = ST_CLOSED;
}

static Coder* pushCoder(lua_State* L, const char* className)
{
    Coder* c = (Coder*)lua_newuserdata(L, sizeof(Coder));                /* -> coder */
    memset(c, 0, sizeof(Coder));      /* bzalloc, bzfree, opaque NULL: malloc and free */
    c->status  = ST_CLOSED;
    c->maxsize = CB_NO_LIMIT;
    luaL_setmetatable(L, className);
    return c;
}

/* raises "Error in <func>: <message of ret>" for a failed init, the coder stays closed */
static int failInit(lua_State* L, Coder* c, const char* func, int ret)
{
    releaseCoder(c);
    return luaL_error(L, "Error in %s: %s", func, retMessage(ret));
}

static Coder* newDecoder(lua_State* L, const Options* o)
{
    Coder* c = pushCoder(L, CBZ2_DECOMPRESSOR_CLASS_NAME);              /* -> coder */
    int    ret;

    c->maxsize       = o->maxsize;
    c->allowTrailing = o->allowTrailing;
    ret = BZ2_bzDecompressInit(&c->z, 0, o->smallMode ? 1 : 0);
    if (ret != BZ_OK) {
        failInit(L, c, "BZ2_bzDecompressInit", ret);
    }
    c->kind   = K_DECODER;
    c->status = ST_OPEN;
    return c;
}

static Coder* newEncoder(lua_State* L, const Options* o)
{
    Coder* c = pushCoder(L, CBZ2_COMPRESSOR_CLASS_NAME);                /* -> coder */
    int    ret;

    ret = BZ2_bzCompressInit(&c->z, o->blockSize100k, 0, o->workFactor);
    if (ret != BZ_OK) {
        failInit(L, c, "BZ2_bzCompressInit", ret);
    }
    c->kind   = K_ENCODER;
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

/* raises the last error recorded in the coder; releases the state, resets a carray target */
static int failCoder(lua_State* L, Coder* c, Output* o)
{
    outDiscard(o);
    if (c->msgFunc) {
        lua_pushfstring(L, "Error in %s: %s", c->msgFunc, c->msg);
    } else {
        lua_pushstring(L, c->msg);
    }
    releaseCoder(c);
    return lua_error(L);
}

/* records an error that ends the decoder's stream */
static void setFailed(Coder* c, const char* func, const char* msg, int ret)
{
    c->msgFunc   = func;
    c->msg       = msg;
    c->failed    = 1;
    c->failedRet = ret;
}

static unsigned int availOf(size_t n)
{
    return (unsigned int)((n > CB_MAX_AVAIL) ? CB_MAX_AVAIL : n);
}

/* ============================================================================================ */

/*
 * Feeds the input to the decoder until all of it is consumed, the stream ends or an error
 * occurs. Raises no error of its own (only Lua errors of the output, e.g. out of memory).
 * Returns libbz2's status: BZ_OK (all input consumed, the stream goes on), BZ_STREAM_END
 * (*consumed: the input bytes up to the end of the stream; libbz2 reads no byte after it)
 * or an error status with the message recorded in the coder (c->failed). maxsize: no more
 * than maxsize bytes are written to the output; if the stream has more, BZ_OUTBUFF_FULL is
 * returned.
 *
 * Empty input does not call BZ2_bzDecompress(): nothing could be done.
 */
static int runDecode(Coder* c, const Input* in, Output* o, size_t want, size_t* consumed)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;
    int            ret   = BZ_OK;
    uint8_t        extra[1];

    *consumed = 0;
    if (c->failed) {
        return c->failedRet;
    }
    if (avail == 0) {
        return BZ_OK;
    }
    c->status = ST_BUSY;
    for (;;) {
        size_t   space, used, produced;
        uint8_t* p;
        int      overflow = 0;
        if (c->maxsize != CB_NO_LIMIT) {
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
            if (c->maxsize != CB_NO_LIMIT && space > want) {
                space = want;   /* a carray target may have more space: keep to maxsize */
            }
        }
        c->z.next_in   = (char*)next;
        c->z.avail_in  = availOf(avail);
        c->z.next_out  = (char*)p;
        c->z.avail_out = availOf(space);
        space          = c->z.avail_out;
        used           = c->z.avail_in;
        ret = BZ2_bzDecompress(&c->z);
        used     = used - c->z.avail_in;
        produced = space - c->z.avail_out;
        next  += used;
        avail -= used;
        if (overflow) {
            if (produced > 0) {
                setFailed(c, NULL, MSG_MAXSIZE, BZ_OUTBUFF_FULL);
                ret = BZ_OUTBUFF_FULL;
                break;
            }
        } else {
            outCommit(o, produced);
            c->total += produced;
        }
        if (ret == BZ_STREAM_END) {
            break;
        }
        if (ret != BZ_OK) {
            setFailed(c, FUNC_DECOMPRESS, retMessage(ret), ret);
            break;
        }
        if (c->z.avail_out == 0) {
            if (!overflow) {
                want = outGrow(o);
            }
            continue;
        }
        if (avail > 0) {
            if (used > 0 || produced > 0) {
                continue;
            }
            ret = BZ_SEQUENCE_ERROR;   /* no progress, not expected */
            setFailed(c, FUNC_DECOMPRESS, retMessage(ret), ret);
            break;
        }
        ret = BZ_OK;       /* all input consumed, more is expected */
        break;
    }
    *consumed = in->len - avail;
    c->status = (ret == BZ_STREAM_END) ? ST_DONE : ST_OPEN;
    return ret;
}

/*
 * The raising variant for update/finish/decompress: an error closes the coder. Returns
 * 1 at the end of the stream (after checking for trailing data), 0 if more input is
 * expected.
 */
static int decodeOrFail(lua_State* L, Coder* c, const Input* in, Output* o, size_t want)
{
    size_t consumed;
    int    ret = runDecode(c, in, o, want, &consumed);
    if (ret == BZ_STREAM_END) {
        if (consumed < in->len && !c->allowTrailing) {
            c->msgFunc = FUNC_DECOMPRESS;
            c->msg     = MSG_TRAILING;
            failCoder(L, c, o);
        }
        return 1;
    }
    if (ret != BZ_OK) {
        failCoder(L, c, o);
    }
    return 0;
}

/* the end of the input before the end of the stream */
static void failEnd(lua_State* L, Coder* c, Output* o)
{
    c->msgFunc = FUNC_DECOMPRESS;
    c->msg     = MSG_END_OF_INPUT;
    failCoder(L, c, o);
}

/* raises an error of BZ2_bzCompress() */
static void failEncode(lua_State* L, Coder* c, Output* o, int ret)
{
    c->msgFunc = FUNC_COMPRESS;
    c->msg     = retMessage(ret);
    failCoder(L, c, o);
}

/*
 * Compresses the input with BZ_RUN, then, for action BZ_FLUSH or BZ_FINISH, ends the
 * block or the stream without further input. This is what the bzip2 tool and Perl's
 * IO::Compress::Bzip2 do (BZ2_bzWrite, then BZ2_bzWriteClose / bzdeflate, then bzclose),
 * so the output is the same as theirs, regardless of how the input is split: libbz2
 * gives other bytes in a rare case when the input is given to BZ_FINISH directly (the
 * input ends just where a block is full). The large input is fed in pieces of at most
 * UINT_MAX bytes (avail_in is an unsigned int), which BZ_RUN allows.
 */
static void runEncode(lua_State* L, Coder* c, const Input* in, Output* o, int action, size_t want)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;

    c->status = ST_BUSY;
    while (avail > 0) {
        size_t   space, used, given;
        uint8_t* p = outPrep(o, want, &space);
        int      ret;
        c->z.next_in   = (char*)next;
        c->z.avail_in  = availOf(avail);
        c->z.next_out  = (char*)p;
        c->z.avail_out = availOf(space);
        space          = c->z.avail_out;
        given          = c->z.avail_in;
        ret = BZ2_bzCompress(&c->z, BZ_RUN);
        used   = given - c->z.avail_in;
        next  += used;
        avail -= used;
        outCommit(o, space - c->z.avail_out);
        if (ret != BZ_RUN_OK) {
            failEncode(L, c, o, ret);
        }
        if (c->z.avail_out == 0) {
            /* the output may go on: libbz2 holds it back until there is space */
            want = outGrow(o);
            if (avail == 0) {
                /* no input left: is there more output? BZ_PARAM_ERROR if there is none */
                for (;;) {
                    p = outPrep(o, want, &space);
                    c->z.next_in   = (char*)next;
                    c->z.avail_in  = 0;
                    c->z.next_out  = (char*)p;
                    c->z.avail_out = availOf(space);
                    space          = c->z.avail_out;
                    ret = BZ2_bzCompress(&c->z, BZ_RUN);
                    outCommit(o, space - c->z.avail_out);
                    if (ret == BZ_PARAM_ERROR) {
                        break;      /* no progress: all output was taken */
                    }
                    if (ret != BZ_RUN_OK) {
                        failEncode(L, c, o, ret);
                    }
                    if (c->z.avail_out != 0) {
                        break;
                    }
                    want = outGrow(o);
                }
            }
        }
    }
    if (action != BZ_RUN) {
        int done = (action == BZ_FLUSH) ? BZ_RUN_OK : BZ_STREAM_END;
        int more = (action == BZ_FLUSH) ? BZ_FLUSH_OK : BZ_FINISH_OK;
        for (;;) {
            size_t   space;
            uint8_t* p = outPrep(o, want, &space);
            int      ret;
            c->z.next_in   = (char*)next;
            c->z.avail_in  = 0;
            c->z.next_out  = (char*)p;
            c->z.avail_out = availOf(space);
            space          = c->z.avail_out;
            ret = BZ2_bzCompress(&c->z, action);
            outCommit(o, space - c->z.avail_out);
            if (ret == done) {
                break;      /* the block or the stream is complete */
            }
            if (ret != more) {
                failEncode(L, c, o, ret);
            }
            if (c->z.avail_out == 0) {
                want = outGrow(o);
            }
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
static size_t compressGuess(size_t n)
{
    return n / 4 + 1024;
}

/* ============================================================================================ */
/* module functions                                                                             */
/* ============================================================================================ */

/* compress.bzip2.decompress(data [, opts] [, out]) */
static int Bzip2_decompress(lua_State* L)
{
    Input   in;
    Options opt;
    Output  o;
    Coder*  c;
    int     optsArg;
    int     outArg;

    checkInput(L, 1, &in);
    outArg = checkOptsOut(L, 2, &optsArg);
    checkOptions(L, optsArg, "decompress", OPTS_DECODER, &opt);
    c = newDecoder(L, &opt);
    outInit(L, &o, outArg, outArg, 1);

    if (!decodeOrFail(L, c, &in, &o, decompressGuess(in.len))) {
        failEnd(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.bzip2.compress(data [, opts] [, out]) */
static int Bzip2_compress(lua_State* L)
{
    Input   in;
    Options opt;
    Output  o;
    Coder*  c;
    int     optsArg;
    int     outArg;

    checkInput(L, 1, &in);
    outArg = checkOptsOut(L, 2, &optsArg);
    checkOptions(L, optsArg, "compress", OPTS_ENCODER, &opt);
    c = newEncoder(L, &opt);
    outInit(L, &o, outArg, outArg, 1);

    runEncode(L, c, &in, &o, BZ_FINISH, compressGuess(in.len));
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.bzip2.decompressor([opts]) */
static int Bzip2_decompressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "decompressor", OPTS_DECODER, &opt);
    newDecoder(L, &opt);
    return 1;
}

/* compress.bzip2.compressor([opts]) */
static int Bzip2_compressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "compressor", OPTS_ENCODER, &opt);
    newEncoder(L, &opt);
    return 1;
}

/* compress.bzip2.version() -> the version of libbz2 (BZ2_bzlibVersion()) */
static int Bzip2_version(lua_State* L)
{
    lua_pushstring(L, BZ2_bzlibVersion());
    return 1;
}

/* ============================================================================================ */
/* decompressor methods                                                                         */
/* ============================================================================================ */

#define DEC_WHAT "decompressor"
#define ENC_WHAT "compressor"

static int failTrailing(lua_State* L, Coder* c, Output* o)
{
    c->msgFunc = FUNC_DECOMPRESS;
    c->msg     = MSG_TRAILING;
    return failCoder(L, c, o);
}

/* decompressor:update(chunk [, out]) -> string or nil, or out */
static int Decompressor_update(lua_State* L)
{
    Coder* c = checkStream(L, CBZ2_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
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
        decodeOrFail(L, c, &in, &o, decompressGuess(in.len));
    }
    outPush(&o, 1);
    return 1;
}

/* decompressor:finish([chunk [, out]]) -> string, or out */
static int Decompressor_finish(lua_State* L)
{
    Coder* c = checkStream(L, CBZ2_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
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
    } else if (!decodeOrFail(L, c, &in, &o, decompressGuess(in.len))) {
        failEnd(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/*
 * decompressor:decompress(chunk [, out]) -> output, status, consumed
 * (also as decompressor:bzinflate, the name of Compress::Raw::Bunzip2)
 *
 * Raises no error for the data: the status tells the caller, as for Compress::Raw::Bzip2's
 * $status = $bz->bzinflate($in, $out). output is a string ("" if there is none), or out.
 */
static int Decompressor_decompress(lua_State* L)
{
    Coder* c = checkStream(L, CBZ2_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
    Input  in;
    Output o;
    size_t consumed = 0;
    int    ret;

    checkInput(L, 2, &in);
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    if (c->status == ST_DONE) {
        /* the end of the stream again, nothing consumed */
        ret = BZ_STREAM_END;
    } else {
        ret = runDecode(c, &in, &o, decompressGuess(in.len), &consumed);
    }
    outPush(&o, 0);
    lua_pushinteger(L, (lua_Integer)ret);
    lua_pushinteger(L, (lua_Integer)consumed);
    return 3;
}

/* decompressor:msg() -> message of the last error, or nil */
static int Decompressor_msg(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, CBZ2_DECOMPRESSOR_CLASS_NAME);
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
static int compressorOp(lua_State* L, Coder* c, int action, int chunkOptional, int outArg)
{
    Input  in;
    Output o;

    if (chunkOptional) {
        optInput(L, 2, &in);
    } else {
        checkInput(L, 2, &in);
    }
    lua_settop(L, outArg);
    outInit(L, &o, optOut(L, outArg), outArg, 2);
    runEncode(L, c, &in, &o, action, LUAL_BUFFERSIZE);
    if (action == BZ_FINISH) {
        releaseCoder(c);
    }
    outPush(&o, action != BZ_FINISH);
    return 1;
}

/* compressor:update(chunk [, out]) -> string or nil, or out */
static int Compressor_update(lua_State* L)
{
    Coder* c = checkStream(L, CBZ2_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    return compressorOp(L, c, BZ_RUN, 0, 3);
}

/*
 * compressor:flush([chunk [, mode] [, out]]) -> string or nil (string for "finish"), or
 * out. A carray (userdata) at 3 is out, else 3 is the mode and 4 out.
 *
 * libbz2 has only BZ_FLUSH: it ends the current block, but holds back its last bits (up to
 * 8, in the bit buffer of the encoder), and the decoder needs some bits of what follows to
 * end the block: unlike zlib's and liblzma's sync flush, the output is not decodable up to
 * the last byte given. Its mode is "block", like zlib's Z_BLOCK; "sync" and "full" are not
 * supported.
 */
static int Compressor_flush(lua_State* L)
{
    Coder* c      = checkStream(L, CBZ2_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    int    action = BZ_FLUSH;
    int    t      = lua_type(L, 3);
    int    outArg = 4;

    if (t == LUA_TUSERDATA || t == LUA_TNONE || t == LUA_TNIL) {
        outArg = (t == LUA_TUSERDATA) ? 3 : 4;
    } else if (t == LUA_TSTRING) {
        const char* m = lua_tostring(L, 3);
        if      (strcmp(m, "block")  == 0) action = BZ_FLUSH;
        else if (strcmp(m, "finish") == 0) action = BZ_FINISH;
        else if (strcmp(m, "sync") == 0 || strcmp(m, "full") == 0) {
            /* raised before anything is done: the stream stays usable */
            return luaL_error(L, "flush mode '%s' is not supported for format 'bzip2'", m);
        }
        else luaL_argerror(L, 3, "invalid flush mode");
    } else if (t == LUA_TNUMBER) {
        lua_Integer v;
        lua_pushvalue(L, 3);
        if (!topInteger(L, &v) || !(v == BZ_RUN || v == BZ_FLUSH || v == BZ_FINISH)) {
            luaL_argerror(L, 3, "invalid flush mode");
        }
        lua_pop(L, 1);
        action = (int)v;
    } else {
        luaL_argerror(L, 3, "invalid flush mode");
    }
    return compressorOp(L, c, action, 1, outArg);
}

/* compressor:finish([chunk [, out]]) -> string, or out */
static int Compressor_finish(lua_State* L)
{
    Coder* c = checkStream(L, CBZ2_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    return compressorOp(L, c, BZ_FINISH, 1, 3);
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
    Coder* c = (Coder*)luaL_checkudata(L, 1, CBZ2_DECOMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", CBZ2_DECOMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

static int Compressor_toString(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, CBZ2_COMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", CBZ2_COMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

/* ============================================================================================ */

static const luaL_Reg ModuleFunctions[] =
{
    { "decompress",   Bzip2_decompress     },
    { "compress",     Bzip2_compress       },
    { "decompressor", Bzip2_decompressor   },
    { "compressor",   Bzip2_compressor     },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg PlainModuleFunctions[] =
{
    { "version",      Bzip2_version        },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg DecompressorMethods[] =
{
    { "update",       Decompressor_update  },
    { "finish",       Decompressor_finish  },
    { "decompress",   Decompressor_decompress },   /* also as "bzinflate", see below */
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

/* the constants of bzlib.h with libbz2's values */
typedef struct Constant
{
    const char* name;
    int         value;
} Constant;

static const Constant Constants[] =
{
    /* actions (flush modes) */
    { "BZ_RUN",               BZ_RUN               },
    { "BZ_FLUSH",             BZ_FLUSH             },
    { "BZ_FINISH",            BZ_FINISH            },
    /* status codes */
    { "BZ_OK",                BZ_OK                },
    { "BZ_RUN_OK",            BZ_RUN_OK            },
    { "BZ_FLUSH_OK",          BZ_FLUSH_OK          },
    { "BZ_FINISH_OK",         BZ_FINISH_OK         },
    { "BZ_STREAM_END",        BZ_STREAM_END        },
    { "BZ_SEQUENCE_ERROR",    BZ_SEQUENCE_ERROR    },
    { "BZ_PARAM_ERROR",       BZ_PARAM_ERROR       },
    { "BZ_MEM_ERROR",         BZ_MEM_ERROR         },
    { "BZ_DATA_ERROR",        BZ_DATA_ERROR        },
    { "BZ_DATA_ERROR_MAGIC",  BZ_DATA_ERROR_MAGIC  },
    { "BZ_IO_ERROR",          BZ_IO_ERROR          },
    { "BZ_UNEXPECTED_EOF",    BZ_UNEXPECTED_EOF    },
    { "BZ_OUTBUFF_FULL",      BZ_OUTBUFF_FULL      },
    { "BZ_CONFIG_ERROR",      BZ_CONFIG_ERROR      },
    { NULL,                   0                    } /* sentinel */
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

int compress_bzip2_init_module(lua_State* L, int module)
{
    int             capiCache = pushCapiCache(L);          /* -> cc */
    const Constant* k;

    if (luaL_newmetatable(L, CBZ2_DECOMPRESSOR_CLASS_NAME)) {     /* -> cc, meta */
        setupMeta(L, CBZ2_DECOMPRESSOR_CLASS_NAME, capiCache,
                  DecompressorMethods, DecompressorMetaMethods);
        /* bzinflate: the name of Compress::Raw::Bunzip2, the same function */
        lua_getfield(L, -1, "__index");                    /* -> cc, meta, Class */
        lua_getfield(L, -1, "decompress");                 /* -> cc, meta, Class, f */
        lua_setfield(L, -2, "bzinflate");                  /* -> cc, meta, Class */
        lua_pop(L, 1);                                     /* -> cc, meta */
    }
    lua_pop(L, 1);                                         /* -> cc */

    if (luaL_newmetatable(L, CBZ2_COMPRESSOR_CLASS_NAME)) {       /* -> cc, meta */
        setupMeta(L, CBZ2_COMPRESSOR_CLASS_NAME, capiCache,
                  CompressorMethods, CompressorMetaMethods);
    }
    lua_pop(L, 1);                                         /* -> cc */

    lua_pushvalue(L, module);                              /* -> cc, module */
        lua_pushvalue(L, capiCache);                       /* -> cc, module, cc */
        luaL_setfuncs(L, ModuleFunctions, 1);              /* -> cc, module */
        luaL_setfuncs(L, PlainModuleFunctions, 0);         /* -> cc, module */
        for (k = Constants; k->name; ++k) {
            lua_pushinteger(L, (lua_Integer)k->value);     /* -> cc, module, value */
            lua_setfield(L, -2, k->name);                  /* -> cc, module */
        }
    lua_pop(L, 2);                                         /* -> */

    return 0;
}

/* ============================================================================================ */
