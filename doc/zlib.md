# compress.zlib Documentation
<!-- ---------------------------------------------------------------------------------------- -->
##   Contents
<!-- ---------------------------------------------------------------------------------------- -->

   * [Overview](#overview)
   * [Data](#data)
   * [Formats](#formats)
   * [Module Functions](#module-functions)
        * [zlib.compress()](#zlib_compress)
        * [zlib.decompress()](#zlib_decompress)
        * [zlib.compressor()](#zlib_compressor)
        * [zlib.decompressor()](#zlib_decompressor)
        * [zlib.crc32()](#zlib_crc32)
        * [zlib.adler32()](#zlib_adler32)
        * [zlib.version()](#zlib_version)
        * [zlib._VERSION](#zlib__VERSION)
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
   * [Compatibility with Perl's Compress::Zlib](#compatibility-with-perls-compresszlib)
   * [Errors](#errors)
   * [Thread safety / multiple Lua states](#thread-safety--multiple-lua-states)
   * [Building](#building)

<!-- ---------------------------------------------------------------------------------------- -->
##   Overview
<!-- ---------------------------------------------------------------------------------------- -->

The [Lua] module *compress.zlib* of [lua-compress](../README.md) provides deflate 
compression ([RFC 1951]) in the formats zlib ([RFC 1950]), gzip ([RFC 1952]) and raw 
deflate, based on the system's [zlib] library:

  * [zlib.compress()](#zlib_compress) and [zlib.decompress()](#zlib_decompress)
    process the whole data in one call.
  * [zlib.compressor()](#zlib_compressor) and 
    [zlib.decompressor()](#zlib_decompressor) create stream objects that take the 
    data in pieces, with the flush modes of zlib.
  * [decompressor:decompress()](#decompressor_decompress) (also as *inflate()*) is the 
    variant of *decompressor:update()* that raises no errors for the data but returns 
    zlib's status codes and the number of bytes consumed, for code that evaluates them 
    like Perl's *Compress::Zlib*.
  * All parameters of *deflateInit2()* (level, method, windowBits, memLevel, strategy),
    dictionaries and the gzip header fields of *deflateSetHeader()* can be given; with the same parameters and zlib version the output
    is byte for byte the same as that of other zlib users, e.g. Perl's 
    *Compress::Zlib*, see [Compatibility with Perl's 
    Compress::Zlib](#compatibility-with-perls-compresszlib).
  * [zlib.crc32()](#zlib_crc32) and [zlib.adler32()](#zlib_adler32) compute the 
    checksums of zlib.

Data may be Lua strings or [carray] objects, see [Data](#data). Errors are raised with
*error()*, see [Errors](#errors). The module follows the 
[Common Conventions](README.md#common-conventions) of lua-compress.

The module name to require is *"compress.zlib"*; it is also available as 
*require("compress").zlib* through the [meta module](README.md#the-meta-module-compress):

```lua
local zlib = require("compress.zlib")
```

This module works with Lua 5.1 up to 5.5 and LuaJIT. The [carray] module is optional: 
compress.zlib neither links against it nor requires it, carray objects are recognized
through the [Carray C API]. The rock *compress.zlib* depends on nothing but Lua and zlib
and can be installed without the other rocks of lua-compress.

The metatable names (*getmetatable()*) are *"compress.zlib"*, 
*"compress.zlib.compressor"* and *"compress.zlib.decompressor"*; the latter two also 
appear in *tostring()* of the stream objects.

[Lua]:          https://www.lua.org
[zlib]:         https://zlib.net
[RFC 1950]:     https://www.rfc-editor.org/rfc/rfc1950
[RFC 1951]:     https://www.rfc-editor.org/rfc/rfc1951
[RFC 1952]:     https://www.rfc-editor.org/rfc/rfc1952
[carray]:       https://github.com/osch/lua-carray
[Carray C API]: https://github.com/lua-capis/lua-carray-capi

<!-- ---------------------------------------------------------------------------------------- -->
##   Data
<!-- ---------------------------------------------------------------------------------------- -->

The data to compress or decompress (argument *data*, and *chunk* of the stream methods),
the [dictionary](#option_dictionary) and the data of the checksum functions may be

  * a Lua string (a number is converted to a string, as in the string library), or
  * a carray object with elements of 1 byte size (element types *"char"*, *"uchar"*, 
    *"schar"*, *"int8"*, *"uint8"*). Other element types raise an error. A carray is read
    directly from its buffer, without copying; read-only carrays are accepted.

Data may contain arbitrary binary data including NUL bytes, and may be larger than 4 GB
(zlib's interface takes at most 4 GB per call; the module feeds larger data in pieces).

The result is a Lua string. Every function and method (except the checksums) can 
instead append its output to a carray given as its last argument *out* (see 
[Output](README.md#output-string-or-carray) in the Common Conventions):

  * the carray must have 1 byte elements and be writable and resizable, and must not be
    the same object as the input data of the call;
  * the output is appended after the carray's content, the carray is resized as needed 
    and returned instead of a string (also when nothing was appended); its capacity is 
    kept, so *buf:reset()* before a call reuses a carray without reallocation;
  * *zlib.compress(data, out)* is *zlib.compress(data, nil, out)*: the second argument 
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
zlib.compress(data, { format = "gzip" }, buf)   -- buf contains the compressed data
buf:reset()                                     -- empty again, keeps the capacity
local c = zlib.compressor()
for chunk in inputFile:lines(65536) do
    c:update(chunk, buf)                        -- appended to buf
end
c:flush(nil, "full", buf)
c:finish(nil, buf)
```

<!-- ---------------------------------------------------------------------------------------- -->
##   Formats
<!-- ---------------------------------------------------------------------------------------- -->

The option [*format*](#option_format) selects the format; the compressed data inside is
the same deflate stream for all of them:

  * *"zlib"* (default): [RFC 1950], a 2 byte header (with the window size and, if a 
    dictionary is used, its Adler-32), the deflate stream and the Adler-32 of the data.
  * *"gzip"*: [RFC 1952]. By default compress.zlib writes zlib's minimal gzip header: no
    file name, modification time 0, the operating system code of zlib's build (*OS_CODE*,
    a compile-time constant of zlib: 3 = Unix, 19 = macOS, 10 = native Windows, so this
    byte differs between platforms), XFL 2 for level 9 and 4 for levels 0 and 1 (and the
    strategies *Z_HUFFMAN_ONLY*, *Z_RLE*, *Z_FIXED*). The option 
    [*gzipHeader*](#option_gzipHeader) sets the header fields (operating system, 
    modification time, file name, comment, extra field, text flag, header CRC). 
    Decompression reads all header fields (and checks the header CRC if there is one) 
    and checks the CRC-32 and the length of the data.
  * *"raw"*: the deflate stream alone ([RFC 1951]), without header and checksum.
  * *"auto"* (decompression only): zlib or gzip, detected from the header (zlib's 
    *windowBits + 32*). Raw deflate is not detected.

Only one stream is decompressed: data after its end raises an error (unless 
[*allowtrailing*](#option_allowtrailing) is set); concatenated gzip members, which the
*gzip* tool decompresses one after the other, are such data. 
[decompressor:decompress()](#decompressor_decompress) gives the position of the end, so that 
a caller can go on with the next member in a new decompressor.

As in zlib and Perl, the format can also be selected with 
[*windowBits*](#option_windowBits): negative values select raw deflate, 16 + n gzip and 
32 + n (decompression only) automatic detection.

<!-- ---------------------------------------------------------------------------------------- -->
##   Module Functions
<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_compress">**`zlib.compress(data[, opts][, out])
  `**</span>
  
  Compresses *data* and returns the compressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray, see [Data](#data). May be empty.
  * *opts* - optional table with the [options](#options) *format*, *level*, *method*,
    *windowBits*, *memLevel*, *strategy*, *dictionary* and *gzipHeader*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  The result is the output of one *deflate(Z_FINISH)* call for the whole data with 
  enough output space (the same as zlib's *compress2()* for the format zlib and the 
  default memLevel), see [Compressed Output](#compressed-output).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_decompress">**`zlib.decompress(data[, opts][, out])
  `**</span>
  
  Decompresses *data* and returns the decompressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray containing exactly one complete stream of the format.
  * *opts* - optional table with the [options](#options) *format*, *windowBits*, 
    *dictionary*, *maxsize* and *allowtrailing*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  Raises an error if *data* is not valid, if it ends before the end of the stream (this 
  includes empty *data*), if there is data after the end of the stream (unless 
  *allowtrailing* is set), or if the output exceeds *maxsize*. The output is produced in
  a growing buffer; nothing of the size *maxsize* is allocated in advance.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_compressor">**`zlib.compressor([opts])
  `**</span>
  
  Creates a compressor stream object, see [Compressor Methods](#compressor-methods).
  
  * *opts* - optional table with the [options](#options) *format*, *level*, *method*,
    *windowBits*, *memLevel*, *strategy*, *dictionary* and *gzipHeader*. A carray for 
    the output is given to the methods, not to *compressor()*.
  
  The native deflate state (about 256 KB with the defaults, *memLevel* and *windowBits* 
  change it) is released by [compressor:finish()](#compressor_finish), or by the garbage
  collector if the object is no longer used. The garbage collector of Lua does not see 
  this memory; therefore streams should be finished.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_decompressor">**`zlib.decompressor([opts])
  `**</span>
  
  Creates a decompressor stream object, see [Decompressor Methods](#decompressor-methods).
  
  * *opts* - optional table with the [options](#options) *format*, *windowBits*, 
    *dictionary*, *maxsize*, which limits the whole output of the stream, and 
    *allowtrailing*. A carray for the output is given to the methods, not to 
    *decompressor()*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_crc32">**`zlib.crc32(data[, crc])
  `**</span>
  
  Returns the CRC-32 of *data* (string or carray) as integer 0..0xFFFFFFFF, the 
  checksum of gzip. With *crc*, the CRC-32 of the data so far, the computation goes on:
  *zlib.crc32(b, zlib.crc32(a)) == zlib.crc32(a .. b)*. The CRC-32 of empty data is 0. 
  Like *Compress::Zlib::crc32*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_adler32">**`zlib.adler32(data[, adler])
  `**</span>
  
  Returns the Adler-32 of *data* (string or carray) as integer 0..0xFFFFFFFF, the 
  checksum of the zlib format. With *adler*, the Adler-32 of the data so far, the 
  computation goes on. The Adler-32 of empty data is 1. Like *Compress::Zlib::adler32*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib_version">**`zlib.version()
  `**</span>
  
  Returns the version of the zlib library the module runs with (*zlibVersion()*) and 
  the version of the *zlib.h* it was compiled with (*ZLIB_VERSION*), as two strings, 
  e.g. *"1.3.2", "1.3.2"*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="zlib__VERSION">**`zlib._VERSION
  `**</span>
  
  The version of the compress.zlib module as string, e.g. *"0.0.1"*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Constants
<!-- ---------------------------------------------------------------------------------------- -->

The module table contains the constants of *zlib.h* (integers with zlib's values), with 
the names Perl's *Compress::Zlib* uses for them:

  * **Status codes** (results of [decompressor:decompress()](#decompressor_decompress)):
    *Z_OK* (0), *Z_STREAM_END* (1), *Z_NEED_DICT* (2), *Z_ERRNO* (-1), 
    *Z_STREAM_ERROR* (-2), *Z_DATA_ERROR* (-3), *Z_MEM_ERROR* (-4), *Z_BUF_ERROR* (-5),
    *Z_VERSION_ERROR* (-6).
  * **Flush modes** (for [compressor:flush()](#compressor_flush)): *Z_NO_FLUSH* (0), 
    *Z_PARTIAL_FLUSH* (1), *Z_SYNC_FLUSH* (2), *Z_FULL_FLUSH* (3), *Z_FINISH* (4), 
    *Z_BLOCK* (5).
  * **Levels**: *Z_NO_COMPRESSION* (0), *Z_BEST_SPEED* (1), *Z_BEST_COMPRESSION* (9),
    *Z_DEFAULT_COMPRESSION* (-1).
  * **Strategies**: *Z_DEFAULT_STRATEGY* (0), *Z_FILTERED* (1), *Z_HUFFMAN_ONLY* (2), 
    *Z_RLE* (3), *Z_FIXED* (4).
  * **Method, window, memory**: *Z_DEFLATED* (8), *MAX_WBITS* (15), *MAX_MEM_LEVEL* (9),
    *DEF_MEM_LEVEL* (8, zlib's default memLevel; not exported by *zlib.h* itself).

<!-- ---------------------------------------------------------------------------------------- -->
##   Options
<!-- ---------------------------------------------------------------------------------------- -->

Options are given as table, e.g. *zlib.compress(data, { format = "gzip", level = 9 })*.
Numbers must be integers (or floats with an integral value). The defaults are those of 
zlib. An option of the module that the function does not take raises *option 'maxsize'
is not supported by compress()*, a name that is no option of the module *unknown option
'name'*.

  * <span id="option_format">**format**</span> - string, default *"zlib"*: *"zlib"*,
    *"gzip"*, *"raw"*, for decompression also *"auto"*, see [Formats](#formats). Valid 
    for all functions except the checksums.

  * <span id="option_level">**level**</span> - integer -1..9, default -1 
    (*Z_DEFAULT_COMPRESSION*, which is level 6). 0 stores the data uncompressed (in 
    stored blocks), 1 is fastest, 9 compresses best. *level* is also the common name of
    the compression strength in lua-compress (see [Options](README.md#conv-options) in 
    the Common Conventions). Valid for *compress* and *compressor*.

  * <span id="option_method">**method**</span> - integer, default 8 (*Z_DEFLATED*), the
    only method of zlib. Valid for *compress* and *compressor*.

  * <span id="option_windowBits">**windowBits**</span> - integer, default 15 
    (*MAX_WBITS*): the base 2 logarithm of the window size (the distance back that the 
    compressor refers to and the decompressor needs).
      * Compression: 9..15 (zlib changes 8 to 9 for the format zlib and rejects it for
        raw and gzip). 
      * Decompression: 8..15, at least the value used for compression; 0 takes the 
        window size from the zlib header (formats zlib, gzip and auto).
      * As in zlib and Perl, *-8..-15* select raw deflate, *16 + n* gzip and *32 + n* 
        (decompression only) automatic detection. If both *format* and such a 
        *windowBits* are given, they must agree, else the error *windowBits contradicts
        format* is raised.
    
    Valid for all functions except the checksums.

  * <span id="option_memLevel">**memLevel**</span> - integer 1..9, default 8 (zlib's 
    *DEF_MEM_LEVEL*). How much memory the compressor uses for its internal state: more
    memory is faster and compresses a little better. It also determines how many symbols
    a deflate block holds (2^(memLevel + 6)), so for data of more than about 16 KB the 
    output depends on it. **Perl's *Compress::Zlib*, *Compress::Raw::Zlib* and 
    *IO::Compress::** use *MAX_MEM_LEVEL* (9), not zlib's default**, see 
    [Compatibility with Perl's Compress::Zlib](#compatibility-with-perls-compresszlib).
    Valid for *compress* and *compressor*.

  * <span id="option_strategy">**strategy**</span> - integer, default 
    *Z_DEFAULT_STRATEGY*: *zlib.Z_DEFAULT_STRATEGY*, *Z_FILTERED* (data with many small
    random values), *Z_HUFFMAN_ONLY* (no string matching), *Z_RLE* (matches of 
    distance 1 only), *Z_FIXED* (no dynamic Huffman codes). Valid for *compress* and 
    *compressor*.

  * <span id="option_dictionary">**dictionary**</span> - string or carray: a preset
    dictionary, data that is likely to occur in the data to compress (only its last 
    32 KB are used). The same dictionary must be given for decompression. 
      * Format zlib: the header contains the Adler-32 of the dictionary; the 
        decompressor uses the given dictionary when the data asks for it 
        (*Z_NEED_DICT*), a wrong one raises 
        *Error in inflateSetDictionary: incorrect dictionary*, none 
        *Error in inflate: need dictionary*. A dictionary that the data does not need
        is ignored.
      * Format raw: the dictionary is set at the start (as *Compress::Raw::Zlib* does);
        there is no check, a wrong dictionary gives wrong data or an error.
      * Format gzip has no dictionaries: *dictionary is not supported for format 'gzip'*.
    
    The decompressor keeps a copy of the dictionary. Valid for all functions except the
    checksums.

  * <span id="option_gzipHeader">**gzipHeader**</span> - table: the fields of the gzip 
    header ([RFC 1952]), given to zlib's *deflateSetHeader()*. Only for the format gzip
    (*format = "gzip"* or *windowBits* 16 + n), else the error *gzipHeader is only
    supported for format 'gzip'* is raised. Valid for *compress* and *compressor*. 
    Fields (all optional):

    | Field     | Type                  | Header                         | Default               |
    |-----------|-----------------------|--------------------------------|-----------------------|
    | *os*      | integer 0..255        | OS byte                        | zlib's *OS_CODE*      |
    | *mtime*   | integer 0..0xFFFFFFFF | MTIME (Unix time, 0 = none)    | 0                     |
    | *name*    | string or carray      | FNAME: file name               | none (flag not set)   |
    | *comment* | string or carray      | FCOMMENT: comment              | none (flag not set)   |
    | *extra*   | string or carray      | FEXTRA: extra field, 0..65535 bytes | none (flag not set) |
    | *text*    | boolean               | FTEXT: the data is probably text | *false*             |
    | *hcrc*    | boolean               | FHCRC: header CRC              | *false*               |

      * The defaults are those of zlib's default header, so *gzipHeader = {}* gives the
        same bytes as no *gzipHeader*. *os* defaults to the operating system code zlib 
        writes without a header, the compile-time constant *OS_CODE* of zlib's build 
        (3 = Unix, 19 = macOS, 10 = native Windows, also 3 for Cygwin/MSYS builds): give
        *os* explicitly (e.g. 3, or 255 = unknown) for output that is the same on all 
        platforms.
      * *name* and *comment* are written NUL-terminated and must not contain NUL bytes
        (RFC 1952: ISO 8859-1 text; the bytes are not checked otherwise). *extra* is 
        written as given, preceded by its length (2 bytes, little endian); RFC 1952 
        defines it as a sequence of subfields (2 byte ID, 2 byte length, data), which 
        is not checked. An empty string sets the flag with an empty field. Strings and
        carrays with 1 byte elements are accepted, as for [data](#data) (a number is
        converted to a string).
      * *mtime* is written as 4 bytes little endian; it is not set from the clock.
      * *hcrc*: the header ends with the two low bytes of the CRC-32 of the header bytes 
        before them; zlib's inflate checks it (*Error in inflate: header crc mismatch*).
      * XFL is set by zlib from *level* and *strategy* as for the default header (see 
        [Formats](#formats)); it is no field of *gzipHeader*.

    The fields are copied when the stream is created (zlib writes the header with the 
    first output); the compressor keeps the copy until it is finished. Unknown fields 
    raise *gzipHeader: unknown field 'name'*. Example:

    ```lua
    local gz = zlib.compress(data, { format = "gzip", gzipHeader = { 
        os = 3, mtime = os.time(), name = "data.txt", comment = "created by Lua", hcrc = true } })
    ```

  * <span id="option_maxsize">**maxsize**</span> - integer >= 0, default unlimited. Upper
    limit for the decompressed size; if the output would exceed it, the error 
    *output exceeds maxsize* is raised (by [decompress()](#decompressor_decompress): the 
    status *Z_BUF_ERROR*). This protects against compression bombs: deflate compresses 
    50 MB of zeros to about 50 KB. No more than *maxsize* bytes of output are produced.
    The limit counts the output of the call (or of the stream), not the length of an 
    output carray. Valid for *decompress* and *decompressor*.

  * <span id="option_allowtrailing">**allowtrailing**</span> - boolean, default *false*.
    If *true*, data after the end of the stream is ignored instead of raising the 
    error *Error in inflate: unexpected data after end of stream*. Valid for 
    *decompress* and *decompressor*.

  * <span id="option_out">**out**</span> - no longer an option: the output carray is the
    last argument of the call, see [Data](#data). *out* in an options table raises 
    *option 'out' is no longer supported: pass the carray as the last argument*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A compressor object is created by [zlib.compressor()](#zlib_compressor). The output
of all calls concatenated is one stream of the format. Each method takes an optional 
carray *out* as last argument: the output is appended to it and the carray is returned 
instead of a string or *nil* (see [Data](#data)); the optional *chunk* comes first, *nil*
gives none: *c:finish(nil, out)*. A carray as only argument of *flush* or *finish* is the 
chunk.

```lua
local c = zlib.compressor({ format = "gzip", level = 9 })
for chunk in inputFile:lines(65536) do
    local out = c:update(chunk)
    if out then outputFile:write(out) end
end
outputFile:write(c:finish())
```

* <span id="compressor_update">**`compressor:update(chunk[, out])
  `**</span>

  Compresses *chunk* (string or carray) with *Z_NO_FLUSH*. Returns the compressed output
  that is available, or *nil* if there is none yet: zlib collects input until it has a
  block. The first call returns the header of the formats zlib and gzip at once, also 
  for an empty chunk.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_flush">**`compressor:flush([chunk][, mode][, out])
  `**</span>

  Compresses the optional *chunk* and flushes the compressor with *mode*; returns the 
  output (string, or *nil* if there is none), or the carray *out*. The stream can be 
  continued with *update*. The second argument is *mode* if it is a string or a number 
  and *out* if it is a carray: *c:flush(chunk, out)* flushes with the default mode, 
  *c:flush(chunk, "full", out)* and *c:flush(nil, nil, out)* are valid as well. *mode* 
  is a string or one of the flush constants:

  * *"sync"* or *zlib.Z_SYNC_FLUSH* (default): all output so far can be decompressed up
    to the last byte given to the compressor; the output ends with an empty stored 
    block (the bytes *00 00 FF FF*).
  * *"full"* or *zlib.Z_FULL_FLUSH*: as *"sync"*, and the compressor forgets the data
    so far, so that decompression can start again at this point (for raw deflate:
    a new decompressor can decompress the data after the flush point alone). Compresses
    worse when used often.
  * *"block"* or *zlib.Z_BLOCK*: completes the current deflate block (for applications 
    that control the block structure; the last bits may still be held back).
  * *"partial"* or *zlib.Z_PARTIAL_FLUSH*: like *"sync"* with an empty fixed code block 
    instead of a stored block (older applications).
  * *zlib.Z_NO_FLUSH*: no flush, the same as *update(chunk)*.
  * *"finish"* or *zlib.Z_FINISH*: the same as [finish(chunk)](#compressor_finish).

  A second flush without new data in between gives *nil*. Frequent flushing makes the 
  compression worse.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_finish">**`compressor:finish([chunk[, out]])
  `**</span>

  Compresses the optional *chunk*, ends the stream (*Z_FINISH*) and returns the rest of
  the output as string (never empty). Releases the native deflate state; any further 
  call raises the error *compressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Decompressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A decompressor object is created by [zlib.decompressor()](#zlib_decompressor). It
decompresses one stream given in arbitrary pieces; the output of all calls 
concatenated is the same as that of [zlib.decompress()](#zlib_decompress) for the 
whole stream. *update* and *finish* raise errors; [decompress](#decompressor_decompress) 
returns zlib's status codes instead. The methods may be mixed on the same object. Each 
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
  error *Error in inflate: unexpected end of input* if it is not. Returns the output of
  *chunk* (the empty string without *chunk*). Releases the native inflate state; any 
  further call raises the error *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_decompress">**`decompressor:decompress(chunk[, out])
  `**</span>
  <span id="decompressor_inflate">**`decompressor:inflate(chunk[, out])
  `**</span>

  The status method: decompresses *chunk* (string or carray) like *update*, but raises 
  no error for the data. **Unlike the module function 
  [zlib.decompress()](#zlib_decompress)**, which raises an error for invalid, incomplete
  or trailing data, it returns three values: *output, status, consumed* (see 
  [The status method](README.md#the-status-method-decompressordecompress) in the Common
  Conventions). Errors are raised only for invalid arguments, a closed object and 
  memory errors. *inflate* is the same method under the name of Perl's 
  *($out, $status) = $i->inflate($in)* of *Compress::Zlib* / *Compress::Raw::Zlib*, for 
  code that evaluates zlib's status like Perl code:

  * *output* - the decompressed data of this call, a string (*""* if there is none), or
    the carray *out* with the output appended; on an error the output up to the error.
  * *status* - one of the [status codes](#constants):
      * *Z_OK* - all of *chunk* was consumed, the stream is not complete yet (also for an
        empty or truncated stream: only *finish()* decides that the input ended).
      * *Z_STREAM_END* - the end of the stream was reached. Data after it is not 
        consumed (*consumed* < *#chunk*) and does not raise an error, regardless of 
        *allowtrailing*. Every later call returns *"", Z_STREAM_END, 0* (as zlib's 
        *inflate()* does).
      * *Z_DATA_ERROR* - invalid data (also a wrong checksum, or a wrong dictionary),
        *Z_NEED_DICT* - the data needs a dictionary and none was given, *Z_MEM_ERROR*.
        [msg()](#decompressor_msg) gives zlib's message. The stream cannot go on: 
        every later call returns the same status with no output.
      * *Z_BUF_ERROR* - the output would exceed *maxsize*; *output* contains the data 
        up to *maxsize*, *msg()* gives *"output exceeds maxsize"*. The stream cannot go 
        on.
  * *consumed* - the number of bytes of *chunk* that were used. Less than *#chunk* only
    for *Z_STREAM_END* (the rest is data after the stream) and for errors.

  Like Perl's *inflate()* with *Z_BUF_ERROR* mapped to *Z_OK* when all input is used:
  the statuses are the same as those of *Compress::Raw::Zlib*'s *inflate()* for the 
  same input pieces, and *consumed* is what Perl's *-ConsumeInput* removes from its 
  input buffer (checked by *tests/zlib/test04.lua*; for *Z_NEED_DICT* Perl leaves its 
  input buffer as it was, *consumed* counts the header bytes that zlib has read).

  ```lua
  local d = zlib.decompressor({ format = "raw" })
  local out, status, consumed = d:decompress(data)
  if status == zlib.Z_STREAM_END then
      local trailing = data:sub(consumed + 1)    -- data after the deflate stream
  elseif status ~= zlib.Z_OK then
      print("error: " .. d:msg())
  end
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_msg">**`decompressor:msg()
  `**</span>

  Returns the message of the last error of the decompressor (zlib's *msg*, e.g. 
  *"incorrect header check"*, *"invalid distance too far back"*, *"need dictionary"*, 
  *"incorrect dictionary"*, *"output exceeds maxsize"*), or *nil* if there was none. 
  Also works after the object was closed.

After an error of *update* or *finish*, the native state of a stream object is released
and every further call raises *compressor is closed* or *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressed Output
<!-- ---------------------------------------------------------------------------------------- -->

zlib's output is deterministic: the same zlib version with the same parameters gives the
same bytes. compress.zlib gives these guarantees, checked by *tests/zlib/test01.lua* and
*tests/zlib/test04.lua*:

  * *zlib.compress(data, opts)* is the output of *deflateInit2()* with the parameters of 
    *opts*, *deflateSetDictionary()* with the dictionary if given, and one 
    *deflate(Z_FINISH)* call for the whole data.
  * For levels 1..9, a compressor gives the same output as *compress* for any chunk 
    sizes (*update* and *finish* without flushes), and the same output as other zlib 
    users that feed the same data with the same flushes, regardless of their buffer 
    sizes. Checked against Perl's *Compress::Raw::Zlib*, *Compress::Zlib*, 
    *IO::Compress::Deflate/RawDeflate/Gzip* and Python's *zlib* module.
  * Level 0 (stored blocks): the block sizes depend on how *deflate()* is called and on
    the output space given to it. *compress* gives the output of zlib's *compress2()*
    (blocks of 65535 bytes); streams and other programs (Perl, Python) may split the 
    data differently. The decompressed data is always the same.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compatibility with Perl's Compress::Zlib
<!-- ---------------------------------------------------------------------------------------- -->

For code ported from Perl, the functions of *Compress::Zlib* / *Compress::Raw::Zlib* / 
*IO::Compress::** correspond to these calls. **Perl uses memLevel 9 (*MAX_MEM_LEVEL*) 
where zlib's default is 8**; give *memLevel = zlib.MAX_MEM_LEVEL* to get Perl's output 
byte for byte (with the same zlib version: *Compress::Raw::Zlib::zlib_version()* and 
*zlib.version()*; Perl distributions often bundle their own zlib).

| Perl                                                        | compress.zlib                                                              |
|-------------------------------------------------------------|----------------------------------------------------------------------------|
| *Compress::Zlib::compress($data, $level)*                   | *zlib.compress(data, { level = level, memLevel = 9 })*                     |
| *Compress::Zlib::uncompress($data)*                         | *zlib.decompress(data)*                                                    |
| *deflateInit(-Level => l, ...)*, *deflate*, *flush*         | *zlib.compressor({ level = l, memLevel = 9, ... })*, *update*, *finish*    |
| *$d->flush($out, Z_SYNC_FLUSH)*                             | *c:flush(nil, zlib.Z_SYNC_FLUSH)*                                          |
| *inflateInit(-WindowBits => w)*, *($out, $st) = inflate($in)* | *d = zlib.decompressor({ windowBits = w })*, *out, st, n = d:inflate(in)* (= *d:decompress(in)*) |
| *-Dictionary => $dict*                                      | *dictionary = dict*                                                        |
| *IO::Compress::Gzip* (*Time => 0*)                          | *zlib.compress(data, { format = "gzip", memLevel = 9, gzipHeader = { os = 3 } })* |
| *IO::Compress::Gzip*'s *-OS_Code*, *-Time*, *-Name*, *-Comment* | *gzipHeader = { os = ..., mtime = ..., name = ..., comment = ... }*   |
| *-ExtraField*, *-TextFlag*, *-HeaderCRC*                    | *gzipHeader = { extra = ..., text = true, hcrc = true }*                   |
| *IO::Compress::Deflate*, *IO::Compress::RawDeflate*         | *format = "zlib"* / *"raw"*, *memLevel = 9*                                |
| *IO::Uncompress::Gunzip*, *Inflate*, *RawInflate*           | *zlib.decompress(data, { format = "gzip"* / *"zlib"* / *"raw", allowtrailing = true })* |
| *Compress::Zlib::crc32*, *adler32*                          | *zlib.crc32*, *zlib.adler32*                                               |

Differences:

  * *IO::Compress::Gzip* writes its own gzip header: with *Time => 0* (else the current
    time) and the same *OS_Code* (Perl's default: its own table, 3 for Unix also on 
    macOS; zlib's: *OS_CODE*, see [gzipHeader](#option_gzipHeader)) it is the same as 
    zlib's, except XFL for level 0 and for the strategies *Z_HUFFMAN_ONLY*, *Z_RLE*,
    *Z_FIXED* (Perl: 0, zlib: 4); *Minimal => 1* sets the operating system code to 255.
    *-Name*, *-Comment*, *-ExtraField* (as string), *-TextFlag* and *-Time* give the 
    same bytes as the fields of *gzipHeader*. *-HeaderCRC* differs: *IO::Compress::Gzip*
    writes only the low byte of the CRC-32 (*crc32 & 0xFF*, the high byte 0) instead of
    its two low bytes, which zlib's inflate (and compress.zlib) rejects with *header crc
    mismatch*; compress.zlib writes the CRC of RFC 1952, which *IO::Uncompress::Gunzip*
    accepts unless *Strict => 1*. *Compress::Raw::Zlib* and *Compress::Zlib* have no
    *deflateSetHeader()*: their gzip streams (*WindowBits => 16 + n*) always have zlib's
    default header.
  * *IO::Uncompress::** ignore data after the end of the stream (as *allowtrailing*), 
    and by default (*Transparent => 1*) pass input through unchanged that is not 
    compressed at all; the latter is not done by compress.zlib, but 
    [decompress()](#decompressor_decompress) gives the status to decide it. Concatenated 
    gzip members (*MultiStream*) are not decompressed in one call.
  * Perl's *inflate()* modifies its input argument (removes the consumed bytes); 
    compress.zlib returns *consumed* instead. Perl's *-AppendOutput => 1* corresponds to
    a carray as *out*, to which the output is appended.
  * Level 0: see [Compressed Output](#compressed-output).

<!-- ---------------------------------------------------------------------------------------- -->
##   Errors
<!-- ---------------------------------------------------------------------------------------- -->

All errors are raised with *error()*, except the status method 
[decompressor:decompress()](#decompressor_decompress). The function name in argument errors 
depends on the Lua version.

  * **Invalid compressed data**: *Error in inflate: \<zlib's message\>*, e.g. 
    *Error in inflate: incorrect header check*, *Error in inflate: invalid block type*,
    *Error in inflate: header crc mismatch* (gzip),
    *Error in inflate: incorrect data check* (checksum), 
    *Error in inflate: incorrect length check* (gzip), 
    *Error in inflate: invalid window size* (windowBits too small).
  * **Dictionaries**: *Error in inflate: need dictionary*, 
    *Error in inflateSetDictionary: incorrect dictionary*.
  * **Incomplete compressed data**: *Error in inflate: unexpected end of input*.
  * **Data after the end of the stream**: 
    *Error in inflate: unexpected data after end of stream*, unless the option 
    *allowtrailing* is set.
  * **Output limit**: *output exceeds maxsize*.
  * **zlib failures**: *Error in deflate: \<message\>*, *Error in inflateInit2: 
    \<message\>*, *Error in deflateInit2: \<message\>* (e.g. *insufficient memory*, 
    *incompatible version*; not expected to happen).
  * **Invalid options**: argument errors with the messages *invalid format value*, 
    *invalid level value*, *invalid method value*, *invalid windowBits value*, 
    *windowBits contradicts format*, *invalid memLevel value*, *invalid strategy value*,
    *dictionary is not supported for format 'gzip'*, *invalid maxsize value*, 
    *invalid allowtrailing value*, *unknown option 'name'*, *option 'name' is not 
    supported by compress()* (also *decompress*, *compressor*, *decompressor*), 
    *option 'out' is no longer supported: pass the carray as the last argument*, 
    *option names must be strings*, *table or carray expected, got string* (second 
    argument of *compress*/*decompress*), *table expected, got string* (*compressor*, 
    *decompressor*), e.g. 
    *bad argument #2 to 'compress.zlib.compress' (invalid level value)*; 
    *invalid flush mode* (argument 3 of *flush*), *invalid checksum value*.
  * **Invalid gzipHeader** (argument errors as well): *gzipHeader is only supported for
    format 'gzip'*, *gzipHeader: table expected, got string*, *gzipHeader: unknown field
    'name'*, *gzipHeader: field names must be strings*, *gzipHeader: invalid os value*,
    *gzipHeader: invalid mtime value*, *gzipHeader: invalid text value*, 
    *gzipHeader: invalid hcrc value*, *gzipHeader: name must not contain NUL bytes* (also
    *comment*), *gzipHeader: extra too long (more than 65535 bytes)*, 
    *gzipHeader: name: string or carray expected, got table*, *gzipHeader: name: carray 
    elements must be 1 byte in size* (also *comment*, *extra*).
  * **Invalid data arguments**: *string or carray expected, got table*, 
    *carray elements must be 1 byte in size*, *dictionary: string or carray expected, 
    got table*, *dictionary: carray elements must be 1 byte in size*.
  * **Output carray**: *out: carray expected, got string*, *out: carray is not writable*,
    *out: carray elements must be 1 byte in size*, 
    *out: carray must not be the input data*, *cannot resize carray* (the carray is not 
    resizable, e.g. one referencing foreign memory, or out of memory), as argument errors
    of the position of *out*.
  * **Stream objects**: *compressor is closed*, *decompressor is closed* (after *finish* 
    or after an error of *update*/*finish*).
  * **Out of memory**: *Error in deflateInit2: insufficient memory* and the like, or 
    Lua's memory error.

<!-- ---------------------------------------------------------------------------------------- -->
##   Thread safety / multiple Lua states
<!-- ---------------------------------------------------------------------------------------- -->

compress.zlib has no global mutable data: the cached Carray C API is kept per Lua state 
(in upvalues of the module functions), each stream object owns its own zlib stream. zlib
itself is thread safe. compress.zlib can therefore be loaded into several independent
Lua states of the same process, and these states can be used concurrently from 
different OS threads (each state by one thread at a time, as usual for Lua). Closing one
state does not affect the others. *tests/zlib/test03.lua* checks this with two Lua 
states running in parallel threads.

<!-- ---------------------------------------------------------------------------------------- -->
##   Building
<!-- ---------------------------------------------------------------------------------------- -->

With [LuaRocks](https://luarocks.org) from the repository root:

```
luarocks make rockspecs/compress.zlib-scm-0.rockspec
luarocks --lua-version 5.4 --local make rockspecs/compress.zlib-scm-0.rockspec
```

zlib is the only external dependency of this rock (*ZLIB*: header *zlib.h*, library *z*).
If it is not installed in a standard location, give its prefix or its directories:

```
luarocks make rockspecs/compress.zlib-scm-0.rockspec ZLIB_DIR=/opt/homebrew/opt/zlib
luarocks make rockspecs/compress.zlib-scm-0.rockspec ZLIB_INCDIR=... ZLIB_LIBDIR=...
```

Packages: *zlib1g-dev* (Debian/Ubuntu), *zlib* (Arch/Manjaro, Homebrew; macOS has zlib
in its SDK), *zlib-devel* (Fedora).

Windows:

  * **MSVC**: the rockspec links the import library *zlib.lib* (the usual name of zlib's
    import library with MSVC, also expected by other rocks such as lua-zlib). Install 
    zlib with vcpkg (*vcpkg install zlib:x64-windows*) and build in a Visual Studio 
    developer prompt with *ZLIB_DIR=\<vcpkg\>/installed/x64-windows*; the DLL from 
    *\<dir\>/bin* must be on the *PATH*. zlib's own CMake build, which vcpkg uses, may 
    name the import library *z.lib* instead: then copy *\<dir\>/lib/z.lib* to 
    *\<dir\>/lib/zlib.lib* (as the CI workflow does).
  * **MinGW/MSYS2**: install *mingw-w64-x86_64-zlib*; the rockspec links *libz.dll.a* 
    (library *z*) from */mingw64/lib*. If LuaRocks does not find it, give 
    *ZLIB_INCDIR=/mingw64/include ZLIB_LIBDIR=/mingw64/lib*.

Without LuaRocks, the Makefile in *src* builds *src/build/lua$(LUA_VERSION)/compress/zlib.so*
(settings can be overridden in *src/sandbox.mk*; *COPTS* and *LOPTS* are added to the 
flags of zlib from *pkg-config*); *src/activate.sh* sets the Lua paths for using the 
module from the source tree:

```
cd src
make zlib LUA_VERSION=5.4 COPTS=-I/usr/include/lua5.4
. activate.sh
```

The tests are run from the *tests/zlib* directory:

  * *lua test01.lua* - string data: formats, parameters, options, errors, streaming 
    with all chunk sizes (also 1 byte), flush modes, dictionaries, the status method 
    *decompress()* (and its alias *inflate()*), checksums, 10 MB
  * *lua test02.lua* - carray data, carray output of all functions and methods 
    (appending, reuse after reset, returned object, maxsize, errors), carray 
    dictionaries and chunks 
    (skipped if carray is not installed); the error cases for read-only and 
    non-resizable carrays need the test helper module *compress_testcarray* 
    (*luarocks make tests/compress_testcarray-scm-0.rockspec* from the repository root,
    or *make testcarray* in *src*), skipped if it is not installed
  * *lua test03.lua* - several Lua states in parallel threads; needs the test helper 
    module *compress_multistate* (*luarocks make tests/compress_multistate-scm-0.rockspec*
    from the repository root, or *make multistate* in *src*), skipped if it is not 
    installed
  * *lua test04.lua* - comparison with Perl (*Compress::Zlib*, *Compress::Raw::Zlib*, 
    *IO::Compress::\**, *IO::Uncompress::\**, through the helper script *test04.pl*):
    byte for byte the same compressed output for the same parameters (if Perl uses the
    same zlib version), Perl decompresses our output, the same statuses and consumed 
    bytes of *inflate()*, the gzip header fields of *IO::Compress::Gzip* (*OS_Code*, 
    *Time*, *Name*, *Comment*, *ExtraField*, *TextFlag*, *HeaderCRC*) against 
    *gzipHeader*, and *IO::Uncompress::Gunzip* reads the fields of our headers; Python's
    *zlib* module (byte for byte as well); the command line tools *gzip* (decompressed 
    data only) and *zlib-flate* (qpdf). Each part is skipped if the tool is not 
    installed, the command line tools on Windows.
  * *lua test05.lua* - the option *gzipHeader*: every field and all combinations, the
    header bytes (flags, mtime, OS byte, NUL-terminated name and comment, extra length,
    header CRC), XFL, streaming (also a header written over many *deflate()* calls), round 
    trips, carrays as field values (skipped without carray), errors

<!-- ---------------------------------------------------------------------------------------- -->
