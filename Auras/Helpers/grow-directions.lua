-- Grow directions: which way a row of things fills from its start, for a
-- Segmented bar's segments and a dynamic group's auras.

---@alias GrowID
---| "right"      # from the left edge, rightwards
---| "left"       # from the right edge, leftwards
---| "down"       # from the top edge, downwards
---| "up"         # from the bottom edge, upwards
---| "horizontal" # from the middle outwards, both ways along a row
---| "vertical"   # from the middle outwards, both ways down a column

local growDirections = {}

-- In order, for the editors' Grow choice.
growDirections.CHOICES = {
    { id = "right", label = "Right" },
    { id = "left", label = "Left" },
    { id = "down", label = "Down" },
    { id = "up", label = "Up" },
    { id = "horizontal", label = "Centred, horizontally" },
    { id = "vertical", label = "Centred, vertically" },
}

local HORIZONTAL = { right = true, left = true, horizontal = true }
local CENTRED = { horizontal = true, vertical = true }
local BACKWARDS = { left = true, up = true }

--- Whether it grows along a row rather than down a column.
---@param growID GrowID
---@return boolean
function growDirections.IsHorizontal(growID)
    return HORIZONTAL[growID] == true
end

--- Whether it fills from the middle outwards both ways.
---@param growID GrowID
---@return boolean
function growDirections.IsCentred(growID)
    return CENTRED[growID] == true
end

--- Whether it starts from the far edge (right or bottom).
---@param growID GrowID
---@return boolean
function growDirections.IsBackwards(growID)
    return BACKWARDS[growID] == true
end

return growDirections
