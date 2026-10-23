-- Text-specific controls for the aura editor's sections (see
-- UI/Windows/aura-editor). The text's template, font, size and colour are
-- the editor's own Text section; this adds the max width and the display's
-- options. Kept out of Auras/Displays/text so the display doesn't depend on
-- UI code.

local limits = require("Auras/Displays/text").limits
local choiceCombo = require("UI/Controls/choice-combo")
local numberInput = require("UI/Controls/number-input")

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

-- The box grows to fit its text, so only its widest is set.
function textEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Max width",
        value = aura.maxWidth,
        min = limits.minWidth,
        max = limits.maxWidth,
        step = 10,
        slider = true,
        tooltip = "The widest the text's box gets. It grows to fit the text up to this, then the text wraps onto more lines.",
        onChange = function(value) update("maxWidth", value) end,
    })
end

function textEditor.appearance(view, aura, update)
    view:AddCheckboxButton({
        {
            text = "Hide when empty",
            value = "hideWhenEmpty",
            selected = aura.hideWhenEmpty == true,
            tooltip = "Hide the text while the value is 0: a channel or buff that isn't running, a cooldown that's ready. It still shows while unlocked, so it can be moved.",
        },
        {
            text = "Show icon",
            value = "showIcon",
            selected = aura.showIcon == true,
            tooltip = "Show the data source's icon at one end, a line tall. For Any channel it's whatever is being channelled.",
        },
        {
            text = "Text shadow",
            value = "textShadow",
            selected = aura.textShadow ~= false,
            tooltip = "Draw a shadow behind the text, so it reads over busy backgrounds.",
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
        tooltip = "Where the lines sit when the text wraps.",
        onChange = function(id) update("textAlign", id) end,
    })
    choiceCombo.Add(view, {
        label = "Icon side",
        choices = choiceCombo.SIDES,
        value = aura.iconSide or "left",
        tooltip = "Which end the icon goes at, with Show icon on.",
        onChange = function(id) update("iconSide", id) end,
    })
end

return textEditor
