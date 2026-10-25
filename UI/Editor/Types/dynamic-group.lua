-- Dynamic group editor controls (see TypeEditor in UI/Editor/aura-editor).
-- Like a group, it has no data source, appearance or text; it adds a
-- Layout section for how its auras are lined up.

local DynamicGroup = require("Auras/Displays/dynamic-group")
local growDirections = require("Auras/Helpers/grow-directions")
local choiceCombo = require("UI/Controls/choice-combo")
local numberInput = require("UI/Controls/number-input")

---@type TypeEditor
local dynamicGroupEditor = {}

dynamicGroupEditor.usesSource = false
dynamicGroupEditor.usesAppearance = false
dynamicGroupEditor.usesText = false

--- The Layout section: grow direction, spacing and alignment.
---@param view EditorView
---@param aura DynamicGroupOptions
---@param update fun(key: string, value: any)
function dynamicGroupEditor.layout(view, aura, update)
    choiceCombo.Add(view, {
        label = "Grow",
        choices = growDirections.CHOICES,
        value = aura.grow or DynamicGroup.defaults.grow,
        onChange = function(growID) update("grow", growID) end,
    })
    numberInput.Add(view, {
        label = "Spacing",
        value = aura.spacing or DynamicGroup.defaults.spacing,
        min = 0,
        max = DynamicGroup.limits.maxSpacing,
        step = 1,
        slider = true,
        onChange = function(value) update("spacing", value) end,
    })
    choiceCombo.Add(view, {
        label = "Alignment",
        choices = DynamicGroup.ALIGN,
        value = aura.align or DynamicGroup.defaults.align,
        tooltip = "Across the grow direction",
        onChange = function(alignID) update("align", alignID) end,
    })
end

return dynamicGroupEditor
