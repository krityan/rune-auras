-- Base64 (standard alphabet, with = padding), for sharing auras as text:
-- its characters are all in the game's character set and none is read as
-- a text tag.

local base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- Six-bit value to its character, and character byte to its value.
local CHAR_FOR, VALUE_OF = {}, {}
for index = 1, #ALPHABET do
    local char = ALPHABET:sub(index, index)
    CHAR_FOR[index - 1] = char
    VALUE_OF[char:byte()] = index - 1
end
local PAD = ("="):byte()
local SIX_BITS = 0x3F
local BYTE_BITS = 0xFF
-- Three bytes make four characters.
local BYTES_PER_GROUP, CHARS_PER_GROUP = 3, 4

--- Encodes a string.
--- `Encode("hello")` gives "aGVsbG8=".
---@param text string
---@return string
function base64.Encode(text)
    local out = {}
    for index = 1, #text, BYTES_PER_GROUP do
        local first, second, third = text:byte(index, index + 2)
        local bits = (first << 16) | ((second or 0) << 8) | (third or 0)
        out[#out + 1] = CHAR_FOR[(bits >> 18) & SIX_BITS] .. CHAR_FOR[(bits >> 12) & SIX_BITS]
            .. (second and CHAR_FOR[(bits >> 6) & SIX_BITS] or "=")
            .. (third and CHAR_FOR[bits & SIX_BITS] or "=")
    end
    return table.concat(out)
end

--- Decodes a base64 string, refusing anything that isn't valid: a length
--- that isn't a multiple of 4, a character outside the alphabet, or padding
--- anywhere but the end.
---@param text any
---@return string? decoded nil if it isn't valid base64.
function base64.Decode(text)
    if type(text) ~= "string" or #text % CHARS_PER_GROUP ~= 0 then return nil end
    local out = {}
    for index = 1, #text, CHARS_PER_GROUP do
        local isLastGroup = index + CHARS_PER_GROUP - 1 == #text
        local values = {}
        local padding = 0
        for offset = 0, CHARS_PER_GROUP - 1 do
            local byte = text:byte(index + offset)
            local value = VALUE_OF[byte]
            -- Only the last group's last two characters may be padding.
            if byte == PAD and isLastGroup and offset >= 2 then
                padding = padding + 1
                value = 0
            elseif value == nil or padding > 0 then
                return nil
            end
            values[offset + 1] = value
        end
        local bits = (values[1] << 18) | (values[2] << 12) | (values[3] << 6) | values[4]
        out[#out + 1] = string.char((bits >> 16) & BYTE_BITS)
        if padding < 2 then out[#out + 1] = string.char((bits >> 8) & BYTE_BITS) end
        if padding < 1 then out[#out + 1] = string.char(bits & BYTE_BITS) end
    end
    return table.concat(out)
end

return base64
