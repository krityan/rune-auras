-- Segmented bar controls for the aura editor's sections (see
-- UI/Windows/aura-editor). It has no value text, so the Text section is
-- dropped; the generic Fill colour colours the filled segments. Kept out of
-- Auras/Displays/segments so the display doesn't depend on UI code.

local Segments = require("Auras/Displays/segments")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

local limits = Segments.limits
local defaults = Segments.defaults

local segmentsEditor = {}

-- The shortest a row can be: a pixel per segment plus the spacing, as the
-- display clamps it (see Segments:Apply).
local function minimumTotal(aura)
    local count = math.max(1, math.min(limits.maxSegments, math.floor(aura.segments or defaults.segments)))
    local perRow = math.floor(aura.perRow or 0)
    if perRow <= 0 or perRow > count then perRow = count end
    local spacing = math.max(0, math.min(limits.maxSpacing, aura.spacing or defaults.spacing))
    return math.min(limits.maxTotal, perRow + (perRow - 1) * spacing)
end

-- The total length control while it's shown, so changing the segments, per
-- row or spacing can move its minimum without rebuilding (which would end
-- a slider drag). Forgotten at the start of every build (beginBuild): with
-- the Size section collapsed it isn't rebuilt, and the old one is gone.
local totalInput = nil

function segmentsEditor.beginBuild()
    totalInput = nil
end

local function refreshTotalRange(aura, update)
    if totalInput == nil then return end
    local minimum = minimumTotal(aura)
    totalInput:SetRange(minimum, limits.maxTotal)
    local total = aura.totalLength or defaults.totalLength
    if total < minimum then
        update("totalLength", minimum)
        totalInput:SetValue(minimum)
    end
end

segmentsEditor.usesText = false

-- Size by and Grow change which size controls show.
segmentsEditor.rebuildOn = { sizeBy = true, grow = true }

function segmentsEditor.size(view, aura, update)
    local grow = aura.grow or defaults.grow
    local horizontal = grow == "right" or grow == "left" or grow == "horizontal"
    local byTotal = aura.sizeBy == "total"
    choiceCombo.Add(view, {
        label = "Size by",
        choices = Segments.SIZE_BY,
        value = byTotal and "total" or "segment",
        tooltip = "Each segment: set a segment's size. Total length: set the row's length, shared between its segments, so it stays the same however many there are.",
        onChange = function(id) update("sizeBy", id) end,
    })
    local function addWidth()
        numberInput.Add(view, {
            label = "Segment width",
            value = aura.segmentWidth or defaults.segmentWidth,
            min = limits.minSize,
            max = limits.maxWidth,
            step = 1,
            slider = true,
            onChange = function(value) update("segmentWidth", value) end,
        })
    end
    local function addHeight()
        numberInput.Add(view, {
            label = "Segment height",
            value = aura.segmentHeight or defaults.segmentHeight,
            min = limits.minSize,
            max = limits.maxHeight,
            step = 1,
            slider = true,
            onChange = function(value) update("segmentHeight", value) end,
        })
    end
    if byTotal then
        -- The total sets the length along the grow direction; the segment
        -- size still sets the other way.
        totalInput = numberInput.Add(view, {
            label = horizontal and "Total width" or "Total height",
            value = aura.totalLength or defaults.totalLength,
            min = minimumTotal(aura),
            max = limits.maxTotal,
            step = 1,
            slider = true,
            tooltip = "The length of a row (or column), including spacing.",
            onChange = function(value) update("totalLength", value) end,
        })
        if horizontal then addHeight() else addWidth() end
    else
        addWidth()
        addHeight()
    end
    numberInput.Add(view, {
        label = "Spacing",
        value = aura.spacing or defaults.spacing,
        min = 0,
        max = limits.maxSpacing,
        step = 1,
        slider = true,
        tooltip = "Pixels between segments.",
        onChange = function(value)
            update("spacing", value)
            refreshTotalRange(aura, update)
        end,
    })
end

function segmentsEditor.layout(view, aura, update)
    numberInput.Add(view, {
        label = "Segments",
        value = aura.segments or defaults.segments,
        min = 1,
        max = limits.maxSegments,
        step = 1,
        slider = true,
        tooltip = "How many there are: the most stacks (or charges) the source can have.",
        onChange = function(value)
            update("segments", value)
            refreshTotalRange(aura, update)
        end,
    })
    numberInput.Add(view, {
        label = "Per row",
        value = aura.perRow or defaults.perRow,
        min = 0,
        max = limits.maxSegments,
        step = 1,
        slider = true,
        tooltip = "Segments before wrapping onto another row (or column). 0 never wraps.",
        onChange = function(value)
            update("perRow", value)
            refreshTotalRange(aura, update)
        end,
    })
    choiceCombo.Add(view, {
        label = "Grow",
        choices = Segments.GROW,
        value = aura.grow or defaults.grow,
        tooltip = "Which way the segments fill: from one edge, or from the middle outwards both ways (centred).",
        onChange = function(id) update("grow", id) end,
    })
    view:AddCheckboxButton({
        {
            text = "Show empty segments",
            value = "showEmpty",
            selected = aura.showEmpty ~= false,
            tooltip = "Off: only the filled segments show.",
        },
    }, {
        onChange = function(_, _, _, selected) update("showEmpty", selected == true) end,
    })
end

function segmentsEditor.appearance(view, aura, update)
    colourInput.Add(view, {
        label = "Empty colour",
        value = aura.backgroundColour,
        windowTitle = "Empty segment colour",
        onChange = function(colour) update("backgroundColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Border colour",
        value = aura.borderColour,
        windowTitle = "Segment border colour",
        onChange = function(colour) update("borderColour", colour) end,
    })
    numberInput.Add(view, {
        label = "Border thickness",
        value = aura.borderThickness,
        min = 0,
        max = limits.maxBorder,
        step = 1,
        slider = true,
        onChange = function(value) update("borderThickness", value) end,
    })
end

return segmentsEditor
