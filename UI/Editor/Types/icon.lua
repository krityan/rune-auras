-- Icon editor controls (see TypeEditor in UI/Editor/aura-editor).

local dataSources = require("Auras/Registries/data-sources")
local Icon = require("Auras/Displays/icon")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

---@type TypeEditor
local iconEditor = {}

-- The longest "Show below" a buff can be given, in seconds.
local MAX_SHOW_BELOW = 3600

-- Icons have their own swipe colour, so the editor's generic fill colour
-- doesn't apply.
iconEditor.usesFillColour = false
-- Swipe anticlockwise is only offered for the radial.
iconEditor.rebuildOn = { swipeStyle = true }

--- The Size section: one size, as icons are kept square.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Size",
        value = aura.width,
        min = Icon.limits.minSize,
        max = Icon.limits.maxSize,
        step = 2,
        slider = true,
        onChange = function(value)
            -- Kept square.
            update("height", value)
            update("width", value)
        end,
    })
end

--- The Appearance section: tint, swipe, border, and the on/off options of
--- sources that have them (cooldowns, buffs and channels; see DataSource.state).
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.appearance(view, aura, update)
    local source = dataSources.Get(aura.source)
    colourInput.Add(view, {
        label = "Icon tint",
        value = aura.iconColour or Icon.defaults.iconColour,
        windowTitle = "Icon tint",
        tooltip = "White for none",
        onChange = function(colour) update("iconColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Background colour",
        value = aura.backgroundColour or Icon.defaults.backgroundColour,
        windowTitle = "Icon background colour",
        onChange = function(colour) update("backgroundColour", colour) end,
    })
    choiceCombo.Add(view, {
        label = "Swipe",
        choices = Icon.SwipeStylesFor(source),
        value = Icon.DrawnSwipe(aura.swipeStyle, source),
        onChange = function(style) update("swipeStyle", style) end,
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
        tooltip = "0 for none",
        onChange = function(value) update("borderThickness", value) end,
    })
    local options = {
        {
            text = "Invert swipe",
            value = "invertSwipe",
            selected = aura.invertSwipe == true,
            tooltip = "Swipes the other part",
        },
    }
    if Icon.DrawnSwipe(aura.swipeStyle, source) == "radial" then
        options[#options + 1] = {
            text = "Swipe anticlockwise",
            value = "swipeAnticlockwise",
            selected = aura.swipeAnticlockwise == true,
        }
    end
    local state = source ~= nil and source.state or nil
    if state == "active" then
        options[#options + 1] = {
            text = "Desaturate while inactive",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
        }
        options[#options + 1] = {
            text = "Hide while inactive",
            value = "hideWhileInactive",
            selected = aura.hideWhileInactive == true,
            tooltip = "Except while unlocked",
        }
        options[#options + 1] = {
            text = "Hide while active",
            value = "hideWhileActive",
            selected = aura.hideWhileActive == true,
            tooltip = "To show a missing buff; see Show below",
        }
        options[#options + 1] = {
            text = "Hide text while inactive",
            value = "hideTextWhenReady",
            selected = aura.hideTextWhenReady ~= false,
        }
    elseif state == "cooldown" then
        options[#options + 1] = {
            text = "Desaturate while on cooldown",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
        }
        options[#options + 1] = {
            text = "Hide text when ready",
            value = "hideTextWhenReady",
            selected = aura.hideTextWhenReady ~= false,
        }
    end
    view:AddCheckboxButton(options, {
        onChange = function(_, _, value, selected)
            update(value, selected == true)
        end,
    })
    if state == "active" then
        numberInput.Add(view, {
            label = "Show below (seconds)",
            value = aura.showActiveBelow or 0,
            min = 0,
            max = MAX_SHOW_BELOW,
            tooltip = "A reminder to refresh; 0 stays hidden",
            onChange = function(value) update("showActiveBelow", value) end,
        })
    end
end

return iconEditor
