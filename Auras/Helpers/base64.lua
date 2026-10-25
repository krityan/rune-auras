-- Base64 (standard alphabet, with = padding), for sharing auras as text:
-- its characters are all in the game's character set and none is read as
-- a text tag. Decode refuses anything that isn't valid base64.
-- Usage: local base64 = require("Auras/Helpers/base64")
--        base64.Encode("hello")      --> "aGVsbG8="
--        base64.Decode("aGVsbG8=")   --> "hello", or nil if it's not base64

local base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENCODE, DECODE = {}, {}
for index = 1, #ALPHABET do
    local char = ALPHABET:sub(index, index)
    ENCODE[index - 1] = char
    DECODE[char:byte()] = index - 1
end
local PAD = ("="):byte()

function base64.Encode(text)
    local out = {}
    for index = 1, #text, 3 do
        local a, b, c = text:byte(index, index + 2)
        local bits = (a << 16) | ((b or 0) << 8) | (c or 0)
        out[#out + 1] = ENCODE[(bits >> 18) & 63] .. ENCODE[(bits >> 12) & 63]
            .. (b and ENCODE[(bits >> 6) & 63] or "=") .. (c and ENCODE[bits & 63] or "=")
    end
    return table.concat(out)
end

-- nil for anything that isn't valid base64: a length that isn't a multiple
-- of 4, a character outside the alphabet, or padding anywhere but the end.
function base64.Decode(text)
    if type(text) ~= "string" or #text % 4 ~= 0 then return nil end
    local out = {}
    for index = 1, #text, 4 do
        local last = index + 3 == #text
        local values = {}
        local padding = 0
        for offset = 0, 3 do
            local byte = text:byte(index + offset)
            local value = DECODE[byte]
            if byte == PAD and last and offset >= 2 then
                padding = padding + 1
                value = 0
            elseif value == nil or padding > 0 then
                return nil
            end
            values[offset + 1] = value
        end
        local bits = (values[1] << 18) | (values[2] << 12) | (values[3] << 6) | values[4]
        out[#out + 1] = string.char((bits >> 16) & 255)
        if padding < 2 then out[#out + 1] = string.char((bits >> 8) & 255) end
        if padding < 1 then out[#out + 1] = string.char(bits & 255) end
    end
    return table.concat(out)
end

return base64
