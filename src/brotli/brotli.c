#include <brotli/decode.h>
#include <brotli/encode.h>

#include "../common/data.h"
#include "brotli.h"

/* ============================================================================================ */

const char* const BROTLI_DECOMPRESSOR_CLASS_NAME = "compress.brotli.decompressor";
const char* const BROTLI_COMPRESSOR_CLASS_NAME   = "compress.brotli.compressor";

/* ============================================================================================ */

/* BROTLI_PARAM_SIZE_HINT is a 32 bit value */
#define CB_MAX_HINT    ((size_t)0xFFFFFFFFu)

/* maxsize when no limit is given */
#define CB_NO_LIMIT    SIZE_MAX

/* the messages of IO::Compress::Brotli, see "Errors" in doc/README.md */
#define MSG_DECODER_FUNC    "BrotliDecoderDecompressStream"
#define MSG_ENCODER_ERROR   "Error in BrotliEncoderCompressStream"
#define MSG_QUALITY         "Invalid quality value"
#define MSG_LEVEL           "Invalid level value"
#define MSG_MAXSIZE         "output exceeds maxsize"
#define MSG_END_OF_INPUT    "unexpected end of input"
#define MSG_TRAILING        "unexpected data after end of stream"
#define MSG_WINDOW          "Invalid window value"
#define MSG_MODE            "Invalid encoder mode"

/* ============================================================================================ */

#define OPT_QUALITY   0x01
#define OPT_LGWIN     0x02
#define OPT_MODE      0x04
#define OPT_SIZEHINT  0x08
#define OPT_MAXSIZE   0x10
#define OPT_OUT       0x20   /* the former option out: never allowed, see optionError() */
#define OPT_TRAILING  0x40
#define OPT_LEVEL     0x80   /* the common name of quality, allowed together with OPT_QUALITY */

typedef struct Options
{
    int               quality;
    int               qualityGiven; /* OPT_QUALITY and/or OPT_LEVEL: which were given */
    int               lgwin;
    BrotliEncoderMode mode;
    size_t            sizehint;    /* 0: not set */
    size_t            maxsize;
    int               allowTrailing;
} Options;

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

    o->quality  = BROTLI_DEFAULT_QUALITY;
    o->qualityGiven = 0;
    o->lgwin    = BROTLI_DEFAULT_WINDOW;
    o->mode     = BROTLI_DEFAULT_MODE;
    o->sizehint = 0;
    o->maxsize  = CB_NO_LIMIT;
    o->allowTrailing = 0;

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
        lua_Integer v;
        if (name) {
            if      (strcmp(name, "quality")  == 0) opt = OPT_QUALITY;
            else if (strcmp(name, "level")    == 0) opt = OPT_LEVEL;
            else if (strcmp(name, "lgwin")    == 0) opt = OPT_LGWIN;
            else if (strcmp(name, "mode")     == 0) opt = OPT_MODE;
            else if (strcmp(name, "sizehint") == 0) opt = OPT_SIZEHINT;
            else if (strcmp(name, "maxsize")  == 0) opt = OPT_MAXSIZE;
            else if (strcmp(name, "out")      == 0) opt = OPT_OUT;
            else if (strcmp(name, "allowtrailing") == 0) opt = OPT_TRAILING;
        }
        if (!(opt & (allowed | ((allowed & OPT_QUALITY) ? OPT_LEVEL : 0)))) {
            optionError(L, arg, func, name, opt);
        }
        switch (opt) {
            case OPT_QUALITY:
            case OPT_LEVEL:
                if (!topInteger(L, &v) || v < BROTLI_MIN_QUALITY || v > BROTLI_MAX_QUALITY) {
                    luaL_argerror(L, arg, (opt == OPT_QUALITY) ? MSG_QUALITY : MSG_LEVEL);
                }
                if (o->qualityGiven && o->quality != (int)v) {
                    /* both given (in any order of lua_next()) */
                    luaL_argerror(L, arg, "level contradicts quality");
                }
                o->quality = (int)v;
                o->qualityGiven |= opt;
                break;
            case OPT_LGWIN:
                if (!topInteger(L, &v) || v < BROTLI_MIN_WINDOW_BITS || v > BROTLI_MAX_WINDOW_BITS) {
                    luaL_argerror(L, arg, MSG_WINDOW);
                }
                o->lgwin = (int)v;
                break;
            case OPT_MODE: {
                const char* m = (lua_type(L, -1) == LUA_TSTRING) ? lua_tostring(L, -1) : "";
                if      (strcmp(m, "generic") == 0) o->mode = BROTLI_MODE_GENERIC;
                else if (strcmp(m, "text")    == 0) o->mode = BROTLI_MODE_TEXT;
                else if (strcmp(m, "font")    == 0) o->mode = BROTLI_MODE_FONT;
                else luaL_argerror(L, arg, MSG_MODE);
                break;
            }
            case OPT_SIZEHINT:
                if (!topInteger(L, &v) || v < 0) {
                    luaL_argerror(L, arg, "invalid sizehint value");
                }
                o->sizehint = toSize(v);
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
            default:
                break;
        }
        lua_pop(L, 1);                                                  /* -> key */
    }                                                                   /* -> */
}

