-- How single values are saved in PersistentDB: colours as hex strings (it
-- rounds large numbers, losing their alpha byte) and numbers back to integers.

local savedValues = {}

-- Directions for the Store's conversions between saved and plugin form.
savedValues.DECODE, savedValues.ENCODE = true, false

-- Colours are 32 bits: red, green, blue, then alpha in the low byte.
local COLOUR_BITS = 0xFFFFFFFF
local RGB_BITS = 0xFFFFFF00
local OPAQUE_ALPHA = 0xFF

--- Whether a field holds a 0xRRGGBBAA colour: it's named "colour" or ends
--- in "Colour". These are saved as hex strings.
---@param key any
---@return boolean
function savedValues.IsColourKey(key)
    return key == "colour" or (type(key) == "string" and key:match("Colour$") ~= nil)
end

--- Rounds a stored number down to an integer: storage can return floats.
---@param value any
---@return integer? integer nil if it isn't a number.
function savedValues.ToInteger(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.floor(number)
end

--- A colour's saved form.
---@param colour integer 0xRRGGBBAA.
---@return string hex Eight hex digits.
function savedValues.EncodeColour(colour)
    return string.format("%08X", colour & COLOUR_BITS)
end

--- A saved colour back as 0xRRGGBBAA. Older saves stored numbers whose
--- alpha byte was rounded away; those come back fully opaque.
---@param value any Hex string, or an old number.
---@return integer? colour nil if it isn't either.
function savedValues.DecodeColour(value)
    if type(value) == "string" then
        return tonumber(value, 16)
    end
    local number = savedValues.ToInteger(value)
    if number == nil then return nil end
    return (number & RGB_BITS) | OPAQUE_ALPHA
end

return savedValues
