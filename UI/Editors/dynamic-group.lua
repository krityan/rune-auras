-- Dynamic-group settings for the aura editor (see UI/Windows/aura-editor).
-- Like a group, it has no data source, appearance or text. Its position is
-- an aura's (an anchor and offset), placing the point its auras grow from;
-- it adds a Layout section for how they're lined up. Kept out of
-- Auras/Displays so the display doesn't depend on UI code.

local DynamicGroup = require("Auras/Displays/dynamic-group")
local choiceCombo = require("UI/Controls/choice-combo")
local numberInput = require("UI/Controls/number-input")

local dynamicGroupEditor = {}

dynamicGroupEditor.usesSource = false
dynamicGroupEditor.usesAppearance = false
dynamicGroupEditor.usesText = false

function dynamicGroupEditor.layout(view, aura, update)
    choiceCombo.Add(view, {
        label = "Grow",
        choices = DynamicGroup.GROW,
        value = aura.grow or DynamicGroup.defaults.grow,
        tooltip = "Which way its auras line up from its point: one way, or centred on it.",
        onChange = function(id) update("grow", id) end,
    })
    numberInput.Add(view, {
        label = "Spacing",
        value = aura.spacing or DynamicGroup.defaults.spacing,
        min = 0,
        max = DynamicGroup.limits.maxSpacing,
        step = 1,
        slider = true,
        tooltip = "Pixels between its auras.",
        onChange = function(value) update("spacing", value) end,
    })
    choiceCombo.Add(view, {
        label = "Alignment",
        choices = DynamicGroup.ALIGN,
        value = aura.align or DynamicGroup.defaults.align,
        tooltip = "How auras of different sizes line up across the grow direction.",
        onChange = function(id) update("align", id) end,
    })
end

return dynamicGroupEditor
