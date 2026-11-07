-- The aura editor's Trigger tab: which game value the aura shows, picked
-- by data type then data source, and that source's own options. Groups
-- have none.

local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local choiceCombo = require("UI/Controls/choice-combo")
local numberInput = require("UI/Controls/number-input")
local sourcePicker = require("UI/Controls/source-picker")
local fastTypeahead = require("UI/PrettyUI/fast-typeahead")
local uiConstants = require("UI/ui-constants")

local triggerTab = {}

---@type table<integer, string> Aura id to the data type picked before a source of it was chosen. Forgotten when the editor switches aura or closes.
local pickedTypes = {}
---@type table<integer, string> Aura id to the category picked before a source of it was chosen. Forgotten like pickedTypes.
local pickedCategories = {}
-- The duration box's value for no length, so the source shows only on or off.
local NO_DURATION = 0

--- Whether the aura still has the colour it was given, rather than one the
--- player picked: the previous source's colour, or with none the store's default or
--- the display type's own (a segmented bar starts green).
---@param aura Aura
---@param previous DataSource?
---@return boolean
local function hasUntouchedColour(aura, previous)
    if previous ~= nil then return aura.colour == previous.colour end
    local displayType = displayTypes.Get(aura.display)
    local typeDefaults = displayType and displayType.module.defaults or {}
    return aura.colour == auraStore.DEFAULT_COLOUR or aura.colour == typeDefaults.colour
end

--- Switches the aura to a source. Its name and colour follow the new
--- source's unless the player already picked their own.
---@param aura Aura
---@param source DataSource
---@param context EditorTabContext
local function pickSource(aura, source, context)
    pickedTypes[aura.id], pickedCategories[aura.id] = nil, nil
    local previous = dataSources.Get(aura.source)
    local hasUntouchedName = auraStore.HasDefaultName(aura) or (previous ~= nil and aura.name == previous.label)
    local colourFollows = hasUntouchedColour(aura, previous)
    auraStore.Edit(aura.id, function(edited)
        if hasUntouchedName then edited.name = source.label end
        if colourFollows then edited.colour = source.colour end
        -- They belong to the old source.
        if source.id ~= edited.source then edited.sourceOptions = nil end
    end)
    context.update("source", source.id)
    -- Some options (e.g. a bar's Smooth fill) depend on the source.
    context.requestRebuild()
end

--- Ticks or unticks one of the aura's source options, then saves and reports it.
---@param aura Aura
---@param key string A SourceOptions field.
---@param ticked boolean
---@param context EditorTabContext Needs onChanged.
local function setSourceOption(aura, key, ticked, context)
    auraStore.Edit(aura.id, function(edited)
        edited.sourceOptions = edited.sourceOptions or {}
        -- Unticked is nil, so an empty table is tidied away.
        edited.sourceOptions[key] = ticked or nil
    end)
    context.onChanged()
end

--- Adds "Equipped weapon"'s options (see SourceOptions).
---@param view EditorView
---@param aura Aura
---@param context EditorTabContext Needs onChanged.
local function addEquippedOptions(view, aura, context)
    local options = aura.sourceOptions or {}
    view:AddCheckboxButton({
        {
            text = "Hide without a special",
            value = "hideWithoutSpecial",
            selected = options.hideWithoutSpecial == true,
            tooltip = "Hidden while the weapon has no special attack cooldown, except while unlocked",
        },
        {
            text = "Remember last weapon",
            value = "rememberSpecial",
            selected = options.rememberSpecial == true,
            tooltip = "Keeps showing the last special attack worn after switching to a weapon without one",
        },
    }, {
        marginTop = uiConstants.ITEM_GAP,
        onChange = function(_, _, value, selected) setSourceOption(aura, value, selected == true, context) end,
    })
end

--- Adds the length an on/off source can count down from when it comes on
--- (see SourceOptions.durationSeconds), for a source that can be timed.
---@param view EditorView
---@param aura Aura
---@param context EditorTabContext Needs onChanged.
local function addDurationOption(view, aura, context)
    local options = aura.sourceOptions or {}
    numberInput.Add(view, {
        label = "Max duration (seconds)",
        value = options.durationSeconds or NO_DURATION,
        min = NO_DURATION,
        max = auraStore.MAX_DURATION_SECONDS,
        tooltip = "Counts down from when it first shows on the target; 0 shows only whether it's on",
        onChange = function(value)
            local isSet = value >= auraStore.MIN_DURATION_SECONDS
            auraStore.Edit(aura.id, function(edited)
                edited.sourceOptions = edited.sourceOptions or {}
                -- No length is nil, so an empty table is tidied away.
                edited.sourceOptions.durationSeconds = isSet and value or nil
            end)
            context.onChanged()
        end,
    })
end

--- Builds the tab for an aura.
---@param aura Aura
---@param context EditorTabContext Needs update.
function triggerTab.Build(aura, context)
    local auraID = aura.id
    local view = context.view()
    local currentSource = dataSources.Get(aura.source)
    local typeList = dataSources.Types()
    local dataTypeID = pickedTypes[auraID] or (currentSource and currentSource.type) or typeList[1].id
    local dataTypeEntries, dataTypeIndexByID = choiceCombo.Entries(typeList)
    view:AddText("Data type")
    fastTypeahead.Add(view, {
        entries = dataTypeEntries,
        selectedID = dataTypeIndexByID[dataTypeID],
        tooltip = "Type to filter",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local picked = typeList[entryID]
            if picked == nil or picked.id == dataTypeID then return end
            -- The aura keeps its source until one of the new type is picked.
            pickedTypes[auraID], pickedCategories[auraID] = picked.id, nil
            context.requestRebuild()
        end,
    })
    sourcePicker.Add(view, {
        dataTypeID = dataTypeID,
        selectedID = aura.source,
        categoryID = pickedCategories[auraID],
        tooltip = "Type to filter",
        onPick = function(source) pickSource(aura, source, context) end,
        onCategory = function(categoryID)
            -- The aura keeps its source until one of the new category is picked.
            pickedCategories[auraID] = categoryID
            context.requestRebuild()
        end,
    })
    if aura.source == dataSources.EQUIPPED_SPECIAL_ID then addEquippedOptions(view, aura, context) end
    local canTime = currentSource ~= nil and currentSource.readTimed ~= nil
    if canTime then addDurationOption(view, aura, context) end
end

--- Forgets data types and categories picked without a source, when the
--- editor switches aura or closes.
function triggerTab.Forget()
    pickedTypes, pickedCategories = {}, {}
end

return triggerTab
