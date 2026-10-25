-- Segmented bar editor controls (see TypeEditor in UI/Editor/aura-editor).
-- It has no value text, so the Text section is dropped; the generic Fill
-- colour colours the filled segments.

local Segments = require("Auras/Displays/segments")
local growDirections = require("Auras/Helpers/grow-directions")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

local limits = Segments.limits
local defaults = Segments.defaults

---@type TypeEditor
local segmentsEditor = {}

-- The total length control while it's shown, so changing the segments, per
-- row or spacing can move its minimum without rebuilding (which would end
-- a slider drag). Forgotten at the start of every build (beginBuild): with
-- the Size section collapsed it isn't rebuilt, and the old one is gone.
---@type NumberInput?
local totalInput = nil

--- Forgets the total length control at the start of every build.
function segmentsEditor.beginBuild()
    totalInput = nil
end

--- Moves the total length control's minimum after the count, per row or
--- spacing changed, raising the length if it's now too short.
---@param aura SegmentsOptions
---@param update fun(key: string, value: any)
local function refreshTotalRange(aura, update)
    if totalInput == nil then return end
    local minimum = Segments.MinimumTotal(aura)
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

--- The Size section: size by segment or total, the sizes, and spacing.
---@param view EditorView
---@param aura SegmentsOptions
---@param update fun(key: string, value: any)
function segmentsEditor.size(view, aura, update)
    local grow = aura.grow or defaults.grow
    local horizontal = growDirections.IsHorizontal(grow)
    local byTotal = aura.sizeBy == "total"
    choiceCombo.Add(view, {
        label = "Size by",
        choices = Segments.SIZE_BY,
        value = byTotal and "total" or "segment",
        onChange = function(sizeBy) update("sizeBy", sizeBy) end,
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
            min = Segments.MinimumTotal(aura),
            max = limits.maxTotal,
            step = 1,
            slider = true,
            tooltip = "Including spacing",
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
        onChange = function(value)
            update("spacing", value)
            refreshTotalRange(aura, update)
        end,
    })
end

--- The Layout section: count, wrapping, grow direction and empty segments.
---@param view EditorView
---@param aura SegmentsOptions
---@param update fun(key: string, value: any)
function segmentsEditor.layout(view, aura, update)
    numberInput.Add(view, {
        label = "Segments",
        value = aura.segments or defaults.segments,
        min = 1,
        max = limits.maxSegments,
        step = 1,
        slider = true,
        tooltip = "The most stacks or charges",
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
        tooltip = "0 never wraps",
        onChange = function(value)
            update("perRow", value)
            refreshTotalRange(aura, update)
        end,
    })
    choiceCombo.Add(view, {
        label = "Grow",
        choices = growDirections.CHOICES,
        value = aura.grow or defaults.grow,
        onChange = function(growID) update("grow", growID) end,
    })
    view:AddCheckboxButton({
        {
            text = "Show empty segments",
            value = "showEmpty",
            selected = aura.showEmpty ~= false,
        },
    }, {
        onChange = function(_, _, _, selected) update("showEmpty", selected == true) end,
    })
end

--- The Appearance section: empty and border colours, border thickness.
---@param view EditorView
---@param aura SegmentsOptions
---@param update fun(key: string, value: any)
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
