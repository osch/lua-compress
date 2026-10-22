-- Compares compress.bzip2 with other libbz2 users on this machine: Perl's
-- Compress::Raw::Bzip2 and IO::Compress::Bzip2 / IO::Uncompress::Bunzip2 (helper script
-- test04.pl) and the command line tool bzip2. Each part is skipped if the tool is not
-- installed (the command line tool on Windows).
--
-- With the same libbz2 version and the same block size the compressed bytes are expected
-- to be identical, not only the decompressed data (the work factor does not change the
-- output). Perl's default block size differs: Compress::Raw::Bzip2 and IO::Compress::Bzip2
-- use 1 (100 kB), the bzip2 tool and compress.bzip2 9 (900 kB); the tests give it
-- explicitly. Compress-Raw-Bzip2 bundles its own copy of libbz2 (1.0.8) by default.

local bzip2 = require("compress.bzip2")

local format = string.format

-- the Perl to compare with (COMPRESS_TEST_PERL, default "perl" from PATH; a path without
-- spaces); Compress::Raw::Bzip2 may come from PERL5LIB (e.g. a local::lib)
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

-- random bytes without two equal neighbours: each byte is one symbol of the block
-- (libbz2 counts runs of 4 and more as fewer), so that n bytes fill exactly n - 1 symbols
-- and the last byte is still pending in the run-length encoder
local function noRuns(n, seed)
    local rnd = newRandom(seed)
    local t, prev = {}, -1
    for i = 1, n do
        local c = rnd(255)
        if c >= prev and prev >= 0 then c = c + 1 end
        t[i] = string.char(c)
        prev = c
    end
    return table.concat(t)
end

local function text(n, seed)
    local words = { "lorem", "ipsum", "dolor", "sit", "amet", "\0", "\n", "bzip2", "Lua", "1234" }
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
    { "text",   text(250000, 3) },
    { "random", randomBytes(30000, 5) },
    { "mixed",  text(50000, 7) .. randomBytes(20000, 9) .. text(50000, 11) },
    { "varied", varied(150000, 13) },
    -- repetitive data: the fallback sorting algorithm of libbz2 (work factor)
    { "runs",   ("ab"):rep(60000) .. ("\0"):rep(30000) .. ("abc"):rep(20000) },
    -- block size 1: the input ends where the block (99981 symbols) is full, the last byte
    -- still pending; libbz2 gives other bytes when all input is given to BZ_FINISH at once
    -- (BZ2_bzBuffToBuffCompress) than with BZ_RUN and then BZ_FINISH (bzip2, Perl, ours)
    { "edge",   noRuns(99982, 15) },
}

-- os.tmpname() gives a name in the root directory on Windows, use the current one there
local isWindows = package.config:sub(1, 1) == "\\"
local devnull = isWindows and "NUL" or "/dev/null"
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local tmpDir
if isWindows then
    tmpDir = "compress_bzip2_test04.tmp"
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

local bzVersion = bzip2.version()
local requireIdentical = os.getenv("COMPRESS_TEST_REQUIRE_IDENTICAL") == "1"

-- the version number of a libbz2 version string ("1.0.8, 13-Jul-2019")
local function versionNumber(v)
    return v and v:match("^%s*(%d+%.%d+%.%d+)")
end

-- the tests, run with pcall: the temporary files are removed also after a failure
local function main()

PRINT("==================================================================================")
-- Perl
local perlVersion = capture(PERL .. ' -MCompress::Raw::Bzip2 -MIO::Compress::Bzip2 -e '
                            .. '"print Compress::Raw::Bzip2::bzlibversion()" 2>' .. devnull)
if not perlVersion or perlVersion == "" then
    print("perl with Compress::Raw::Bzip2 and IO::Compress::Bzip2 not available: test part skipped")
