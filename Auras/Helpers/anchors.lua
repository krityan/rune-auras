-- Anchor points: the nine points of a box an aura is placed from, and the
-- conversions between anchored offsets and screen positions.

local anchors = {}

--- One of the nine anchor points. On screen, x/y measure inwards from it:
--- "topright" with x = 10, y = 10 sits 10 px in from the top-right corner,
--- and centred axes count right/down as positive.
---@alias AnchorID
---| "topleft"
---| "top"
---| "topright"
---| "left"
---| "centre"
---| "right"
---| "bottomleft"
---| "bottom"
---| "bottomright"

---@class Anchor
---@field id AnchorID
---@field label string Shown in the editor.
---@field h number Fraction of the free space left of the box: 0, 0.5 or 1.
---@field v number Fraction of the free space above the box.

---@type Anchor[]
local ANCHORS = {
    { id = "topleft", label = "Top left", h = 0, v = 0 },
    { id = "top", label = "Top", h = 0.5, v = 0 },
    { id = "topright", label = "Top right", h = 1, v = 0 },
    { id = "left", label = "Left", h = 0, v = 0.5 },
    { id = "centre", label = "Centre", h = 0.5, v = 0.5 },
    { id = "right", label = "Right", h = 1, v = 0.5 },
    { id = "bottomleft", label = "Bottom left", h = 0, v = 1 },
    { id = "bottom", label = "Bottom", h = 0.5, v = 1 },
    { id = "bottomright", label = "Bottom right", h = 1, v = 1 },
}

---@type table<AnchorID, Anchor>
local ANCHORS_BY_ID = {}
for _, anchor in ipairs(ANCHORS) do
    ANCHORS_BY_ID[anchor.id] = anchor
end

-- The fraction of an axis at its far edge (right or bottom).
local FAR_EDGE = 1
-- The fraction of an axis at its middle.
local MIDDLE = 0.5

---@type AnchorID
anchors.DEFAULT = "topleft"

--- Every anchor point, in the editor's order.
---@return Anchor[]
function anchors.List()
    return ANCHORS
end

--- An anchor point by id; the default for an unknown id.
---@param anchorID AnchorID?
---@return Anchor
function anchors.Get(anchorID)
    return ANCHORS_BY_ID[anchorID] or ANCHORS_BY_ID[anchors.DEFAULT]
end

--- Which way a positive offset moves along an axis: offsets point inwards
--- from the far edge.
---@param fraction number An Anchor's h or v.
---@return integer sign 1 (right/down) or -1 (left/up).
local function direction(fraction)
    return fraction == FAR_EDGE and -1 or 1
end

--- Rounds to the nearest whole pixel.
---@param value number
---@return integer
local function roundPixel(value)
    return math.floor(value + 0.5)
end

--- Which way a positive x and y move an aura on screen.
---@param anchorID AnchorID
---@return integer xSign 1 (right) or -1 (left).
---@return integer ySign 1 (down) or -1 (up).
function anchors.Direction(anchorID)
    local anchor = anchors.Get(anchorID)
    return direction(anchor.h), direction(anchor.v)
end

--- Converts an anchored offset to the box's top-left corner in its parent.
---@param anchorID AnchorID
---@param x number Offset, inwards from the anchor.
---@param y number
---@param width number Box size.
---@param height number
---@param parentWidth number
---@param parentHeight number
---@return integer left
---@return integer top
function anchors.ToScreen(anchorID, x, y, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local left = anchor.h * (parentWidth - width) + direction(anchor.h) * x
    local top = anchor.v * (parentHeight - height) + direction(anchor.v) * y
    return roundPixel(left), roundPixel(top)
end

--- Converts a box's top-left corner back to an offset from the anchor.
---@param anchorID AnchorID
---@param left number
---@param top number
---@param width number Box size.
---@param height number
---@param parentWidth number
---@param parentHeight number
---@return integer x
---@return integer y
function anchors.FromScreen(anchorID, left, top, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local x = (left - anchor.h * (parentWidth - width)) * direction(anchor.h)
    local y = (top - anchor.v * (parentHeight - height)) * direction(anchor.v)
    return roundPixel(x), roundPixel(y)
end

--- Places a box from a group's point. In a group the anchor is the point on
--- the box that attaches, and x/y are a plain offset (right and down) from
--- the group's point.
---@param anchorID AnchorID The box's attach point.
---@param x number Offset from the group's point.
---@param y number
---@param width number Box size.
---@param height number
---@param pointX number The group's point on screen.
---@param pointY number
---@return integer left
---@return integer top
function anchors.FromPoint(anchorID, x, y, width, height, pointX, pointY)
    local anchor = anchors.Get(anchorID)
    return roundPixel(pointX + x - anchor.h * width), roundPixel(pointY + y - anchor.v * height)
end

--- Converts a box's top-left corner back to an offset from a group's point
--- (see FromPoint).
---@param anchorID AnchorID The box's attach point.
---@param left number
---@param top number
---@param width number Box size.
---@param height number
---@param pointX number The group's point on screen.
---@param pointY number
---@return integer x
---@return integer y
function anchors.ToPoint(anchorID, left, top, width, height, pointX, pointY)
    local anchor = anchors.Get(anchorID)
    return roundPixel(left + anchor.h * width - pointX), roundPixel(top + anchor.v * height - pointY)
end

--- The offset range along one axis that keeps a box inside its parent.
---@param fraction number The anchor's h or v.
---@param freeSpace number Parent size minus box size.
---@return integer minimum
---@return integer maximum
local function axisRange(fraction, freeSpace)
    freeSpace = math.max(0, freeSpace)
    if fraction == MIDDLE then return -(freeSpace // 2), freeSpace // 2 end
    return 0, freeSpace
end

--- The offsets that keep a box fully inside its parent.
---@param anchorID AnchorID
---@param width number Box size.
---@param height number
---@param parentWidth number
---@param parentHeight number
---@return integer minX
---@return integer maxX
---@return integer minY
---@return integer maxY
function anchors.OffsetRange(anchorID, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local minX, maxX = axisRange(anchor.h, parentWidth - width)
    local minY, maxY = axisRange(anchor.v, parentHeight - height)
    return minX, maxX, minY, maxY
end

return anchors
