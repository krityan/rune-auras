-- LZW compression for sharing auras: a serialized aura repeats the same key
-- names over and over, so this shrinks an export a lot, which matters as
-- the game's text field takes about 10,000 characters at most. Codes are
-- written with as many bits as the dictionary needs so far, up to 16; once
-- full, the dictionary stops growing.

local lzw = {}

local BITS_PER_BYTE = 8
local BYTE_BITS = 0xFF
-- Codes 0-255 are the single bytes, so the dictionary starts this big.
local SINGLE_BYTE_CODES = 256
-- The fewest bits a code is written with: enough for the single bytes and the next code.
local MIN_BITS = 9
local MAX_BITS = 16
local MAX_CODES = 1 << MAX_BITS
-- Decompressed text larger than this is refused (a real export is a small
-- fraction of it), so a crafted input can't balloon.
local MAX_OUTPUT = 4000000

--- How many bits a code needs while the dictionary has `size` entries.
---@param size integer
---@return integer
local function bitsFor(size)
    local bits = MIN_BITS
    while (1 << bits) < size and bits < MAX_BITS do bits = bits + 1 end
    return bits
end

--- A mask of the lowest `count` bits.
---@param count integer
---@return integer
local function lowBits(count)
    return (1 << count) - 1
end

--- Compresses a string.
---@param text string
---@return string packed
function lzw.Compress(text)
    local dictionary, size = {}, SINGLE_BYTE_CODES
    for code = 0, SINGLE_BYTE_CODES - 1 do dictionary[string.char(code)] = code end
    local out, pendingBits, pendingCount = {}, 0, 0
    --- Appends a code, at the width the dictionary needs now, flushing
    --- whole bytes.
    ---@param code integer
    local function write(code)
        local bits = bitsFor(size)
        pendingBits = (pendingBits << bits) | code
        pendingCount = pendingCount + bits
        while pendingCount >= BITS_PER_BYTE do
            pendingCount = pendingCount - BITS_PER_BYTE
            out[#out + 1] = string.char((pendingBits >> pendingCount) & BYTE_BITS)
        end
        pendingBits = pendingBits & lowBits(pendingCount)
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
    if pendingCount > 0 then
        out[#out + 1] = string.char((pendingBits << (BITS_PER_BYTE - pendingCount)) & BYTE_BITS)
    end
    return table.concat(out)
end

--- The text a string was compressed from. Checks every code, so anything
--- that isn't valid output of Compress is refused.
---@param data any
---@return string? text nil if it isn't valid.
function lzw.Decompress(data)
    if type(data) ~= "string" then return nil end
    local dictionary, size = {}, SINGLE_BYTE_CODES
    for code = 0, SINGLE_BYTE_CODES - 1 do dictionary[code] = string.char(code) end
    local out, total = {}, 0
    local pendingBits, pendingCount, position = 0, 0, 1
    local previous = nil
    while true do
        -- The decoder's dictionary runs one entry behind the encoder's (it
        -- adds each entry a code later), so reading uses the size it will have.
        local encoderSize = previous == nil and size or math.min(size + 1, MAX_CODES)
        local bits = bitsFor(encoderSize)
        while pendingCount < bits and position <= #data do
            pendingBits = (pendingBits << BITS_PER_BYTE) | data:byte(position)
            pendingCount = pendingCount + BITS_PER_BYTE
            position = position + 1
        end
        if pendingCount < bits then break end
        pendingCount = pendingCount - bits
        local code = (pendingBits >> pendingCount) & lowBits(bits)
        pendingBits = pendingBits & lowBits(pendingCount)
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
    if pendingCount >= BITS_PER_BYTE or position <= #data then return nil end
    return table.concat(out)
end

return lzw
