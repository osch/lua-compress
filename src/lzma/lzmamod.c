#include <lzma.h>

#include "../common/data.h"
#include "lzmamod.h"

/* ============================================================================================ */

const char* const CLZMA_DECOMPRESSOR_CLASS_NAME = "compress.lzma.decompressor";
const char* const CLZMA_COMPRESSOR_CLASS_NAME   = "compress.lzma.compressor";

/* ============================================================================================ */

/* maxsize when no limit is given */
#define CL_NO_LIMIT    SIZE_MAX

/* the largest dictionary of liblzma's encoders (1.5 GiB) */
#define CL_DICT_SIZE_ENC_MAX   ((lua_Integer)1536 * 1024 * 1024)
/* the largest dictionary size the properties of a decoder can give */
#define CL_DICT_SIZE_DEC_MAX   ((lua_Integer)0xFFFFFFFF)

/* LZMA_FULL_BARRIER: liblzma 5.2 and later */
#if defined(LZMA_VERSION) && LZMA_VERSION >= UINT32_C(50020000)
#  define CL_HAVE_FULL_BARRIER 1
#endif

/* LZMA_FILTER_LZMA1EXT (raw LZMA1 with known uncompressed size): liblzma 5.4 and later */
#if defined(LZMA_FILTER_LZMA1EXT)
#  define CL_HAVE_LZMA1EXT 1
#endif

#define MSG_MAXSIZE         "output exceeds maxsize"
#define MSG_END_OF_INPUT    "unexpected end of input"
#define MSG_TRAILING        "unexpected data after end of stream"

/*
 * liblzma has no function for the messages of its status codes: these are the messages of
 * the xz command line tool (message_strm() in xz's message.c).
 */
static const char* retMessage(lzma_ret ret)
{
    switch (ret) {
        case LZMA_OK:                return "No error";
        case LZMA_STREAM_END:        return "End of stream";
        case LZMA_NO_CHECK:          return "No integrity check; not verifying file integrity";
        case LZMA_UNSUPPORTED_CHECK: return "Unsupported type of integrity check; "
                                            "not verifying file integrity";
        case LZMA_GET_CHECK:         return "Integrity check type is available";
        case LZMA_MEM_ERROR:         return "Cannot allocate memory";
        case LZMA_MEMLIMIT_ERROR:    return "Memory usage limit reached";
        case LZMA_FORMAT_ERROR:      return "File format not recognized";
        case LZMA_OPTIONS_ERROR:     return "Unsupported options";
        case LZMA_DATA_ERROR:        return "Compressed data is corrupt";
        case LZMA_BUF_ERROR:         return "Unexpected end of input";
        case LZMA_PROG_ERROR:        return "Internal error (bug)";
        default:                     return "Unknown error";
    }
}

/* ============================================================================================ */

#define FMT_XZ     1   /* default */
#define FMT_LZMA   2   /* .lzma, lzma_alone */
#define FMT_RAW    3
#define FMT_AUTO   4   /* decoder: xz or lzma, from the header */

#define FILTER_LZMA1  1
#define FILTER_LZMA2  2   /* default for format raw */

#define OPT_FORMAT    0x00001
#define OPT_PRESET    0x00002
#define OPT_LEVEL     0x00004   /* the common name of preset, allowed together with OPT_PRESET */
#define OPT_EXTREME   0x00008
#define OPT_CHECK     0x00010
#define OPT_FILTER    0x00020
#define OPT_PROPS     0x00040
#define OPT_DICTSIZE  0x00080
#define OPT_LC        0x00100
#define OPT_LP        0x00200
#define OPT_PB        0x00400
#define OPT_MODE      0x00800
#define OPT_NICELEN   0x01000
#define OPT_MF        0x02000
#define OPT_DEPTH     0x04000
#define OPT_SIZE      0x08000
#define OPT_MEMLIMIT  0x10000
#define OPT_MAXSIZE   0x20000
#define OPT_TRAILING  0x40000
#define OPT_OUT       0x80000   /* the former option out: never allowed, see optionError() */

/* the fields of lzma_options_lzma */
#define OPTS_TUNE     (OPT_DICTSIZE | OPT_LC | OPT_LP | OPT_PB | OPT_MODE | OPT_NICELEN | OPT_MF \
                       | OPT_DEPTH)
#define OPTS_ENCODER  (OPT_FORMAT | OPT_PRESET | OPT_EXTREME | OPT_CHECK | OPT_FILTER | OPTS_TUNE)
#define OPTS_DECODER  (OPT_FORMAT | OPT_FILTER | OPT_PROPS | OPT_DICTSIZE | OPT_LC | OPT_LP | OPT_PB \
                       | OPT_SIZE | OPT_MEMLIMIT | OPT_MAXSIZE | OPT_TRAILING)
#define OPTS_PROPERTIES (OPT_PRESET | OPT_EXTREME | OPT_FILTER | OPTS_TUNE)

typedef struct Options
{
    int         format;
    int         filter;
    uint32_t    preset;
    int         extreme;
    lzma_check  check;
    unsigned    given;         /* the OPT_* bits of the options given */
    uint32_t    dictSize;
    uint32_t    lc, lp, pb;
    lzma_mode   mode;
    uint32_t    niceLen;
    lzma_match_finder mf;
    uint32_t    depth;
    Input       props;         /* properties (OPT_PROPS given) */
    uint64_t    size;
    uint64_t    memlimit;
    size_t      maxsize;
    int         allowTrailing;
} Options;

static uint32_t checkIntOption(lua_State* L, int arg, lua_Integer min, lua_Integer max, const char* msg)
{
    lua_Integer v;
    if (!topInteger(L, &v) || v < min || v > max) {
        luaL_argerror(L, arg, msg);
    }
    return (uint32_t)v;
}

