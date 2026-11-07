-- The data source picker: a typeahead of one data type's sources, under a
-- "Data source" label, for the Trigger tab and for checks. A type with
-- categories (see DataType.categories) has a "Category" combo first, and
-- the typeahead lists that category's sources.

local dataSources = require("Auras/Registries/data-sources")
local choiceCombo = require("UI/Controls/choice-combo")
local fastTypeahead = require("UI/PrettyUI/fast-typeahead")

local sourcePicker = {}

-- Combo entry id and typeahead order for "Choose a source...", shown before
-- the sources until one of this type is picked: the typeahead would show its
-- first entry otherwise.
local PLACEHOLDER_ENTRY_ID = 0
local PLACEHOLDER_ORDER, SOURCE_ORDER = 0, 1

---@class SourcePickerOptions
---@field dataTypeID string The data type whose sources are listed.
---@field selectedID string? The source picked now; one of another type (or category) shows the placeholder.
---@field categoryID string? The category picked, for a type with categories; nil for the picked source's, else the first.
---@field tooltip string
---@field onPick fun(source: DataSource) Called when a different source is picked.
---@field onCategory fun(categoryID: string)? Called when a different category is picked; the caller rebuilds the picker with it as categoryID.

--- The category to list: the one picked (if it's the type's), else the
--- selected source's, else the first.
---@param categories DataCategory[]
---@param options SourcePickerOptions
---@return string categoryID
local function shownCategory(categories, options)
    for _, category in ipairs(categories) do
        if category.id == options.categoryID then return category.id end
    end
    local selected = dataSources.Get(options.selectedID)
    local isOfType = selected ~= nil and selected.type == options.dataTypeID
    if isOfType and selected.category ~= nil then return selected.category end
    return categories[1].id
end

--- Adds the category combo (for a type with categories), the label and the typeahead to a view.
---@param view EditorView
---@param options SourcePickerOptions
function sourcePicker.Add(view, options)
    local categories = dataSources.Categories(options.dataTypeID)
    local categoryID = nil
    if categories ~= nil then
        categoryID = shownCategory(categories, options)
        choiceCombo.Add(view, {
            label = "Category",
            choices = categories,
            value = categoryID,
            onChange = function(pickedID)
                if options.onCategory ~= nil then options.onCategory(pickedID) end
            end,
        })
    end
    local sources = dataSources.ListByType(options.dataTypeID, categoryID)
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
