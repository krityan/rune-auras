-- Icon-specific controls for the aura editor's sections (see UI/Windows/aura-editor).
-- Kept out of Auras/Displays/icon so the display doesn't depend on UI code.

local dataSources = require("Auras/Registries/data-sources")
local Icon = require("Auras/Displays/icon")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

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
    colourInput.Add(view, {
        label = "Swipe colour",
        value = aura.swipeColour,
        windowTitle = "Icon swipe colour",
        onChange = function(colour) update("swipeColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Border colour",
        value = aura.borderColour,
        windowTitle = "Icon border colour",
        onChange = function(colour) update("borderColour", colour) end,
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
            tooltip = "Cover the other part of the value instead: what's done for a cooldown, what's left for a buff or other value.",
        },
    }
    -- Only cooldowns and buffs have an on/off state (see Auras/Displays/icon).
    local source = dataSources.Get(aura.source)
    if source ~= nil and source.type == "buff" then
        options[#options + 1] = {
            text = "Desaturate while inactive",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
            tooltip = "Show the icon in greyscale while the buff isn't active (darkened if it has no greyscale copy).",
        }
        options[#options + 1] = {
            text = "Hide while inactive",
            value = "hideWhileInactive",
            selected = aura.hideWhileInactive == true,
            tooltip = "Hide the icon entirely while the buff isn't active. It still shows while unlocked, so it can be moved.",
        }
        options[#options + 1] = {
            text = "Show initial tick",
            value = "showInitialTick",
            selected = aura.showInitialTick ~= false,
            tooltip = "Show the buff as soon as it appears on the game's buff bar, with its expected duration, instead of a tick later when the bar shows its timer.",
        }
        options[#options + 1] = {
            text = "Hide text while inactive",
            value = "hideTextWhenReady",
            selected = aura.hideTextWhenReady ~= false,
            tooltip = "Only show the value text while the buff is active.",
        }
    elseif source ~= nil and source.type == "cooldown" then
        options[#options + 1] = {
            text = "Desaturate while on cooldown",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
            tooltip = "Show the icon in greyscale until the ability is ready (darkened if it has no greyscale copy).",
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
