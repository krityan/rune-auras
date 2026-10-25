-- Segmented bar display: a row (or column) of small bars, one per stack,
-- each filled while that many are up: 5 stacks of Necrosis fill 5 of 12.
-- The box is the size of every segment, so the display doesn't move as
-- stacks come and go, except in a dynamic group with empty segments hidden,
-- where it shrinks to the filled ones so the group packs it to what's showing.

local Border = require("Auras/Displays/Parts/border")
local placement = require("Auras/Displays/Parts/placement")
local maths = require("Auras/Helpers/maths")
local growDirections = require("Auras/Helpers/grow-directions")
local rectangles = require("Auras/Displays/Parts/rectangles")

local clamp = maths.Clamp
local newRectangle = rectangles.Filled

--- A segmented bar aura's own options.
---@class SegmentsOptions: Aura
---@field segments integer How many: sources don't say how many stacks a buff can have.
---@field perRow integer Segments per row before wrapping; 0: never.
---@field grow GrowID From the box's matching edge, or from the middle outwards both ways (centred).
---@field segmentWidth number With sizeBy "segment".
---@field segmentHeight number
---@field sizeBy "segment"|"total" Size each segment, or fit a row into totalLength along the grow direction (so a condition changing the count keeps the length).
---@field totalLength number
---@field spacing number
---@field showEmpty boolean false hides the unfilled ones (all show while unlocked).
---@field backgroundColour integer
---@field borderColour integer
---@field borderThickness integer

--- One segment's components and place.
---@class SegmentPart
---@field layer userdata
---@field background userdata
---@field fill userdata
---@field frame Border? Made once it has a thickness.
---@field row integer 0-based.
---@field slot integer 0-based place along its row.
---@field rowCount integer How many its row holds (the last may be short).
---@field x number Its place in the full box, kept so fitBox can shift it.
---@field y number
---@field width number
---@field height number
---@field isFilled boolean?

---@class Segments: Placed
---@field backing userdata An unlocked display's tint, behind everything.
---@field parts SegmentPart[] Made as needed and reused.
local Segments = {}
Segments.__index = Segments
placement.Install(Segments)

-- The display sizes itself, so its aura's width/height are only nominal and
-- the editor reads its size from the aura manager (see auraSize in
-- UI/Editor/aura-editor).
Segments.sizesItself = true

Segments.defaults = {
    segments = 12,
    perRow = 0,
    grow = "right",
    segmentWidth = 30,
    segmentHeight = 12,
    sizeBy = "segment",
    totalLength = 300,
    spacing = 2,
    showEmpty = true,
    colour = 0x2ECC40FF,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000FF,
    borderThickness = 1,
    width = 100,
    height = 12,
}

-- For the editor (UI/Editor/Types/segments).
Segments.SIZE_BY = {
    { id = "segment", label = "Each segment" },
    { id = "total", label = "Total length" },
}
Segments.limits = {
    maxSegments = 30,
    minSize = 4, maxWidth = 300, maxHeight = 100,
    maxTotal = 1200,
    maxSpacing = 20,
    maxBorder = 4,
}

-- The border leaves at least this much inside the smallest segment.
local MIN_INNER_SIZE = 2

--- Creates a segmented bar for an aura. If the game runs out of interface
--- parts partway (see the aura manager), the root goes, taking whatever was
--- made in it, and the error is raised again.
---@param parent userdata
---@param aura SegmentsOptions
---@param groupPoint GroupPoint?
---@return Segments
function Segments.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Segments)
    self.root = ui.Layer.new(parent)
    local ok, problem = pcall(function()
        self.backing = newRectangle(self.root, placement.UNLOCKED_BACKGROUND_RGBA)
        self.backing:SetPos(0, 0)
        self.parts = {}
        self:bindDrag()
        self:Apply(aura)
    end)
    if not ok then
        self.root:Destroy()
        error(problem, 0)
    end
    return self
end

--- A segment's components, made if needed. Its border is made once it has a
--- thickness (the game has 4,096 interface parts in all).
---@param index integer
---@return SegmentPart
function Segments:segmentPart(index)
    local part = self.parts[index]
    if part == nil then
        local layer = ui.Layer.new(self.root)
        layer.clickthrough = true
        part = {
            layer = layer,
            background = newRectangle(layer, 0),
            fill = newRectangle(layer, 0),
        }
        self.parts[index] = part
    end
    return part
end

--- Where a segment starts along the grow direction, and how long it is: a
--- fixed size each, or a share of the total length with the remainder
--- spread so the row is exactly that long.
---@param slot integer 0-based place along the row.
---@param slots integer Segments per row.
---@param size number Each segment's length, without a total.
---@param total number? The row's length, with sizeBy "total".
---@param spacing number
---@return number start
---@return number length
local function slotSpan(slot, slots, size, total, spacing)
    if total == nil then return slot * (size + spacing), size end
    local start = (slot * (total + spacing)) // slots
    local finish = ((slot + 1) * (total + spacing)) // slots - spacing
    return start, math.max(1, finish - start)
end

