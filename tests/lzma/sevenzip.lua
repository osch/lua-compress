-- Test helper of tests/lzma: a minimal reader of the 7z container, enough to find the
-- packed streams of an archive and the LZMA coder properties of their folders, as an
-- archive reader that decodes 7z with compress.lzma does it (e.g. a port of ExifTool's
-- 7Z.pm with its encoded header). Supports the structures 7-Zip writes for archives
-- with one coder per folder (LZMA, LZMA2, Copy); no BCJ, no encryption. Lua 5.1 or later.
--
--   local sz = dofile("sevenzip.lua")
--   local info = sz.signature(archive)        -- next header offset/size, or nil
--   local si, pos = sz.streamsInfo(s, pos)   -- packPos, packSizes, folders (coders with
--                                             -- method id and properties, unpackSizes)
--   sz.decodeHeader(archive, lzma)            -- the header (kHeader ...), decoded if needed

local sevenzip = {}

local function le(s, pos, n)
    local v = 0
    for i = n, 1, -1 do
        v = v * 256 + s:byte(pos + i - 1)
    end
    return v
end

-- the variable length NUMBER of 7z: the leading 1 bits of the first byte tell how many
-- bytes follow (little endian), the rest of the first byte is the high part
local function number(s, pos)
    local first = s:byte(pos)
    pos = pos + 1
    local mask = 128
    local value = 0
    local factor = 1           -- 256^i, as integer
    for _ = 0, 7 do
        if math.floor(first / mask) % 2 == 0 then
            local high = first % mask
            return value + high * factor, pos
        end
        value = value + s:byte(pos) * factor
        factor = factor * 256
        pos = pos + 1
        mask = math.floor(mask / 2)
    end
    return value, pos
end
sevenzip.number = number

local function expect(s, pos, id, what)
    assert(s:byte(pos) == id, string.format("7z: %s (0x%02x) expected at %d, got 0x%02x", what, id,
                                            pos, s:byte(pos) or -1))
    return pos + 1
end

-- skips a digests structure (kCRC): allAreDefined, (bit vector), the CRCs
local function digests(s, pos, n)
    local all = s:byte(pos)
    pos = pos + 1
    local defined = n
    if all == 0 then
        defined = 0
        local nbytes = math.floor((n + 7) / 8)
        for i = 0, n - 1 do
            local b = s:byte(pos + math.floor(i / 8))
            if math.floor(b / 2 ^ (7 - i % 8)) % 2 == 1 then defined = defined + 1 end
        end
        pos = pos + nbytes
    end
    local crcs = {}
    for i = 1, defined do
        crcs[i] = le(s, pos, 4)
        pos = pos + 4
    end
    return pos, crcs
end

local function folder(s, pos)
    local f = { coders = {} }
    local numCoders
    numCoders, pos = number(s, pos)
    local numOut = 0
    for i = 1, numCoders do
        local flag = s:byte(pos)
        pos = pos + 1
        local c = { id = s:sub(pos, pos + flag % 16 - 1) }
        pos = pos + flag % 16
        c.numIn, c.numOut = 1, 1
        if math.floor(flag / 16) % 2 == 1 then
            c.numIn, pos = number(s, pos)
            c.numOut, pos = number(s, pos)
        end
        if math.floor(flag / 32) % 2 == 1 then
            local n
            n, pos = number(s, pos)
            c.properties = s:sub(pos, pos + n - 1)
            pos = pos + n
        end
        assert(math.floor(flag / 128) == 0, "7z: alternative coder methods are not supported")
        numOut = numOut + c.numOut
        f.coders[i] = c
    end
    assert(numOut == 1, "7z: only folders with one coder are supported")
    f.numOut = numOut
    return f, pos
end

