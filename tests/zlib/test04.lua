-- Compares compress.zlib with other zlib users on this machine, for the same parameters:
-- Perl's Compress::Zlib, Compress::Raw::Zlib and IO::Compress / IO::Uncompress (helper
-- script test04.pl), Python's zlib module, and the command line tools gzip and zlib-flate.
-- Each part is skipped if the tool is not installed (the command line tools on Windows).
--
-- Perl and Python use zlib too: with the same zlib version and the same parameters the
-- compressed bytes are expected to be identical, not only the decompressed data. Perl's
-- defaults differ from zlib's in memLevel: Compress::Zlib and Compress::Raw::Zlib use
-- MAX_MEM_LEVEL (9), zlib (and compress.zlib) 8; the tests give memLevel explicitly.
-- GNU gzip has its own deflate implementation: only the decompressed data is compared.

local zlib = require("compress.zlib")

local format = string.format

-- the Perl to compare with (COMPRESS_TEST_PERL, default "perl" from PATH; a
-- path without spaces). Its Compress::Raw::Zlib must be built for the same
-- platform as the zlib under test: e.g. on Windows a native Perl such as
-- Strawberry, not the Cygwin/MSYS Perl of Git for Windows, whose zlib writes
-- another OS byte into gzip headers.
local PERL = os.getenv("COMPRESS_TEST_PERL") or "perl"

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end

-- os.execute returns a number in Lua 5.1/LuaJIT and true/nil in Lua 5.2+
local function run(cmd)
    local r = os.execute(cmd)
    return r == true or r == 0
end