/* a non-negative integer as uint64_t (Lua numbers: up to 2^53 exactly) */
static uint64_t checkU64Option(lua_State* L, int arg, const char* msg)
{
    lua_Integer v;
    if (!topInteger(L, &v) || v < 0) {
        luaL_argerror(L, arg, msg);
    }
    return (uint64_t)v;
}

/*
 * A string option at the top of the stack whose value may also be given as one of the
 * integer constants of liblzma: names[i] corresponds to values[i]. Returns the value.
 */
static int checkNamedOption(lua_State* L, int arg, const char* const* names, const int* values,
                            const char* msg)
{
    int i;
    if (lua_type(L, -1) == LUA_TSTRING) {
        const char* s = lua_tostring(L, -1);
        for (i = 0; names[i]; ++i) {
            if (strcmp(s, names[i]) == 0) {
                return values[i];
            }
        }
    } else if (lua_type(L, -1) == LUA_TNUMBER) {
        lua_Integer v;
        if (topInteger(L, &v)) {
            for (i = 0; names[i]; ++i) {
                if (v == values[i]) {
                    return values[i];
                }
            }
        }
    }
    luaL_argerror(L, arg, msg);
    return 0;
}

static const char* const CheckNames[]  = { "none", "crc32", "crc64", "sha256", NULL };
static const int         CheckValues[] = { LZMA_CHECK_NONE, LZMA_CHECK_CRC32, LZMA_CHECK_CRC64,
                                           LZMA_CHECK_SHA256 };
static const char* const ModeNames[]   = { "fast", "normal", NULL };
static const int         ModeValues[]  = { LZMA_MODE_FAST, LZMA_MODE_NORMAL };
static const char* const MfNames[]     = { "hc3", "hc4", "bt2", "bt3", "bt4", NULL };
static const int         MfValues[]    = { LZMA_MF_HC3, LZMA_MF_HC4, LZMA_MF_BT2, LZMA_MF_BT3,
                                           LZMA_MF_BT4 };

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

/* the name of the first option of the set bits that was given (for error messages) */
static const char* firstGiven(unsigned given)
{
    if (given & OPT_DICTSIZE) return "dictSize";
    if (given & OPT_LC)       return "lc";
    if (given & OPT_LP)       return "lp";
    if (given & OPT_PB)       return "pb";
    if (given & OPT_MODE)     return "mode";
    if (given & OPT_NICELEN)  return "niceLen";
    if (given & OPT_MF)       return "mf";
    if (given & OPT_DEPTH)    return "depth";
    return "?";
}

/*
 * Reads the options table at arg (nil or absent: defaults). allowed is the set of
 * options valid for the calling function func (its name for error messages); arg 0:
 * no options. opts.properties stays on the stack while it is used.
 */
