-- Compares compress.brotli with other Brotli implementations on this machine, for the same
-- parameters: the brotli command line tool and Perl's IO::Compress::Brotli. Each part is
-- skipped if the tool is not installed. Both use libbrotli, so the compressed bytes are
-- expected to be identical, not only the decompressed data.

local brotli = require("compress.brotli")

local format = string.format

-- the Perl to compare with (COMPRESS_TEST_PERL, default "perl" from PATH; a
-- path without spaces)
local PERL = os.getenv("COMPRESS_TEST_PERL") or "perl"

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end

-- os.execute returns a number in Lua 5.1/LuaJIT and true/nil in Lua 5.2+
local function run(cmd)
    local r = os.execute(cmd)
    return r == true or r == 0
end

local function readFile(name)
    local f = assert(io.open(name, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(name, data)
    local f = assert(io.open(name, "wb"))
    f:write(data)
    f:close()
end

local function newRandom(seed)
    local x = seed
    return function(n)
        x = (x * 16807) % 2147483647
        return x % n
    end
end

local function randomBytes(n, seed)
    local rnd = newRandom(seed)
    local t = {}
    for i = 1, n do t[i] = string.char(rnd(256)) end
    return table.concat(t)
end

local function text(n, seed)
    local words = { "lorem", "ipsum", "dolor", "sit", "amet", "\0", "\n", "Brotli", "Lua", "1234" }
    local rnd = newRandom(seed)
    local t, len = {}, 0
    while len < n do
        local w = words[rnd(#words) + 1]
        t[#t + 1] = w .. " "
        len = len + #w + 1
    end
    return table.concat(t):sub(1, n)
end

local datasets = {
    { "empty",  "" },
    { "nul",    ("\0"):rep(1000) },
    { "text",   text(300000, 3) },
    { "random", randomBytes(60000, 5) },
    { "mixed",  text(100000, 7) .. randomBytes(30000, 9) .. text(100000, 11) },
}
local params = {}
for _, q in ipairs({ 0, 1, 2, 5, 9, 10, 11 }) do
    for _, w in ipairs({ 10, 16, 22, 24 }) do
        params[#params + 1] = { q, w }
    end
end

-- os.tmpname() gives a name in the root directory on Windows, use the current one there
local isWindows = package.config:sub(1, 1) == "\\"
local tmp = isWindows and "compress_brotli_test04.tmp" or os.tmpname()
local files = {}
local function tmpFile(suffix)
    local name = tmp .. suffix
    files[#files + 1] = name
    return name
end

-- reads a file written by a tool and registers it for cleanup
local function readTmp(name)
    files[#files + 1] = name
    return readFile(name)
end

local function cleanup()
    for _, name in ipairs(files) do os.remove(name) end
    os.remove(tmp)
end

local compared  = 0
local fallbacks = 0

PRINT("==================================================================================")
if not run("brotli --version > " .. tmpFile(".v") .. " 2>&1") then
    print("brotli command line tool not available: test part skipped")
else
    PRINT(readFile(tmp .. ".v"):gsub("%s+$", ""))
    for _, ds in ipairs(datasets) do
        local name, data = ds[1], ds[2]
        local inFile = tmpFile("." .. name)
        writeFile(inFile, data)
        for _, p in ipairs(params) do
            local q, w = p[1], p[2]
            local outFile = tmpFile(format(".%s.q%d.w%d.br", name, q, w))
            assert(run(format("brotli -f -q %d -w %d -o %s %s", q, w, outFile, inFile)))
            local cli = readFile(outFile)
            -- the CLI uses the streaming encoder with the file size as size hint (and reads
            -- files of this size in one piece); compress() differs from it only by the
            -- fallback of BrotliEncoderCompress() to uncompressed data
            local own = brotli.compress(data, { quality = q, lgwin = w })
            local str = brotli.compressor({ quality = q, lgwin = w, sizehint = #data }):finish(data)
            assert(cli == str, format("CLI %s q=%d w=%d: %d <> %d bytes", name, q, w, #cli, #str))
            if own ~= str then
                assert(#data == 0 or #own < #str, format("CLI %s q=%d w=%d", name, q, w))
                fallbacks = fallbacks + 1
            end
            assert(brotli.decompress(cli) == data)
            compared = compared + 1
            if q == 5 then
                -- the CLI decompresses the output of compress.brotli
                local brFile, decFile = tmpFile(".own.br"), tmpFile(".own.dec")
                writeFile(brFile, own)
                assert(run(format("brotli -f -d -o %s %s", decFile, brFile)))
                assert(readFile(decFile) == data)
            end
        end
    end
    PRINT(format("brotli CLI: %d compressed outputs compared (%d differ from compress(): empty input or uncompressed fallback)",
                 compared, fallbacks))
end
PRINT("==================================================================================")
if not run(PERL .. " -MIO::Compress::Brotli -e 1 > " .. tmpFile(".pv") .. " 2>&1") then
    print("Perl module IO::Compress::Brotli not available: test part skipped")
else
    compared = 0
    -- one Perl process writes all outputs: bro() for each parameter pair and the
    -- streaming interface (create, quality, window, compress, finish)
    local perlFile = tmpFile(".pl")
    writeFile(perlFile, [[
use strict; use warnings;
use IO::Compress::Brotli; use IO::Uncompress::Brotli;
my ($in, $out, @params) = @ARGV;
open(my $fh, '<:raw', $in) or die; local $/; my $data = <$fh>; close $fh;
sub put { my ($name, $d) = @_; open(my $o, '>:raw', "$out.$name") or die; print $o $d; close $o; }
for my $p (@params) {
    my ($q, $w) = split /,/, $p;
    put("bro.$q.$w", bro($data, $q, $w));
    # (no $b->mode(): it fails in IO::Compress::Brotli 0.022 for every mode)
    my $b = IO::Compress::Brotli->create;
    $b->quality($q); $b->window($w);
    my $r = '';
    for (my $i = 0; $i < length($data); $i += 10000) { $r .= $b->compress(substr($data, $i, 10000)); }
    $r .= $b->finish();
    put("stream.$q.$w", $r);
}
# Perl decompresses compress.brotli's output (written by the Lua side as "$in.lb")
if (-e "$in.lb") {
    open(my $l, '<:raw', "$in.lb") or die; my $c = <$l>; close $l;
    put("unbro", unbro($c));
    put("unbro_given", unbro($c, length($data) || 1));
}
]])
    for _, ds in ipairs(datasets) do
        local name, data = ds[1], ds[2]
        local inFile = tmpFile("." .. name)
        local outBase = tmpFile("." .. name .. ".perl")
        writeFile(inFile, data)
        local own5 = brotli.compress(data, { quality = 5 })
        writeFile(tmpFile("." .. name .. ".lb"), own5)
        local plist = {}
        for _, p in ipairs(params) do plist[#plist + 1] = p[1] .. "," .. p[2] end
        assert(run(format("%s %s %s %s %s", PERL, perlFile, inFile, outBase, table.concat(plist, " "))))
        for _, p in ipairs(params) do
            local q, w = p[1], p[2]
            local perl = readTmp(format("%s.bro.%d.%d", outBase, q, w))
            local own = brotli.compress(data, { quality = q, lgwin = w })
            assert(perl == own, format("Perl bro %s q=%d w=%d: %d <> %d bytes", name, q, w, #perl, #own))
            assert(brotli.decompress(perl) == data)
            compared = compared + 1
            local pstream = readTmp(format("%s.stream.%d.%d", outBase, q, w))
            local c = brotli.compressor({ quality = q, lgwin = w })
            local parts = {}
            for i = 1, #data, 10000 do parts[#parts + 1] = c:update(data:sub(i, i + 9999)) end
            parts[#parts + 1] = c:finish()
            local ostream = table.concat(parts)
            assert(pstream == ostream, format("Perl stream %s q=%d w=%d: %d <> %d bytes",
                                              name, q, w, #pstream, #ostream))
            assert(brotli.decompress(pstream) == data)
            compared = compared + 1
        end
        assert(readTmp(outBase .. ".unbro") == data)
        assert(readTmp(outBase .. ".unbro_given") == data)
    end
    PRINT(format("Perl IO::Compress::Brotli: %d compressed outputs compared", compared))
end
PRINT("==================================================================================")
cleanup()
print("OK.")
