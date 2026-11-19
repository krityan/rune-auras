-- Small number helpers shared by displays and controls.

local maths = {}

--- Keeps a value within a range. Where the limits cross, the minimum wins.
---@param value number
---@param minimum number? nil: no lower limit.
---@param maximum number? nil: no upper limit.
---@return number
function maths.Clamp(value, minimum, maximum)
    if maximum ~= nil and value > maximum then
        value = maximum
    end

    if minimum ~= nil and value < minimum then
        value = minimum
    end

    return value
end

local CHANNEL_BITS = 0xFF

--- A 0xRRGGBBAA colour in greyscale (Rec. 601 luma, as the grey icons are
--- made), keeping its alpha: for a display's background while its icon is
--- greyed, as it shows through the icon's transparent parts.
---@param colour integer
---@return integer
function maths.GreyColour(colour)
    local red, green, blue = (colour >> 24) & CHANNEL_BITS, (colour >> 16) & CHANNEL_BITS, (colour >> 8) & CHANNEL_BITS
    local luma = math.floor(0.299 * red + 0.587 * green + 0.114 * blue + 0.5)
    return (luma << 24) | (luma << 16) | (luma << 8) | (colour & CHANNEL_BITS)
end

return maths