/* ============================================================================================ */

/*
 * Native decoder or encoder state, owned by a userdata with __gc: the state is also
 * released if a Lua error (e.g. out of memory) interrupts a call. The one-shot
 * functions use such a userdata too and release the state before they return.
 */
typedef struct Coder
{
    BrotliDecoderState* dec;
    BrotliEncoderState* enc;
    int                 status;
    size_t              total;     /* decompressor: bytes produced so far */
    size_t              maxsize;   /* decompressor: limit for total */
    int                 allowTrailing; /* decompressor: ignore data after the end */
    int                 failed;    /* decompressor: 0, or the status of an error that ends the
                                      stream (BROTLI_DECODER_RESULT_ERROR or _NEEDS_MORE_OUTPUT) */
    const char*         msgFunc;   /* decompressor: the C function and message of the last */
    const char*         msg;       /*   error (static strings), NULL if none */
} Coder;

#define ST_OPEN    0   /* ready for more data */
#define ST_BUSY    1   /* inside a call; still set if that call was aborted by a Lua error */
#define ST_DONE    2   /* decompressor: end of the Brotli stream reached */
#define ST_CLOSED  3   /* native state released: finished or failed */

static void releaseCoder(Coder* c)
{
    if (c->dec) {
        BrotliDecoderDestroyInstance(c->dec);
        c->dec = NULL;
    }
    if (c->enc) {
        BrotliEncoderDestroyInstance(c->enc);
        c->enc = NULL;
    }
    c->status = ST_CLOSED;
}

static Coder* pushCoder(lua_State* L, const char* className)
{
    Coder* c = (Coder*)lua_newuserdata(L, sizeof(Coder));                /* -> coder */
    memset(c, 0, sizeof(Coder));
    c->status  = ST_CLOSED;
    c->maxsize = CB_NO_LIMIT;
    luaL_setmetatable(L, className);
    return c;
}

static Coder* newDecoder(lua_State* L, const Options* o)
{
    Coder* c = pushCoder(L, BROTLI_DECOMPRESSOR_CLASS_NAME);            /* -> coder */
    c->dec = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    if (!c->dec) {
        luaL_error(L, "cannot create Brotli decoder");
    }
    c->maxsize = o->maxsize;
    c->allowTrailing = o->allowTrailing;
    c->status  = ST_OPEN;
    return c;
}

