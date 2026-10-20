-- Anchor points for placing an aura in the game area. An aura's x/y is an
-- offset from its anchor, measured inwards: "Top right" with x = 10, y = 10
-- sits 10 pixels in from the top-right corner. Centred axes measure
-- right/down as positive.
-- Usage: local anchors = require("Auras/anchors")

local anchors = {}

-- h/v are the fraction of the free space to the left of/above the aura.
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

local ANCHORS_BY_ID = {}
for _, anchor in ipairs(ANCHORS) do
    ANCHORS_BY_ID[anchor.id] = anchor
end

anchors.DEFAULT = "topleft"

function anchors.List()
    return ANCHORS
end

function anchors.Get(anchorID)
    return ANCHORS_BY_ID[anchorID] or ANCHORS_BY_ID[anchors.DEFAULT]
end

-- Offsets point inwards from right/bottom edges.
local function direction(fraction)
    return fraction == 1 and -1 or 1
end

-- Which way a positive x and y move the aura on screen (1: right/down,
-- -1: left/up), as offsets point inwards from right and bottom edges.
function anchors.Direction(anchorID)
    local anchor = anchors.Get(anchorID)
    return direction(anchor.h), direction(anchor.v)
end

-- Converts an anchored offset to the aura's top-left corner in the parent.
function anchors.ToScreen(anchorID, x, y, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local left = anchor.h * (parentWidth - width) + direction(anchor.h) * x
    local top = anchor.v * (parentHeight - height) + direction(anchor.v) * y
    return math.floor(left + 0.5), math.floor(top + 0.5)
end

-- Converts the aura's top-left corner back to an offset from the anchor.
function anchors.FromScreen(anchorID, left, top, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local x = (left - anchor.h * (parentWidth - width)) * direction(anchor.h)
    local y = (top - anchor.v * (parentHeight - height)) * direction(anchor.v)
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

-- The offsets that keep the aura fully on screen, as minX, maxX, minY, maxY.
function anchors.OffsetRange(anchorID, width, height, parentWidth, parentHeight)
    local anchor = anchors.Get(anchorID)
    local function axis(fraction, space)
        space = math.max(0, space)
        if fraction == 0.5 then return -(space // 2), space // 2 end
        return 0, space
    end
    local minX, maxX = axis(anchor.h, parentWidth - width)
    local minY, maxY = axis(anchor.v, parentHeight - height)
    return minX, maxX, minY, maxY
end

return anchors
