-- A labelled combo box for picking one of a few fixed choices, each an
-- { id, label } with any kind of id (ComboBox entry ids must be integers, so
-- list positions are mapped back to the choices' own ids here).
-- Usage:
--   local choiceCombo = require("UI/Controls/choice-combo")
--   choiceCombo.Add(view, {
--       label = "Icon side",
--       choices = { { id = "left", label = "Left" }, { id = "right", label = "Right" } },
--       value = aura.iconSide or "left",
--       tooltip = "...",
--       onChange = function(id) ... end,
--   })

local choiceCombo = {}

-- Which end of a display something goes at (e.g. an icon).
choiceCombo.SIDES = {
    { id = "left", label = "Left" },
    { id = "right", label = "Right" },
}

function choiceCombo.Add(view, options)
    local entries, selected = {}, 1
    for index, choice in ipairs(options.choices) do
        entries[index] = { label = choice.label, id = index }
        if choice.id == options.value then selected = index end
    end
    local current = options.value
    view:AddText(options.label)
    return view:AddComboBox({
        -- Fills the row unless given a width.
        width = options.width,
        widthAnchor = options.widthAnchor,
        entries = entries,
        selectedID = selected,
        tooltip = options.tooltip,
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local choice = options.choices[entryID]
            if choice ~= nil and choice.id ~= current then
                current = choice.id
                options.onChange(choice.id)
            end
        end,
    })
end

return choiceCombo
