-- Picking an aura's text: a field, then optionally a separator and a second
-- field, as three combo boxes on one row, so a text holds only the source's
-- values (see textTemplate).

local textTemplate = require("Auras/Helpers/text-template")
local dataSources = require("Auras/Registries/data-sources")
local choiceCombo = require("UI/Controls/choice-combo")
local uiConstants = require("UI/ui-constants")

local textPicker = {}

-- The choice for having no second field, and so no separator.
local NONE = { id = "none", label = "None" }
-- The separator's only choice while there's no second field.
local NO_SEPARATOR = { NONE }
-- The separator's box is narrow and centred on the row; the fields share
-- the rest, a gap either side of it.
local SEPARATOR_WIDTH = 64
local GAP = uiConstants.GAP

---@class TextPickerOptions
---@field label string Shown above the row.
---@field template string? The text picked now; one that isn't valid shows as the default.
---@field sourceID string? The aura's source, which decides the fields listed.
---@field onChange fun(template: string, rebuild: boolean) Called when a different text is picked; `rebuild` when a second field was added or removed, which the controls must be rebuilt to show.

--- The fields a source fills, plus `keep` if it doesn't (picked for another
--- source), so the combo can show it.
---@param sourceID string?
---@param keep TextFieldID?
---@return Choice[]
local function fieldChoices(sourceID, keep)
    local choices = {}
    for _, field in ipairs(textTemplate.FIELDS) do
        if field.id == keep or dataSources.FillsTextField(sourceID, field.id) then
            choices[#choices + 1] = { id = field.id, label = field.label }
        end
    end
    return choices
end

--- Adds the text's label and its row of combo boxes to a view: the field,
--- the separator, and a second field or none. A separator, once picked,
--- stays when either field changes.
---@param view EditorView
---@param options TextPickerOptions
function textPicker.Add(view, options)
    local parts = textTemplate.Parts(options.template)
    local first, separator, second = parts.first, parts.separator, parts.second

    --- Reports the text after a field or the separator changes.
    ---@param rebuild boolean
    local function report(rebuild)
        options.onChange(textTemplate.Join(first, separator, second), rebuild)
    end

    -- Each field is half the row less the separator and the gaps beside it.
    local padding = view.contentPadding
    local fieldWidth = -(padding * 2 + SEPARATOR_WIDTH + GAP * 2) / 2
    view:AddText(options.label)

    choiceCombo.Add(view, {
        x = padding,
        width = fieldWidth,
        widthAnchor = 0.5,
        choices = fieldChoices(options.sourceID, first),
        value = first,
        onChange = function(fieldID)
            first = fieldID
            report(false)
        end,
    })

    choiceCombo.Add(view, {
        inline = true,
        x = -SEPARATOR_WIDTH / 2,
        xAnchor = 0.5,
        width = SEPARATOR_WIDTH,
        choices = second ~= nil and textTemplate.SEPARATORS or NO_SEPARATOR,
        value = separator or NONE.id,
        disabled = second == nil,
        onChange = function(separatorID)
            separator = separatorID
            report(false)
        end,
    })

    local secondChoices = fieldChoices(options.sourceID, second)
    table.insert(secondChoices, 1, NONE)
    choiceCombo.Add(view, {
        inline = true,
        x = SEPARATOR_WIDTH / 2 + GAP,
        xAnchor = 0.5,
        width = fieldWidth,
        widthAnchor = 0.5,
        choices = secondChoices,
        value = second or NONE.id,
        onChange = function(fieldID)
            local hadSecond = second ~= nil
            if fieldID == NONE.id then
                second, separator = nil, nil
            else
                second = fieldID
                if not hadSecond then separator = textTemplate.DefaultSeparator(first, second) end
            end
            -- The separator's box is switched on or off with the second field.
            local hasSecond = second ~= nil
            report(hasSecond ~= hadSecond)
        end,
    })
end

return textPicker
