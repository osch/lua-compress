# compress.bzip2 Documentation
<!-- ---------------------------------------------------------------------------------------- -->
##   Contents
<!-- ---------------------------------------------------------------------------------------- -->

   * [Overview](#overview)
   * [Data](#data)
   * [Format](#format)
   * [Concatenated Streams](#concatenated-streams)
   * [Module Functions](#module-functions)
        * [bzip2.compress()](#bzip2_compress)
        * [bzip2.decompress()](#bzip2_decompress)
        * [bzip2.compressor()](#bzip2_compressor)
        * [bzip2.decompressor()](#bzip2_decompressor)
        * [bzip2.version()](#bzip2_version)
        * [bzip2._VERSION](#bzip2__VERSION)
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
   * [Compatibility with Perl's Compress::Raw::Bzip2](#compatibility-with-perls-compressrawbzip2)
   * [Errors](#errors)
   * [Thread safety / multiple Lua states](#thread-safety--multiple-lua-states)
   * [Building](#building)

<!-- ---------------------------------------------------------------------------------------- -->
##   Overview
<!-- ---------------------------------------------------------------------------------------- -->

The [Lua] module *compress.bzip2* of [lua-compress](../README.md) provides bzip2 
compression in the *.bz2* format of the *bzip2* tool, based on *libbz2*, the library of 
[bzip2]:

  * [bzip2.compress()](#bzip2_compress) and [bzip2.decompress()](#bzip2_decompress)
    process the whole data in one call.
  * [bzip2.compressor()](#bzip2_compressor) and 
    [bzip2.decompressor()](#bzip2_decompressor) create stream objects that take the 
    data in pieces.
  * [decompressor:decompress()](#decompressor_decompress) (also as *bzinflate()*) is the 
    variant of *decompressor:update()* that raises no errors for the data but returns 
    libbz2's status codes and the number of bytes consumed, for code that evaluates them 
    like Perl's *Compress::Raw::Bunzip2*.
  * The block size (*blockSize100k*, 1..9, also as *level*), the work factor and the low 
    memory decompression mode (*small*) of libbz2 can be given; with the same block size 
    and libbz2 version the output is byte for byte the same as that of the *bzip2* tool 
    and of Perl's *Compress::Raw::Bzip2* / *IO::Compress::Bzip2*, see 
    [Compressed Output](#compressed-output).

Data may be Lua strings or [carray] objects, see [Data](#data). Errors are raised with
*error()*, see [Errors](#errors). The module follows the 
[Common Conventions](README.md#common-conventions) of lua-compress.

The module name to require is *"compress.bzip2"*; it is also available as 
*require("compress").bzip2* through the [meta module](README.md#the-meta-module-compress):

```lua
local bzip2 = require("compress.bzip2")
```

This module works with Lua 5.1 up to 5.5 and LuaJIT. The [carray] module is optional: 
compress.bzip2 neither links against it nor requires it, carray objects are recognized
through the [Carray C API]. The rock *compress.bzip2* depends on nothing but Lua and 
libbz2 and can be installed without the other rocks of lua-compress.

The metatable names (*getmetatable()*) are *"compress.bzip2"*, 
*"compress.bzip2.compressor"* and *"compress.bzip2.decompressor"*; the latter two also 
appear in *tostring()* of the stream objects.

[Lua]:          https://www.lua.org
[bzip2]:        https://sourceware.org/bzip2/
[carray]:       https://github.com/osch/lua-carray
[Carray C API]: https://github.com/lua-capis/lua-carray-capi

<!-- ---------------------------------------------------------------------------------------- -->
##   Data
<!-- ---------------------------------------------------------------------------------------- -->

The data to compress or decompress (argument *data*, and *chunk* of the stream methods)
may be

  * a Lua string (a number is converted to a string, as in the string library), or
  * a carray object with elements of 1 byte size (element types *"char"*, *"uchar"*, 
    *"schar"*, *"int8"*, *"uint8"*). Other element types raise an error. A carray is read
    directly from its buffer, without copying; read-only carrays are accepted.

Data may contain arbitrary binary data including NUL bytes.

The result is a Lua string. Every function and method (except *version()*) can instead 
append its output to a carray given as its last argument *out* (see 
[Output](README.md#output-string-or-carray) in the Common Conventions):

  * the carray must have 1 byte elements and be writable and resizable, and must not be
    the same object as the input data of the call;
  * the output is appended after the carray's content, the carray is resized as needed 
    and returned instead of a string (also when nothing was appended); its capacity is 
    kept, so *buf:reset()* before a call reuses a carray without reallocation;
  * *bzip2.compress(data, out)* is *bzip2.compress(data, nil, out)*: the second argument 
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
bzip2.compress(data, { level = 9 }, buf)        -- buf contains the compressed data
buf:reset()                                     -- empty again, keeps the capacity
local c = bzip2.compressor()
for chunk in inputFile:lines(65536) do
    c:update(chunk, buf)                        -- appended to buf
end
c:finish(nil, buf)
```

<!-- ---------------------------------------------------------------------------------------- -->
##   Format
<!-- ---------------------------------------------------------------------------------------- -->

A bzip2 stream is the *.bz2* format of the *bzip2* tool: the header *"BZh"* with the 
block size digit *"1"* .. *"9"*, the compressed blocks (each one up to *blockSize100k* 
\* 100000 bytes of input, compressed on its own with the Burrows-Wheeler transform and 
Huffman coding, with a CRC32 of its data) and the end of stream marker with the combined
CRC of all blocks. The blocks are not byte aligned: the stream is a bit stream, its last
byte is padded with zero bits. The decoder checks the CRC of every block and the combined
CRC at the end.

libbz2 has only this format: there is no raw format and no other header. 
*BZ2_bzCompressInit()* / *BZ2_bzCompress()* compress, *BZ2_bzDecompressInit()* / 
*BZ2_bzDecompress()* decompress. The decompressor reads exactly up to the last byte of a
stream, never further: data after it (the next stream of a *.bz2* file, see below) is 
left as it is.

<!-- ---------------------------------------------------------------------------------------- -->
##   Concatenated Streams
<!-- ---------------------------------------------------------------------------------------- -->

*bzip2 -d* decompresses a file of several concatenated streams (*cat a.bz2 b.bz2*, 
parallel compressors such as *pbzip2* write files like that) as one, and Perl's 
*IO::Uncompress::Bunzip2* does with *MultiStream => 1*. compress.bzip2 decompresses one 
stream per decompressor: [bzip2.decompress()](#bzip2_decompress) raises an error for the 
data after the first stream, unless [allowtrailing](#option_allowtrailing) is set, then 
it is ignored (as *IO::Uncompress::Bunzip2* without *MultiStream*). All streams are read 
with the status method, whose *consumed* gives the start of the next stream:

```lua
local function decompressAll(input)
    local out, pos = {}, 1
    repeat
        local d = bzip2.decompressor()
        local o, status, consumed = d:decompress(input:sub(pos))
        if status ~= bzip2.BZ_STREAM_END then
            error(status == bzip2.BZ_OK and "unexpected end of input" or d:msg())
        end
        out[#out + 1] = o
        pos = pos + consumed
    until pos > #input
    return table.concat(out)
end
```

With streams that come in pieces, each piece is given to the decompressor of the current 
stream; when it returns *BZ_STREAM_END*, the rest of the piece (*chunk:sub(consumed + 
1)*) goes to a new decompressor. (With *MultiStream* and its default *Transparent => 1*,
*IO::Uncompress::Bunzip2* appends data after the last stream that is no bzip2 stream to 
the output unchanged.)

<!-- ---------------------------------------------------------------------------------------- -->
##   Module Functions
<!-- ---------------------------------------------------------------------------------------- -->

* <span id="bzip2_compress">**`bzip2.compress(data[, opts][, out])
  `**</span>
  
  Compresses *data* and returns the compressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray, see [Data](#data). May be empty.
  * *opts* - optional table with the [options](#options) *blockSize100k* (or *level*) 
    and *workFactor*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  The result is the output of *BZ2_bzCompress(BZ_RUN)* for the whole data and 
  *BZ2_bzCompress(BZ_FINISH)*, see [Compressed Output](#compressed-output).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="bzip2_decompress">**`bzip2.decompress(data[, opts][, out])
  `**</span>
  
  Decompresses *data* and returns the decompressed data as string, or appended to the 
  carray *out*, which is returned.
  
  * *data* - string or carray containing exactly one complete bzip2 stream.
  * *opts* - optional table with the [options](#options) *small*, *maxsize* and 
    *allowtrailing*.
  * *out* - optional carray, see [Data](#data); may also be given as second argument 
    when there are no options.
  
  Raises an error if *data* is not valid, if it ends before the end of the stream (this 
  includes empty *data*), if there is data after the end of the stream (unless 
  *allowtrailing* is set, see also [Concatenated Streams](#concatenated-streams)) or if 
  the output exceeds *maxsize*. The output is produced in a growing buffer; nothing of 
  the size *maxsize* is allocated in advance.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="bzip2_compressor">**`bzip2.compressor([opts])
  `**</span>
  
  Creates a compressor stream object, see [Compressor Methods](#compressor-methods).
  
  * *opts* - optional table with the options of [bzip2.compress()](#bzip2_compress). A 
    carray for the output is given to the methods, not to *compressor()*.
  
  The native encoder state (400 KB + 8 \* the block size: about 7.6 MB with block size 9,
  1.2 MB with 1) is released by [compressor:finish()](#compressor_finish), or by the 
  garbage collector if the object is no longer used. The garbage collector of Lua does 
  not see this memory; therefore streams should be finished.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="bzip2_decompressor">**`bzip2.decompressor([opts])
  `**</span>
  
  Creates a decompressor stream object, see [Decompressor Methods](#decompressor-methods).
  
  * *opts* - optional table with the options of [bzip2.decompress()](#bzip2_decompress);
    *maxsize* limits the whole output of the stream. A carray for the output is given to
    the methods, not to *decompressor()*.
  
  The decoder needs memory for the block size of the stream (from its header): 100 KB + 
  4 \* the block size, about 3.7 MB for block size 9, or with [small](#option_small) 
  100 KB + 2.5 \* the block size, about 2.3 MB.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="bzip2_version">**`bzip2.version()
  `**</span>
  
  Returns the version of libbz2 the module runs with (*BZ2_bzlibVersion()*), e.g. 
  *"1.0.8, 13-Jul-2019"*, the same string as Perl's 
  *Compress::Raw::Bzip2::bzlibversion()*. *bzlib.h* has no version macro, so unlike the 
  other modules there is no second value with the version compiled against.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="bzip2__VERSION">**`bzip2._VERSION
  `**</span>
  
  The version of the compress.bzip2 module as string, e.g. *"0.0.1"*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Constants
<!-- ---------------------------------------------------------------------------------------- -->

The module table contains the constants of *bzlib.h* (integers with libbz2's values), 
with the names of libbz2, which Perl's *Compress::Raw::Bzip2* uses as well:

  * **Status codes** (results of [decompressor:decompress()](#decompressor_decompress)):
    *BZ_OK* (0), *BZ_RUN_OK* (1), *BZ_FLUSH_OK* (2), *BZ_FINISH_OK* (3), 
    *BZ_STREAM_END* (4), *BZ_SEQUENCE_ERROR* (-1), *BZ_PARAM_ERROR* (-2), 
    *BZ_MEM_ERROR* (-3), *BZ_DATA_ERROR* (-4), *BZ_DATA_ERROR_MAGIC* (-5), 
    *BZ_IO_ERROR* (-6), *BZ_UNEXPECTED_EOF* (-7), *BZ_OUTBUFF_FULL* (-8), 
    *BZ_CONFIG_ERROR* (-9). The decompressor returns *BZ_OK*, *BZ_STREAM_END*, 
    *BZ_DATA_ERROR*, *BZ_DATA_ERROR_MAGIC*, *BZ_MEM_ERROR* and *BZ_OUTBUFF_FULL* (for 
    [maxsize](#option_maxsize)); *BZ_RUN_OK*, *BZ_FLUSH_OK* and *BZ_FINISH_OK* are 
    results of the compressor, *BZ_IO_ERROR* and *BZ_UNEXPECTED_EOF* of libbz2's file 
    functions, which compress.bzip2 does not use.
  * **Actions** (flush modes for [compressor:flush()](#compressor_flush)): *BZ_RUN* (0),
    *BZ_FLUSH* (1), *BZ_FINISH* (2).

<!-- ---------------------------------------------------------------------------------------- -->
##   Options
<!-- ---------------------------------------------------------------------------------------- -->

Options are given as table, e.g. *bzip2.compress(data, { blockSize100k = 1 })*. Numbers 
must be integers (or floats with an integral value). The defaults are those of the 
*bzip2* tool and libbz2's documentation (**not those of Perl**, see 
[Compatibility](#compatibility-with-perls-compressrawbzip2)). An option of the module that
the function does not take raises *option 'maxsize' is not supported by compress()*, a 
name that is no option of the module *unknown option 'name'*. The option names are the 
parameter names of *BZ2_bzCompressInit()* and *BZ2_bzDecompressInit()*.

  * <span id="option_blockSize100k">**blockSize100k**</span>, 
    <span id="option_level">**level**</span> - integer 1..9, default 9: the block size in 
    units of 100000 bytes, *bzip2 -1* .. *bzip2 -9*. Larger blocks compress better (for 
    data larger than the block size) and need more memory for compressing and 
    decompressing. The block size is stored in the header (*"BZh9"*). *level* is the 
    common name of the compression strength in lua-compress (see 
    [Options](README.md#conv-options) in the Common Conventions), an alias of 
    *blockSize100k*: both may be given if they have the same value, else 
    *level contradicts blockSize100k* is raised. Valid for *compress* and *compressor*.

  * <span id="option_workFactor">**workFactor**</span> - integer 0..250, default 0 (= 
    libbz2's default 30): how much effort the standard sorting algorithm spends on very 
    repetitive data before libbz2 switches to its slower but always reasonable fallback 
    algorithm. It changes the speed only, not the output: both algorithms give the same 
    bytes. Valid for *compress* and *compressor*.

  * <span id="option_small">**small**</span> - boolean, default *false*: the alternative 
    decompression algorithm of libbz2 (*BZ2_bzDecompressInit()* with *small* = 1, *bzip2 
    -s*), which needs about half the memory (at most about 2.3 MB) and is about half as 
    fast. Valid for *decompress* and *decompressor*.

  * <span id="option_maxsize">**maxsize**</span> - integer >= 0, default unlimited. Upper
    limit for the decompressed size; if the output would exceed it, the error 
    *output exceeds maxsize* is raised (by [decompress()](#decompressor_decompress): the 
    status *BZ_OUTBUFF_FULL*). This protects against compression bombs: bzip2 compresses 
    50 MB of zeros to less than 1 KB. No more than *maxsize* bytes of output are produced.
    The limit counts the output of the call (or of the stream), not the length of an 
    output carray. Valid for *decompress* and *decompressor*.

  * <span id="option_allowtrailing">**allowtrailing**</span> - boolean, default *false*.
    If *true*, data after the end of the stream is ignored instead of raising the 
    error *Error in BZ2_bzDecompress: unexpected data after end of stream*. Valid for 
    *decompress* and *decompressor*.

  * <span id="option_out">**out**</span> - no longer an option: the output carray is the
    last argument of the call, see [Data](#data). *out* in an options table raises 
    *option 'out' is no longer supported: pass the carray as the last argument*.

libbz2's *verbosity* (debug output on stderr) is not offered: it is always 0.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A compressor object is created by [bzip2.compressor()](#bzip2_compressor). The output
of all calls concatenated is one bzip2 stream. Each method takes an optional carray *out*
as last argument: the output is appended to it and the carray is returned instead of a 
string or *nil* (see [Data](#data)); the optional *chunk* comes first, *nil* gives none:
*c:finish(nil, out)*. A carray as only argument of *flush* or *finish* is the chunk.

```lua
local c = bzip2.compressor({ level = 9 })
for chunk in inputFile:lines(65536) do
    local out = c:update(chunk)
    if out then outputFile:write(out) end
end
outputFile:write(c:finish())
```

* <span id="compressor_update">**`compressor:update(chunk[, out])
  `**</span>

  Compresses *chunk* (string or carray) with *BZ_RUN*. Returns the compressed output
  that is available, or *nil* if there is none yet: libbz2 collects the input of a whole
  block (up to *blockSize100k* \* 100000 bytes) before it writes anything, the header 
  included. An empty chunk gives *nil* (libbz2 is not called).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_flush">**`compressor:flush([chunk][, mode][, out])
  `**</span>

  Compresses the optional *chunk* (as *update*) and flushes the compressor with *mode*; 
  returns the output (string, or *nil* if there is none), or the carray *out*. The stream
  can be continued with *update*. The second argument is *mode* if it is a string or a 
  number and *out* if it is a carray: *c:flush(chunk, out)* flushes with the default 
  mode. *mode* is a string or one of the action constants:

  * *"block"* or *bzip2.BZ_FLUSH* (default): ends the current block 
    (*BZ2_bzCompress(BZ_FLUSH)*, as Perl's *bzflush*); the next data starts a new block. 
    **This does not make the output decodable up to the last byte given**, as the sync 
    flushes of zlib and liblzma do: bzip2 is a bit stream, libbz2 holds back the last 
    bits of the block (up to a byte) until more output comes, and the decoder ends a 
    block only when it has read some bits of what follows. A decompressor fed with the 
    output so far gives the data of the earlier blocks; the data of the last block comes
    with the next output of the compressor (at the latest with *finish*). The name is 
    that of zlib's similar *Z_BLOCK*.
  * *bzip2.BZ_RUN*: no flush, the same as *update(chunk)*.
  * *"finish"* or *bzip2.BZ_FINISH*: the same as [finish(chunk)](#compressor_finish).

  *"sync"* and *"full"*, the flush modes of the other modules, raise *flush mode 'sync' is
  not supported for format 'bzip2'* before anything is done (the stream stays usable): 
  libbz2 cannot provide them. A flush at the start of the stream gives the first bytes of
  the header. A second flush without new data in between gives *nil*. Every flush ends a
  block, so frequent flushing makes the compression worse.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="compressor_finish">**`compressor:finish([chunk[, out]])
  `**</span>

  Compresses the optional *chunk*, ends the stream (*BZ_FINISH*) and returns the rest of
  the output as string (never empty). Releases the native encoder state; any further 
  call raises the error *compressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Decompressor Methods
<!-- ---------------------------------------------------------------------------------------- -->

A decompressor object is created by [bzip2.decompressor()](#bzip2_decompressor). It
decompresses one stream given in arbitrary pieces; the output of all calls 
concatenated is the same as that of [bzip2.decompress()](#bzip2_decompress) for the 
whole stream. *update* and *finish* raise errors; [decompress](#decompressor_decompress) 
returns libbz2's status codes instead. The methods may be mixed on the same object. Each 
method takes an optional carray *out* as last argument, as the compressor methods do.
libbz2 decodes a block when it has read all of it, so output comes block by block.

* <span id="decompressor_update">**`decompressor:update(chunk[, out])
  `**</span>

  Decompresses *chunk* (string or carray). Returns all output available so far, or *nil* 
  if there is none. Once the end of the stream has been reached, further chunks must be
  empty, unless the option *allowtrailing* is set: then they are ignored.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_finish">**`decompressor:finish([chunk[, out]])
  `**</span>

  Decompresses the optional *chunk* and checks that the stream is complete: raises the 
  error *Error in BZ2_bzDecompress: unexpected end of input* if it is not. Returns the 
  output of *chunk* (the empty string without *chunk*). Releases the native decoder 
  state; any further call raises the error *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_decompress">**`decompressor:decompress(chunk[, out])
  `**</span>
  <span id="decompressor_bzinflate">**`decompressor:bzinflate(chunk[, out])
  `**</span>

  The status method: decompresses *chunk* (string or carray) like *update*, but raises 
  no error for the data. **Unlike the module function 
  [bzip2.decompress()](#bzip2_decompress)**, which raises an error for invalid, 
  incomplete or trailing data, it returns three values: *output, status, consumed* (see 
  [The status method](README.md#the-status-method-decompressordecompress) in the Common
  Conventions). Errors are raised only for invalid arguments and a closed object. 
  *bzinflate* is the same method under the name of Perl's *$status = 
  $bz->bzinflate($in, $out)* of *Compress::Raw::Bunzip2*, for code that evaluates 
  libbz2's status like Perl code:

  * *output* - the decompressed data of this call, a string (*""* if there is none), or
    the carray *out* with the output appended; on an error the output up to the error.
  * *status* - one of the [status codes](#constants):
      * *BZ_OK* - all of *chunk* was consumed, the stream is not complete yet (also for 
        an empty or truncated stream: only *finish()* decides that the input ended).
      * *BZ_STREAM_END* - the end of the stream was reached. Data after it is not 
        consumed (*consumed* < *#chunk*) and does not raise an error, regardless of 
        *allowtrailing*; it may be the next stream, see 
        [Concatenated Streams](#concatenated-streams). Every later call returns 
        *"", BZ_STREAM_END, 0*.
      * *BZ_DATA_ERROR_MAGIC* (the data does not start with *"BZh1"* .. *"BZh9"*), 
        *BZ_DATA_ERROR* (invalid data, also a wrong block CRC or combined CRC; the CRC of
        a block is checked after its data was produced), *BZ_MEM_ERROR*. 
        [msg()](#decompressor_msg) gives the message. The stream cannot go on: every 
        later call returns the same status with no output.
      * *BZ_OUTBUFF_FULL* - the output would exceed *maxsize*; *output* contains the data 
        up to *maxsize*, *msg()* gives *"output exceeds maxsize"*. The stream cannot go 
        on.
  * *consumed* - the number of bytes of *chunk* that were used. Less than *#chunk* only
    for *BZ_STREAM_END* (the rest is data after the stream) and for errors.

  The statuses, *consumed* and the output are the same as those of 
  *Compress::Raw::Bunzip2*'s *bzinflate()* for the same input pieces (Perl's 
  *ConsumeInput* removes *consumed* bytes from its input buffer), checked by 
  *tests/bzip2/test04.lua*; on an error Perl leaves its input buffer as it was and 
  discards the output of the call. Empty input gives *BZ_OK* and does not call libbz2.

  ```lua
  local d = bzip2.decompressor()
  local out, status, consumed = d:bzinflate(data)
  if status == bzip2.BZ_STREAM_END then
      local trailing = data:sub(consumed + 1)    -- data after the bzip2 stream
  elseif status ~= bzip2.BZ_OK then
      print("error: " .. d:msg())
  end
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="decompressor_msg">**`decompressor:msg()
  `**</span>

  Returns the message of the last error of the decompressor, or *nil* if there was none.
  These are libbz2's own texts for its status codes (those of *BZ2_bzerror()*): 
  *"DATA_ERROR"*, *"DATA_ERROR_MAGIC"*, *"MEM_ERROR"*, ..., and compress.bzip2's 
  *"output exceeds maxsize"*, *"unexpected end of input"* and *"unexpected data after 
  end of stream"*. Also works after the object was closed.

After an error of *update* or *finish*, the native state of a stream object is released
and every further call raises *compressor is closed* or *decompressor is closed*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compressed Output
<!-- ---------------------------------------------------------------------------------------- -->

libbz2 is deterministic: the same libbz2 version with the same block size gives the same
bytes, whatever the work factor. compress.bzip2 gives these guarantees, checked by 
*tests/bzip2/test01.lua* and *tests/bzip2/test04.lua*:

  * *bzip2.compress(data, opts)* is the output of *BZ2_bzCompress(BZ_RUN)* for the whole 
    data and then *BZ2_bzCompress(BZ_FINISH)*, as the *bzip2* tool (*BZ2_bzWrite()*, 
    *BZ2_bzWriteClose()*) and Perl's *Compress::Raw::Bzip2* (*bzdeflate*, *bzclose*) do it.
  * A compressor gives the same output as *compress* for any chunk sizes (*update* and 
    *finish* without flushes); *finish(chunk)* and *flush(chunk)* compress the chunk with 
    *BZ_RUN* first.
  * The output is byte for byte the same as that of *bzip2 -1* .. *bzip2 -9* (*-9* is the
    default of both) and of Perl's *Compress::Raw::Bzip2* and *IO::Compress::Bzip2* with 
    the same block size (Perl's default is 1), also with Perl's *bzflush* after the same 
    pieces of input and *flush()*.
  * libbz2's one-call function *BZ2_bzBuffToBuffCompress()*, which gives all input to 
    *BZ_FINISH* at once, writes other bytes in one rare case: when the input ends just 
    where a block becomes full (the last byte is still in libbz2's run-length encoder), 
    it puts the last byte into that block, the others into a block of its own. Both 
    decompress to the same data.

<!-- ---------------------------------------------------------------------------------------- -->
##   Compatibility with Perl's Compress::Raw::Bzip2
<!-- ---------------------------------------------------------------------------------------- -->

For code ported from Perl, the classes of *Compress::Raw::Bzip2* and the functions of 
*IO::Compress::Bzip2* / *IO::Uncompress::Bunzip2* correspond to these calls. **Perl's 
default block size is 1** (*$blockSize100k* of *Compress::Raw::Bzip2->new* and 
*BlockSize100K* of *IO::Compress::Bzip2*: 100 kB), where the *bzip2* tool and 
compress.bzip2 use 9: give *blockSize100k = 1* (or *level = 1*) to get Perl's output 
byte for byte, with the same libbz2 version (*Compress::Raw::Bzip2::bzlibversion()* and 
*bzip2.version()*). *Compress-Raw-Bzip2* bundles libbz2 (1.0.8) by default, many 
distributions build it with the system's libbz2. Perl's work factor default is 0 (= 30), 
as here.

| Perl                                                           | compress.bzip2                                                              |
|----------------------------------------------------------------|-----------------------------------------------------------------------------|
| *Compress::Raw::Bzip2->new($append, $bs, $wf)*, defaults 1, 1, 0 | *c = bzip2.compressor({ blockSize100k = bs, workFactor = wf })* (defaults 9, 0) |
| *$bz->bzdeflate($in, $out)*                                    | *c:update(in)* (or *c:update(in, out)* with a carray)                       |
| *$bz->bzflush($out)*                                           | *c:flush()* (mode *"block"*, *BZ_FLUSH*)                                    |
| *$bz->bzclose($out)*                                           | *c:finish()*                                                                |
| *Compress::Raw::Bunzip2->new($append, $consume, $small)*, defaults 1, 1, 0 | *d = bzip2.decompressor({ small = true })*                       |
| *$status = $bz->bzinflate($in, $out)*                          | *out, status, n = d:bzinflate(in)* (= *d:decompress(in)*); *in:sub(n + 1)* is what Perl leaves in *$in* |
| *IO::Compress::Bzip2::bzip2(\\$in => \\$out, BlockSize100K => bs, WorkFactor => wf)* | *bzip2.compress(in, { blockSize100k = bs or 1, workFactor = wf })* |
| *IO::Uncompress::Bunzip2::bunzip2(\\$in => \\$out, Small => s)* | *bzip2.decompress(in, { small = s, allowtrailing = true })*               |
| *... MultiStream => 1*                                         | a loop over the streams, see [Concatenated Streams](#concatenated-streams)  |
| *Compress::Raw::Bzip2::bzlibversion()*                         | *bzip2.version()*                                                           |
| *BZ_OK*, *BZ_STREAM_END*, *BZ_DATA_ERROR*, ...                 | *bzip2.BZ_OK*, *bzip2.BZ_STREAM_END*, *bzip2.BZ_DATA_ERROR*, ...            |

Differences:

  * Perl's *bzinflate()* modifies its input argument (with *ConsumeInput*, the default, 
    it removes the consumed bytes, but not after an error) and appends to its output 
    argument (*AppendOutput*, the default), but discards the output of a call that ends 
    with an error; compress.bzip2 returns the output, up to an error, and *consumed*. A 
    carray as *out* corresponds to *AppendOutput*. *LimitOutput* has no counterpart (the
    output grows as needed; [maxsize](#option_maxsize) limits it).
  * After the end of the stream, Perl's *bzinflate()* gives *BZ_SEQUENCE_ERROR* (libbz2's
    status for a finished stream); compress.bzip2 gives *BZ_STREAM_END* again (Common 
    Conventions).
  * Perl's statuses are dual values whose strings are Perl's own texts (*"Data Error"*, 
    *"Magic Error"*); compress.bzip2's [msg()](#decompressor_msg) gives libbz2's 
    (*"DATA_ERROR"*, *"DATA_ERROR_MAGIC"*).
  * *IO::Uncompress::Bunzip2* ignores data after the end of the stream (as 
    *allowtrailing*), and by default (*Transparent => 1*) passes input through unchanged
    that is not bzip2 data at all (it does not start with *"BZh"*): its *bunzip2()* then
    succeeds with a copy of the input. compress.bzip2 does not do the latter, but 
    [decompress()](#decompressor_decompress) gives the status *BZ_DATA_ERROR_MAGIC* to 
    decide it. Empty input is an error for compress.bzip2, *bunzip2()* gives an empty 
    output.
  * *Verbosity* is not offered (always 0).

<!-- ---------------------------------------------------------------------------------------- -->
##   Errors
<!-- ---------------------------------------------------------------------------------------- -->

All errors are raised with *error()*, except the status method 
[decompressor:decompress()](#decompressor_decompress). The function name in argument errors 
depends on the Lua version.

  * **Invalid compressed data**: *Error in BZ2_bzDecompress: \<message\>* with the messages
    of [msg()](#decompressor_msg): *Error in BZ2_bzDecompress: DATA_ERROR_MAGIC* (no 
    bzip2 header), *Error in BZ2_bzDecompress: DATA_ERROR* (corrupt data, also a wrong 
    CRC).
  * **Incomplete compressed data**: *Error in BZ2_bzDecompress: unexpected end of input*.
  * **Data after the end of the stream**: 
    *Error in BZ2_bzDecompress: unexpected data after end of stream*, unless the option 
    *allowtrailing* is set.
  * **Output limit**: *output exceeds maxsize*.
  * **libbz2 failures**: *Error in BZ2_bzCompressInit: MEM_ERROR* (also 
    *BZ2_bzDecompressInit*, *BZ2_bzCompress*, *BZ2_bzDecompress*; *CONFIG_ERROR* for a 
    libbz2 built for another platform).
  * **Invalid options**: argument errors with the messages *invalid blockSize100k value*,
    *invalid level value*, *level contradicts blockSize100k*, *invalid workFactor value*, 
    *invalid small value*, *invalid maxsize value*, *invalid allowtrailing value*, 
    *unknown option 'name'*, *option 'name' is not supported by compress()* (also 
    *decompress*, *compressor*, *decompressor*), *option 'out' is no longer supported: 
    pass the carray as the last argument*, *option names must be strings*, *table or 
    carray expected, got string* (second argument of *compress*/*decompress*), *table 
    expected, got string* (*compressor*, *decompressor*), e.g. 
    *bad argument #2 to 'compress.bzip2.compress' (invalid blockSize100k value)*; 
    *invalid flush mode* (argument 3 of *flush*).
  * **Flush modes**: *flush mode 'sync' is not supported for format 'bzip2'* (also 
    *'full'*).
  * **Invalid data arguments**: *string or carray expected, got table*, 
    *carray elements must be 1 byte in size*.
  * **Output carray**: *out: carray expected, got string*, *out: carray is not writable*,
    *out: carray elements must be 1 byte in size*, 
    *out: carray must not be the input data*, *cannot resize carray* (the carray is not 
    resizable, e.g. one referencing foreign memory, or out of memory), as argument errors
    of the position of *out*.
  * **Stream objects**: *compressor is closed*, *decompressor is closed* (after *finish* 
    or after an error of *update*/*finish*).
  * **Out of memory**: *Error in BZ2_bzCompressInit: MEM_ERROR* and the like, or Lua's 
    memory error.

<!-- ---------------------------------------------------------------------------------------- -->
##   Thread safety / multiple Lua states
<!-- ---------------------------------------------------------------------------------------- -->

compress.bzip2 has no global mutable data: the cached Carray C API is kept per Lua state 
(in upvalues of the module functions), each stream object owns its own libbz2 stream. 
libbz2's stream functions have no global state either. compress.bzip2 can therefore be 
loaded into several independent Lua states of the same process, and these states can be 
used concurrently from different OS threads (each state by one thread at a time, as 
usual for Lua). Closing one state does not affect the others. *tests/bzip2/test03.lua* 
checks this with two Lua states running in parallel threads.

<!-- ---------------------------------------------------------------------------------------- -->
##   Building
<!-- ---------------------------------------------------------------------------------------- -->

With [LuaRocks](https://luarocks.org) from the repository root:

```
luarocks make rockspecs/compress.bzip2-scm-0.rockspec
luarocks --lua-version 5.4 --local make rockspecs/compress.bzip2-scm-0.rockspec
```

libbz2 is the only external dependency of this rock (*BZIP2*: header *bzlib.h*, library 
*bz2*). If it is not installed in a standard location, give its prefix or its 
directories:

```
luarocks make rockspecs/compress.bzip2-scm-0.rockspec BZIP2_DIR=/opt/homebrew/opt/bzip2
luarocks make rockspecs/compress.bzip2-scm-0.rockspec BZIP2_INCDIR=... BZIP2_LIBDIR=...
```

Packages: *libbz2-dev* (Debian/Ubuntu), *bzip2* (Arch/Manjaro, Homebrew; macOS also has 
libbz2 in its SDK), *bzip2-devel* (Fedora). libbz2 1.0 or later.

Windows:

  * **MSVC**: the rockspec links the import library *bz2.lib*, the name of vcpkg's port 
    *bzip2* (the DLL is *bz2.dll*). Install it with vcpkg 
    (*vcpkg install bzip2:x64-windows*) and build in a Visual Studio developer prompt 
    with *BZIP2_DIR=\<vcpkg\>/installed/x64-windows*; the DLL from *\<dir\>/bin* must be 
    on the *PATH*. Other builds may name the import library *libbz2.lib*: then copy it to
    *bz2.lib*. The original *bzlib.h* of bzip2 declares the functions as function 
    pointers on Windows unless *BZ_EXPORT* is defined; compress.bzip2 defines it, the 
    patched headers of vcpkg and MSYS2 do not need it.
  * **MinGW/MSYS2**: install *mingw-w64-ucrt-x86_64-bzip2* (or *mingw-w64-x86_64-bzip2*);
    the rockspec links *libbz2.dll.a* (library *bz2*). If LuaRocks does not find it, give 
    *BZIP2_DIR=/ucrt64* or *BZIP2_INCDIR=/ucrt64/include BZIP2_LIBDIR=/ucrt64/lib*.

Without LuaRocks, the Makefile in *src* builds *src/build/lua$(LUA_VERSION)/compress/bzip2.so*
(settings can be overridden in *src/sandbox.mk*; *COPTS* and *LOPTS* are added to the 
flags of libbz2 from *pkg-config*, if it knows *bzip2*, else *-lbz2*); *src/activate.sh* 
sets the Lua paths for using the module from the source tree:

```
cd src
make bzip2 LUA_VERSION=5.4 COPTS=-I/usr/include/lua5.4
. activate.sh
```

The tests are run from the *tests/bzip2* directory:

  * *lua test01.lua* - string data: block sizes, work factor, option errors, errors 
    (bad magic, corrupt and truncated data), trailing data and concatenated streams, 
    *maxsize*, the *small* mode, streaming with all chunk sizes (also 1 byte), flush 
    modes, the status method *decompress()* (and its alias *bzinflate()*), 10 MB
  * *lua test02.lua* - carray data, carray output of all functions and methods 
    (appending, reuse after reset, returned object, maxsize, errors), carray chunks 
    (skipped if carray is not installed); the error cases for read-only and 
    non-resizable carrays need the test helper module *compress_testcarray* 
    (*luarocks make tests/compress_testcarray-scm-0.rockspec* from the repository root,
    or *make testcarray* in *src*), skipped if it is not installed
  * *lua test03.lua* - several Lua states in parallel threads; needs the test helper 
    module *compress_multistate* (*luarocks make tests/compress_multistate-scm-0.rockspec*
    from the repository root, or *make multistate* in *src*), skipped if it is not 
    installed
  * *lua test04.lua* - comparison with Perl (*Compress::Raw::Bzip2*, 
    *Compress::Raw::Bunzip2*, *IO::Compress::Bzip2*, *IO::Uncompress::Bunzip2*, through 
    the helper script *test04.pl*; *COMPRESS_TEST_PERL* names the Perl, *PERL5LIB* may 
    give a local::lib): byte for byte the same compressed output for the same block size
    (if Perl uses the same libbz2 version), also with *bzflush*, Perl decompresses our 
    output (also *MultiStream*), the same statuses, consumed bytes and output of 
    *bzinflate()*; the command line tool *bzip2* (byte for byte with *bzip2 -1* .. 
    *-9*, both directions, also *bzip2 -d -s* and concatenated streams). With 
    *COMPRESS_TEST_REQUIRE_IDENTICAL=1* a different libbz2 version of Perl or *bzip2* is 
    an error. Each part is skipped if the tool is not installed, the command line tool on
    Windows.

<!-- ---------------------------------------------------------------------------------------- -->
