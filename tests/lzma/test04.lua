-- Compares compress.lzma with other liblzma users and LZMA implementations on this machine:
-- Perl's Compress::Raw::Lzma and IO::Compress::Xz / IO::Uncompress::UnXz (helper script
-- test04.pl), the command line tool xz (formats xz, lzma, raw), and 7-Zip (7z, 7za or 7zr):
-- archives with an encoded (LZMA compressed) header, decoded with raw LZMA1 and the coder
-- properties as an archive reader does it, and 7-Zip's own decoder for our .xz/.lzma files.
-- Each part is skipped if the tool is not installed (the command line tools on Windows).
--
-- Perl and xz use liblzma too: with the same liblzma version and the same parameters the
-- compressed bytes are expected to be identical, not only the decompressed data. Perl's
-- defaults differ in the check: Compress::Raw::Lzma's EasyEncoder and IO::Compress::Xz use
-- CRC32, xz (and compress.lzma) CRC64; the tests give the check explicitly. 7-Zip has its
-- own LZMA implementation: only the data is compared.

local lzma = require("compress.lzma")

local format = string.format

-- the Perl to compare with (COMPRESS_TEST_PERL, default "perl" from PATH; a path without
-- spaces); Compress::Raw::Lzma may come from PERL5LIB (e.g. a local::lib)
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
    local words = { "lorem", "ipsum", "dolor", "sit", "amet", "\0", "\n", "lzma", "Lua", "1234" }
    local rnd = newRandom(seed)
    local t, len = {}, 0
    while len < n do
        local w = words[rnd(#words) + 1]
        t[#t + 1] = w .. " "
        len = len + #w + 1
    end
    return table.concat(t):sub(1, n)
end

-- varied content with many different short matches (numbers, markup)
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
    { "text",   text(200000, 3) },
    { "random", randomBytes(30000, 5) },
    { "mixed",  text(50000, 7) .. randomBytes(20000, 9) .. text(50000, 11) },
    { "varied", varied(150000, 13) },
}

local function with(base, extra)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- the 7z reader of the tests, with the sample archive of 7-Zip 26.01
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local sz = dofile(here .. "sevenzip.lua")

-- os.tmpname() gives a name in the root directory on Windows, use the current one there
local isWindows = package.config:sub(1, 1) == "\\"
local devnull = isWindows and "NUL" or "/dev/null"
local tmpDir
if isWindows then
    tmpDir = "compress_lzma_test04.tmp"
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
local dirs = {}
local function cleanup()
    for _, name in ipairs(files) do os.remove(tmpDir .. "/" .. name) end
    for i = #dirs, 1, -1 do os.remove(dirs[i]) end
    if isWindows then
        run(format('rmdir "%s"', tmpDir))
    else
        os.remove(tmpDir)
    end
end

for i, d in ipairs(datasets) do
    writeFile(tmpFile("in" .. i), d[2])
end

local lzmaVersion = lzma.version()
local requireIdentical = os.getenv("COMPRESS_TEST_REQUIRE_IDENTICAL") == "1"

-- our options for a filter spec of test04.pl ("lzma1:Lc=0,..." or "lzma2p:3")
local PERL_NAMES = { DictSize = "dictSize", Lc = "lc", Lp = "lp", Pb = "pb", Mode = "mode",
                     Nice = "niceLen", Mf = "mf", Depth = "depth" }
local function optsOfFilter(spec)
    local o = {}
    local typ, args = spec:match("^([^:]+):?(.*)$")
    if typ == "lzma1p" or typ == "lzma2p" then
        o.preset = tonumber(args)
        typ = typ:sub(1, 5)
    else
        for k, v in args:gmatch("(%w+)=(%d+)") do
            o[assert(PERL_NAMES[k], k)] = tonumber(v)
        end
    end
    o.filter = typ
    return o
end

-- the tests, run with pcall: the temporary files are removed also after a failure
local function main()

PRINT("==================================================================================")
-- Perl
local perlVersion = capture(PERL .. ' -MCompress::Raw::Lzma -MIO::Compress::Xz -e '
                            .. '"print Compress::Raw::Lzma::lzma_version_string()" 2>' .. devnull)
if not perlVersion or perlVersion == "" then
    print("perl with Compress::Raw::Lzma and IO::Compress::Xz not available: test part skipped")
else
    local identical = (perlVersion == lzmaVersion)
    if not identical and requireIdentical then
        error(format("Perl's Compress::Raw::Lzma uses liblzma %s, compress.lzma %s: byte identity "
                     .. "cannot be checked", perlVersion, lzmaVersion))
    end
    PRINT(format("Perl Compress::Raw::Lzma with liblzma %s, compress.lzma with liblzma %s%s", perlVersion,
                 lzmaVersion, identical and "" or ": different versions, only the data is compared"))
    local jobs, checks, batchFiles = {}, {}, {}
    local nextId = 0
    local nJobs = 0
    local counts = { bytes = 0, data = 0, status = 0 }
    local function job(line, check)
        nextId = nextId + 1
        local id = "j" .. nextId
        jobs[#jobs + 1] = (line:gsub("%$ID", id))
        checks[#checks + 1] = { id, check }
        batchFiles[#batchFiles + 1] = id .. ".perl"
        batchFiles[#batchFiles + 1] = id .. ".out"
    end
    local function jobFile(prefix, data)
        local name = format("%s%d", prefix, nextId + 1)
        batchFiles[#batchFiles + 1] = name
        writeFile(tmpDir .. "/" .. name, data)
        return name
    end
    local function runBatch()
        batchFiles[#batchFiles + 1] = "jobs"
        writeFile(tmpDir .. "/jobs", table.concat(jobs, "\n") .. "\n")
        local ok = run(format('%s "%stest04.pl" "%s" jobs', PERL, here, tmpDir))
        local results = {}
        for k, c in ipairs(checks) do
            local outName = tmpDir .. "/" .. c[1] .. ".out"
            local f = io.open(outName, "rb")
            local out = f and f:read("*a")
            if f then f:close() end
            results[k] = ok and { readFile(tmpDir .. "/" .. c[1] .. ".perl"), out }
        end
        for _, name in ipairs(batchFiles) do os.remove(tmpDir .. "/" .. name) end
        assert(ok, "perl failed")
        for k, c in ipairs(checks) do
            c[2](results[k][1], results[k][2])
        end
        nJobs = nJobs + #checks
        jobs, checks, batchFiles = {}, {}, {}
    end
    local function firstDiff(a, b)
        local i = 1
        while i <= #a and i <= #b and a:byte(i) == b:byte(i) do i = i + 1 end
        return format("first difference at offset %d (lengths %d/%d)", i - 1, #a, #b)
    end
    local function sameBytes(ours, perls, what)
        if identical then
            if ours ~= perls then
                error(what .. ": output differs from Perl's, " .. firstDiff(ours, perls))
            end
            counts.bytes = counts.bytes + 1
        end
    end
    local CHECKS = { none = 0, crc32 = 1, crc64 = 4, sha256 = 10 }

    for i, d in ipairs(datasets) do
        local s = d[2]
        local inName = "in" .. i
        local function encoderJob(line, ours, dopts, what)
            job(line, function(perls)
                sameBytes(ours, perls, what)
                assert(lzma.decompress(perls, dopts) == s, what)
                counts.data = counts.data + 1
            end)
        end
        -- Compress::Raw::Lzma::EasyEncoder: preset, extreme, check
        for _, p in ipairs({ { 0, false, "crc32" }, { 1, false, "crc64" }, { 3, true, "none" },
                             { 6, false, "crc32" }, { 6, false, "sha256" }, { 1, true, "crc32" } }) do
            local ours = lzma.compress(s, { preset = p[1], extreme = p[2], check = p[3] })
            encoderJob(format("easy\t$ID\t%s\t%d\t%d\t%d", inName, p[1], p[2] and 1 or 0, CHECKS[p[3]]),
                       ours, {}, format("%s easy preset %d extreme %s check %s", d[1], p[1],
                                        tostring(p[2]), p[3]))
        end
        -- the filters: StreamEncoder (LZMA2), AloneEncoder (LZMA1), RawEncoder (both)
        local lzma2Filters = { "lzma2p:6", "lzma2p:1", "lzma2:DictSize=65536,Lc=1,Lp=1,Pb=1",
                               "lzma2:Mode=1,Nice=32,Mf=4", "lzma2:Mf=19,Depth=8" }
        local lzma1Filters = { "lzma1p:6", "lzma1p:2", "lzma1:DictSize=1048576,Lc=0,Pb=0",
                               "lzma1:Lc=4,Lp=0,Pb=4,Nice=128", "lzma1:Mode=1,Mf=3" }
        for _, f in ipairs(lzma2Filters) do
            local o = optsOfFilter(f)
            o.filter = nil
            local ours = lzma.compress(s, with(o, { check = "crc64" }))
            encoderJob(format("stream\t$ID\t%s\t%s\t4", inName, f), ours, {}, d[1] .. " stream " .. f)
            ours = lzma.compress(s, with(optsOfFilter(f), { format = "raw" }))
            encoderJob(format("rawenc\t$ID\t%s\t%s", inName, f), ours, { format = "raw" }, d[1] .. " raw " .. f)
        end
        for _, f in ipairs(lzma1Filters) do
            local o = optsOfFilter(f)
            o.filter = nil
            local ours = lzma.compress(s, with(o, { format = "lzma" }))
            encoderJob(format("alone\t$ID\t%s\t%s", inName, f), ours, { format = "lzma" }, d[1] .. " alone " .. f)
            local ro = with(optsOfFilter(f), { format = "raw" })
            ours = lzma.compress(s, ro)
            encoderJob(format("rawenc\t$ID\t%s\t%s", inName, f), ours,
                       { format = "raw", filter = "lzma1", lc = ro.lc, lp = ro.lp, pb = ro.pb },
                       d[1] .. " raw " .. f)
        end
        -- IO::Compress::Xz (EasyEncoder, CRC32) and IO::Compress::Lzma (AloneEncoder, preset 6)
        for _, p in ipairs({ 1, 6 }) do
            encoderJob(format("ioxz\t$ID\t%s\t%d", inName, p), lzma.compress(s, { preset = p, check = "crc32" }),
                       {}, d[1] .. " IO::Compress::Xz preset " .. p)
        end
        encoderJob(format("iolzma\t$ID\t%s", inName), lzma.compress(s, { format = "lzma" }),
                   { format = "lzma" }, d[1] .. " IO::Compress::Lzma")
        -- Perl decodes our output: the decoders and IO::Uncompress::UnXz/UnLzma
        local ours = {
            { "stream", "-", lzma.compress(s, { preset = 2 }) },
            { "auto",   "-", lzma.compress(s, { format = "lzma", preset = 2 }) },
            { "alone",  "-", lzma.compress(s, { format = "lzma", preset = 2 }) },
            { "raw",    "lzma2:DictSize=1048576", lzma.compress(s, { format = "raw", preset = 2 }) },
            { "raw",    "lzma1:Lc=1,Lp=1,Pb=1", lzma.compress(s, { format = "raw", filter = "lzma1", lc = 1, lp = 1, pb = 1 }) },
        }
        for _, o in ipairs(ours) do
            local name = jobFile("ours", o[3])
            job(format("decode\t$ID\t%s\t%s\t%s\t-\t0", name, o[1], o[2]), function(perls, out)
                assert(perls == "1 0" and out == s, d[1] .. " Perl's " .. o[1] .. " decoder: " .. perls)
                counts.data = counts.data + 1
            end)
        end
        for _, l in ipairs({ { "unxz", lzma.compress(s, { check = "sha256" }) },
                             { "unlzma", lzma.compress(s, { format = "lzma", preset = 0 }) } }) do
            local name = jobFile("ours", l[2])
            job(format("%s\t$ID\t%s", l[1], name), function(perls, out)
                assert(perls == "ok" and out == s, d[1] .. " " .. l[1])
                counts.data = counts.data + 1
            end)
        end
        runBatch()
    end

    -- statuses: the status method code() gives the same statuses as Perl's code(), consumes
    -- the same input and gives the same output
    local s = datasets[6][2]
    local cases = {}
    local fmts = {
        { "xz",   "stream", "-",     {},                                   lzma.compress(s, { preset = 1 }) },
        { "auto", "auto",   "-",     { format = "auto" },                  lzma.compress(s, { format = "lzma", preset = 1 }) },
        { "lzma", "alone",  "-",     { format = "lzma" },                  lzma.compress(s, { format = "lzma", preset = 1 }) },
        { "raw2", "raw",    "lzma2", { format = "raw" },                   lzma.compress(s, { format = "raw", preset = 1 }) },
        { "raw1", "raw",    "lzma1", { format = "raw", filter = "lzma1" }, lzma.compress(s, { format = "raw", filter = "lzma1", preset = 1 }) },
    }
    for _, f in ipairs(fmts) do
        local c = f[5]
        for _, cs in ipairs({ { "complete", c }, { "trailing", c .. "TRAILING DATA" },
                              { "truncated", c:sub(1, math.floor(#c / 2)) },
                              { "corrupt", c:sub(1, 20) .. ("\255"):rep(7) .. c:sub(28) },
                              { "garbage", ("garbage data"):rep(3) }, { "empty", "" } }) do
            for _, chunk in ipairs({ 0, 1, 777 }) do
                cases[#cases + 1] = { f, cs[1], cs[2], chunk }
            end
        end
    end
    -- the encoded header of a 7z archive (raw LZMA1 without end marker): with its
    -- properties, and with the defaults of Lzma::Filter::Lzma1() as ExifTool's 7Z.pm uses it
    local archive = sz.SAMPLE
    local hdr, enc, si, packed = sz.decodeHeader(archive, lzma)
    assert(enc and #hdr >= si.folders[1].unpackSize)
    local props = si.folders[1].coders[1].properties
    for _, chunk in ipairs({ 0, 1, 100 }) do
        cases[#cases + 1] = { { "7z", "raw", "lzma1", { format = "raw", filter = "lzma1", properties = props } },
                              "7z header", packed, chunk, props }
        cases[#cases + 1] = { { "7z", "raw", "lzma1", { format = "raw", filter = "lzma1" } },
                              "7z header, Lzma1()", packed, chunk }
    end
    local nStatus = 0
    for _, cs in ipairs(cases) do
        local f, name, data, chunk, p = cs[1], cs[2], cs[3], cs[4], cs[5]
        local file = jobFile("case", data)
        local propsFile = p and jobFile("props", p) or "-"
        local d = lzma.decompressor(f[4])
        local statuses, outs, rest = {}, {}, 0
        local step = (chunk > 0) and chunk or math.max(#data, 1)
        local pieces = {}
        for i = 1, #data, step do pieces[#pieces + 1] = data:sub(i, i + step - 1) end
        if #pieces == 0 then pieces[1] = "" end
        for _, piece in ipairs(pieces) do
            local out, st, n = d:code(piece)
            statuses[#statuses + 1] = tostring(st)
            outs[#outs + 1] = out
            rest = #piece - n
            if st ~= lzma.LZMA_OK then break end
        end
        local mine = table.concat(statuses, ",") .. " " .. rest
        local what = format("%s %s, chunks of %d", f[1], name, chunk)
        job(format("decode\t$ID\t%s\t%s\t%s\t%s\t%d", file, f[2], f[3], propsFile, chunk),
            function(perls, out)
                -- on errors liblzma stops at a position that depends on the output buffer
                -- sizes (Perl: 16 KB pieces): then only the statuses are compared
                local pst = perls:match("^(%S+)")
                if pst:match("^[0,]*[01]$") then
                    assert(perls == mine, format("%s: %s, Perl: %s", what, mine, perls))
                else
                    assert(pst == table.concat(statuses, ","), format("%s: %s, Perl: %s", what, mine, perls))
                end
                local ours = table.concat(outs)
                -- the same output (on errors Perl's may end elsewhere: its buffer sizes)
                if perls:match("^[0,]*1 ") or perls:match("^[0,]*0 ") then
                    assert(out == ours, what .. ": output differs")
                end
                counts.status = counts.status + 1
            end)
        nStatus = nStatus + 1
    end
    runBatch()
    PRINT(format("Perl: %d jobs, %d outputs byte identical, %d decompressions, %d status sequences",
                 nJobs, counts.bytes, counts.data, counts.status))
    assert(counts.status == nStatus)
    assert(not identical or counts.bytes > 100)
end
PRINT("==================================================================================")
-- the command line tool xz (liblzma): formats xz, lzma, raw
if isWindows then
    print("command line tools are not used on Windows: test part skipped")
elseif not run("xz --version >" .. devnull .. " 2>&1") then
    print("xz not available: test part skipped")
else
    local v = capture("xz --version"):match("liblzma (%S+)")
    local identical = (v == lzmaVersion)
    if not identical and requireIdentical then
        error(format("xz uses liblzma %s, compress.lzma %s: byte identity cannot be checked", tostring(v),
                     lzmaVersion))
    end
    PRINT(format("xz with liblzma %s%s", tostring(v), identical and "" or ": different version, only the data is compared"))
    -- xz options (single-threaded: -T1, the threaded encoder writes other blocks) and ours
    local cases = {
        { "-6",                    {} },
        { "-0",                    { preset = 0 } },
        { "-3e",                   { preset = 3, extreme = true } },
        { "-9",                    { preset = 9 } },
        { "-1 -C crc32",           { preset = 1, check = "crc32" } },
        { "-1 -C none",            { preset = 1, check = "none" } },
        { "-1 -C sha256",          { preset = 1, check = "sha256" } },
        { "--lzma2=preset=6,dict=64KiB,lc=1,lp=1,pb=1", { dictSize = 65536, lc = 1, lp = 1, pb = 1 } },
        { "--lzma2=preset=2,mode=fast,nice=16,mf=hc3,depth=4",
          { preset = 2, mode = "fast", niceLen = 16, mf = "hc3", depth = 4 } },
        { "--format=lzma",         { format = "lzma" } },
        { "--format=lzma -2",      { format = "lzma", preset = 2 } },
        { "--format=lzma --lzma1=preset=6,dict=1MiB,lc=0,pb=0", { format = "lzma", dictSize = 1048576, lc = 0, pb = 0 } },
        { "--format=raw",          { format = "raw" } },
        { "--format=raw --lzma2=preset=1,dict=256KiB", { format = "raw", preset = 1, dictSize = 262144 } },
        { "--format=raw --lzma1=preset=6", { format = "raw", filter = "lzma1" } },
        { "--format=raw --lzma1=preset=1,lc=2,lp=2,pb=1", { format = "raw", filter = "lzma1", preset = 1, lc = 2, lp = 2, pb = 1 } },
    }
    local n, same = 0, 0
    for i, d in ipairs(datasets) do
        local s = d[2]
        local inName = tmpDir .. "/in" .. i
        for k, c in ipairs(cases) do
            local opts = c[2]
            local out = tmpFile(format("xz%d_%d", i, k))
            assert(run(format('xz -T1 -q -c %s < "%s" > "%s"', c[1], inName, out)), c[1])
            local x = readFile(out)
            local ours = lzma.compress(s, opts)
            if identical then
                assert(x == ours, d[1] .. " xz " .. c[1] .. ": output differs")
                same = same + 1
            end
            local dopts = { format = opts.format, filter = opts.filter, lc = opts.lc, lp = opts.lp, pb = opts.pb }
            if dopts.format ~= "raw" then
                dopts.lc, dopts.lp, dopts.pb = nil, nil, nil
            end
            assert(lzma.decompress(x, dopts) == s, d[1] .. " " .. c[1])
            -- xz decompresses ours
            local oursName = tmpFile(format("ours%d_%d", i, k))
            writeFile(oursName, ours)
            local back = tmpFile(format("back%d_%d", i, k))
            assert(run(format('xz -d -q -c %s < "%s" > "%s"', c[1]:match("%-%-format=%S+") and c[1] or "",
                              oursName, back)), c[1])
            assert(readFile(back) == s, d[1] .. " xz -d " .. c[1])
            n = n + 1
        end
        -- concatenated xz streams: xz decompresses all, compress.lzma the first one
        local both = tmpFile(format("both%d.xz", i))
        local cx = lzma.compress(s, { preset = 0 })
        writeFile(both, cx .. cx)
        local back = tmpFile(format("both%d", i))
        assert(run(format('xz -dc "%s" > "%s"', both, back)))
        assert(readFile(back) == s .. s)
        assert(lzma.decompress(cx .. cx, { allowtrailing = true }) == s)
        local _, st, used = lzma.decompressor():code(cx .. cx)
        assert(st == lzma.LZMA_STREAM_END and used == #cx)
    end
    PRINT(format("xz: %d comparisons, %d byte identical", n, same))
end
PRINT("==================================================================================")
-- 7-Zip: archives with an encoded header (raw LZMA1, as ExifTool's 7Z.pm reads it), and
-- 7-Zip's own decoder for our .xz and .lzma files
local tool
if not isWindows then
    for _, t in ipairs({ "7z", "7za", "7zr" }) do
        if run(t .. " i >" .. devnull .. " 2>&1") then
            tool = t
            break
        end
    end
end
if isWindows then
    print("command line tools are not used on Windows: test part skipped")
elseif not tool then
    print("7z, 7za or 7zr not available: test part skipped")
else
    PRINT(format("7-Zip: %s", (capture(tool .. " 2>&1"):match("7%-Zip[^\n]*") or tool)))
    local okz, zlib = pcall(require, "compress.zlib")
    local n = 0
    local function check(archiveName, expect)
        local a = readFile(archiveName)
        local header, encoded, si, packed, o = sz.decodeHeader(a, lzma)
        assert(header:byte(1) == 1, archiveName)
        if encoded then
            local f = si.folders[1]
            assert(f.coders[1].id == sz.LZMA, "7-Zip compresses headers with LZMA")
            assert(#header >= f.unpackSize)
            header = header:sub(1, f.unpackSize)
            if okz then
                assert(zlib.crc32(header) == f.crc, archiveName .. ": header CRC")
            end
            -- with the unpack size: exactly the header, also in pieces
            local okSize = pcall(lzma.decompressor, { format = "raw", filter = "lzma1", size = 0 })
            if okSize then
                local d = lzma.decompressor(with(o, { size = f.unpackSize }))
                local parts = {}
                for i = 1, #packed, 1000 do parts[#parts + 1] = d:update(packed:sub(i, i + 999)) end
                parts[#parts + 1] = d:finish()
                assert(table.concat(parts) == header)
            end
            -- the defaults of Lzma::Filter::Lzma1(), the status method as Perl's code()
            local out, st, used = lzma.decompressor({ format = "raw", filter = "lzma1" }):code(packed)
            assert(st == lzma.LZMA_OK and used == #packed and out:sub(1, #header) == header)
        end
        -- the names of the files (UTF-16LE) are in the header
        for _, name in ipairs(expect.names) do
            assert(header:find((name:gsub(".", "%0\0")), 1, true), archiveName .. ": " .. name)
        end
        -- the packed data of one file: its folder, LZMA1 or LZMA2
        if expect.data then
            local main = sz.streamsInfo(header, 3)
            assert(main.folders[1].coders[1].id == expect.method)
            local okSize = pcall(lzma.decompressor, { format = "raw", filter = "lzma1", size = 0 })
            local data = sz.decodeFolder(a, main, 1, lzma,
                                         (okSize and expect.method == sz.LZMA) and { size = main.folders[1].unpackSize })
            assert(data:sub(1, #expect.data) == expect.data and #data >= #expect.data, archiveName)
            if okz then
                assert(zlib.crc32(data:sub(1, main.folders[1].unpackSize)) == zlib.crc32(expect.data))
            end
        end
        n = n + 1
        return encoded
    end
    local dir = tmpDir .. "/files"
    assert(run(format('mkdir "%s"', dir)))
    dirs[#dirs + 1] = dir
    -- many files with long names: a large header
    local names = {}
    for i = 1, 1500 do
        local name = format("a_rather_long_file_name_number_%04d.dat", i)
        names[#names + 1] = name
        writeFile(dir .. "/" .. name, (i % 10 == 0) and text(i, i) or "")
    end
    local archiveName = tmpFile("many.7z")
    assert(run(format('cd "%s" && %s a -bd -y -mhc=on "../many.7z" . >%s', dir, tool, devnull)))
    assert(check(archiveName, { names = { names[1], names[777], names[1500] } }))
    for _, name in ipairs(names) do os.remove(dir .. "/" .. name) end
    -- one file, compressed with LZMA and LZMA2 and their options
    local s = varied(300000, 21)
    writeFile(dir .. "/data.txt", s)
    for k, m in ipairs({ { "-m0=lzma -mx=1", sz.LZMA }, { "-m0=lzma -mx=5", sz.LZMA }, { "-m0=lzma -mx=9", sz.LZMA },
                         { "-m0=lzma:d=64k:lc=1:lp=1:pb=1", sz.LZMA }, { "-m0=lzma:d=4m:fb=128:mf=hc4", sz.LZMA },
                         { "-m0=lzma2 -mx=5", sz.LZMA2 }, { "-m0=lzma2:d=1m", sz.LZMA2 } }) do
        local name = tmpFile(format("one%d.7z", k))
        assert(run(format('cd "%s" && %s a -bd -y -mhc=on %s "../one%d.7z" data.txt >%s', dir, tool, m[1], k, devnull)))
        check(name, { names = { "data.txt" }, data = s, method = m[2] })
    end
    -- an archive without header compression: the header as it is
    local plain = tmpFile("plain.7z")
    assert(run(format('cd "%s" && %s a -bd -y -mhc=off "../plain.7z" data.txt >%s', dir, tool, devnull)))
    assert(not check(plain, { names = { "data.txt" }, data = s, method = sz.LZMA2 }))
    os.remove(dir .. "/data.txt")
    -- 7-Zip decompresses our .xz and .lzma files
    for k, opts in ipairs({ {}, { preset = 9 }, { check = "sha256" }, { format = "lzma" },
                            { format = "lzma", preset = 1, lc = 0, pb = 0 } }) do
        local ext = (opts.format == "lzma") and "lzma" or "xz"
        local name = tmpFile(format("ours%d.%s", k, ext))
        writeFile(name, lzma.compress(s, opts))
        local back = tmpFile(format("ours%d.back", k))
        assert(run(format('%s e -bd -y -so "%s" > "%s" 2>%s', tool, name, back, devnull)))
        assert(readFile(back) == s, "7-Zip decodes " .. ext)
        n = n + 1
    end
    PRINT(format("7-Zip: %d archives and files", n))
end
PRINT("==================================================================================")
end

local ok, err = xpcall(main, debug.traceback)
cleanup()
if not ok then
    error(err, 0)
end
print("OK.")
