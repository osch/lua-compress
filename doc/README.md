# lua-compress Documentation
<!-- ---------------------------------------------------------------------------------------- -->
##   Contents
<!-- ---------------------------------------------------------------------------------------- -->

   * [Overview](#overview)
   * [Modules and Rocks](#modules-and-rocks)
   * [The Meta Module compress](#the-meta-module-compress)
        * [compress.\<name\>](#compress_name)
        * [compress.names](#compress_names)
        * [compress._VERSION](#compress__VERSION)
   * [Common Conventions](#common-conventions)
        * [Functions and methods](#functions-and-methods)
        * [Data](#conv-data)
        * [Output: string or carray](#output-string-or-carray)
        * [The status method decompressor:decompress()](#the-status-method-decompressordecompress)
        * [Options](#conv-options)
        * [Errors](#conv-errors)
        * [Thread safety](#conv-threads)
   * [Building](#building)

<!-- ---------------------------------------------------------------------------------------- -->
##   Overview
<!-- ---------------------------------------------------------------------------------------- -->

*lua-compress* is a collection of [Lua] modules for compression and decompression, each
one based on the reference C library of its format. All modules share the same 
conventions (see [Common Conventions](#common-conventions)):

  * data may be Lua strings or [carray] objects; a carray is read directly from its 
    buffer, without copying,
  * the output is a new Lua string, or is appended in place to a carray given as the 
    last argument of a call,
  * there are functions that process the whole data in one call, and stream objects 
    (compressor, decompressor) that take the data in pieces,
  * errors are raised with *error()*; the decompressor method 
    [decompress()](#the-status-method-decompressordecompress) returns the status codes 
    of the C library instead.

The modules work with Lua 5.1 up to 5.5 and LuaJIT. The [carray] module is optional: no
module links against it or requires it, carray objects are recognized through the 
[Carray C API].

[Lua]:          https://www.lua.org
[carray]:       https://github.com/osch/lua-carray
[Carray C API]: https://github.com/lua-capis/lua-carray-capi

<!-- ---------------------------------------------------------------------------------------- -->
##   Modules and Rocks
<!-- ---------------------------------------------------------------------------------------- -->

Each module is a rock of its own, with the module name as rock name:

| Rock / module                       | Format           | C library                      | Status   |
|-------------------------------------|------------------|--------------------------------|----------|
| [compress.brotli](brotli.md)        | Brotli           | libbrotlidec, libbrotlienc     | done     |
| [compress.zlib](zlib.md)            | zlib, gzip, raw  | zlib                           | done     |
| [compress.lzma](lzma.md)            | xz, lzma, raw    | liblzma (XZ Utils)             | done     |
| [compress.bzip2](bzip2.md)          | bzip2            | libbz2                         | done     |
| *compress* (meta rock)              | -                | -                              | done     |

  * A module rock *compress.\<name\>* depends on nothing but Lua and needs only its own 
    C library as external dependency. It can be installed alone, e.g. 
    *luarocks install compress.brotli*, and is then used with 
    *require("compress.brotli")*. The module rocks do not depend on each other; the 
    helper sources they have in common (Lua compatibility, Carray C API header) are 
    compiled into each module, there is no shared runtime module.
  * The meta rock *compress* depends on all module rocks and installs the pure Lua 
    module *compress*, see [below](#the-meta-module-compress). It is the only rock that 
    contains *compress.lua*.

A module *compress.\<name\>* is a C module (entry point *luaopen_compress_\<name\>*), 
installed as *compress/\<name\>.so* (*compress/\<name\>.dll* on Windows) in the Lua 
C module path.

<!-- ---------------------------------------------------------------------------------------- -->
##   The Meta Module compress
<!-- ---------------------------------------------------------------------------------------- -->

The pure Lua module *compress* of the meta rock gives access to all modules under one 
name. Each module is loaded on its first access only:

```lua
local compress = require("compress")

local brotli = compress.brotli                 -- loads "compress.brotli" now
assert(brotli == require("compress.brotli"))   -- the same object
```

* <span id="compress_name">**`compress.<name>`
  `**</span>

  For a name listed in [compress.names](#compress_names): the module 
  *"compress.\<name\>"*. On the first access it is loaded with *require()* and stored in
  the table *compress*, so *require("compress").brotli* and *require("compress.brotli")*
  are the same object (it is also in *package.loaded*). Errors of *require()*, e.g. for a
  module that is not installed, are raised on the access and nothing is stored, so a 
  later access tries again.

  Any other key gives *nil*, as for an ordinary table: no module is looked up for it. 
  A misspelled module name therefore gives *nil*, not an error; *compress.names* tells
  which names are modules. (Raising an error for unknown keys was not chosen, because 
  generic code that inspects tables, e.g. serializers or *if compress.x then*, must not 
  fail on it.)

* <span id="compress_names">**`compress.names`
  `**</span>

  The names of the modules the meta module knows, as a list of strings in the order of
  [Modules and Rocks](#modules-and-rocks), e.g. *{ "brotli", "zlib", "lzma", "bzip2" }*. These are 
  the modules the meta rock depends on.

* <span id="compress__VERSION">**`compress._VERSION`
  `**</span>

  The version of the meta module as string, e.g. *"0.0.1"*. The modules have their own
  *_VERSION* (all rocks of lua-compress are released with the same version number).

The metatable of the table *compress* is protected: *getmetatable(compress)* gives the 
string *"compress"*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Common Conventions
<!-- ---------------------------------------------------------------------------------------- -->

These conventions hold for all modules: [compress.brotli](brotli.md), 
[compress.zlib](zlib.md), [compress.lzma](lzma.md) and [compress.bzip2](bzip2.md) follow 
them and describe them in detail. A module documents only what is specific to its format:
its options, status codes and flush modes.

### Functions and methods

| Call                                         | Result                                           |
|----------------------------------------------|--------------------------------------------------|
| *M.compress(data[, opts][, out])*            | compressed data                                  |
| *M.decompress(data[, opts][, out])*          | decompressed data                                |
| *M.compressor([opts])*                       | compressor stream object                         |
| *M.decompressor([opts])*                     | decompressor stream object                       |
| *compressor:update(chunk[, out])*            | output so far                                    |
| *compressor:flush([chunk][, mode][, out])*   | output, decodable up to the last byte given (*mode* where the format has flush modes; bzip2 can only end its block, see [compress.bzip2](bzip2.md#compressor_flush)) |
| *compressor:finish([chunk][, out])*          | the rest of the output; ends the stream          |
| *decompressor:update(chunk[, out])*          | output so far                                    |
| *decompressor:finish([chunk][, out])*        | the rest of the output; checks the end           |
| *decompressor:decompress(chunk[, out])*      | *output, status, consumed*, raises no data errors |
| *decompressor:msg()*                         | the message of the last error, or *nil*          |
| *M.version()*, *M._VERSION*                  | version of the C library, of the module          |

*M.compress()* and *M.decompress()* process the whole data in one call; the stream 
objects take it in pieces, the output of all calls concatenated is the same. A module 
may add aliases with the names of the Perl module it corresponds to (zlib: *inflate* for 
*decompress*). *finish()* releases the native state; afterwards, and after an error of a
raising method, every call raises *compressor is closed* / *decompressor is closed*. The
native state is also released by the garbage collector, but Lua does not see its memory, 
so streams should be finished.

<span id="conv-data"></span>
### Data

*data* and *chunk* are a Lua string (a number is converted to a string, as in the 
string library) or a carray with 1 byte elements (*"char"*, *"uchar"*, *"schar"*, 
*"int8"*, *"uint8"*), read directly from its buffer, without copying; read-only carrays 
are accepted. Data may contain arbitrary bytes including NUL.

### Output: string or carray

**The output of every call is a new Lua string, unless the call is given a carray: then
the output is appended to the carray and the carray is returned.** This holds for the 
one-shot functions and for all stream methods alike:

  * **Without a carray**: the one-shot functions and *finish()* return a string (never 
    *nil*); *update()* and *flush()* return a string, or *nil* if there is no output 
    yet; *decompress()* returns *""* if there is no output.
  * **With a carray**: the output is appended after the content the carray has; nothing
    is replaced. The call returns the carray, also when nothing was appended 
    (*decompress()*: *carray, status, consumed*). Reusing a buffer is the caller's 
    business: *buf:reset()* empties a carray and keeps its capacity (see [carray]), so 
    that a buffer used again and again is not reallocated once it is large enough. 
    There is no buffer bound to a stream object: each call names its own carray (or 
    none).
  * **Position**: the carray is always an argument of its own, the last one:
      * One-shot functions, whose *data* is required: the second argument is the 
        options table if it is a table (or *nil*), and *out* if it is a carray; so 
        *M.compress(data, out)* is *M.compress(data, nil, out)*, and 
        *M.compress(data, opts, out)* gives both. Any other type raises the argument 
        error *table or carray expected, got string*.
      * Stream methods: the arguments are positional, *chunk* always comes first, also 
        where it is optional. A carray at the position of *chunk* is the chunk (input 
        data); to give *out* without a chunk, pass *nil*: *c:finish(nil, out)*, 
        *c:flush(nil, out)*. An optional argument between *chunk* and *out* that is no 
        data (the *mode* of zlib's *flush*) is told from *out* by its type: 
        *c:flush(chunk, out)* and *c:flush(chunk, "full", out)* are both valid.
      * *nil* as *out* is the same as no *out*: the result is a string.
  * **Requirements**: the carray has 1 byte elements and is writable and resizable 
    (else *out: carray elements must be 1 byte in size*, *out: carray is not writable*,
    *cannot resize carray*); it must not be the same object as the input data of the 
    call (*out: carray must not be the input data*). Errors of *out* are argument errors
    of its position, e.g. *bad argument #3 to 'update' (out: carray expected, got 
    string)*.
  * **Not an option**: *out* is no option; *out* in an options table raises 
    *option 'out' is no longer supported: pass the carray as the last argument*.
  * **maxsize** counts the output of the call (one-shot functions) or of the stream 
    (decompressor objects), never the length of the carray: content that the carray 
    had before does not count.
  * **Errors**: if a raising call fails, the carray is set back to the length it had 
    before the call: it keeps its previous content, including what earlier successful 
    calls of the same stream appended, and nothing of the failed call. Argument errors
    are raised before anything is written. The status method *decompress()* raises no
    error for the data: like its string result, the carray receives the output up to 
    the error.

The [carray] module is optional: no module links against it or requires it, carrays 
are recognized through the [Carray C API].

### The status method decompressor:decompress()

*decompressor:decompress(chunk[, out])* is the variant of *decompressor:update()* that 
raises no errors for the data, for code that evaluates the status of the C library 
(e.g. ported from Perl's *Compress::Zlib* and similar modules). **Unlike the module 
function *M.decompress()*, which raises an error for invalid, incomplete or trailing 
data, the method returns a status.** It raises errors only for invalid arguments, a 
closed object and memory errors. It returns three values:

  * *output* - the output of this call: a string (*""* if there is none), or the carray
    *out*; on an error the output up to the error.
  * *status* - the status code of the C library, an integer with the library's value; 
    the module offers the codes as constants with the library's names (zlib: *Z_OK*, 
    *Z_STREAM_END*, ...; brotli: *BROTLI_DECODER_RESULT_SUCCESS*, ...; lzma: *LZMA_OK*,
    *LZMA_STREAM_END*, ...; bzip2: *BZ_OK*, *BZ_STREAM_END*, ...). There are 
    four kinds of results:
      * the stream goes on: all of *chunk* was consumed and more input is expected (also
        for an empty or truncated stream: only *finish()* decides that the input ended);
      * the end of the stream: data after it is not consumed and is no error, regardless
        of *allowtrailing*; every later call returns *""* (or *out* unchanged), the same
        status and *consumed* 0;
      * invalid data: [msg()](#functions-and-methods) gives the message (zlib's *msg*, 
        libbrotli's error code name, the xz tool's message for liblzma's status); the 
        stream cannot go on: every later call returns the same status with no output and
        *consumed* 0;
      * the output would exceed *maxsize* (zlib: *Z_BUF_ERROR*, lzma: *LZMA_BUF_ERROR*,
        bzip2: *BZ_OUTBUFF_FULL*): the output up to *maxsize* is returned, 
        *msg()* gives *"output exceeds maxsize"*; the stream cannot go on.
  * *consumed* - the number of bytes of *chunk* that were used. Less than *#chunk* only 
    at the end of the stream (the rest is data after the stream: *chunk:sub(consumed + 
    1)*) and for errors.

The methods may be mixed on the same object: after the end of the stream *finish()* 
succeeds, after an error *update()* and *finish()* raise it (and close the object), and
*decompress()* after a raising error gives *decompressor is closed*. *msg()* also works 
after the object was closed. A module may offer the method under the name of the Perl 
module as well: zlib *inflate* (*Compress::Raw::Zlib*), lzma *code* 
(*Compress::Raw::Lzma*), bzip2 *bzinflate* (*Compress::Raw::Bzip2*).

<span id="conv-options"></span>
### Options

Options are given as a table; numbers must be integers (or floats with an integral 
value). A name that is no option of the module raises *unknown option 'name'*, an option
of the module that the function does not take raises *option 'name' is not supported by
compress()* (e.g. *maxsize* for *compress*); keys that are no strings raise *option names
must be strings*. Options common to all modules:

  * **level** - the compression strength, for *compress* and *compressor*. Each module 
    maps it to its library's parameter and range:

    | Module          | level is            | Range, default       |
    |-----------------|---------------------|----------------------|
    | compress.zlib   | *level* itself      | -1..9, -1 (= 6)      |
    | compress.brotli | alias of *quality*  | 0..11, 11            |
    | compress.lzma   | alias of *preset*   | 0..9, 6              |
    | compress.bzip2  | alias of *blockSize100k* | 1..9, 9         |

    Where *level* is an alias, both names may be given if they have the same value; 
    different values raise *level contradicts quality* (*preset*, *blockSize100k*).
  * **maxsize** - limit for the decompressed size (protection against compression 
    bombs), for *decompress* and *decompressor*: *output exceeds maxsize* (or the status 
    of *decompress()*); no more than *maxsize* bytes of output are produced.
  * **allowtrailing** - boolean: ignore data after the end of the compressed stream 
    instead of raising *unexpected data after end of stream*, for *decompress* and 
    *decompressor*.

The window size is module specific: *lgwin* (brotli), *windowBits* (zlib), *dictSize* 
(lzma). Option names that come from the C library keep its spelling (*windowBits*, 
*memLevel*, *blockSize100k*).

<span id="conv-errors"></span>
### Errors

Errors are raised with *error()* as strings; messages of the C library are passed on 
with the name of the failing C function, e.g. 
*Error in BrotliDecoderDecompressStream: ERROR_FORMAT_PADDING_1*, *Error in inflate: 
incorrect header check*. The only exception is the status method 
[decompress()](#the-status-method-decompressordecompress).

<span id="conv-threads"></span>
### Thread safety

No module has global mutable data. The modules can be loaded into several independent 
Lua states of the same process that run in different OS threads.

<!-- ---------------------------------------------------------------------------------------- -->
##   Building
<!-- ---------------------------------------------------------------------------------------- -->

With [LuaRocks](https://luarocks.org) from the repository root, each module rock first, 
then the meta rock:

```
luarocks make rockspecs/compress.brotli-scm-0.rockspec
luarocks make rockspecs/compress.zlib-scm-0.rockspec
luarocks make rockspecs/compress.lzma-scm-0.rockspec
luarocks make rockspecs/compress.bzip2-scm-0.rockspec
luarocks make rockspecs/compress-scm-0.rockspec
```

The rockspecs are in *rockspecs/*: *compress.\<name\>-\<version\>.rockspec* for the 
module rocks, *compress-\<version\>.rockspec* for the meta rock, each as release and as 
*scm-0*. *rockspecs/setversion.lua \<version\>* (run in *rockspecs/*) sets the version 
of all release rockspecs and the *_VERSION* of the meta module. The external 
dependencies of each module (and how to give non-standard locations) are described in 
its documentation: [compress.brotli](brotli.md#building), 
[compress.zlib](zlib.md#building), [compress.lzma](lzma.md#building), 
[compress.bzip2](bzip2.md#building).

Without LuaRocks, the Makefile in *src* builds the modules into 
*src/build/lua$(LUA_VERSION)/compress/* (*make* builds all modules, *make brotli*, 
*make zlib*, *make lzma* or *make bzip2* one of them; settings can be overridden in 
*src/sandbox.mk*), and *src/activate.sh* sets the Lua paths for using the modules and the meta module from the
source tree:

```
cd src
make LUA_VERSION=5.4 COPTS=-I/usr/include/lua5.4
. activate.sh
```

Source layout: *src/compress.lua* (meta module), *src/\<name\>/* (the C sources of a 
module), *src/common/* (sources compiled into every module: *util.h*, *compat-5.3.\**, 
*carray_capi.h*, and *data.h* with the handling of string and carray data that all 
modules share). The tests are in *tests/\<name\>/* and are run from that directory, 
e.g. *cd tests/brotli; lua test01.lua*; *tests/compress/test01.lua* tests the meta 
module. Two test helper modules are shared by the tests of all modules: 
*compress_testcarray* (read-only and non-resizable carrays) and *compress_multistate* 
(several Lua states in parallel threads), installed with 
*luarocks make tests/compress_testcarray-scm-0.rockspec* and 
*luarocks make tests/compress_multistate-scm-0.rockspec* (or *make testcarray* and 
*make multistate* in *src*); tests that need them are skipped if they are not installed.
