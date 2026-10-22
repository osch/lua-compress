#ifndef COMPRESS_ZLIBMOD_H
#define COMPRESS_ZLIBMOD_H

#include "../common/util.h"

/* ============================================================================================ */

extern const char* const ZLIB_DECOMPRESSOR_CLASS_NAME;
extern const char* const ZLIB_COMPRESSOR_CLASS_NAME;

/* ============================================================================================ */

int compress_zlib_init_module(lua_State* L, int module);

/* ============================================================================================ */

#endif /* COMPRESS_ZLIBMOD_H */