-- the StreamsInfo structure at pos (after its id): returns it and the position after it
function sevenzip.streamsInfo(s, pos)
    local si = { packSizes = {}, folders = {} }
    if s:byte(pos) == 0x06 then                     -- kPackInfo
        pos = pos + 1
        local n
        si.packPos, pos = number(s, pos)
        n, pos = number(s, pos)
        pos = expect(s, pos, 0x09, "kSize")
        for i = 1, n do
            si.packSizes[i], pos = number(s, pos)
        end
        if s:byte(pos) == 0x0A then
            pos = digests(s, pos + 1, n)
        end
        pos = expect(s, pos, 0x00, "kEnd")
    end
    if s:byte(pos) == 0x07 then                     -- kUnpackInfo
        pos = pos + 1
        pos = expect(s, pos, 0x0B, "kFolder")
        local n
        n, pos = number(s, pos)
        pos = expect(s, pos, 0x00, "external 0")
        for i = 1, n do
            si.folders[i], pos = folder(s, pos)
        end
        pos = expect(s, pos, 0x0C, "kCodersUnpackSize")
        for i = 1, n do
            si.folders[i].unpackSize, pos = number(s, pos)
        end
        if s:byte(pos) == 0x0A then
            local crcs
            pos, crcs = digests(s, pos + 1, n)
            for i = 1, n do si.folders[i].crc = crcs[i] end
        end
        pos = expect(s, pos, 0x00, "kEnd")
    end
    if s:byte(pos) == 0x08 then                     -- kSubStreamsInfo: not needed, skipped
        si.subStreams = true
        return si, nil
    end
    pos = expect(s, pos, 0x00, "kEnd")
    return si, pos
end

-- the signature header: { nextOffset, nextSize } or nil if s is no 7z archive
function sevenzip.signature(s)
    if s:sub(1, 6) ~= "7z\188\175\39\28" then
        return nil
    end
    return { nextOffset = le(s, 13, 8), nextSize = le(s, 21, 8) }
end

sevenzip.LZMA  = "\3\1\1"
sevenzip.LZMA2 = "\33"
sevenzip.COPY  = "\0"

-- decodes folder i of the streams info si of archive s with compress.lzma (raw LZMA1 or
-- LZMA2 with the coder's properties, and the unpack size as option size where supported)
function sevenzip.decodeFolder(s, si, i, lzma, opts)
    local f = si.folders[i]
    local start = 32 + si.packPos
    for k = 1, i - 1 do start = start + si.packSizes[k] end
    local packed = s:sub(start + 1, start + si.packSizes[i])
    local c = f.coders[1]
    if c.id == sevenzip.COPY then
        return packed, packed
    end
    local o = { format = "raw", filter = (c.id == sevenzip.LZMA) and "lzma1" or "lzma2",
                properties = c.properties }
    assert(c.id == sevenzip.LZMA or c.id == sevenzip.LZMA2, "7z: unsupported coder")
    for k, v in pairs(opts or {}) do o[k] = v end
    return lzma.decompress(packed, o), packed, o
end

-- the header of the archive s: decoded with compress.lzma if it is an encoded header
function sevenzip.decodeHeader(s, lzma, opts)
    local sig = assert(sevenzip.signature(s), "7z: no signature")
    local pos = 32 + sig.nextOffset + 1
    local id = s:byte(pos)
    if id == 0x01 then
        return s:sub(pos, pos + sig.nextSize - 1), false
    end
    assert(id == 0x17, "7z: header expected")      -- kEncodedHeader
    local si = sevenzip.streamsInfo(s, pos + 1)
    local header, packed, o = sevenzip.decodeFolder(s, si, 1, lzma, opts)
    return header, true, si, packed, o
end

-- a 7z archive from 7-Zip 26.01 (7z a -mx=5 -mhc=on a.7z name_*.txt, five files name_<i>.txt
-- with "file <i> content\n") with an encoded header: an LZMA1 stream with the coder
-- properties 5d 00 10 00 00 (lc 3, lp 0, pb 2, 4 KiB dictionary), 250 bytes unpacked
sevenzip.SAMPLE = (("377abcaf271c0004da62c34da50000000000000021000000000000006bd47fb7e0004a001e5d00331a49d6b7" ..
                  "902bb159e3d6c8fb2ea04c90f7a5ca49cc3d5a781777a52c00000000813307ae0fd0697dbc9f3f4741058786" ..
                  "a34b54acd3d58407c008b6169a3e3936770c44e29fc249fdf01e1f0f981078a64b6fe0ea1a1d6c16f4dae3f9" ..
                  "26987c9d2cb289012ff6960f18dadc93d5efc7909bb9b70b702629e24b604e567f4cda930c6f5b06525dc861" ..
                  "b802478e86ef597dbe5896334b27aa14eced2f000017062601097f00070b01000123030101055d001000000c" ..
                  "80fa0a010a0524eb0000")
                 :gsub("..", function(h) return string.char(tonumber(h, 16)) end))

return sevenzip
