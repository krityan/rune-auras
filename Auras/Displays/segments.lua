-- Segmented bar display: a row (or column) of small bars, one per stack,
-- each filled while that many are up: 5 stacks of Necrosis fill 5 of 12.
-- For a cooldown, one per charge, and the next charge's segment fills as it
-- recharges, with an optional text of the aura's template.
-- The box is the size of every segment, so the display doesn't move as
-- stacks come and go, except in a dynamic group with empty segments hidden,
-- where it shrinks to the filled ones so the group packs it to what's showing.

local Border = require("Auras/Displays/Parts/border")
local dataSources = require("Auras/Registries/data-sources")
local TextNodes = require("Auras/Displays/Parts/text-nodes")
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
---@field showProgressText boolean For a cooldown, show the aura's text template on the recharging segment.
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
---@field border integer
---@field innerWidth number Inside the border, where the fill goes.
---@field innerHeight number
---@field horizontal boolean Fills along x (see fillPartway).
---@field backwards boolean Fills from the far end.
---@field x number Its place in the full box, kept so fitBox can shift it.
---@field y number
---@field width number
---@field height number
---@field isFilled boolean? Filled, or recharging (for fitBox).

---@class Segments: Placed
---@field backing userdata An unlocked display's tint, behind everything.
---@field parts SegmentPart[] Made as needed and reused.
---@field texts TextNodes The progress text: drawn beside the root (see Placed.overlay), over the recharging segment.
---@field textList TextNode[] The progress text's one node, or none.
local Segments = {}
Segments.__index = Segments
placement.Mixin(Segments)

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
    showProgressText = false,
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
        self.texts = TextNodes.new(parent)
        self.overlay = self.texts
        self:bindDrag()
        self:Apply(aura)
    end)
    if not ok then
        self.root:Destroy()
        if self.texts ~= nil then self.texts:Destroy() end
        error(problem, 0)
    end
    return self
end

--- Whether a source's segments recharge: a cooldown's charges fill them,
--- and its time the next one.
---@param source DataSource?
---@return boolean
function Segments.Recharges(source)
    return source ~= nil and source.state == "cooldown" and source.timed == true
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

--- Fills part of a segment along the grow direction, from the end it grows
--- from.
---@param part SegmentPart
---@param progress number 0 to 1.
local function fillPartway(part, progress)
    local fill = part.fill
    local innerWidth, innerHeight = part.innerWidth, part.innerHeight
    local width, height = innerWidth, innerHeight
    if part.horizontal then
        width = math.floor(innerWidth * progress + 0.5)
    else
        height = math.floor(innerHeight * progress + 0.5)
    end
    local x, y = part.border, part.border
    if part.backwards and part.horizontal then x = x + innerWidth - width end
    if part.backwards and not part.horizontal then y = y + innerHeight - height end
    fill:SetPos(x, y)
    fill:SetSize(width, height)
    fill.hidden = width <= 0 or height <= 0
end

--- Gives a segment its whole fill back, after recharging.
---@param part SegmentPart
local function fillWhole(part)
    part.fill:SetPos(part.border, part.border)
    part.fill:SetSize(part.innerWidth, part.innerHeight)
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
    part.border, part.innerWidth, part.innerHeight = border, width - border * 2, height - border * 2
    part.horizontal, part.backwards = layout.horizontal, growDirections.IsBackwards(layout.grow)
    fillWhole(part)
    part.fill.rgba = aura.colour
    part.layer.hidden = false
end

--- The progress text's node, from the aura's own text options, centred on
--- the recharging segment; none unless it's wanted.
---@param aura SegmentsOptions
---@return TextNode[]
function Segments:progressTexts(aura)
    if not (self.recharges and aura.showProgressText == true) then return {} end
    return { {
        key = 1,
        showText = true,
        textTemplate = aura.textTemplate,
        textColour = aura.textColour,
        textFont = aura.textFont,
        textSize = aura.textSize,
        limitDecimals = aura.limitDecimals,
        decimalsBelow = aura.decimalsBelow,
        anchor = "centre",
        x = 0,
        y = 0,
    } }
end

--- Lays the segments out and restyles them from the aura.
---@param aura SegmentsOptions
function Segments:Apply(aura)
    local layout = self:computeLayout(aura)
    for index = 1, layout.count do self:layoutSegment(index, layout, aura) end
    for index = layout.count + 1, #self.parts do self.parts[index].layer.hidden = true end
    self.count, self.perRow, self.centred = layout.count, layout.perRow, layout.centred
    self.showEmpty = aura.showEmpty ~= false
    self.recharges = Segments.Recharges(dataSources.Get(aura.source))
    self.textList = self:progressTexts(aura)
    -- Laid out on the recharging segment by the next redraw.
    self.textPart = nil
    self:place(aura)
    self:setMovable(aura.unlocked)
    self.backing.hidden = not self.movable
    -- Redrawn for the new layout.
    self.filled = nil
    self:redraw()
