-- Icon-specific controls for the aura editor's sections (see UI/aura-editor).
-- Kept out of Auras/Displays/icon so the display doesn't depend on UI code.

local dataSources = require("Auras/data-sources")
local Icon = require("Auras/Displays/icon")
local numberInput = require("UI/number-input")

local iconEditor = {}

-- Icons have their own swipe colour, so the editor's generic fill colour
-- doesn't apply.
iconEditor.usesFillColour = false

function iconEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Size",
        value = aura.width,
        min = Icon.limits.minSize,
        max = Icon.limits.maxSize,
        step = 2,
        slider = true,
        tooltip = "Set the icon's width and height.",
        onChange = function(value)
            -- Kept square. Height is set directly so one update saves and
            -- refreshes for both.
            aura.height = value
            update("width", value)
        end,
    })
end

function iconEditor.appearance(view, aura, update)
    local styles = Icon.SWIPE_STYLES
    local entries, selected = {}, nil
    for index, style in ipairs(styles) do
        entries[index] = { label = style.label, id = index }
        if style.id == aura.swipeStyle then selected = index end
    end
    view:AddText("Swipe")
    view:AddComboBox({
        entries = entries,
        selectedID = selected,
        tooltip = "How the remaining time is drawn over the icon.",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local style = styles[entryID]
            if style ~= nil then update("swipeStyle", style.id) end
        end,
    })
    view:AddText("Swipe colour")
    view:AddColourPicker({
        width = 40,
        height = 32,
        value = aura.swipeColour,
        alphaSlider = true,
        windowTitle = "Icon swipe colour",
        onChange = function(_, colour) update("swipeColour", colour) end,
    })
    view:AddText("Border colour")
    view:AddColourPicker({
        width = 40,
        height = 32,
        value = aura.borderColour,
        alphaSlider = true,
        windowTitle = "Icon border colour",
        onChange = function(_, colour) update("borderColour", colour) end,
    })
    numberInput.Add(view, {
        label = "Border thickness",
        value = aura.borderThickness,
        min = 0,
        max = Icon.limits.maxBorder,
        step = 1,
        slider = true,
        tooltip = "Set the border thickness in pixels. 0 removes the border.",
        onChange = function(value) update("borderThickness", value) end,
    })
    local options = {
        {
            text = "Invert swipe",
            value = "invertSwipe",
            selected = aura.invertSwipe == true,
            tooltip = "Cover what's done (or what's left, for values other than cooldowns) instead.",
        },
    }
    -- Only a cooldown has a "ready" state (see Auras/Displays/icon).
    local source = dataSources.Get(aura.source)
    if source ~= nil and source.type == "cooldown" then
        options[#options + 1] = {
            text = "Grey out while on cooldown",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
            tooltip = "Darken the icon until the ability is ready.",
        }
        options[#options + 1] = {
            text = "Hide text when ready",
            value = "hideTextWhenReady",
            selected = aura.hideTextWhenReady ~= false,
            tooltip = "Only show the value text while the ability is on cooldown.",
        }
    end
    view:AddCheckboxButton(options, {
        onChange = function(_, _, value, selected)
            update(value, selected == true)
        end,
    })
end

return iconEditor
