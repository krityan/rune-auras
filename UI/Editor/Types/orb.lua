-- Orb editor controls (see TypeEditor in UI/Editor/aura-editor).

local dataSources = require("Auras/Registries/data-sources")
local orbOptions = require("Auras/Displays/Options/orb")
local iconOptions = require("Auras/Displays/Options/icon")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")

local limits = orbOptions.limits

---@type TypeEditor
local orbEditor = {}

-- The desaturate option's label, by the source's state.
local DESATURATE_LABELS = { cooldown = "Desaturate while on cooldown", active = "Desaturate while inactive" }

-- Fill anticlockwise is only offered for the radial fill, and Fill
-- direction for the linear one.
orbEditor.rebuildOn = { fillStyle = true }

--- The Size section: one size, as orbs are kept round.
---@param view EditorView
---@param aura OrbOptions
---@param update fun(key: string, value: any)
function orbEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Size",
        value = aura.width,
        min = limits.minSize,
        max = limits.maxSize,
        step = 2,
        slider = true,
        onChange = function(value)
            -- Kept round.
            update("height", value)
            update("width", value)
        end,
    })
end

--- The Appearance section: the fill's style and options, the icon, colours
--- and border.
--- Smooth fill only shows for sources that report a value between ticks.
---@param view EditorView
---@param aura OrbOptions
---@param update fun(key: string, value: any)
function orbEditor.appearance(view, aura, update)
    local fillStyle = aura.fillStyle == "radial" and "radial" or "linear"
    choiceCombo.Add(view, {
        label = "Fill",
        choices = orbOptions.FILL_STYLES,
        value = fillStyle,
        onChange = function(style) update("fillStyle", style) end,
    })
    if fillStyle == "linear" then
        choiceCombo.Add(view, {
            label = "Fill direction",
            choices = iconOptions.WIPE_DIRECTIONS,
            value = iconOptions.WipeDirection(aura.fillDirection, orbOptions.defaults.fillDirection),
            onChange = function(direction) update("fillDirection", direction) end,
        })
    end
    local source = dataSources.ForAura(aura)
    local options = {
        {
            text = "Invert fill",
            value = "invertFill",
            selected = aura.invertFill == true,
        },
    }
    if fillStyle == "radial" then
        options[#options + 1] = {
            text = "Fill anticlockwise",
            value = "fillAnticlockwise",
            selected = aura.fillAnticlockwise == true,
        }
    end
    if source ~= nil and source.smooth then
        options[#options + 1] = {
            text = "Smooth fill",
            value = "smoothFill",
            selected = aura.smoothFill == true,
        }
    end
    options[#options + 1] = {
        text = "Hide when empty",
        value = "hideWhenEmpty",
        selected = aura.hideWhenEmpty == true,
    }
    options[#options + 1] = {
        text = "Show icon",
        value = "showIcon",
        selected = aura.showIcon == true,
    }
    -- Named as the Icon display's is, for what greys it.
    local desaturateLabel = DESATURATE_LABELS[source ~= nil and source.state or ""]
    if desaturateLabel ~= nil then
        options[#options + 1] = {
            text = desaturateLabel,
            value = "dimWhileActive",
            selected = aura.dimWhileActive == true,
        }
    end
    view:AddCheckboxButton(options, {
        onChange = function(_, _, value, selected) update(value, selected == true) end,
    })
    colourInput.Add(view, {
        label = "Background colour",
        value = aura.backgroundColour,
        windowTitle = "Orb background colour",
        onChange = function(colour) update("backgroundColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Border colour",
        value = aura.borderColour,
        windowTitle = "Orb border colour",
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

return orbEditor