static void checkOptions(lua_State* L, int arg, const char* func, unsigned allowed, Options* o)
{
    int t       = arg ? lua_type(L, arg) : LUA_TNONE;
    int decoder = (allowed & OPT_MAXSIZE) != 0;

    memset(o, 0, sizeof(Options));
    o->format   = FMT_XZ;
    o->filter   = FILTER_LZMA2;
    o->preset   = LZMA_PRESET_DEFAULT;
    o->check    = LZMA_CHECK_CRC64;
    o->memlimit = UINT64_MAX;
    o->maxsize  = CL_NO_LIMIT;

    if (t != LUA_TNONE && t != LUA_TNIL) {
        if (t != LUA_TTABLE) {
            luaL_argerror(L, arg, lua_pushfstring(L, "table expected, got %s", luaL_typename(L, arg)));
        }
        lua_pushnil(L);                                                 /* -> key */
        while (lua_next(L, arg)) {                                      /* -> key, value */
            const char* name = (lua_type(L, -2) == LUA_TSTRING) ? lua_tostring(L, -2) : NULL;
            unsigned    opt  = 0;
            if (name) {
                if      (strcmp(name, "format")     == 0) opt = OPT_FORMAT;
                else if (strcmp(name, "preset")     == 0) opt = OPT_PRESET;
                else if (strcmp(name, "level")      == 0) opt = OPT_LEVEL;
                else if (strcmp(name, "extreme")    == 0) opt = OPT_EXTREME;
                else if (strcmp(name, "check")      == 0) opt = OPT_CHECK;
                else if (strcmp(name, "filter")     == 0) opt = OPT_FILTER;
                else if (strcmp(name, "properties") == 0) opt = OPT_PROPS;
                else if (strcmp(name, "dictSize")   == 0) opt = OPT_DICTSIZE;
                else if (strcmp(name, "lc")         == 0) opt = OPT_LC;
                else if (strcmp(name, "lp")         == 0) opt = OPT_LP;
                else if (strcmp(name, "pb")         == 0) opt = OPT_PB;
                else if (strcmp(name, "mode")       == 0) opt = OPT_MODE;
                else if (strcmp(name, "niceLen")    == 0) opt = OPT_NICELEN;
                else if (strcmp(name, "mf")         == 0) opt = OPT_MF;
                else if (strcmp(name, "depth")      == 0) opt = OPT_DEPTH;
                else if (strcmp(name, "size")       == 0) opt = OPT_SIZE;
                else if (strcmp(name, "memlimit")   == 0) opt = OPT_MEMLIMIT;
                else if (strcmp(name, "maxsize")    == 0) opt = OPT_MAXSIZE;
                else if (strcmp(name, "allowtrailing") == 0) opt = OPT_TRAILING;
                else if (strcmp(name, "out")        == 0) opt = OPT_OUT;
            }
            if (!(opt & (allowed | ((allowed & OPT_PRESET) ? OPT_LEVEL : 0)))) {
                optionError(L, arg, func, name, opt);
            }
            switch (opt) {
                case OPT_FORMAT: {
                    const char* f = (lua_type(L, -1) == LUA_TSTRING) ? lua_tostring(L, -1) : "";
                    if      (strcmp(f, "xz")   == 0) o->format = FMT_XZ;
                    else if (strcmp(f, "lzma") == 0) o->format = FMT_LZMA;
                    else if (strcmp(f, "raw")  == 0) o->format = FMT_RAW;
                    else if (strcmp(f, "auto") == 0 && decoder) o->format = FMT_AUTO;
                    else luaL_argerror(L, arg, "invalid format value");
                    break;
                }
                case OPT_PRESET:
                case OPT_LEVEL: {
                    uint32_t v = checkIntOption(L, arg, 0, 9, (opt == OPT_PRESET) ? "invalid preset value"
                                                                                : "invalid level value");
                    if ((o->given & (OPT_PRESET | OPT_LEVEL)) && o->preset != v) {
                        /* both given (in any order of lua_next()) */
                        luaL_argerror(L, arg, "level contradicts preset");
                    }
                    o->preset = v;
                    break;
                }
                case OPT_EXTREME:
                    if (lua_type(L, -1) != LUA_TBOOLEAN) {
                        luaL_argerror(L, arg, "invalid extreme value");
                    }
                    o->extreme = lua_toboolean(L, -1);
                    break;
                case OPT_CHECK:
                    o->check = (lzma_check)checkNamedOption(L, arg, CheckNames, CheckValues,
                                                            "invalid check value");
                    break;
                case OPT_FILTER: {
                    const char* f = (lua_type(L, -1) == LUA_TSTRING) ? lua_tostring(L, -1) : "";
                    if      (strcmp(f, "lzma1") == 0) o->filter = FILTER_LZMA1;
                    else if (strcmp(f, "lzma2") == 0) o->filter = FILTER_LZMA2;
                    else luaL_argerror(L, arg, "invalid filter value");
                    break;
                }
                case OPT_DICTSIZE:
                    o->dictSize = checkIntOption(L, arg, LZMA_DICT_SIZE_MIN,
                                                 decoder ? CL_DICT_SIZE_DEC_MAX : CL_DICT_SIZE_ENC_MAX,
                                                 "invalid dictSize value");
                    break;
                case OPT_LC:
                    o->lc = checkIntOption(L, arg, LZMA_LCLP_MIN, LZMA_LCLP_MAX, "invalid lc value");
                    break;
                case OPT_LP:
                    o->lp = checkIntOption(L, arg, LZMA_LCLP_MIN, LZMA_LCLP_MAX, "invalid lp value");
                    break;
                case OPT_PB:
                    o->pb = checkIntOption(L, arg, LZMA_PB_MIN, LZMA_PB_MAX, "invalid pb value");
                    break;
                case OPT_MODE:
                    o->mode = (lzma_mode)checkNamedOption(L, arg, ModeNames, ModeValues,
                                                          "invalid mode value");
                    break;
                case OPT_NICELEN:
                    o->niceLen = checkIntOption(L, arg, 2, 273, "invalid niceLen value");
                    break;
                case OPT_MF:
                    o->mf = (lzma_match_finder)checkNamedOption(L, arg, MfNames, MfValues,
                                                                "invalid mf value");
                    break;
                case OPT_DEPTH:
                    o->depth = checkIntOption(L, arg, 0, 0xFFFFFFFF, "invalid depth value");
                    break;
                case OPT_SIZE:
                    o->size = checkU64Option(L, arg, "invalid size value");
                    break;
                case OPT_MEMLIMIT:
                    o->memlimit = checkU64Option(L, arg, "invalid memlimit value");
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
                    if (lua_type(L, -1) != LUA_TBOOLEAN) {
                        luaL_argerror(L, arg, "invalid allowtrailing value");
                    }
                    o->allowTrailing = lua_toboolean(L, -1);
                    break;
                default: /* OPT_PROPS, handled below */
                    break;
            }
            o->given |= opt;
            lua_pop(L, 1);                                              /* -> key */
        }                                                               /* -> */
        if (o->given & OPT_PROPS) {
            lua_getfield(L, arg, "properties");                         /* -> props */
            if (!toInput(L, -1, arg, "properties: ", &o->props)) {
                luaL_argerror(L, arg, lua_pushfstring(L, "properties: string or carray expected, got %s",
                                                         luaL_typename(L, -1)));
            }
            /* props stays on the stack */
        }
    }

    /* options that depend on the format */
    if (allowed & OPT_FORMAT) {
        if ((o->given & OPT_CHECK) && o->format != FMT_XZ) {
            luaL_argerror(L, arg, "check is only supported for format 'xz'");
        }
        if ((o->given & OPT_FILTER) && o->format != FMT_RAW) {
            luaL_argerror(L, arg, "filter is only supported for format 'raw'");
        }
        if ((o->given & OPT_PROPS) && o->format != FMT_RAW) {
            luaL_argerror(L, arg, "properties is only supported for format 'raw'");
        }
        if (decoder && (o->given & OPTS_TUNE) && o->format != FMT_RAW) {
            /* the other formats have the parameters in their headers */
            luaL_argerror(L, arg, lua_pushfstring(L, "%s is only supported for format 'raw'",
                                                     firstGiven(o->given & OPTS_TUNE)));
        }
    }
    if ((o->given & OPT_PROPS) && (o->given & OPTS_TUNE)) {
        luaL_argerror(L, arg, lua_pushfstring(L, "properties cannot be combined with %s",
                                                 firstGiven(o->given & OPTS_TUNE)));
    }
    if (o->given & OPT_SIZE) {
        if (o->format != FMT_RAW || o->filter != FILTER_LZMA1) {
            luaL_argerror(L, arg, "size is only supported for format 'raw' with filter 'lzma1'");
        }
#ifndef CL_HAVE_LZMA1EXT
        luaL_argerror(L, arg, "size is not supported by this liblzma version (5.4 or later is needed)");
#endif
    }
}

/*
 * Sets up the LZMA1/LZMA2 options from preset, extreme and the fields given; raises an
 * argument error of arg if lc + lp exceeds 4.
 */
