-- The data source picker: a typeahead of one data type's sources, under a
-- "Data source" label, for the Trigger tab and for checks.

local dataSources = require("Auras/Registries/data-sources")
local fastTypeahead = require("UI/PrettyUI/fast-typeahead")

local sourcePicker = {}

-- Combo entry id and typeahead order for "Choose a source...", shown before
-- the sources until one of this type is picked: the typeahead would show its
-- first entry otherwise.
local PLACEHOLDER_ENTRY_ID = 0
local PLACEHOLDER_ORDER, SOURCE_ORDER = 0, 1

---@class SourcePickerOptions
---@field dataTypeID string The data type whose sources are listed.
---@field selectedID string? The source picked now; one of another type shows the placeholder.
---@field tooltip string
---@field onPick fun(source: DataSource) Called when a different source is picked.

--- Adds the label and the typeahead to a view.
---@param view EditorView
---@param options SourcePickerOptions
function sourcePicker.Add(view, options)
    local sources = dataSources.ListByType(options.dataTypeID)
    local entries, selected = {}, nil
    for index, source in ipairs(sources) do
        entries[index] = { label = source.label, id = index, order = SOURCE_ORDER }
        if source.id == options.selectedID then selected = index end
    end
    if selected == nil then
        entries[#entries + 1] = { label = "Choose a source...", id = PLACEHOLDER_ENTRY_ID, order = PLACEHOLDER_ORDER }
        selected = PLACEHOLDER_ENTRY_ID
    end
    view:AddText("Data source")
    fastTypeahead.Add(view, {
        entries = entries,
        selectedID = selected,
        tooltip = options.tooltip,
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local source = sources[entryID]
            if source == nil or source.id == options.selectedID then return end
            options.onPick(source)
        end,
    })
end

return sourcePicker
