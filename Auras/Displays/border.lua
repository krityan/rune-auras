-- A rectangular border drawn inside a display's bounds, shared by the
-- display types. It's four separate edges rather than one filled rectangle
-- so a translucent border and whatever sits inside it don't stack where
-- they would overlap.
-- Usage:
--   local border = require("Auras/Displays/border")
--   self.border = border.new(self.root, colour)
--   self.border:Layout(width, height, thickness)
--   self.border:SetColour(colour)

local Border = {}
Border.__index = Border

function Border.new(parent, rgba)
    local self = setmetatable({ edges = {} }, Border)
    for index = 1, 4 do
        local edge = ui.Rectangle.new(parent)
        edge.fill = true
        edge.rgba = rgba
        edge.clickthrough = true
        self.edges[index] = edge
    end
    return self
end

function Border:Layout(width, height, thickness)
    local top, bottom, left, right = self.edges[1], self.edges[2], self.edges[3], self.edges[4]
    top:SetPos(0, 0)
    top:SetSize(width, thickness)
    bottom:SetPos(0, height - thickness)
    bottom:SetSize(width, thickness)
    left:SetPos(0, thickness)
    left:SetSize(thickness, height - thickness * 2)
    right:SetPos(width - thickness, thickness)
    right:SetSize(thickness, height - thickness * 2)
    for _, edge in ipairs(self.edges) do edge.hidden = thickness <= 0 end
end

function Border:SetColour(rgba)
    for _, edge in ipairs(self.edges) do edge.rgba = rgba end
end

return Border
