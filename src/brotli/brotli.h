#ifndef COMPRESS_BROTLI_H
#define COMPRESS_BROTLI_H

#include "../common/util.h"

/* ============================================================================================ */

extern const char* const BROTLI_DECOMPRESSOR_CLASS_NAME;
extern const char* const BROTLI_COMPRESSOR_CLASS_NAME;

/* ============================================================================================ */

int compress_brotli_init_module(lua_State* L, int module);

/* ============================================================================================ */

#endif /* COMPRESS_BROTLI_H */