static Coder* newEncoder(lua_State* L, const Options* o)
{
    Coder* c = pushCoder(L, BROTLI_COMPRESSOR_CLASS_NAME);              /* -> coder */
    c->enc = BrotliEncoderCreateInstance(NULL, NULL, NULL);
    if (!c->enc) {
        luaL_error(L, "cannot create Brotli encoder");
    }
    BrotliEncoderSetParameter(c->enc, BROTLI_PARAM_QUALITY, (uint32_t)o->quality);
    BrotliEncoderSetParameter(c->enc, BROTLI_PARAM_LGWIN,   (uint32_t)o->lgwin);
    BrotliEncoderSetParameter(c->enc, BROTLI_PARAM_MODE,    (uint32_t)o->mode);
    if (o->sizehint > 0) {
        size_t hint = (o->sizehint < CB_MAX_HINT) ? o->sizehint : CB_MAX_HINT;
        BrotliEncoderSetParameter(c->enc, BROTLI_PARAM_SIZE_HINT, (uint32_t)hint);
    }
    c->status = ST_OPEN;
    return c;
}

/* checks that the stream object at index 1 may be used and marks it busy */
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

static int fail(lua_State* L, Coder* c, Output* o, const char* msg)
{
    outDiscard(o);
    lua_pushstring(L, msg);
    return failTop(L, c, o);
}

/* records an error of the decoder */
static void setError(Coder* c, const char* func, const char* msg)
{
    c->msgFunc = func;
    c->msg     = msg;
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

/* the name of the decoder's error code, e.g. "ERROR_FORMAT_PADDING_1" (a static string) */
static const char* decoderErrorName(Coder* c)
{
    const char* s = BrotliDecoderErrorString(BrotliDecoderGetErrorCode(c->dec));
    if (*s == '_') {
        ++s;   /* "_ERROR_FORMAT_..." */
    }
    return s;
}

/* ============================================================================================ */

/*
 * Feeds the input to the decoder until all of it is consumed, the stream ends or an
 * error occurs. Raises no error of its own (only Lua errors of the output, e.g. out of
 * memory). Returns a BrotliDecoderResult:
 *   SUCCESS           - the end of the stream was reached, *consumed: the input bytes up
 *                       to it (c->status ST_DONE);
 *   NEEDS_MORE_INPUT  - all input consumed, the stream goes on;
 *   ERROR             - invalid data, the error recorded in the coder, c->failed set;
 *   NEEDS_MORE_OUTPUT - the output would exceed maxsize: no more than maxsize bytes are
 *                       written to the output, c->failed set.
 */
static BrotliDecoderResult runDecoder(Coder* c, const Input* in, Output* o, size_t want,
                                      size_t* consumed)
{
    const uint8_t*      next  = in->ptr;
    size_t              avail = in->len;
    BrotliDecoderResult r;
    uint8_t             extra[1];

    c->status = ST_BUSY;
    for (;;) {
        size_t   space, aout, produced;
        uint8_t* p;
        uint8_t* np;
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
            if (space > want) {
                space = want;   /* a carray target may have more space: keep to maxsize */
            }
        }
        np   = p;
        aout = space;
        r    = BrotliDecoderDecompressStream(c->dec, &avail, &next, &aout, &np, NULL);
        produced = space - aout;
        if (overflow) {
            if (produced > 0 || r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT
                || BrotliDecoderHasMoreOutput(c->dec))
            {
                setError(c, NULL, MSG_MAXSIZE);
                c->failed = BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
                r         = BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
                break;
            }
        } else {
            outCommit(o, produced);
            c->total += produced;
        }
        if (r == BROTLI_DECODER_RESULT_ERROR) {
            setError(c, MSG_DECODER_FUNC, decoderErrorName(c));
            c->failed = BROTLI_DECODER_RESULT_ERROR;
            break;
        }
        if (r != BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT && !BrotliDecoderHasMoreOutput(c->dec)) {
            /* NEEDS_MORE_INPUT can coincide with the output buffer having filled up at the
             * exact same byte, in which case there is still pending output to drain even
             * though the result code alone says otherwise. */
            break;
        }
        if (!overflow) {
            want = outGrow(o);
        }
    }
    *consumed = in->len - avail;
    c->status = (r == BROTLI_DECODER_RESULT_SUCCESS) ? ST_DONE : ST_OPEN;
    return r;
}

