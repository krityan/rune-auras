-- Dynamic group display: a group (Auras/Displays/group) that lays out its
-- contents itself rather than leaving them at their own positions. They
-- grow from its point, placed as a group's is; the auras showing (see
-- auraManager: loaded, and not hiding themselves, e.g. an inactive buff set
-- to hide) are lined up from there in list order, so one that hides lets
-- the rest close up.
-- Grows (`grow`): right, left, down, up, or centred horizontally or
-- vertically on the point; `spacing` pixels apart; `align` lines them up
-- across that direction (start: top or left, centre, end: bottom or right).

local Group = require("Auras/Displays/group")

local DynamicGroup = setmetatable({}, { __index = Group })
DynamicGroup.__index = DynamicGroup

DynamicGroup.defaults = {
    grow = "right",
    spacing = 4,
    align = "centre",
}

-- For the editor (UI/Editors/dynamic-group).
DynamicGroup.GROW = {
    { id = "right", label = "Right" },
    { id = "left", label = "Left" },
    { id = "down", label = "Down" },
    { id = "up", label = "Up" },
    { id = "horizontal", label = "Centred, horizontally" },
    { id = "vertical", label = "Centred, vertically" },
}
DynamicGroup.ALIGN = {
    { id = "start", label = "Start (top or left)" },
    { id = "centre", label = "Centre" },
    { id = "end", label = "End (bottom or right)" },
}
DynamicGroup.limits = { maxSpacing = 100 }

local HORIZONTAL = { right = true, left = true, horizontal = true }

function DynamicGroup.new(parent, aura, groupPoint)
    return Group.new(parent, aura, groupPoint, DynamicGroup)
end

function DynamicGroup:Apply(aura)
    Group.Apply(self, aura)
    self.grow = aura.grow or DynamicGroup.defaults.grow
    self.spacing = aura.spacing or DynamicGroup.defaults.spacing
    self.align = aura.align or DynamicGroup.defaults.align
    -- Lay out again with the new settings.
    self.laidOutCount = nil
end

-- Where a display goes across the grow direction, from its size along that
-- axis and the origin's coordinate on it.
local function across(align, origin, size)
    if align == "start" then return origin end
    if align == "end" then return origin - size end
    return origin - size // 2
end

-- Lines up `displays[1..count]` (the contents showing, in list order).
-- Returns whether anything moved, so the manager can redraw the group's box.
function DynamicGroup:Layout(displays, count)
    local horizontal = HORIZONTAL[self.grow] == true
    local spacing = self.spacing
    -- How far the row reaches along the grow direction.
    local total = spacing * math.max(0, count - 1)
    for index = 1, count do
        local display = displays[index]
        total = total + (horizontal and display.width or display.height)
    end
    local originAlong = horizontal and self.point.x or self.point.y
    local originAcross = horizontal and self.point.y or self.point.x
    local cursor = originAlong
    if self.grow == "horizontal" or self.grow == "vertical" then cursor = originAlong - total // 2 end
    local backwards = self.grow == "left" or self.grow == "up"
    local moved = count ~= self.laidOutCount
    self.laidOutCount = count
    for index = 1, count do
        local display = displays[index]
        local along = horizontal and display.width or display.height
        local position = backwards and cursor - along or cursor
        cursor = backwards and position - spacing or position + along + spacing
        local cross = across(self.align, originAcross, horizontal and display.height or display.width)
        local x, y = position, cross
        if not horizontal then x, y = cross, position end
        if display.root.x ~= x or display.root.y ~= y then moved = true end
        display:SetLayoutPos(x, y)
    end
    return moved
end

return DynamicGroup
