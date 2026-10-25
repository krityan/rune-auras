-- A combo box for picking one of a few fixed choices with any kind of id
-- (ComboBox entry ids must be integers, so list positions are mapped back
-- to the choices' own ids here).

local choiceCombo = {}

---@class Choice
---@field id any
---@field label string

---@class ChoiceComboOptions
---@field label string? Shown on its own row above; nil when something beside it already names it (e.g. a checkbox).
---@field choices Choice[]
---@field value any The id selected.
---@field tooltip string?
---@field disabled boolean?
---@field width number? Fills the row unless given.
---@field widthAnchor number?
---@field onChange fun(choiceID: any) Called when a different choice is picked.

--- Which end of a display something goes at (e.g. an icon).
---@type Choice[]
choiceCombo.SIDES = {
    { id = "left", label = "Left" },
    { id = "right", label = "Right" },
}

--- ComboBox entries for a list of choices: entry ids must be integers, so
--- each entry's id is its choice's place in the list.
---@param choices Choice[]
---@return table[] entries
---@return table<any, integer> indexByID Each choice's id to its entry's id.
function choiceCombo.Entries(choices)
    local entries, indexByID = {}, {}
    for index, choice in ipairs(choices) do
        entries[index] = { label = choice.label, id = index }
        indexByID[choice.id] = index
    end
    return entries, indexByID
end

--- Adds the combo box (and its label) to a view.
---@param view EditorView
---@param options ChoiceComboOptions
---@return table combo The PrettyUI combo box.
function choiceCombo.Add(view, options)
    local entries, indexByID = choiceCombo.Entries(options.choices)
    local selected = indexByID[options.value] or 1
    local current = options.value
    if options.label ~= nil then view:AddText(options.label) end
    return view:AddComboBox({
        disabled = options.disabled,
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
