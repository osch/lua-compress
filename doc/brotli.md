# compress.brotli Documentation
<!-- ---------------------------------------------------------------------------------------- -->
##   Contents
<!-- ---------------------------------------------------------------------------------------- -->

   * [Overview](#overview)
   * [Data](#data)
   * [Module Functions](#module-functions)
        * [brotli.compress()](#brotli_compress)
        * [brotli.decompress()](#brotli_decompress)
        * [brotli.compressor()](#brotli_compressor)
        * [brotli.decompressor()](#brotli_decompressor)
        * [brotli.version()](#brotli_version)
        * [brotli._VERSION](#brotli__VERSION)
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
   * [Errors](#errors)
   * [Thread safety / multiple Lua states](#thread-safety--multiple-lua-states)
   * [Building](#building)

<!-- ---------------------------------------------------------------------------------------- -->
##   Overview
<!-- ---------------------------------------------------------------------------------------- -->

The [Lua] module *compress.brotli* of [lua-compress](../README.md) provides [Brotli]
compression ([RFC 7932]) based on the reference library *libbrotli* (*libbrotlienc*,
*libbrotlidec*):

  * [brotli.compress()](#brotli_compress) and [brotli.decompress()](#brotli_decompress)
    process the whole data in one call.
  * [brotli.compressor()](#brotli_compressor) and 
    [brotli.decompressor()](#brotli_decompressor) create stream objects that take the 
    data in pieces, for large data that should not be held in memory as a whole.
  * [decompressor:decompress()](#decompressor_decompress) is the variant of 
    *decompressor:update()* that raises no errors for the data but returns libbrotli's
    result codes and the number of bytes consumed.

Data may be Lua strings or [carray] objects, see [Data](#data). Errors are raised with
*error()*, see [Errors](#errors). The module follows the 
[Common Conventions](README.md#common-conventions) of lua-compress.

The module name to require is *"compress.brotli"*; it is also available as 
*require("compress").brotli* through the [meta module](README.md#the-meta-module-compress):

```lua
local brotli = require("compress.brotli")
```

This module works with Lua 5.1 up to 5.5 and LuaJIT. The [carray] module is optional: 
compress.brotli neither links against it nor requires it, carray objects are recognized
through the [Carray C API]. The rock *compress.brotli* depends on nothing but Lua and
libbrotli and can be installed without the other rocks of lua-compress.

[Lua]:          https://www.lua.org
[Brotli]:       https://github.com/google/brotli
[RFC 7932]:     https://www.rfc-editor.org/rfc/rfc7932
[carray]:       https://github.com/osch/lua-carray
[Carray C API]: https://github.com/lua-capis/lua-carray-capi

<!-- ---------------------------------------------------------------------------------------- -->
##   Data
<!-- ---------------------------------------------------------------------------------------- -->

The data to compress or decompress (argument *data*, and *chunk* of the stream methods) may 
be

  * a Lua string (a number is converted to a string, as in the string library), or
  * a carray object with elements of 1 byte size (element types *"char"*, *"uchar"*, 
    *"schar"*, *"int8"*, *"uint8"*). Other element types raise an error. A carray is read
    directly from its buffer, without copying; read-only carrays are accepted.

Data may contain arbitrary binary data including NUL bytes.

The result is a Lua string. Every function and method can instead append its output to
a carray given as its last argument *out* (see 
[Output](README.md#output-string-or-carray) in the Common Conventions):

  * the carray must have 1 byte elements and be writable and resizable, and must not be
    the same object as the input data of the call;
  * the output is appended after the carray's content, the carray is resized as needed 
    and returned instead of a string (also when nothing was appended); its capacity is 
    kept, so *buf:reset()* before a call reuses a carray without reallocation;
  * *brotli.compress(data, out)* is *brotli.compress(data, nil, out)*: the second 
    argument of the one-shot functions is the options table or *out*, told by its type;
  * the stream methods take *out* after *chunk*; without a chunk *nil* is given: 
    *c:finish(nil, out)*;
  * [maxsize](#option_maxsize) counts the output of the call (or stream), not the length 
    of the carray;
  * if a call raises an error, the carray is set back to its previous length; 
    [decompressor:decompress()](#decompressor_decompress), which raises no errors for 
    the data, appends the output up to the error.

```lua
local buf = carray.new("char")
brotli.compress(data, { quality = 9 }, buf)   -- buf contains the compressed data
buf:reset()                                   -- empty again, keeps the capacity
local c = brotli.compressor()
for chunk in inputFile:lines(65536) do
    c:update(chunk, buf)                      -- appended to buf
end
c:finish(nil, buf)
```

<!-- ---------------------------------------------------------------------------------------- -->
##   Module Functions
<!-- ---------------------------------------------------------------------------------------- -->

* <span id="brotli_compress">**`brotli.compress(data[, opts][, out])
  `**</span>
  
  Compresses *data* and returns the compressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray, see [Data](#data). May be empty.
  * *opts* - optional table with the [options](#options) *quality* (or *level*), *lgwin*
    and *mode*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  The result is the same byte sequence that *BrotliEncoderCompress()* of libbrotli gives
  for the same parameters, see [Compressed Output](#compressed-output).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="brotli_decompress">**`brotli.decompress(data[, opts][, out])
  `**</span>
  
  Decompresses *data* and returns the decompressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray containing exactly one complete Brotli stream. 
  * *opts* - optional table with the [options](#options) *maxsize* and *allowtrailing*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  Raises an error if *data* is not a valid Brotli stream, if it ends before the end of the
  stream (this includes empty *data*: the shortest Brotli stream is one byte), if there is
  data after the end of the stream (unless *allowtrailing* is set), or if the output 
  exceeds *maxsize*. The output is produced in a growing buffer; nothing of the size 
  *maxsize* is allocated in advance.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="brotli_compressor">**`brotli.compressor([opts])
  `**</span>
  
  Creates a compressor stream object, see [Compressor Methods](#compressor-methods).
  
  * *opts* - optional table with the [options](#options) *quality* (or *level*), 
    *lgwin*, *mode* and *sizehint*.
  
  A carray for the output is given to the methods, not to *compressor()*.
  
  The native encoder state is released by [compressor:finish()](#compressor_finish), or by 
  the garbage collector if the object is no longer used. Especially for high quality
  levels and large windows the encoder state needs a lot of memory, which the garbage
  collector of Lua does not see; therefore streams should be finished.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="brotli_decompressor">**`brotli.decompressor([opts])
  `**</span>
  
  Creates a decompressor stream object, see [Decompressor Methods](#decompressor-methods).
  
  * *opts* - optional table with the [options](#options) *maxsize*, which limits the
    whole output of the stream, and *allowtrailing*.
  
  A carray for the output is given to the methods, not to *decompressor()*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="brotli_version">**`brotli.version()
  `**</span>
  
  Returns the versions of the libbrotli decoder and encoder libraries the module runs with,
  as two strings, e.g. *"1.2.0", "1.2.0"*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="brotli__VERSION">**`brotli._VERSION
  `**</span>
  
  The version of the compress.brotli module as string, e.g. *"0.0.1"*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Constants
<!-- ---------------------------------------------------------------------------------------- -->

The module table contains the results of libbrotli's *BrotliDecoderDecompressStream()* 
(the enum *BrotliDecoderResult* of *brotli/decode.h*, integers with libbrotli's values), 
the status codes of [decompressor:decompress()](#decompressor_decompress):

  * *BROTLI_DECODER_RESULT_ERROR* (0) - invalid data.
  * *BROTLI_DECODER_RESULT_SUCCESS* (1) - the end of the Brotli stream was reached.
  * *BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT* (2) - all input consumed, the stream goes on.
  * *BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT* (3) - the output would exceed 
    [*maxsize*](#option_maxsize) (libbrotli gives this result when its output buffer is
    full; compress.brotli always gives the decoder more space, up to *maxsize*).

<!-- ---------------------------------------------------------------------------------------- -->
##   Options
<!-- ---------------------------------------------------------------------------------------- -->

Options are given as table, e.g. *brotli.compress(data, { quality = 5, lgwin = 18 })*.
Numbers must be integers (or floats with an integral value). An option of the module 
that the function does not take raises *option 'maxsize' is not supported by 
compress()*, a name that is no option of the module *unknown option 'name'*.

  * <span id="option_quality">**quality**</span> - integer 0..11, default 11 
    (*BROTLI_DEFAULT_QUALITY*). Compression level: 0 is fastest, 11 compresses best and 
    slowest. Valid for *compress* and *compressor*.

  * <span id="option_level">**level**</span> - the same as *quality*: *level* is the 
    common name of the compression strength in lua-compress (see 
    [Options](README.md#conv-options) in the Common Conventions). If both are given, 
    they must have the same value, else the error *level contradicts quality* is 
    raised; an invalid value raises *Invalid level value*. Valid for *compress* and 
    *compressor*.

  * <span id="option_lgwin">**lgwin**</span> - integer 10..24, default 22 
    (*BROTLI_DEFAULT_WINDOW*). Base 2 logarithm of the sliding window size: the encoder 
    references data at most *2^lgwin - 16* bytes back. The decoder needs a buffer of this
    size. Valid for *compress* and *compressor*.

  * <span id="option_mode">**mode**</span> - string, default *"generic"*. Tunes the encoder
    for the kind of data. Valid for *compress* and *compressor*.
      * *"generic"* - no assumptions about the data.
      * *"text"* - UTF-8 text.
      * *"font"* - WOFF 2.0 font data.

  * <span id="option_sizehint">**sizehint**</span> - integer >= 0, default 0 (unknown).
    The expected total size of the input of a *compressor*, which the encoder uses to choose
    its internal parameters. *compress* always sets it to the size of *data*. With the 
    same *sizehint* a compressor gives the same output as *compress* for quality 2 and 
    above, independently of the chunk sizes. Valid for *compressor*.

  * <span id="option_maxsize">**maxsize**</span> - integer >= 0, default unlimited. Upper
    limit for the decompressed size; if the output would exceed it, the error 
    *output exceeds maxsize* is raised (by [decompress()](#decompressor_decompress): the
    status *BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT*). This protects against compression
    bombs: Brotli can compress 50 MB of zeros to less than 100 bytes. Decompression stops
    as soon as the limit is reached, no more than *maxsize* bytes of output are produced.
    The limit counts the output of the call (or of the stream), not the length of an 
    output carray. Valid for *decompress* and *decompressor*.

  * <span id="option_allowtrailing">**allowtrailing**</span> - boolean, default *false*.
    If *true*, data after the end of the Brotli stream is ignored instead of raising the 
    error *unexpected data after end of stream*.
    Valid for *decompress* and *decompressor*.

  * <span id="option_out">**out**</span> - not an option: 
    the output carray is the last argument of the call, see [Data](#data). *out* in an
    options table raises *option 'out' is no longer supported: pass the carray as the 
    last argument*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A compressor object is created by [brotli.compressor()](#brotli_compressor). The output
of all calls concatenated is one Brotli stream. Each method takes an optional carray 
*out* as last argument: the output is appended to it and the carray is returned instead
of a string or *nil* (see [Data](#data)); the optional *chunk* comes first, *nil* gives 
none: *c:finish(nil, out)*. A carray as only argument of *flush* or *finish* is the 
chunk.

```lua
local c = brotli.compressor({ quality = 9 })
for chunk in inputFile:lines(65536) do
    local out = c:update(chunk)
    if out then outputFile:write(out) end
end
outputFile:write(c:finish())
```

* <span id="compressor_update">**`compressor:update(chunk[, out])
  `**</span>

  Compresses *chunk* (string or carray). Returns the compressed output that is available,
  or *nil* if there is none yet: the encoder collects input until it has enough for a
  block.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_flush">**`compressor:flush([chunk[, out]])
  `**</span>

  Compresses the optional *chunk* and flushes the encoder: the returned output (string, or
  *nil* if there is nothing to flush) together with all previous output can be decompressed
  up to the last byte given to the compressor. Frequent flushing makes the compression
  worse. The stream can be continued with *update*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_finish">**`compressor:finish([chunk[, out]])
  `**</span>

  Compresses the optional *chunk*, ends the stream and returns the rest of the output as 
  string (never empty). Releases the native encoder state; any further call raises the 
  error *compressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Decompressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A decompressor object is created by [brotli.decompressor()](#brotli_decompressor). It
decompresses one Brotli stream given in arbitrary pieces; the output of all calls 
concatenated is the same as that of [brotli.decompress()](#brotli_decompress) for the 
whole stream. *update* and *finish* raise errors; 
[decompress](#decompressor_decompress) returns libbrotli's result codes instead. The 
methods may be mixed on the same object. Each method takes an optional carray *out* as 
last argument, as the compressor methods do.

* <span id="decompressor_update">**`decompressor:update(chunk[, out])
  `**</span>

  Decompresses *chunk* (string or carray). Returns all output available so far, or *nil* 
  if there is none. Once the end of the Brotli stream has been reached, further chunks 
  must be empty, unless the option *allowtrailing* is set: then they are ignored.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_finish">**`decompressor:finish([chunk[, out]])
  `**</span>

  Decompresses the optional *chunk* and checks that the stream is complete: raises the 
  error *Error in BrotliDecoderDecompressStream: unexpected end of input* if it is not. 
  Returns the output of *chunk* (the empty string without *chunk*). Releases the native 
  decoder state; any further call raises the error *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_decompress">**`decompressor:decompress(chunk[, out])
  `**</span>

  The status method: decompresses *chunk* (string or carray) like *update*, but raises 
  no error for the data. **Unlike the module function 
  [brotli.decompress()](#brotli_decompress)**, which raises an error for invalid, 
  incomplete or trailing data, it returns three values: *output, status, consumed* (see 
  [The status method](README.md#the-status-method-decompressordecompress) in the Common
  Conventions). Errors are raised only for invalid arguments, a closed object and 
  memory errors.

  * *output* - the decompressed data of this call, a string (*""* if there is none), or
    the carray *out* with the output appended; on an error the output up to the error.
  * *status* - one of the [constants](#constants):
      * *BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT* - all of *chunk* was consumed, the 
        stream is not complete yet (also for an empty or truncated stream: only 
        *finish()* decides that the input ended).
      * *BROTLI_DECODER_RESULT_SUCCESS* - the end of the Brotli stream was reached. Data
        after it is not consumed (*consumed* < *#chunk*) and does not raise an error, 
        regardless of *allowtrailing*. Every later call returns *"", 
        BROTLI_DECODER_RESULT_SUCCESS, 0*.
      * *BROTLI_DECODER_RESULT_ERROR* - invalid data; [msg()](#decompressor_msg) gives
        libbrotli's error code name, e.g. *"ERROR_FORMAT_PADDING_1"*. The stream cannot
        go on: every later call returns the same status with no output.
      * *BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT* - the output would exceed *maxsize*; 
        *output* contains the data up to *maxsize*, *msg()* gives *"output exceeds 
        maxsize"*. The stream cannot go on.
  * *consumed* - the number of bytes of *chunk* that were used. Less than *#chunk* only
    for *BROTLI_DECODER_RESULT_SUCCESS* (the rest is data after the stream: libbrotli 
    stops reading exactly at its end) and for errors.

  After an error status, *update* and *finish* raise the error (and close the object), 
  e.g. *Error in BrotliDecoderDecompressStream: ERROR_FORMAT_PADDING_1*; after 
  *BROTLI_DECODER_RESULT_SUCCESS*, *finish()* succeeds.

  ```lua
  local d = brotli.decompressor()
  local out, status, consumed = d:decompress(data)
  if status == brotli.BROTLI_DECODER_RESULT_SUCCESS then
      local trailing = data:sub(consumed + 1)    -- data after the Brotli stream
  elseif status ~= brotli.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT then
      print("error: " .. d:msg())
  end
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_msg">**`decompressor:msg()
  `**</span>

  Returns the message of the last error of the decompressor, or *nil* if there was none:
  libbrotli's error code name (*BrotliDecoderErrorString()* without the leading 
  underscore, e.g. *"ERROR_FORMAT_PADDING_1"*, *"ERROR_FORMAT_EXUBERANT_NIBBLE"*), 
  *"output exceeds maxsize"*, *"unexpected end of input"* or *"unexpected data after end
  of stream"* (the last two only from *update*/*finish*). Also works after the object 
  was closed.

After an error of a raising method, the native state of a stream object is released and
every further call raises *compressor is closed* or *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressed Output
<!-- ---------------------------------------------------------------------------------------- -->

Different Brotli encoders, and the same encoder with different parameters, may produce 
different but equally valid streams for the same data. compress.brotli gives these guarantees,
checked by *tests/brotli/test04.lua*:

  * *brotli.compress(data, { quality = q, lgwin = w, mode = m })* is identical to the 
    output of *BrotliEncoderCompress(q, w, m, ...)* of the same libbrotli version. It
    includes its special cases: empty input gives the single byte *"\6"*, and data that 
    does not compress (output larger than *BrotliEncoderMaxCompressedSize()*) is stored as 
    uncompressed meta-blocks.
  * A compressor gives the same output as the streaming encoder of libbrotli used the same 
    way, e.g. with *sizehint* set to the file size as the *brotli* command line tool
    (checked for files up to 300 KB).
  * From quality 2 on, a compressor with *sizehint = #data* gives the same output as 
    *compress*, for any chunk sizes. For quality 0 and 1 the output depends on the chunk
    sizes.

<!-- ---------------------------------------------------------------------------------------- -->
##   Errors
<!-- ---------------------------------------------------------------------------------------- -->

All errors are raised with *error()*, except the status method 
[decompressor:decompress()](#decompressor_decompress). The function name in argument 
errors depends on the Lua version.

  * **Invalid compressed data**: *Error in BrotliDecoderDecompressStream: \<code\>* with the
    libbrotli error code name, e.g. 
    *Error in BrotliDecoderDecompressStream: ERROR_FORMAT_PADDING_1*.
  * **Incomplete compressed data**: 
    *Error in BrotliDecoderDecompressStream: unexpected end of input*.
  * **Data after the end of the stream**: 
    *Error in BrotliDecoderDecompressStream: unexpected data after end of stream*, unless
    the option *allowtrailing* is set.
  * **Output limit**: *output exceeds maxsize*.
  * **Encoder failure**: *Error in BrotliEncoderCompressStream* (not expected to happen).
  * **Invalid options**: argument errors with the messages *Invalid quality value*,
    *Invalid level value*, *level contradicts quality*, *Invalid window value*, 
    *Invalid encoder mode*, *invalid maxsize value*, *invalid sizehint value*, 
    *invalid allowtrailing value*, *unknown option 'name'*, *option 'name' is not 
    supported by compress()* (also *decompress*, *compressor*, *decompressor*), 
    *option 'out' is no longer supported: pass the carray as the last argument*, 
    *option names must be strings*, *table or carray expected, got string* (second 
    argument of *compress*/*decompress*), *table expected, got string* (*compressor*, 
    *decompressor*), e.g. 
    *bad argument #2 to 'compress.brotli.compress' (Invalid quality value)*.
  * **Invalid data arguments**: *string or carray expected, got table*, 
    *carray elements must be 1 byte in size*.
  * **Output carray**: *out: carray expected, got string*, *out: carray is not writable*,
    *out: carray elements must be 1 byte in size*, 
    *out: carray must not be the input data*, *cannot resize carray* (the carray is not 
    resizable, e.g. one referencing foreign memory, or out of memory), as argument errors
    of the position of *out*.
  * **Stream objects**: *compressor is closed*, *decompressor is closed* (after *finish* 
    or after an error of a raising method).
  * **Out of memory**: *cannot create Brotli decoder*, *cannot create Brotli encoder*, or 
    Lua's memory error.

<!-- ---------------------------------------------------------------------------------------- -->
##   Thread safety / multiple Lua states
<!-- ---------------------------------------------------------------------------------------- -->

compress.brotli has no global mutable data: the cached Carray C API is kept per Lua state (in
upvalues of the module functions), each stream object owns its own libbrotli state. 
libbrotli itself works without global state. compress.brotli can therefore be loaded into several
independent Lua states of the same process, and these states can be used concurrently
from different OS threads (each state by one thread at a time, as usual for Lua). Closing
one state does not affect the others. *tests/brotli/test03.lua* checks this with two Lua states
running in parallel threads.

<!-- ---------------------------------------------------------------------------------------- -->
##   Building
<!-- ---------------------------------------------------------------------------------------- -->

With [LuaRocks](https://luarocks.org) from the repository root:

```
luarocks make rockspecs/compress.brotli-scm-0.rockspec
luarocks --lua-version 5.4 --local make rockspecs/compress.brotli-scm-0.rockspec
```

Brotli is the only external dependency of this rock (headers *brotli/decode.h* and
*brotli/encode.h*, libraries *brotlidec* and *brotlienc*). If it is not installed in a standard location, give its 
prefix or its directories. The rockspec checks the decoder and the encoder
separately (*BROTLIDEC* and *BROTLIENC*), so both variables are given, usually
with the same value:

```
luarocks make rockspecs/compress.brotli-scm-0.rockspec BROTLIDEC_DIR=/opt/homebrew/opt/brotli BROTLIENC_DIR=/opt/homebrew/opt/brotli
luarocks make rockspecs/compress.brotli-scm-0.rockspec BROTLIDEC_INCDIR=... BROTLIDEC_LIBDIR=... BROTLIENC_INCDIR=... BROTLIENC_LIBDIR=...
```

Packages: *libbrotli-dev* (Debian/Ubuntu), *brotli* (Arch/Manjaro, Homebrew), 
*brotli-devel* (Fedora).

Windows:

  * **MSVC**: install Brotli with vcpkg (*vcpkg install brotli:x64-windows*) and build in a
    Visual Studio developer prompt with 
    *BROTLIDEC_DIR=\<vcpkg\>/installed/x64-windows BROTLIENC_DIR=\<vcpkg\>/installed/x64-windows*. The headers are in
    *\<dir\>/include/brotli*, the import libraries *brotlidec.lib* and *brotlienc.lib* in
    *\<dir\>/lib*; *brotlidec.dll*, *brotlienc.dll* and *brotlicommon.dll* from 
    *\<dir\>/bin* must be on the *PATH*. When linking the static libraries 
    (*x64-windows-static*), *brotlicommon* must be added to the libraries in the rockspec.
  * **MinGW/MSYS2**: install *mingw-w64-x86_64-brotli* (*pacman -S 
    mingw-w64-x86_64-brotli*); headers and libraries are in */mingw64/include* and
    */mingw64/lib* (*libbrotlidec.dll.a*, *libbrotlienc.dll.a*), the DLLs in 
    */mingw64/bin*. If LuaRocks does not find them, give 
    *BROTLIDEC_INCDIR=/mingw64/include BROTLIDEC_LIBDIR=/mingw64/lib BROTLIENC_INCDIR=/mingw64/include BROTLIENC_LIBDIR=/mingw64/lib*.

Without LuaRocks, the Makefile in *src* builds *src/build/lua$(LUA_VERSION)/compress/brotli.so*
(settings can be overridden in *src/sandbox.mk*, e.g. *PLATFORM := WIN* for MinGW; *COPTS*
and *LOPTS* are added to the flags of Brotli from *pkg-config*, they do not replace them);
*src/activate.sh* sets the Lua paths for using the module from the source tree:

```
cd src
make brotli LUA_VERSION=5.4 COPTS=-I/usr/include/lua5.4
. activate.sh
```

The tests are run from the *tests/brotli* directory:

  * *lua test01.lua* - string data: options (also *level*), errors, streaming, the 
    status method *decompressor:decompress()* (statuses, consumed bytes, trailing data,
    errors, 1 byte pieces), 10 MB
  * *lua test02.lua* - carray data and carray output of all functions and methods 
    (appending, reuse after reset, returned object, maxsize, errors; skipped if carray 
    is not installed); the error cases for read-only and non-resizable carrays need the test 
    helper module *compress_testcarray* (*luarocks make 
    tests/compress_testcarray-scm-0.rockspec* from the repository root, or 
    *make testcarray* in *src*), skipped if it is not installed
  * *lua test03.lua* - several Lua states in parallel threads; needs the test helper 
    module *compress_multistate* (*luarocks make tests/compress_multistate-scm-0.rockspec*
    from the repository root, or *make multistate* in *src*), skipped if it is not 
    installed
  * *lua test04.lua* - byte for byte comparison with the *brotli* command line tool,
    each part skipped if not installed
  * *lua bench01.lua [reps]* - benchmark: compress and decompress 1 MB, string results
    vs. carray targets

<!-- ---------------------------------------------------------------------------------------- -->