--- An aura's segment count, how many go in a row and the spacing, within
--- the limits. perRow 0 (or more than the count) puts them all in one row.
---@param aura SegmentsOptions
---@return integer count
---@return integer perRow
---@return number spacing
local function rowOptions(aura)
    local limits = Segments.limits
    local count = clamp(math.floor(aura.segments or Segments.defaults.segments), 1, limits.maxSegments)
    local perRow = math.floor(aura.perRow or 0)
    if perRow <= 0 or perRow > count then perRow = count end
    local spacing = clamp(aura.spacing or Segments.defaults.spacing, 0, limits.maxSpacing)
    return count, perRow, spacing
end

--- The shortest a row can be with an aura's count, per row and spacing: a
--- pixel per segment plus the spacing. The display clamps totalLength to
--- it, and the editor's total length control starts there.
---@param aura SegmentsOptions
---@return integer
function Segments.MinimumTotal(aura)
    local _, perRow, spacing = rowOptions(aura)
    return math.min(Segments.limits.maxTotal, perRow + (perRow - 1) * spacing)
end

--- The layout every segment is placed from.
---@class SegmentLayout
---@field count integer
---@field perRow integer
---@field horizontal boolean
---@field centred boolean
---@field grow GrowID
---@field alongSize number Each segment's length along the grow direction.
---@field acrossSize number
---@field spacing number
---@field total number? With sizeBy "total".
---@field rowLength number
---@field border integer

