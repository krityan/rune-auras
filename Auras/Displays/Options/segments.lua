-- A Segmented bar aura's options: their defaults, limits and choices, and
-- the rules both the display and the editor apply to them (how many to a
-- row, the shortest total length). Kept apart from the drawing code
-- (Auras/Displays/segments) so reading them doesn't load it.

local maths = require("Auras/Helpers/maths")

local clamp = maths.Clamp

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

---@class SegmentsDisplayOptions: DisplayOptions
local segmentsOptions = {}

-- The display sizes itself, so its aura's width/height are only nominal and
-- the editor reads its size from the aura manager (see auraManager.ScreenSize).
segmentsOptions.sizesItself = true

segmentsOptions.defaults = {
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

segmentsOptions.SIZE_BY = {
    { id = "segment", label = "Each segment" },
    { id = "total", label = "Total length" },
}

segmentsOptions.limits = {
    maxSegments = 30,
    minSize = 4, maxWidth = 300, maxHeight = 100,
    maxTotal = 1200,
    maxSpacing = 20,
    maxBorder = 4,
}

--- An aura's segment count, how many go in a row and the spacing, within
--- the limits. perRow 0 (or more than the count) puts them all in one row.
---@param aura SegmentsOptions
---@return integer count
---@return integer perRow
---@return number spacing
function segmentsOptions.RowOptions(aura)
    local limits, defaults = segmentsOptions.limits, segmentsOptions.defaults
    local count = clamp(math.floor(aura.segments or defaults.segments), 1, limits.maxSegments)
    local perRow = math.floor(aura.perRow or 0)
    if perRow <= 0 or perRow > count then perRow = count end
    local spacing = clamp(aura.spacing or defaults.spacing, 0, limits.maxSpacing)
    return count, perRow, spacing
end

--- The shortest a row can be with an aura's count, per row and spacing: a
--- pixel per segment plus the spacing. The display clamps totalLength to
--- it, and the editor's total length control starts there.
---@param aura SegmentsOptions
---@return integer
function segmentsOptions.MinimumTotal(aura)
    local _, perRow, spacing = segmentsOptions.RowOptions(aura)
    return math.min(segmentsOptions.limits.maxTotal, perRow + (perRow - 1) * spacing)
end

--- Whether a source's segments recharge: a cooldown's charges fill them,
--- and its time the next one.
---@param source DataSource?
---@return boolean
function segmentsOptions.Recharges(source)
    return source ~= nil and source.state == "cooldown" and source.timed == true
end

return segmentsOptions
