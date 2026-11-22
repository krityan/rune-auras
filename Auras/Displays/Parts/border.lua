-- A rectangular border inside a display's bounds, shared by the display
-- types: one outline rectangle drawn inwards by its thickness.

local rectangles = require("Auras/Displays/Parts/rectangles")

local Border = {}
Border.__index = Border

function Border.new(parent, rgba)
    local self = setmetatable({}, Border)
    local outline = rectangles.Outline(parent, rgba)
    outline:SetPos(0, 0)
    self.outline = outline
    return self
end

function Border:Layout(width, height, thickness)
    local outline = self.outline
    outline:SetPos(0, 0)
    outline:SetSize(width, height)
    -- Positive thickness draws inwards, inside the bounds.
    outline.outlineThickness = math.max(1, thickness)
    outline.hidden = thickness <= 0
end

function Border:SetColour(rgba)
    self.outline.rgba = rgba
end

return Border
