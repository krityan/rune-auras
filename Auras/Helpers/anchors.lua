-- Anchor points: the nine points of a box an aura is placed from, and the
-- conversions between anchored offsets and screen positions.

local anchors = {}

--- One of the nine anchor points. Offsets from it count right and up,
--- whatever the anchor: "topright" with x = -10, y = -10 sits 10 px in
--- from the top-right corner. A group's offsets, and a text node's on its
--- display, count the same way.
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

--- Rounds to the nearest whole pixel.
---@param value number
---@return integer
local function roundPixel(value)
    return math.floor(value + 0.5)
end

--- Converts between an offset (right and up) and the same distance in
--- screen pixels (right and down). It's its own inverse.
---@param x number
---@param y number
---@return number x
---@return number y
function anchors.ScreenDelta(x, y)
    return x, -y
end

--- Converts an offset saved inwards from its anchor (the old convention:
--- right/bottom anchors counted leftwards/upwards, the rest
--- rightwards/downwards) to one counting right and up.
---@param anchorID AnchorID?
---@param x number
---@param y number
---@return number x
---@return number y
function anchors.FromInwardOffset(anchorID, x, y)
    local anchor = anchors.Get(anchorID)
    local xSign = anchor.h == FAR_EDGE and -1 or 1
    local ySign = anchor.v == FAR_EDGE and 1 or -1
    return xSign * x, ySign * y
end

--- Converts an anchored offset to the box's top-left corner in its parent.
---@param anchorID AnchorID
---@param x number Offset from the anchor, right.
---@param y number Offset from the anchor, up.
---@param width number Box size.
---@param height number
---@param parentWidth number
---@param parentHeight number
---@return integer left
---@return integer top
function anchors.ToScreen(anchorID, x, y, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local left = anchor.h * (parentWidth - width) + x
    local top = anchor.v * (parentHeight - height) - y
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
    local x = left - anchor.h * (parentWidth - width)
    local y = anchor.v * (parentHeight - height) - top
    return roundPixel(x), roundPixel(y)
end

--- Places a box from a group's point. In a group the anchor is the point on
--- the box that attaches, and x/y are a plain offset (right and up) from
--- the group's point.
---@param anchorID AnchorID The box's attach point.
---@param x number Offset from the group's point, right.
---@param y number Offset from the group's point, up.
---@param width number Box size.
---@param height number
---@param pointX number The group's point on screen.
---@param pointY number
---@return integer left
---@return integer top
function anchors.FromPoint(anchorID, x, y, width, height, pointX, pointY)
    local anchor = anchors.Get(anchorID)
    return roundPixel(pointX + x - anchor.h * width), roundPixel(pointY - y - anchor.v * height)
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
    return roundPixel(left + anchor.h * width - pointX), roundPixel(pointY - top - anchor.v * height)
end

--- The offset range along one axis that keeps a box inside its parent,
--- counting towards the axis's far edge (right, or down on screen).
---@param fraction number The anchor's h or v.
---@param freeSpace number Parent size minus box size.
---@return integer minimum
---@return integer maximum
local function axisRange(fraction, freeSpace)
    freeSpace = math.max(0, freeSpace)
    if fraction == MIDDLE then return -(freeSpace // 2), freeSpace // 2 end
    if fraction == FAR_EDGE then return -freeSpace, 0 end
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
    -- Up is positive, so the screen's downward range turns over.
    local downMin, downMax = axisRange(anchor.v, parentHeight - height)
    return minX, maxX, -downMax, -downMin
end

return anchors