/*
 * The raising variant for update/finish/decompress: an error closes the coder. Returns
 * 1 at the end of the stream (after checking for trailing data), 0 if more input is
 * expected.
 */
static int decodeOrFail(lua_State* L, Coder* c, const Input* in, Output* o, size_t want)
{
    size_t              consumed;
    BrotliDecoderResult r = runDecoder(c, in, o, want, &consumed);
    if (r == BROTLI_DECODER_RESULT_SUCCESS) {
        if (consumed < in->len && !c->allowTrailing) {
            setError(c, MSG_DECODER_FUNC, MSG_TRAILING);
            failCoder(L, c, o);
        }
        return 1;
    }
    if (r != BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) {
        failCoder(L, c, o);
    }
    return 0;
}

static int failEndOfInput(lua_State* L, Coder* c, Output* o)
{
    setError(c, MSG_DECODER_FUNC, MSG_END_OF_INPUT);
    return failCoder(L, c, o);
}

static int failTrailing(lua_State* L, Coder* c, Output* o)
{
    setError(c, MSG_DECODER_FUNC, MSG_TRAILING);
    return failCoder(L, c, o);
}

/*
 * Feeds the input to the encoder with the given operation until all input is consumed
 * and all output is taken (for FINISH: until the stream is finished).
 */
static void runEncoder(lua_State* L, Coder* c, Input* in, Output* o, BrotliEncoderOperation op,
                       size_t want)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;

    c->status = ST_BUSY;
    for (;;) {
        size_t   space, aout;
        uint8_t* p  = outPrep(o, want, &space);
        uint8_t* np = p;
        aout = space;
        if (!BrotliEncoderCompressStream(c->enc, op, &avail, &next, &aout, &np, NULL)) {
            fail(L, c, o, MSG_ENCODER_ERROR);
        }
        outCommit(o, space - aout);
        if (avail == 0 && !BrotliEncoderHasMoreOutput(c->enc)
            && (op != BROTLI_OPERATION_FINISH || BrotliEncoderIsFinished(c->enc)))
        {
            break;
        }
        want = outGrow(o);
    }
    c->status = ST_OPEN;
}

/*
 * The fallback of BrotliEncoderCompress() for output larger than
 * BrotliEncoderMaxCompressedSize(): the data as uncompressed meta-blocks. Same
 * bytes as MakeUncompressedStream() in libbrotli's enc/encode.c (MIT license,
 * Copyright 2013 Google Inc.), so that compress() gives the same output as
 * BrotliEncoderCompress(). out must have space for BrotliEncoderMaxCompressedSize(n)
 * bytes, n > 0.
 */
