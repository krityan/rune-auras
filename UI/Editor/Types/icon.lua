-- Icon editor controls (see TypeEditor in UI/Editor/aura-editor).

local dataSources = require("Auras/Registries/data-sources")
local iconOptions = require("Auras/Displays/Options/icon")
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
-- Swipe anticlockwise is only offered for the radial, Wipe direction for
-- the linear wipe.
iconEditor.rebuildOn = { swipeStyle = true }

--- The label of a text node's checkbox to blank it while the source is
--- ready, or nil for a source that's never ready (neither a cooldown nor a
--- buff).
---@param aura Aura
---@return string?
function iconEditor.hideWhenReadyLabel(aura)
    local source = aura.source and dataSources.Get(aura.source)
    local state = source ~= nil and source.state or nil
    if state == "cooldown" then return "Hide when ready" end
    if state == "active" then return "Hide while inactive" end
    return nil
end

--- The Size section: one size, as icons are kept square.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Size",
        value = aura.width,
        min = iconOptions.limits.minSize,
        max = iconOptions.limits.maxSize,
        step = 2,
        slider = true,
        onChange = function(value)
            -- Kept square.
            update("height", value)
            update("width", value)
        end,
    })
end

--- Adds icon tint, background and border controls.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.appearance(view, aura, update)
    colourInput.Add(view, {
        label = "Icon tint",
        value = aura.iconColour or iconOptions.defaults.iconColour,
        windowTitle = "Icon tint",
        tooltip = "White for none",
        onChange = function(colour) update("iconColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Background colour",
        value = aura.backgroundColour or iconOptions.defaults.backgroundColour,
        windowTitle = "Icon background colour",
        onChange = function(colour) update("backgroundColour", colour) end,
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
        max = iconOptions.limits.maxBorder,
        step = 1,
        slider = true,
        tooltip = "0 for none",
        onChange = function(value) update("borderThickness", value) end,
    })
end

--- Adds swipe and visibility controls for the source's cooldown or active duration.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.state(view, aura, update)
    local source = dataSources.ForAura(aura)
    local swipeStyle = iconOptions.DrawnSwipe(aura.swipeStyle, source)
    choiceCombo.Add(view, {
        label = "Swipe",
        choices = iconOptions.SwipeStylesFor(source),
        value = swipeStyle,
        onChange = function(style) update("swipeStyle", style) end,
    })
    if swipeStyle == "linear" then
        choiceCombo.Add(view, {
            label = "Wipe direction",
            choices = iconOptions.WIPE_DIRECTIONS,
            value = aura.wipeDirection or iconOptions.defaults.wipeDirection,
            onChange = function(direction) update("wipeDirection", direction) end,
        })
    end
    colourInput.Add(view, {
        label = "Swipe colour",
        value = aura.swipeColour,
        windowTitle = "Icon swipe colour",
        onChange = function(colour) update("swipeColour", colour) end,
    })
    local options = {
        {
            text = "Invert swipe",
            value = "invertSwipe",
            selected = aura.invertSwipe == true,
            tooltip = "Make the swipe count down",
        },
    }
    if swipeStyle == "radial" then
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
    elseif state == "cooldown" then
        options[#options + 1] = {
            text = "Desaturate while on cooldown",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
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
