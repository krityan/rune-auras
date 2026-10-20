-- Bar-specific controls for the aura editor's sections (see UI/aura-editor).
-- Kept out of Auras/Displays/bar so the display doesn't depend on UI code.

local dataSources = require("Auras/data-sources")
local limits = require("Auras/Displays/bar").limits
local numberInput = require("UI/number-input")

local barEditor = {}

function barEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Width",
        value = aura.width,
        min = limits.minWidth,
        max = limits.maxWidth,
        step = 10,
        slider = true,
        tooltip = "Set the bar width.",
        onChange = function(value) update("width", value) end,
    })
    numberInput.Add(view, {
        label = "Height",
        value = aura.height,
        min = limits.minHeight,
        max = limits.maxHeight,
        step = 1,
        slider = true,
        tooltip = "Set the bar height.",
        onChange = function(value) update("height", value) end,
    })
end

function barEditor.appearance(view, aura, update)
    local fillOptions = {
        {
            text = "Invert fill",
            value = "invertFill",
            selected = aura.invertFill == true,
            tooltip = "Fill the bar as the value drops instead of emptying it.",
        },
    }
    -- Only sources that report a value between ticks can move every frame.
    local source = dataSources.Get(aura.source)
    if source ~= nil and source.smooth then
        fillOptions[#fillOptions + 1] = {
            text = "Smooth fill",
            value = "smoothFill",
            selected = aura.smoothFill == true,
            tooltip = "Move the fill every frame instead of every game tick.",
        }
    end
    view:AddCheckboxButton(fillOptions, {
        onChange = function(_, _, value, selected)
            update(value, selected == true)
        end,
    })
    view:AddText("Background colour")
    view:AddColourPicker({
        width = 40,
        height = 32,
        value = aura.backgroundColour,
        alphaSlider = true,
        windowTitle = "Bar background colour",
        onChange = function(_, colour) update("backgroundColour", colour) end,
    })
    view:AddText("Border colour")
    view:AddColourPicker({
        width = 40,
        height = 32,
        value = aura.borderColour,
        alphaSlider = true,
        windowTitle = "Bar border colour",
        onChange = function(_, colour) update("borderColour", colour) end,
    })
    numberInput.Add(view, {
        label = "Border thickness",
        value = aura.borderThickness,
        min = 0,
        max = limits.maxBorder,
        step = 1,
        slider = true,
        tooltip = "Set the border thickness in pixels. 0 removes the border.",
        onChange = function(value) update("borderThickness", value) end,
    })
end

return barEditor
