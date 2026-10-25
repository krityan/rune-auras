-- Dynamic group display: a group that lays out its contents itself rather
-- than leaving them at their own positions. They grow from its point,
-- placed as a group's is; the auras showing are lined up from there in list
-- order, so one that hides lets the rest close up.

local Group = require("Auras/Displays/group")
local growDirections = require("Auras/Helpers/grow-directions")

--- A dynamic group's own options.
---@class DynamicGroupOptions: Aura
---@field grow GrowID Which way they grow; or centred on the point.
---@field spacing number Pixels apart.
---@field align "start"|"centre"|"end" How they line up across the grow direction (start: top or left).

---@class DynamicGroup: Group
---@field grow GrowID
---@field spacing number
---@field align "start"|"centre"|"end"
---@field laidOutCount integer? What the last layout was, to tell whether anything moved.
---@field laidOutTotal number?
---@field laidOutThickest number?
local DynamicGroup = setmetatable({}, { __index = Group })
DynamicGroup.__index = DynamicGroup

DynamicGroup.defaults = {
    grow = "right",
    spacing = 4,
    align = "centre",
}

-- For the editor (UI/Editor/Types/dynamic-group).
DynamicGroup.ALIGN = {
    { id = "start", label = "Start (top or left)" },
    { id = "centre", label = "Centre" },
    { id = "end", label = "End (bottom or right)" },
}
DynamicGroup.limits = { maxSpacing = 100 }

--- Creates a dynamic group's display.
---@param parent userdata
---@param aura DynamicGroupOptions
---@param groupPoint GroupPoint?
---@return DynamicGroup
function DynamicGroup.new(parent, aura, groupPoint)
    return Group.new(parent, aura, groupPoint, DynamicGroup)
end

--- Applies the group's options, so the next Layout lines its contents up again.
---@param aura DynamicGroupOptions
function DynamicGroup:Apply(aura)
    Group.Apply(self, aura)
    self.grow = aura.grow or DynamicGroup.defaults.grow
    self.spacing = aura.spacing or DynamicGroup.defaults.spacing
    self.align = aura.align or DynamicGroup.defaults.align
    self.laidOutCount = nil
end

--- Where a display goes across the grow direction.
---@param align string
---@param origin number The point's coordinate on that axis.
---@param size number The display's size along that axis.
---@return number
local function acrossPosition(align, origin, size)
    if align == "start" then return origin end
    if align == "end" then return origin - size end
    return origin - size // 2
end

--- Lines up the contents showing (mounted, loaded, and not hiding
--- themselves), in list order.
---@param displays Placed[] The displays showing, from 1.
---@param count integer How many of them to lay out.
---@return boolean moved Whether anything moved or resized, so the manager can redraw the group's box.
function DynamicGroup:Layout(displays, count)
    local horizontal = growDirections.IsHorizontal(self.grow)
    local spacing = self.spacing
    -- How far the row reaches along the grow direction.
    local total = spacing * math.max(0, count - 1)
    local thickest = 0
    for index = 1, count do
        local display = displays[index]
        total = total + (horizontal and display.width or display.height)
        thickest = math.max(thickest, horizontal and display.height or display.width)
    end
    local originAlong = horizontal and self.point.x or self.point.y
    local originAcross = horizontal and self.point.y or self.point.x
    local cursor = originAlong
    if growDirections.IsCentred(self.grow) then cursor = originAlong - total // 2 end
    local backwards = growDirections.IsBackwards(self.grow)
    -- A display can change size without anything moving (a segmented bar
    -- at the end shrinking to its filled segments), so the bounds are
    -- refreshed then too.
    local moved = count ~= self.laidOutCount or total ~= self.laidOutTotal or thickest ~= self.laidOutThickest
    self.laidOutCount, self.laidOutTotal, self.laidOutThickest = count, total, thickest
    for index = 1, count do
        local display = displays[index]
        local alongSize = horizontal and display.width or display.height
        local alongStart = backwards and cursor - alongSize or cursor
        cursor = backwards and alongStart - spacing or alongStart + alongSize + spacing
        local acrossStart = acrossPosition(self.align, originAcross, horizontal and display.height or display.width)
        local x, y = alongStart, acrossStart
        if not horizontal then x, y = acrossStart, alongStart end
        if display.root.x ~= x or display.root.y ~= y then moved = true end
        display:SetLayoutPos(x, y)
    end
    return moved
end

return DynamicGroup
