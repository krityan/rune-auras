-- Segmented bar display: a row (or column) of small bars, one per stack,
-- each filled while that many are up: 5 stacks of Necrosis fill 5 of 12.
-- The count is the source's stacks (a buff's) or charges (an ability's),
-- else its current value, whole. How many segments there are is the
-- aura's `segments`, as sources don't say how many stacks a buff can have.
-- They grow `grow` (right, left, down or up) from the box's matching edge,
-- or from the middle outwards both ways (horizontal, vertical: centred),
-- wrapping onto another row (or column) every `perRow` (0: never), and
-- `showEmpty` off hides the unfilled ones. `sizeBy` "segment" sizes each
-- segment (segmentWidth/Height); "total" fits a row into `totalLength`
-- along the grow direction instead, so changing the count (e.g. through a
-- condition) keeps the row the same length. The box is the size of all of
-- them either way, so the display doesn't move as stacks come and go; it
-- sizes itself (sizesItself), so its aura's width/height are only nominal.
-- The exception is a dynamic group with empty segments hidden: there the
-- box shrinks to the filled ones, so the group packs it to what's showing.
-- When the aura is unlocked it can be dragged around.

local Border = require("Auras/Displays/border")
local placement = require("Auras/Displays/placement")

local Segments = {}
Segments.__index = Segments
placement.Install(Segments)

-- The editor reads its size from the aura manager (see auraSize in
-- UI/Windows/aura-editor).
Segments.sizesItself = true

Segments.defaults = {
    segments = 12,
    -- Segments per row before wrapping (0: never).
    perRow = 0,
    grow = "right",
    segmentWidth = 30,
    segmentHeight = 12,
    -- "segment" or "total" (see above).
    sizeBy = "segment",
    totalLength = 300,
    spacing = 2,
    showEmpty = true,
    colour = 0x2ECC40FF,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000FF,
    borderThickness = 1,
    -- Nominal; the display sizes itself to its segments.
    width = 100,
    height = 12,
}

-- For the editor (UI/Editors/segments).
Segments.SIZE_BY = {
    { id = "segment", label = "Each segment" },
    { id = "total", label = "Total length" },
}
Segments.GROW = {
    { id = "right", label = "Right" },
    { id = "left", label = "Left" },
    { id = "down", label = "Down" },
    { id = "up", label = "Up" },
    { id = "horizontal", label = "Centred, horizontally" },
    { id = "vertical", label = "Centred, vertically" },
}
Segments.limits = {
    maxSegments = 30,
    minSize = 4, maxWidth = 300, maxHeight = 100,
    maxTotal = 1200,
    maxSpacing = 20,
    maxBorder = 4,
}

local HORIZONTAL = { right = true, left = true, horizontal = true }
-- Centred growth fills from the middle of each row outwards.
local CENTRED = { horizontal = true, vertical = true }

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function newRectangle(parent, rgba)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.fill = true
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

function Segments.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Segments)
    self.root = ui.Layer.new(parent)
    -- The game can run out of interface parts partway through (see the
    -- aura manager); then the root goes, taking whatever was made in it,
    -- and the error is passed on.
    local ok, problem = pcall(function()
        -- An unlocked display's tint, behind everything, so it's easy to find.
        self.backing = newRectangle(self.root, placement.UNLOCKED_BACKGROUND_RGBA)
        self.backing:SetPos(0, 0)
        -- Made as needed and reused: { layer, background, fill, frame }.
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

function Segments:segmentPart(index)
    local part = self.parts[index]
    if part == nil then
        local layer = ui.Layer.new(self.root)
        layer.clickthrough = true
        part = {
            layer = layer,
            background = newRectangle(layer, 0),
            fill = newRectangle(layer, 0),
            -- frame: its border, made once it has a thickness (four edges
            -- a segment, and the game has 4,096 interface parts in all).
        }
        self.parts[index] = part
    end
    return part
end

-- Where segment `slot` (0-based along a row) starts along the grow
-- direction, and how long it is: a fixed size each, or a share of the total
-- length with the remainder spread so the row is exactly that long.
local function slotSpan(slot, slots, size, total, spacing)
    if total == nil then return slot * (size + spacing), size end
    local start = (slot * (total + spacing)) // slots
    local finish = ((slot + 1) * (total + spacing)) // slots - spacing
    return start, math.max(1, finish - start)
end

function Segments:Apply(aura)
    local limits = Segments.limits
    local count = clamp(math.floor(aura.segments or Segments.defaults.segments), 1, limits.maxSegments)
    local perRow = math.floor(aura.perRow or 0)
    if perRow <= 0 or perRow > count then perRow = count end
    local width = clamp(aura.segmentWidth or Segments.defaults.segmentWidth, limits.minSize, limits.maxWidth)
    local height = clamp(aura.segmentHeight or Segments.defaults.segmentHeight, limits.minSize, limits.maxHeight)
    local spacing = clamp(aura.spacing or Segments.defaults.spacing, 0, limits.maxSpacing)
    local grow = aura.grow or Segments.defaults.grow
    local horizontal = HORIZONTAL[grow] == true

    -- Along the grow direction a row holds perRow; rows stack across it.
    local rows = (count + perRow - 1) // perRow
    local alongSize = horizontal and width or height
    local acrossSize = horizontal and height or width
    local total = nil
    if aura.sizeBy == "total" then
        total = clamp(math.floor(aura.totalLength or Segments.defaults.totalLength),
            perRow + (perRow - 1) * spacing, limits.maxTotal)
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

    -- The border leaves at least a couple of pixels inside the smallest
    -- segment.
    local smallest = math.min(acrossSize, select(2, slotSpan(0, perRow, alongSize, total, spacing)))
    local border = clamp(aura.borderThickness or Segments.defaults.borderThickness, 0,
        math.min(limits.maxBorder, (smallest - 2) // 2))

    local centred = CENTRED[grow] == true
    for index = 1, count do
        local part = self:segmentPart(index)
        local slot = (index - 1) % perRow
        local row = (index - 1) // perRow
        -- How many segments this row holds (the last may be short), and
        -- where this one is in it, for centred filling (see redraw).
        local rowCount = math.min(perRow, count - row * perRow)
        part.row, part.slot, part.rowCount = row, slot, rowCount
        local alongStart, alongLength
        if centred then
            -- A short last row sits in the middle of the full row.
            local lastStart, lastLength = slotSpan(rowCount - 1, perRow, alongSize, total, spacing)
            local offset = (rowLength - (lastStart + lastLength)) // 2
            alongStart, alongLength = slotSpan(slot, perRow, alongSize, total, spacing)
            alongStart = alongStart + offset
        else
            -- Backwards growth starts from the far edge.
            if grow == "left" or grow == "up" then slot = perRow - 1 - slot end
            alongStart, alongLength = slotSpan(slot, perRow, alongSize, total, spacing)
        end
        local acrossStart = row * (acrossSize + spacing)
        local x, y, w, h = alongStart, acrossStart, alongLength, acrossSize
        if not horizontal then x, y, w, h = acrossStart, alongStart, acrossSize, alongLength end
        -- Its place in the full box, kept so fitBox can shift it.
        part.x, part.y, part.w, part.h = x, y, w, h
        part.layer:SetPos(x, y)
        part.layer:SetSize(w, h)
        if part.frame == nil and border > 0 then part.frame = Border.new(part.layer, 0) end
        if part.frame ~= nil then
            part.frame:Layout(w, h, border)
            part.frame:SetColour(aura.borderColour)
        end
        part.background:SetPos(border, border)
        part.background:SetSize(w - border * 2, h - border * 2)
        part.background.rgba = aura.backgroundColour
        part.fill:SetPos(border, border)
        part.fill:SetSize(w - border * 2, h - border * 2)
        part.fill.rgba = aura.colour
        part.layer.hidden = false
    end
    for index = count + 1, #self.parts do self.parts[index].layer.hidden = true end
    self.count, self.perRow, self.centred = count, perRow, centred
    self.showEmpty = aura.showEmpty ~= false
    self:place(aura)
    self:setMovable(aura.unlocked)
    self.backing.hidden = not self.movable
    -- Redrawn for the new layout.
    self.filled = nil
    self:redraw()
end

-- The number filled: the source's stacks or charges, else its current
-- value, whole.
function Segments:SetValue(curr, _, _, stacks)
    local filled = stacks
    if filled == nil and curr ~= nil then filled = math.floor(curr) end
    filled = math.max(0, filled or 0)
    -- The aura manager marks it layoutManaged after it's made, so a change
    -- of that redraws too.
    if filled == self.value and (self.layoutManaged == true) == self.drawnManaged then return end
    self.value = filled
    self:redraw()
end

-- Sizes the box to the filled segments (`toFilled`, when some but not all
-- are filled) or to all of them, moving the segments so the box starts at
-- 0, 0: with backwards or centred growth the filled ones don't start at
-- the box's corner.
function Segments:fitBox(toFilled)
    local minX, minY, maxX, maxY = 0, 0, self.fullWidth, self.fullHeight
    if toFilled and self.filled > 0 and self.filled < self.count then
        minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        for index = 1, self.count do
            local part = self.parts[index]
            if part.isFilled then
                minX, minY = math.min(minX, part.x), math.min(minY, part.y)
                maxX, maxY = math.max(maxX, part.x + part.w), math.max(maxY, part.y + part.h)
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

function Segments:redraw()
    local filled = math.min(self.value or 0, self.count)
    local managed = self.layoutManaged == true
    if filled == self.filled and managed == self.drawnManaged then return end
    self.filled, self.drawnManaged = filled, managed
    -- Unlocked, every segment shows, so the whole display can be found.
    local showEmpty = self.showEmpty or self.movable
    for index = 1, self.count do
        local part = self.parts[index]
        local isFilled = index <= filled
        if self.centred then
            -- Rows fill in order; in the row being filled, the filled ones
            -- are its middle segments.
            local inRow = math.max(0, math.min(part.rowCount, filled - part.row * self.perRow))
            local first = (part.rowCount - inRow) // 2
            isFilled = part.slot >= first and part.slot < first + inRow
        end
        part.isFilled = isFilled
        part.fill.hidden = not isFilled
        part.layer.hidden = not (isFilled or showEmpty)
    end
    -- In a dynamic group with empty segments hidden, only the filled ones
    -- take up room, so the group packs it to them. Anywhere else the box
    -- stays full size, so an anchored bar doesn't move as stacks change.
    self:fitBox(managed and not showEmpty)
    -- With nothing to draw it hides itself (as Bar's Hide when empty does),
    -- so a dynamic group closes up around it and a condition's Hide can
    -- still override it.
    self:setHidden(filled == 0 and not showEmpty)
end

function Segments:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Segments
