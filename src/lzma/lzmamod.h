#ifndef COMPRESS_LZMAMOD_H
#define COMPRESS_LZMAMOD_H

#include "../common/util.h"

/* ============================================================================================ */

extern const char* const CLZMA_DECOMPRESSOR_CLASS_NAME;
extern const char* const CLZMA_COMPRESSOR_CLASS_NAME;

/* ============================================================================================ */

int compress_lzma_init_module(lua_State* L, int module);

/* ============================================================================================ */

#endif /* COMPRESS_LZMAMOD_H */
