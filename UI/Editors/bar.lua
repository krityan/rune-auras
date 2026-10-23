-- Bar-specific controls for the aura editor's sections (see UI/Windows/aura-editor).
-- Kept out of Auras/Displays/bar so the display doesn't depend on UI code.

local dataSources = require("Auras/Registries/data-sources")
local limits = require("Auras/Displays/bar").limits
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

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
        {
            text = "Hide when empty",
            value = "hideWhenEmpty",
            selected = aura.hideWhenEmpty == true,
            tooltip = "Hide the bar while the value is 0: a channel or buff that isn't running, a cooldown that's ready. It still shows while unlocked, so it can be moved.",
        },
        {
            text = "Show icon",
            value = "showIcon",
            selected = aura.showIcon == true,
            tooltip = "Show the data source's icon at one end of the bar, as a square the bar's height. For Any channel it's whatever is being channelled.",
        },
    }
    -- Only sources that report a value between ticks can move every frame,
    -- and only times in seconds can be divided into ticks.
    local source = dataSources.Get(aura.source)
    local timed = source ~= nil and source.timed == true
    if source ~= nil and source.smooth then
        fillOptions[#fillOptions + 1] = {
            text = "Smooth fill",
            value = "smoothFill",
            selected = aura.smoothFill == true,
            tooltip = "Move the fill every frame instead of every game tick.",
        }
    end
    if timed then
        fillOptions[#fillOptions + 1] = {
            text = "Show ticks",
            value = "showTicks",
            selected = aura.showTicks == true,
            tooltip = "Mark each game tick (0.6s) along the bar, like the game's channel bar. Left out when they'd be too close together to tell apart.",
        }
    end
    view:AddCheckboxButton(fillOptions, {
        onChange = function(_, _, value, selected)
            update(value, selected == true)
        end,
    })
    choiceCombo.Add(view, {
        label = "Icon side",
        choices = choiceCombo.SIDES,
        value = aura.iconSide or "left",
        tooltip = "Which end of the bar the icon goes at, with Show icon on.",
        onChange = function(id) update("iconSide", id) end,
    })
    if timed then
        colourInput.Add(view, {
            label = "Tick colour",
            value = aura.tickColour,
            windowTitle = "Bar tick colour",
            onChange = function(colour) update("tickColour", colour) end,
        })
    end
    colourInput.Add(view, {
        label = "Background colour",
        value = aura.backgroundColour,
        windowTitle = "Bar background colour",
        onChange = function(colour) update("backgroundColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Border colour",
        value = aura.borderColour,
        windowTitle = "Bar border colour",
        onChange = function(colour) update("borderColour", colour) end,
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