static void buildLzmaOptions(lua_State* L, int arg, const Options* o, lzma_options_lzma* opt)
{
    uint32_t lc, lp;
    memset(opt, 0, sizeof(*opt));
    if (lzma_lzma_preset(opt, o->preset | (o->extreme ? LZMA_PRESET_EXTREME : 0))) {
        luaL_argerror(L, arg, "invalid preset value");   /* not expected: 0..9 is checked */
    }
    if (o->given & OPT_DICTSIZE) opt->dict_size = o->dictSize;
    if (o->given & OPT_LC)       opt->lc        = o->lc;
    if (o->given & OPT_LP)       opt->lp        = o->lp;
    if (o->given & OPT_PB)       opt->pb        = o->pb;
    if (o->given & OPT_MODE)     opt->mode      = o->mode;
    if (o->given & OPT_NICELEN)  opt->nice_len  = o->niceLen;
    if (o->given & OPT_MF)       opt->mf        = o->mf;
    if (o->given & OPT_DEPTH)    opt->depth     = o->depth;
    lc = opt->lc;
    lp = opt->lp;
    if (lc + lp > LZMA_LCLP_MAX) {
        luaL_argerror(L, arg, "lc + lp must not exceed 4");
    }
}

/* ============================================================================================ */

/*
 * Native encoder or decoder state, owned by a userdata with __gc: the state is also
 * released if a Lua error (e.g. out of memory) interrupts a call. The one-shot
 * functions use such a userdata too and release the state before they return.
 */