--- Works out the layout from an aura's options, and sizes the full box.
---@param aura SegmentsOptions
---@return SegmentLayout
function Segments:computeLayout(aura)
    local limits = Segments.limits
    local count, perRow, spacing = rowOptions(aura)
    local segmentWidth = clamp(aura.segmentWidth or Segments.defaults.segmentWidth, limits.minSize, limits.maxWidth)
    local segmentHeight = clamp(aura.segmentHeight or Segments.defaults.segmentHeight, limits.minSize, limits.maxHeight)
    local grow = aura.grow or Segments.defaults.grow
    local horizontal = growDirections.IsHorizontal(grow)

    -- Along the grow direction a row holds perRow; rows stack across it.
    local rows = (count + perRow - 1) // perRow
    local alongSize = horizontal and segmentWidth or segmentHeight
    local acrossSize = horizontal and segmentHeight or segmentWidth
    local total = nil
    if aura.sizeBy == "total" then
        total = clamp(math.floor(aura.totalLength or Segments.defaults.totalLength), Segments.MinimumTotal(aura),
            limits.maxTotal)
    end
    local rowLength = total or (perRow * alongSize + (perRow - 1) * spacing)
    local acrossLength = rows * acrossSize + (rows - 1) * spacing
    -- The full box; redraw shrinks it to the filled segments in a dynamic
    -- group with empty ones hidden (see fitBox).
    self.fullWidth = horizontal and rowLength or acrossLength
    self.fullHeight = horizontal and acrossLength or rowLength
    self.width, self.height = self.fullWidth, self.fullHeight
    self.root:SetSize(self.width, self.height)
    self.backing:SetSize(self.width, self.height)

    local _, firstLength = slotSpan(0, perRow, alongSize, total, spacing)
    local smallest = math.min(acrossSize, firstLength)
    local thickestBorder = math.min(limits.maxBorder, (smallest - MIN_INNER_SIZE) // 2)
    return {
        count = count, perRow = perRow, horizontal = horizontal, centred = growDirections.IsCentred(grow), grow = grow,
        alongSize = alongSize, acrossSize = acrossSize, spacing = spacing, total = total, rowLength = rowLength,
        border = clamp(aura.borderThickness or Segments.defaults.borderThickness, 0, thickestBorder),
    }
end

--- Where a segment starts along the grow direction, and how long it is,
--- for its place in the layout. A short last row of a centred bar sits in
--- the middle of the full row.
---@param layout SegmentLayout
---@param slot integer
---@param rowCount integer
---@return number start
---@return number length
local function alongSpan(layout, slot, rowCount)
    local perRow, alongSize, total, spacing = layout.perRow, layout.alongSize, layout.total, layout.spacing
    if layout.centred then
        local lastStart, lastLength = slotSpan(rowCount - 1, perRow, alongSize, total, spacing)
        local offset = (layout.rowLength - (lastStart + lastLength)) // 2
        local start, length = slotSpan(slot, perRow, alongSize, total, spacing)
        return start + offset, length
    end
    if growDirections.IsBackwards(layout.grow) then slot = perRow - 1 - slot end
    return slotSpan(slot, perRow, alongSize, total, spacing)
end

--- Places and styles one segment.
---@param index integer
---@param layout SegmentLayout
---@param aura SegmentsOptions
function Segments:layoutSegment(index, layout, aura)
    local part = self:segmentPart(index)
    local perRow, border = layout.perRow, layout.border
    local slot = (index - 1) % perRow
    local row = (index - 1) // perRow
    local rowCount = math.min(perRow, layout.count - row * perRow)
    part.row, part.slot, part.rowCount = row, slot, rowCount
    local alongStart, alongLength = alongSpan(layout, slot, rowCount)
    local acrossStart = row * (layout.acrossSize + layout.spacing)
    local x, y, width, height = alongStart, acrossStart, alongLength, layout.acrossSize
    if not layout.horizontal then x, y, width, height = acrossStart, alongStart, layout.acrossSize, alongLength end
    part.x, part.y, part.width, part.height = x, y, width, height
    part.layer:SetPos(x, y)
    part.layer:SetSize(width, height)
    if part.frame == nil and border > 0 then part.frame = Border.new(part.layer, 0) end
    if part.frame ~= nil then
        part.frame:Layout(width, height, border)
        part.frame:SetColour(aura.borderColour)
    end
    part.background:SetPos(border, border)
    part.background:SetSize(width - border * 2, height - border * 2)
    part.background.rgba = aura.backgroundColour
    part.fill:SetPos(border, border)
    part.fill:SetSize(width - border * 2, height - border * 2)
    part.fill.rgba = aura.colour
    part.layer.hidden = false
end

--- Lays the segments out and restyles them from the aura.
---@param aura SegmentsOptions
function Segments:Apply(aura)
    local layout = self:computeLayout(aura)
    for index = 1, layout.count do self:layoutSegment(index, layout, aura) end
    for index = layout.count + 1, #self.parts do self.parts[index].layer.hidden = true end
    self.count, self.perRow, self.centred = layout.count, layout.perRow, layout.centred
    self.showEmpty = aura.showEmpty ~= false
    self:place(aura)
    self:setMovable(aura.unlocked)
    self.backing.hidden = not self.movable
    -- Redrawn for the new layout.
    self.filled = nil
    self:redraw()
end

--- Shows how many segments are filled: the source's stacks (for a buff) or
--- charges (for an ability), else its current value, whole.
---@param curr number?
---@param stacks number?
function Segments:SetValue(curr, _, _, stacks)
    local filled = stacks
    if filled == nil and curr ~= nil then filled = math.floor(curr) end
    filled = math.max(0, filled or 0)
    -- The aura manager marks it layoutManaged after it's made, so a change
    -- of that redraws too.
    local isManaged = self.layoutManaged == true
    if filled == self.value and isManaged == self.drawnManaged then return end
    self.value = filled
    self:redraw()
end

--- Sizes the box to the filled segments or to all of them, moving the
--- segments so the box starts at 0, 0: with backwards or centred growth the
--- filled ones don't start at the box's corner.
---@param toFilled boolean Fit to the filled ones (when some but not all are).
function Segments:fitBox(toFilled)
    local minX, minY, maxX, maxY = 0, 0, self.fullWidth, self.fullHeight
    local someFilled = self.filled > 0 and self.filled < self.count
    if toFilled and someFilled then
        minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        for index = 1, self.count do
            local part = self.parts[index]
            if part.isFilled then
                minX, minY = math.min(minX, part.x), math.min(minY, part.y)
                maxX, maxY = math.max(maxX, part.x + part.width), math.max(maxY, part.y + part.height)
            end
        end
    end
    for index = 1, self.count do
        local part = self.parts[index]
        part.layer:SetPos(part.x - minX, part.y - minY)
    end
    local width, height = maxX - minX, maxY - minY
    if width ~= self.width or height ~= self.height then
        self.width, self.height = width, height
        self.root:SetSize(width, height)
        self.backing:SetSize(width, height)
    end
end

--- Whether a segment is filled. Rows fill in order; centred, the filled
--- ones in the row being filled are its middle segments.
---@param index integer
---@param part SegmentPart
---@param filled integer
---@return boolean
function Segments:isSegmentFilled(index, part, filled)
    if not self.centred then return index <= filled end
    local filledInRow = math.max(0, math.min(part.rowCount, filled - part.row * self.perRow))
    local firstFilled = (part.rowCount - filledInRow) // 2
    return part.slot >= firstFilled and part.slot < firstFilled + filledInRow
end

--- Shows the filled segments, and the empty ones unless hidden.
function Segments:redraw()
    local filled = math.min(self.value or 0, self.count)
    local isManaged = self.layoutManaged == true
    if filled == self.filled and isManaged == self.drawnManaged then return end
    self.filled, self.drawnManaged = filled, isManaged
    -- Unlocked, every segment shows, so the whole display can be found.
    local showEmpty = self.showEmpty or self.movable
    for index = 1, self.count do
        local part = self.parts[index]
        local isFilled = self:isSegmentFilled(index, part, filled)
        part.isFilled = isFilled
        part.fill.hidden = not isFilled
        part.layer.hidden = not (isFilled or showEmpty)
    end
    -- In a dynamic group with empty segments hidden, only the filled ones
    -- take up room, so the group packs it to them. Anywhere else the box
    -- stays full size, so an anchored bar doesn't move as stacks change.
    self:fitBox(isManaged and not showEmpty)
    -- With nothing to draw it hides itself (as Bar's Hide when empty does),
    -- so a dynamic group closes up around it and a condition's Hide can
    -- still override it.
    self:setHidden(filled == 0 and not showEmpty)
end

--- Destroys the display and everything in it.
function Segments:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Segments
