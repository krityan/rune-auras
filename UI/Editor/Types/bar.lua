-- Bar editor controls (see TypeEditor in UI/Editor/aura-editor).

local dataSources = require("Auras/Registries/data-sources")
local limits = require("Auras/Displays/bar").limits
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

---@type TypeEditor
local barEditor = {}

--- The Size section: width and height.
---@param view EditorView
---@param aura BarOptions
---@param update fun(key: string, value: any)
function barEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Width",
        value = aura.width,
        min = limits.minWidth,
        max = limits.maxWidth,
        step = 10,
        slider = true,
        onChange = function(value) update("width", value) end,
    })
    numberInput.Add(view, {
        label = "Height",
        value = aura.height,
        min = limits.minHeight,
        max = limits.maxHeight,
        step = 1,
        slider = true,
        onChange = function(value) update("height", value) end,
    })
end

--- The Appearance section: fill options, icon, ticks, colours and border.
--- Smooth fill only shows for sources that report a value between ticks,
--- and ticks only for times in seconds.
---@param view EditorView
---@param aura BarOptions
---@param update fun(key: string, value: any)
function barEditor.appearance(view, aura, update)
    local fillOptions = {
        {
            text = "Invert fill",
            value = "invertFill",
            selected = aura.invertFill == true,
            tooltip = "Fills as the value drops",
        },
        {
            text = "Hide when empty",
            value = "hideWhenEmpty",
            selected = aura.hideWhenEmpty == true,
            tooltip = "Hidden at 0, except while unlocked",
        },
        {
            text = "Show icon",
            value = "showIcon",
            selected = aura.showIcon == true,
        },
    }
    local source = dataSources.Get(aura.source)
    local timed = source ~= nil and source.timed == true
    if source ~= nil and source.smooth then
        fillOptions[#fillOptions + 1] = {
            text = "Smooth fill",
            value = "smoothFill",
            selected = aura.smoothFill == true,
            tooltip = "Every frame, not every tick",
        }
    end
    if timed then
        fillOptions[#fillOptions + 1] = {
            text = "Show ticks",
            value = "showTicks",
            selected = aura.showTicks == true,
            tooltip = "A mark every 0.6s tick",
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
        onChange = function(side) update("iconSide", side) end,
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
        tooltip = "0 for none",
        onChange = function(value) update("borderThickness", value) end,
    })
end

return barEditor
