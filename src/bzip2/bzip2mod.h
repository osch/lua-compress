#ifndef COMPRESS_BZIP2MOD_H
#define COMPRESS_BZIP2MOD_H

#include "../common/util.h"

/* ============================================================================================ */

extern const char* const CBZ2_DECOMPRESSOR_CLASS_NAME;
extern const char* const CBZ2_COMPRESSOR_CLASS_NAME;

/* ============================================================================================ */

int compress_bzip2_init_module(lua_State* L, int module);

/* ============================================================================================ */

#endif /* COMPRESS_BZIP2MOD_H */
