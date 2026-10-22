.PHONY: default all brotli zlib lzma bzip2 multistate testcarray
default: all
all: brotli zlib lzma bzip2

BUILD_DATE  := $(shell date "+%Y-%m-%dT%H:%M:%S")

LNX_GCC_RUN := gcc -shared -fPIC -O2 -g -Werror=return-type
WIN_GCC_RUN := gcc -shared -fPIC -O2
MAC_GCC_RUN := MACOSX_DEPLOYMENT_TARGET=10.8 gcc -O2 -bundle -undefined dynamic_lookup -all_load

BROTLI_CFLAGS := $(shell pkg-config --cflags libbrotlidec libbrotlienc 2>/dev/null)
BROTLI_LIBS   := $(or $(shell pkg-config --libs libbrotlidec libbrotlienc 2>/dev/null),-lbrotlidec -lbrotlienc)

ZLIB_CFLAGS   := $(shell pkg-config --cflags zlib 2>/dev/null)
ZLIB_LIBS     := $(or $(shell pkg-config --libs zlib 2>/dev/null),-lz)

LZMA_CFLAGS   := $(shell pkg-config --cflags liblzma 2>/dev/null)
LZMA_LIBS     := $(or $(shell pkg-config --libs liblzma 2>/dev/null),-llzma)

BZIP2_CFLAGS  := $(shell pkg-config --cflags bzip2 2>/dev/null)
BZIP2_LIBS    := $(or $(shell pkg-config --libs bzip2 2>/dev/null),-lbz2)

# the flags of a library from pkg-config are always added to COPTS/LOPTS in its
# rule, so COPTS/LOPTS given on the command line or in sandbox.mk extend them
LNX_COPTS   :=
WIN_COPTS   := -I/mingw64/include/lua5.1
MAC_COPTS   := -I/usr/local/opt/lua/include/lua5.3

LNX_LOPTS   :=
WIN_LOPTS   :=
MAC_LOPTS   :=

LNX_SO_EXT  := so
WIN_SO_EXT  := dll
MAC_SO_EXT  := so

GCC_RUN     :=
SO_EXT      :=
COPTS       :=
LOPTS       :=

# platforms: LNX, WIN, MAC
# (may be set in sandbox.mk)

PLATFORM    := LNX
LUA_VERSION := 5.5

-include sandbox.mk

GCC_RUN       := $(or $(GCC_RUN),       $($(PLATFORM)_GCC_RUN))
SO_EXT        := $(or $(SO_EXT),        $($(PLATFORM)_SO_EXT))
COPTS         := $(or $(COPTS),         $($(PLATFORM)_COPTS))
LOPTS         := $(or $(LOPTS),         $($(PLATFORM)_LOPTS))

OUT_DIR       := build/lua$(LUA_VERSION)

# module compress.brotli -> build/lua$(LUA_VERSION)/compress/brotli.$(SO_EXT)
brotli:
	@mkdir -p $(OUT_DIR)/compress/
	$(GCC_RUN) $(COPTS) $(BROTLI_CFLAGS) \
	    -D COMPRESS_BROTLI_VERSION=Makefile"-$(BUILD_DATE)" \
	    brotli/main.c brotli/brotli.c \
	    brotli/brotli_compat.c  \
	    $(LOPTS) $(BROTLI_LIBS) \
	    -o $(OUT_DIR)/compress/brotli.$(SO_EXT)

# module compress.zlib -> build/lua$(LUA_VERSION)/compress/zlib.$(SO_EXT)
zlib:
	@mkdir -p $(OUT_DIR)/compress/
	$(GCC_RUN) $(COPTS) $(ZLIB_CFLAGS) \
	    -D COMPRESS_ZLIB_VERSION=Makefile"-$(BUILD_DATE)" \
	    zlib/main.c zlib/zlibmod.c \
	    zlib/zlib_compat.c  \
	    $(LOPTS) $(ZLIB_LIBS) \
	    -o $(OUT_DIR)/compress/zlib.$(SO_EXT)

# module compress.lzma -> build/lua$(LUA_VERSION)/compress/lzma.$(SO_EXT)
lzma:
	@mkdir -p $(OUT_DIR)/compress/
	$(GCC_RUN) $(COPTS) $(LZMA_CFLAGS) \
	    -D COMPRESS_LZMA_VERSION=Makefile"-$(BUILD_DATE)" \
	    lzma/main.c lzma/lzmamod.c \
	    lzma/lzma_compat.c  \
	    $(LOPTS) $(LZMA_LIBS) \
	    -o $(OUT_DIR)/compress/lzma.$(SO_EXT)

# module compress.bzip2 -> build/lua$(LUA_VERSION)/compress/bzip2.$(SO_EXT)
bzip2:
	@mkdir -p $(OUT_DIR)/compress/
	$(GCC_RUN) $(COPTS) $(BZIP2_CFLAGS) \
	    -D COMPRESS_BZIP2_VERSION=Makefile"-$(BUILD_DATE)" \
	    bzip2/main.c bzip2/bzip2mod.c \
	    bzip2/bzip2_compat.c  \
	    $(LOPTS) $(BZIP2_LIBS) \
	    -o $(OUT_DIR)/compress/bzip2.$(SO_EXT)

# Test helper module for tests/*/test02.lua (read-only and non-resizable carrays)
testcarray:
	@mkdir -p $(OUT_DIR)/
	$(GCC_RUN) $(COPTS) \
	    ../tests/testcarray.c \
	    -o $(OUT_DIR)/compress_testcarray.$(SO_EXT)

# Test helper module for tests/*/test03.lua (several Lua states, parallel threads)
multistate:
	@mkdir -p $(OUT_DIR)/
	$(GCC_RUN) $(COPTS) \
	    ../tests/multistate.c \
	    $(if $(filter WIN,$(PLATFORM)),,-lpthread) \
	    -o $(OUT_DIR)/compress_multistate.$(SO_EXT)
