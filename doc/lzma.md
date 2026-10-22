# compress.lzma Documentation
<!-- ---------------------------------------------------------------------------------------- -->
##   Contents
<!-- ---------------------------------------------------------------------------------------- -->

   * [Overview](#overview)
   * [Data](#data)
   * [Formats](#formats)
   * [Raw LZMA1 and 7z](#raw-lzma1-and-7z)
   * [Module Functions](#module-functions)
        * [lzma.compress()](#lzma_compress)
        * [lzma.decompress()](#lzma_decompress)
        * [lzma.compressor()](#lzma_compressor)
        * [lzma.decompressor()](#lzma_decompressor)
        * [lzma.properties()](#lzma_properties)
        * [lzma.version()](#lzma_version)
        * [lzma._VERSION](#lzma__VERSION)
   * [Constants](#constants)
   * [Options](#options)
   * [Compressor Methods](#compressor-methods)
        * [compressor:update()](#compressor_update)
        * [compressor:flush()](#compressor_flush)
        * [compressor:finish()](#compressor_finish)
   * [Decompressor Methods](#decompressor-methods)
        * [decompressor:update()](#decompressor_update)
        * [decompressor:finish()](#decompressor_finish)
        * [decompressor:decompress()](#decompressor_decompress)
        * [decompressor:msg()](#decompressor_msg)
   * [Compressed Output](#compressed-output)
   * [Compatibility with Perl's Compress::Raw::Lzma](#compatibility-with-perls-compressrawlzma)
   * [Errors](#errors)
   * [Thread safety / multiple Lua states](#thread-safety--multiple-lua-states)
   * [Building](#building)

<!-- ---------------------------------------------------------------------------------------- -->
##   Overview
<!-- ---------------------------------------------------------------------------------------- -->

The [Lua] module *compress.lzma* of [lua-compress](../README.md) provides LZMA compression
in the formats xz, lzma (the legacy *.lzma* format of LZMA Utils) and raw LZMA1/LZMA2 
streams, based on *liblzma* of [XZ Utils]:

  * [lzma.compress()](#lzma_compress) and [lzma.decompress()](#lzma_decompress)
    process the whole data in one call.
  * [lzma.compressor()](#lzma_compressor) and 
    [lzma.decompressor()](#lzma_decompressor) create stream objects that take the 
    data in pieces, with the flush modes of liblzma.
  * [decompressor:decompress()](#decompressor_decompress) (also as *code()*) is the 
    variant of *decompressor:update()* that raises no errors for the data but returns 
    liblzma's status codes and the number of bytes consumed, for code that evaluates them 
    like Perl's *Compress::Raw::Lzma*.
  * The presets 0..9 and *extreme* of liblzma, the integrity checks of xz and the options
    of the LZMA1/LZMA2 filters (dictionary size, *lc*, *lp*, *pb*, mode, match finder, ...)
    can be given; with the same parameters and liblzma version the output is byte for 
    byte the same as that of the *xz* tool and of Perl's *Compress::Raw::Lzma*, see 
    [Compressed Output](#compressed-output).
  * Raw LZMA1 streams with the 5 byte coder properties, as 7z archives store them, are
    decoded with the option [properties](#option_properties), see 
    [Raw LZMA1 and 7z](#raw-lzma1-and-7z); [lzma.properties()](#lzma_properties) gives 
    the properties for encoder options.

Data may be Lua strings or [carray] objects, see [Data](#data). Errors are raised with
*error()*, see [Errors](#errors). The module follows the 
[Common Conventions](README.md#common-conventions) of lua-compress.

The module name to require is *"compress.lzma"*; it is also available as 
*require("compress").lzma* through the [meta module](README.md#the-meta-module-compress):

```lua
local lzma = require("compress.lzma")
```

This module works with Lua 5.1 up to 5.5 and LuaJIT. The [carray] module is optional: 
compress.lzma neither links against it nor requires it, carray objects are recognized
through the [Carray C API]. The rock *compress.lzma* depends on nothing but Lua and 
liblzma and can be installed without the other rocks of lua-compress.

The metatable names (*getmetatable()*) are *"compress.lzma"*, 
*"compress.lzma.compressor"* and *"compress.lzma.decompressor"*; the latter two also 
appear in *tostring()* of the stream objects.

[Lua]:          https://www.lua.org
[XZ Utils]:     https://tukaani.org/xz/
[carray]:       https://github.com/osch/lua-carray
[Carray C API]: https://github.com/lua-capis/lua-carray-capi

<!-- ---------------------------------------------------------------------------------------- -->
##   Data
<!-- ---------------------------------------------------------------------------------------- -->

The data to compress or decompress (argument *data*, and *chunk* of the stream methods)
and the [properties](#option_properties) may be

  * a Lua string (a number is converted to a string, as in the string library), or
  * a carray object with elements of 1 byte size (element types *"char"*, *"uchar"*, 
    *"schar"*, *"int8"*, *"uint8"*). Other element types raise an error. A carray is read
    directly from its buffer, without copying; read-only carrays are accepted.

Data may contain arbitrary binary data including NUL bytes.

The result is a Lua string. Every function and method (except *properties()* and 
*version()*) can instead append its output to a carray given as its last argument *out*
(see [Output](README.md#output-string-or-carray) in the Common Conventions):

  * the carray must have 1 byte elements and be writable and resizable, and must not be
    the same object as the input data of the call;
  * the output is appended after the carray's content, the carray is resized as needed 
    and returned instead of a string (also when nothing was appended); its capacity is 
    kept, so *buf:reset()* before a call reuses a carray without reallocation;
  * *lzma.compress(data, out)* is *lzma.compress(data, nil, out)*: the second argument 
    of the one-shot functions is the options table or *out*, told by its type;
  * the stream methods take *out* after *chunk* (and after the *mode* of 
    [flush](#compressor_flush), which is told from *out* by its type); without a chunk 
    *nil* is given: *c:finish(nil, out)*;
  * [maxsize](#option_maxsize) counts the output of the call (or stream), not the length 
    of the carray;
  * if a call raises an error, the carray is set back to its previous length; 
    [decompressor:decompress()](#decompressor_decompress), which raises no errors for 
    the data, appends the output up to the error.

```lua
local buf = carray.new("char")
lzma.compress(data, { preset = 9 }, buf)        -- buf contains the compressed data
buf:reset()                                     -- empty again, keeps the capacity
local c = lzma.compressor()
for chunk in inputFile:lines(65536) do
    c:update(chunk, buf)                        -- appended to buf
end
c:finish(nil, buf)
```

<!-- ---------------------------------------------------------------------------------------- -->
##   Formats
<!-- ---------------------------------------------------------------------------------------- -->

The option [*format*](#option_format) selects the format:

  * *"xz"* (default): the *.xz* format of XZ Utils: a stream header with the type of the
    integrity [check](#option_check), one block with the LZMA2 data (more after a
    [full flush](#compressor_flush)), the index and the stream footer. The decoder checks 
    the CRC32 of the headers and the integrity check of the data. Encoded with 
    *lzma_easy_encoder()* (preset only) or *lzma_stream_encoder()* with one LZMA2 filter
    (LZMA options given), decoded with *lzma_stream_decoder()*.
  * *"lzma"*: the legacy *.lzma* format (LZMA_Alone, LZMA Utils and the *lzma* tool of
    XZ Utils): the 5 property bytes of LZMA1 (lc/lp/pb and the dictionary size), the 
    uncompressed size (8 bytes; the encoder writes -1, unknown) and the LZMA1 data with
    an end marker. No integrity check. *lzma_alone_encoder()* / *lzma_alone_decoder()*;
    the decoder also reads files with a known size in the header.
  * *"raw"*: a raw LZMA2 (default) or LZMA1 stream without any header, selected with the
    option [*filter*](#option_filter). The decoder needs the parameters that the other 
    formats have in their headers: the [*properties*](#option_properties), or 
    *dictSize*, *lc*, *lp* and *pb* (defaults: those of preset 6). LZMA2 streams have 
    an end marker and their own chunk structure (they store *lc*, *lp*, *pb* themselves, 
    the decoder needs only a dictionary at least as large as the encoder's); LZMA1 
    streams are described in [Raw LZMA1 and 7z](#raw-lzma1-and-7z). 
    *lzma_raw_encoder()* / *lzma_raw_decoder()*.
  * *"auto"* (decompression only): xz or lzma, detected from the header 
    (*lzma_auto_decoder()*; liblzma 5.4 and later also detects lzip). Raw streams are not
    detected.

Only one stream is decompressed: data after its end raises an error (unless 
[*allowtrailing*](#option_allowtrailing) is set); concatenated xz streams, which the
*xz* tool decompresses one after the other, are such data. 
[decompressor:decompress()](#decompressor_decompress) gives the position of the end, so that 
a caller can go on with the next stream in a new decompressor.

<!-- ---------------------------------------------------------------------------------------- -->
##   Raw LZMA1 and 7z
<!-- ---------------------------------------------------------------------------------------- -->

7z archives store LZMA1 streams without header: the coder of the folder has the 5 byte 
coder properties (the same bytes as at the start of a *.lzma* file: *(pb \* 5 + lp) \* 9 
\+ lc*, then the dictionary size as 32 bit little endian), the folder the unpack size. 
7-Zip compresses the archive header itself with LZMA1 as well (the *encoded header* of 
*7z a -mhc=on*, the default). Such a stream is decoded with

```lua
local d = lzma.decompressor({ format = "raw", filter = "lzma1", properties = props })
local data, status, consumed = d:code(packed)     -- LZMA_OK: the stream has no end marker
-- or, with the unpack size of the folder (liblzma 5.4 and later):
local data = lzma.decompress(packed, { format = "raw", filter = "lzma1",
                                       properties = props, size = unpackSize })
```

Raw LZMA1 streams may end in two ways:

  * **With an end marker** (EOPM): as written by liblzma's raw LZMA1 encoder (and so by 
    *lzma.compress(data, { format = "raw", filter = "lzma1" })*), *xz --format=raw* and
    in *.lzma* files. The decoder ends there (*LZMA_STREAM_END*), and data after it is 
    noticed as for the other formats.
  * **Without an end marker**: as 7-Zip writes them, the decoder must know the size. 
      * Without the option [*size*](#option_size), **the end of the input is the end of 
        the stream**: the status method gives *LZMA_OK* for all of the input, and 
        *finish()* and *lzma.decompress()* accept the end of the input instead of 
        raising *unexpected end of input*. A truncated stream is not noticed, and at the
        end the decoder may produce a few bytes more than the encoder was given (the
        range coder's last bytes decode to further symbols): take the first *unpack 
        size* bytes of the output.
      * With the option [*size*](#option_size) (the uncompressed size; liblzma's 
        *LZMA_FILTER_LZMA1EXT*, liblzma 5.4 and later), the decoder ends after exactly 
        *size* bytes with *LZMA_STREAM_END*; an end marker after them is accepted 
        (*LZMA_LZMA1EXT_ALLOW_EOPM*), data after the end is noticed, and a truncated 
        stream raises *unexpected end of input*. With older liblzma versions the option
        raises *size is not supported by this liblzma version (5.4 or later is needed)*.

Without *properties* and without the explicit options, the raw LZMA1 decoder uses the 
options of preset 6 (8 MiB dictionary, lc 3, lp 0, pb 2): the defaults of Perl's 
*Lzma::Filter::Lzma1()*. A dictionary that is larger than the encoder's does no harm, 
*lc*, *lp* and *pb* must be the encoder's: so the default decodes every stream with these
three values and a dictionary of at most 8 MiB (as 7-Zip's encoded headers, which have 
lc 3, lp 0, pb 2 and a small dictionary).

[lzma.properties()](#lzma_properties) gives the properties for the options of an 
encoder: *lzma.properties({ filter = "lzma1", dictSize = 65536 })* is *"\93\0\0\1\0"*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Module Functions
<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma_compress">**`lzma.compress(data[, opts][, out])
  `**</span>
  
  Compresses *data* and returns the compressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray, see [Data](#data). May be empty.
  * *opts* - optional table with the [options](#options) *format*, *preset* (or 
    *level*), *extreme*, *check*, *filter*, *dictSize*, *lc*, *lp*, *pb*, *mode*, 
    *niceLen*, *mf* and *depth*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  The result is the output of *lzma_code(LZMA_FINISH)* for the whole data, see 
  [Compressed Output](#compressed-output).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma_decompress">**`lzma.decompress(data[, opts][, out])
  `**</span>
  
  Decompresses *data* and returns the decompressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray containing exactly one complete stream of the format.
  * *opts* - optional table with the [options](#options) *format*, *filter*, 
    *properties*, *dictSize*, *lc*, *lp*, *pb*, *size*, *memlimit*, *maxsize* and 
    *allowtrailing*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  Raises an error if *data* is not valid, if it ends before the end of the stream (this 
  includes empty *data*; not for raw LZMA1 without *size*, see 
  [Raw LZMA1 and 7z](#raw-lzma1-and-7z)), if there is data after the end of the stream 
  (unless *allowtrailing* is set), if the output exceeds *maxsize* or if the decoder 
  needs more memory than *memlimit*. The output is produced in a growing buffer; nothing
  of the size *maxsize* is allocated in advance.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma_compressor">**`lzma.compressor([opts])
  `**</span>
  
  Creates a compressor stream object, see [Compressor Methods](#compressor-methods).
  
  * *opts* - optional table with the options of [lzma.compress()](#lzma_compress). A 
    carray for the output is given to the methods, not to *compressor()*.
  
  The native encoder state (about 94 MiB with preset 6, 674 MiB with preset 9, 
  *xz --info-memory* and the man page of xz list the values of all presets; *dictSize* 
  and *mf* change it) is released by [compressor:finish()](#compressor_finish), or by 
  the garbage collector if the object is no longer used. The garbage collector of Lua 
  does not see this memory; therefore streams should be finished.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma_decompressor">**`lzma.decompressor([opts])
  `**</span>
  
  Creates a decompressor stream object, see [Decompressor Methods](#decompressor-methods).
  
  * *opts* - optional table with the options of [lzma.decompress()](#lzma_decompress);
    *maxsize* limits the whole output of the stream. A carray for the output is given to
    the methods, not to *decompressor()*.
  
  The decoder needs memory for the dictionary of the stream (plus less than 100 KB), see 
  [*memlimit*](#option_memlimit).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma_properties">**`lzma.properties([opts])
  `**</span>
  
  Returns the encoded properties of the LZMA1 or LZMA2 filter for the options *opts* 
  (*lzma_properties_encode()*): for *filter = "lzma1"* the 5 bytes of 7z and the 
  *.lzma* header (lc/lp/pb byte, the dictionary size as 32 bit little endian), for 
  *filter = "lzma2"* (default) 1 byte (the dictionary size, rounded up to 2^n or 
  3 \* 2^(n-1)). These are the properties that a raw decoder needs, see 
  [Raw LZMA1 and 7z](#raw-lzma1-and-7z).
  
  * *opts* - optional table with the [options](#options) *filter*, *preset* (or 
    *level*), *extreme*, *dictSize*, *lc*, *lp*, *pb*, *mode*, *niceLen*, *mf* and 
    *depth* (only the first ones go into the properties).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma_version">**`lzma.version()
  `**</span>
  
  Returns the version of liblzma the module runs with (*lzma_version_string()*) and 
  the version of the *lzma.h* it was compiled with (*LZMA_VERSION_STRING*), as two 
  strings, e.g. *"5.8.3", "5.8.3"*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lzma__VERSION">**`lzma._VERSION
  `**</span>
  
  The version of the compress.lzma module as string, e.g. *"0.0.1"*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Constants
<!-- ---------------------------------------------------------------------------------------- -->

The module table contains the constants of *lzma.h* (integers with liblzma's values), 
with the names of liblzma, which Perl's *Compress::Raw::Lzma* uses as well:

  * **Status codes** (results of [decompressor:decompress()](#decompressor_decompress)):
    *LZMA_OK* (0), *LZMA_STREAM_END* (1), *LZMA_NO_CHECK* (2), 
    *LZMA_UNSUPPORTED_CHECK* (3), *LZMA_GET_CHECK* (4), *LZMA_MEM_ERROR* (5), 
    *LZMA_MEMLIMIT_ERROR* (6), *LZMA_FORMAT_ERROR* (7), *LZMA_OPTIONS_ERROR* (8), 
    *LZMA_DATA_ERROR* (9), *LZMA_BUF_ERROR* (10), *LZMA_PROG_ERROR* (11). 
    *LZMA_NO_CHECK*, *LZMA_UNSUPPORTED_CHECK* and *LZMA_GET_CHECK* are only returned by
    liblzma for decoder flags that compress.lzma does not set: they do not occur.
  * **Actions** (flush modes for [compressor:flush()](#compressor_flush)): *LZMA_RUN* (0),
    *LZMA_SYNC_FLUSH* (1), *LZMA_FULL_FLUSH* (2), *LZMA_FINISH* (3), 
    *LZMA_FULL_BARRIER* (4, liblzma 5.2 and later).
  * **Integrity checks** (for [check](#option_check)): *LZMA_CHECK_NONE* (0), 
    *LZMA_CHECK_CRC32* (1), *LZMA_CHECK_CRC64* (4), *LZMA_CHECK_SHA256* (10).
  * **Presets**: *LZMA_PRESET_DEFAULT* (6), *LZMA_PRESET_LEVEL_MASK* (0x1F), 
    *LZMA_PRESET_EXTREME* (0x80000000; compress.lzma takes it as option 
    [extreme](#option_extreme)).
  * **LZMA options** (for [mode](#option_mode) and [mf](#option_mf)): *LZMA_MODE_FAST* 
    (1), *LZMA_MODE_NORMAL* (2), *LZMA_MF_HC3* (0x03), *LZMA_MF_HC4* (0x04), 
    *LZMA_MF_BT2* (0x12), *LZMA_MF_BT3* (0x13), *LZMA_MF_BT4* (0x14), 
    *LZMA_DICT_SIZE_MIN* (4096), *LZMA_DICT_SIZE_DEFAULT* (8 MiB), *LZMA_LCLP_MIN* (0),
    *LZMA_LCLP_MAX* (4), *LZMA_LC_DEFAULT* (3), *LZMA_LP_DEFAULT* (0), *LZMA_PB_MIN* (0),
    *LZMA_PB_MAX* (4), *LZMA_PB_DEFAULT* (2).

<!-- ---------------------------------------------------------------------------------------- -->
##   Options
<!-- ---------------------------------------------------------------------------------------- -->

Options are given as table, e.g. *lzma.compress(data, { preset = 9, check = "crc32" })*.
Numbers must be integers (or floats with an integral value). The defaults are those of 
liblzma and the *xz* tool. An option of the module that the function does not take raises
*option 'maxsize' is not supported by compress()*, a name that is no option of the module
*unknown option 'name'*.

  * <span id="option_format">**format**</span> - string, default *"xz"*: *"xz"*, 
    *"lzma"*, *"raw"*, for decompression also *"auto"*, see [Formats](#formats). Valid 
    for all functions except *properties()*.

  * <span id="option_preset">**preset**</span>, <span id="option_level">**level**</span> - 
    integer 0..9, default 6 (*LZMA_PRESET_DEFAULT*): the presets of liblzma and *xz -0* 
    .. *xz -9*, which set all LZMA options (dictionary 256 KiB for 0 up to 64 MiB for 9).
    *level* is the common name of the compression strength in lua-compress (see 
    [Options](README.md#conv-options) in the Common Conventions), an alias of *preset*: 
    both may be given if they have the same value, else *level contradicts preset* is 
    raised. The options below change single values of the preset. Valid for *compress*,
    *compressor* and *properties*.

  * <span id="option_extreme">**extreme**</span> - boolean, default *false*: 
    *LZMA_PRESET_EXTREME*, the slower variant of the preset that compresses a little 
    better (*xz -6e*). Valid for *compress*, *compressor* and *properties*.

  * <span id="option_check">**check**</span> - string or integer constant, default 
    *"crc64"*: the integrity check of the xz format, *"none"*, *"crc32"*, *"crc64"*, 
    *"sha256"* (or *lzma.LZMA_CHECK_NONE*, ...). The default is that of the *xz* tool; 
    **Perl's *Compress::Raw::Lzma* and *IO::Compress::Xz* use CRC32**, see 
    [Compatibility](#compatibility-with-perls-compressrawlzma). Only for the format xz 
    (else *check is only supported for format 'xz'*). Valid for *compress* and 
    *compressor*.

  * <span id="option_filter">**filter**</span> - string, default *"lzma2"*: the filter of
    the format raw, *"lzma1"* or *"lzma2"*. Only for the format raw (else *filter is only
    supported for format 'raw'*). Valid for all functions.

  * <span id="option_properties">**properties**</span> - string or carray: the encoded 
    properties of the raw filter (*lzma_properties_decode()*), 5 bytes for LZMA1 
    (as 7z and the *.lzma* header store them), 1 byte for LZMA2, e.g. from 
    [lzma.properties()](#lzma_properties). Invalid properties raise *Error in 
    lzma_properties_decode: Unsupported options*. Instead of *properties* the explicit 
    options *dictSize*, *lc*, *lp* and *pb* may be given (not both: *properties cannot 
    be combined with dictSize*). Only for the format raw. Valid for *decompress* and 
    *decompressor*.

  * <span id="option_dictSize">**dictSize**</span> - integer, the dictionary size in 
    bytes (the window size: how far back the encoder refers, how much memory the decoder
    needs): encoder 4096 (*LZMA_DICT_SIZE_MIN*) up to 1.5 GiB, raw decoder up to 
    4 GiB - 1; default: that of the preset. The xz and lzma headers and the LZMA2 
    properties store it rounded up to 2^n or 3 \* 2^(n-1). For decoders only for the 
    format raw (the other formats have it in their headers: *dictSize is only supported
    for format 'raw'*). Valid for all functions.

  * <span id="option_lc">**lc**</span>, <span id="option_lp">**lp**</span>, 
    <span id="option_pb">**pb**</span> - integers 0..4: the number of literal context 
    bits, literal position bits and position bits of LZMA (*lc + lp* at most 4, else 
    *lc + lp must not exceed 4*); defaults 3, 0, 2. For decoders only for the format 
    raw. Valid for all functions.

  * <span id="option_mode">**mode**</span> - *"fast"* or *"normal"* (or 
    *lzma.LZMA_MODE_FAST*, *LZMA_MODE_NORMAL*), default: that of the preset (fast for 
    presets 0..3). <span id="option_niceLen">**niceLen**</span> - integer 2..273, the 
    match length at which the encoder stops searching (liblzma raises a value below the
    minimum of the match finder). <span id="option_mf">**mf**</span> - the match finder,
    *"hc3"*, *"hc4"*, *"bt2"*, *"bt3"*, *"bt4"* (or the *LZMA_MF_\** constants). 
    <span id="option_depth">**depth**</span> - integer >= 0, the maximum search depth 
    of the match finder, 0: automatic. Encoder options with the names of the fields of 
    *lzma_options_lzma* (*nice_len* is *niceLen*). Valid for *compress*, *compressor* 
    and *properties*.

  * <span id="option_size">**size**</span> - integer >= 0: the uncompressed size of a raw
    LZMA1 stream (liblzma 5.4 and later), see [Raw LZMA1 and 7z](#raw-lzma1-and-7z). 
    Only for the format raw with the filter lzma1 (else *size is only supported for 
    format 'raw' with filter 'lzma1'*). Valid for *decompress* and *decompressor*.

  * <span id="option_memlimit">**memlimit**</span> - integer >= 0, default unlimited: 
    the memory the decoder may use (0 is taken as 1, as by liblzma). If the stream needs
    more (its dictionary), the error *Error in lzma_code: Memory usage limit reached* is 
    raised (status *LZMA_MEMLIMIT_ERROR*). For the format raw, which liblzma's raw 
    decoder does not limit, compress.lzma compares the memory usage of the raw decoder 
    (*lzma_raw_decoder_memusage()*) with the limit when the decoder is created; if it is
    exceeded, the first call that decodes gives the error (*Error in lzma_raw_decoder: 
    Memory usage limit reached*, or the status). Perl's decoders use 128 MiB by default.
    Valid for *decompress* and *decompressor*.

  * <span id="option_maxsize">**maxsize**</span> - integer >= 0, default unlimited. Upper
    limit for the decompressed size; if the output would exceed it, the error 
    *output exceeds maxsize* is raised (by [decompress()](#decompressor_decompress): the 
    status *LZMA_BUF_ERROR*). This protects against compression bombs: LZMA compresses 
    50 MB of zeros to about 8 KB. No more than *maxsize* bytes of output are produced.
    The limit counts the output of the call (or of the stream), not the length of an 
    output carray. Valid for *decompress* and *decompressor*.

  * <span id="option_allowtrailing">**allowtrailing**</span> - boolean, default *false*.
    If *true*, data after the end of the stream is ignored instead of raising the 
    error *Error in lzma_code: unexpected data after end of stream*. Valid for 
    *decompress* and *decompressor*.

  * <span id="option_out">**out**</span> - no longer an option: the output carray is the
    last argument of the call, see [Data](#data). *out* in an options table raises 
    *option 'out' is no longer supported: pass the carray as the last argument*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A compressor object is created by [lzma.compressor()](#lzma_compressor). The output
of all calls concatenated is one stream of the format. Each method takes an optional 
carray *out* as last argument: the output is appended to it and the carray is returned 
instead of a string or *nil* (see [Data](#data)); the optional *chunk* comes first, *nil*
gives none: *c:finish(nil, out)*. A carray as only argument of *flush* or *finish* is the 
chunk.

```lua
local c = lzma.compressor({ preset = 9 })
for chunk in inputFile:lines(65536) do
    local out = c:update(chunk)
    if out then outputFile:write(out) end
end
outputFile:write(c:finish())
```

* <span id="compressor_update">**`compressor:update(chunk[, out])
  `**</span>

  Compresses *chunk* (string or carray) with *LZMA_RUN*. Returns the compressed output
  that is available, or *nil* if there is none yet: liblzma collects input before it 
  writes data. The first call with data returns the headers of the formats xz and lzma.
  An empty chunk gives *nil* (liblzma is not called).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_flush">**`compressor:flush([chunk][, mode][, out])
  `**</span>

  Compresses the optional *chunk* and flushes the compressor with *mode*; returns the 
  output (string, or *nil* if there is none), or the carray *out*. The stream can be 
  continued with *update*. The second argument is *mode* if it is a string or a number 
  and *out* if it is a carray: *c:flush(chunk, out)* flushes with the default mode. 
  *mode* is a string or one of the action constants:

  * *"sync"* or *lzma.LZMA_SYNC_FLUSH* (default): all output so far can be decompressed 
    up to the last byte given to the compressor. Formats xz and raw with LZMA2.
  * *"full"* or *lzma.LZMA_FULL_FLUSH*: as *"sync"*, and the xz block is finished: the 
    next data starts a new block that does not refer to the data before. Format xz.
  * *"barrier"* or *lzma.LZMA_FULL_BARRIER*: the same as *"full"* for the single-threaded
    encoder of compress.lzma. Format xz.
  * *lzma.LZMA_RUN*: no flush, the same as *update(chunk)*.
  * *"finish"* or *lzma.LZMA_FINISH*: the same as [finish(chunk)](#compressor_finish).

  LZMA1 (the format lzma and raw LZMA1) cannot be flushed: liblzma does not support it. A
  flush mode that the format does not support raises *flush mode 'sync' is not supported 
  for format 'lzma'* (*for filter 'lzma1'*, *for filter 'lzma2'*) before anything is 
  done; the stream stays usable. A second flush without new data in between gives *nil*.
  Frequent flushing makes the compression worse.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_finish">**`compressor:finish([chunk[, out]])
  `**</span>

  Compresses the optional *chunk*, ends the stream (*LZMA_FINISH*) and returns the rest of
  the output as string (never empty). Releases the native encoder state; any further 
  call raises the error *compressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Decompressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A decompressor object is created by [lzma.decompressor()](#lzma_decompressor). It
decompresses one stream given in arbitrary pieces; the output of all calls 
concatenated is the same as that of [lzma.decompress()](#lzma_decompress) for the 
whole stream. *update* and *finish* raise errors; [decompress](#decompressor_decompress) 
returns liblzma's status codes instead. The methods may be mixed on the same object. Each 
method takes an optional carray *out* as last argument, as the compressor methods do.

* <span id="decompressor_update">**`decompressor:update(chunk[, out])
  `**</span>

  Decompresses *chunk* (string or carray). Returns all output available so far, or *nil* 
  if there is none. Once the end of the stream has been reached, further chunks must be
  empty, unless the option *allowtrailing* is set: then they are ignored.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_finish">**`decompressor:finish([chunk[, out]])
  `**</span>

  Decompresses the optional *chunk* and checks that the stream is complete: raises the 
  error *Error in lzma_code: unexpected end of input* if it is not (not for raw LZMA1 
  without *size*: there the end of the input is the end, see 
  [Raw LZMA1 and 7z](#raw-lzma1-and-7z)). Returns the output of *chunk* (the empty string
  without *chunk*). Releases the native decoder state; any further call raises the error
  *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_decompress">**`decompressor:decompress(chunk[, out])
  `**</span>
  <span id="decompressor_code">**`decompressor:code(chunk[, out])
  `**</span>

  The status method: decompresses *chunk* (string or carray) like *update*, but raises 
  no error for the data. **Unlike the module function 
  [lzma.decompress()](#lzma_decompress)**, which raises an error for invalid, incomplete
  or trailing data, it returns three values: *output, status, consumed* (see 
  [The status method](README.md#the-status-method-decompressordecompress) in the Common
  Conventions). Errors are raised only for invalid arguments and a closed object. *code*
  is the same method under the name of Perl's *$status = $lz->code($in, $out)* of 
  *Compress::Raw::Lzma*, for code that evaluates liblzma's status like Perl code:

  * *output* - the decompressed data of this call, a string (*""* if there is none), or
    the carray *out* with the output appended; on an error the output up to the error.
  * *status* - one of the [status codes](#constants):
      * *LZMA_OK* - all of *chunk* was consumed, the stream is not complete yet (also for
        an empty or truncated stream: only *finish()* decides that the input ended; and
        always for raw LZMA1 without end marker and without *size*).
      * *LZMA_STREAM_END* - the end of the stream was reached. Data after it is not 
        consumed (*consumed* < *#chunk*) and does not raise an error, regardless of 
        *allowtrailing*. Every later call returns *"", LZMA_STREAM_END, 0*.
      * *LZMA_FORMAT_ERROR* (no xz or lzma header), *LZMA_OPTIONS_ERROR* (header or 
        filter options that liblzma does not support), *LZMA_DATA_ERROR* (invalid data, 
        also a wrong integrity check), *LZMA_MEMLIMIT_ERROR* (the stream needs more memory
        than *memlimit*), *LZMA_MEM_ERROR*. [msg()](#decompressor_msg) gives the message.
        The stream cannot go on: every later call returns the same status with no output.
      * *LZMA_BUF_ERROR* - the output would exceed *maxsize*; *output* contains the data 
        up to *maxsize*, *msg()* gives *"output exceeds maxsize"*. The stream cannot go 
        on.
  * *consumed* - the number of bytes of *chunk* that were used. Less than *#chunk* only
    for *LZMA_STREAM_END* (the rest is data after the stream) and for errors.

  The statuses, *consumed* and the output are the same as those of *Compress::Raw::Lzma*'s
  *code()* for the same input pieces (Perl's *ConsumeInput* removes *consumed* bytes 
  from its input buffer), checked by *tests/lzma/test04.lua* for all decoders, also for 
  7z's encoded headers with Perl's *RawDecoder(Filter => Lzma::Filter::Lzma1())*; after 
  an error the position where liblzma stopped may differ (it depends on the output 
  buffer sizes). Empty input gives *LZMA_OK* and does not call liblzma (whose 
  *lzma_code()* gives *LZMA_BUF_ERROR* for the second call in a row without progress).

  ```lua
  local d = lzma.decompressor({ format = "auto" })
  local out, status, consumed = d:code(data)
  if status == lzma.LZMA_STREAM_END then
      local trailing = data:sub(consumed + 1)    -- data after the xz or lzma stream
  elseif status ~= lzma.LZMA_OK then
      print("error: " .. d:msg())
  end
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_msg">**`decompressor:msg()
  `**</span>

  Returns the message of the last error of the decompressor, or *nil* if there was none.
  liblzma has no messages of its own; compress.lzma gives those of the *xz* tool for 
  liblzma's status codes (*"File format not recognized"*, *"Unsupported options"*, 
  *"Compressed data is corrupt"*, *"Memory usage limit reached"*, *"Cannot allocate 
  memory"*, ...) and its own *"output exceeds maxsize"*, *"unexpected end of input"* and
  *"unexpected data after end of stream"*. Also works after the object was closed.

After an error of *update* or *finish*, the native state of a stream object is released
and every further call raises *compressor is closed* or *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressed Output
<!-- ---------------------------------------------------------------------------------------- -->

liblzma's single-threaded encoders are deterministic: the same liblzma version with the 
same parameters gives the same bytes, regardless of how the data is fed in pieces. 
compress.lzma gives these guarantees, checked by *tests/lzma/test01.lua* and 
*tests/lzma/test04.lua*:

  * *lzma.compress(data, opts)* is the output of the encoder of the format 
    (*lzma_easy_encoder()* for xz with the preset alone, *lzma_stream_encoder()* with 
    one LZMA2 filter for xz with LZMA options, *lzma_alone_encoder()*, 
    *lzma_raw_encoder()*) and *lzma_code(LZMA_FINISH)* for the whole data.
  * A compressor gives the same output as *compress* for any chunk sizes (*update* and 
    *finish* without flushes).
  * The output is byte for byte the same as that of *xz -T1* with the same options 
    (*-0* .. *-9*, *-e*, *-C*, *--format=lzma*, *--format=raw*, *--lzma1=...*, 
    *--lzma2=...*) and of Perl's *Compress::Raw::Lzma* (*EasyEncoder*, *StreamEncoder*, 
    *AloneEncoder*, *RawEncoder*) and *IO::Compress::Xz* / *IO::Compress::Lzma*. The 
    multi-threaded encoder of *xz* (*-T0*, the default of xz 5.6) writes other blocks. 
  * Other LZMA implementations (7-Zip, the LZMA SDK) decode the output (checked for 
    7-Zip with *.xz* and *.lzma* files), but compress differently.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compatibility with Perl's Compress::Raw::Lzma
<!-- ---------------------------------------------------------------------------------------- -->

For code ported from Perl, the classes of *Compress::Raw::Lzma* and the functions of 
*IO::Compress::Xz* / *IO::Compress::Lzma* / *IO::Uncompress::UnXz* / 
*IO::Uncompress::UnLzma* correspond to these calls. **Perl's xz encoders use the check
CRC32** where liblzma's *xz* tool and compress.lzma use CRC64: give *check = "crc32"* to
get Perl's output byte for byte (with the same liblzma version: 
*Compress::Raw::Lzma::lzma_version_string()* and *lzma.version()*).

| Perl                                                           | compress.lzma                                                                 |
|----------------------------------------------------------------|-------------------------------------------------------------------------------|
| *EasyEncoder->new(Preset => p, Extreme => e)*, *code*, *flush* | *lzma.compressor({ preset = p, extreme = e, check = "crc32" })*, *update*, *finish* |
| *Check => LZMA_CHECK_CRC64* (*NONE*, *SHA256*)                 | *check = "crc64"* (*"none"*, *"sha256"*)                                      |
| *StreamEncoder->new(Filter => Lzma::Filter::Lzma2(DictSize => d, ...))* | *lzma.compressor({ dictSize = d, ..., check = "crc32" })*            |
| *AloneEncoder->new(Filter => Lzma::Filter::Lzma1(...))*        | *lzma.compressor({ format = "lzma", ... })*                                   |
| *RawEncoder->new(Filter => [Lzma::Filter::Lzma1(...)])*        | *lzma.compressor({ format = "raw", filter = "lzma1", ... })*                  |
| *Lzma::Filter::Lzma2::Preset(p)*                               | *preset = p*                                                                  |
| *DictSize*, *Lc*, *Lp*, *Pb*, *Mode*, *Nice*, *Mf*, *Depth*   | *dictSize*, *lc*, *lp*, *pb*, *mode*, *niceLen*, *mf*, *depth*                 |
| *$enc->flush($out, LZMA_SYNC_FLUSH)*                           | *c:flush(nil, lzma.LZMA_SYNC_FLUSH)*                                          |
| *StreamDecoder->new(MemLimit => m)*, *($st) = $d->code($in, $out)* | *d = lzma.decompressor({ memlimit = m })*, *out, st, n = d:code(in)* (= *d:decompress(in)*) |
| *AloneDecoder->new*, *AutoDecoder->new*                        | *lzma.decompressor({ format = "lzma" })*, *({ format = "auto" })*            |
| *RawDecoder->new(Filter => [Lzma::Filter::Lzma1()])*           | *lzma.decompressor({ format = "raw", filter = "lzma1" })*                     |
| *RawDecoder->new(Filter => [...], Properties => $props)*       | *lzma.decompressor({ format = "raw", filter = "lzma1", properties = props })* |
| *IO::Compress::Xz* (*Preset*, *Extreme*)                       | *lzma.compress(data, { preset = p, check = "crc32" })*                        |
| *IO::Compress::Lzma*                                           | *lzma.compress(data, { format = "lzma" })*                                    |
| *IO::Uncompress::UnXz*, *UnLzma*                               | *lzma.decompress(data, { format = "xz"* / *"lzma", allowtrailing = true })*   |
| *Compress::Raw::Lzma::lzma_version_string()*                   | *lzma.version()*                                                              |

Differences:

  * Perl's decoders limit the memory to 128 MiB by default (*MemLimit*), compress.lzma's
    decoders are unlimited unless [memlimit](#option_memlimit) is given; Perl's 
    *RawDecoder* has no limit.
  * Perl's *code()* modifies its input argument (with *ConsumeInput*, the default, it 
    removes the consumed bytes) and by default replaces its output argument; 
    compress.lzma returns the output and *consumed* instead. Perl's *AppendOutput => 1* 
    corresponds to a carray as *out*, to which the output is appended. *LimitOutput* and
    *Bufsize* have no counterpart (the output grows as needed; [maxsize](#option_maxsize)
    limits it).
  * Filter chains with more than one filter (BCJ filters such as *Lzma::Filter::X86*, 
    *Lzma::Filter::Delta*) and the preset dictionary (*PresetDict*) are not supported.
  * *IO::Uncompress::** ignore data after the end of the stream (as *allowtrailing*), 
    and by default (*Transparent => 1*) pass input through unchanged that is not 
    compressed at all; the latter is not done by compress.lzma, but 
    [decompress()](#decompressor_decompress) gives the status to decide it. Concatenated
    xz streams (*MultiStream*) are not decompressed in one call.

<!-- ---------------------------------------------------------------------------------------- -->
##   Errors
<!-- ---------------------------------------------------------------------------------------- -->

All errors are raised with *error()*, except the status method 
[decompressor:decompress()](#decompressor_decompress). The function name in argument errors 
depends on the Lua version.

  * **Invalid compressed data**: *Error in lzma_code: \<message\>* with the messages of 
    [msg()](#decompressor_msg), e.g. *Error in lzma_code: File format not recognized*,
    *Error in lzma_code: Compressed data is corrupt* (also a wrong integrity check), 
    *Error in lzma_code: Unsupported options*.
  * **Incomplete compressed data**: *Error in lzma_code: unexpected end of input*.
  * **Data after the end of the stream**: 
    *Error in lzma_code: unexpected data after end of stream*, unless the option 
    *allowtrailing* is set.
  * **Output limit**: *output exceeds maxsize*.
  * **Memory limit**: *Error in lzma_code: Memory usage limit reached*, *Error in 
    lzma_raw_decoder: Memory usage limit reached* (format raw).
  * **Properties**: *Error in lzma_properties_decode: Unsupported options* (wrong length,
    invalid lc/lp/pb byte, an LZMA2 dictionary size above 4 GiB).
  * **liblzma failures**: *Error in lzma_easy_encoder: \<message\>* (also 
    *lzma_stream_encoder*, *lzma_alone_encoder*, *lzma_raw_encoder*, 
    *lzma_stream_decoder*, *lzma_alone_decoder*, *lzma_auto_decoder*, 
    *lzma_raw_decoder*, *lzma_properties_encode*), e.g. *Cannot allocate memory*.
  * **Invalid options**: argument errors with the messages *invalid format value*, 
    *invalid preset value*, *invalid level value*, *level contradicts preset*, *invalid 
    extreme value*, *invalid check value*, *invalid filter value*, *invalid dictSize 
    value*, *invalid lc value* (also *lp*, *pb*), *lc + lp must not exceed 4*, 
    *invalid mode value*, *invalid niceLen value*, *invalid mf value*, *invalid depth 
    value*, *invalid size value*, *invalid memlimit value*, *invalid maxsize value*, 
    *invalid allowtrailing value*, *check is only supported for format 'xz'*, 
    *filter is only supported for format 'raw'*, *properties is only supported for 
    format 'raw'*, *dictSize is only supported for format 'raw'* (also *lc*, *lp*, *pb*;
    decoders), *properties cannot be combined with dictSize* (also *lc*, *lp*, *pb*), 
    *size is only supported for format 'raw' with filter 'lzma1'*, *size is not 
    supported by this liblzma version (5.4 or later is needed)*, *unknown option 'name'*,
    *option 'name' is not supported by compress()* (also *decompress*, *compressor*, 
    *decompressor*, *properties*), *option 'out' is no longer supported: pass the carray
    as the last argument*, *option names must be strings*, *table or carray expected, 
    got string* (second argument of *compress*/*decompress*), *table expected, got 
    string* (*compressor*, *decompressor*, *properties*), e.g. 
    *bad argument #2 to 'compress.lzma.compress' (invalid preset value)*; 
    *invalid flush mode* (argument 3 of *flush*).
  * **Flush modes**: *flush mode 'sync' is not supported for format 'lzma'* (also 
    *'full'*, *'barrier'*; *for filter 'lzma1'*, *for filter 'lzma2'*).
  * **Invalid data arguments**: *string or carray expected, got table*, 
    *carray elements must be 1 byte in size*, *properties: string or carray expected, 
    got table*, *properties: carray elements must be 1 byte in size*.
  * **Output carray**: *out: carray expected, got string*, *out: carray is not writable*,
    *out: carray elements must be 1 byte in size*, 
    *out: carray must not be the input data*, *cannot resize carray* (the carray is not 
    resizable, e.g. one referencing foreign memory, or out of memory), as argument errors
    of the position of *out*.
  * **Stream objects**: *compressor is closed*, *decompressor is closed* (after *finish* 
    or after an error of *update*/*finish*).
  * **Out of memory**: *Error in lzma_easy_encoder: Cannot allocate memory* and the 
    like, or Lua's memory error.

<!-- ---------------------------------------------------------------------------------------- -->
##   Thread safety / multiple Lua states
<!-- ---------------------------------------------------------------------------------------- -->

compress.lzma has no global mutable data: the cached Carray C API is kept per Lua state 
(in upvalues of the module functions), each stream object owns its own liblzma stream. 
liblzma itself is thread safe. compress.lzma can therefore be loaded into several 
independent Lua states of the same process, and these states can be used concurrently 
from different OS threads (each state by one thread at a time, as usual for Lua). Closing
one state does not affect the others. *tests/lzma/test03.lua* checks this with two Lua 
states running in parallel threads.

<!-- ---------------------------------------------------------------------------------------- -->
##   Building
<!-- ---------------------------------------------------------------------------------------- -->

With [LuaRocks](https://luarocks.org) from the repository root:

```
luarocks make rockspecs/compress.lzma-scm-0.rockspec
luarocks --lua-version 5.4 --local make rockspecs/compress.lzma-scm-0.rockspec
```

liblzma is the only external dependency of this rock (*LZMA*: header *lzma.h*, library 
*lzma*). If it is not installed in a standard location, give its prefix or its 
directories:

```
luarocks make rockspecs/compress.lzma-scm-0.rockspec LZMA_DIR=/opt/homebrew/opt/xz
luarocks make rockspecs/compress.lzma-scm-0.rockspec LZMA_INCDIR=... LZMA_LIBDIR=...
```

Packages: *liblzma-dev* (Debian/Ubuntu), *xz* (Arch/Manjaro, Homebrew), *xz-devel* 
(Fedora). liblzma 5.0 or later; the option [size](#option_size) needs 5.4, the flush 
mode *"barrier"* 5.2.

Windows:

  * **MSVC**: the rockspec links the import library *lzma.lib*, the name of XZ Utils' 
    CMake build since 5.6.3 (the DLL is *liblzma.dll*). Install it with vcpkg 
    (*vcpkg install liblzma:x64-windows*) and build in a Visual Studio developer prompt 
    with *LZMA_DIR=\<vcpkg\>/installed/x64-windows*; the DLL from *\<dir\>/bin* must be 
    on the *PATH*. Older builds (XZ Utils before 5.6.3) name the import library 
    *liblzma.lib*: then copy *\<dir\>/lib/liblzma.lib* to *\<dir\>/lib/lzma.lib* (as the 
    CI workflow does if needed). vcpkg's *lzma.h* is set up for the DLL; for a static 
    liblzma *LZMA_API_STATIC* must be defined.
  * **MinGW/MSYS2**: install *mingw-w64-ucrt-x86_64-xz* (or *mingw-w64-x86_64-xz*); the 
    rockspec links *liblzma.dll.a* (library *lzma*). If LuaRocks does not find it, give 
    *LZMA_DIR=/ucrt64* or *LZMA_INCDIR=/ucrt64/include LZMA_LIBDIR=/ucrt64/lib*.

Without LuaRocks, the Makefile in *src* builds *src/build/lua$(LUA_VERSION)/compress/lzma.so*
(settings can be overridden in *src/sandbox.mk*; *COPTS* and *LOPTS* are added to the 
flags of liblzma from *pkg-config*); *src/activate.sh* sets the Lua paths for using the 
module from the source tree:

```
cd src
make lzma LUA_VERSION=5.4 COPTS=-I/usr/include/lua5.4
. activate.sh
```

The tests are run from the *tests/lzma* directory:

  * *lua test01.lua* - string data: formats, presets and LZMA options, option errors, 
    properties, raw LZMA1 with and without end marker and with *size*, a 7z archive with
    an encoded header (decoded with the test helper *sevenzip.lua*, a minimal 7z reader),
    errors, trailing data, *maxsize*, *memlimit*, streaming with all chunk sizes (also 
    1 byte), flush modes, the status method *decompress()* (and its alias *code()*), 
    10 MB
  * *lua test02.lua* - carray data, carray output of all functions and methods 
    (appending, reuse after reset, returned object, maxsize, errors), carray chunks and
    properties (skipped if carray is not installed); the error cases for read-only and 
    non-resizable carrays need the test helper module *compress_testcarray* 
    (*luarocks make tests/compress_testcarray-scm-0.rockspec* from the repository root,
    or *make testcarray* in *src*), skipped if it is not installed
  * *lua test03.lua* - several Lua states in parallel threads; needs the test helper 
    module *compress_multistate* (*luarocks make tests/compress_multistate-scm-0.rockspec*
    from the repository root, or *make multistate* in *src*), skipped if it is not 
    installed
  * *lua test04.lua* - comparison with Perl (*Compress::Raw::Lzma*, *IO::Compress::Xz*, 
    *IO::Compress::Lzma*, *IO::Uncompress::UnXz*, *IO::Uncompress::UnLzma*, through the
    helper script *test04.pl*; *COMPRESS_TEST_PERL* names the Perl, *PERL5LIB* may give 
    a local::lib): byte for byte the same compressed output for the same parameters (if
    Perl uses the same liblzma version), Perl decompresses our output, the same statuses,
    consumed bytes and output of *code()* (also for a 7z header with *Lzma1()*); the 
    command line tool *xz* (byte for byte with *xz -T1*, both directions); 7-Zip (*7z*, 
    *7za* or *7zr*): archives with encoded headers and LZMA/LZMA2 data decoded with the 
    coder properties and the unpack sizes, and 7-Zip decodes our *.xz* and *.lzma* 
    files. With *COMPRESS_TEST_REQUIRE_IDENTICAL=1* a different liblzma version of Perl 
    or *xz* is an error. Each part is skipped if the tool is not installed, the command
    line tools on Windows.

<!-- ---------------------------------------------------------------------------------------- -->