static size_t makeUncompressedStream(const uint8_t* in, size_t n, uint8_t* out)
{
    size_t r = 0;
    out[r++] = 0x21;   /* window bits = 10, is_last = false */
    out[r++] = 0x03;   /* empty metadata, padding */
    while (n > 0) {
        uint32_t nibbles = 0;
        uint32_t chunk   = (n > ((size_t)1 << 24)) ? ((uint32_t)1 << 24) : (uint32_t)n;
        uint32_t bits;
        if (chunk > ((uint32_t)1 << 16)) {
            nibbles = (chunk > ((uint32_t)1 << 20)) ? 2 : 1;
        }
        bits = (nibbles << 1) | ((chunk - 1) << 3) | ((uint32_t)1 << (19 + 4 * nibbles));
        out[r++] = (uint8_t)bits;
        out[r++] = (uint8_t)(bits >> 8);
        out[r++] = (uint8_t)(bits >> 16);
        if (nibbles == 2) {
            out[r++] = (uint8_t)(bits >> 24);
        }
        memcpy(out + r, in, chunk);
        r  += chunk;
        in += chunk;
        n  -= chunk;
    }
    out[r++] = 3;
    return r;
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

/* compress.brotli.decompress(data [, opts] [, out]) */
static int Brotli_decompress(lua_State* L)
{
    Input   in;
    Options opt;
    Output  o;
    Coder*  c;
    int     optsArg;
    int     outArg;

    checkInput(L, 1, &in);
    outArg = checkOptsOut(L, 2, &optsArg);
    checkOptions(L, optsArg, "decompress", OPT_MAXSIZE | OPT_TRAILING, &opt);
    c = newDecoder(L, &opt);
    outInit(L, &o, outArg, outArg, 1);

    if (!decodeOrFail(L, c, &in, &o, decompressGuess(in.len))) {
        failEndOfInput(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.brotli.compress(data [, opts] [, out]) */
static int Brotli_compress(lua_State* L)
{
    Input   in;
    Options opt;
    Output  o;
    Coder*  c;
    int     optsArg;
    int     outArg;

    checkInput(L, 1, &in);
    outArg = checkOptsOut(L, 2, &optsArg);
    checkOptions(L, optsArg, "compress", OPT_QUALITY | OPT_LGWIN | OPT_MODE, &opt);
    opt.sizehint = in.len;   /* as BrotliEncoderCompress() does, for the same output */
    c = newEncoder(L, &opt);
    outInit(L, &o, outArg, outArg, 1);

    if (in.len == 0) {
        /* the shortest stream, as BrotliEncoderCompress() gives it */
        size_t   space;
        uint8_t* p = outPrep(&o, 1, &space);
        *p = 6;
        outCommit(&o, 1);
    } else {
        size_t bound = BrotliEncoderMaxCompressedSize(in.len);
        runEncoder(L, c, &in, &o, BROTLI_OPERATION_FINISH, compressGuess(in.len));
        if (bound > 0 && o.len > bound) {
            /* incompressible data: the fallback of BrotliEncoderCompress() */
            size_t   space;
            uint8_t* p;
            releaseCoder(c);
            if (o.capi) {
                o.len = 0;
            } else {
                /* a new buffer on top of the old one, only the top value is returned */
                outInit(L, &o, 0, 0, 0);
            }
            p = outPrep(&o, bound, &space);
            outCommit(&o, makeUncompressedStream(in.ptr, in.len, p));
        }
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.brotli.decompressor([opts]) */
static int Brotli_decompressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "decompressor", OPT_MAXSIZE | OPT_TRAILING, &opt);
    newDecoder(L, &opt);
    return 1;
}

/* compress.brotli.compressor([opts]) */
static int Brotli_compressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "compressor", OPT_QUALITY | OPT_LGWIN | OPT_MODE | OPT_SIZEHINT, &opt);
    newEncoder(L, &opt);
    return 1;
}

static void pushVersion(lua_State* L, uint32_t v)
{
    /* BROTLI_VERSION layout: 0xMMMmmmppp */
    lua_pushfstring(L, "%d.%d.%d", (int)(v >> 24), (int)((v >> 12) & 0xFFF), (int)(v & 0xFFF));
}

/* compress.brotli.version() -> decoder version, encoder version */
static int Brotli_version(lua_State* L)
{
    pushVersion(L, BrotliDecoderVersion());
    pushVersion(L, BrotliEncoderVersion());
    return 2;
}

/* ============================================================================================ */
/* decompressor methods                                                                         */
/* ============================================================================================ */

#define DEC_WHAT "decompressor"
#define ENC_WHAT "compressor"

/* decompressor:update(chunk [, out]) -> string or nil, or out */
static int Decompressor_update(lua_State* L)
{
    Coder* c = checkStream(L, BROTLI_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
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
    Coder* c = checkStream(L, BROTLI_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
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
        failEndOfInput(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/*
 * decompressor:decompress(chunk [, out]) -> output, status, consumed
 *
 * Raises no error for the data: the status tells the caller (a BrotliDecoderResult).
 * output is a string ("" if there is none), or out.
 */
static int Decompressor_decompress(lua_State* L)
{
    Coder*              c = checkStream(L, BROTLI_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
    Input               in;
    Output              o;
    size_t              consumed = 0;
    BrotliDecoderResult r;

    checkInput(L, 2, &in);
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    if (c->failed) {
        r = (BrotliDecoderResult)c->failed;
    } else if (c->status == ST_DONE) {
        r = BROTLI_DECODER_RESULT_SUCCESS;   /* nothing more is consumed */
    } else {
        r = runDecoder(c, &in, &o, decompressGuess(in.len), &consumed);
    }
    outPush(&o, 0);
    lua_pushinteger(L, (lua_Integer)r);
    lua_pushinteger(L, (lua_Integer)consumed);
    return 3;
}

/* decompressor:msg() -> message of the last error, or nil */
static int Decompressor_msg(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, BROTLI_DECOMPRESSOR_CLASS_NAME);
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

/* compressor:update/flush/finish(chunk [, out]): chunk at 2, out at 3 */
static int compressorOp(lua_State* L, BrotliEncoderOperation op, int chunkOptional)
{
    Coder* c = checkStream(L, BROTLI_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    Input  in;
    Output o;

    if (chunkOptional) {
        optInput(L, 2, &in);
    } else {
        checkInput(L, 2, &in);
    }
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    runEncoder(L, c, &in, &o, op, LUAL_BUFFERSIZE);
    if (op == BROTLI_OPERATION_FINISH) {
        releaseCoder(c);
    }
    outPush(&o, op != BROTLI_OPERATION_FINISH);
    return 1;
}

/* compressor:update(chunk [, out]) -> string or nil, or out */
static int Compressor_update(lua_State* L)
{
    return compressorOp(L, BROTLI_OPERATION_PROCESS, 0);
}

/* compressor:flush([chunk [, out]]) -> string or nil, or out */
static int Compressor_flush(lua_State* L)
{
    return compressorOp(L, BROTLI_OPERATION_FLUSH, 1);
}

/* compressor:finish([chunk [, out]]) -> string, or out */
static int Compressor_finish(lua_State* L)
{
    return compressorOp(L, BROTLI_OPERATION_FINISH, 1);
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
    Coder* c = (Coder*)luaL_checkudata(L, 1, BROTLI_DECOMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", BROTLI_DECOMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

static int Compressor_toString(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, BROTLI_COMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", BROTLI_COMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

/* ============================================================================================ */

static const luaL_Reg ModuleFunctions[] =
{
    { "decompress",   Brotli_decompress   },
    { "compress",     Brotli_compress     },
    { "decompressor", Brotli_decompressor },
    { "compressor",   Brotli_compressor   },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg PlainModuleFunctions[] =
{
    { "version",      Brotli_version      },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg DecompressorMethods[] =
{
    { "update",       Decompressor_update  },
    { "finish",       Decompressor_finish  },
    { "decompress",   Decompressor_decompress },
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

/* the results of BrotliDecoderDecompressStream() with libbrotli's values */
typedef struct Constant
{
    const char* name;
    int         value;
} Constant;

static const Constant Constants[] =
{
    { "BROTLI_DECODER_RESULT_ERROR",             BROTLI_DECODER_RESULT_ERROR             },
    { "BROTLI_DECODER_RESULT_SUCCESS",           BROTLI_DECODER_RESULT_SUCCESS           },
    { "BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT",  BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT  },
    { "BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT", BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT },
    { NULL,                                      0                                       } /* sentinel */
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

int compress_brotli_init_module(lua_State* L, int module)
{
    int             capiCache = pushCapiCache(L);          /* -> cc */
    const Constant* k;

    if (luaL_newmetatable(L, BROTLI_DECOMPRESSOR_CLASS_NAME)) {   /* -> cc, meta */
        setupMeta(L, BROTLI_DECOMPRESSOR_CLASS_NAME, capiCache,
                  DecompressorMethods, DecompressorMetaMethods);
    }
    lua_pop(L, 1);                                         /* -> cc */

    if (luaL_newmetatable(L, BROTLI_COMPRESSOR_CLASS_NAME)) {     /* -> cc, meta */
        setupMeta(L, BROTLI_COMPRESSOR_CLASS_NAME, capiCache,
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