end

--- Shows how many segments are filled: the source's stacks (for a buff) or
--- charges (for an ability), else its current value, whole. For a
--- cooldown, the next charge's segment fills by how far it has recharged.
---@param curr number?
---@param max number?
---@param fillCurr number? The unrounded time left, for a smooth fill.
---@param stacks number?
function Segments:SetValue(curr, max, fillCurr, stacks)
    local filled = stacks
    if filled == nil and curr ~= nil then filled = math.floor(curr) end
    filled = math.max(0, filled or 0)
    local progress = nil
    local isRecharging = self.recharges and curr ~= nil and curr > 0 and max ~= nil and max > 0
    if isRecharging then progress = clamp(1 - (fillCurr or curr) / max, 0, 1) end
    self.curr, self.max, self.stacks = curr, max, stacks
    -- The aura manager marks it layoutManaged after it's made, so a change
    -- of that redraws too.
    local isManaged = self.layoutManaged == true
    local unchanged = filled == self.value and progress == self.progress
    if not (unchanged and isManaged == self.drawnManaged) then
        self.value, self.progress = filled, progress
        self:redraw()
    end
    self:drawText()
end

--- The source's name, for $name and $arrow in the progress text.
---@param name string?
---@param spriteID integer?
---@param objectID integer?
---@param arrow string?
function Segments:SetDetails(name, spriteID, objectID, arrow)
    self.name, self.arrow = name, arrow
end

--- Fills the progress text while a charge is recharging; it only reformats
--- when its values change (see TextNodes:SetValues).
function Segments:drawText()
    local isShown = self.progress ~= nil
    self.texts:SetValues(self.curr, self.max, self.stacks, self.name, self.arrow, isShown, "")
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

--- The segment the next charge fills: the one filling one more would add.
---@param filled integer
---@return integer? index nil when every segment is filled.
function Segments:nextSegment(filled)
    if filled >= self.count then return nil end
    for index = 1, self.count do
        local part = self.parts[index]
        if self:isSegmentFilled(index, part, filled + 1) and not self:isSegmentFilled(index, part, filled) then
            return index
        end
    end
    return nil
end

--- Lays the progress text out on the recharging segment, when that changed
--- (its size can differ by segment, and fitBox moves them).
---@param part SegmentPart?
function Segments:placeText(part)
    if part == nil then return end
    if part ~= self.textPart then
        self.textPart = part
        self.texts:Apply(self.textList, part.width, part.height)
    end
    self.overlayX, self.overlayY = part.layer.x, part.layer.y
    self:syncOverlay()
end

--- Shows the filled segments, the recharging one, and the empty ones
--- unless hidden.
function Segments:redraw()
    local filled = math.min(self.value or 0, self.count)
    local isManaged = self.layoutManaged == true
    local progress = self.progress
    if filled == self.filled and progress == self.drawnProgress and isManaged == self.drawnManaged then return end
    -- Most steps while recharging only move the recharging segment's fill.
    local onlyRecharged = filled == self.filled and isManaged == self.drawnManaged
        and progress ~= nil and self.drawnProgress ~= nil
    self.drawnProgress = progress
    if onlyRecharged then
        -- None when every segment is already filled (fewer than the charges).
        if self.partwayIndex ~= nil then fillPartway(self.parts[self.partwayIndex], progress) end
        return
    end
    self.filled, self.drawnManaged = filled, isManaged
    -- Unlocked, every segment shows, so the whole display can be found.
    local showEmpty = self.showEmpty or self.movable
    local rechargingIndex = progress and self:nextSegment(filled) or nil
    if self.partwayIndex ~= nil and self.partwayIndex ~= rechargingIndex then
        fillWhole(self.parts[self.partwayIndex])
    end
    self.partwayIndex = rechargingIndex
    for index = 1, self.count do
        local part = self.parts[index]
        local isFilled = self:isSegmentFilled(index, part, filled)
        local isRecharging = index == rechargingIndex
        part.isFilled = isFilled or isRecharging
        part.fill.hidden = not isFilled
        part.layer.hidden = not (isFilled or isRecharging or showEmpty)
        if isRecharging then fillPartway(part, progress) end
    end
    -- In a dynamic group with empty segments hidden, only the filled ones
    -- take up room, so the group packs it to them. Anywhere else the box
    -- stays full size, so an anchored bar doesn't move as stacks change.
    self:fitBox(isManaged and not showEmpty)
    self:placeText(rechargingIndex and self.parts[rechargingIndex])
    -- With nothing to draw it hides itself (as Bar's Hide when empty does),
    -- so a dynamic group closes up around it and a condition's Hide can
    -- still override it.
    self:setHidden(filled == 0 and rechargingIndex == nil and not showEmpty)
end

--- Destroys the display and everything in it.
function Segments:Destroy()
    self.root:Destroy()
    self.root = nil
    self.texts:Destroy()
end

return Segments