else
    local identical = (versionNumber(perlVersion) == versionNumber(bzVersion))
    if not identical and requireIdentical then
        error(format("Perl's Compress::Raw::Bzip2 uses libbz2 %s, compress.bzip2 %s: byte identity "
                     .. "cannot be checked", perlVersion, bzVersion))
    end
    PRINT(format("Perl Compress::Raw::Bzip2 with libbz2 %s, compress.bzip2 with libbz2 %s%s", perlVersion,
                 bzVersion, identical and "" or ": different versions, only the data is compared"))
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

    for i, d in ipairs(datasets) do
        local s = d[2]
        local inName = "in" .. i
        local function encoderJob(line, ours, what)
            job(line, function(perls)
                sameBytes(ours, perls, what)
                assert(bzip2.decompress(perls) == s, what)
                counts.data = counts.data + 1
            end)
        end
        -- Compress::Raw::Bzip2: block size, work factor, pieces, flushes
        for _, p in ipairs({ { 1, 0, 0 }, { 9, 0, 0 }, { 5, 30, 0 }, { 1, 1, 0 }, { 9, 250, 0 },
                             { 2, 0, 1 }, { 1, 0, 7777 }, { 3, 0, 50000 } }) do
            local ours = bzip2.compress(s, { blockSize100k = p[1], workFactor = p[2] })
            encoderJob(format("deflate\t$ID\t%s\t%d\t%d\t%d\t0", inName, p[1], p[2], p[3]), ours,
                       format("%s Compress::Raw::Bzip2 %d %d, pieces of %d", d[1], p[1], p[2], p[3]))
        end
        -- bzflush() after each piece: our flush()
        for _, p in ipairs({ { 1, 7777 }, { 9, 100000 } }) do
            local c = bzip2.compressor({ level = p[1] })
            local parts = {}
            for k = 1, #s, p[2] do
                parts[#parts + 1] = c:update(s:sub(k, k + p[2] - 1))
                parts[#parts + 1] = c:flush()
            end
            parts[#parts + 1] = c:finish()
            encoderJob(format("deflate\t$ID\t%s\t%d\t0\t%d\t1", inName, p[1], p[2]), table.concat(parts),
                       format("%s Compress::Raw::Bzip2 %d with bzflush, pieces of %d", d[1], p[1], p[2]))
        end
        -- IO::Compress::Bzip2: its default block size is 1
        encoderJob(format("iobzip2\t$ID\t%s\t-", inName), bzip2.compress(s, { level = 1 }),
                   d[1] .. " IO::Compress::Bzip2")
        encoderJob(format("iobzip2\t$ID\t%s\t9", inName), bzip2.compress(s),
                   d[1] .. " IO::Compress::Bzip2 BlockSize100K 9")
        -- Perl decodes our output: Compress::Raw::Bunzip2 and IO::Uncompress::Bunzip2
        for _, o in ipairs({ { 0, bzip2.compress(s) }, { 1, bzip2.compress(s, { level = 2 }) } }) do
            local name = jobFile("ours", o[2])
            job(format("decode\t$ID\t%s\t%d\t0", name, o[1]), function(perls, out)
                assert(perls == "4 0" and out == s, d[1] .. " Perl's decoder: " .. perls)
                counts.data = counts.data + 1
            end)
        end
        local name = jobFile("ours", bzip2.compress(s, { level = 4 }))
        job(format("bunzip2\t$ID\t%s\t0", name), function(perls, out)
            assert(perls == "ok" and out == s, d[1] .. " bunzip2")
            counts.data = counts.data + 1
        end)
        runBatch()
    end

    -- concatenated streams: IO::Uncompress::Bunzip2 with MultiStream reads all, without it the
    -- first one (data after it is ignored, as with allowtrailing); our loop over the streams
    -- with the status method gives the same
    local s1, s2 = datasets[3][2], datasets[4][2]
    local multi = bzip2.compress(s1, { level = 1 }) .. bzip2.compress(s2) .. bzip2.compress("")
    local function all(data)
        local out, pos = {}, 1
        repeat
            local o, st, n = bzip2.decompressor():decompress(data:sub(pos))
            assert(st == bzip2.BZ_STREAM_END)
            out[#out + 1] = o
            pos = pos + n
        until pos > #data
        return table.concat(out)
    end
    assert(all(multi) == s1 .. s2)
    for _, m in ipairs({ 0, 1 }) do
        local name = jobFile("multi", multi)
        job(format("bunzip2\t$ID\t%s\t%d", name, m), function(perls, out)
            local expect = (m == 1) and all(multi) or bzip2.decompress(multi, { allowtrailing = true })
            assert(perls == "ok" and out == expect, "MultiStream " .. m)
            counts.data = counts.data + 1
        end)
    end
    runBatch()

    -- statuses: the status method bzinflate() gives the same statuses as Perl's bzinflate(),
    -- consumes the same input and gives the same output
    local s = datasets[6][2]
    local cases = {}
    for _, k in ipairs({ 1, 9 }) do
        local c = bzip2.compress(s, { level = k })
        for _, cs in ipairs({ { "complete", c }, { "trailing", c .. "TRAILING DATA" },
                              { "two streams", c .. bzip2.compress("x") },
                              { "truncated", c:sub(1, math.floor(#c / 2)) },
                              { "corrupt", c:sub(1, 2000) .. ("\255"):rep(7) .. c:sub(2008) },
                              { "bad crc", c:sub(1, -3) .. string.char((c:byte(-2) + 1) % 256) .. c:sub(-1) },
                              { "garbage", ("garbage data"):rep(3) }, { "bad magic", "BZh0" .. c:sub(5) },
                              { "empty", "" } }) do
            for _, chunk in ipairs({ 0, 1, 777 }) do
                for _, small in ipairs({ false, true }) do
                    if not small or chunk == 777 then
                        cases[#cases + 1] = { k, cs[1], cs[2], chunk, small }
                    end
                end
            end
        end
    end
    local nStatus = 0
    for _, cs in ipairs(cases) do
        local k, name, data, chunk, small = cs[1], cs[2], cs[3], cs[4], cs[5]
        local file = jobFile("case", data)
        local d = bzip2.decompressor({ small = small })
        local statuses, outs, rest = {}, {}, 0
        local step = (chunk > 0) and chunk or math.max(#data, 1)
        local pieces = {}
        for i = 1, #data, step do pieces[#pieces + 1] = data:sub(i, i + step - 1) end
        if #pieces == 0 then pieces[1] = "" end
        for _, piece in ipairs(pieces) do
            local out, st, n = d:bzinflate(piece)
            statuses[#statuses + 1] = tostring(st)
            outs[#outs + 1] = out
            rest = #piece - n
            if st ~= bzip2.BZ_OK then break end
        end
        local mine = table.concat(statuses, ",") .. " " .. rest
        local what = format("block size %d, %s, chunks of %d%s", k, name, chunk, small and ", small" or "")
        job(format("decode\t$ID\t%s\t%d\t%d", file, small and 1 or 0, chunk),
            function(perls, out)
                -- on errors Perl's bzinflate does not remove the consumed input: then only
                -- the statuses are compared
                local pst = perls:match("^(%S+)")
                if pst:match("^[0,]*[04]$") then
                    assert(perls == mine, format("%s: %s, Perl: %s", what, mine, perls))
                else
                    assert(pst == table.concat(statuses, ","), format("%s: %s, Perl: %s", what, mine, perls))
                end
                -- the same output; on errors Perl's bzinflate discards the output of the
                -- call (ours gives the output up to the error)
                local ours = table.concat(outs)
                if not pst:match("^[0,]*[04]$") then
                    ours = table.concat(outs, "", 1, #outs - 1)
                end
                assert(out == ours, format("%s: output differs (%d/%d bytes, Perl: %s)", what, #ours, #out, perls))
                counts.status = counts.status + 1
            end)
        nStatus = nStatus + 1
    end
    runBatch()
    PRINT(format("Perl: %d jobs, %d outputs byte identical, %d decompressions, %d status sequences",
                 nJobs, counts.bytes, counts.data, counts.status))
    assert(counts.status == nStatus)
    assert(not identical or counts.bytes > 80)
end
PRINT("==================================================================================")
-- the command line tool bzip2 (libbz2)
if isWindows then
    print("command line tools are not used on Windows: test part skipped")
elseif not run("bzip2 --help >" .. devnull .. " 2>&1") then
    print("bzip2 not available: test part skipped")
else
    -- "bzip2, a block-sorting file compressor.  Version 1.0.8, 13-Jul-2019."
    local v = capture("bzip2 --help 2>&1 </dev/null"):match("Version (%d+%.%d+%.%d+)")
    local identical = (v == versionNumber(bzVersion))
    if not identical and requireIdentical then
        error(format("bzip2 uses libbz2 %s, compress.bzip2 %s: byte identity cannot be checked", tostring(v),
                     bzVersion))
    end
    PRINT(format("bzip2 %s%s", tostring(v), identical and "" or ": different version, only the data is compared"))
    local n, same = 0, 0
    for i, d in ipairs(datasets) do
        local s = d[2]
        local inName = tmpDir .. "/in" .. i
        for k = 1, 9 do
            if k <= 2 or k == 5 or k == 9 or d[1] == "text" then
                local out = tmpFile(format("bz%d_%d", i, k))
                assert(run(format('bzip2 -%d -c < "%s" > "%s"', k, inName, out)))
                local x = readFile(out)
                local ours = bzip2.compress(s, { level = k })
                if identical then
                    assert(x == ours, d[1] .. " bzip2 -" .. k .. ": output differs")
                    same = same + 1
                end
                assert(bzip2.decompress(x) == s, d[1] .. " bzip2 -" .. k)
                -- bzip2 decompresses ours, also with -s (small)
                local oursName = tmpFile(format("ours%d_%d", i, k))
                writeFile(oursName, ours)
                local back = tmpFile(format("back%d_%d", i, k))
                assert(run(format('bzip2 -d %s -c < "%s" > "%s"', (k % 2 == 0) and "-s" or "", oursName, back)))
                assert(readFile(back) == s, d[1] .. " bzip2 -d " .. k)
                n = n + 1
            end
        end
        -- concatenated streams: bzip2 decompresses all, our loop over the streams as well
        local both = tmpFile(format("both%d.bz2", i))
        local c = bzip2.compress(s, { level = 1 })
        writeFile(both, c .. c)
        local back = tmpFile(format("both%d", i))
        assert(run(format('bzip2 -dc "%s" > "%s"', both, back)))
        assert(readFile(back) == s .. s)
        assert(bzip2.decompress(c .. c, { allowtrailing = true }) == s)
        local _, st, used = bzip2.decompressor():decompress(c .. c)
        assert(st == bzip2.BZ_STREAM_END and used == #c)
    end
    PRINT(format("bzip2: %d comparisons, %d byte identical", n, same))
end
PRINT("==================================================================================")
end

local ok, err = xpcall(main, debug.traceback)
cleanup()
if not ok then
    error(err, 0)
end
print("OK.")
