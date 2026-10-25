-- LZW compression for sharing auras: a serialized aura repeats the same key
-- names over and over, so this shrinks an export a lot, which matters as
-- the game's text field takes about 10,000 characters at most.
-- Codes are written with as many bits as the dictionary needs so far, up
-- to 16; once full, the dictionary stops growing. Decompress checks every
-- code and returns nil for anything that isn't valid output of Compress.
-- Usage: local lzw = require("Auras/Helpers/lzw")
--        local packed = lzw.Compress(text)
--        local text = lzw.Decompress(packed)   -- or nil

local lzw = {}

local MAX_BITS = 16
local MAX_CODES = 1 << MAX_BITS
-- Decompressed text larger than this is refused (a real export is a small
-- fraction of it), so a crafted input can't balloon.
local MAX_OUTPUT = 4000000

local function bitsFor(size)
    local bits = 9
    while (1 << bits) < size and bits < MAX_BITS do bits = bits + 1 end
    return bits
end

function lzw.Compress(text)
    local dictionary, size = {}, 256
    for code = 0, 255 do dictionary[string.char(code)] = code end
    local out, buffer, buffered = {}, 0, 0
    local function write(code)
        local bits = bitsFor(size)
        buffer = (buffer << bits) | code
        buffered = buffered + bits
        while buffered >= 8 do
            buffered = buffered - 8
            out[#out + 1] = string.char((buffer >> buffered) & 255)
        end
        buffer = buffer & ((1 << buffered) - 1)
    end
    local current = ""
    for index = 1, #text do
        local char = text:sub(index, index)
        local joined = current .. char
        if dictionary[joined] ~= nil then
            current = joined
        else
            write(dictionary[current])
            if size < MAX_CODES then
                dictionary[joined] = size
                size = size + 1
            end
            current = char
        end
    end
    if current ~= "" then write(dictionary[current]) end
    if buffered > 0 then out[#out + 1] = string.char((buffer << (8 - buffered)) & 255) end
    return table.concat(out)
end

-- The text `data` was compressed from, or nil if it isn't valid.
function lzw.Decompress(data)
    if type(data) ~= "string" then return nil end
    -- The decoder's dictionary runs one entry behind the encoder's (it adds
    -- each entry a code later), so reading uses the size it will have.
    local dictionary, size = {}, 256
    for code = 0, 255 do dictionary[code] = string.char(code) end
    local out, total = {}, 0
    local buffer, buffered, position = 0, 0, 1
    local previous = nil
    while true do
        local bits = bitsFor(previous == nil and size or math.min(size + 1, MAX_CODES))
        while buffered < bits and position <= #data do
            buffer = (buffer << 8) | data:byte(position)
            buffered = buffered + 8
            position = position + 1
        end
        if buffered < bits then break end
        buffered = buffered - bits
        local code = (buffer >> buffered) & ((1 << bits) - 1)
        buffer = buffer & ((1 << buffered) - 1)
        local entry = dictionary[code]
        if entry == nil then
            -- Only the entry about to be added can be used before it exists.
            if previous == nil or code ~= size then return nil end
            entry = previous .. previous:sub(1, 1)
        end
        total = total + #entry
        if total > MAX_OUTPUT then return nil end
        out[#out + 1] = entry
        if previous ~= nil and size < MAX_CODES then
            dictionary[size] = previous .. entry:sub(1, 1)
            size = size + 1
        end
        previous = entry
    end
    -- Leftover bits are only the final byte's padding.
    if buffered >= 8 or position <= #data then return nil end
    return table.concat(out)
end

return lzw
