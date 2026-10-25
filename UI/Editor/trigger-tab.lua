-- The aura editor's Trigger tab: which game value the aura shows, picked
-- by data type then data source. Groups have none.

local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local choiceCombo = require("UI/Controls/choice-combo")
local sourcePicker = require("UI/Controls/source-picker")

local triggerTab = {}


---@type table<integer, string> Aura id to the data type picked before a source of it was chosen. Forgotten when the editor switches aura or closes.
local pickedTypes = {}

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
    pickedTypes[aura.id] = nil
    local previous = dataSources.Get(aura.source)
    local hasUntouchedName = auraStore.HasDefaultName(aura) or (previous ~= nil and aura.name == previous.label)
    local colourFollows = hasUntouchedColour(aura, previous)
    auraStore.Edit(aura.id, function(edited)
        if hasUntouchedName then edited.name = source.label end
        if colourFollows then edited.colour = source.colour end
    end)
    context.update("source", source.id)
    -- Some options (e.g. a bar's Smooth fill) depend on the source.
    context.requestRebuild()
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
    view:AddComboBox({
        entries = dataTypeEntries,
        selectedID = dataTypeIndexByID[dataTypeID],
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local picked = typeList[entryID]
            if picked == nil or picked.id == dataTypeID then return end
            -- The aura keeps its source until one of the new type is picked.
            pickedTypes[auraID] = picked.id
            context.requestRebuild()
        end,
    })
    sourcePicker.Add(view, {
        dataTypeID = dataTypeID,
        selectedID = aura.source,
        tooltip = "Type to filter",
        onPick = function(source) pickSource(aura, source, context) end,
    })
end

--- Forgets data types picked without a source, when the editor switches
--- aura or closes.
function triggerTab.Forget()
    pickedTypes = {}
end

return triggerTab
