-- Small number helpers shared by displays and controls.

local maths = {}

--- Keeps a value within a range. Where the limits cross, the minimum wins.
---@param value number
---@param minimum number? nil: no lower limit.
---@param maximum number? nil: no upper limit.
---@return number
function maths.Clamp(value, minimum, maximum)
    if maximum ~= nil and value > maximum then value = maximum end
    if minimum ~= nil and value < minimum then value = minimum end
    return value
end

return maths
