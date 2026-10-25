-- Text display editor controls (see TypeEditor in UI/Editor/aura-editor).
-- The text's template, font, size and colour are the editor's own Text
-- section; this adds the max width and the display's options.

local limits = require("Auras/Displays/text").limits
local choiceCombo = require("UI/Controls/choice-combo")
local numberInput = require("UI/Controls/number-input")

---@type TypeEditor
local textEditor = {}

-- The text is the whole display, so there's no fill colour to pick and no
-- "Show value text" to turn off.
textEditor.usesFillColour = false
textEditor.usesShowText = false

local ALIGNMENTS = {
    { id = "left", label = "Left" },
    { id = "centre", label = "Centre" },
    { id = "right", label = "Right" },
}

--- The Size section: the box grows to fit its text, so only its widest is set.
---@param view EditorView
---@param aura TextOptions
---@param update fun(key: string, value: any)
function textEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Max width",
        value = aura.maxWidth,
        min = limits.minWidth,
        max = limits.maxWidth,
        step = 10,
        slider = true,
        tooltip = "Wraps past this",
        onChange = function(value) update("maxWidth", value) end,
    })
end

--- The Appearance section: hiding, icon, shadow and alignment.
---@param view EditorView
---@param aura TextOptions
---@param update fun(key: string, value: any)
function textEditor.appearance(view, aura, update)
    view:AddCheckboxButton({
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
        {
            text = "Text shadow",
            value = "textShadow",
            selected = aura.textShadow ~= false,
        },
    }, {
        onChange = function(_, _, value, selected)
            update(value, selected == true)
        end,
    })
    choiceCombo.Add(view, {
        label = "Text alignment",
        choices = ALIGNMENTS,
        value = aura.textAlign or "centre",
        tooltip = "For wrapped lines",
        onChange = function(alignID) update("textAlign", alignID) end,
    })
    choiceCombo.Add(view, {
        label = "Icon side",
        choices = choiceCombo.SIDES,
        value = aura.iconSide or "left",
        onChange = function(side) update("iconSide", side) end,
    })
end

return textEditor