local function capture(cmd)
    local f = io.popen(cmd)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
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
    local words = { "lorem", "ipsum", "dolor", "sit", "amet", "\0", "\n", "zlib", "Lua", "1234" }
    local rnd = newRandom(seed)
    local t, len = {}, 0
    while len < n do
        local w = words[rnd(#words) + 1]
        t[#t + 1] = w .. " "
        len = len + #w + 1
    end
    return table.concat(t):sub(1, n)
end

-- varied content with many different short matches (numbers, markup): deflate blocks
-- with many symbols, where memLevel (the size of the symbol buffer) and Z_FILTERED matter
local function varied(n, seed)
    local rnd = newRandom(seed)
    local t, len = {}, 0
    while len < n do
        local s = format("<item id=\"%d\" value=\"%d.%02d\">%s</item>\n", rnd(100000), rnd(1000),
                         rnd(100), text(rnd(40) + 1, rnd(1000) + 1))
        t[#t + 1] = s
        len = len + #s
    end
    return table.concat(t):sub(1, n)
end

local datasets = {
    { "empty",  "" },
    { "nul",    ("\0"):rep(1000) },
    { "text",   text(300000, 3) },
    { "random", randomBytes(60000, 5) },
    { "mixed",  text(100000, 7) .. randomBytes(30000, 9) .. text(100000, 11) },
    { "varied", varied(200000, 13) },
}
local DICT = varied(5000, 99)

local function wbitsFor(fmt, w)
    if fmt == "raw" then return -w end
    if fmt == "gzip" then return w + 16 end
    return w
end

-- the parameter sets: { format, level, windowBits, memLevel, strategy }
local params = {}
for _, f in ipairs({ "zlib", "gzip", "raw" }) do
    for _, level in ipairs({ -1, 0, 1, 2, 5, 9 }) do
        for _, memLevel in ipairs({ 1, 8, 9 }) do
            params[#params + 1] = { f, level, 15, memLevel, 0 }
        end
    end
    for strategy = 0, 4 do
        params[#params + 1] = { f, 6, 15, 9, strategy }
        params[#params + 1] = { f, 9, 15, 8, strategy }
    end
    for _, w in ipairs({ 9, 10, 12, 14 }) do
        params[#params + 1] = { f, 6, w, 9, 0 }
        params[#params + 1] = { f, 1, w, 1, 0 }
    end
end

local function optsOf(p, extra)
    local o = { format = p[1], level = p[2], windowBits = (p[1] == "raw") and -p[3] or p[3],
                memLevel = p[4], strategy = p[5] }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- streaming in pieces, optionally with a flush after each piece
local function streamCompress(data, chunk, opts, flush)
    local c = zlib.compressor(opts)
    local out = {}
    if chunk == 0 then chunk = math.max(#data, 1) end
    for i = 1, #data, chunk do
        out[#out + 1] = c:update(data:sub(i, i + chunk - 1))
        if flush ~= "none" then
            out[#out + 1] = c:flush(nil, flush)
        end
    end
    out[#out + 1] = c:finish()
    return table.concat(out)
end

-- os.tmpname() gives a name in the root directory on Windows, use the current one there
local isWindows = package.config:sub(1, 1) == "\\"
local tmpDir
if isWindows then
    tmpDir = "compress_zlib_test04.tmp"
else
    tmpDir = os.tmpname()
    os.remove(tmpDir)
end
assert(run(format('mkdir "%s"', tmpDir)), "cannot create temporary directory")
local files = {}
local function tmpFile(name)
    files[#files + 1] = name
    return tmpDir .. "/" .. name
end
local function cleanup()
    for _, name in ipairs(files) do os.remove(tmpDir .. "/" .. name) end
    if isWindows then
        run(format('rmdir "%s"', tmpDir))
    else
        os.remove(tmpDir)
    end
end

for i, d in ipairs(datasets) do
    writeFile(tmpFile("in" .. i), d[2])
end
writeFile(tmpFile("dict"), DICT)

local zlibVersion = zlib.version()

-- the tests, run with pcall: the temporary files are removed also after a failure
local function main()

PRINT("==================================================================================")
-- Perl
local perlVersion = capture(PERL .. ' -MCompress::Raw::Zlib -e "print Compress::Raw::Zlib::zlib_version()" 2>'
                            .. (isWindows and "NUL" or "/dev/null"))
if not perlVersion or perlVersion == "" then
    print("perl with Compress::Raw::Zlib not available: test part skipped")
else
    -- the same zlib version: byte identical output expected
    local identical = (perlVersion == zlibVersion)
    -- (COMPRESS_TEST_REQUIRE_IDENTICAL=1, as in CI: a version mismatch would
    --  silently weaken the test to comparing the data only)
    if not identical and os.getenv("COMPRESS_TEST_REQUIRE_IDENTICAL") == "1" then
        error(format("Perl's Compress::Raw::Zlib uses zlib %s, compress.zlib %s: byte identity "
                     .. "cannot be checked", perlVersion, zlibVersion))
    end
    PRINT(format("Perl Compress::Raw::Zlib with zlib %s, compress.zlib with zlib %s%s", perlVersion,
                 zlibVersion, identical and "" or ": different versions, only the data is compared"))
    -- the jobs run in batches (one Perl process each), whose files are removed afterwards
    local jobs = {}       -- lines of the job file
    local checks = {}     -- { id, function(perlResult) }
    local batchFiles = {}
    local nextId = 0
    local nJobs = 0
    local function job(line, check)
        nextId = nextId + 1
        local id = "j" .. nextId
        jobs[#jobs + 1] = (line:gsub("%$ID", id))
        checks[#checks + 1] = { id, check }
        batchFiles[#batchFiles + 1] = id .. ".perl"
    end
    -- a file for the next job, removed with its batch
    local function jobFile(prefix, data)
        local name = format("%s%d", prefix, nextId + 1)
        batchFiles[#batchFiles + 1] = name
        writeFile(tmpDir .. "/" .. name, data)
        return name
    end
    local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
    local function runBatch()
        batchFiles[#batchFiles + 1] = "jobs"
        writeFile(tmpDir .. "/jobs", table.concat(jobs, "\n") .. "\n")
        local ok = run(format('%s "%stest04.pl" "%s" jobs', PERL, here, tmpDir))
        local results = {}
        for _, c in ipairs(checks) do
            results[#results + 1] = ok and readFile(tmpDir .. "/" .. c[1] .. ".perl")
        end
        for _, name in ipairs(batchFiles) do os.remove(tmpDir .. "/" .. name) end
        assert(ok, "perl failed")
        for k, c in ipairs(checks) do
            c[2](results[k])
        end
        nJobs = nJobs + #checks
        jobs, checks, batchFiles = {}, {}, {}
    end
    -- the result of Perl's inflate jobs: statuses, rest of the input, length and crc32
    local function inflateResult(perls)
        local st, rest, len, crc = perls:match("^(%S+) (%d+) (%d+) (%d+)$")
        assert(st, perls)
        return st, tonumber(rest), tonumber(len), tonumber(crc)
    end
    local counts = { bytes = 0, data = 0, status = 0 }
    local function firstDiff(a, b)
        local i = 1
        while i <= #a and i <= #b and a:byte(i) == b:byte(i) do i = i + 1 end
        return format("first difference at offset %d (ours %s, Perl %s; lengths %d/%d)", i - 1,
                      a:byte(i) or "end", b:byte(i) or "end", #a, #b)
    end
    local function sameBytes(ours, perls, what)
        if identical then
            if ours ~= perls then
                error(what .. ": output differs from Perl's, " .. firstDiff(ours, perls))
            end
            counts.bytes = counts.bytes + 1
        end
    end

    -- the header fields for the IO::Compress::Gzip comparison (merged into os 3, mtime 0);
    -- ExtraField: Perl checks the subfield structure (ID, length, data)
    local gzipHeaders = {
        { "name",       { name = "file.txt" } },
        { "empty name", { name = "" } },
        { "latin1 name", { name = "dir/n\228me.txt" } },
        { "comment",    { comment = "a comment\nwith two lines" } },
        { "extra",      { extra = "AB\2\0hiCD\0\0" } },
        { "text",       { text = true } },
        { "hcrc",       { hcrc = true } },
        { "time os",    { mtime = 1700000000, os = 255 } },
        { "os 0",       { os = 0 } },
        { "all",        { name = "all.txt", comment = "all fields", extra = "XY\3\0abc",
                          text = true, hcrc = true, mtime = 4294967295, os = 11 } },
    }
    for i, d in ipairs(datasets) do
        local s = d[2]
        for _, p in ipairs(params) do
            local opts = optsOf(p)
            local ours = zlib.compress(s, opts)
            local what = format("%s %s level %d windowBits %d memLevel %d strategy %d",
                                d[1], p[1], p[2], p[3], p[4], p[5])
            local wb = wbitsFor(p[1], p[3])
            -- Compress::Raw::Zlib::Deflate, all at once
            job(format("deflate\t$ID\tin%d\t%d\t8\t%d\t%d\t%d\t-\t0\tnone", i, p[2], wb, p[4], p[5]),
                function(perls)
                    -- level 0: the sizes of the stored blocks depend on how deflate() is
                    -- called and on the output buffer sizes (Perl: its scalar's buffer)
                    if p[2] ~= 0 then
                        sameBytes(ours, perls, what)
                    end
                    assert(zlib.decompress(perls, { format = p[1] }) == s, what)
                    counts.data = counts.data + 1
                end)
            -- Perl inflates our output
            local name = jobFile("ours", ours)
            job(format("inflate\t$ID\t%s\t%d\t-\t0", name, wbitsFor(p[1], 15)),
                function(perls)
                    local st, rest, len, crc = inflateResult(perls)
                    assert(st == "1" and rest == 0 and len == #s and crc == zlib.crc32(s),
                           what .. ": Perl's inflate")
                    counts.data = counts.data + 1
                end)
        end
        -- streaming in pieces, with and without flushes, compared with Perl fed the same way
        for _, p in ipairs({ { "zlib", 6, 15, 9, 0 }, { "raw", 9, 15, 9, 0 }, { "gzip", 1, 15, 8, 0 },
                             { "zlib", 0, 15, 9, 0 }, { "raw", 6, 12, 9, 1 } }) do
            for _, chunk in ipairs({ 1000, 65536 }) do
                for _, flush in ipairs({ "none", "sync", "full" }) do
                    local ours = streamCompress(s, chunk, optsOf(p), flush)
                    local what = format("%s %s level %d, chunks of %d, flush %s", d[1], p[1], p[2],
                                        chunk, flush)
                    job(format("deflate\t$ID\tin%d\t%d\t8\t%d\t%d\t%d\t-\t%d\t%s", i, p[2],
                               wbitsFor(p[1], p[3]), p[4], p[5], chunk, flush),
                        function(perls)
                            -- level 0: the stored blocks depend on the output buffer sizes
                            if p[2] ~= 0 then
                                sameBytes(ours, perls, what)
                            end
                            assert(zlib.decompress(perls, { format = p[1] }) == s, what)
                            assert(zlib.decompress(ours, { format = p[1] }) == s, what)
                            counts.data = counts.data + 1
                        end)
                end
            end
        end
        -- dictionaries
        for _, f in ipairs({ "zlib", "raw" }) do
            for _, memLevel in ipairs({ 8, 9 }) do
                local opts = { format = f, memLevel = memLevel, dictionary = DICT }
                local ours = zlib.compress(s, opts)
                local what = format("%s %s dictionary memLevel %d", d[1], f, memLevel)
                job(format("deflate\t$ID\tin%d\t-1\t8\t%d\t%d\t0\tdict\t0\tnone", i, wbitsFor(f, 15),
                           memLevel),
                    function(perls)
                        sameBytes(ours, perls, what)
                        assert(zlib.decompress(perls, { format = f, dictionary = DICT }) == s, what)
                        counts.data = counts.data + 1
                    end)
                local name = jobFile("ours", ours)
                job(format("inflate\t$ID\t%s\t%d\tdict\t0", name, wbitsFor(f, 15)),
                    function(perls)
                        local st, rest, len, crc = inflateResult(perls)
                        assert(st == "1" and rest == 0 and len == #s and crc == zlib.crc32(s),
                               what .. ": Perl's inflate")
                        counts.data = counts.data + 1
                    end)
            end
        end
        -- Compress::Zlib::compress and IO::Compress use memLevel 9
        for _, level in ipairs({ -1, 1, 9 }) do
            local ours = zlib.compress(s, { level = level, memLevel = zlib.MAX_MEM_LEVEL })
            job(format("compress\t$ID\tin%d\t%d", i, level), function(perls)
                sameBytes(ours, perls, d[1] .. " Compress::Zlib::compress level " .. level)
            end)
            for _, strategy in ipairs({ 0, 1 }) do
                local w = format("%s IO::Compress level %d strategy %d", d[1], level, strategy)
                local o = { level = level, memLevel = 9, strategy = strategy }
                local oz = zlib.compress(s, o)
                o.format = "raw"
                local oraw = zlib.compress(s, o)
                o.format = "gzip"
                o.gzipHeader = { os = 3, mtime = 0 }
                local ogz = zlib.compress(s, o)
                job(format("iodeflate\t$ID\tin%d\t%d\t%d", i, level, strategy), function(perls)
                    sameBytes(oz, perls, w)
                end)
                job(format("iorawdeflate\t$ID\tin%d\t%d\t%d", i, level, strategy), function(perls)
                    sameBytes(oraw, perls, w)
                end)
                -- IO::Compress::Gzip writes its own header. Both sides get the same header
                -- fields explicitly: the OS byte would differ otherwise, Perl's default is
                -- Compress::Raw::Zlib's own table (3 for Unix, also on macOS), zlib's the
                -- OS_CODE of its build (19 on macOS, 10 on Windows). XFL: Perl sets it only
                -- for levels 1 and 9, zlib also for level 0 and for the strategies
                -- Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED -- not used here, so the bytes are the same
                job(format("iogzip\t$ID\tin%d\t%d\t%d\t3\t0\t-\t-\t-\t0\t0", i, level, strategy),
                    function(perls)
                        sameBytes(ogz, perls, w .. " gzip")
                        assert(zlib.decompress(perls, { format = "gzip" }) == s)
                    end)
            end
        end
        -- the gzip header fields: IO::Compress::Gzip with Name, Comment, ExtraField, TextFlag,
        -- HeaderCRC, Time and OS_Code, ours with gzipHeader; IO::Uncompress::Gunzip reads
        -- the fields of our header
        for _, hv in ipairs(gzipHeaders) do
            for _, level in ipairs({ -1, 9 }) do
                local hdr = { os = 3, mtime = 0 }
                for k, v in pairs(hv[2]) do hdr[k] = v end
                local ours = zlib.compress(s, { format = "gzip", level = level, memLevel = 9,
                                                gzipHeader = hdr })
                local w = format("%s IO::Compress::Gzip level %d, header %s", d[1], level, hv[1])
                local function file(prefix, v) return v and jobFile(prefix, v) or "-" end
                local nameFile, commentFile = file("hname", hdr.name), file("hcomment", hdr.comment)
                local extraFile = file("hextra", hdr.extra)
                job(format("iogzip\t$ID\tin%d\t%d\t0\t%d\t%.0f\t%s\t%s\t%s\t%d\t%d", i, level, hdr.os,
                           hdr.mtime, nameFile, commentFile, extraFile, hdr.text and 1 or 0,
                           hdr.hcrc and 1 or 0),
                    function(perls)
                        local p = perls
                        if hdr.hcrc then
                            -- IO::Compress::Gzip writes only the low byte of the header CRC
                            -- (crc32 & 0xFF, its high byte 0; RFC 1952: the two low bytes of
                            -- the CRC-32), which zlib's inflate rejects
                            local pos = 11 + (hdr.extra and 2 + #hdr.extra or 0)
                                        + (hdr.name and #hdr.name + 1 or 0)
                                        + (hdr.comment and #hdr.comment + 1 or 0)
                            local crc = zlib.crc32(perls:sub(1, pos - 1))
                            assert(perls:byte(pos) == crc % 256, w .. ": Perl's header CRC")
                            if perls:byte(pos + 1) ~= math.floor(crc / 256) % 256 then
                                assert(perls:byte(pos + 1) == 0, w .. ": Perl's header CRC")
                                local ok, err = pcall(zlib.decompress, perls, { format = "gzip" })
                                assert(not ok and err:find("header crc mismatch", 1, true), w)
                                p = perls:sub(1, pos) .. string.char(math.floor(crc / 256) % 256)
                                    .. perls:sub(pos + 2)
                            end
                        end
                        sameBytes(ours, p, w)
                        assert(zlib.decompress(p, { format = "gzip" }) == s, w)
                        counts.data = counts.data + 1
                    end)
                local name = jobFile("ours", ours)
                job(format("gunziphdr\t$ID\t%s", name), function(perls)
                    local function hexOf(v)
                        return v and (v:gsub(".", function(c) return format("%02x", c:byte()) end)) or "-"
                    end
                    local expect = format("ok %d %.0f %d %.0f %d %d %s %s %s", #s, zlib.crc32(s), hdr.os,
                                          hdr.mtime, hdr.text and 1 or 0, hdr.hcrc and 1 or 0,
                                          hexOf(hdr.name), hexOf(hdr.comment), hexOf(hdr.extra))
                    assert(perls == expect, format("%s: Perl's Gunzip: %s, expected %s", w, perls, expect))
                    counts.data = counts.data + 1
                end)
            end
        end
        -- Perl's IO::Uncompress and Compress::Zlib::uncompress read our output
        local list = {
            { "gunzip",     zlib.compress(s, { format = "gzip" }) },
            { "inflateio",  zlib.compress(s) },
            { "rawinflate", zlib.compress(s, { format = "raw" }) },
            { "uncompress", zlib.compress(s, { level = 9 }) },
        }
        for _, l in ipairs(list) do
            local name = jobFile("ours", l[2])
            job(format("%s\t$ID\t%s", l[1], name), function(perls)
                assert(perls == format("ok %d %.0f", #s, zlib.crc32(s)), d[1] .. " " .. l[1])
                counts.data = counts.data + 1
            end)
        end
        runBatch()
    end

    -- statuses: the status method inflate() gives the same statuses as Perl's inflate,
    -- and consumes the same input (trailing data)
    local s = datasets[3][2]
    local cases = {}
    for _, f in ipairs({ "zlib", "gzip", "raw" }) do
        local c = zlib.compress(s, { format = f })
        local cases1 = {
            { "complete",  c },
            { "trailing",  c .. "TRAILING DATA" },
            { "truncated", c:sub(1, math.floor(#c / 2)) },
            { "corrupt",   c:sub(1, 2) .. "\255\255\255" .. c:sub(6) },
            { "garbage",   "garbage data" },
            { "empty",     "" },
        }
        for _, cs in ipairs(cases1) do
            for _, chunk in ipairs({ 0, 1, 777 }) do
                cases[#cases + 1] = { f, cs[1], cs[2], chunk }
            end
        end
    end
    local dc = zlib.compress(s, { dictionary = DICT })
    cases[#cases + 1] = { "zlib", "needdict", dc, 0 }
    cases[#cases + 1] = { "zlib", "dict", dc, 100, DICT }
    cases[#cases + 1] = { "zlib", "wrongdict", dc, 0, "wrong" }
    for _, cs in ipairs(cases) do
        local f, name, data, chunk, dict = cs[1], cs[2], cs[3], cs[4], cs[5]
        local file = jobFile("case", data)
        local dictFile = dict and jobFile("dict", dict) or "-"

        -- ours, fed the same way: stop after the first status other than Z_OK
        local d = zlib.decompressor({ format = f, dictionary = dict })
        local statuses, outs, rest = {}, {}, 0
        local step = (chunk > 0) and chunk or math.max(#data, 1)
        local pieces = {}
        for i = 1, #data, step do pieces[#pieces + 1] = data:sub(i, i + step - 1) end
        if #pieces == 0 then pieces[1] = "" end
        for _, piece in ipairs(pieces) do
            local out, st, n = d:inflate(piece)
            statuses[#statuses + 1] = tostring(st)
            outs[#outs + 1] = out
            rest = #piece - n
            if st ~= zlib.Z_OK then break end
        end
        local mine = table.concat(statuses, ",") .. " " .. rest
        local what = format("%s %s, chunks of %d", f, name, chunk)
        job(format("inflate\t$ID\t%s\t%d\t%s\t%d", file, wbitsFor(f, 15), dictFile, chunk),
            function(perls)
                local pst, prest, plen, pcrc = inflateResult(perls)
                if name == "needdict" then
                    -- Perl does not consume the input for Z_NEED_DICT (it updates its input
                    -- buffer only for Z_OK, Z_STREAM_END, Z_BUF_ERROR and Z_DATA_ERROR),
                    -- consumed includes the 6 bytes of the header here
                    prest = prest - 6
                end
                assert(pst .. " " .. prest == mine, format("%s: %s, Perl: %s %d", what, mine, pst, prest))
                -- the same output (on errors Perl's may end elsewhere: its buffer sizes)
                if pst:match("^[0,]*1$") or pst:match("^[0,]*0$") then
                    local out = table.concat(outs)
                    assert(plen == #out and pcrc == zlib.crc32(out), what)
                end
                counts.status = counts.status + 1
            end)
    end

    runBatch()
    PRINT(format("Perl: %d jobs, %d outputs byte identical, %d decompressions, %d status sequences",
                 nJobs, counts.bytes, counts.data, counts.status))
    assert(not identical or counts.bytes > 800)
end
PRINT("==================================================================================")
-- Python's zlib module
local pyVersion = capture('python3 -c "import zlib; print(zlib.ZLIB_RUNTIME_VERSION)" 2>'
                          .. (isWindows and "NUL" or "/dev/null"))
pyVersion = pyVersion and pyVersion:match("^%s*(.-)%s*$")
if not pyVersion or pyVersion == "" then
    print("python3 not available: test part skipped")
else
    local identical = (pyVersion == zlibVersion)
    PRINT(format("Python zlib with zlib %s%s", pyVersion,
                 identical and "" or ": different version, only the data is compared"))
    local script = {
        "import sys, zlib",
        "d = sys.argv[1]",
        "for line in open(d + '/pyjobs'):",
        "    f = line.split()",
        "    if not f: continue",
        "    data = open(d + '/' + f[1], 'rb').read()",
        "    args = [int(f[2]), zlib.DEFLATED, int(f[3]), int(f[4]), int(f[5])]",
        "    if f[6] != '-': args.append(open(d + '/' + f[6], 'rb').read())",
        "    c = zlib.compressobj(*args)",
        "    out = c.compress(data) + c.flush()",
        "    open(d + '/' + f[0] + '.py', 'wb').write(out)",
        "    back = zlib.decompressobj(int(f[3]), *args[5:]).decompress(open(d + '/' + f[0] + '.ours', 'rb').read())",
        "    open(d + '/' + f[0] + '.back', 'w').write('%d %d' % (len(back), zlib.crc32(back)))",
    }
    writeFile(tmpFile("pyjobs.py"), table.concat(script, "\n") .. "\n")
    local n, total = 0, 0
    for i, d in ipairs(datasets) do
        -- one Python process per dataset, its files are removed afterwards
        local jobs, expect, batch = {}, {}, { "pyjobs" }
        for _, p in ipairs(params) do
            for _, dict in ipairs({ false, true }) do
                if not (dict and p[1] == "gzip") then
                    local id = "p" .. #jobs + 1
                    local opts = optsOf(p, { dictionary = dict and DICT or nil })
                    local ours = zlib.compress(d[2], opts)
                    writeFile(tmpDir .. "/" .. id .. ".ours", ours)
                    batch[#batch + 1] = id .. ".ours"
                    batch[#batch + 1] = id .. ".py"
                    batch[#batch + 1] = id .. ".back"
                    jobs[#jobs + 1] = format("%s in%d %d %d %d %d %s", id, i, p[2], wbitsFor(p[1], p[3]),
                                             p[4], p[5], dict and "dict" or "-")
                    expect[#expect + 1] = { id, ours, d[2], opts }
                end
            end
        end
        writeFile(tmpDir .. "/pyjobs", table.concat(jobs, "\n") .. "\n")
        local ok = run(format('python3 "%s/pyjobs.py" "%s"', tmpDir, tmpDir))
        local results = {}
        for k, e in ipairs(expect) do
            results[k] = ok and { readFile(tmpDir .. "/" .. e[1] .. ".py"),
                                  readFile(tmpDir .. "/" .. e[1] .. ".back") }
        end
        for _, name in ipairs(batch) do os.remove(tmpDir .. "/" .. name) end
        assert(ok, "python3 failed")
        for k, e in ipairs(expect) do
            local py, back = results[k][1], results[k][2]
            -- level 0: Python calls deflate() twice (compress, flush), the stored blocks differ
            if identical and e[4].level ~= 0 then
                assert(py == e[2], d[1] .. " " .. jobs[k] .. ": output differs from Python's")
                n = n + 1
            end
            assert(zlib.decompress(py, { format = e[4].format, dictionary = e[4].dictionary }) == e[3])
            assert(back == format("%d %.0f", #e[3], zlib.crc32(e[3])))
        end
        total = total + #expect
    end
    PRINT(format("Python: %d outputs, %d byte identical", total, n))
end
PRINT("==================================================================================")
-- gzip command line tool (its own deflate implementation: only the data is compared)
local devnull = isWindows and "NUL" or "/dev/null"
if isWindows then
    print("command line tools are not used on Windows: test part skipped")
elseif not run("gzip --version >" .. devnull .. " 2>&1") then
    print("gzip not available: test part skipped")
else
    local n = 0
    for i, d in ipairs(datasets) do
        local s = d[2]
        local inName = tmpDir .. "/in" .. i
        -- gzip decompresses our output
        for _, level in ipairs({ 0, 1, 6, 9 }) do
            local gz = tmpFile(format("ours%d_%d.gz", i, level))
            writeFile(gz, zlib.compress(s, { format = "gzip", level = level }))
            local back = tmpFile(format("back%d_%d", i, level))
            assert(run(format('gzip -dc "%s" > "%s"', gz, back)))
            assert(readFile(back) == s, d[1])
            n = n + 1
        end
        -- we decompress gzip's output: without and with file name and time in the header
        for _, level in ipairs({ 1, 9 }) do
            local gz = tmpFile(format("gzip%d_%d.gz", i, level))
            assert(run(format('gzip -c -n -%d "%s" > "%s"', level, inName, gz)))
            local data = readFile(gz)
            assert(zlib.decompress(data, { format = "gzip" }) == s, d[1])
            assert(zlib.decompress(data, { format = "auto" }) == s, d[1])
            n = n + 1
        end
        local gz = tmpFile(format("gzipN%d.gz", i))
        assert(run(format('gzip -c -N "%s" > "%s"', inName, gz)))
        local data = readFile(gz)
        assert(data:byte(4) % 16 >= 8)        -- FNAME
        local d2 = zlib.decompressor({ format = "gzip" })
        local out, st, used = d2:inflate(data .. data)
        assert(out == s and st == zlib.Z_STREAM_END and used == #data)
        -- concatenated members: gzip -d decompresses all, compress.zlib the first one
        local both = tmpFile(format("both%d.gz", i))
        writeFile(both, data .. data)
        local back = tmpFile(format("both%d", i))
        assert(run(format('gzip -dc "%s" > "%s"', both, back)))
        assert(readFile(back) == s .. s)
        assert(zlib.decompress(data .. data, { format = "gzip", allowtrailing = true }) == s)
        n = n + 1
    end
    PRINT(format("gzip: %d comparisons", n))
end
PRINT("==================================================================================")
-- zlib-flate (from qpdf; uses zlib with deflateInit() and its defaults)
if isWindows then
    print("command line tools are not used on Windows: test part skipped")
elseif not run("zlib-flate -compress < " .. devnull .. " > " .. devnull .. " 2>&1") then
    print("zlib-flate not available: test part skipped")
else
    local n, same = 0, 0
    for i, d in ipairs(datasets) do
        local s = d[2]
        local inName = tmpDir .. "/in" .. i
        local zf = tmpFile(format("zf%d.z", i))
        assert(run(format('zlib-flate -compress < "%s" > "%s"', inName, zf)))
        local data = readFile(zf)
        -- zlib-flate writes nothing at all for empty input
        if s ~= "" then
            assert(zlib.decompress(data) == s)
            if data == zlib.compress(s) then same = same + 1 end
        end
        local ours = tmpFile(format("ours%d.z", i))
        writeFile(ours, zlib.compress(s, { level = 9, memLevel = 9 }))
        local back = tmpFile(format("zfback%d", i))
        assert(run(format('zlib-flate -uncompress < "%s" > "%s"', ours, back)))
        assert(readFile(back) == s)
        n = n + 1
    end
    -- qpdf may be built with zopfli or another default level: identity is only reported
    PRINT(format("zlib-flate: %d datasets, %d compressed byte identical with the defaults", n, same))
end
PRINT("==================================================================================")
end

local ok, err = xpcall(main, debug.traceback)
cleanup()
if not ok then
    error(err, 0)
end
print("OK.")