typedef struct Coder
{
    lzma_stream z;
    int         kind;          /* K_NONE, K_DECODER, K_ENCODER: is z initialized */
    int         status;
    int         format;
    int         filter;        /* format raw: the filter */
    unsigned    flushModes;    /* encoder: the supported flush modes (FLUSH_* bits) */
    int         endless;       /* decoder: raw LZMA1 without size, the end of the input ends it */
    size_t      total;         /* decoder: bytes produced so far */
    size_t      maxsize;       /* decoder: limit for total */
    int         allowTrailing; /* decoder: ignore data after the end */
    int         failed;        /* decoder: the stream cannot go on, the status is failedRet */
    lzma_ret    failedRet;
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

#define FLUSH_SYNC     0x01
#define FLUSH_FULL     0x02
#define FLUSH_BARRIER  0x04

static void releaseCoder(Coder* c)
{
    if (c->kind != K_NONE) {
        lzma_end(&c->z);
    }
    c->kind   = K_NONE;
    c->status = ST_CLOSED;
}

static Coder* pushCoder(lua_State* L, const char* className)
{
    lzma_stream init = LZMA_STREAM_INIT;
    Coder* c = (Coder*)lua_newuserdata(L, sizeof(Coder));                /* -> coder */
    memset(c, 0, sizeof(Coder));
    c->z       = init;
    c->status  = ST_CLOSED;
    c->maxsize = CL_NO_LIMIT;
    luaL_setmetatable(L, className);
    return c;
}

/* raises "Error in <func>: <message of ret>" for a failed init, the coder stays closed */
static int failInit(lua_State* L, Coder* c, const char* func, lzma_ret ret)
{
    releaseCoder(c);
    return luaL_error(L, "Error in %s: %s", func, retMessage(ret));
}

static Coder* newDecoder(lua_State* L, int optsArg, const Options* o)
{
    Coder*      c = pushCoder(L, CLZMA_DECOMPRESSOR_CLASS_NAME);        /* -> coder */
    lzma_ret    ret = LZMA_OK;
    const char* func = NULL;

    c->format        = o->format;
    c->filter        = o->filter;
    c->maxsize       = o->maxsize;
    c->allowTrailing = o->allowTrailing;
    switch (o->format) {
        case FMT_XZ:
            func = "lzma_stream_decoder";
            ret  = lzma_stream_decoder(&c->z, o->memlimit, 0);
            break;
        case FMT_LZMA:
            func = "lzma_alone_decoder";
            ret  = lzma_alone_decoder(&c->z, o->memlimit);
            break;
        case FMT_AUTO:
            func = "lzma_auto_decoder";
            ret  = lzma_auto_decoder(&c->z, o->memlimit, 0);
            break;
        default: {
            lzma_options_lzma  opt;
            lzma_filter        filters[2];
            void*              allocated = NULL;
            uint64_t           usage;
            filters[0].id      = (o->filter == FILTER_LZMA1) ? LZMA_FILTER_LZMA1 : LZMA_FILTER_LZMA2;
#ifdef CL_HAVE_LZMA1EXT
            if (o->given & OPT_SIZE) {
                filters[0].id  = LZMA_FILTER_LZMA1EXT;
            }
#endif
            filters[0].options = &opt;
            filters[1].id      = LZMA_VLI_UNKNOWN;
            filters[1].options = NULL;
            if (o->given & OPT_PROPS) {
                ret = lzma_properties_decode(&filters[0], NULL, o->props.ptr, o->props.len);
                if (ret != LZMA_OK) {
                    failInit(L, c, "lzma_properties_decode", ret);
                }
                allocated = filters[0].options;
            } else {
                buildLzmaOptions(L, optsArg, o, &opt);
            }
#ifdef CL_HAVE_LZMA1EXT
            if (o->given & OPT_SIZE) {
                lzma_options_lzma* p = (lzma_options_lzma*)filters[0].options;
                p->ext_flags     = LZMA_LZMA1EXT_ALLOW_EOPM;
                p->ext_size_low  = (uint32_t)(o->size & 0xFFFFFFFFu);
                p->ext_size_high = (uint32_t)(o->size >> 32);
            }
#endif
            /* liblzma's raw decoder has no memory limit: check it here, with the same
             * error status as the other decoders (given by the first call that decodes) */
            usage = lzma_raw_decoder_memusage(filters);
            if (usage != UINT64_MAX && usage > (o->memlimit ? o->memlimit : 1)) {
                free(allocated);
                c->failed    = 1;
                c->failedRet = LZMA_MEMLIMIT_ERROR;
                c->msgFunc   = "lzma_raw_decoder";
                c->msg       = retMessage(LZMA_MEMLIMIT_ERROR);
                c->status    = ST_OPEN;
                return c;
            }
            func = "lzma_raw_decoder";
            ret  = lzma_raw_decoder(&c->z, filters);
            free(allocated);   /* the decoder keeps a copy of the options */
            c->endless = (o->filter == FILTER_LZMA1 && !(o->given & OPT_SIZE));
            break;
        }
    }
    if (ret != LZMA_OK) {
        failInit(L, c, func, ret);
    }
    c->kind   = K_DECODER;
    c->status = ST_OPEN;
    return c;
}

static Coder* newEncoder(lua_State* L, int optsArg, const Options* o)
{
    Coder*            c = pushCoder(L, CLZMA_COMPRESSOR_CLASS_NAME);    /* -> coder */
    lzma_ret          ret;
    const char*       func;
    lzma_options_lzma opt;
    lzma_filter       filters[2];

    c->format = o->format;
    c->filter = o->filter;
    buildLzmaOptions(L, optsArg, o, &opt);
    filters[0].id      = LZMA_FILTER_LZMA2;
    filters[0].options = &opt;
    filters[1].id      = LZMA_VLI_UNKNOWN;
    filters[1].options = NULL;
    switch (o->format) {
        case FMT_XZ:
            if (!(o->given & OPTS_TUNE)) {
                /* the preset alone: lzma_easy_encoder(), as xz and Perl's EasyEncoder */
                func = "lzma_easy_encoder";
                ret  = lzma_easy_encoder(&c->z, o->preset | (o->extreme ? LZMA_PRESET_EXTREME : 0),
                                         o->check);
            } else {
                /* the same filter chain with changed LZMA2 options */
                func = "lzma_stream_encoder";
                ret  = lzma_stream_encoder(&c->z, filters, o->check);
            }
            c->flushModes = FLUSH_SYNC | FLUSH_FULL | FLUSH_BARRIER;
            break;
        case FMT_LZMA:
            func = "lzma_alone_encoder";
            ret  = lzma_alone_encoder(&c->z, &opt);
            c->flushModes = 0;
            break;
        default:
            if (o->filter == FILTER_LZMA1) {
                filters[0].id = LZMA_FILTER_LZMA1;
                c->flushModes = 0;
            } else {
                c->flushModes = FLUSH_SYNC;
            }
            func = "lzma_raw_encoder";
            ret  = lzma_raw_encoder(&c->z, filters);
            break;
    }
    if (ret != LZMA_OK) {
        failInit(L, c, func, ret);
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
static void setFailed(Coder* c, const char* func, const char* msg, lzma_ret ret)
{
    c->msgFunc   = func;
    c->msg       = msg;
    c->failed    = 1;
    c->failedRet = ret;
}

/* ============================================================================================ */

/*
 * Feeds the input to the decoder until all of it is consumed, the stream ends or an error
 * occurs. Raises no error of its own (only Lua errors of the output, e.g. out of memory).
 * Returns liblzma's status: LZMA_OK (all input consumed, the stream goes on),
 * LZMA_STREAM_END (*consumed: the input bytes up to the end of the stream) or an error
 * status with the message recorded in the coder (c->failed). maxsize: no more than maxsize
 * bytes are written to the output; if the stream has more, LZMA_BUF_ERROR is returned.
 *
 * Empty input does not call lzma_code(): liblzma returns LZMA_BUF_ERROR for the second of
 * two calls in a row without progress.
 */
static lzma_ret runDecode(Coder* c, const Input* in, Output* o, size_t want, size_t* consumed)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;
    lzma_ret       ret   = LZMA_OK;
    uint8_t        extra[1];

    *consumed = 0;
    if (c->failed) {
        return c->failedRet;
    }
    if (avail == 0) {
        return LZMA_OK;
    }
    c->status = ST_BUSY;
    for (;;) {
        size_t   space, used, produced;
        uint8_t* p;
        int      overflow = 0;
        if (c->maxsize != CL_NO_LIMIT) {
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
            if (c->maxsize != CL_NO_LIMIT && space > want) {
                space = want;   /* a carray target may have more space: keep to maxsize */
            }
        }
        c->z.next_in   = next;
        c->z.avail_in  = avail;
        c->z.next_out  = p;
        c->z.avail_out = space;
        ret = lzma_code(&c->z, LZMA_RUN);
        used     = avail - c->z.avail_in;
        produced = space - c->z.avail_out;
        next  += used;
        avail -= used;
        if (overflow) {
            if (produced > 0) {
                setFailed(c, NULL, MSG_MAXSIZE, LZMA_BUF_ERROR);
                ret = LZMA_BUF_ERROR;
                break;
            }
        } else {
            outCommit(o, produced);
            c->total += produced;
        }
        if (ret == LZMA_STREAM_END) {
            break;
        }
        if (ret == LZMA_BUF_ERROR && avail == 0) {
            ret = LZMA_OK;      /* no progress without input: more input is needed */
            break;
        }
        if (ret != LZMA_OK) {
            setFailed(c, "lzma_code", retMessage(ret), ret);
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
            ret = LZMA_PROG_ERROR;   /* no progress, not expected */
            setFailed(c, "lzma_code", retMessage(ret), ret);
            break;
        }
        ret = LZMA_OK;     /* all input consumed, more is expected */
        break;
    }
    *consumed = in->len - avail;
    c->status = (ret == LZMA_STREAM_END) ? ST_DONE : ST_OPEN;
    return ret;
}

/*
 * The raising variant for update/finish/decompress: an error closes the coder. Returns
 * 1 at the end of the stream (after checking for trailing data), 0 if more input is
 * expected.
 */
static int decodeOrFail(lua_State* L, Coder* c, const Input* in, Output* o, size_t want)
{
    size_t   consumed;
    lzma_ret ret = runDecode(c, in, o, want, &consumed);
    if (ret == LZMA_STREAM_END) {
        if (consumed < in->len && !c->allowTrailing) {
            c->msgFunc = "lzma_code";
            c->msg     = MSG_TRAILING;
            failCoder(L, c, o);
        }
        return 1;
    }
    if (ret != LZMA_OK) {
        failCoder(L, c, o);
    }
    return 0;
}

/* the end of the input before the end of the stream (not an error for raw LZMA1 without size) */
static void checkEnd(lua_State* L, Coder* c, Output* o)
{
    if (!c->endless) {
        c->msgFunc = "lzma_code";
        c->msg     = MSG_END_OF_INPUT;
        failCoder(L, c, o);
    }
}

/*
 * Feeds the input to the encoder with the given action until all input is consumed and
 * all output is taken (for a flush or LZMA_FINISH: until liblzma reports its end).
 */
static void runEncode(lua_State* L, Coder* c, const Input* in, Output* o, lzma_action action,
                      size_t want)
{
    const uint8_t* next  = in->ptr;
    size_t         avail = in->len;

    if (action == LZMA_RUN && avail == 0) {
        return;   /* no call without progress, see runDecode() */
    }
    c->status = ST_BUSY;
    for (;;) {
        size_t   space, used;
        uint8_t* p = outPrep(o, want, &space);
        lzma_ret ret;
        c->z.next_in   = next;
        c->z.avail_in  = avail;
        c->z.next_out  = p;
        c->z.avail_out = space;
        ret = lzma_code(&c->z, action);
        used   = avail - c->z.avail_in;
        next  += used;
        avail -= used;
        outCommit(o, space - c->z.avail_out);
        if (ret == LZMA_STREAM_END) {
            break;      /* the flush or the stream is complete */
        }
        if (ret != LZMA_OK) {
            c->msgFunc = "lzma_code";
            c->msg     = retMessage(ret);
            failCoder(L, c, o);
        }
        if (c->z.avail_out == 0) {
            want = outGrow(o);
            continue;
        }
        if (action == LZMA_RUN && avail == 0) {
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
static size_t compressGuess(size_t n)
{
    return n / 4 + 1024;
}

/* ============================================================================================ */
/* module functions                                                                             */
/* ============================================================================================ */

/* compress.lzma.decompress(data [, opts] [, out]) */
static int Lzma_decompress(lua_State* L)
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
    c = newDecoder(L, 2, &opt);
    outInit(L, &o, outArg, outArg, 1);

    if (!decodeOrFail(L, c, &in, &o, decompressGuess(in.len))) {
        checkEnd(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.lzma.compress(data [, opts] [, out]) */
static int Lzma_compress(lua_State* L)
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
    c = newEncoder(L, 2, &opt);
    outInit(L, &o, outArg, outArg, 1);

    runEncode(L, c, &in, &o, LZMA_FINISH, compressGuess(in.len));
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/* compress.lzma.decompressor([opts]) */
static int Lzma_decompressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "decompressor", OPTS_DECODER, &opt);
    newDecoder(L, 1, &opt);
    return 1;
}

/* compress.lzma.compressor([opts]) */
static int Lzma_compressor(lua_State* L)
{
    Options opt;
    checkOptions(L, 1, "compressor", OPTS_ENCODER, &opt);
    newEncoder(L, 1, &opt);
    return 1;
}

/*
 * compress.lzma.properties([opts]) -> the encoded properties of the LZMA1 or LZMA2 filter
 * (lzma_properties_encode()): 5 bytes for LZMA1 (lc/lp/pb byte, dictionary size as 32 bit
 * little endian), as 7z and the .lzma header store them, 1 byte for LZMA2.
 */
static int Lzma_properties(lua_State* L)
{
    Options           o;
    lzma_options_lzma opt;
    lzma_filter       filter;
    uint32_t          size = 0;
    uint8_t           buf[16];
    lzma_ret          ret;

    checkOptions(L, 1, "properties", OPTS_PROPERTIES, &o);
    buildLzmaOptions(L, 1, &o, &opt);
    filter.id      = (o.filter == FILTER_LZMA1) ? LZMA_FILTER_LZMA1 : LZMA_FILTER_LZMA2;
    filter.options = &opt;
    ret = lzma_properties_size(&size, &filter);
    if (ret == LZMA_OK && size > sizeof(buf)) {
        ret = LZMA_PROG_ERROR;
    }
    if (ret == LZMA_OK) {
        ret = lzma_properties_encode(&filter, buf);
    }
    if (ret != LZMA_OK) {
        return luaL_error(L, "Error in lzma_properties_encode: %s", retMessage(ret));
    }
    lua_pushlstring(L, (const char*)buf, size);
    return 1;
}

/* compress.lzma.version() -> liblzma version at runtime, liblzma version compiled against */
static int Lzma_version(lua_State* L)
{
    lua_pushstring(L, lzma_version_string());
    lua_pushstring(L, LZMA_VERSION_STRING);
    return 2;
}

/* ============================================================================================ */
/* decompressor methods                                                                         */
/* ============================================================================================ */

#define DEC_WHAT "decompressor"
#define ENC_WHAT "compressor"

static int failTrailing(lua_State* L, Coder* c, Output* o)
{
    c->msgFunc = "lzma_code";
    c->msg     = MSG_TRAILING;
    return failCoder(L, c, o);
}

/* decompressor:update(chunk [, out]) -> string or nil, or out */
static int Decompressor_update(lua_State* L)
{
    Coder* c = checkStream(L, CLZMA_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
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
    Coder* c = checkStream(L, CLZMA_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
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
        checkEnd(L, c, &o);
    }
    releaseCoder(c);
    outPush(&o, 0);
    return 1;
}

/*
 * decompressor:decompress(chunk [, out]) -> output, status, consumed
 * (also as decompressor:code, the name of Compress::Raw::Lzma)
 *
 * Raises no error for the data: the status tells the caller, as for Compress::Raw::Lzma's
 * $status = $z->code($in, $out). output is a string ("" if there is none), or out.
 */
static int Decompressor_decompress(lua_State* L)
{
    Coder*   c = checkStream(L, CLZMA_DECOMPRESSOR_CLASS_NAME, DEC_WHAT);
    Input    in;
    Output   o;
    size_t   consumed = 0;
    lzma_ret ret;

    checkInput(L, 2, &in);
    lua_settop(L, 3);
    outInit(L, &o, optOut(L, 3), 3, 2);
    if (c->status == ST_DONE) {
        /* as liblzma: the end of the stream again, nothing consumed */
        ret = LZMA_STREAM_END;
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
    Coder* c = (Coder*)luaL_checkudata(L, 1, CLZMA_DECOMPRESSOR_CLASS_NAME);
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
static int compressorOp(lua_State* L, Coder* c, lzma_action action, int chunkOptional, int outArg)
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
    if (action == LZMA_FINISH) {
        releaseCoder(c);
    }
    outPush(&o, action != LZMA_FINISH);
    return 1;
}

/* compressor:update(chunk [, out]) -> string or nil, or out */
static int Compressor_update(lua_State* L)
{
    Coder* c = checkStream(L, CLZMA_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    return compressorOp(L, c, LZMA_RUN, 0, 3);
}

/*
 * compressor:flush([chunk [, mode] [, out]]) -> string or nil (string for "finish"), or
 * out. A carray (userdata) at 3 is out, else 3 is the mode and 4 out.
 */
static int Compressor_flush(lua_State* L)
{
    Coder*      c      = checkStream(L, CLZMA_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    lzma_action action = LZMA_SYNC_FLUSH;
    int         t      = lua_type(L, 3);
    int         outArg = 4;
    unsigned    need   = 0;
    const char* name   = "sync";

    if (t == LUA_TUSERDATA || t == LUA_TNONE || t == LUA_TNIL) {
        outArg = (t == LUA_TUSERDATA) ? 3 : 4;
    } else if (t == LUA_TSTRING) {
        const char* m = lua_tostring(L, 3);
        if      (strcmp(m, "sync")    == 0) action = LZMA_SYNC_FLUSH;
        else if (strcmp(m, "full")    == 0) action = LZMA_FULL_FLUSH;
#ifdef CL_HAVE_FULL_BARRIER
        else if (strcmp(m, "barrier") == 0) action = LZMA_FULL_BARRIER;
#endif
        else if (strcmp(m, "finish")  == 0) action = LZMA_FINISH;
        else luaL_argerror(L, 3, "invalid flush mode");
    } else if (t == LUA_TNUMBER) {
        lua_Integer v;
        lua_pushvalue(L, 3);
        if (!topInteger(L, &v) || !(v == LZMA_RUN || v == LZMA_SYNC_FLUSH || v == LZMA_FULL_FLUSH
#ifdef CL_HAVE_FULL_BARRIER
                                    || v == LZMA_FULL_BARRIER
#endif
                                    || v == LZMA_FINISH)) {
            luaL_argerror(L, 3, "invalid flush mode");
        }
        lua_pop(L, 1);
        action = (lzma_action)v;
    } else {
        luaL_argerror(L, 3, "invalid flush mode");
    }
    switch (action) {
        case LZMA_SYNC_FLUSH:   need = FLUSH_SYNC;    name = "sync";    break;
        case LZMA_FULL_FLUSH:   need = FLUSH_FULL;    name = "full";    break;
#ifdef CL_HAVE_FULL_BARRIER
        case LZMA_FULL_BARRIER: need = FLUSH_BARRIER; name = "barrier"; break;
#endif
        default: break;
    }
    if (need && !(c->flushModes & need)) {
        /* raised before anything is done: the stream stays usable */
        if (c->format == FMT_RAW) {
            return luaL_error(L, "flush mode '%s' is not supported for filter '%s'", name,
                              (c->filter == FILTER_LZMA1) ? "lzma1" : "lzma2");
        }
        return luaL_error(L, "flush mode '%s' is not supported for format '%s'", name,
                          (c->format == FMT_LZMA) ? "lzma" : "xz");
    }
    return compressorOp(L, c, action, 1, outArg);
}

/* compressor:finish([chunk [, out]]) -> string, or out */
static int Compressor_finish(lua_State* L)
{
    Coder* c = checkStream(L, CLZMA_COMPRESSOR_CLASS_NAME, ENC_WHAT);
    return compressorOp(L, c, LZMA_FINISH, 1, 3);
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
    Coder* c = (Coder*)luaL_checkudata(L, 1, CLZMA_DECOMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", CLZMA_DECOMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

static int Compressor_toString(lua_State* L)
{
    Coder* c = (Coder*)luaL_checkudata(L, 1, CLZMA_COMPRESSOR_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", CLZMA_COMPRESSOR_CLASS_NAME, (void*)c);
    return 1;
}

/* ============================================================================================ */

static const luaL_Reg ModuleFunctions[] =
{
    { "decompress",   Lzma_decompress     },
    { "compress",     Lzma_compress       },
    { "decompressor", Lzma_decompressor   },
    { "compressor",   Lzma_compressor     },
    { "properties",   Lzma_properties     },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg PlainModuleFunctions[] =
{
    { "version",      Lzma_version        },
    { NULL,           NULL } /* sentinel */
};

static const luaL_Reg DecompressorMethods[] =
{
    { "update",       Decompressor_update  },
    { "finish",       Decompressor_finish  },
    { "decompress",   Decompressor_decompress },   /* also as "code", see below */
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

/* the constants of lzma.h with liblzma's values */
typedef struct Constant
{
    const char* name;
    uint32_t    value;
} Constant;

static const Constant Constants[] =
{
    /* status codes (lzma_ret) */
    { "LZMA_OK",                LZMA_OK                },
    { "LZMA_STREAM_END",        LZMA_STREAM_END        },
    { "LZMA_NO_CHECK",          LZMA_NO_CHECK          },
    { "LZMA_UNSUPPORTED_CHECK", LZMA_UNSUPPORTED_CHECK },
    { "LZMA_GET_CHECK",         LZMA_GET_CHECK         },
    { "LZMA_MEM_ERROR",         LZMA_MEM_ERROR         },
    { "LZMA_MEMLIMIT_ERROR",    LZMA_MEMLIMIT_ERROR    },
    { "LZMA_FORMAT_ERROR",      LZMA_FORMAT_ERROR      },
    { "LZMA_OPTIONS_ERROR",     LZMA_OPTIONS_ERROR     },
    { "LZMA_DATA_ERROR",        LZMA_DATA_ERROR        },
    { "LZMA_BUF_ERROR",         LZMA_BUF_ERROR         },
    { "LZMA_PROG_ERROR",        LZMA_PROG_ERROR        },
    /* actions (flush modes) */
    { "LZMA_RUN",               LZMA_RUN               },
    { "LZMA_SYNC_FLUSH",        LZMA_SYNC_FLUSH        },
    { "LZMA_FULL_FLUSH",        LZMA_FULL_FLUSH        },
#ifdef CL_HAVE_FULL_BARRIER
    { "LZMA_FULL_BARRIER",      LZMA_FULL_BARRIER      },
#endif
    { "LZMA_FINISH",            LZMA_FINISH            },
    /* integrity checks */
    { "LZMA_CHECK_NONE",        LZMA_CHECK_NONE        },
    { "LZMA_CHECK_CRC32",       LZMA_CHECK_CRC32       },
    { "LZMA_CHECK_CRC64",       LZMA_CHECK_CRC64       },
    { "LZMA_CHECK_SHA256",      LZMA_CHECK_SHA256      },
    /* presets */
    { "LZMA_PRESET_DEFAULT",    LZMA_PRESET_DEFAULT    },
    { "LZMA_PRESET_LEVEL_MASK", LZMA_PRESET_LEVEL_MASK },
    { "LZMA_PRESET_EXTREME",    LZMA_PRESET_EXTREME    },
    /* LZMA1/LZMA2 options */
    { "LZMA_MODE_FAST",         LZMA_MODE_FAST         },
    { "LZMA_MODE_NORMAL",       LZMA_MODE_NORMAL       },
    { "LZMA_MF_HC3",            LZMA_MF_HC3            },
    { "LZMA_MF_HC4",            LZMA_MF_HC4            },
    { "LZMA_MF_BT2",            LZMA_MF_BT2            },
    { "LZMA_MF_BT3",            LZMA_MF_BT3            },
    { "LZMA_MF_BT4",            LZMA_MF_BT4            },
    { "LZMA_DICT_SIZE_MIN",     LZMA_DICT_SIZE_MIN     },
    { "LZMA_DICT_SIZE_DEFAULT", LZMA_DICT_SIZE_DEFAULT },
    { "LZMA_LCLP_MIN",          LZMA_LCLP_MIN          },
    { "LZMA_LCLP_MAX",          LZMA_LCLP_MAX          },
    { "LZMA_LC_DEFAULT",        LZMA_LC_DEFAULT        },
    { "LZMA_LP_DEFAULT",        LZMA_LP_DEFAULT        },
    { "LZMA_PB_MIN",            LZMA_PB_MIN            },
    { "LZMA_PB_MAX",            LZMA_PB_MAX            },
    { "LZMA_PB_DEFAULT",        LZMA_PB_DEFAULT        },
    { NULL,                     0                      } /* sentinel */
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

int compress_lzma_init_module(lua_State* L, int module)
{
    int             capiCache = pushCapiCache(L);          /* -> cc */
    const Constant* k;

    if (luaL_newmetatable(L, CLZMA_DECOMPRESSOR_CLASS_NAME)) {    /* -> cc, meta */
        setupMeta(L, CLZMA_DECOMPRESSOR_CLASS_NAME, capiCache,
                  DecompressorMethods, DecompressorMetaMethods);
        /* code: the name of Compress::Raw::Lzma, the same function */
        lua_getfield(L, -1, "__index");                    /* -> cc, meta, Class */
        lua_getfield(L, -1, "decompress");                 /* -> cc, meta, Class, f */
        lua_setfield(L, -2, "code");                       /* -> cc, meta, Class */
        lua_pop(L, 1);                                     /* -> cc, meta */
    }
    lua_pop(L, 1);                                         /* -> cc */

    if (luaL_newmetatable(L, CLZMA_COMPRESSOR_CLASS_NAME)) {      /* -> cc, meta */
        setupMeta(L, CLZMA_COMPRESSOR_CLASS_NAME, capiCache,
                  CompressorMethods, CompressorMetaMethods);
    }
    lua_pop(L, 1);                                         /* -> cc */

    lua_pushvalue(L, module);                              /* -> cc, module */
        lua_pushvalue(L, capiCache);                       /* -> cc, module, cc */
        luaL_setfuncs(L, ModuleFunctions, 1);              /* -> cc, module */
        luaL_setfuncs(L, PlainModuleFunctions, 0);         /* -> cc, module */
        for (k = Constants; k->name; ++k) {
#if LUA_VERSION_NUM >= 503
            lua_pushinteger(L, (lua_Integer)k->value);     /* -> cc, module, value */
#else
            lua_pushnumber(L, (lua_Number)k->value);       /* lua_Integer may have 32 bits */
#endif
            lua_setfield(L, -2, k->name);                  /* -> cc, module */
        }
    lua_pop(L, 2);                                         /* -> */

    return 0;
}

/* ============================================================================================ */
